import Foundation

/// Reads from a local server what the device drops when it relays it.
actor UPnPContentDirectoryClient {
    private let endpoint: MediaServerEndpoint
    private let session: URLSession

    init(endpoint: MediaServerEndpoint, session: URLSession = HEOSURLSession.localServer) {
        self.endpoint = endpoint
        self.session = session
    }

    /// Empty when the server cannot search: the device then fails every query with `eid=12`.
    func searchCapabilities() async throws -> [String] {
        let xml = try await send("GetSearchCapabilities")
        let caps = SOAPEnvelope.unescapeXMLEntities(SOAPEnvelope.extractTag("SearchCaps", from: xml) ?? "")
        return caps.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Album art of the children of `objectID`, keyed by their id, which is the HEOS cid.
    func childArtwork(of objectID: String, start: Int, count: Int) async throws -> [String: String] {
        let xml = try await send("Browse", arguments: [
            ("ObjectID", objectID),
            ("BrowseFlag", "BrowseDirectChildren"),
            ("Filter", "upnp:albumArtURI"),
            ("StartingIndex", String(start)),
            ("RequestedCount", String(count)),
            ("SortCriteria", ""),
        ])
        guard let result = SOAPEnvelope.extractTag("Result", from: xml) else { return [:] }
        return DIDLArtworkIndex.parse(SOAPEnvelope.unescapeXMLEntities(result))
    }

    private func send(_ action: String, arguments: [(String, String)] = []) async throws -> String {
        try await SOAPEnvelope.send(
            action: action, arguments: arguments,
            controlURL: endpoint.controlURL,
            serviceType: endpoint.serviceType, session: session
        )
    }
}
