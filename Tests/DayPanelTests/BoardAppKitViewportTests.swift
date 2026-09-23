import AppKit
import XCTest
@testable import ApolloRuntime

/// Behaviour of the AppKit board viewport in a real (offscreen) window:
/// virtualization, reuse, per-column offsets, selection and the reference
/// drop semantics. Pure CPU; no display is required.
@MainActor
final class BoardAppKitViewportTests: XCTestCase {

    private final class Recorder {
        var orders: [String: [String]] = [:]
        var offsets: [CGFloat] = []
        var cleared = 0
        var activated: [(String, NSEvent.ModifierFlags)] = []
    }

    private struct Harness {
        let window: NSWindow
        let view: BoardViewportView
        let coordinator: BoardAppKitCoordinator
        let recorder: Recorder
        let appState: AppState
    }

    static let statuses = ApolloPreviewFixtures.statuses

    private func tasks(_ n: Int) -> [CUTask] {
        ApolloBoardFixtureGenerator.tasks(count: n)
    }

    private func makeHarness(tasks: [CUTask], size: NSSize = NSSize(width: 1200, height: 800)) -> Harness {
        let appState = AppState(previewMode: true)
        appState.tasks = tasks
        let recorder = Recorder()
        let actions = BoardAppKitActions(
            activate: { task, modifiers, _ in recorder.activated.append((task.id, modifiers)) },
            clearSelection: { recorder.cleared += 1 },
            draggedIds: { [$0.id] },
            dragPreviewTasks: { [$0] },
            contextActions: { _ in [] },
            setColumnOrder: { key, ids in recorder.orders[key] = ids },
            horizontalOffset: { recorder.offsets.append($0) })
        let coordinator = BoardAppKitCoordinator(appState: appState, actions: actions)
        let view = BoardViewportView(coordinator: coordinator)
        coordinator.viewport = view
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        return Harness(window: window, view: view, coordinator: coordinator,
                       recorder: recorder, appState: appState)
    }

    private func snapshot(_ tasks: [CUTask], order: [String: [String]] = [:]) -> BoardRenderSnapshot {
        BoardRenderSnapshot.make(tasks: tasks, activeListId: tasks.first?.listId ?? "",
                                 statuses: Self.statuses, showSubtasks: true, filters: TaskFilters(),
                                 cardOrder: order, workspaceName: "Moon Ventures", isColdLoading: false)
    }

    func testHeaderRejectsHitTestingButKeepsContentInteractive() {
        let h = makeHarness(tasks: [])
        h.coordinator.apply(snapshot: snapshot([]), selected: [],
                            headerChromeHeight: 100, force: true)
        // Simulate a card scrolled beneath the header, spanning its boundary.
        let card = NSView(frame: NSRect(x: 300, y: 20, width: 200, height: 160))
        h.view.addSubview(card)
        let covered = NSPoint(x: 350, y: 60)
        let exposed = NSPoint(x: 350, y: 140)
        XCTAssertNil(h.view.hitTest(h.view.convert(covered, to: h.view.superview)))
        XCTAssertTrue(h.view.hitTest(h.view.convert(exposed, to: h.view.superview)) === card)
        XCTAssertTrue(card.isBehindPageHeader(windowPoint: h.view.convert(covered, to: nil)))
        XCTAssertFalse(card.isBehindPageHeader(windowPoint: h.view.convert(exposed, to: nil)))
        // A route/header geometry update must change the boundary immediately.
        h.coordinator.apply(snapshot: snapshot([]), selected: [],
                            headerChromeHeight: 50, force: false)
        XCTAssertTrue(h.view.hitTest(h.view.convert(covered, to: h.view.superview)) === card)
        h.window.close()
    }

    // MARK: Virtualization and reuse

    func testLiveViewsAreBoundedByViewportNotByTaskCount() {
        for count in [169, 1_000, 5_000] {
            let all = tasks(count)
            let h = makeHarness(tasks: all)
            let snap = snapshot(all)
            h.coordinator.apply(snapshot: snap, selected: [], headerChromeHeight: 100, force: true)
            XCTAssertEqual(snap.orderedTaskIds.count, all.filter { !$0.isCompleted && !$0.archived }.count)
            // All status columns stay mounted; cards are virtualized per column.
            XCTAssertEqual(h.coordinator.mountedColumnCount, Self.statuses.count, "count \(count)")
            XCTAssertLessThanOrEqual(h.coordinator.liveCardViews, Self.statuses.count * 20, "count \(count)")
            print("BOARD_VIRT count=\(count) live=\(h.coordinator.liveCardViews) columns=\(h.coordinator.mountedColumnCount) created=\(h.coordinator.poolCounters.created)")
        }
    }

    func testRoundTripScrollDoesNotGrowViews() throws {
        let all = tasks(5_000)
        let h = makeHarness(tasks: all)
        h.coordinator.apply(snapshot: snapshot(all), selected: [], headerChromeHeight: 100, force: true)
        let busiest = try XCTUnwrap(snapshot(all).columns.max { $0.cards.count < $1.cards.count })
        h.view.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        let column = try XCTUnwrap(h.coordinator.column(busiest.key)
                                   ?? { () -> BoardColumnView? in
                                       let index = snapshot(all).columns.firstIndex { $0.key == busiest.key }!
                                       h.view.scrollView.contentView.scroll(
                                           to: NSPoint(x: BoardViewportView.columnX(index) - 258, y: 0))
                                       return h.coordinator.column(busiest.key)
                                   }())
        var maxLive = 0
        for pass in 0..<2 {
            for step in stride(from: 0, through: 60_000, by: 97) { column.verticalOffset = CGFloat(step) }
            for step in stride(from: 60_000, through: 0, by: -113) { column.verticalOffset = CGFloat(step) }
            maxLive = max(maxLive, h.coordinator.liveCardViews)
            if pass == 0 { continue }
        }
        let createdAfterFirst = h.coordinator.poolCounters.created
        for step in stride(from: 0, through: 60_000, by: 89) { column.verticalOffset = CGFloat(step) }
        XCTAssertEqual(h.coordinator.poolCounters.created, createdAfterFirst,
                       "steady-state scrolling must only reuse")
        XCTAssertLessThanOrEqual(maxLive, Self.statuses.count * 20)
        print("BOARD_ROUNDTRIP created=\(h.coordinator.poolCounters.created) reused=\(h.coordinator.poolCounters.reused) maxLive=\(maxLive)")
    }

    // MARK: Offsets and horizontal relay

    func testColumnOffsetSurvivesHorizontalScrollAndIsNotTransferred() throws {
        let all = tasks(1_000)
        let h = makeHarness(tasks: all, size: NSSize(width: 700, height: 800))
        let snap = snapshot(all)
        h.coordinator.apply(snapshot: snap, selected: [], headerChromeHeight: 100, force: true)
        let first = try XCTUnwrap(h.coordinator.column(snap.columns[0].key))
        first.verticalOffset = 900
        // Scroll far right and back: no column is rebuilt, offsets stay per status.
        let far = BoardViewportView.documentWidth(columns: snap.columns.count)
        let created = h.coordinator.poolCounters.created
        h.view.scrollView.contentView.scroll(to: NSPoint(x: far - 700, y: 0))
        XCTAssertEqual(h.coordinator.poolCounters.created, created, "horizontal scroll must not create cards")
        let last = try XCTUnwrap(h.coordinator.column(snap.columns.last!.key))
        XCTAssertEqual(last.verticalOffset, 0, "a remounted column must not inherit another offset")
        h.view.scrollView.contentView.scroll(to: .zero)
        XCTAssertEqual(try XCTUnwrap(h.coordinator.column(snap.columns[0].key)).verticalOffset, 900)
        // SwiftUI contentOffset.x semantics: −258 at rest.
        XCTAssertEqual(h.recorder.offsets.last, -258)
        XCTAssertEqual(h.view.contentOffsetX, -258)
    }

    // MARK: Selection and reuse hygiene

    func testSelectionAppliesToVisibleCardsAndNeverLeaksThroughReuse() throws {
        let all = tasks(1_000)
        let h = makeHarness(tasks: all)
        let snap = snapshot(all)
        let col = snap.columns[0]
        let selectedId = col.cards[0].id
        h.coordinator.apply(snapshot: snap, selected: [selectedId], headerChromeHeight: 100, force: true)
        let column = try XCTUnwrap(h.coordinator.column(col.key))
        XCTAssertEqual(column.cardView(for: selectedId)?.isSelected, true)
        XCTAssertEqual(column.cardView(for: col.cards[1].id)?.isSelected, false)
        // Scroll the selected card away; reused views must not keep selection.
        column.verticalOffset = 20_000
        for id in col.cards.map(\.id) where id != selectedId {
            if let card = column.cardView(for: id) { XCTAssertFalse(card.isSelected, id) }
        }
        column.verticalOffset = 0
        XCTAssertEqual(column.cardView(for: selectedId)?.isSelected, true)
        h.coordinator.apply(snapshot: snap, selected: [], headerChromeHeight: 100, force: false)
        XCTAssertEqual(column.cardView(for: selectedId)?.isSelected, false)
    }

    func testCardClickReportsTaskAndModifiers() throws {
        let all = tasks(169)
        let h = makeHarness(tasks: all)
        let snap = snapshot(all)
        h.coordinator.apply(snapshot: snap, selected: [], headerChromeHeight: 100, force: true)
        let col = snap.columns[0]
        let card = try XCTUnwrap(h.coordinator.column(col.key)?.cardView(for: col.cards[0].id))
        h.coordinator.cardActivated(card, modifiers: [.command])
        XCTAssertEqual(h.recorder.activated.first?.0, col.cards[0].id)
        XCTAssertEqual(h.recorder.activated.first?.1, [.command])
    }

    // MARK: Drop semantics (reference delegates)

    func testSameColumnHoverReordersLiveAndCrossColumnLightsDestination() throws {
        let all = tasks(169)
        let h = makeHarness(tasks: all)
        let snap = snapshot(all)
        h.coordinator.apply(snapshot: snap, selected: [], headerChromeHeight: 100, force: true)
        let source = try XCTUnwrap(snap.columns.first { $0.cards.count >= 3 })
        let column = try XCTUnwrap(h.coordinator.column(source.key))
        let dragged = try XCTUnwrap(column.cardView(for: source.cards[2].id))
        let payload = try XCTUnwrap(h.coordinator.cardDragPayload(dragged))
        XCTAssertEqual(MyTasksDragPayload.decode(payload.payload), [source.cards[2].id])
        XCTAssertEqual(h.coordinator.currentDraggingIds, [source.cards[2].id])
        XCTAssertTrue(dragged.isDragSource)

        // Entering card 0 of the same column → live reorder before it, no wash.
        _ = h.coordinator.columnDragUpdated(column, cardId: source.cards[0].id, payload: payload.payload)
        XCTAssertEqual(h.recorder.orders[source.key]?.prefix(2).map { $0 },
                       [source.cards[2].id, source.cards[0].id])
        XCTAssertNil(h.coordinator.currentDragOverStatus)

        // Moving to the column background lights the own column (reference quirk).
        _ = h.coordinator.columnDragUpdated(column, cardId: nil, payload: payload.payload)
        XCTAssertEqual(h.coordinator.currentDragOverStatus, source.key)

        // Another mounted column: entering one of its cards lights it.
        let other = try XCTUnwrap(snap.columns.first { $0.key != source.key && !$0.cards.isEmpty
            && h.coordinator.column($0.key) != nil })
        let otherView = try XCTUnwrap(h.coordinator.column(other.key))
        h.coordinator.columnDragExited(column)
        XCTAssertNil(h.coordinator.currentDragOverStatus)
        _ = h.coordinator.columnDragUpdated(otherView, cardId: other.cards[0].id, payload: payload.payload)
        XCTAssertEqual(h.coordinator.currentDragOverStatus, other.key)

        // Drop on the gutter (board reset): clears drag state, rejects the drop.
        h.coordinator.resetDropPerformed()
        XCTAssertNil(h.coordinator.currentDragOverStatus)
        XCTAssertTrue(h.coordinator.currentDraggingIds.isEmpty)
        XCTAssertFalse(dragged.isDragSource)
    }

    func testCancelledDragKeepsReferenceStateUntilNextDrop() throws {
        let all = tasks(169)
        let h = makeHarness(tasks: all)
        let snap = snapshot(all)
        h.coordinator.apply(snapshot: snap, selected: [], headerChromeHeight: 100, force: true)
        let col = try XCTUnwrap(snap.columns.first { !$0.cards.isEmpty })
        let card = try XCTUnwrap(h.coordinator.column(col.key)?.cardView(for: col.cards[0].id))
        _ = h.coordinator.cardDragPayload(card)
        h.coordinator.cardDragEnded(card, operation: [])
        // SwiftUI `.onDrag` has no end callback; the reference keeps the
        // source dimmed until a board drop delegate clears it.
        XCTAssertEqual(h.coordinator.currentDraggingIds, [col.cards[0].id])
    }

    // MARK: CPU cost (not frame presentation)

    func testSnapshotAndTileCost() throws {
        for count in [169, 1_000, 5_000] {
            let all = tasks(count)
            BoardTitleCache.shared.lines(for: "warm")
            var t0 = CFAbsoluteTimeGetCurrent()
            let snap = snapshot(all)
            let snapMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            let h = makeHarness(tasks: all)
            t0 = CFAbsoluteTimeGetCurrent()
            h.coordinator.apply(snapshot: snap, selected: [], headerChromeHeight: 100, force: true)
            let firstApplyMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            t0 = CFAbsoluteTimeGetCurrent()
            h.coordinator.apply(snapshot: snap, selected: [], headerChromeHeight: 100, force: false)
            let noopApplyMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            let busiest = try XCTUnwrap(snap.columns.prefix(4).max { $0.cards.count < $1.cards.count })
            let column = try XCTUnwrap(h.coordinator.column(busiest.key))
            var ticks = 0
            t0 = CFAbsoluteTimeGetCurrent()
            for y in stride(from: 0, through: 12_000, by: 6) { column.verticalOffset = CGFloat(y); ticks += 1 }
            let perTickUs = (CFAbsoluteTimeGetCurrent() - t0) * 1_000_000 / Double(ticks)
            print(String(format: "BOARD_COST count=%d snapshot=%.2fms firstApply=%.2fms noopApply=%.2fms scrollTick=%.1fus (column %d cards)",
                         count, snapMs, firstApplyMs, noopApplyMs, perTickUs, busiest.cards.count))
        }
    }
}
