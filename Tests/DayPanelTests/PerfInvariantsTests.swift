import XCTest
@testable import DayPanel

/// Guards the invariants fixed during the 2026-06 performance
/// overhaul (Fases 1-3). Each of these regressed in production
/// and was expensive to diagnose — if one of these tests fails,
/// the corresponding user-visible bug is back:
///   • unstable sort  → "tarefas mudam de posição sozinhas"
///   • page order     → listas embaralhadas após paginação
///   • causality      → "status volta ao anterior após Done"
///   • cache          → launch lento / cache corrompido
final class PerfInvariantsTests: XCTestCase {

    // MARK: - Helpers

    private func makeTask(id: String,
                          status: String = "to do",
                          priority: Int = 0,
                          due: Date? = nil) -> CUTask {
        CUTask(id: id, title: "Task \(id)", status: status,
               statusColor: "#87909E", priority: priority,
               priorityColor: "#9E9E9E", startDate: nil, dueDate: due,
               listId: "l1", listName: "Lista", isCompleted: false)
    }

    private let statuses = [
        CUStatus(status: "in progress", color: "#4194F6", type: "custom"),
        CUStatus(status: "to do",       color: "#87909E", type: "open"),
        CUStatus(status: "complete",    color: "#6BC950", type: "done"),
    ]

    // MARK: - Sort determinism

    /// Fully-tied tasks (same status, no due date, same priority)
    /// must come out in the SAME order regardless of input order.
    /// Swift's sort is not stable; without the id tie-break the
    /// list reshuffled on every sync.
    func testSortIsDeterministicForTiedTasks() {
        let tied = (0..<50).map { makeTask(id: String(format: "t%02d", $0)) }
        let a = AppState.sortByDeadlineThenPriority(tied,          statuses: statuses)
        let b = AppState.sortByDeadlineThenPriority(tied.reversed(), statuses: statuses)
        let c = AppState.sortByDeadlineThenPriority(tied.shuffled(), statuses: statuses)
        XCTAssertEqual(a.map(\.id), b.map(\.id))
        XCTAssertEqual(a.map(\.id), c.map(\.id))
        // Tie-break is ascending id.
        XCTAssertEqual(a.map(\.id), a.map(\.id).sorted())
    }

    /// The primary keys still apply before the tie-break:
    /// active ("custom") status outranks open, earlier due date
    /// first, dated before undated, higher priority first.
    func testSortPrimaryKeys() {
        let now = Date()
        let active   = makeTask(id: "active",  status: "in progress")
        let openSoon = makeTask(id: "soon",    status: "to do", due: now)
        let openLate = makeTask(id: "late",    status: "to do", due: now.addingTimeInterval(3600))
        let undated  = makeTask(id: "undated", status: "to do")
        let urgent   = makeTask(id: "urgent",  status: "to do", priority: 1)

        let sorted = AppState.sortByDeadlineThenPriority(
            [undated, openLate, urgent, openSoon, active].shuffled(),
            statuses: statuses
        )
        let ids = sorted.map(\.id)
        // Active status group first.
        XCTAssertEqual(ids.first, "active")
        // Dated before undated, earlier first.
        XCTAssertLessThan(ids.firstIndex(of: "soon")!, ids.firstIndex(of: "late")!)
        XCTAssertLessThan(ids.firstIndex(of: "late")!, ids.firstIndex(of: "undated")!)
        // Among undated same-status, priority 1 beats none.
        XCTAssertLessThan(ids.firstIndex(of: "urgent")!, ids.firstIndex(of: "undated")!)
    }

    // MARK: - Parallel pagination assembly

    /// Pages fetched in concurrent batches must be stitched in
    /// page order, stop at the first short page, and never skip
    /// a page.
    func testPaginatedPreservesOrderAndStopsAtShortPage() async throws {
        // 3 full pages (100) + a short page 3 (37) = 337 tasks.
        let result = try await ClickUpService.paginated(maxPages: 10) { page -> [CUTask] in
            let count = page < 3 ? 100 : (page == 3 ? 37 : 0)
            return (0..<count).map { i in
                self.makeTask(id: String(format: "p%02d-%03d", page, i))
            }
        }
        XCTAssertEqual(result.count, 337)
        // Page order strictly preserved end-to-end.
        XCTAssertEqual(result.map(\.id), result.map(\.id).sorted())
    }

    /// A list that fits in one page costs exactly one request —
    /// no speculative fetches.
    func testPaginatedSinglePageMakesOneCall() async throws {
        let calls = Counter()
        let result = try await ClickUpService.paginated(maxPages: 10) { page -> [CUTask] in
            await calls.increment()
            return (0..<42).map { self.makeTask(id: "p\(page)-\($0)") }
        }
        XCTAssertEqual(result.count, 42)
        let total = await calls.value
        XCTAssertEqual(total, 1)
    }

    /// A mid-batch failure must throw (callers keep their old
    /// data) instead of returning a silently-truncated list.
    func testPaginatedThrowsOnPageFailure() async {
        struct Boom: Error {}
        do {
            _ = try await ClickUpService.paginated(maxPages: 10) { page -> [CUTask] in
                if page == 2 { throw Boom() }
                return (0..<100).map { self.makeTask(id: "p\(page)-\($0)") }
            }
            XCTFail("expected throw")
        } catch {
            // expected
        }
    }

    // MARK: - Causality guard

    /// A fetch that STARTED before (or within the replica-lag
    /// margin of) a local mutation must not overwrite the local
    /// row — no matter how long the fetch took to return.
    func testCausalityGuardPreservesFreshMutations() {
        let mutatedAt = Date()

        // Fetch started before the mutation → stale snapshot.
        XCTAssertTrue(AppState.shouldPreserveLocal(
            pending: false,
            mutatedAt: mutatedAt,
            fetchStartedAt: mutatedAt.addingTimeInterval(-30),
            margin: 10))

        // Fetch started just after the mutation, inside the
        // replica-lag margin → still stale.
        XCTAssertTrue(AppState.shouldPreserveLocal(
            pending: false,
            mutatedAt: mutatedAt,
            fetchStartedAt: mutatedAt.addingTimeInterval(5),
            margin: 10))

        // Fetch started well after the margin → server data wins.
        XCTAssertFalse(AppState.shouldPreserveLocal(
            pending: false,
            mutatedAt: mutatedAt,
            fetchStartedAt: mutatedAt.addingTimeInterval(11),
            margin: 10))

        // In-flight mutation always wins.
        XCTAssertTrue(AppState.shouldPreserveLocal(
            pending: true,
            mutatedAt: nil,
            fetchStartedAt: mutatedAt.addingTimeInterval(999),
            margin: 10))

        // No mutation on record → server data wins.
        XCTAssertFalse(AppState.shouldPreserveLocal(
            pending: false,
            mutatedAt: nil,
            fetchStartedAt: mutatedAt,
            margin: 10))
    }

    // MARK: - Split cache

    /// Round-trip through the split layout, and migration: a
    /// legacy single-file `cache.json` must still load when the
    /// split files don't exist yet.
    func testCacheRoundTripAndLegacyFallback() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("apollo-cache-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let snapshot = AppCache(events: CalendarEvent.mock(),
                                tasks: CUTask.mock(),
                                lastSyncedAt: Date(),
                                assignedToMeTasks: [makeTask(id: "mine")])

        // Split-layout round trip.
        let cache = CacheManager(directory: tmp)
        cache.save(snapshot)
        cache.waitForPendingWrites()
        let loaded = try XCTUnwrap(cache.load())
        XCTAssertEqual(loaded.tasks.map(\.id),  snapshot.tasks.map(\.id))
        XCTAssertEqual(loaded.events.map(\.id), snapshot.events.map(\.id))
        XCTAssertEqual(loaded.assignedToMeTasks.map(\.id), ["mine"])

        // Legacy fallback: only the old single file present.
        let legacyDir = tmp.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let legacyData = try JSONEncoder().encode(snapshot)
        try legacyData.write(to: legacyDir.appendingPathComponent("cache.json"))
        let legacyCache = CacheManager(directory: legacyDir)
        let legacyLoaded = try XCTUnwrap(legacyCache.load())
        XCTAssertEqual(legacyLoaded.tasks.map(\.id), snapshot.tasks.map(\.id))
    }
}

/// Tiny actor-based counter for concurrency-safe call counting
/// inside `paginated`'s fetch closure.
private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
