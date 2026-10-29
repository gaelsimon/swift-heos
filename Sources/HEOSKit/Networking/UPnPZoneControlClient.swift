import Foundation
import NeosDomain

/// Reads and sets the name a device holds for its multi-room zone, via Denon's ZoneControl UPnP
/// service: the HEOS app's group presets set it, the CLI never shows it. Endpoint on port 60006.
public actor UPnPZoneControlClient {
    private let session: URLSession
    private let baseURL: URL
    private static let controlPath = "/upnp/control/AiosServicesDvc/ZoneControl"
    private static let serviceType = "urn:schemas-denon-com:service:ZoneControl:2"
    private static let noZone = String(repeating: "0", count: 32)

    public init(host: String, port: Int = 60006) throws {
        guard let url = URL(string: "http://\(host):\(port)") else { throw UPnPError.invalidResponse }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        self.session = URLSession(configuration: config)
        self.baseURL = url
    }

    init(host: String, port: Int = 60006, sessionConfiguration: URLSessionConfiguration) throws {
        guard let url = URL(string: "http://\(host):\(port)") else { throw UPnPError.invalidResponse }
        self.session = URLSession(configuration: sessionConfiguration)
        self.baseURL = url
    }

    public func invalidateSession() {
        session.invalidateAndCancel()
    }

    /// The zone's name; nil when the device is in no zone, empty when the zone has none.
    public func zoneName() async throws -> String? {
        guard let uuid = try await zoneUUID() else { return nil }
        let xml = try await send("GetZoneFriendlyName", arguments: [("ZoneUUID", uuid)])
        guard let name = SOAPEnvelope.extractTag("ZoneFriendlyName", from: xml) else {
            throw UPnPError.invalidResponse
        }
        return SOAPEnvelope.unescapeXMLEntities(name)
    }

    /// Renames the zone this device is in; fails when it is in none.
    public func setZoneName(_ name: String) async throws {
        guard let uuid = try await zoneUUID() else { throw UPnPError.invalidResponse }
        _ = try await send("SetZoneFriendlyName", arguments: [("ZoneUUID", uuid), ("ZoneFriendlyName", name)])
    }

    private func zoneUUID() async throws -> String? {
        let xml = try await send("GetZoneUUID")
        guard let uuid = SOAPEnvelope.extractTag("ZoneUUID", from: xml) else { throw UPnPError.invalidResponse }
        return uuid.isEmpty || uuid == Self.noZone ? nil : uuid
    }

    private func send(_ action: String, arguments: [(String, String)] = []) async throws -> String {
        try await SOAPEnvelope.send(
            action: action, arguments: arguments,
            controlURL: baseURL.appendingPathComponent(Self.controlPath),
            serviceType: Self.serviceType, session: session
        )
    }
}
