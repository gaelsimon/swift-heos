import Foundation
import Testing
@testable import HEOSKit

@Suite("LocalServerDirectory", .serialized)
struct LocalServerDirectoryTests {

    private static let path = "/localdir/control"
    private static let serviceType = "urn:schemas-upnp-org:service:ContentDirectory:1"
    private static let kanteleSID = -1744769114
    private static let minimSID = -956885524

    private static func endpoint(_ name: String, host: String = "127.0.0.1") -> MediaServerEndpoint {
        MediaServerEndpoint(friendlyName: name, serviceType: serviceType, controlURL: URL(string: "http://\(host):8200\(path)")!)
    }

    private static func server(_ name: String, sid: Int) -> BrowseItem {
        BrowseItem(name: name, type: .heosServer, sid: sid, browsable: true)
    }

    private struct Harness {
        let directory: LocalServerDirectory
        let clock: ManualClock
        let locates: CallCounter
        let clients: CallCounter
    }

    private func makeHarness(
        endpoints: [MediaServerEndpoint] = [endpoint("Kantele NAS"), endpoint("Minim Nasperes")],
        locateDelay: Duration = .zero
    ) -> Harness {
        let clock = ManualClock()
        let locates = CallCounter()
        let clients = CallCounter()
        let directory = LocalServerDirectory(
            locate: {
                locates.increment()
                try? await Task.sleep(for: locateDelay)
                return endpoints
            },
            makeClient: { endpoint in
                clients.increment()
                return UPnPContentDirectoryClient(endpoint: endpoint, session: URLSession(configuration: MockURLProtocol.makeConfiguration()))
            },
            now: { clock.instant }
        )
        return Harness(directory: directory, clock: clock, locates: locates, clients: clients)
    }

    private func soap(action: String, body: String) -> String {
        """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
        <u:\(action)Response xmlns:u="\(Self.serviceType)">\(body)</u:\(action)Response>
        </s:Body></s:Envelope>
        """
    }

    private func registerArtwork(_ artwork: [String: String], hits: CallCounter? = nil) {
        let didl = artwork.map { id, url in
            "&lt;container id=&quot;\(id)&quot;&gt;&lt;upnp:albumArtURI&gt;\(url)&lt;/upnp:albumArtURI&gt;&lt;/container&gt;"
        }.joined()
        MockURLProtocol.register(pathContaining: Self.path) { _ in
            hits?.increment()
            return (200, self.soap(action: "Browse", body: "<Result>&lt;DIDL-Lite&gt;\(didl)&lt;/DIDL-Lite&gt;</Result>"))
        }
    }

    // MARK: - Resolving

    @Test func unknownSidHasNoClient() async {
        let harness = makeHarness()
        let client = await harness.directory.client(for: 42)
        #expect(client == nil)
        #expect(harness.locates.count == 0)
    }

    @Test func matchesServerByNameAndKeepsIt() async {
        let harness = makeHarness()
        await harness.directory.noteServers(in: [Self.server("Kantele NAS", sid: Self.kanteleSID)])
        let first = await harness.directory.client(for: Self.kanteleSID)
        let second = await harness.directory.client(for: Self.kanteleSID)
        #expect(first != nil)
        #expect(first === second)
        #expect(harness.locates.count == 1)
        #expect(harness.clients.count == 1)
    }

    @Test func oneDiscoveryServesEveryServerListed() async {
        let harness = makeHarness()
        await harness.directory.noteServers(in: [
            Self.server("Kantele NAS", sid: Self.kanteleSID),
            Self.server("Minim Nasperes", sid: Self.minimSID),
        ])
        let kantele = await harness.directory.client(for: Self.kanteleSID)
        let minim = await harness.directory.client(for: Self.minimSID)
        #expect(kantele != nil)
        #expect(minim != nil)
        #expect(harness.locates.count == 1)
    }

    @Test func onlyLocalServersAreNoted() async {
        let harness = makeHarness()
        await harness.directory.noteServers(in: [
            BrowseItem(name: "Kantele NAS", type: .heosService, sid: Self.kanteleSID),
            BrowseItem(name: "Albums", type: .container, cid: "albums"),
        ])
        let local = await harness.directory.isLocalServer(sid: Self.kanteleSID)
        #expect(!local)
    }

    @Test func twoServersUnderOneNameMatchNothing() async {
        let harness = makeHarness(endpoints: [Self.endpoint("Twin"), Self.endpoint("Twin", host: "127.0.0.2")])
        await harness.directory.noteServers(in: [Self.server("Twin", sid: 7)])
        let client = await harness.directory.client(for: 7)
        #expect(client == nil)
    }

    @Test func missingServerIsAskedForAgainOnlyAfterTheCooldown() async {
        let harness = makeHarness(endpoints: [])
        await harness.directory.noteServers(in: [Self.server("Kantele NAS", sid: Self.kanteleSID)])
        _ = await harness.directory.client(for: Self.kanteleSID)
        _ = await harness.directory.client(for: Self.kanteleSID)
        #expect(harness.locates.count == 1)
        harness.clock.advance(by: LocalServerDirectory.locateCooldown)
        _ = await harness.directory.client(for: Self.kanteleSID)
        #expect(harness.locates.count == 2)
    }

    @Test func listingServersStartsLookingForThem() async throws {
        let harness = makeHarness()
        await harness.directory.noteServers(in: [Self.server("Kantele NAS", sid: Self.kanteleSID)])
        for _ in 0..<100 where harness.locates.count == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.locates.count == 1)
        _ = await harness.directory.client(for: Self.kanteleSID)
        #expect(harness.locates.count == 1)
    }

    @Test func listingOtherItemsLooksForNothing() async throws {
        let harness = makeHarness()
        await harness.directory.noteServers(in: [BrowseItem(name: "Albums", type: .container, cid: "albums")])
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.locates.count == 0)
    }

    @Test func aDiscoveryThatMissesAKnownServerKeepsIt() async {
        let answers = Answers([[Self.endpoint("Kantele NAS")], [Self.endpoint("Minim Nasperes")]])
        let clock = ManualClock()
        let directory = LocalServerDirectory(
            locate: { answers.next() },
            makeClient: { UPnPContentDirectoryClient(endpoint: $0, session: URLSession(configuration: MockURLProtocol.makeConfiguration())) },
            now: { clock.instant }
        )
        await directory.noteServers(in: [Self.server("Kantele NAS", sid: Self.kanteleSID)])
        _ = await directory.client(for: Self.kanteleSID)
        clock.advance(by: LocalServerDirectory.locateCooldown)
        await directory.noteServers(in: [Self.server("Minim Nasperes", sid: Self.minimSID)])
        let minim = await directory.client(for: Self.minimSID)
        await directory.noteServers(in: [Self.server("Kantele NAS", sid: 11)])
        let kantele = await directory.client(for: 11)
        #expect(minim != nil)
        #expect(kantele != nil)
    }

    /// Hands out one discovery answer per call, then empty lists.
    private final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: [[MediaServerEndpoint]]

        init(_ answers: [[MediaServerEndpoint]]) {
            remaining = answers
        }

        func next() -> [MediaServerEndpoint] {
            lock.lock()
            defer { lock.unlock() }
            return remaining.isEmpty ? [] : remaining.removeFirst()
        }
    }

    @Test func concurrentLookupsShareOneDiscovery() async {
        let harness = makeHarness(locateDelay: .milliseconds(100))
        await harness.directory.noteServers(in: [
            Self.server("Kantele NAS", sid: Self.kanteleSID),
            Self.server("Minim Nasperes", sid: Self.minimSID),
        ])
        async let kantele = harness.directory.client(for: Self.kanteleSID)
        async let minim = harness.directory.client(for: Self.minimSID)
        let (first, second) = await (kantele, minim)
        #expect(first != nil)
        #expect(second != nil)
        #expect(harness.locates.count == 1)
    }

    // MARK: - Artwork

    @Test func fillsOnlyTheArtTheDeviceDropped() async {
        registerArtwork(["al-1": "http://nas/al-1.jpg", "al-2": "http://nas/al-2.jpg"])
        let harness = makeHarness()
        await harness.directory.noteServers(in: [Self.server("Kantele NAS", sid: Self.kanteleSID)])
        let result = BrowseResult(items: [
            BrowseItem(name: "One", type: .album, cid: "al-1", browsable: true),
            BrowseItem(name: "Track", imageURL: "http://nas/track.jpg", type: .song, mid: "al-2"),
            BrowseItem(name: "Three", type: .album, cid: "al-3", browsable: true),
        ], returned: 3, count: 30)

        let filled = await harness.directory.fillingArtwork(result, sid: Self.kanteleSID, cid: "albums", start: 0)

        #expect(filled.items.map(\.imageURL) == ["http://nas/al-1.jpg", "http://nas/track.jpg", ""])
        #expect(filled.returned == 3)
        #expect(filled.count == 30)
    }

    @Test func doesNotAskWhenNothingIsMissing() async {
        let hits = CallCounter()
        registerArtwork(["al-1": "http://nas/al-1.jpg"], hits: hits)
        let harness = makeHarness()
        await harness.directory.noteServers(in: [Self.server("Kantele NAS", sid: Self.kanteleSID)])
        let result = BrowseResult(items: [BrowseItem(name: "One", imageURL: "http://heos/one.jpg", type: .album, cid: "al-1")])

        _ = await harness.directory.fillingArtwork(result, sid: Self.kanteleSID, cid: "albums", start: 0)

        #expect(hits.count == 0)
    }

    @Test func leavesOtherSourcesAlone() async {
        let hits = CallCounter()
        registerArtwork(["al-1": "http://nas/al-1.jpg"], hits: hits)
        let harness = makeHarness()
        let result = BrowseResult(items: [BrowseItem(name: "One", type: .album, cid: "al-1")])

        let filled = await harness.directory.fillingArtwork(result, sid: 3, cid: "al-1", start: 0)

        #expect(filled.items[0].imageURL.isEmpty)
        #expect(hits.count == 0)
    }

    private static let fault = """
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><detail><UPnPError>
    <errorCode>701</errorCode><errorDescription>No such object</errorDescription>
    </UPnPError></detail></s:Fault></s:Body></s:Envelope>
    """

    private static let oneAlbum = BrowseResult(items: [BrowseItem(name: "One", type: .album, cid: "al-1")])

    private func fill(_ harness: Harness, cid: String = "albums") async -> BrowseResult {
        await harness.directory.fillingArtwork(Self.oneAlbum, sid: Self.kanteleSID, cid: cid, start: 0)
    }

    private func notedHarness() async -> Harness {
        let harness = makeHarness()
        await harness.directory.noteServers(in: [Self.server("Kantele NAS", sid: Self.kanteleSID)])
        return harness
    }

    private func register(status: Int, body: String = "", hits: CallCounter) {
        MockURLProtocol.register(pathContaining: Self.path) { _ in
            hits.increment()
            return (status, body)
        }
    }

    @Test func aContainerWithoutArtIsNotAskedAgain() async {
        let hits = CallCounter()
        registerArtwork([:], hits: hits)
        let harness = await notedHarness()

        _ = await fill(harness)
        _ = await fill(harness)
        #expect(hits.count == 1)

        _ = await fill(harness, cid: "f-g")
        #expect(hits.count == 2)
    }

    @Test func artForOtherObjectsCountsAsNone() async {
        let hits = CallCounter()
        registerArtwork(["al-9": "http://nas/al-9.jpg"], hits: hits)
        let harness = await notedHarness()

        let filled = await fill(harness)
        _ = await fill(harness)

        #expect(filled.items[0].imageURL.isEmpty)
        #expect(hits.count == 1)
    }

    @Test func anUnreachableServerIsLookedForAgainAfterTheCooldown() async {
        let hits = CallCounter()
        register(status: URLError.cannotConnectToHost.rawValue, hits: hits)
        let harness = await notedHarness()

        let filled = await fill(harness)
        #expect(filled.items[0].imageURL.isEmpty)
        _ = await fill(harness)
        #expect(hits.count == 1)
        #expect(harness.locates.count == 1)

        harness.clock.advance(by: LocalServerDirectory.locateCooldown)
        _ = await fill(harness)
        #expect(harness.locates.count == 2)
        #expect(harness.clients.count == 2)
        #expect(hits.count == 2)
    }

    @Test func aSlowServerStaysButItsContainerIsNotWaitedOnAgain() async {
        let hits = CallCounter()
        register(status: URLError.timedOut.rawValue, hits: hits)
        let harness = await notedHarness()

        _ = await fill(harness)
        _ = await fill(harness)
        _ = await fill(harness, cid: "f-g")

        #expect(hits.count == 2)
        #expect(harness.clients.count == 1)
        #expect(harness.locates.count == 1)
    }

    @Test func aSoapFaultKeepsTheServer() async {
        let hits = CallCounter()
        register(status: 500, body: Self.fault, hits: hits)
        let harness = await notedHarness()

        _ = await fill(harness, cid: "gone")
        _ = await fill(harness, cid: "gone")

        #expect(hits.count == 1)
        #expect(harness.clients.count == 1)
        #expect(harness.locates.count == 1)
    }

    @Test func anHTTPErrorKeepsTheServer() async {
        let hits = CallCounter()
        register(status: 503, hits: hits)
        let harness = await notedHarness()

        _ = await fill(harness)
        _ = await fill(harness, cid: "f-g")

        #expect(hits.count == 2)
        #expect(harness.clients.count == 1)
    }

    @Test func aCancelledRequestConcludesNothing() async {
        let hits = CallCounter()
        register(status: URLError.cancelled.rawValue, hits: hits)
        let harness = await notedHarness()

        _ = await fill(harness)
        _ = await fill(harness)

        #expect(hits.count == 2)
        #expect(harness.clients.count == 1)
    }

    // MARK: - Search support

    @Test func emptyCapabilitiesMeanNoSearch() async {
        MockURLProtocol.register(pathContaining: Self.path) { _ in
            (200, self.soap(action: "GetSearchCapabilities", body: "<SearchCaps></SearchCaps>"))
        }
        let harness = makeHarness(endpoints: [Self.endpoint("NASPERES")])
        await harness.directory.noteServers(in: [Self.server("NASPERES", sid: 9)])
        let support = await harness.directory.searchSupport(sid: 9)
        #expect(support == .unsupported)
    }

    @Test func listedCapabilitiesMeanSearch() async {
        MockURLProtocol.register(pathContaining: Self.path) { _ in
            (200, self.soap(action: "GetSearchCapabilities", body: "<SearchCaps>dc:title,upnp:artist</SearchCaps>"))
        }
        let harness = makeHarness()
        await harness.directory.noteServers(in: [Self.server("Kantele NAS", sid: Self.kanteleSID)])
        let support = await harness.directory.searchSupport(sid: Self.kanteleSID)
        #expect(support == .supported)
    }

    @Test func unreachableServerLeavesSearchUnknown() async {
        register(status: URLError.cannotConnectToHost.rawValue, hits: CallCounter())
        let harness = await notedHarness()
        let support = await harness.directory.searchSupport(sid: Self.kanteleSID)
        #expect(support == .unknown)
        let unlisted = await harness.directory.searchSupport(sid: 3)
        #expect(unlisted == .unknown)
    }

    @Test func slowServerLeavesSearchUnknownAndStays() async {
        register(status: URLError.timedOut.rawValue, hits: CallCounter())
        let harness = await notedHarness()
        let support = await harness.directory.searchSupport(sid: Self.kanteleSID)
        _ = await harness.directory.searchSupport(sid: Self.kanteleSID)
        #expect(support == .unknown)
        #expect(harness.clients.count == 1)
    }
}
