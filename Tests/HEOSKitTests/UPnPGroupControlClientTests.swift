import Foundation
import Testing
@testable import HEOSKit
import NeosDomain

@Suite("UPnPGroupControlClient", .serialized)
struct UPnPGroupControlClientTests {

    private static let path = "/upnp/control/AiosServicesDvc/GroupControl"

    private func makeClient() throws -> UPnPGroupControlClient {
        try UPnPGroupControlClient(host: "127.0.0.1", port: 60006, sessionConfiguration: MockURLProtocol.makeConfiguration())
    }

    private func response(action: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
        <s:Body>
        <u:\(action)Response xmlns:u="urn:schemas-denon-com:service:GroupControl:1">
        \(body)
        </u:\(action)Response>
        </s:Body>
        </s:Envelope>
        """
    }

    /// Serves the two-step exchange: GetGroupUUID then GetGroupMemberChannel(channel).
    private func registerExchange(channel: String) {
        MockURLProtocol.register(pathContaining: Self.path) { request in
            let action = request.value(forHTTPHeaderField: "SOAPACTION") ?? ""
            if action.contains("GetGroupMemberChannel") {
                return (200, self.response(action: "GetGroupMemberChannel", body: "<AudioChannel>\(channel)</AudioChannel>"))
            }
            return (200, self.response(action: "GetGroupUUID", body: "<GroupUUID>uuid-123</GroupUUID>"))
        }
    }

    @Test func returnsNormalChannelForMultiRoomMember() async throws {
        registerExchange(channel: "NORMAL")
        let client = try makeClient()
        let channel = try await client.memberChannel()
        #expect(channel == "NORMAL")
        await client.invalidateSession()
    }

    @Test func returnsLeftChannelForStereoPairMember() async throws {
        registerExchange(channel: "LEFT")
        let client = try makeClient()
        let channel = try await client.memberChannel()
        #expect(channel == "LEFT")
        await client.invalidateSession()
    }

    @Test func throwsWhenGroupUUIDMissing() async throws {
        MockURLProtocol.register(pathContaining: Self.path) { _ in
            (200, self.response(action: "GetGroupUUID", body: "<GroupUUID></GroupUUID>"))
        }
        let client = try makeClient()
        await #expect(throws: (any Error).self) { try await client.memberChannel() }
        await client.invalidateSession()
    }

    @Test func throwsOnSoapFault() async throws {
        let fault = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
        <s:Body><s:Fault><detail><UPnPError>
        <errorCode>501</errorCode><errorDescription>Action Failed</errorDescription>
        </UPnPError></detail></s:Fault></s:Body></s:Envelope>
        """
        MockURLProtocol.register(pathContaining: Self.path) { _ in (500, fault) }
        let client = try makeClient()
        await #expect(throws: (any Error).self) { try await client.memberChannel() }
        await client.invalidateSession()
    }

    @Test func throwsOnHTTPError() async throws {
        MockURLProtocol.register(pathContaining: Self.path) { _ in (404, "") }
        let client = try makeClient()
        await #expect(throws: (any Error).self) { try await client.memberChannel() }
        await client.invalidateSession()
    }

    // MARK: - membership

    /// Serves the four-step exchange a pair member answers: UUID, status, channel, friendly name.
    private func registerPair(status: String, channel: String, name: String?) {
        MockURLProtocol.register(pathContaining: Self.path) { request in
            let action = request.value(forHTTPHeaderField: "SOAPACTION") ?? ""
            if action.contains("GetGroupStatus") {
                return (200, self.response(action: "GetGroupStatus", body: "<GroupStatus>\(status)</GroupStatus>"))
            }
            if action.contains("GetGroupMemberChannel") {
                return (200, self.response(action: "GetGroupMemberChannel", body: "<AudioChannel>\(channel)</AudioChannel>"))
            }
            if action.contains("GetGroupFriendlyName") {
                guard let name else { return (500, "") }
                return (200, self.response(action: "GetGroupFriendlyName", body: "<GroupFriendlyName>\(name)</GroupFriendlyName>"))
            }
            return (200, self.response(action: "GetGroupUUID", body: "<GroupUUID>uuid-123</GroupUUID>"))
        }
    }

    @Test func membershipReadsThePairLeaderWithItsRoomName() async throws {
        registerPair(status: "LEADER", channel: "LEFT", name: "Kitchen &amp; Den")
        let client = try makeClient()
        let membership = try await client.membership()
        #expect(membership == PairMembership(groupUUID: "uuid-123", role: .leader, channel: "LEFT", name: "Kitchen & Den"))
        #expect(membership?.roomName == "Kitchen & Den")
        await client.invalidateSession()
    }

    @Test func membershipReadsTheFollower() async throws {
        registerPair(status: "SLAVE", channel: "RIGHT", name: "Kitchen")
        let client = try makeClient()
        let membership = try await client.membership()
        #expect(membership?.role == .follower)
        #expect(membership?.isChannelSeat == true)
        await client.invalidateSession()
    }

    @Test func membershipIsNilOutsideAnyGroup() async throws {
        MockURLProtocol.register(pathContaining: Self.path) { _ in
            (200, self.response(action: "GetGroupUUID", body: "<GroupUUID></GroupUUID>"))
        }
        let client = try makeClient()
        let membership = try await client.membership()
        #expect(membership == nil)
        await client.invalidateSession()
    }

    @Test func membershipSurvivesARefusedFriendlyName() async throws {
        registerPair(status: "NONE", channel: "NORMAL", name: nil)
        let client = try makeClient()
        let membership = try await client.membership()
        #expect(membership?.channel == "NORMAL")
        #expect(membership?.name == "")
        #expect(membership?.roomName == nil)
        await client.invalidateSession()
    }

    @Test func productionInitBuildsAndInvalidates() async throws {
        let client = try UPnPGroupControlClient(host: "127.0.0.1")
        await client.invalidateSession()
    }
}
