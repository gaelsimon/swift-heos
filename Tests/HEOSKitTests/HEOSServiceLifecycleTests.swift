import Testing
import Foundation
@testable import HEOSKit
import NeosDomain

@Suite("HEOSService Suspend/Resume Tests")
struct HEOSServiceLifecycleTests {

    @Test @MainActor func suspendWithoutASessionDoesNothing() async {
        let state = MockStateUpdater()
        let service = HEOSService(stateUpdater: state)

        await service.suspend()

        #expect(state.connectionState == nil)
    }

    @Test @MainActor func suspendKeepsTheReconnectTarget() async {
        let state = MockStateUpdater()
        let service = HEOSService(stateUpdater: state)
        await service.connectionCoordinator.recordConnection(host: "192.0.2.10", port: 1255, playerID: 7)

        await service.suspend()

        let host = await service.connectionCoordinator.lastHost
        let pid = await service.connectionCoordinator.lastPlayerID
        #expect(host == "192.0.2.10")
        #expect(pid == 7)
        #expect(state.connectionState == .reconnecting)
    }

    @Test @MainActor func resumeWithoutASessionDoesNothing() async {
        let state = MockStateUpdater()
        let service = HEOSService(stateUpdater: state)

        await service.resume()

        let isReconnecting = await service.connectionCoordinator.isReconnecting
        #expect(isReconnecting == false)
    }

    /// Reconnecting keeps the dead connection, so resuming must read the flag, not the nil-ness.
    @Test func resumeIsWorthDoingWhileReconnectingWithAStaleConnection() {
        #expect(HEOSService.shouldResume(hasTarget: true, hasConnection: true, isReconnecting: true))
        #expect(HEOSService.shouldResume(hasTarget: true, hasConnection: false, isReconnecting: false))
        #expect(HEOSService.shouldResume(hasTarget: true, hasConnection: true, isReconnecting: false) == false)
        #expect(HEOSService.shouldResume(hasTarget: false, hasConnection: false, isReconnecting: true) == false)
    }

    @Test @MainActor func disconnectForgetsTheTargetSoASleepCannotResurrectIt() async {
        let state = MockStateUpdater()
        let service = HEOSService(stateUpdater: state)
        await service.connectionCoordinator.recordConnection(host: "192.0.2.10", port: 1255, playerID: nil)

        await service.disconnect()
        await service.suspend()
        await service.resume()

        let host = await service.connectionCoordinator.lastHost
        let isReconnecting = await service.connectionCoordinator.isReconnecting
        #expect(host == nil)
        #expect(isReconnecting == false)
        #expect(state.connectionState == .disconnected)
    }

    @Test @MainActor func resumeRestartsReconnectionForTheSuspendedTarget() async {
        let state = MockStateUpdater()
        let service = HEOSService(stateUpdater: state)
        await service.connectionCoordinator.recordConnection(host: "192.0.2.10", port: 1255, playerID: nil)
        await service.suspend()

        await service.resume()

        let isReconnecting = await service.connectionCoordinator.isReconnecting
        #expect(isReconnecting == true)

        await service.disconnect()
    }

    // MARK: - A failed group fetch

    /// A getGroups that times out on reconnect used to publish an empty list: the sidebar lost every
    /// group and a stereo pair un-collapsed into two rows until the next groups_changed.
    @Test @MainActor func aFailedGroupFetchLeavesTheGroupsOnScreenAlone() async {
        let state = MockStateUpdater()
        let pair = SpeakerGroup(
            gid: 1,
            name: "Kitchen Left",
            players: [
                GroupPlayer(name: "Kitchen Left", pid: 1, role: .leader),
                GroupPlayer(name: "Kitchen Right", pid: 2, role: .member)
            ]
        )
        state.groups = [pair]
        state.multiRoomGroupIDs = []
        // No services: every fetch reads as a failure, which is the reconnect-after-a-blip case.
        let service = HEOSService(stateUpdater: state)

        await service.loadStateTwoPhase()

        #expect(state.groups.map(\.gid) == [1])
        #expect(state.calls.contains { $0.hasPrefix("setGroups") } == false)
    }

    // MARK: - A failed sources fetch

    /// A getMusicSources that fails on connect used to publish an empty list: the sidebar lost its
    /// Services section until a sources_changed event, which may never come (issue neos-audio#33).
    @Test @MainActor func aFailedSourcesFetchOnFirstConnectLeavesTheSourcesAlone() async {
        let state = MockStateUpdater()
        state.musicSources = [MusicSource(sid: 3, name: "TuneIn", type: "music_service")]
        let service = HEOSService(stateUpdater: state)

        await service.loadStateTwoPhase()

        #expect(state.musicSources.map(\.sid) == [3])
    }

    @Test @MainActor func aFailedSourcesFetchOnReconnectLeavesTheSourcesAlone() async {
        let state = MockStateUpdater()
        state.musicSources = [MusicSource(sid: 3, name: "TuneIn", type: "music_service")]
        let service = HEOSService(stateUpdater: state)

        await service.loadAllStateParallel(cachedPID: 1)

        #expect(state.musicSources.map(\.sid) == [3])
    }

    /// A device busy with the connect burst can refuse the sources request; asked again alone, it answers.
    private func serviceWhoseFirstSourcesRequestIsRefused(_ state: MockStateUpdater, again: Bool = false) async throws -> HEOSService {
        let transport = MockTCPTransport(autoRespond: true)
        let connection = HEOSConnection(transport: transport)
        try await connection.connect(host: "test", port: 1255)
        try await Task.sleep(for: .milliseconds(50))
        await transport.enqueueResponse(
            #"{"heos":{"command":"browse/get_music_sources","result":"fail","message":"eid=13&text=Processing previous command"}}"#
        )
        await transport.enqueueResponse(again
            ? #"{"heos":{"command":"browse/get_music_sources","result":"fail","message":"eid=13&text=Processing previous command"}}"#
            : #"{"heos":{"command":"browse/get_music_sources","result":"success","message":""},"payload":[{"name":"TuneIn","sid":3,"type":"music_service","available":"true"}]}"#
        )
        let service = HEOSService(stateUpdater: state)
        await service.useBrowseService(HEOSKit.BrowseService(connection: connection))
        return service
    }

    @Test @MainActor func aRefusedSourcesRequestOnFirstConnectIsAskedAgain() async throws {
        let state = MockStateUpdater()
        let service = try await serviceWhoseFirstSourcesRequestIsRefused(state)

        await service.loadStateTwoPhase()

        #expect(state.musicSources.map(\.sid) == [3])
    }

    @Test @MainActor func aRefusedSourcesRequestOnReconnectIsAskedAgain() async throws {
        let state = MockStateUpdater()
        let service = try await serviceWhoseFirstSourcesRequestIsRefused(state)

        await service.loadAllStateParallel(cachedPID: 1)

        #expect(state.musicSources.map(\.sid) == [3])
    }

    @Test @MainActor func aSourcesRequestRefusedTwiceShowsInDiagnostics() async throws {
        let state = MockStateUpdater()
        let service = try await serviceWhoseFirstSourcesRequestIsRefused(state, again: true)

        await service.loadStateTwoPhase()

        #expect(state.nonFatalReports.map(\.source) == ["connect.sources"])
    }
}

private extension HEOSService {
    func useBrowseService(_ service: HEOSKit.BrowseService) {
        browseService = service
    }
}
