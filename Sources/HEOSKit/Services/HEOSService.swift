import Foundation
import NeosDomain
import os

public actor HEOSService {
    var connection: HEOSConnection?
    var playerService: PlayerService?
    var groupService: GroupService?
    var browseService: BrowseService?
    var systemService: SystemService?
    var avrClient: AVRControlClient?
    var avrEventTask: Task<Void, Never>?
    var upnpTransport: UPnPAVTransportClient?
    var upnpACT: UPnPACTClient?
    var volumeLimitTask: Task<Void, Never>?
    let discovery = DeviceDiscovery()
    let localServers = LocalServerDirectory()
    var eventRouter: EventRouter?
    var eventTask: Task<Void, Never>?
    var discoveryTask: Task<Void, Never>?
    let notifyListener = SSDPNotifyListener()
    let bonjourDiscovery = BonjourDiscovery()
    let connectionCoordinator: ConnectionCoordinator
    var isWakingUp = false

    /// Asks a device over UPnP which stereo or surround seat it holds; tests swap in a stub.
    var pairMembershipReader: @Sendable (String) async -> PairMembership? = { host in
        guard let client = try? UPnPGroupControlClient(host: host) else { return nil }
        defer { Task { await client.invalidateSession() } }
        return try? await client.membership()
    }
    var pairLookups: [String: (at: ContinuousClock.Instant, pair: PairMembership?)] = [:]

    func usePairMembershipReader(_ reader: @escaping @Sendable (String) async -> PairMembership?) {
        pairMembershipReader = reader
        pairLookups = [:]
    }

    /// Reads the name a zone leader holds for its multi-room zone; tests swap in a stub.
    var zoneNameReader: @Sendable (String) async -> String? = { host in
        guard let client = try? UPnPZoneControlClient(host: host) else { return nil }
        defer { Task { await client.invalidateSession() } }
        return try? await client.zoneName()
    }

    var zoneNameWriter: @Sendable (String, String) async throws -> Void = { host, name in
        let client = try UPnPZoneControlClient(host: host)
        defer { Task { await client.invalidateSession() } }
        try await client.setZoneName(name)
    }

    func useZoneNameReader(_ reader: @escaping @Sendable (String) async -> String?) {
        zoneNameReader = reader
    }

    func useZoneNameWriter(_ writer: @escaping @Sendable (String, String) async throws -> Void) {
        zoneNameWriter = writer
    }

    /// Publishes a discovered device with its pair seat attached, off the discovery stream so a
    /// slow device holds up nobody else; the seat is re-read once a minute at most.
    nonisolated func publishDiscovered(_ device: DiscoveredDevice) {
        Task {
            let pair = await self.pairMembership(of: device.host)
            await self.stateUpdater.addDiscoveredDevice(device.withPair(pair))
        }
    }

    func pairMembership(of host: String) async -> PairMembership? {
        if let cached = pairLookups[host], cached.at.duration(to: .now) < .seconds(60) {
            return cached.pair
        }
        let pair = await pairMembershipReader(host)
        pairLookups[host] = (.now, pair)
        return pair
    }

    var volumeThrottles: [Int: Throttle<Int>] = [:]
    var groupVolumeThrottles: [Int: Throttle<Int>] = [:]

    let stateUpdater: StateUpdater

    public init(stateUpdater: StateUpdater) {
        self.stateUpdater = stateUpdater
        self.connectionCoordinator = ConnectionCoordinator(stateUpdater: stateUpdater)
    }

    // MARK: - Connection

    public func connect(host: String, port: Int = 1255, cachedPlayerID: Int? = nil) async throws {
        HEOSLogger.service.info("Connect requested for \(host):\(port)")

        // Tear down any existing connection before reconnecting
        eventTask?.cancel()
        eventTask = nil
        avrEventTask?.cancel()
        avrEventTask = nil
        await connection?.disconnect()
        connection = nil

        // Plain TCP on the given port (1255 for HEOS CLI)
        let transport = TCPTransport()
        let conn = HEOSConnection(transport: transport)
        try await conn.connect(host: host, port: port)

        self.connection = conn
        await connectionCoordinator.recordConnection(host: host, port: port, playerID: nil)
        self.playerService = PlayerService(connection: conn)
        self.groupService = GroupService(connection: conn)
        self.browseService = BrowseService(connection: conn, now: { ContinuousClock.now }, localServers: localServers)
        self.systemService = SystemService(connection: conn)
        self.eventRouter = EventRouter(
            stateUpdater: stateUpdater,
            playerService: self.playerService,
            groupService: self.groupService,
            browseService: self.browseService,
            refreshTopology: { [weak self] groups in
                await self?.refreshGroupTopology(groups: groups)
            }
        )

        await resetVolumeThrottles()
        await stateUpdater.setConnectionState(.connected)

        // Register for events first so we don't miss state changes during initial load
        try await systemService?.registerForChangeEvents(enable: true)
        startEventListening()

        // Load initial state; event listener is active, so any concurrent
        // changes from the device will be captured
        await loadInitialState(cachedPlayerID: cachedPlayerID)

        await conn.startHeartbeat()

        // Best-effort AVR connection for power control (port 23, same host)
        await connectAVR(host: host)

        // Best-effort UPnP AVTransport connection for seek/position (port 60006, same host)
        connectUPnP(host: host)

        HEOSLogger.service.info("Connected and initialized")
    }

    public func disconnect() async {
        await tearDownSession()
        await connectionCoordinator.clearTarget()
        await stopContinuousDiscovery()
        await stateUpdater.setMaxVolume(nil)
        await stateUpdater.setConnectionState(.disconnected)
        HEOSLogger.service.info("Disconnected")
    }

    // MARK: - Discovery

    public func discoverDevices() async throws -> [DiscoveredDevice] {
        try await discovery.discover(timeout: 5.0)
    }

    public func startContinuousDiscovery() {
        guard discoveryTask == nil else { return }
        HEOSLogger.discovery.info("Starting continuous discovery")

        discoveryTask = Task {
            await withTaskGroup(of: Void.self) { group in
                // Passive: listen for NOTIFY announcements
                group.addTask { [notifyListener] in
                    let stream = await notifyListener.listen()

                    for await response in stream {
                        guard !Task.isCancelled else { break }

                        HEOSLogger.discovery.info("NOTIFY received from \(response.host)")
                        let device = await DeviceDiscovery.enrichDevice(from: response)
                        self.publishDiscovered(device)
                    }
                }

                // Active: periodic M-SEARCH with backoff
                group.addTask {
                    var interval: TimeInterval = 3.0
                    let maxInterval: TimeInterval = 30.0

                    while !Task.isCancelled {
                        do {
                            let devices = try await self.discovery.discover(timeout: 5.0)
                            for device in devices {
                                self.publishDiscovered(device)
                            }

                            if !devices.isEmpty {
                                // Found devices; slow down active probing
                                interval = min(interval * 2, maxInterval)
                            } else {
                                // No devices; stay aggressive
                                interval = 3.0
                            }
                        } catch {
                            HEOSLogger.discovery.warning("Active discovery failed: \(error.localizedDescription)")
                        }

                        try? await Task.sleep(for: .seconds(interval))
                    }
                }

                // Bonjour/mDNS: continuous background monitoring
                group.addTask { [bonjourDiscovery] in
                    let stream = await bonjourDiscovery.startContinuous()
                    for await device in stream {
                        guard !Task.isCancelled else { break }
                        self.publishDiscovered(device)
                    }
                }
            }
        }
    }

    public func stopContinuousDiscovery() async {
        discoveryTask?.cancel()
        discoveryTask = nil
        await notifyListener.stop()
        await bonjourDiscovery.stop()
        HEOSLogger.discovery.info("Stopped continuous discovery")
    }

    // MARK: - Player Actions

    public func play(pid: Int) async throws {
        try await ensureConnected()
        try await ensurePoweredOn()
        try await requirePlayerService().setPlayState(pid: pid, state: .play)
    }

    public func pause(pid: Int) async throws {
        try await ensureConnected()
        try await requirePlayerService().setPlayState(pid: pid, state: .pause)
    }

    public func stop(pid: Int) async throws {
        try await ensureConnected()
        try await requirePlayerService().setPlayState(pid: pid, state: .stop)
    }

    /// Re-reads play state and now-playing for `pid`, applying each only on success so a
    /// transient failure never overwrites good state with defaults.
    public func resyncPlaybackState(pid: Int) async {
        guard let playerService else { return }
        let playState = try? await playerService.getPlayState(pid: pid)
        let nowPlaying = try? await playerService.getNowPlayingMedia(pid: pid)
        await applyResyncedPlayback(playState: playState, nowPlaying: nowPlaying, to: stateUpdater)
    }

    public func next(pid: Int) async throws {
        try await ensureConnected()
        try await ensurePoweredOn()
        try await requirePlayerService().playNext(pid: pid)
    }

    public func previous(pid: Int) async throws {
        try await ensureConnected()
        try await ensurePoweredOn()
        try await requirePlayerService().playPrevious(pid: pid)
    }

    public func getVolume(pid: Int) async throws -> Int {
        try await ensureConnected()
        return try await requirePlayerService().getVolume(pid: pid)
    }

    public func setVolume(pid: Int, level: Int) async throws {
        try await ensureConnected()
        await volumeThrottle(for: pid).submit(level)
    }

    public func toggleMute(pid: Int) async throws {
        try await ensureConnected()
        try await requirePlayerService().toggleMute(pid: pid)
    }

    public func setPlayMode(pid: Int, repeat repeatMode: RepeatMode, shuffle: ShuffleMode) async throws {
        try await ensureConnected()
        try await requirePlayerService().setPlayMode(pid: pid, repeat: repeatMode, shuffle: shuffle)
    }

    // MARK: - Queue Actions

    public func getQueue(pid: Int, range: ClosedRange<Int>? = nil) async throws -> [QueueItem] {
        try await ensureConnected()
        guard let playerService else { throw HEOSServiceError.notConnected }
        return try await playerService.getQueue(pid: pid, range: range)
    }

    public func playQueueItem(pid: Int, qid: Int) async throws {
        try await ensureConnected()
        try await ensurePoweredOn()
        try await requirePlayerService().playQueueItem(pid: pid, qid: qid)
    }

    public func removeFromQueue(pid: Int, qids: [Int]) async throws {
        try await ensureConnected()
        try await requirePlayerService().removeFromQueue(pid: pid, qids: qids)
    }

    public func clearQueue(pid: Int) async throws {
        try await ensureConnected()
        try await requirePlayerService().clearQueue(pid: pid)
    }

    public func moveQueueItem(pid: Int, from sourceQIDs: [Int], to destQID: Int) async throws {
        try await ensureConnected()
        try await requirePlayerService().moveQueueItem(pid: pid, from: sourceQIDs, to: destQID)
    }

    // MARK: - Group Actions

    public func getGroups() async throws -> [SpeakerGroup] {
        try await ensureConnected()
        guard let groupService else { throw HEOSServiceError.notConnected }
        return try await groupService.getGroups()
    }

    public func createGroup(leaderPID: Int, memberPIDs: [Int]) async throws {
        try await ensureConnected()
        try await requireGroupService().createGroup(leaderPID: leaderPID, memberPIDs: memberPIDs)
    }

    public func refreshSpeakers() async throws {
        try await ensureConnected()
        let players = try await requirePlayerService().getPlayers()
        let groups = try await requireGroupService().getGroups()
        await stateUpdater.setPlayers(players)
        await stateUpdater.setGroups(groups)
        Task { await self.refreshGroupTopology(groups: groups, players: players) }
        Task { [groupService, stateUpdater] in await groupService?.pushLevels(of: groups, to: stateUpdater) }
    }

    public func ungroup(pid: Int) async throws {
        try await ensureConnected()
        try await requireGroupService().ungroup(pid: pid)
    }

    /// Writes the name to the zone leader over UPnP, then publishes what the devices now report.
    public func renameGroup(gid: Int, name: String) async throws {
        try await ensureConnected()
        let players = try await requirePlayerService().getPlayers()
        let groups = try await requireGroupService().getGroups()
        guard let leaderPID = groups.first(where: { $0.gid == gid })?.leader?.pid,
              let host = players.first(where: { $0.pid == leaderPID })?.ip, !host.isEmpty else {
            throw HEOSServiceError.noGroupLeader(gid: gid)
        }
        try await zoneNameWriter(host, name)
        await stateUpdater.setZoneNames(zoneNames(of: groups, players: players))
    }

    public func setGroupVolume(gid: Int, level: Int) async throws {
        try await ensureConnected()
        await groupVolumeThrottle(for: gid).submit(level)
    }

    public func toggleGroupMute(gid: Int) async throws {
        try await ensureConnected()
        try await requireGroupService().toggleGroupMute(gid: gid)
    }

    // MARK: - Browse Actions

    public func getMusicSources() async throws -> [MusicSource] {
        try await ensureConnected()
        guard let browseService else { throw HEOSServiceError.notConnected }
        return try await browseService.getMusicSources()
    }

    public func browseSource(sid: Int, range: ClosedRange<Int>? = nil) async throws -> BrowseResult {
        try await ensureConnected()
        guard let browseService else { throw HEOSServiceError.notConnected }
        return try await browseService.browseSource(sid: sid, range: range)
    }

    public func browseContainer(sid: Int, cid: String, range: ClosedRange<Int>? = nil) async throws -> BrowseResult {
        try await ensureConnected()
        guard let browseService else { throw HEOSServiceError.notConnected }
        return try await browseService.browseContainer(sid: sid, cid: cid, range: range)
    }

    public func playStation(pid: Int, sid: Int, cid: String, mid: String, name: String) async throws {
        try await ensureConnected()
        try await ensurePoweredOn()
        try await requireBrowseService().playStation(pid: pid, sid: sid, cid: cid, mid: mid, name: name)
    }

    public func playURL(pid: Int, url: String) async throws {
        try await ensureConnected()
        try await ensurePoweredOn()
        try await requireBrowseService().playURL(pid: pid, url: url)
    }

    public func playInput(pid: Int, input: String) async throws {
        try await ensureConnected()
        try await ensurePoweredOn()
        try await requireBrowseService().playInput(pid: pid, input: input)
    }

    public func addToQueue(pid: Int, sid: Int, cid: String, mid: String?, criteria: AddCriteria) async throws {
        try await ensureConnected()
        if criteria == .playNow || criteria == .replaceAndPlay {
            try await ensurePoweredOn()
        }
        try await requireBrowseService().addToQueue(pid: pid, sid: sid, cid: cid, mid: mid, criteria: criteria)
    }

    public func getSourceInfo(sid: Int) async throws -> HEOSResponse {
        try await ensureConnected()
        guard let browseService else { throw HEOSServiceError.notConnected }
        return try await browseService.getSourceInfo(sid: sid)
    }

    public func getHistory(range: ClosedRange<Int>? = nil) async throws -> BrowseResult {
        try await ensureConnected()
        guard let browseService else { throw HEOSServiceError.notConnected }
        return try await browseService.getHistory(range: range)
    }

    public func renamePlaylist(sid: Int, cid: String, name: String) async throws {
        try await ensureConnected()
        try await requireBrowseService().renamePlaylist(sid: sid, cid: cid, name: name)
    }

    public func deletePlaylist(sid: Int, cid: String) async throws {
        try await ensureConnected()
        try await requireBrowseService().deletePlaylist(sid: sid, cid: cid)
    }

    public func checkUpdate(pid: Int) async throws -> HEOSResponse {
        try await ensureConnected()
        guard let playerService else { throw HEOSServiceError.notConnected }
        return try await playerService.checkUpdate(pid: pid)
    }

    public func retrieveMetadata(sid: Int, cid: String) async throws -> HEOSResponse {
        try await ensureConnected()
        guard let browseService else { throw HEOSServiceError.notConnected }
        return try await browseService.retrieveMetadata(sid: sid, cid: cid)
    }

    public func setServiceOption(sid: Int, option: Int, params: [String: String] = [:]) async throws {
        try await ensureConnected()
        try await requireBrowseService().setServiceOption(sid: sid, option: option, params: params)
    }

    // MARK: - Search Actions

    public func getSearchCriteria(sid: Int) async throws -> [SearchCriteria] {
        try await ensureConnected()
        guard let browseService else { throw HEOSServiceError.notConnected }
        return try await browseService.getSearchCriteria(sid: sid)
    }

    public func search(sid: Int, query: String, scid: Int, range: ClosedRange<Int>? = nil) async throws -> BrowseResult {
        try await ensureConnected()
        guard let browseService else { throw HEOSServiceError.notConnected }
        return try await browseService.search(sid: sid, query: query, criteriaID: scid, range: range)
    }

    // MARK: - Account Actions

    public func signIn(username: String, password: String) async throws {
        try await ensureConnected()
        try await requireSystemService().signIn(username: username, password: password)
    }

    public func signOut() async throws {
        try await ensureConnected()
        try await requireSystemService().signOut()
    }

    public func checkAccount() async throws -> String? {
        try await ensureConnected()
        return try await requireSystemService().checkAccount()
    }

    // MARK: - Power Control (AVR)

    public func powerOn() async throws {
        guard let avrClient else {
            HEOSLogger.avr.warning("AVR client not available")
            return
        }
        try await avrClient.powerOn()
        await stateUpdater.setPowerState(true)
    }

    public func powerOff() async throws {
        guard let avrClient else {
            HEOSLogger.avr.warning("AVR client not available")
            return
        }
        try await avrClient.powerOff()
        await stateUpdater.setPowerState(false)
    }


    // MARK: - UPnP AVTransport (Seek / Position / Metadata)

    /// Seek to a position (in seconds) in the current track via UPnP AVTransport.
    public func seek(target: TimeInterval) async throws {
        guard let upnpTransport else {
            HEOSLogger.upnp.warning("UPnP transport not available")
            return
        }
        try await upnpTransport.seek(target: target)
    }

    /// Query the current playback position and duration via UPnP AVTransport.
    public func getPositionInfo() async throws -> PositionInfo? {
        guard let upnpTransport else {
            HEOSLogger.upnp.warning("UPnP transport not available")
            return nil
        }
        return try await upnpTransport.getPositionInfo()
    }

    /// Fetch and parse DIDL-Lite track metadata from the AVTransport `GetCurrentState` action.
    /// This returns richer metadata (sample rate, bit depth, audio format) than `GetPositionInfo`.
    /// Returns nil if UPnP is unavailable or the metadata can't be parsed.
    public func fetchTrackMetadata() async throws -> TrackMetadata? {
        guard let upnpTransport else { return nil }
        guard let didlString = try await upnpTransport.getCurrentTrackMetaData() else { return nil }
        return DIDLLiteParser.parse(didlString)
    }

    /// Query which transport actions are available for the current media.
    public func getTransportActions() async throws -> Set<String> {
        guard let upnpTransport else { return [] }
        return try await upnpTransport.getTransportActions()
    }

}

public enum HEOSServiceError: Error, Sendable, LocalizedError {
    case notConnected
    case noGroupLeader(gid: Int)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to speaker"
        case .noGroupLeader(let gid): "Group \(gid) has no reachable leader"
        }
    }
}

/// Applies resynced playback values, skipping any that failed to fetch (`nil`) so a
/// transient failure never overwrites good state with defaults.
func applyResyncedPlayback(
    playState: PlayState?,
    nowPlaying: (media: NowPlayingMedia, options: [ServiceOption])?,
    to stateUpdater: StateUpdater
) async {
    if let playState {
        await stateUpdater.setPlayState(playState)
    }
    if let nowPlaying {
        await stateUpdater.setNowPlaying(nowPlaying.media)
        await stateUpdater.setNowPlayingOptions(nowPlaying.options)
    }
}
