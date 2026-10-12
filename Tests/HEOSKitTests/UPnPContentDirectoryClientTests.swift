import Foundation
import Testing
@testable import HEOSKit

@Suite("UPnPContentDirectoryClient", .serialized)
struct UPnPContentDirectoryClientTests {

    private static let path = "/cdclient/control"
    private static let serviceType = "urn:schemas-upnp-org:service:ContentDirectory:1"

    private func makeClient() -> UPnPContentDirectoryClient {
        let endpoint = MediaServerEndpoint(
            friendlyName: "Kantele NAS",
            serviceType: Self.serviceType,
            controlURL: URL(string: "http://127.0.0.1:8200\(Self.path)")!
        )
        return UPnPContentDirectoryClient(endpoint: endpoint, session: URLSession(configuration: MockURLProtocol.makeConfiguration()))
    }

    private func response(action: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
        <s:Body>
        <u:\(action)Response xmlns:u="\(Self.serviceType)">
        \(body)
        </u:\(action)Response>
        </s:Body>
        </s:Envelope>
        """
    }

    private static let fault = """
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
    <s:Body><s:Fault><detail><UPnPError>
    <errorCode>701</errorCode><errorDescription>No such object</errorDescription>
    </UPnPError></detail></s:Fault></s:Body></s:Envelope>
    """

    /// A Browse result as a server sends it: DIDL-Lite entity-escaped inside the SOAP body.
    private static let escapedResult = """
    &lt;DIDL-Lite xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&quot; \
    xmlns:upnp=&quot;urn:schemas-upnp-org:metadata-1-0/upnp/&quot;&gt;\
    &lt;container id=&quot;al-1&quot;&gt;&lt;upnp:albumArtURI&gt;http://nas/al-1.jpg&lt;/upnp:albumArtURI&gt;&lt;/container&gt;\
    &lt;container id=&quot;al-2&quot;&gt;&lt;upnp:albumArtURI&gt;http://nas/al-2.jpg&lt;/upnp:albumArtURI&gt;&lt;/container&gt;\
    &lt;/DIDL-Lite&gt;
    """

    @Test func parsesSearchCapabilities() async throws {
        MockURLProtocol.register(pathContaining: Self.path) { _ in
            (200, self.response(action: "GetSearchCapabilities",
                                body: "<SearchCaps>upnp:class, dc:title,upnp:artist[@role=&quot;AlbumArtist&quot;]</SearchCaps>"))
        }
        let capabilities = try await makeClient().searchCapabilities()
        #expect(capabilities == ["upnp:class", "dc:title", "upnp:artist[@role=\"AlbumArtist\"]"])
    }

    @Test func emptySearchCapabilitiesMeansNoSearch() async throws {
        MockURLProtocol.register(pathContaining: Self.path) { _ in
            (200, self.response(action: "GetSearchCapabilities", body: "<SearchCaps></SearchCaps>"))
        }
        let capabilities = try await makeClient().searchCapabilities()
        #expect(capabilities.isEmpty)
    }

    @Test func browsesChildrenWithTheRangeAsked() async throws {
        let bodies = Bodies()
        MockURLProtocol.register(pathContaining: Self.path) { request in
            bodies.record(request)
            return (200, self.response(action: "Browse", body: "<Result>\(Self.escapedResult)</Result><NumberReturned>2</NumberReturned>"))
        }
        let artwork = try await makeClient().childArtwork(of: "0$albums", start: 10, count: 2)
        #expect(artwork == ["al-1": "http://nas/al-1.jpg", "al-2": "http://nas/al-2.jpg"])
        let sent = bodies.last
        #expect(sent.body.contains("<ObjectID>0$albums</ObjectID>"))
        #expect(sent.body.contains("<BrowseFlag>BrowseDirectChildren</BrowseFlag>"))
        #expect(sent.body.contains("<StartingIndex>10</StartingIndex>"))
        #expect(sent.body.contains("<RequestedCount>2</RequestedCount>"))
        #expect(sent.body.contains("<Filter>upnp:albumArtURI</Filter>"))
        #expect(!sent.body.contains("InstanceID"))
        #expect(sent.action == "\"\(Self.serviceType)#Browse\"")
    }

    @Test func browseWithoutResultHasNoArt() async throws {
        MockURLProtocol.register(pathContaining: Self.path) { _ in
            (200, self.response(action: "Browse", body: "<NumberReturned>0</NumberReturned>"))
        }
        let artwork = try await makeClient().childArtwork(of: "albums", start: 0, count: 5)
        #expect(artwork.isEmpty)
    }

    @Test func throwsOnSoapFault() async {
        MockURLProtocol.register(pathContaining: Self.path) { _ in (500, Self.fault) }
        await #expect(throws: (any Error).self) {
            try await makeClient().childArtwork(of: "missing", start: 0, count: 1)
        }
    }

    @Test func throwsOnHTTPError() async {
        MockURLProtocol.register(pathContaining: Self.path) { _ in (404, "") }
        await #expect(throws: (any Error).self) {
            try await makeClient().searchCapabilities()
        }
    }

    /// What the handler saw of each request, since the handler runs off the test's thread.
    private final class Bodies: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(action: String, body: String)] = []

        func record(_ request: URLRequest) {
            lock.lock()
            defer { lock.unlock() }
            recorded.append((request.value(forHTTPHeaderField: "SOAPACTION") ?? "", request.bodyString))
        }

        var last: (action: String, body: String) {
            lock.lock()
            defer { lock.unlock() }
            return recorded.last ?? ("", "")
        }
    }
}
