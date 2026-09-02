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

    /// Consecutive system errors per target, and the error to raise once one is left alone.
    private var searchFailures: [SearchTarget: Int] = [:]
    private var refusedSearches: [SearchTarget: HEOSError] = [:]

    /// Errors that mean the source, not the request: the device relaying a server that broke.
    private static let systemErrorID = 12

    /// One failure is not enough to tell a server that cannot search from one that was busy.
    private static let failuresBeforeGivingUp = 2

    public init(connection: HEOSConnection) {
        self.connection = connection
    }

    public func getMusicSources() async throws -> [MusicSource] {
        let response = try await connection.send(.getMusicSources)
        // A re-read source list is where a server that was asleep earns another try.
        searchFailures.removeAll()
        refusedSearches.removeAll()
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

    /// Raises the recorded error without asking again once a target has failed enough times.
    /// Some DLNA servers publish criteria they cannot honour, and a caller searching every
    /// source spends the browse gate -- which is serial -- on requests that cannot succeed,
    /// so the ones that would answer wait behind them.
    public func search(sid: Int, query: String, criteriaID: Int, range: ClosedRange<Int>? = nil) async throws -> BrowseResult {
        let target = SearchTarget(sid: sid, criteriaID: criteriaID)
        if let refused = refusedSearches[target] { throw refused }

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

    /// Counts a system error against a target and stops asking once it has failed enough.
    private func noteSearchFailure(_ target: SearchTarget, _ error: HEOSError) {
        let count = (searchFailures[target] ?? 0) + 1
        searchFailures[target] = count
        guard count >= Self.failuresBeforeGivingUp else { return }
        refusedSearches[target] = error
        HEOSLogger.service.info(
            "Leaving search on sid \(target.sid) criteria \(target.criteriaID) alone after \(count) system errors"
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
