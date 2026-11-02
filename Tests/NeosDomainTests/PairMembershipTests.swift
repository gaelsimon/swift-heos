import Testing
@testable import NeosDomain

@Suite("PairMembership")
struct PairMembershipTests {

    @Test(arguments: [
        ("LEADER", PairMembership.Role.leader), ("GROUP_LEAD", .leader),
        ("SLAVE", .follower), ("group_slave", .follower),
        ("NONE", .none), ("NO_GROUP", .none), ("", .none)
    ])
    func roleReadsTheActionAndTheEventedStatusNames(status: String, role: PairMembership.Role) {
        #expect(PairMembership.Role(groupStatus: status) == role)
    }

    @Test func aFollowerWithoutANameHasNoRoomName() {
        let seat = PairMembership(groupUUID: "g", role: .follower, channel: "RIGHT", name: "")
        #expect(seat.isChannelSeat)
        #expect(seat.roomName == nil)
    }
}
