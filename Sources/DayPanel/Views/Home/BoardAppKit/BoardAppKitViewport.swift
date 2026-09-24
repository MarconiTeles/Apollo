import AppKit
import Combine
import SwiftUI

/// Actions the SwiftUI shell exposes to the AppKit board. Selection, detail
/// navigation, context menus and the persisted local order stay owned by
/// `EditorialBoardView`; the viewport only reports user intent.
struct BoardAppKitActions {
    var activate: (_ task: CUTask, _ modifiers: NSEvent.ModifierFlags, _ rect: CGRect) -> Void
    var clearSelection: () -> Void
    var draggedIds: (_ task: CUTask) -> [String]
    var dragPreviewTasks: (_ task: CUTask) -> [CUTask]
    var contextActions: (_ task: CUTask) -> [TaskContextAction]
    /// Writes the local order for `statusKey` (never synced to ClickUp).
    var setColumnOrder: (_ statusKey: String, _ ids: [String]) -> Void
    var horizontalOffset: (_ contentOffsetX: CGFloat) -> Void
}

/// AppKit replacement of the reference board's scrolling content only:
/// horizontal document + status columns + cards. Header, labels, toolbar,
/// materials and popups remain the SwiftUI shell.
struct BoardAppKitViewport: NSViewRepresentable {
    let snapshot: BoardRenderSnapshot
    let selectedTaskIds: Set<String>
    let headerChromeHeight: CGFloat
    let appState: AppState
    let actions: BoardAppKitActions

    func makeCoordinator() -> BoardAppKitCoordinator {
        BoardAppKitCoordinator(appState: appState, actions: actions)
    }

    func makeNSView(context: Context) -> BoardViewportView {
        let view = BoardViewportView(coordinator: context.coordinator)
        context.coordinator.viewport = view
        context.coordinator.apply(snapshot: snapshot, selected: selectedTaskIds,
                                  headerChromeHeight: headerChromeHeight, force: true)
        return view
    }

    func updateNSView(_ view: BoardViewportView, context: Context) {
        context.coordinator.actions = actions
        context.coordinator.appState = appState
        context.coordinator.apply(snapshot: snapshot, selected: selectedTaskIds,
                                  headerChromeHeight: headerChromeHeight, force: false)
    }
}

/// Horizontal board document. Columns keep the reference geometry:
/// 258pt leading content margin, 260pt columns, 20pt gaps, 28pt trailing.
@MainActor
final class BoardDocumentView: NSView {
    override var isFlipped: Bool { true }
    weak var coordinator: BoardAppKitCoordinator?

    /// Board background tap → clear selection (reference `.onTapGesture`).
    override func mouseDown(with event: NSEvent) {
        coordinator?.actions.clearSelection()
    }

    // Catch-all drop target (reference `BoardResetDropDelegate`).
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .move }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .move }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        coordinator?.resetDropPerformed()
        return false
    }
    override func wantsPeriodicDraggingUpdates() -> Bool { false }
}

@MainActor
final class BoardViewportView: NSView, HeaderOccludingViewport {
    var headerOcclusionHeight: CGFloat = 0
    override var isFlipped: Bool { true }
    static let leadingMargin: CGFloat = 258
    static let trailingMargin: CGFloat = 28
    static let columnWidth: CGFloat = 260
    static let columnGap: CGFloat = 20

    let scrollView = NSScrollView()
    let document = BoardDocumentView()
    private weak var coordinator: BoardAppKitCoordinator?
    private var boundsObserver: NSObjectProtocol?

    init(coordinator: BoardAppKitCoordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.drawsBackground = false
        document.coordinator = coordinator
        document.wantsLayer = true
        document.registerForDraggedTypes([.string])
        scrollView.documentView = document
        addSubview(scrollView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.horizontalBoundsChanged() }
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Quadro")
    }

    required init?(coder: NSCoder) { nil }

    static func columnX(_ index: Int) -> CGFloat {
        leadingMargin + CGFloat(index) * (columnWidth + columnGap)
    }

    static func documentWidth(columns: Int) -> CGFloat {
        guard columns > 0 else { return leadingMargin + trailingMargin }
        return columnX(columns - 1) + columnWidth + trailingMargin
    }

    override func layout() {
        super.layout()
        if scrollView.frame != bounds {
            scrollView.frame = bounds
            coordinator?.viewportResized()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let windowPoint = superview?.convert(point, to: nil) ?? point
        guard !isBehindPageHeader(windowPoint: windowPoint) else { return nil }
        return super.hitTest(point)
    }

    /// SwiftUI `ScrollGeometry.contentOffset.x` equivalent: the offset
    /// relative to the content start (negative by the leading margin at rest).
    var contentOffsetX: CGFloat {
        scrollView.contentView.bounds.minX - Self.leadingMargin
    }

    private func horizontalBoundsChanged() {
        coordinator?.horizontalScrolled()
    }
}

// MARK: - Coordinator

@MainActor
final class BoardAppKitCoordinator: NSObject, BoardCardViewDelegate, BoardColumnViewDelegate {
    var appState: AppState
    var actions: BoardAppKitActions
    weak var viewport: BoardViewportView?

    let pool = BoardCardPool()
    private(set) var snapshot = BoardRenderSnapshot.empty
    private var selectedIds: Set<String> = []
    private var metrics = BoardColumnMetrics(headerChromeHeight: 140)
    private var mounted: [String: BoardColumnView] = [:]
    /// Vertical offsets by status key while a column is unmounted.
    private var savedOffsets: [String: CGFloat] = [:]
    private var popupCancellable: AnyCancellable?

    // Drag state mirrors the reference @State: draggingTaskId,
    // draggingTaskIds and dragOverStatus.
    private var draggingTaskId: String?
    private var draggingTaskIds: [String] = []
    private var dragOverStatus: String?
    /// Active nested target, reproducing SwiftUI's enter/exit sequence
    /// between the card-level and column-level drop delegates.
    private enum DropTarget: Equatable { case card(String, column: String), column(String) }
    private var dropTarget: DropTarget?
    private var animateNextOrderChange = false

    init(appState: AppState, actions: BoardAppKitActions) {
        self.appState = appState
        self.actions = actions
        super.init()
        popupCancellable = appState.$anyPopupOpen
            .removeDuplicates()
            .sink { open in
                if open { MainActor.assumeIsolated { BoardCardView.resetActiveHover() } }
            }
    }

    var cardDelegate: BoardCardViewDelegate? { self }
    var workspaceName: String { snapshot.workspaceName }
    var isPopupOpen: Bool { appState.anyPopupOpen }

    // MARK: Snapshot application

    func apply(snapshot new: BoardRenderSnapshot, selected: Set<String>,
               headerChromeHeight: CGFloat, force: Bool) {
        BoardInstrumentation.interval("BoardApply") {
            applyUnsigned(snapshot: new, selected: selected,
                          headerChromeHeight: headerChromeHeight, force: force)
        }
    }

    private func applyUnsigned(snapshot new: BoardRenderSnapshot, selected: Set<String>,
                               headerChromeHeight: CGFloat, force: Bool) {
        BoardInstrumentation.counters.applies += 1
        startCounterLogIfNeeded()
        viewport?.headerOcclusionHeight = headerChromeHeight
        let newMetrics = BoardColumnMetrics(headerChromeHeight: headerChromeHeight)
        let columnsChanged = force || new != snapshot || newMetrics != metrics
        let selectionChanged = selected != selectedIds
        let workspaceChanged = new.workspaceName != snapshot.workspaceName
        let animated = animateNextOrderChange
        animateNextOrderChange = false
        if columnsChanged {
            let oldKeys = snapshot.columns.map(\.key)
            snapshot = new
            metrics = newMetrics
            selectedIds = selected
            layoutDocument(columnSetChanged: oldKeys != new.columns.map(\.key), animated: animated)
            if workspaceChanged { mounted.values.forEach { $0.rebindAll(workspaceChanged: true) } }
        }
        if selectionChanged {
            selectedIds = selected
            mounted.values.forEach { $0.refreshInteractionStates(animated: true) }
        }
    }

    func viewportResized() { layoutDocument(columnSetChanged: false, animated: false) }

    func horizontalScrolled() {
        if let viewport { actions.horizontalOffset(viewport.contentOffsetX) }
    }

    private func layoutDocument(columnSetChanged: Bool, animated: Bool) {
        guard let viewport else { return }
        let height = viewport.bounds.height
        let width = BoardViewportView.documentWidth(columns: snapshot.columns.count)
        let size = NSSize(width: width, height: height)
        if viewport.document.frame.size != size { viewport.document.setFrameSize(size) }
        if columnSetChanged {
            // Remount by key: a recycled column must never inherit another
            // status' scroll position.
            for (key, column) in mounted {
                savedOffsets[key] = column.verticalOffset
                column.removeFromSuperview()
            }
            mounted.removeAll()
        }
        mountVisibleColumns(animated: animated)
        // Layout-driven offset changes arrive during a SwiftUI update; hand
        // them to the labels relay on the next turn. Scroll ticks stay
        // synchronous (see `horizontalScrolled`).
        let offset = viewport.contentOffsetX
        DispatchQueue.main.async { [weak self] in self?.actions.horizontalOffset(offset) }
    }

    /// Every status column stays mounted (there are only a handful); only
    /// their cards are virtualized. Horizontal scrolling therefore never
    /// creates, binds or diffs anything — it just moves one clip view.
    private func mountVisibleColumns(animated: Bool = false) {
        guard let viewport else { return }
        let height = viewport.bounds.height
        var wanted = Set<String>()
        for (index, column) in snapshot.columns.enumerated() {
            let frame = NSRect(x: BoardViewportView.columnX(index), y: 0,
                               width: BoardViewportView.columnWidth, height: height)
            wanted.insert(column.key)
            if let view = mounted[column.key] {
                if view.frame != frame { view.frame = frame }
                view.update(snapshot: column, metrics: metrics,
                            isColdLoading: snapshot.isColdLoading, animated: animated)
            } else {
                let view = BoardColumnView(snapshot: column, metrics: metrics,
                                           isColdLoading: snapshot.isColdLoading)
                view.delegate = self
                view.frame = frame
                viewport.document.addSubview(view)
                view.layoutSubtreeIfNeeded()
                if let offset = savedOffsets[column.key] { view.verticalOffset = offset }
                view.tile()
                view.setDropTarget(dragOverStatus == column.key)
                mounted[column.key] = view
            }
        }
        for (key, view) in mounted where !wanted.contains(key) {
            savedOffsets[key] = view.verticalOffset
            view.removeFromSuperview()
            mounted[key] = nil
        }
    }

    // MARK: Diagnostics (DEV instrumentation)

    private var counterTimer: Timer?

    private func startCounterLogIfNeeded() {
        #if APOLLO_DEV
        guard counterTimer == nil else { return }
        counterTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.viewport?.window != nil else { timer.invalidate(); return }
                let c = BoardInstrumentation.counters
                BoardInstrumentation.log.info(
                    "board counters liveCards=\(self.liveCardViews) mountedColumns=\(self.mountedColumnCount) created=\(self.pool.created) reused=\(self.pool.reused) applies=\(c.applies) columnUpdates=\(c.columnUpdates) tiles=\(c.tiles) binds=\(c.binds) heightRecomputes=\(c.heightRecomputes) cards=\(self.snapshot.orderedTaskIds.count)")
            }
        }
        #endif
    }

    func column(_ key: String) -> BoardColumnView? { mounted[key] }
    var currentDragOverStatus: String? { dragOverStatus }
    var currentDraggingIds: [String] { draggingTaskIds }

    var liveCardViews: Int { mounted.values.reduce(0) { $0 + $1.liveCardCount } }
    var mountedColumnCount: Int { mounted.count }
    var poolCounters: (created: Int, reused: Int) { (pool.created, pool.reused) }

    // MARK: BoardColumnViewDelegate

    func isSelected(_ id: String) -> Bool { selectedIds.contains(id) }
    func isDragSource(_ id: String) -> Bool { draggingTaskIds.contains(id) }
    func columnBackgroundClicked(_ column: BoardColumnView) { actions.clearSelection() }
    func columnDidScroll(_ column: BoardColumnView) {}

    // MARK: BoardCardViewDelegate

    func cardActivated(_ card: BoardCardView, modifiers: NSEvent.ModifierFlags) {
        guard let task = card.task else { return }
        let rect = MouseOriginCapture.rectInMainWindow(for: card)
        actions.activate(task, modifiers,
                         rect == .zero ? MouseOriginCapture.currentClickRectInMainWindow() : rect)
    }

    func cardDragPayload(_ card: BoardCardView) -> (payload: String, image: NSImage, frame: NSRect)? {
        guard let task = card.task else { return nil }
        let ids = actions.draggedIds(task)
        guard !ids.isEmpty else { return nil }
        draggingTaskId = task.id
        draggingTaskIds = ids
        refreshDragSources()
        let preview = BoardDragPreview.image(tasks: actions.dragPreviewTasks(task), primary: task)
        // SwiftUI centres the custom preview under the pointer.
        let pointer = card.convert(NSApplication.shared.currentEvent?.locationInWindow ?? .zero, from: nil)
        let frame = NSRect(x: pointer.x - preview.size.width / 2,
                           y: pointer.y - preview.size.height / 2,
                           width: preview.size.width, height: preview.size.height)
        return (MyTasksDragPayload.encode(ids), preview, frame)
    }

    func cardDragEnded(_ card: BoardCardView, operation: NSDragOperation) {
        // The SwiftUI reference has no drag-end callback: a gesture cancelled
        // outside every board drop target leaves the drag state untouched until
        // the next drop. Only drop delegates below clear it.
        dropTarget = nil
    }

    func cardContextActions(_ card: BoardCardView) -> [TaskContextAction] {
        guard let task = card.task else { return [] }
        return actions.contextActions(task)
    }

    private func refreshDragSources() {
        mounted.values.forEach { $0.refreshInteractionStates(animated: true) }
    }

    private func setDragOverStatus(_ key: String?) {
        guard dragOverStatus != key else { return }
        let old = dragOverStatus
        dragOverStatus = key
        if let old { mounted[old]?.setDropTarget(false) }
        if let key { mounted[key]?.setDropTarget(true) }
    }

    private func clearDragState() {
        draggingTaskId = nil
        draggingTaskIds.removeAll()
        refreshDragSources()
    }

    // MARK: Drop destination (reference delegates)

    private func draggedStatusKey() -> String? {
        guard let id = draggingTaskId,
              let t = appState.tasks.first(where: { $0.id == id }) else { return nil }
        return t.status.lowercased()
    }

    func columnDragUpdated(_ column: BoardColumnView, cardId: String?, payload: String?) -> NSDragOperation {
        guard payload != nil else { return [] }
        let key = column.snapshot.key
        let target: DropTarget = cardId.map { .card($0, column: key) } ?? .column(key)
        if target != dropTarget {
            exit(dropTarget)
            dropTarget = target
            enter(target)
        }
        return .move
    }

    func columnDragExited(_ column: BoardColumnView) {
        exit(dropTarget)
        dropTarget = nil
    }

    private func enter(_ target: DropTarget?) {
        switch target {
        case .card(let id, let key):
            // CardReorderDropDelegate.dropEntered
            if draggedStatusKey() == key {
                reorder(dragInFrontOf: id, statusKey: key)
            } else {
                setDragOverStatus(key)
            }
        case .column(let key):
            // BoardDropDelegate.dropEntered
            setDragOverStatus(key)
        case nil:
            break
        }
    }

    private func exit(_ target: DropTarget?) {
        // Only the column delegate implements dropExited.
        if case .column(let key)? = target, dragOverStatus == key {
            setDragOverStatus(nil)
        }
    }

    private func currentIds(_ key: String) -> [String] {
        snapshot.columns.first { $0.key == key }?.cards.map(\.id) ?? []
    }

    private func reorder(dragInFrontOf targetId: String, statusKey: String) {
        guard let ids = BoardOrdering.reorder(ids: currentIds(statusKey),
                                              dragging: draggingTaskIds,
                                              before: targetId) else { return }
        animateNextOrderChange = true
        actions.setColumnOrder(statusKey, ids)
    }

    func columnPerformDrop(_ column: BoardColumnView, cardId: String?, payload: String?) -> Bool {
        let status = column.snapshot.status
        let key = column.snapshot.key
        dropTarget = nil
        if let targetId = cardId {
            // CardReorderDropDelegate.performDrop
            let primaryId = draggingTaskId
            let ids = draggingTaskIds.isEmpty ? primaryId.map { [$0] } ?? [] : draggingTaskIds
            clearDragState()
            setDragOverStatus(nil)
            NotificationCenter.default.post(name: .apolloTaskDropCompleted, object: nil)
            guard !ids.isEmpty else { return false }
            let appState = self.appState
            let needsStatusChange = ids.contains { id in
                appState.tasks.first(where: { $0.id == id })?.status.lowercased() != key
            }
            if needsStatusChange {
                let originals = ids.compactMap { appState.tasksById[$0] }.filter {
                    $0.status.lowercased() != key
                }
                Task { @MainActor [weak self] in
                    let toMove = ids
                        .compactMap { id in appState.tasks.first(where: { $0.id == id }) }
                        .filter { $0.status.lowercased() != key }
                    // Persist the destination order before the optimistic batch
                    // lands, as the reference `onCrossColumnPlace` does.
                    if let self {
                        self.actions.setColumnOrder(key, BoardOrdering.place(ids: self.currentIds(key),
                                                                             dragIds: ids,
                                                                             before: targetId))
                    }
                    await appState.updateTaskStatuses(toMove, to: status, silent: true)
                    appState.pushTaskStatusUndo(originals,
                        label: originals.count == 1
                            ? "Mover tarefa para \(status.status.uppercased())"
                            : "Mover \(originals.count) tarefas para \(status.status.uppercased())")
                }
            }
            return true
        }
        // BoardDropDelegate.performDrop
        clearDragState()
        NotificationCenter.default.post(name: .apolloTaskDropCompleted, object: nil)
        guard let raw = payload else {
            setDragOverStatus(nil)
            return false
        }
        let ids = MyTasksDragPayload.decode(raw)
        let appState = self.appState
        Task { @MainActor [weak self] in
            let toMove = ids
                .compactMap { id in appState.tasks.first(where: { $0.id == id }) }
                .filter { $0.status.lowercased() != status.status.lowercased() }
            let originals = toMove
            await appState.updateTaskStatuses(toMove, to: status, silent: true)
            appState.pushTaskStatusUndo(originals,
                label: originals.count == 1
                    ? "Mover tarefa para \(status.status.uppercased())"
                    : "Mover \(originals.count) tarefas para \(status.status.uppercased())")
            self?.setDragOverStatus(nil)
        }
        return true
    }

    /// BoardResetDropDelegate.performDrop — drop on gutters/margins.
    func resetDropPerformed() {
        exit(dropTarget)
        dropTarget = nil
        clearDragState()
        setDragOverStatus(nil)
    }
}

/// Renders the reference `TaskDragStackPreview` once per drag gesture.
@MainActor
enum BoardDragPreview {
    static func image(tasks: [CUTask], primary: CUTask) -> NSImage {
        let renderer = ImageRenderer(content: TaskDragStackPreview(tasks: tasks, primary: primary,
                                                                   width: 260))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        renderer.isOpaque = false
        return renderer.nsImage ?? NSImage(size: NSSize(width: 260, height: 46))
    }
}
