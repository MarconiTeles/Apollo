import XCTest
@testable import DayPanel

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
}
