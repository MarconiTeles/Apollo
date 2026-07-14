import XCTest
@testable import DayPanel

final class UploadActivityTests: XCTestCase {
    func testQueueKeepsNewestFirstAndCapsRecentUploads() {
        var queue: [AppState.UploadActivity] = []
        for index in 0..<24 {
            queue = AppState.insertingUploadActivity(
                makeActivity(index: index),
                into: queue
            )
        }

        XCTAssertEqual(queue.count, 20)
        XCTAssertEqual(queue.first?.fileName, "23.mov")
        XCTAssertEqual(queue.last?.fileName, "4.mov")
    }

    func testProgressIsClampedAndDoesNotRegressAfterCompletion() {
        let activity = makeActivity(index: 1)
        var queue = [activity]

        queue = AppState.updatingUploadProgress(
            id: activity.id, fraction: 1.4, in: queue
        )
        XCTAssertEqual(queue[0].progress, 1, accuracy: 0.0001)

        queue = AppState.finishingUploadActivity(
            id: activity.id, succeeded: true, in: queue
        )
        queue = AppState.updatingUploadProgress(
            id: activity.id, fraction: 0.4, in: queue
        )
        XCTAssertEqual(queue[0].progress, 1, accuracy: 0.0001)
        XCTAssertEqual(queue[0].state, .completed)
    }

    func testFailureRetainsLastRealProgressAndMarksFailed() {
        let activity = makeActivity(index: 2)
        var queue = AppState.updatingUploadProgress(
            id: activity.id, fraction: 0.42, in: [activity]
        )
        queue = AppState.finishingUploadActivity(
            id: activity.id, succeeded: false, in: queue
        )

        XCTAssertEqual(queue[0].progress, 0.42, accuracy: 0.0001)
        XCTAssertEqual(queue[0].state, .failed)
    }

    func testURLSessionProgressFractionUsesExpectedBytes() {
        XCTAssertNil(UploadProgressMath.fraction(sent: 1, expected: 0))
        XCTAssertEqual(UploadProgressMath.fraction(sent: 25, expected: 100)!,
                       0.25, accuracy: 0.0001)
        XCTAssertEqual(UploadProgressMath.fraction(sent: 130, expected: 100)!,
                       1, accuracy: 0.0001)
    }

    private func makeActivity(index: Int) -> AppState.UploadActivity {
        AppState.UploadActivity(
            id: UUID(),
            fileName: "\(index).mov",
            taskId: "task-\(index)",
            taskTitle: "Tarefa \(index)",
            progress: 0,
            state: .uploading
        )
    }
}
