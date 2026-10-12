import Testing
import Foundation
@testable import HEOSKit

@Suite("BrowseService Tests")
struct BrowseServiceTests {

    // MARK: - Helpers

    private func makeResponse(command: String, message: String = "", payload: String = "") -> String {
        if payload.isEmpty {
            return """
            {"heos":{"command":"\(command)","result":"success","message":"\(message)"}}
            """
        }
        return """
        {"heos":{"command":"\(command)","result":"success","message":"\(message)"},"payload":\(payload)}
        """
    }

    private func makeSetup() async throws -> (BrowseService, MockTCPTransport, HEOSConnection) {
        let transport = MockTCPTransport(autoRespond: true)
        let connection = HEOSConnection(transport: transport)
        try await connection.connect(host: "test", port: 1255)
        try await Task.sleep(for: .milliseconds(50))
        let service = BrowseService(connection: connection)
        return (service, transport, connection)
    }

    /// A search failure shaped like the one a DLNA server that cannot search produces.
    private func makeSearchSystemError(sid: Int, scid: Int, query: String) -> String {
        """
        {"heos":{"command":"browse/search","result":"fail","message":"eid=12&text=System error&syserrno=-15&sid=\(sid)&search=\(query)&scid=\(scid)"}}
        """
    }

    private func searchIgnoringError(_ service: BrowseService, sid: Int, scid: Int, query: String) async {
        _ = try? await service.search(sid: sid, query: query, criteriaID: scid)
    }

    // MARK: - Search Capability

    private func makeSetupWithClock() async throws -> (BrowseService, MockTCPTransport, HEOSConnection, ManualClock) {
        let transport = MockTCPTransport(autoRespond: true)
        let connection = HEOSConnection(transport: transport)
        try await connection.connect(host: "test", port: 1255)
        try await Task.sleep(for: .milliseconds(50))
        let clock = ManualClock()
        let service = BrowseService(connection: connection, now: { clock.instant })
        return (service, transport, connection, clock)
    }

    @Test func repeatedSystemErrorsLeaveATargetAloneBriefly() async throws {
        let (service, transport, connection, _) = try await makeSetupWithClock()
        for _ in 0..<5 {
            await transport.enqueueResponse(makeSearchSystemError(sid: -2116790550, scid: 1, query: "x"))
        }

        for _ in 0..<5 {
            await searchIgnoringError(service, sid: -2116790550, scid: 1, query: "x")
        }

        // Two reached the wire; the burst behind them raised the recorded error.
        #expect(await transport.sentData.count == 2)
        await connection.disconnect()
    }

    @Test func theSkipWindowExpires() async throws {
        let (service, transport, connection, clock) = try await makeSetupWithClock()
        for _ in 0..<3 {
            await transport.enqueueResponse(makeSearchSystemError(sid: 9, scid: 1, query: "x"))
        }
        for _ in 0..<3 {
            await searchIgnoringError(service, sid: 9, scid: 1, query: "x")
        }
        #expect(await transport.sentData.count == 2)

        clock.advance(by: .seconds(4))
        await transport.enqueueResponse(makeSearchSystemError(sid: 9, scid: 1, query: "x"))
        await searchIgnoringError(service, sid: 9, scid: 1, query: "x")

        #expect(await transport.sentData.count == 3)
        await connection.disconnect()
    }

    @Test func aWokenServerIsSearchableAgainOnceTheWindowIsOver() async throws {
        let (service, transport, connection, clock) = try await makeSetupWithClock()
        for _ in 0..<2 {
            await transport.enqueueResponse(makeSearchSystemError(sid: 9, scid: 1, query: "x"))
        }
        for _ in 0..<2 {
            await searchIgnoringError(service, sid: 9, scid: 1, query: "x")
        }

        clock.advance(by: .seconds(4))
        await transport.enqueueResponse(makeResponse(
            command: "browse/search",
            message: "sid=9&search=x&scid=1&returned=1&count=1",
            payload: """
            [{"container":"no","name":"Woken Up","type":"song","mid":"m1","playable":"yes","image_url":""}]
            """
        ))

        let result = try await service.search(sid: 9, query: "x", criteriaID: 1)

        #expect(result.items.first?.name == "Woken Up")
        await connection.disconnect()
    }

    @Test func criteriaAreCountedSeparately() async throws {
        let (service, transport, connection, _) = try await makeSetupWithClock()
        for scid in [1, 2] {
            for _ in 0..<2 {
                await transport.enqueueResponse(makeSearchSystemError(sid: 7, scid: scid, query: "x"))
            }
        }

        for scid in [1, 2] {
            for _ in 0..<3 {
                await searchIgnoringError(service, sid: 7, scid: scid, query: "x")
            }
        }

        // Two per criteria, not two for the source.
        #expect(await transport.sentData.count == 4)
        await connection.disconnect()
    }

    @Test func anErrorThatIsNotASystemErrorNeverSkips() async throws {
        let (service, transport, connection, _) = try await makeSetupWithClock()
        for _ in 0..<4 {
            await transport.enqueueResponse("""
            {"heos":{"command":"browse/search","result":"fail","message":"eid=6&text=Invalid ID&sid=9&search=x&scid=1"}}
            """)
        }

        for _ in 0..<4 {
            await searchIgnoringError(service, sid: 9, scid: 1, query: "x")
        }

        #expect(await transport.sentData.count == 4)
        await connection.disconnect()
    }

    @Test func rereadingTheSourceListClearsEverySkip() async throws {
        let (service, transport, connection, _) = try await makeSetupWithClock()
        for _ in 0..<2 {
            await transport.enqueueResponse(makeSearchSystemError(sid: 9, scid: 1, query: "x"))
        }
        for _ in 0..<3 {
            await searchIgnoringError(service, sid: 9, scid: 1, query: "x")
        }
        #expect(await transport.sentData.count == 2)

        await transport.enqueueResponse(makeResponse(command: "browse/get_music_sources", payload: "[]"))
        _ = try await service.getMusicSources()
        await transport.enqueueResponse(makeSearchSystemError(sid: 9, scid: 1, query: "x"))
        await searchIgnoringError(service, sid: 9, scid: 1, query: "x")

        // get_music_sources plus one search that reached the wire again.
        #expect(await transport.sentData.count == 4)
        await connection.disconnect()
    }

    // MARK: - getMusicSources

    @Test func getMusicSourcesReturnsSources() async throws {
        let (service, transport, connection) = try await makeSetup()
        await transport.enqueueResponse(makeResponse(
            command: "browse/get_music_sources",
            payload: """
            [{"name":"TuneIn","image_url":"","type":"music_service","sid":3,"available":"true"},{"name":"Tidal","image_url":"","type":"music_service","sid":10,"available":"true"}]
            """
        ))

        let sources = try await service.getMusicSources()

        #expect(sources.count == 2)
        #expect(sources[0].name == "TuneIn")
        #expect(sources[0].sid == 3)
        #expect(sources[1].name == "Tidal")
        #expect(sources[1].sid == 10)
        await connection.disconnect()
    }

    // MARK: - browseSource

    @Test func browseSourceReturnsItems() async throws {
        let (service, transport, connection) = try await makeSetup()
        await transport.enqueueResponse(makeResponse(
            command: "browse/browse",
            message: "sid=3&returned=2&count=10",
            payload: """
            [{"container":"yes","name":"Favorites","type":"container","cid":"fav_cid","playable":"no","image_url":""},{"container":"yes","name":"Local Radio","type":"container","cid":"local_cid","playable":"no","image_url":""}]
            """
        ))

        let result = try await service.browseSource(sid: 3)

        #expect(result.items.count == 2)
        #expect(result.items[0].name == "Favorites")
        #expect(result.items[0].browsable == true)
        #expect(result.returned == 2)
        #expect(result.count == 10)
        await connection.disconnect()
    }

    // MARK: - browseContainer

    @Test func browseContainerReturnsItems() async throws {
        let (service, transport, connection) = try await makeSetup()
        await transport.enqueueResponse(makeResponse(
            command: "browse/browse",
            message: "sid=3&cid=fav_cid&returned=1&count=1",
            payload: """
            [{"name":"BBC Radio 1","type":"station","mid":"s/12345","playable":"yes","image_url":"https://img.com/bbc.jpg","cid":"fav_cid"}]
            """
        ))

        let result = try await service.browseContainer(sid: 3, cid: "fav_cid")

        #expect(result.items.count == 1)
        #expect(result.items[0].name == "BBC Radio 1")
        #expect(result.items[0].playable == true)
        await connection.disconnect()
    }

    // MARK: - search

    @Test func searchReturnsResults() async throws {
        let (service, transport, connection) = try await makeSetup()
        await transport.enqueueResponse(makeResponse(
            command: "browse/search",
            message: "sid=10&scid=1&returned=1&count=50",
            payload: """
            [{"name":"Music Track","type":"song","mid":"t123","playable":"yes","image_url":"","artist":"Artist","album":"Album"}]
            """
        ))

        let result = try await service.search(sid: 10, query: "music", criteriaID: 1)

        #expect(result.items.count == 1)
        #expect(result.items[0].name == "Music Track")
        await connection.disconnect()
    }

    // MARK: - getSearchCriteria

    @Test func getSearchCriteriaReturnsCriteria() async throws {
        let (service, transport, connection) = try await makeSetup()
        await transport.enqueueResponse(makeResponse(
            command: "browse/get_search_criteria",
            message: "sid=10",
            payload: """
            [{"name":"Artist","scid":1,"cid":null,"wildcard":"yes"},{"name":"Album","scid":2,"cid":null,"wildcard":"yes"},{"name":"Track","scid":3,"cid":null,"wildcard":"yes"}]
            """
        ))

        let criteria = try await service.getSearchCriteria(sid: 10)

        #expect(criteria.count == 3)
        #expect(criteria[0].name == "Artist")
        #expect(criteria[0].scid == 1)
        await connection.disconnect()
    }

    // MARK: - getHistory

    @Test func getHistoryBrowsesSID1026() async throws {
        let (service, transport, connection) = try await makeSetup()
        await transport.enqueueResponse(makeResponse(
            command: "browse/browse",
            message: "sid=1026&returned=1&count=1",
            payload: """
            [{"name":"TRACKS","type":"container","cid":"TRACKS","playable":"no","image_url":"","container":"yes"}]
            """
        ))

        let result = try await service.getHistory()

        #expect(result.items.count == 1)
        #expect(result.items[0].name == "TRACKS")

        let sent = await transport.lastSentString()
        #expect(sent?.contains("sid=1026") == true)
        await connection.disconnect()
    }

    // MARK: - getFavorites

    @Test func getFavoritesBrowsesSID1028() async throws {
        let (service, transport, connection) = try await makeSetup()
        await transport.enqueueResponse(makeResponse(
            command: "browse/browse",
            message: "sid=1028&returned=0&count=0",
            payload: "[]"
        ))

        let result = try await service.getFavorites()

        #expect(result.items.isEmpty)
        let sent = await transport.lastSentString()
        #expect(sent?.contains("sid=1028") == true)
        await connection.disconnect()
    }

    // MARK: - playStation

    @Test func playStationSendsCommand() async throws {
        let (service, transport, connection) = try await makeSetup()
        await transport.enqueueResponse(makeResponse(
            command: "browse/play_stream",
            message: "pid=42&sid=3&cid=fav_cid&mid=s/12345&name=BBC"
        ))

        try await service.playStation(pid: 42, sid: 3, cid: "fav_cid", mid: "s/12345", name: "BBC")

        let sent = await transport.lastSentString()
        #expect(sent?.contains("play_stream") == true)
        await connection.disconnect()
    }

    // MARK: - addToQueue

    @Test func addToQueueWithMIDSendsTrackCommand() async throws {
        let (service, transport, connection) = try await makeSetup()
        await transport.enqueueResponse(makeResponse(
            command: "browse/add_to_queue",
            message: "pid=42"
        ))

        try await service.addToQueue(pid: 42, sid: 10, cid: "c1", mid: "m1", criteria: .playNow)

        let sent = await transport.lastSentString()
        #expect(sent?.contains("add_to_queue") == true)
        #expect(sent?.contains("mid=m1") == true)
        await connection.disconnect()
    }

    @Test func addToQueueWithoutMIDSendsContainerCommand() async throws {
        let (service, transport, connection) = try await makeSetup()
        await transport.enqueueResponse(makeResponse(
            command: "browse/add_to_queue",
            message: "pid=42"
        ))

        try await service.addToQueue(pid: 42, sid: 10, cid: "c1", criteria: .playNow)

        let sent = await transport.lastSentString()
        #expect(sent?.contains("add_to_queue") == true)
        await connection.disconnect()
    }

    // MARK: - Local servers

    private static let serverSID = -1744769114

    /// Each test gets its own server path: the suite runs in parallel and the URL mock is shared.
    private func makeLocalServerSetup(path: String, locates: CallCounter) async throws -> (BrowseService, MockTCPTransport, HEOSConnection) {
        let transport = MockTCPTransport(autoRespond: true)
        let connection = HEOSConnection(transport: transport)
        try await connection.connect(host: "test", port: 1255)
        try await Task.sleep(for: .milliseconds(50))
        let endpoint = MediaServerEndpoint(
            friendlyName: "Kantele NAS",
            serviceType: "urn:schemas-upnp-org:service:ContentDirectory:1",
            controlURL: URL(string: "http://127.0.0.1:8200\(path)")!
        )
        let directory = LocalServerDirectory(
            locate: {
                locates.increment()
                return [endpoint]
            },
            makeClient: { UPnPContentDirectoryClient(endpoint: $0, session: URLSession(configuration: MockURLProtocol.makeConfiguration())) },
            now: { ContinuousClock.now }
        )
        let service = BrowseService(connection: connection, now: { ContinuousClock.now }, localServers: directory)
        return (service, transport, connection)
    }

    private func enqueueLocalMusic(_ transport: MockTCPTransport) async {
        await transport.enqueueResponse(makeResponse(
            command: "browse/browse",
            message: "sid=1024&returned=1&count=1",
            payload: """
            [{"name":"Kantele NAS","image_url":"https://cdn/servers.png","type":"heos_server","sid":\(Self.serverSID)}]
            """
        ))
    }

    @Test func localServerContainersGetTheArtTheDeviceDropped() async throws {
        let locates = CallCounter()
        let path = "/browsesvc/artwork/control"
        let (service, transport, connection) = try await makeLocalServerSetup(path: path, locates: locates)
        MockURLProtocol.register(pathContaining: path) { _ in
            (200, """
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:BrowseResponse>
            <Result>&lt;DIDL-Lite&gt;&lt;container id=&quot;al-1&quot;&gt;&lt;upnp:albumArtURI&gt;http://nas:8200/art/al-1&lt;/upnp:albumArtURI&gt;&lt;/container&gt;&lt;/DIDL-Lite&gt;</Result>
            </u:BrowseResponse></s:Body></s:Envelope>
            """)
        }
        await enqueueLocalMusic(transport)
        _ = try await service.browseSource(sid: 1024)
        await transport.enqueueResponse(makeResponse(
            command: "browse/browse",
            message: "sid=\(Self.serverSID)&cid=albums&range=0,0&returned=1&count=11944",
            payload: """
            [{"container":"yes","type":"album","cid":"al-1","playable":"yes","name":"Blue Hour","image_url":"","artist":"Someone"}]
            """
        ))

        let result = try await service.browseContainer(sid: Self.serverSID, cid: "albums", range: 0...0)

        #expect(result.items.first?.imageURL == "http://nas:8200/art/al-1")
        #expect(result.count == 11944)
        #expect(locates.count == 1)
        await connection.disconnect()
    }

    @Test func otherSourcesNeverLookForAServer() async throws {
        let locates = CallCounter()
        let (service, transport, connection) = try await makeLocalServerSetup(path: "/browsesvc/other/control", locates: locates)
        await transport.enqueueResponse(makeResponse(
            command: "browse/browse",
            message: "sid=3&cid=c1&returned=1&count=1",
            payload: """
            [{"container":"yes","type":"container","cid":"c2","name":"Folder","image_url":""}]
            """
        ))

        let result = try await service.browseContainer(sid: 3, cid: "c1")

        #expect(result.items.first?.imageURL == "")
        #expect(locates.count == 0)
        await connection.disconnect()
    }

    private func registerSearchCaps(_ caps: String, path: String) {
        MockURLProtocol.register(pathContaining: path) { _ in
            (200, "<s:Envelope><s:Body><u:GetSearchCapabilitiesResponse><SearchCaps>\(caps)</SearchCaps></u:GetSearchCapabilitiesResponse></s:Body></s:Envelope>")
        }
    }

    @Test func serverThatCannotSearchHasNoCriteria() async throws {
        let path = "/browsesvc/nosearch/control"
        let (service, transport, connection) = try await makeLocalServerSetup(path: path, locates: CallCounter())
        registerSearchCaps("", path: path)
        await enqueueLocalMusic(transport)
        _ = try await service.browseSource(sid: 1024)

        let criteria = try await service.getSearchCriteria(sid: Self.serverSID)

        #expect(criteria.isEmpty)
        let sent = await transport.lastSentString()
        #expect(sent?.contains("get_search_criteria") == false)
        await connection.disconnect()
    }

    @Test func serverThatCanSearchKeepsTheDeviceCriteria() async throws {
        let path = "/browsesvc/search/control"
        let (service, transport, connection) = try await makeLocalServerSetup(path: path, locates: CallCounter())
        registerSearchCaps("dc:title,upnp:artist", path: path)
        await enqueueLocalMusic(transport)
        _ = try await service.browseSource(sid: 1024)
        await transport.enqueueResponse(makeResponse(
            command: "browse/get_search_criteria",
            message: "sid=\(Self.serverSID)",
            payload: """
            [{"name":"Artist","scid":1,"wildcard":"no"},{"name":"Album","scid":2,"wildcard":"no"}]
            """
        ))

        let criteria = try await service.getSearchCriteria(sid: Self.serverSID)

        #expect(criteria.map(\.name) == ["Artist", "Album"])
        await connection.disconnect()
    }
}
