import Foundation
import NeosDomain

/// Reads a device's audio channel (NORMAL vs LEFT/RIGHT/…) via Denon's GroupControl UPnP
/// service — how we tell a stereo pair from a multi-room group. Endpoint on port 60006.
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
        let uuidXML = try await send("GetGroupUUID")
        guard let uuid = SOAPEnvelope.extractTag("GroupUUID", from: uuidXML), !uuid.isEmpty else {
            throw UPnPError.invalidResponse
        }
        let channelXML = try await send("GetGroupMemberChannel", arguments: [("GroupUUID", uuid)])
        guard let channel = SOAPEnvelope.extractTag("AudioChannel", from: channelXML) else {
            throw UPnPError.invalidResponse
        }
        return channel
    }

    /// The device's seat in its stereo or surround group, with the room name; nil when it is in none.
    public func membership() async throws -> PairMembership? {
        let uuidXML = try await send("GetGroupUUID")
        guard let uuid = SOAPEnvelope.extractTag("GroupUUID", from: uuidXML), !uuid.isEmpty else { return nil }
        let arguments = [("GroupUUID", uuid)]
        let statusXML = try await send("GetGroupStatus", arguments: arguments)
        let channelXML = try await send("GetGroupMemberChannel", arguments: arguments)
        guard let status = SOAPEnvelope.extractTag("GroupStatus", from: statusXML),
              let channel = SOAPEnvelope.extractTag("AudioChannel", from: channelXML) else {
            throw UPnPError.invalidResponse
        }
        // The name is a nicety: a device that refuses it still classifies.
        let nameXML = (try? await send("GetGroupFriendlyName", arguments: arguments)) ?? ""
        let name = SOAPEnvelope.extractTag("GroupFriendlyName", from: nameXML).map(Self.unescaped) ?? ""
        return PairMembership(groupUUID: uuid, role: .init(groupStatus: status), channel: channel, name: name)
    }

    private static func unescaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private func send(_ action: String, arguments: [(String, String)] = []) async throws -> String {
        try await SOAPEnvelope.send(
            action: action, arguments: arguments,
            controlURL: baseURL.appendingPathComponent(Self.controlPath),
            serviceType: Self.serviceType, session: session
        )
    }
}
