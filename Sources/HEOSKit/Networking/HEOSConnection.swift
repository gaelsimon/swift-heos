import Foundation
import os

public actor HEOSConnection {
    private let transport: any TransportProtocol
    private let commandBuilder = HEOSCommandBuilder()
    private let responseParser = HEOSResponseParser()
    private var eventContinuation: AsyncStream<HEOSEvent>.Continuation?

    private struct PendingCommand {
        let id: UInt64
        let commandKey: String
        let continuation: CheckedContinuation<HEOSResponse, Error>
        let timeoutTask: Task<Void, Never>
        let timeoutDuration: Duration
    }

    private var nextCommandID: UInt64 = 0
    private var pendingCommands: [UInt64: PendingCommand] = [:]
    /// Responses that fitted more than one pending command; see `recordAmbiguousMatch`.
    private(set) var ambiguousMatchCount = 0
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    public init(transport: any TransportProtocol) {
        self.transport = transport
    }

    public var isConnected: Bool {
        get async { await transport.isConnected }
    }

    public func connect(host: String, port: Int) async throws {
        HEOSLogger.connection.info("Connecting to \(host):\(port)")
        try await transport.connect(host: host, port: port)
        HEOSLogger.connection.info("Connected to \(host):\(port)")
        startReceiving()
    }

    public func disconnect() async {
        HEOSLogger.connection.info("Disconnecting")
        heartbeatTask?.cancel()
        heartbeatTask = nil
        receiveTask?.cancel()
        receiveTask = nil

        for (_, pending) in pendingCommands {
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: TransportError.disconnected)
        }
        pendingCommands.removeAll()

        eventContinuation?.finish()
        eventContinuation = nil

        await transport.disconnect()
        WireLog.shared.log("## disconnected")
        HEOSLogger.connection.info("Disconnected")
    }

    @discardableResult
    public func send(_ command: HEOSCommand, timeout: Duration = .seconds(15)) async throws -> HEOSResponse {
        let commandString = commandBuilder.build(command)
        let commandKey = Self.matchingKey(for: command)

        let id = nextCommandID
        nextCommandID &+= 1

        let data = Data(commandString.utf8)

        // Cancellable: a caller that gives up must free its FIFO slot instead of waiting it out.
        return try await withTaskCancellationHandler {
            // Registered before sending: an instant reply during `transport.send` would go unmatched.
            try await withCheckedThrowingContinuation { continuation in
                registerPending(id: id, commandKey: commandKey, continuation: continuation, timeout: timeout)

                // Cancelled before registration, so `onCancel` could not find it.
                guard !Task.isCancelled else {
                    abandonPending(id)
                    return
                }

                writeCommand(data, id: id, commandString: commandString)
            }
        } onCancel: {
            Task { await self.abandonPending(id) }
        }
    }

    /// Records the command and arms its timeout, so a response can match it from this point on.
    private func registerPending(
        id: UInt64,
        commandKey: String,
        continuation: CheckedContinuation<HEOSResponse, Error>,
        timeout: Duration
    ) {
        pendingCommands[id] = PendingCommand(
            id: id,
            commandKey: commandKey,
            continuation: continuation,
            timeoutTask: makeTimeoutTask(id: id, commandKey: commandKey, timeout: timeout),
            timeoutDuration: timeout
        )
    }

    private func makeTimeoutTask(id: UInt64, commandKey: String, timeout: Duration) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            if let timedOut = pendingCommands.removeValue(forKey: id) {
                WireLog.shared.log("!! timeout #\(id) key=\(commandKey)")
                HEOSLogger.connection.warning("Command #\(id) timed out: \(commandKey)")
                timedOut.continuation.resume(throwing: TransportError.timeout)
            }
        }
    }

    /// One task per write: `transport.send` has no timeout, so serialising would let one stall block the rest.
    /// The priority is pinned: the executor orders jobs by priority first, and two commands sharing a
    /// matching key must reach the wire in ID order or `oldestPendingID` hands them the wrong response.
    private func writeCommand(_ data: Data, id: UInt64, commandString: String) {
        Task(priority: .userInitiated) {
            do {
                try await transport.send(data)
                WireLog.shared.log("-> #\(id) \(commandString.trimmingCharacters(in: .whitespacesAndNewlines))")
                HEOSLogger.connection.debug("Sent command #\(id): \(commandString.trimmingCharacters(in: .whitespacesAndNewlines))")
            } catch {
                guard let failed = pendingCommands.removeValue(forKey: id) else { return }
                failed.timeoutTask.cancel()
                failed.continuation.resume(throwing: error)
            }
        }
    }

    /// Drops a command whose caller gave up, freeing its slot for the next matching response.
    private func abandonPending(_ id: UInt64) {
        guard let pending = pendingCommands.removeValue(forKey: id) else { return }
        WireLog.shared.log("xx abandoned #\(id) key=\(pending.commandKey)")
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: CancellationError())
    }

    public func sendFireAndForget(_ command: HEOSCommand) async throws {
        let commandString = commandBuilder.build(command)
        let data = Data(commandString.utf8)
        try await transport.send(data)
    }

    /// Finishes the stream it replaces: an abandoned continuation never ends its `for await`.
    public func makeEventStream() -> AsyncStream<HEOSEvent> {
        eventContinuation?.finish()
        let (stream, continuation) = AsyncStream<HEOSEvent>.makeStream()
        self.eventContinuation = continuation
        return stream
    }

    public func startHeartbeat(interval: TimeInterval = 10.0) {
        heartbeatTask?.cancel()
        heartbeatTask = Task {
            var consecutiveFailures = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                do {
                    try await send(.heartBeat, timeout: .seconds(5))
                    consecutiveFailures = 0
                } catch {
                    consecutiveFailures += 1
                    HEOSLogger.connection.warning("Heartbeat failed (\(consecutiveFailures)/3): \(error.localizedDescription)")
                    if consecutiveFailures >= 3 {
                        HEOSLogger.connection.error("3 consecutive heartbeat failures; connection lost")
                        handleReceiveError(TransportError.disconnected)
                        break
                    }
                }
            }
        }
    }

    // MARK: - Private

    private func startReceiving() {
        receiveTask = Task {
            let stream = transport.receive()
            do {
                for try await data in stream {
                    handleMessage(data)
                }
            } catch {
                handleReceiveError(error)
            }
        }
    }

    private func handleMessage(_ data: Data) {
        WireLog.shared.log("<- \((String(data: data, encoding: .utf8) ?? "<binary \(data.count)B>").trimmingCharacters(in: .whitespacesAndNewlines))")
        do {
            let parsed = try responseParser.parse(data)
            switch parsed {
            case .response(let response):
                let commandKey = Self.matchingKey(command: response.command, message: response.message)
                if response.isUnderProcess {
                    WireLog.shared.log("~~ under-process key=\(commandKey)")
                    HEOSLogger.connection.debug("Command under process for \(response.command), waiting for real response")
                    resetTimeout(for: commandKey)
                } else if let id = matchPendingID(for: commandKey),
                          let pending = pendingCommands.removeValue(forKey: id) {
                    WireLog.shared.log("ok #\(id) key=\(commandKey)")
                    HEOSLogger.connection.debug("Matched response #\(id): \(response.command)")
                    pending.timeoutTask.cancel()
                    pending.continuation.resume(returning: response)
                } else {
                    WireLog.shared.log("!! UNMATCHED key=\(commandKey) pending=[\(pendingCommandKeys)]")
                    HEOSLogger.connection.warning("Unmatched response: \(commandKey) (pending: \(self.pendingCommandKeys))")
                }
            case .event(let event):
                if event.eventName.contains("error") {
                    HEOSLogger.connection.warning("Event: \(event.eventName); \(event.message)")
                } else {
                    HEOSLogger.connection.debug("Event: \(event.eventName)")
                }
                eventContinuation?.yield(event)
            }
        } catch {
            if let heosError = error as? HEOSError {
                let commandKey = Self.matchingKey(command: heosError.command, message: heosError.message)
                if let id = matchPendingID(for: commandKey),
                   let pending = pendingCommands.removeValue(forKey: id) {
                    WireLog.shared.log("ok-err #\(id) key=\(commandKey)")
                    pending.timeoutTask.cancel()
                    pending.continuation.resume(throwing: heosError)
                } else {
                    WireLog.shared.log("!! UNMATCHED-ERROR key=\(commandKey) pending=[\(pendingCommandKeys)]")
                    HEOSLogger.connection.warning("Unmatched error response: \(commandKey)")
                    eventContinuation?.yield(HEOSEvent(
                        command: "event/system_error",
                        message: [
                            "command": commandKey,
                            "error": heosError.text,
                            "eid": "\(heosError.errorID)"
                        ]
                    ))
                }
            } else {
                let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
                HEOSLogger.connection.error("Parse error: \(error.localizedDescription); data: \(preview)")
            }
        }
    }

    private func handleReceiveError(_ error: Error) {
        WireLog.shared.log("## receive error: \(error.localizedDescription)")
        HEOSLogger.connection.error("Receive error: \(error.localizedDescription)")
        for (_, pending) in pendingCommands {
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: error)
        }
        pendingCommands.removeAll()
        eventContinuation?.finish()
    }

    /// Find the oldest pending command ID matching a command key (FIFO).
    private func oldestPendingID(for commandKey: String) -> UInt64? {
        pendingCommands.values
            .filter { $0.commandKey == commandKey }
            .min(by: { $0.id < $1.id })?
            .id
    }

    /// Exact key first, then the oldest compatible pending command: a parameter missing on either
    /// side is tolerated (echoes vary per firmware and command), a differing value disqualifies --
    /// so an imperfect echo degrades to FIFO while a contradicting one is never mis-delivered.
    private func matchPendingID(for key: String) -> UInt64? {
        if let id = oldestPendingID(for: key) { return id }
        let candidates = compatiblePendingCommands(for: key)
        guard let oldest = candidates.min(by: { $0.id < $1.id }) else { return nil }
        if Set(candidates.map(\.commandKey)).count > 1 {
            recordAmbiguousMatch(key: key, candidates: candidates, resolvedTo: oldest.id)
        }
        return oldest.id
    }

    /// Pending commands the key could belong to: same path, and no parameter the two disagree on.
    private func compatiblePendingCommands(for key: String) -> [PendingCommand] {
        let (path, params) = Self.parseKey(key)
        return pendingCommands.values.filter { pending in
            let (pendingPath, pendingParams) = Self.parseKey(pending.commandKey)
            guard pendingPath == path else { return false }
            return params.allSatisfy { name, value in pendingParams[name].map { $0 == value } ?? true }
                && pendingParams.allSatisfy { name, value in params[name].map { $0 == value } ?? true }
        }
    }

    /// Counts a response that fitted more than one key: the echo omits what tells them apart, so
    /// FIFO is a guess, not a match. Identical keys do not count, their responses being the same.
    private func recordAmbiguousMatch(key: String, candidates: [PendingCommand], resolvedTo id: UInt64) {
        ambiguousMatchCount += 1
        let listed = candidates
            .sorted { $0.id < $1.id }
            .map { "#\($0.id):\($0.commandKey)" }
            .joined(separator: ", ")
        WireLog.shared.log("?? AMBIGUOUS key=\(key) candidates=[\(listed)] -> #\(id)")
        HEOSLogger.connection.warning(
            "Ambiguous response \(key, privacy: .public): [\(listed, privacy: .public)]; resolved FIFO to #\(id)"
        )
    }

    /// Splits a matching key back into its command path and parameters.
    private static func parseKey(_ key: String) -> (path: String, params: [String: String]) {
        guard let bar = key.firstIndex(of: "|") else { return (key, [:]) }
        var params: [String: String] = [:]
        for pair in key[key.index(after: bar)...].split(separator: "&") {
            let sides = pair.split(separator: "=", maxSplits: 1)
            if sides.count == 2 { params[String(sides[0])] = String(sides[1]) }
        }
        return (String(key[..<bar]), params)
    }

    /// Reset the timeout for a pending command when the device sends "command under process".
    private func resetTimeout(for commandKey: String) {
        guard let id = matchPendingID(for: commandKey),
              let existing = pendingCommands.removeValue(forKey: id) else { return }
        existing.timeoutTask.cancel()
        let duration = existing.timeoutDuration
        let newTimeoutTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            if let timedOut = pendingCommands.removeValue(forKey: id) {
                WireLog.shared.log("!! timeout #\(id) key=\(commandKey)")
                HEOSLogger.connection.warning("Command #\(id) timed out: \(commandKey)")
                timedOut.continuation.resume(throwing: TransportError.timeout)
            }
        }
        pendingCommands[id] = PendingCommand(
            id: existing.id,
            commandKey: existing.commandKey,
            continuation: existing.continuation,
            timeoutTask: newTimeoutTask,
            timeoutDuration: duration
        )
    }

    private var pendingCommandKeys: String {
        pendingCommands.values
            .sorted(by: { $0.id < $1.id })
            .map { "#\($0.id):\($0.commandKey)" }
            .joined(separator: ", ")
    }

    // MARK: - Response Matching

    /// Matching key for a command: its path plus the discriminating parameters (sid/cid/scid for
    /// browse, pid/gid elsewhere, range for get_queue) so concurrent same-path commands don't swap responses.
    private static func matchingKey(for command: HEOSCommand) -> String {
        switch command {
        case .browseSource(let sid, let range):
            return "browse/browse|sid=\(sid)" + rangeSuffix(range)
        case .browseSourceContainer(let sid, let cid, let range):
            return "browse/browse|sid=\(sid)&cid=\(normalizeCID(cid))" + rangeSuffix(range)
        case .search(let sid, let term, let scid, let range):
            return "browse/search|sid=\(sid)&scid=\(scid)&search=\(normalizeCID(term))" + rangeSuffix(range)
        case .getSearchCriteria(let sid):
            return "browse/get_search_criteria|sid=\(sid)"
        case .getQueue(let pid, let range):
            return "player/get_queue|pid=\(pid)" + rangeSuffix(range)
        default:
            if let pid = command.pid { return "\(command.commandPath)|pid=\(pid)" }
            if let gid = command.gid { return "\(command.commandPath)|gid=\(gid)" }
            return command.commandPath
        }
    }

    /// Mirror of `matchingKey(for:)`, rebuilt from the parameters a response or error echoes back.
    private static func matchingKey(command: String, message: [String: String]) -> String {
        let echoedRange = message["range"].map { "&range=\($0)" } ?? ""
        if let sid = message["sid"] {
            switch command {
            case "browse/browse":
                if let cid = message["cid"] {
                    return "browse/browse|sid=\(sid)&cid=\(normalizeCID(cid))" + echoedRange
                }
                return "browse/browse|sid=\(sid)" + echoedRange
            case "browse/search":
                if let scid = message["scid"], let term = message["search"] {
                    return "browse/search|sid=\(sid)&scid=\(scid)&search=\(normalizeCID(term))" + echoedRange
                }
                return "browse/search|sid=\(sid)"
            case "browse/get_search_criteria":
                return "browse/get_search_criteria|sid=\(sid)"
            default:
                break
            }
        }
        if let pid = message["pid"] {
            if command == "player/get_queue" {
                return "player/get_queue|pid=\(pid)" + echoedRange
            }
            return "\(command)|pid=\(pid)"
        }
        if let gid = message["gid"] {
            return "\(command)|gid=\(gid)"
        }
        return command
    }

    /// Key fragment for an optional range, formatted as it is sent and echoed on the wire.
    private static func rangeSuffix(_ range: ClosedRange<Int>?) -> String {
        guard let range else { return "" }
        return "&range=\(range.lowerBound),\(range.upperBound)"
    }

    /// Fully percent-decodes a CID for matching key normalization.
    /// HEOS browse responses echo CIDs fully decoded even when sent with nested
    /// encoding (e.g. `%252C` → `%2C` → `,`). Decode repeatedly until stable.
    private static func normalizeCID(_ cid: String) -> String {
        var result = cid
        while let decoded = result.removingPercentEncoding, decoded != result {
            result = decoded
        }
        return result
    }
}
