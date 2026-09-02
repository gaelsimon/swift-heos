import Foundation
import NeosDomain

public actor BrowseService {
    private let connection: HEOSConnection
    private let parser = HEOSResponseParser()

    // MARK: - Browse Serialization

    /// The HEOS device processes browse commands one at a time. Sending multiple
    /// concurrently causes "command under process" responses and eventual timeouts.
    /// This gate ensures only one browse command is in-flight at a time.
    private struct QueuedWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var browseQueue: [QueuedWaiter] = []
    private var isBrowsing = false

    private func acquireBrowseGate() async throws {
        if !isBrowsing {
            isBrowsing = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                browseQueue.append(QueuedWaiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
        isBrowsing = true
    }

    private func cancelWaiter(id: UUID) {
        guard let index = browseQueue.firstIndex(where: { $0.id == id }) else { return }
        let waiter = browseQueue.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releaseBrowseGate() {
        if let next = browseQueue.first {
            browseQueue.removeFirst()
            next.continuation.resume()
        } else {
            isBrowsing = false
        }
    }

    // MARK: - Search Capability

    /// One thing a source can be asked to search: a criteria on a source.
    private struct SearchTarget: Hashable {
        let sid: Int
        let criteriaID: Int
    }

    /// A target left alone until a deadline, and the error to raise until then.
    private struct SkippedTarget {
        let error: HEOSError
        let until: ContinuousClock.Instant
    }

    private var searchFailures: [SearchTarget: Int] = [:]
    private var skipped: [SearchTarget: SkippedTarget] = [:]
    private var reportedTargets: Set<SearchTarget> = []
    private let now: @Sendable () -> ContinuousClock.Instant

    /// Errors that mean the source, not the request: the device relaying a server that broke.
    private static let systemErrorID = 12

    /// One failure is not enough to tell a server that cannot search from one that was busy.
    private static let failuresBeforeSkipping = 2

    /// Long enough to cover a burst of type-ahead searches, short enough that a server waking
    /// up is asked again before whoever is typing has noticed.
    private static let skipWindow: Duration = .seconds(3)

    public init(connection: HEOSConnection) {
        self.init(connection: connection, now: { ContinuousClock.now })
    }

    init(connection: HEOSConnection, now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.connection = connection
        self.now = now
    }

    public func getMusicSources() async throws -> [MusicSource] {
        let response = try await connection.send(.getMusicSources)
        // A re-read source list is a new set of servers; what the old ones did means nothing.
        searchFailures.removeAll()
        skipped.removeAll()
        reportedTargets.removeAll()
        return parser.parseMusicSources(response)
    }

    public func browseSource(sid: Int, range: ClosedRange<Int>? = nil) async throws -> BrowseResult {
        try await acquireBrowseGate()
        defer { releaseBrowseGate() }
        try Task.checkCancellation()
        let response = try await connection.send(.browseSource(sid: sid, range: range))
        return parser.parseBrowseResult(response)
    }

    public func browseContainer(sid: Int, cid: String, range: ClosedRange<Int>? = nil) async throws -> BrowseResult {
        try await acquireBrowseGate()
        defer { releaseBrowseGate() }
        try Task.checkCancellation()
        let response = try await connection.send(.browseSourceContainer(sid: sid, cid: cid, range: range))
        return parser.parseBrowseResult(response)
    }

    /// Raises the recorded error without asking again while a target is inside its skip window.
    public func search(sid: Int, query: String, criteriaID: Int, range: ClosedRange<Int>? = nil) async throws -> BrowseResult {
        let target = SearchTarget(sid: sid, criteriaID: criteriaID)
        if let skip = skipped[target] {
            guard now() >= skip.until else { throw skip.error }
            // The window is over; the next answer decides, not the last one.
            skipped[target] = nil
            searchFailures[target] = nil
        }
        try await acquireBrowseGate()
        defer { releaseBrowseGate() }
        try Task.checkCancellation()
        do {
            let response = try await connection.send(.search(sid: sid, searchString: query, searchCriteriaID: criteriaID, range: range))
            searchFailures[target] = nil
            return parser.parseBrowseResult(response)
        } catch let error as HEOSError where error.errorID == Self.systemErrorID {
            noteSearchFailure(target, error)
            throw error
        }
    }

    /// Leaves a target alone for the skip window once it has failed enough, and reports it once.
    /// The window is short on purpose: standby keeps a server in the source list, failing like
    /// one that cannot search at all, and nothing announces that it woke.
    private func noteSearchFailure(_ target: SearchTarget, _ error: HEOSError) {
        let count = (searchFailures[target] ?? 0) + 1
        searchFailures[target] = count
        guard count >= Self.failuresBeforeSkipping else { return }
        skipped[target] = SkippedTarget(error: error, until: now().advanced(by: Self.skipWindow))
        guard reportedTargets.insert(target).inserted else { return }
        HEOSLogger.service.info(
            "Search on sid \(target.sid) criteria \(target.criteriaID) keeps failing: \(error.text, privacy: .public)"
        )
    }

    public func getSearchCriteria(sid: Int) async throws -> [SearchCriteria] {
        try await acquireBrowseGate()
        defer { releaseBrowseGate() }
        try Task.checkCancellation()
        let response = try await connection.send(.getSearchCriteria(sid: sid))
        return parser.parseSearchCriteria(response)
    }

    public func playStation(pid: Int, sid: Int, cid: String, mid: String, name: String) async throws {
        try await connection.send(.playStation(pid: pid, sid: sid, cid: cid, mid: mid, name: name))
    }

    public func playURL(pid: Int, url: String) async throws {
        try await connection.send(.playURL(pid: pid, url: url))
    }

    public func playPreset(pid: Int, preset: Int) async throws {
        try await connection.send(.playPresetStation(pid: pid, preset: preset))
    }

    public func playInput(pid: Int, input: String, sourcePlayerID: Int? = nil) async throws {
        try await connection.send(.playInputSource(pid: pid, input: input, sourcePlayerID: sourcePlayerID))
    }

    public func addToQueue(pid: Int, sid: Int, cid: String, mid: String? = nil, criteria: AddCriteria) async throws {
        // DLNA servers resolving a searched mid can take 30s+ before the device answers.
        let timeout: Duration = .seconds(60)
        if let mid {
            try await connection.send(.addTrackToQueue(pid: pid, sid: sid, cid: cid, mid: mid, aid: criteria), timeout: timeout)
        } else {
            try await connection.send(.addContainerToQueue(pid: pid, sid: sid, cid: cid, aid: criteria), timeout: timeout)
        }
    }

    public func getFavorites(range: ClosedRange<Int>? = nil) async throws -> BrowseResult {
        try await acquireBrowseGate()
        defer { releaseBrowseGate() }
        try Task.checkCancellation()
        let response = try await connection.send(.browseSource(sid: 1028, range: range))
        return parser.parseBrowseResult(response)
    }

    public func getPlaylists(range: ClosedRange<Int>? = nil) async throws -> BrowseResult {
        try await acquireBrowseGate()
        defer { releaseBrowseGate() }
        try Task.checkCancellation()
        let response = try await connection.send(.browseSource(sid: 1025, range: range))
        return parser.parseBrowseResult(response)
    }

    public func getSourceInfo(sid: Int) async throws -> HEOSResponse {
        try await connection.send(.getSourceInfo(sid: sid))
    }

    public func getHistory(range: ClosedRange<Int>? = nil) async throws -> BrowseResult {
        try await acquireBrowseGate()
        defer { releaseBrowseGate() }
        try Task.checkCancellation()
        let response = try await connection.send(.browseSource(sid: 1026, range: range))
        return parser.parseBrowseResult(response)
    }

    public func renamePlaylist(sid: Int, cid: String, name: String) async throws {
        try await acquireBrowseGate()
        defer { releaseBrowseGate() }
        try Task.checkCancellation()
        try await connection.send(.renamePlaylist(sid: sid, cid: cid, name: name))
    }

    public func deletePlaylist(sid: Int, cid: String) async throws {
        try await acquireBrowseGate()
        defer { releaseBrowseGate() }
        try Task.checkCancellation()
        try await connection.send(.deletePlaylist(sid: sid, cid: cid))
    }

    public func retrieveMetadata(sid: Int, cid: String) async throws -> HEOSResponse {
        try await acquireBrowseGate()
        defer { releaseBrowseGate() }
        try Task.checkCancellation()
        return try await connection.send(.retrieveMetadata(sid: sid, cid: cid))
    }

    public func setServiceOption(sid: Int, option: Int, params: [String: String] = [:]) async throws {
        try await acquireBrowseGate()
        defer { releaseBrowseGate() }
        try Task.checkCancellation()
        try await connection.send(.setServiceOption(sid: sid, option: option, params: params))
    }
}
