import Foundation
import os

/// The searches' own connection to the speaker, opened on demand and shared by several searches at once.
actor SearchChannel {
    enum Failure: Error {
        /// The connection could not be had; the search can go over another one.
        case unavailable
    }

    private let host: String
    private let port: Int
    private let gate: RequestGate
    private let idleTimeout: Duration
    private let retryDelay: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let makeTransport: @Sendable () -> any TransportProtocol

    private var connection: HEOSConnection?
    private var opening: Task<HEOSConnection, Error>?
    private var unavailableUntil: ContinuousClock.Instant?
    private var inFlight = 0
    private var idleTask: Task<Void, Never>?
    private var isClosed = false

    init(
        host: String,
        port: Int,
        limit: Int = 8,
        idleTimeout: Duration = .seconds(30),
        retryDelay: Duration = .seconds(60),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        makeTransport: @escaping @Sendable () -> any TransportProtocol
    ) {
        self.host = host
        self.port = port
        self.gate = RequestGate(limit: limit)
        self.idleTimeout = idleTimeout
        self.retryDelay = retryDelay
        self.now = now
        self.makeTransport = makeTransport
    }

    /// Throws `Failure.unavailable` when the connection cannot be opened or drops before the answer.
    func send(_ command: HEOSCommand) async throws -> HEOSResponse {
        try await gate.run { try await self.sendNow(command) }
    }

    func close() async {
        isClosed = true
        idleTask?.cancel()
        idleTask = nil
        opening?.cancel()
        opening = nil
        await connection?.disconnect()
        connection = nil
    }

    private func sendNow(_ command: HEOSCommand) async throws -> HEOSResponse {
        let conn = try await openConnection()
        beginRequest()
        defer { endRequest() }
        do {
            return try await conn.send(command)
        } catch {
            guard Self.isConnectionFailure(error) else { throw error }
            await drop(conn)
            throw Failure.unavailable
        }
    }

    /// A timeout means a slow service; asking again on another connection would wait as long.
    static func isConnectionFailure(_ error: Error) -> Bool {
        if error is HEOSError || error is CancellationError { return false }
        if let transportError = error as? TransportError { return transportError != .timeout }
        return true
    }

    private func openConnection() async throws -> HEOSConnection {
        if let connection {
            if await connection.isConnected { return connection }
            await drop(connection)
        }
        guard !isClosed else { throw Failure.unavailable }
        if let unavailableUntil {
            guard now() >= unavailableUntil else { throw Failure.unavailable }
            self.unavailableUntil = nil
        }
        let task = opening ?? makeOpeningTask()
        opening = task
        do {
            let conn = try await task.value
            if opening == task { opening = nil }
            guard !isClosed else {
                await conn.disconnect()
                throw Failure.unavailable
            }
            if connection == nil { connection = conn }
            unavailableUntil = nil
            return conn
        } catch {
            if opening == task { opening = nil }
            if !isClosed, unavailableUntil == nil {
                unavailableUntil = now().advanced(by: retryDelay)
                HEOSLogger.connection.warning("Search connection unavailable, searching on the main one: \(error.localizedDescription)")
            }
            throw Failure.unavailable
        }
    }

    private func makeOpeningTask() -> Task<HEOSConnection, Error> {
        let host = host
        let port = port
        let transport = makeTransport()
        return Task {
            let conn = HEOSConnection(transport: transport)
            try await conn.connect(host: host, port: port)
            return conn
        }
    }

    private func drop(_ conn: HEOSConnection) async {
        guard connection === conn else { return }
        connection = nil
        await conn.disconnect()
    }

    private func beginRequest() {
        inFlight += 1
        idleTask?.cancel()
        idleTask = nil
    }

    /// The connection goes once nothing has used it for a while; the next search opens another.
    private func endRequest() {
        inFlight -= 1
        guard inFlight == 0, !isClosed else { return }
        let idleTimeout = idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: idleTimeout)
            guard !Task.isCancelled else { return }
            await self?.closeIfIdle()
        }
    }

    private func closeIfIdle() async {
        guard inFlight == 0, let connection else { return }
        self.connection = nil
        await connection.disconnect()
    }
}
