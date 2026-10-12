import Foundation
import NeosDomain

enum LocalServerSearch: Equatable, Sendable {
    case supported
    case unsupported
    case unknown
}

/// Finds the ContentDirectory behind each local server the device lists, by the name both share.
actor LocalServerDirectory {
    typealias Locate = @Sendable () async -> [MediaServerEndpoint]
    typealias MakeClient = @Sendable (MediaServerEndpoint) -> UPnPContentDirectoryClient

    private let locate: Locate
    private let makeClient: MakeClient
    private let now: @Sendable () -> ContinuousClock.Instant

    private struct Container: Hashable {
        let sid: Int
        let cid: String
    }

    private var names: [Int: String] = [:]
    private var clients: [Int: UPnPContentDirectoryClient] = [:]
    private var artless: Set<Container> = []
    private var failedAt: [Container: ContinuousClock.Instant] = [:]
    private var endpoints: [MediaServerEndpoint] = []
    private var locatedAt: ContinuousClock.Instant?
    private var locating: Task<[MediaServerEndpoint], Never>?

    /// A server missing from the LAN is not searched for again at every row.
    static let locateCooldown: Duration = .seconds(10)

    /// A container whose server was slow or refused is left alone this long, then asked again.
    static let failureCooldown: Duration = .seconds(30)

    init() {
        let discovery = MediaServerDiscovery()
        self.init(
            locate: { await discovery.discover() },
            makeClient: { UPnPContentDirectoryClient(endpoint: $0) },
            now: { ContinuousClock.now }
        )
    }

    init(locate: @escaping Locate, makeClient: @escaping MakeClient, now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.locate = locate
        self.makeClient = makeClient
        self.now = now
    }

    /// Starts looking for the servers as soon as they are listed, ahead of the first page.
    func noteServers(in items: [BrowseItem]) {
        var noted = false
        for item in items where item.type == .heosServer || item.type == .dlnaServer {
            guard let sid = item.sid else { continue }
            names[sid] = item.name
            noted = true
        }
        guard noted, locating == nil, isStale else { return }
        let task = startLocating()
        Task { await absorb(task.value, from: task) }
    }

    func isLocalServer(sid: Int) -> Bool {
        names[sid] != nil
    }

    func searchSupport(sid: Int) async -> LocalServerSearch {
        guard let client = await client(for: sid) else { return .unknown }
        do {
            return try await client.searchCapabilities().isEmpty ? .unsupported : .supported
        } catch {
            if Self.classify(error) == .unreachable { forget(sid: sid) }
            return .unknown
        }
    }

    /// Fills the art the device dropped from `result`, read from the server itself.
    func fillingArtwork(_ result: BrowseResult, sid: Int, cid: String, start: Int) async -> BrowseResult {
        let container = Container(sid: sid, cid: cid)
        guard !artless.contains(container), !isCoolingDown(container),
              result.items.contains(where: { $0.imageURL.isEmpty }),
              let client = await client(for: sid),
              let artwork = await artwork(from: client, container: container, start: start, count: result.items.count)
        else { return result }
        let items = result.items.map { item in
            guard item.imageURL.isEmpty, let id = item.cid ?? item.mid, let url = artwork[id] else { return item }
            return Self.item(item, imageURL: url)
        }
        guard items != result.items else {
            // Later pages of a container hold the same kind of object.
            artless.insert(container)
            return result
        }
        return BrowseResult(items: items, returned: result.returned, count: result.count, options: result.options)
    }

    private func artwork(
        from client: UPnPContentDirectoryClient, container: Container, start: Int, count: Int
    ) async -> [String: String]? {
        do {
            return try await client.childArtwork(of: container.cid, start: start, count: count)
        } catch {
            switch Self.classify(error) {
            case .cancelled:
                break
            case .unreachable:
                forget(sid: container.sid)
            case .slowOrFailing:
                failedAt[container] = now()
            }
            return nil
        }
    }

    private func isCoolingDown(_ container: Container) -> Bool {
        guard let failed = failedAt[container] else { return false }
        return now() < failed.advanced(by: Self.failureCooldown)
    }

    private enum Failure {
        case cancelled
        case unreachable
        case slowOrFailing
    }

    /// Only a server that could not be reached may have moved; a slow or failing one stays.
    private static func classify(_ error: Error) -> Failure {
        if error is CancellationError { return .cancelled }
        guard let urlError = error as? URLError else { return .slowOrFailing }
        switch urlError.code {
        case .cancelled: return .cancelled
        case .timedOut: return .slowOrFailing
        default: return .unreachable
        }
    }

    private static func item(_ item: BrowseItem, imageURL: String) -> BrowseItem {
        BrowseItem(
            name: item.name, imageURL: imageURL, type: item.type, cid: item.cid, mid: item.mid, sid: item.sid,
            playable: item.playable, browsable: item.browsable, artist: item.artist, album: item.album
        )
    }

    func client(for sid: Int) async -> UPnPContentDirectoryClient? {
        if let client = clients[sid] { return client }
        guard let name = names[sid] else { return nil }
        if endpoint(named: name) == nil, locating != nil || isStale {
            await refreshEndpoints()
        }
        guard let endpoint = endpoint(named: name) else { return nil }
        let client = makeClient(endpoint)
        clients[sid] = client
        return client
    }

    private func forget(sid: Int) {
        clients[sid] = nil
        if let name = names[sid] {
            endpoints.removeAll { $0.friendlyName == name }
        }
    }

    private var isStale: Bool {
        guard let locatedAt else { return true }
        return now() >= locatedAt.advanced(by: Self.locateCooldown)
    }

    /// Two servers under one name: nothing says which the device meant.
    private func endpoint(named name: String) -> MediaServerEndpoint? {
        let matches = endpoints.filter { $0.friendlyName == name }
        return matches.count == 1 ? matches[0] : nil
    }

    private func refreshEndpoints() async {
        let task = locating ?? startLocating()
        await absorb(task.value, from: task)
    }

    private func startLocating() -> Task<[MediaServerEndpoint], Never> {
        let task = Task { await locate() }
        locating = task
        return task
    }

    /// The first waiter stores the result; servers it missed stay, some go quiet on SSDP only.
    private func absorb(_ found: [MediaServerEndpoint], from task: Task<[MediaServerEndpoint], Never>) {
        guard locating == task else { return }
        let foundNames = Set(found.map(\.friendlyName))
        endpoints = found + endpoints.filter { !foundNames.contains($0.friendlyName) }
        locatedAt = now()
        locating = nil
    }
}
