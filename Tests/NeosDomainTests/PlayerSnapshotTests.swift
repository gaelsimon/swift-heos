import Testing
@testable import NeosDomain

@Suite("PlayerSnapshot")
@MainActor
struct PlayerSnapshotTests {
    private final class QueueRecorder: MinimalStateUpdater {
        var queues: [[QueueItem]] = []
        override func setQueue(_ items: [QueueItem]) { queues.append(items) }
    }

    private func snapshot(queue: [QueueItem]?) -> PlayerSnapshot {
        PlayerSnapshot(playState: .play, media: NowPlayingMedia(), volume: 3, muted: false,
                       repeatMode: .off, shuffleMode: .off, queue: queue)
    }

    @Test func aSnapshotThatDidNotReadTheQueueLeavesItAlone() {
        let state = QueueRecorder()

        state.applyPlayerSnapshot(snapshot(queue: nil))

        #expect(state.queues.isEmpty)
    }

    @Test func aSnapshotThatReadTheQueueSetsIt() {
        let state = QueueRecorder()

        state.applyPlayerSnapshot(snapshot(queue: [QueueItem(qid: 1)]))

        #expect(state.queues.map { $0.map(\.qid) } == [[1]])
    }
}
