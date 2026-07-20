import XCTest
@testable import ApolloRuntime

final class TaskSelectionTests: XCTestCase {
    private let order = ["a", "b", "c", "d", "e"]

    func testPlainClickOpensWhenSelectionModeIsInactive() {
        let result = TaskSelectionResolver.resolve(
            current: [], anchor: nil, clicked: "c", ordered: order, intent: .plain
        )
        XCTAssertTrue(result.shouldOpen)
        XCTAssertTrue(result.selected.isEmpty)
    }

    func testCommandClickTogglesOneRowAtATime() {
        let added = TaskSelectionResolver.resolve(
            current: ["a"], anchor: "a", clicked: "c", ordered: order, intent: .toggle
        )
        XCTAssertEqual(added.selected, ["a", "c"])
        XCTAssertEqual(added.anchor, "c")

        let removed = TaskSelectionResolver.resolve(
            current: added.selected, anchor: added.anchor,
            clicked: "a", ordered: order, intent: .toggle
        )
        XCTAssertEqual(removed.selected, ["c"])
    }

    func testShiftClickSelectsInclusiveForwardRange() {
        let result = TaskSelectionResolver.resolve(
            current: ["b"], anchor: "b", clicked: "e", ordered: order, intent: .range
        )
        XCTAssertEqual(result.selected, ["b", "c", "d", "e"])
        XCTAssertEqual(result.anchor, "b")
    }

    func testShiftClickSelectsInclusiveReverseRange() {
        let result = TaskSelectionResolver.resolve(
            current: ["d"], anchor: "d", clicked: "b", ordered: order, intent: .range
        )
        XCTAssertEqual(result.selected, ["b", "c", "d"])
    }

    func testDragPayloadRoundTripsMultipleTaskIdsAndAcceptsBoardId() {
        let ids = ["task-1", "task-2", "task-3"]
        XCTAssertEqual(MyTasksDragPayload.decode(MyTasksDragPayload.encode(ids)), ids)
        XCTAssertEqual(MyTasksDragPayload.decode("single-board-task"), ["single-board-task"])
    }

    func testDraggingUnselectedTaskIsTransientAndDoesNotCarrySelection() {
        XCTAssertEqual(
            TaskDragSelectionResolver.draggedIDs(
                dragged: "d", selected: ["a", "b"], ordered: order
            ),
            ["d"]
        )
    }

    func testDraggingSelectedTaskCarriesSelectionInVisibleOrder() {
        XCTAssertEqual(
            TaskDragSelectionResolver.draggedIDs(
                dragged: "d", selected: ["b", "d", "e"], ordered: order
            ),
            ["b", "d", "e"]
        )
    }

    func testTaskDragActivatesOnlyAfterFortyMilliseconds() {
        XCTAssertFalse(TaskDragActivation.isReady(mouseDownTimestamp: 10,
                                                   currentTimestamp: 10.039))
        XCTAssertTrue(TaskDragActivation.isReady(mouseDownTimestamp: 10,
                                                  currentTimestamp: 10.040))
        XCTAssertTrue(TaskDragActivation.isReady(mouseDownTimestamp: 10,
                                                  currentTimestamp: 10.100))
    }

    func testHomeInboxExcludesConnectionAndSyncHealthEntries() {
        for title in ["Sem conexão", "De volta ao online", "Falha na sincronização"] {
            let notification = AppNotification(kind: .warning, title: title)
            XCTAssertFalse(notification.isHomeInboxEligible)
        }
        XCTAssertTrue(AppNotification(kind: .info,
                                      title: "Review atualizado",
                                      targetKind: .review,
                                      targetId: "review-1").isHomeInboxEligible)
    }

    func testReviewNotificationAliasesCollapseToNewestLogicalReview() {
        let stable = AppNotification(
            date: Date(timeIntervalSince1970: 10),
            kind: .info,
            title: "Review atualizado",
            message: "BODY BALDA · V3.mov",
            targetKind: .review,
            targetId: "attachment-v3"
        )
        let replacement = AppNotification(
            date: Date(timeIntervalSince1970: 20),
            kind: .info,
            title: "Review atualizado",
            message: "THE_MINIMAL_V03 · V4.mov",
            targetKind: .review,
            targetId: "attachment-v4"
        )
        let task = AppNotification(
            kind: .success,
            title: "Tarefa atualizada",
            targetKind: .task,
            targetId: "task-1"
        )

        let normalized = AppNotification.normalizingReviewTargets(
            in: [replacement, stable, task]
        ) { target in
            ["attachment-v3", "attachment-v4"].contains(target)
                ? "attachment-v3"
                : nil
        }

        XCTAssertEqual(normalized.count, 2)
        XCTAssertEqual(normalized[0].message, "THE_MINIMAL_V03 · V4.mov")
        XCTAssertEqual(normalized[0].targetId, "attachment-v3")
        XCTAssertEqual(normalized[1], task)
    }
}
