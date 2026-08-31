import Foundation

@MainActor
public protocol StateUpdater: AnyObject, Sendable {
    var selectedPlayerID: Int? { get }
    var isPoweredOn: Bool { get }
    func setConnectionState(_ state: ConnectionState)
    func setPlayers(_ players: [Player])
    func setGroups(_ groups: [SpeakerGroup])
    func setMusicSources(_ sources: [MusicSource])
    func setSelectedPlayerID(_ pid: Int)
    func setPlayState(_ state: PlayState)
    func setNowPlaying(_ media: NowPlayingMedia)
    func setVolume(_ level: Int)
    func setMuted(_ muted: Bool)
    func setRepeatMode(_ mode: RepeatMode)
    func setShuffleMode(_ mode: ShuffleMode)
    func setProgress(position: Int, duration: Int)
    func setQueue(_ items: [QueueItem])
    func setSignedInUser(_ username: String?)
    func setError(_ error: AppError?)
    func setGroupVolume(gid: Int, level: Int)
    func setGroupMuted(gid: Int, muted: Bool)
    func setPlayerVolume(pid: Int, level: Int)
    func addDiscoveredDevice(_ device: DiscoveredDevice)
    func setPowerState(_ isPoweredOn: Bool)
    func setMaxVolume(_ level: Int?)
    func setTrackMetadata(_ metadata: TrackMetadata?)
    func reportNonFatal(source: String, message: String)
    func applyPlayerSnapshot(_ snapshot: PlayerSnapshot)
    func setServiceCapabilities(sid: Int, capabilities: ServiceCapabilities)
    func setNowPlayingOptions(_ options: [ServiceOption])
    func setMultiRoomGroups(_ gids: Set<Int>, unconfirmed: Set<Int>)
}

public extension StateUpdater {
    func setMaxVolume(_ level: Int?) {}
    func setTrackMetadata(_ metadata: TrackMetadata?) {}

    func reportNonFatal(source: String, message: String) {
        _ = source
        _ = message
    }

    func setServiceCapabilities(sid: Int, capabilities: ServiceCapabilities) {}
    func setNowPlayingOptions(_ options: [ServiceOption]) {}
    func setMultiRoomGroups(_: Set<Int>, unconfirmed _: Set<Int>) {}

    /// Every group classified: the caller could read all member channels.
    func setMultiRoomGroups(_ gids: Set<Int>) {
        setMultiRoomGroups(gids, unconfirmed: [])
    }

    func setPlayerVolume(pid _: Int, level _: Int) {
        // Optional; only conformers that track per-speaker volume implement this.
    }

    func applyPlayerSnapshot(_ snapshot: PlayerSnapshot) {
        setPlayState(snapshot.playState)
        setNowPlaying(snapshot.media)
        setNowPlayingOptions(snapshot.nowPlayingOptions)
        setVolume(snapshot.volume)
        setMuted(snapshot.muted)
        setRepeatMode(snapshot.repeatMode)
        setShuffleMode(snapshot.shuffleMode)
        setQueue(snapshot.queue)
    }
}

/// A `StateUpdater` that ignores everything, for consumers that only care about a few signals.
/// Subclass and override what you display.
///
/// Conform to `StateUpdater` directly instead when you want the compiler to tell you about a
/// requirement you have not handled -- which is what an application should want.
@MainActor
open class MinimalStateUpdater: StateUpdater {
    public var selectedPlayerID: Int?
    public var isPoweredOn: Bool = false

    public init() {}

    open func setConnectionState(_ state: ConnectionState) {}
    open func setPlayers(_ players: [Player]) {}
    open func setGroups(_ groups: [SpeakerGroup]) {}
    open func setMusicSources(_ sources: [MusicSource]) {}
    open func setSelectedPlayerID(_ pid: Int) { selectedPlayerID = pid }
    open func setPlayState(_ state: PlayState) {}
    open func setNowPlaying(_ media: NowPlayingMedia) {}
    open func setVolume(_ level: Int) {}
    open func setMuted(_ muted: Bool) {}
    open func setRepeatMode(_ mode: RepeatMode) {}
    open func setShuffleMode(_ mode: ShuffleMode) {}
    open func setProgress(position: Int, duration: Int) {}
    open func setQueue(_ items: [QueueItem]) {}
    open func setSignedInUser(_ username: String?) {}
    open func setError(_ error: AppError?) {}
    open func setGroupVolume(gid: Int, level: Int) {}
    open func setGroupMuted(gid: Int, muted: Bool) {}
    open func addDiscoveredDevice(_ device: DiscoveredDevice) {}
    open func setPowerState(_ isPoweredOn: Bool) { self.isPoweredOn = isPoweredOn }
}
