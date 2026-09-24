import Combine
import Foundation
import Testing
@testable import ApolloRuntime

private final class PollingScrollDefaults: UserDefaults, @unchecked Sendable {
    var writes = 0
    override func set(_ value: Any?, forKey key: String) {
        if key == "taskReviewPendingUpdates.v1" { writes += 1 }
        super.set(value, forKey: key)
    }
}

@Suite(.serialized)
@MainActor
struct ReviewPollingScrollTests {
    @Test func recyclingRowsRetainsProbeIntervalButExplicitRefreshStillWorks() async throws {
        let suite = "ReviewPollingScrollTests.recycling.\(UUID().uuidString)"
        let defaults = try #require(PollingScrollDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var catalogReads = 0
        let store = TaskReviewUpdateStore(defaults: defaults,
                                         fullTaskFetcher: { _ in nil },
                                         catalogFetcher: { _ in catalogReads += 1; return nil })
        var task = CUTask(id: "recycled", title: "Test", status: "open",
                          statusColor: "#888888", priority: 0, priorityColor: "#888888",
                          startDate: nil, dueDate: nil, listId: "test", listName: "Test",
                          isCompleted: false)
        defer { store.unwatch(taskId: task.id) }
        func drain() async {
            // Empty offline probes have no I/O; allow the main-actor pump to run.
            for _ in 0..<20 { await Task.yield() }
        }
        store.watch(task: task)
        await drain()
        #expect(catalogReads == 1)
        for _ in 0..<20 {
            store.unwatch(taskId: task.id)
            store.watch(task: task)
            await drain()
        }
        print("REVIEW_RECYCLE repeated=20 catalogReads=\(catalogReads)")
        #expect(catalogReads == 1, "Scrolling away and back must not reset the 45-second interval")
        store.probeVisibleNow()
        await drain()
        #expect(catalogReads == 2, "Returning from a web review must still force a fresh probe")
        store.unwatch(taskId: task.id)
        task.dateUpdated = Date()
        store.watch(task: task)
        await drain()
        #expect(catalogReads == 3, "A changed task must be probed immediately")
    }

    /// Exercises the entry point seen in the live scroll sample, including
    /// version validation and the durable pending latch, without network I/O.
    @Test func unchangedWatcherBatchDoesNotBlockScrollWithWritesOrPublications() throws {
        let suite = "ReviewPollingScrollTests.\(UUID().uuidString)"
        let defaults = try #require(PollingScrollDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TaskReviewUpdateStore(defaults: defaults,
                                         fullTaskFetcher: { _ in nil },
                                         catalogFetcher: { _ in nil })
        func observe(_ index: Int, comments: Int = 2) {
            store.recordDiscoveredUpdate(
                taskId: "task-\(index)", activeAtt: "review-\(index)",
                mediaUrl: "https://example.com/video-\(index).mov", ext: "mov",
                title: "Video \(index)", uploaderId: 42,
                meta: .init(exists: true, updatedAt: "2026-09-24T00:00:00Z",
                            status: "in_review", commentCount: comments,
                            reviewId: "review-\(index)", currentVersionId: "v1",
                            evaluatedVersionId: "v1"),
                hasUnseenUpdate: true, versionId: "v1")
        }
        for index in 0..<40 { observe(index) }
        let initialWrites = defaults.writes
        #expect(initialWrites == 40)
        var publications = 0
        let subscription = store.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<5 {
            for index in 0..<40 { observe(index) }
        }
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        print("REVIEW_POLL_SCROLL repeated=200 writes=\(defaults.writes - initialWrites) publications=\(publications) mainActorMS=\(ms)")
        #expect(defaults.writes == initialWrites)
        #expect(publications == 0)

        // A real update with the same timestamp must still reach the UI and disk.
        observe(0, comments: 3)
        #expect(defaults.writes == initialWrites + 1)
        #expect(publications == 1)
        let restored = TaskReviewUpdateStore(defaults: defaults,
                                            fullTaskFetcher: { _ in nil },
                                            catalogFetcher: { _ in nil })
        #expect(restored.update(for: "task-0")?.meta.commentCount == 3)
        #expect(restored.update(for: "task-39")?.meta.commentCount == 2)
    }
}
