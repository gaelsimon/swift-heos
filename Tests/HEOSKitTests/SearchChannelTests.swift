import Testing
import Foundation
@testable import HEOSKit

@Suite("SearchChannel Tests")
struct SearchChannelTests {

    /// Hands out mock transports and keeps them, so a test can see how many connections were opened.
    final class TransportMaker: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [MockTCPTransport] = []
        private let autoRespond: Bool
        private let connectError: Error?

        init(autoRespond: Bool = false, connectError: Error? = nil) {
            self.autoRespond = autoRespond
            self.connectError = connectError
        }

        var transports: [MockTCPTransport] {
            lock.lock()
            defer { lock.unlock() }
            return made
        }

        func make() -> any TransportProtocol {
            let transport = MockTCPTransport(autoRespond: autoRespond, connectError: connectError)
            lock.lock()
            made.append(transport)
            lock.unlock()
            return transport
        }
    }

    private func makeChannel(
        _ maker: TransportMaker,
        limit: Int = 8,
        idleTimeout: Duration = .seconds(30),
        clock: ManualClock = ManualClock()
    ) -> SearchChannel {
        SearchChannel(
            host: "test", port: 1255, limit: limit, idleTimeout: idleTimeout, retryDelay: .seconds(60),
            now: { clock.instant }, makeTransport: { maker.make() }
        )
    }

    private func command(scid: Int) -> HEOSCommand {
        .search(sid: 10, searchString: "x", searchCriteriaID: scid, range: 0...4)
    }

    private func answer(scid: Int) -> String {
        """
        {"heos":{"command":"browse/search","result":"success","message":"sid=10&search=x&scid=\(scid)&range=0,4&returned=0&count=0"}}
        """
    }

    private func waitForSent(_ transport: MockTCPTransport, count: Int) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, await transport.sentData.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitUntilReceiving(_ transport: MockTCPTransport) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, !(await transport.isReceiving) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func nothingIsOpenedBeforeTheFirstSearch() async {
        let maker = TransportMaker()
        _ = makeChannel(maker)
        #expect(maker.transports.isEmpty)
    }

    @Test func severalSearchesShareOneConnectionAtOnce() async throws {
        let maker = TransportMaker()
        let channel = makeChannel(maker)

        let searches = (1...3).map { scid in Task { try await channel.send(command(scid: scid)) } }
        try await Task.sleep(for: .milliseconds(50))
        let transport = try #require(maker.transports.first)
        await waitForSent(transport, count: 3)
        await waitUntilReceiving(transport)

        #expect(maker.transports.count == 1)
        #expect(await transport.sentData.count == 3)
        for scid in 1...3 {
            await transport.simulateEvent(answer(scid: scid))
        }
        for search in searches {
            _ = try await search.value
        }
        await channel.close()
    }

    @Test func searchesBeyondTheLimitWaitForASlot() async throws {
        let maker = TransportMaker()
        let channel = makeChannel(maker, limit: 2)

        let searches = (1...3).map { scid in Task { try await channel.send(command(scid: scid)) } }
        try await Task.sleep(for: .milliseconds(50))
        let transport = try #require(maker.transports.first)
        await waitUntilReceiving(transport)
        try await Task.sleep(for: .milliseconds(50))
        let sentBeforeAnswer = await transport.sentData.count
        #expect(sentBeforeAnswer == 2)

        let lastSent = try #require(await transport.lastSentString())
        let afterScid = try #require(lastSent.components(separatedBy: "scid=").last)
        let sentScid = try #require(Int(afterScid.prefix(while: \.isNumber)))
        await transport.simulateEvent(answer(scid: sentScid))
        await waitForSent(transport, count: 3)
        #expect(await transport.sentData.count == 3)

        for scid in 1...3 {
            await transport.simulateEvent(answer(scid: scid))
        }
        for search in searches {
            _ = try? await search.value
        }
        await channel.close()
    }

    @Test func aConnectionThatCannotOpenIsLeftAloneForAWhile() async throws {
        let maker = TransportMaker(connectError: TransportError.timeout)
        let clock = ManualClock()
        let channel = makeChannel(maker, clock: clock)

        await #expect(throws: SearchChannel.Failure.self) { try await channel.send(command(scid: 1)) }
        await #expect(throws: SearchChannel.Failure.self) { try await channel.send(command(scid: 1)) }
        #expect(maker.transports.count == 1)

        clock.advance(by: .seconds(61))
        await #expect(throws: SearchChannel.Failure.self) { try await channel.send(command(scid: 1)) }
        #expect(maker.transports.count == 2)
    }

    @Test func theConnectionClosesWhenIdleAndReopensForTheNextSearch() async throws {
        let maker = TransportMaker(autoRespond: true)
        let channel = makeChannel(maker, idleTimeout: .milliseconds(50))

        let first = Task { try await channel.send(command(scid: 1)) }
        try await Task.sleep(for: .milliseconds(30))
        let transport = try #require(maker.transports.first)
        await waitUntilReceiving(transport)
        await transport.simulateEvent(answer(scid: 1))
        _ = try await first.value

        try await Task.sleep(for: .milliseconds(200))
        #expect(await transport.isConnected == false)

        let second = Task { try await channel.send(command(scid: 2)) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(maker.transports.count == 2)
        second.cancel()
        await channel.close()
    }

    @Test func aDroppedConnectionFailsItsSearchAndIsReopened() async throws {
        let maker = TransportMaker()
        let channel = makeChannel(maker)

        let search = Task { try await channel.send(command(scid: 1)) }
        try await Task.sleep(for: .milliseconds(30))
        let transport = try #require(maker.transports.first)
        await waitForSent(transport, count: 1)
        await waitUntilReceiving(transport)
        await transport.simulateDisconnection()

        await #expect(throws: SearchChannel.Failure.self) { try await search.value }

        let next = Task { try await channel.send(command(scid: 2)) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(maker.transports.count == 2)
        next.cancel()
        await channel.close()
    }

    @Test func aClosedChannelTakesNoMoreSearches() async throws {
        let maker = TransportMaker()
        let channel = makeChannel(maker)
        await channel.close()

        await #expect(throws: SearchChannel.Failure.self) { try await channel.send(command(scid: 1)) }
        #expect(maker.transports.isEmpty)
    }

    @Test func onlyAConnectionProblemCountsAsAFailure() {
        #expect(SearchChannel.isConnectionFailure(TransportError.disconnected))
        #expect(SearchChannel.isConnectionFailure(TransportError.notConnected))
        #expect(!SearchChannel.isConnectionFailure(TransportError.timeout))
        #expect(!SearchChannel.isConnectionFailure(CancellationError()))
        #expect(!SearchChannel.isConnectionFailure(HEOSError(errorID: 12, text: "System error", command: "browse/search", message: [:])))
    }
}
