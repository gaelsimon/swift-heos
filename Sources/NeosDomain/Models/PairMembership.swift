import Foundation

/// What a device says over UPnP GroupControl about the stereo or surround group it sits in.
public struct PairMembership: Sendable, Equatable, Hashable, Codable {
    public enum Role: String, Sendable, Codable {
        case leader, follower, none

        public init(groupStatus: String) {
            switch groupStatus.uppercased() {
            case "LEADER": self = .leader
            case "SLAVE": self = .follower
            default: self = .none
            }
        }
    }

    public let groupUUID: String
    public let role: Role
    public let channel: String
    public let name: String

    public init(groupUUID: String, role: Role, channel: String, name: String) {
        self.groupUUID = groupUUID
        self.role = role
        self.channel = channel
        self.name = name
    }

    /// LEFT, RIGHT or a surround seat; NORMAL is a plain multi-room member.
    public var isChannelSeat: Bool {
        !channel.isEmpty && channel != normalAudioChannel
    }

    /// The room name a pair shows under, when the device knows one.
    public var roomName: String? {
        guard isChannelSeat else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
