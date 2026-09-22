// Diagnostic artifact only. Run temporarily in DayPanelTests with
// APOLLO_STUDIO_OFFLINE=1; does not call initialize(), network, or mutation APIs.
import XCTest
import Combine
@testable import ApolloRuntime

final class ApolloOptimizationAuditTests: XCTestCase {
    private func fixtures(_ count: Int) -> [CUTask] {
        (0..<count).map { i in
            CUTask(id: "audit-\(i)", title: "Audit \(i)", status: "open",
                   statusColor: "#87909E", priority: i % 5,
                   priorityColor: "#9E9E9E", startDate: nil, dueDate: nil,
                   listId: "audit-list", listName: "Audit", isCompleted: false)
        }
    }

    @MainActor
    func testMeasureActualTaskIndexRebuildsAndAlternativePublication() throws {
        ApolloRuntimeEnvironment.activateStudio()
        for (count, changed) in [(132, 1), (132, 10), (1000, 1), (1000, 50), (5000, 50)] {
            let state = AppState.preview(.empty)
            state.tasks = fixtures(count)
            var indexPublishes = 0
            var rootPublishes = 0
            let a = state.$tasksById.dropFirst().sink { _ in indexPublishes += 1 }
            let b = state.objectWillChange.sink { _ in rootPublishes += 1 }

            // Exact property-write pattern in applyStatusToMirrors, excluding
            // its other mirrors and network. Uses the REAL AppState setter/index.
            var started = ContinuousClock.now
            for i in 0..<changed {
                state.tasks[i].status = "in progress"
                state.tasks[i].statusColor = "#4194F6"
                state.tasks[i].isCompleted = false
            }
            let baselineDuration = started.duration(to: .now)
            let baselineIndices = indexPublishes
            let baselineRoot = rootPublishes
            XCTAssertEqual(baselineIndices, 3 * changed)

            state.tasks = fixtures(count)
            indexPublishes = 0
            rootPublishes = 0
            // Experimental comparison, not an app implementation: mutate a
            // value copy, then publish once after all fields are consistent.
            started = ContinuousClock.now
            var next = state.tasks
            for i in 0..<changed {
                next[i].status = "in progress"
                next[i].statusColor = "#4194F6"
                next[i].isCompleted = false
            }
            state.tasks = next
            let batchedDuration = started.duration(to: .now)
            XCTAssertEqual(indexPublishes, 1)
            print("AUDIT_MUTATION n=\(count) changed=\(changed) baseline_index=\(baselineIndices) baseline_root=\(baselineRoot) baseline=\(baselineDuration) single_index=\(indexPublishes) single_root=\(rootPublishes) single=\(batchedDuration)")
            withExtendedLifetime((a, b)) {}
        }
    }

    @MainActor
    func testUnchangedFieldAssignmentStillRebuildsActualIndex() {
        ApolloRuntimeEnvironment.activateStudio()
        let state = AppState.preview(.empty)
        state.tasks = fixtures(132)
        var publishes = 0
        let token = state.$tasksById.dropFirst().sink { _ in publishes += 1 }
        state.tasks[0].isCompleted = false
        XCTAssertEqual(publishes, 1)
        print("AUDIT_UNCHANGED_FIELD index_publishes=\(publishes)")
        withExtendedLifetime(token) {}
    }

    func testMalformedPlainTextIsAcceptedAsTaskIDByExistingDecoder() {
        let decoded = MyTasksDragPayload.decode("ordinary external text")
        XCTAssertEqual(decoded, ["ordinary external text"])
        print("AUDIT_PAYLOAD generic_plain_text_becomes_task_id=true")
    }

    func testClosedDestinationIsExcludedFromOperationalScope() {
        var task = fixtures(1)[0]
        task.isCompleted = true
        task.status = "complete"
        XCTAssertTrue(TaskSurfaceScope.openTasks(in: [task], activeListId: "audit-list").isEmpty)
        print("AUDIT_CLOSED_DESTINATION excluded_from_operational_scope=true")
    }
}
