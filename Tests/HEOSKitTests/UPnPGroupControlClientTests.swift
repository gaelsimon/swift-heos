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

    // MARK: - membership from the evented state

    private static let zeros = String(repeating: "0", count: 32)

    /// The lead of a Denon Home 150 pair as its firmware events it; the per-field actions answer nothing.
    private static let leadEvent = """
    <Event xmlns="urn:schemas-upnp-org:metadata-1-0/GCS/"><DeviceFriendlyName val="Kitchen Left"/>\
    <GroupFriendlyName val="Kitchen &amp; Den"/><GroupStatus val="GROUP_LEAD"/><AudioChannel val="LEFT"/>\
    <GroupUUID val="b821616bff721b73008000a96f02fd5a"/><GroupMemberList val="&lt;GroupMemberList&gt;&lt;/GroupMemberList&gt;"/></Event>
    """

    private static let followerEvent = """
    <Event xmlns="urn:schemas-upnp-org:metadata-1-0/GCS/"><GroupStatus val="GROUP_SLAVE"/>\
    <AudioChannel val="RIGHT"/><GroupUUID val="b821616bff721b73008000a96f02fd5a"/></Event>
    """

    private static let noGroupEvent = """
    <Event xmlns="urn:schemas-upnp-org:metadata-1-0/GCS/"><GroupStatus val="NO_GROUP"/><GroupUUID val="\(zeros)"/></Event>
    """

    /// Serves GetCurrentState with `event` (nil: a fault) and the actions as a device that answers them empty.
    private func registerState(_ event: String?, uuid: String = "b821616bff721b73008000a96f02fd5a") -> Counter {
        let counter = Counter()
        MockURLProtocol.register(pathContaining: Self.path) { request in
            let action = request.value(forHTTPHeaderField: "SOAPACTION") ?? ""
            if action.contains("GetCurrentState") {
                guard let event else { return (500, "") }
                let body = "<CurrentState>\(SOAPEnvelope.xmlEscape(event))</CurrentState>"
                return (200, self.response(action: "GetCurrentState", body: body))
            }
            counter.increment()
            if action.contains("GetGroupUUID") {
                return (200, self.response(action: "GetGroupUUID", body: "<GroupUUID>\(uuid)</GroupUUID>"))
            }
            for tag in ["GroupStatus", "AudioChannel", "GroupFriendlyName"] where action.contains("GetGroup") {
                if action.contains(tag) || (tag == "AudioChannel" && action.contains("MemberChannel")) {
                    return (200, self.response(action: "Get\(tag)", body: "<\(tag)></\(tag)>"))
                }
            }
            return (404, "")
        }
        return counter
    }

    @Test func membershipComesFromTheEventedStateWhenTheActionsAnswerNothing() async throws {
        let actions = registerState(Self.leadEvent)
        let client = try makeClient()
        let membership = try await client.membership()
        #expect(membership == PairMembership(groupUUID: "b821616bff721b73008000a96f02fd5a", role: .leader, channel: "LEFT", name: "Kitchen & Den"))
        #expect(membership?.roomName == "Kitchen & Den")
        #expect(actions.value == 0)
        await client.invalidateSession()
    }

    @Test func aFollowerEventNamesNoRoom() async throws {
        _ = registerState(Self.followerEvent)
        let client = try makeClient()
        let membership = try await client.membership()
        #expect(membership?.role == .follower)
        #expect(membership?.channel == "RIGHT")
        #expect(membership?.roomName == nil)
        await client.invalidateSession()
    }

    @Test func aZeroGroupUUIDInTheEventMeansNoGroupWithoutAskingTheActions() async throws {
        let actions = registerState(Self.noGroupEvent)
        let client = try makeClient()
        let membership = try await client.membership()
        #expect(membership == nil)
        #expect(actions.value == 0)
        await client.invalidateSession()
    }

    @Test func aZeroGroupUUIDFromTheActionMeansNoGroup() async throws {
        _ = registerState(nil, uuid: Self.zeros)
        let client = try makeClient()
        let membership = try await client.membership()
        #expect(membership == nil)
        await client.invalidateSession()
    }

    @Test func theActionsAnswerWhenTheEventLacksAChannel() async throws {
        let event = "<Event><GroupStatus val=\"GROUP_LEAD\"/><GroupUUID val=\"uuid-123\"/></Event>"
        MockURLProtocol.register(pathContaining: Self.path) { request in
            let action = request.value(forHTTPHeaderField: "SOAPACTION") ?? ""
            if action.contains("GetCurrentState") {
                return (200, self.response(action: "GetCurrentState", body: "<CurrentState>\(SOAPEnvelope.xmlEscape(event))</CurrentState>"))
            }
            if action.contains("GetGroupStatus") {
                return (200, self.response(action: "GetGroupStatus", body: "<GroupStatus>LEADER</GroupStatus>"))
            }
            if action.contains("GetGroupMemberChannel") {
                return (200, self.response(action: "GetGroupMemberChannel", body: "<AudioChannel>NORMAL</AudioChannel>"))
            }
            if action.contains("GetGroupFriendlyName") { return (500, "") }
            return (200, self.response(action: "GetGroupUUID", body: "<GroupUUID>uuid-123</GroupUUID>"))
        }
        let client = try makeClient()
        let membership = try await client.membership()
        #expect(membership == PairMembership(groupUUID: "uuid-123", role: .leader, channel: "NORMAL", name: ""))
        await client.invalidateSession()
    }

    @Test func eventValuesUnescapeAndDropEmptyValues() {
        let values = UPnPGroupControlClient.eventValues(in: Self.leadEvent + "<GroupVolume val=\"\"/>")
        #expect(values["GroupFriendlyName"] == "Kitchen & Den")
        #expect(values["GroupMemberList"] == "<GroupMemberList></GroupMemberList>")
        #expect(values["GroupVolume"] == nil)
        #expect(values["GroupStatus"] == "GROUP_LEAD")
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    @Test func productionInitBuildsAndInvalidates() async throws {
        let client = try UPnPGroupControlClient(host: "127.0.0.1")
        await client.invalidateSession()
    }
}
