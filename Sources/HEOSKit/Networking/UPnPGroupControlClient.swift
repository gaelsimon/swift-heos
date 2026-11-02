import Foundation
import NeosDomain

/// Reads a device's seat in its stereo or surround group via Denon's GroupControl UPnP service,
/// how a pair is told from a multi-room group. Endpoint on port 60006.
public actor UPnPGroupControlClient {
    private let session: URLSession
    private let baseURL: URL
    private static let controlPath = "/upnp/control/AiosServicesDvc/GroupControl"
    private static let serviceType = "urn:schemas-denon-com:service:GroupControl:1"

    public init(host: String, port: Int = 60006) throws {
        guard let url = URL(string: "http://\(host):\(port)") else { throw UPnPError.invalidResponse }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        self.session = URLSession(configuration: config)
        self.baseURL = url
    }

    /// Test-only init accepting a custom session configuration (e.g. for URLProtocol mocking).
    init(host: String, port: Int = 60006, sessionConfiguration: URLSessionConfiguration) throws {
        guard let url = URL(string: "http://\(host):\(port)") else { throw UPnPError.invalidResponse }
        self.session = URLSession(configuration: sessionConfiguration)
        self.baseURL = url
    }

    public func invalidateSession() {
        session.invalidateAndCancel()
    }

    /// This device's audio channel within its current group (e.g. NORMAL, LEFT, RIGHT).
    public func memberChannel() async throws -> String {
        guard let uuid = try await groupUUID() else { throw UPnPError.invalidResponse }
        let channelXML = try await send("GetGroupMemberChannel", arguments: [("GroupUUID", uuid)])
        guard let channel = SOAPEnvelope.extractTag("AudioChannel", from: channelXML) else {
            throw UPnPError.invalidResponse
        }
        return channel
    }

    /// The device's seat in its stereo or surround group, with the room name; nil when it is in none.
    /// The evented state is read first: some firmware answers the per-field actions with nothing.
    public func membership() async throws -> PairMembership? {
        let state = await eventedState()
        if let uuid = state["GroupUUID"] {
            if Self.isNoGroup(uuid) { return nil }
            if let status = state["GroupStatus"], let channel = state["AudioChannel"] {
                return PairMembership(groupUUID: uuid, role: .init(groupStatus: status),
                                      channel: channel, name: state["GroupFriendlyName"] ?? "")
            }
        }
        return try await membershipFromActions()
    }

    private func membershipFromActions() async throws -> PairMembership? {
        guard let uuid = try await groupUUID() else { return nil }
        let arguments = [("GroupUUID", uuid)]
        let statusXML = try await send("GetGroupStatus", arguments: arguments)
        let channelXML = try await send("GetGroupMemberChannel", arguments: arguments)
        guard let status = SOAPEnvelope.extractTag("GroupStatus", from: statusXML),
              let channel = SOAPEnvelope.extractTag("AudioChannel", from: channelXML) else {
            throw UPnPError.invalidResponse
        }
        // The name is a nicety: a device that refuses it still classifies.
        let nameXML = (try? await send("GetGroupFriendlyName", arguments: arguments)) ?? ""
        let name = SOAPEnvelope.extractTag("GroupFriendlyName", from: nameXML)
            .map(SOAPEnvelope.unescapeXMLEntities) ?? ""
        return PairMembership(groupUUID: uuid, role: .init(groupStatus: status), channel: channel, name: name)
    }

    /// The GroupControl variables the device last evented; empty when it answers none.
    private func eventedState() async -> [String: String] {
        guard let xml = try? await send("GetCurrentState"),
              let event = SOAPEnvelope.extractTag("CurrentState", from: xml) else { return [:] }
        return Self.eventValues(in: SOAPEnvelope.unescapeXMLEntities(event))
    }

    /// The `<Name val="…"/>` pairs of a LastChange event, values unescaped; empty values are dropped.
    static func eventValues(in event: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"<(\w+) val="([^"]*)"/>"#) else { return [:] }
        var values: [String: String] = [:]
        for match in regex.matches(in: event, range: NSRange(event.startIndex..., in: event)) {
            guard let nameRange = Range(match.range(at: 1), in: event),
                  let valueRange = Range(match.range(at: 2), in: event) else { continue }
            let value = SOAPEnvelope.unescapeXMLEntities(String(event[valueRange]))
            if !value.isEmpty { values[String(event[nameRange])] = value }
        }
        return values
    }

    private func groupUUID() async throws -> String? {
        let xml = try await send("GetGroupUUID")
        guard let uuid = SOAPEnvelope.extractTag("GroupUUID", from: xml), !Self.isNoGroup(uuid) else { return nil }
        return uuid
    }

    // An ungrouped device answers a UUID of zeros, with or without dashes.
    private static func isNoGroup(_ uuid: String) -> Bool {
        uuid.allSatisfy { $0 == "0" || $0 == "-" }
    }

    private func send(_ action: String, arguments: [(String, String)] = []) async throws -> String {
        try await SOAPEnvelope.send(
            action: action, arguments: arguments,
            controlURL: baseURL.appendingPathComponent(Self.controlPath),
            serviceType: Self.serviceType, session: session
        )
    }
}
