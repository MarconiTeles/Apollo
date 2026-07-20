import AppKit
import Combine
import SwiftUI

private extension NSView {
    /// CALayer stores an immutable CGColor, so dynamic AppKit/SwiftUI colors
    /// must be resolved while this view's effective appearance is current.
    /// Converting outside this scope freezes the Aqua variant and produces a
    /// white hover row in Dark Aqua.
    func resolvedCGColor(_ color: Color) -> CGColor {
        var result = NSColor(color).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            result = NSColor(color).cgColor
        }
        return result
    }
}

struct MyTasksAppKitSection: Equatable, Identifiable {
    let status: CUStatus
    let tasks: [CUTask]
    let collapsed: Bool

    var id: String { status.id }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.status.id == rhs.status.id
            && lhs.status.status == rhs.status.status
            && lhs.status.displayHex == rhs.status.displayHex
            && lhs.tasks == rhs.tasks
            && lhs.collapsed == rhs.collapsed
    }
}

/// Keeps a normal click distinct from a drag without making the list feel
/// sluggish. AppKit already supplies the movement threshold; this adds only
/// the requested temporal gate before a dragging session may begin.
enum TaskDragActivation {
    static let delay: TimeInterval = 0.04

    static func isReady(mouseDownTimestamp: TimeInterval,
                        currentTimestamp: TimeInterval) -> Bool {
        currentTimestamp >= mouseDownTimestamp + delay
    }
}

/// Pure-AppKit task viewport. Both headers and rows are recycled by
/// NSCollectionView; there is no NSHostingView per task during scrolling.
struct MyTasksAppKitList: NSViewRepresentable {
    @Environment(\.apolloStudioSession) private var studioSession
    let sections: [MyTasksAppKitSection]
    let selectedTaskIds: Set<String>
    let appState: AppState
    var topContentInset: CGFloat = 72
    var bottomContentInset: CGFloat = 112
    let onActivate: (CUTask, NSEvent.ModifierFlags, CGRect) -> Void
    let onToggleStatus: (String) -> Void
    let onBeginDrag: (CUTask) -> [String]
    let onEndDrag: (Bool) -> Void
    let onClearSelection: () -> Void
    let onMediaAction: (CUTask, TaskMediaFlowMode) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        applyInsets(to: scroll)

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        // The top breathing room belongs to the SCROLLING document, not to
        // NSScrollView's clipping inset. It is visible at rest, then scrolls
        // away so rows can genuinely pass underneath the pinned translucent
        // header (Finder behaviour).
        layout.sectionInset = NSEdgeInsets(top: topContentInset,
                                           left: 0, bottom: 0, right: 0)
        layout.itemSize = NSSize(width: 800, height: 44)

        let collection = WidthTrackingCollectionView(frame: .zero)
        collection.collectionViewLayout = layout
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.isSelectable = false
        collection.backgroundColors = [.clear]
        collection.register(MyTasksTaskItem.self,
                            forItemWithIdentifier: MyTasksTaskItem.identifier)
        collection.register(MyTasksHeaderItem.self,
                            forItemWithIdentifier: MyTasksHeaderItem.identifier)
        collection.register(MyTasksDropPlaceholderItem.self,
                            forItemWithIdentifier: MyTasksDropPlaceholderItem.identifier)
        collection.registerForDraggedTypes([.string])
        collection.onResize = { [weak collection] in
            guard let collection,
                  let flow = collection.collectionViewLayout as? NSCollectionViewFlowLayout
            else { return }
            let width = collection.bounds.width
            guard width > 0, abs(flow.itemSize.width - width) > 0.5 else { return }
            flow.itemSize = NSSize(width: width, height: flow.itemSize.height)
            flow.invalidateLayout()
        }
        let background = MyTasksSelectionBackgroundView()
        background.onClearSelection = onClearSelection
        collection.backgroundView = background
        context.coordinator.collection = collection
        scroll.documentView = collection
        context.coordinator.configureStudio(session: studioSession, scrollView: scroll)
        context.coordinator.update(parent: self, force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        applyInsets(to: scroll)
        if let collection = scroll.documentView as? NSCollectionView,
           let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout,
           abs(layout.sectionInset.top - topContentInset) > 0.5 {
            var sectionInset = layout.sectionInset
            sectionInset.top = topContentInset
            layout.sectionInset = sectionInset
            layout.invalidateLayout()
        }
        context.coordinator.update(parent: self)
        context.coordinator.configureStudio(session: studioSession, scrollView: scroll)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.stopStudioReporting()
    }

    private func applyInsets(to scroll: NSScrollView) {
        // A clip-view top inset would reserve an opaque/non-drawing strip and
        // stop rows exactly at the header edge. Keep only the conditional
        // bottom reservation for the floating bulk toolbar.
        let value = NSEdgeInsets(top: 0, left: 0,
                                 bottom: bottomContentInset, right: 0)
        let current = scroll.contentInsets
        if current.top != value.top || current.left != value.left
            || current.bottom != value.bottom || current.right != value.right {
            scroll.contentInsets = value
        }
        let scrollerValue = NSEdgeInsets(top: topContentInset, left: 0,
                                         bottom: bottomContentInset, right: 0)
        let currentScroller = scroll.scrollerInsets
        if currentScroller.top != scrollerValue.top
            || currentScroller.left != scrollerValue.left
            || currentScroller.bottom != scrollerValue.bottom
            || currentScroller.right != scrollerValue.right {
            scroll.scrollerInsets = scrollerValue
        }
    }

    @MainActor
    final class Coordinator: NSObject,
                             NSCollectionViewDataSource,
                             NSCollectionViewDelegateFlowLayout {
        fileprivate enum Row: Equatable {
            case header(status: CUStatus, count: Int, collapsed: Bool, first: Bool)
            case task(CUTask)
            case dropPlaceholder(CUStatus)

            var id: String {
                switch self {
                case .header(let status, _, _, _): return "h:\(status.id)"
                case .task(let task): return "t:\(task.id)"
                case .dropPlaceholder(let status): return "drop:\(status.id)"
                }
            }

            static func == (lhs: Row, rhs: Row) -> Bool {
                switch (lhs, rhs) {
                case let (.header(ls, lc, lx, lf), .header(rs, rc, rx, rf)):
                    return ls.id == rs.id && ls.status == rs.status
                        && ls.displayHex == rs.displayHex
                        && lc == rc && lx == rx && lf == rf
                case let (.task(l), .task(r)): return l == r
                case let (.dropPlaceholder(l), .dropPlaceholder(r)):
                    return l.id == r.id
                default: return false
                }
            }
        }

        private var rows: [Row] = []
        private var selectedIds: Set<String> = []
        private var appState: AppState
        private var onActivate: (CUTask, NSEvent.ModifierFlags, CGRect) -> Void
        private var onToggleStatus: (String) -> Void
        private var onBeginDrag: (CUTask) -> [String]
        private var onEndDrag: (Bool) -> Void
        private var onClearSelection: () -> Void
        private var onMediaAction: (CUTask, TaskMediaFlowMode) -> Void
        private let statusBubble = StatusPickerBubblePresenter()
        private var columnCancellable: AnyCancellable?
        private weak var studioSession: ApolloStudioSession?
        private weak var studioScrollView: NSScrollView?
        private var studioScrollObserver: NSObjectProtocol?
        private let studioOwnerID: StudioNodeID = "tasks.list"
        weak var collection: NSCollectionView?

        init(parent: MyTasksAppKitList) {
            appState = parent.appState
            onActivate = parent.onActivate
            onToggleStatus = parent.onToggleStatus
            onBeginDrag = parent.onBeginDrag
            onEndDrag = parent.onEndDrag
            onClearSelection = parent.onClearSelection
            onMediaAction = parent.onMediaAction
            super.init()
            // Live column resize: when the user drags a divider, mark visible
            // rows dirty so each re-reads the shared metrics on its next layout.
            // The row WIDTH is unchanged (only internal x's), so we deliberately
            // do NOT invalidate the flow layout (that would re-enter onResize).
            columnCancellable = MyTasksColumnLayout.shared.$widths
                .removeDuplicates()
                .sink { [weak self] _ in self?.relayoutVisibleRows() }
        }

        private func relayoutVisibleRows() {
            guard let collection else { return }
            for path in collection.indexPathsForVisibleItems() {
                (collection.item(at: path) as? MyTasksTaskItem)?.view.needsLayout = true
            }
        }

        func configureStudio(session: ApolloStudioSession?, scrollView: NSScrollView) {
            guard studioSession !== session || studioScrollView !== scrollView else {
                reportVisibleStudioNodesSoon()
                return
            }
            stopStudioReporting()
            studioSession = session
            studioScrollView = scrollView
            guard session != nil else { return }
            scrollView.contentView.postsBoundsChangedNotifications = true
            studioScrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.reportVisibleStudioNodes() }
            }
            reportVisibleStudioNodesSoon()
        }

        func stopStudioReporting() {
            if let studioScrollObserver {
                NotificationCenter.default.removeObserver(studioScrollObserver)
            }
            studioScrollObserver = nil
            studioSession?.removeExternalNodes(owner: studioOwnerID)
            studioSession = nil
            studioScrollView = nil
        }

        private func reportVisibleStudioNodesSoon() {
            guard studioSession != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.reportVisibleStudioNodes() }
        }

        private func reportVisibleStudioNodes() {
            guard let studioSession,
                  let collection,
                  let clip = studioScrollView?.contentView
            else { return }
            collection.layoutSubtreeIfNeeded()
            let paths = collection.indexPathsForVisibleItems().sorted { $0.item < $1.item }
            let nodes: [StudioNodeDescriptor] = paths.compactMap { path in
                guard rows.indices.contains(path.item),
                      let attributes = collection.layoutAttributesForItem(at: path)
                else { return nil }
                var frame = collection.convert(attributes.frame, to: clip)
                frame.origin.x -= clip.bounds.minX
                frame.origin.y -= clip.bounds.minY
                switch rows[path.item] {
                case .task(let task):
                    return StudioNodeDescriptor(
                        id: StudioNodeID(rawValue: "tasks.row.\(task.id)"),
                        parentID: studioOwnerID,
                        title: task.title,
                        kind: .row,
                        frame: frame,
                        source: MyTasksNativeRowView.studioSource,
                        properties: [
                            .init(kind: .height, title: "Altura", value: frame.height),
                            .init(kind: .cornerRadius,
                                  title: "Raio hover",
                                  token: "Editorial.notificationCapsuleRadius"),
                        ]
                    )
                case .header(let status, _, _, _):
                    return StudioNodeDescriptor(
                        id: StudioNodeID(rawValue: "tasks.section.\(status.id)"),
                        parentID: studioOwnerID,
                        title: status.status.uppercased(),
                        kind: .header,
                        frame: frame,
                        source: MyTasksHeaderView.studioSource,
                        properties: [
                            .init(kind: .height, title: "Altura", value: frame.height),
                        ]
                    )
                case .dropPlaceholder:
                    return nil
                }
            }
            studioSession.replaceExternalNodes(owner: studioOwnerID, nodes: nodes)
        }

        func update(parent: MyTasksAppKitList, force: Bool = false) {
            appState = parent.appState
            onActivate = parent.onActivate
            onToggleStatus = parent.onToggleStatus
            onBeginDrag = parent.onBeginDrag
            onEndDrag = parent.onEndDrag
            onClearSelection = parent.onClearSelection
            onMediaAction = parent.onMediaAction
            (collection?.backgroundView as? MyTasksSelectionBackgroundView)?
                .onClearSelection = onClearSelection
            let newRows = Self.flatten(parent.sections)
            let contentChanged = rows != newRows
            let selectionChanged = selectedIds != parent.selectedTaskIds
            selectedIds = parent.selectedTaskIds
            guard force || contentChanged || selectionChanged else { return }

            if contentChanged {
                let idsStable = rows.map(\.id) == newRows.map(\.id)
                let oldIds = rows.map(\.id)
                let nextIds = newRows.map(\.id)
                let oldSet = Set(oldIds)
                let nextSet = Set(nextIds)
                let survivingOld = oldIds.filter(nextSet.contains)
                let survivingNew = nextIds.filter(oldSet.contains)
                let canAnimateInsertDelete = !force
                    && survivingOld == survivingNew
                    && oldIds != nextIds

                if idsStable {
                    rows = newRows
                    rebindVisibleCells()
                } else if canAnimateInsertDelete, let collection {
                    let removed = Set(oldIds.enumerated().compactMap { index, id in
                        nextSet.contains(id) ? nil : IndexPath(item: index, section: 0)
                    })
                    let inserted = Set(nextIds.enumerated().compactMap { index, id in
                        oldSet.contains(id) ? nil : IndexPath(item: index, section: 0)
                    })
                    rows = newRows
                    collection.performBatchUpdates {
                        if !removed.isEmpty { collection.deleteItems(at: removed) }
                        if !inserted.isEmpty { collection.insertItems(at: inserted) }
                    } completionHandler: { [weak self] _ in
                        self?.rebindVisibleCells()
                    }
                } else {
                    rows = newRows
                    collection?.reloadData()
                }
            } else {
                rebindVisibleCells()
            }
            reportVisibleStudioNodesSoon()
        }

        private static func flatten(_ sections: [MyTasksAppKitSection]) -> [Row] {
            var result: [Row] = []
            result.reserveCapacity(sections.reduce(0) { $0 + $1.tasks.count + 1 })
            for (index, section) in sections.enumerated() {
                result.append(.header(status: section.status,
                                      count: section.tasks.count,
                                      collapsed: section.collapsed,
                                      first: index == 0))
                if !section.collapsed {
                    result.append(contentsOf: section.tasks.map(Row.task))
                }
            }
            return result
        }

        private func rebindVisibleCells() {
            guard let collection else { return }
            for path in collection.indexPathsForVisibleItems() where path.item < rows.count {
                switch rows[path.item] {
                case .header(let status, let count, let collapsed, let first):
                    (collection.item(at: path) as? MyTasksHeaderItem)?.bind(
                        status: status, count: count, collapsed: collapsed, first: first,
                        onToggle: { [weak self] in self?.onToggleStatus(status.status.lowercased()) })
                case .task(let task):
                    if let item = collection.item(at: path) as? MyTasksTaskItem {
                        configure(item, task: task)
                    }
                case .dropPlaceholder(let status):
                    (collection.item(at: path) as? MyTasksDropPlaceholderItem)?
                        .bind(status: status)
                }
            }
        }

        private func configure(_ item: MyTasksTaskItem, task: CUTask) {
            item.bind(task: task, appState: appState)
            item.setBulkSelected(selectedIds.contains(task.id))
            item.onRowClick = { [weak self] task, rect in
                self?.onActivate(task, NSEvent.modifierFlags, rect)
            }
            item.onBeginDrag = { [weak self] task in
                guard let self else { return nil }
                let ids = self.onBeginDrag(task)
                return ids.isEmpty ? nil : MyTasksDragPayload.encode(ids)
            }
            item.onEndDrag = { [weak self] completed in
                self?.clearDropPreview(animated: true)
                self?.onEndDrag(completed)
            }
            item.onRequestStatusPicker = { [weak self] task, anchor in
                self?.showStatusPicker(task: task, anchor: anchor)
            }
            item.onMediaAction = { [weak self] task, mode in
                self?.onMediaAction(task, mode)
            }
            item.contextActionsProvider = { [weak self] clicked in
                guard let self else { return nil }
                guard self.selectedIds.contains(clicked.id) else {
                    return TaskContextMenu.actions(for: clicked, appState: self.appState)
                }
                let selected = self.rows.compactMap { row -> CUTask? in
                    guard case .task(let task) = row,
                          self.selectedIds.contains(task.id) else { return nil }
                    return task
                }
                return TaskBulkActions.actions(for: selected, appState: self.appState)
            }
        }

        private func showStatusPicker(task: CUTask, anchor: NSView) {
            statusBubble.show(statuses: appState.availableStatuses,
                              currentStatusName: task.status,
                              anchoredTo: anchor) { [weak self] status in
                guard let self else { return }
                Task { await self.appState.updateTaskStatus(task, to: status) }
            }
        }

        func collectionView(_ collectionView: NSCollectionView,
                            numberOfItemsInSection section: Int) -> Int { rows.count }

        func collectionView(_ collectionView: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            // Durante performBatchUpdates o flow layout ainda consulta index
            // paths do estado PRÉ-batch enquanto `rows` já é o novo array
            // (padrão obrigatório do AppKit). Se a lista encolheu — ex.:
            // envio de mídia hook/body reagrupando linhas — um índice antigo
            // estoura o array e derruba o app (crash 20/jul 17:42). Um item
            // vazio descartável é a resposta segura: o próprio batch o
            // remove/recicla no mesmo passe.
            guard rows.indices.contains(indexPath.item) else {
                return collectionView.makeItem(
                    withIdentifier: MyTasksDropPlaceholderItem.identifier,
                    for: indexPath
                )
            }
            switch rows[indexPath.item] {
            case .header(let status, let count, let collapsed, let first):
                let item = collectionView.makeItem(withIdentifier: MyTasksHeaderItem.identifier,
                                                   for: indexPath) as! MyTasksHeaderItem
                item.bind(status: status, count: count, collapsed: collapsed, first: first,
                          onToggle: { [weak self] in
                              self?.onToggleStatus(status.status.lowercased())
                          })
                return item
            case .task(let task):
                let item = collectionView.makeItem(withIdentifier: MyTasksTaskItem.identifier,
                                                   for: indexPath) as! MyTasksTaskItem
                configure(item, task: task)
                return item
            case .dropPlaceholder(let status):
                let item = collectionView.makeItem(
                    withIdentifier: MyTasksDropPlaceholderItem.identifier,
                    for: indexPath
                ) as! MyTasksDropPlaceholderItem
                item.bind(status: status)
                return item
            }
        }

        func collectionView(_ collectionView: NSCollectionView,
                            layout collectionViewLayout: NSCollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> NSSize {
            // Mesma corrida do itemForRepresentedObjectAt: o prepareLayout do
            // batch pede tamanhos para índices pré-atualização. Altura padrão
            // de linha para índices órfãos — o batch corrige em seguida.
            guard rows.indices.contains(indexPath.item) else {
                return NSSize(width: collectionView.bounds.width, height: 36)
            }
            let height: CGFloat
            switch rows[indexPath.item] {
            // Exact SwiftUI geometry from the previous list:
            // header line ~=14pt + 10pt vertical padding; every following
            // group carries the former 18pt inter-section spacer.
            case .header(_, _, _, let first): height = first ? 34 : 52
            // The ANEXAR capsule (26pt) is the tallest row content; the
            // remaining ~16pt was inter-item padding. Trimmed ~40% (→ ~9.6pt)
            // for a denser list without touching the capsule geometry.
            case .task: height = 36
            case .dropPlaceholder: height = 36
            }
            return NSSize(width: collectionView.bounds.width, height: height)
        }

        private func targetStatus(at indexPath: IndexPath) -> CUStatus? {
            guard rows.indices.contains(indexPath.item) else { return nil }
            switch rows[indexPath.item] {
            case .header(let status, _, _, _):
                return status
            case .task(let task):
                return appState.availableStatuses.first {
                    $0.status.caseInsensitiveCompare(task.status) == .orderedSame
                } ?? CUStatus(status: task.status,
                              color: task.statusColor,
                              type: task.isCompleted ? "closed" : "custom")
            case .dropPlaceholder(let status):
                return status
            }
        }

        private func showDropPreview(for status: CUStatus) {
            let id = "drop:\(status.id)"
            if rows.contains(where: { $0.id == id }) { return }
            clearDropPreview(animated: false)
            guard let header = rows.firstIndex(where: { row in
                guard case .header(let candidate, _, _, _) = row else { return false }
                return candidate.id == status.id
            }) else { return }
            let insertion = min(rows.count, header + 1)
            rows.insert(.dropPlaceholder(status), at: insertion)
            collection?.animator().insertItems(
                at: [IndexPath(item: insertion, section: 0)]
            )
        }

        private func clearDropPreview(animated: Bool) {
            guard let index = rows.firstIndex(where: {
                if case .dropPlaceholder = $0 { return true }
                return false
            }) else { return }
            rows.remove(at: index)
            let path: Set<IndexPath> = [IndexPath(item: index, section: 0)]
            if animated { collection?.animator().deleteItems(at: path) }
            else { collection?.deleteItems(at: path) }
        }

        func collectionView(_ collectionView: NSCollectionView,
                            validateDrop draggingInfo: NSDraggingInfo,
                            proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                            dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
            guard draggingInfo.draggingPasteboard.string(forType: .string) != nil,
                  let status = targetStatus(at: proposedDropIndexPath.pointee as IndexPath)
            else { return [] }
            showDropPreview(for: status)
            if let preview = rows.firstIndex(where: { $0.id == "drop:\(status.id)" }) {
                proposedDropIndexPath.pointee = NSIndexPath(forItem: preview, inSection: 0)
            }
            proposedDropOperation.pointee = .on
            return .move
        }

        func collectionView(_ collectionView: NSCollectionView,
                            acceptDrop draggingInfo: NSDraggingInfo,
                            indexPath: IndexPath,
                            dropOperation: NSCollectionView.DropOperation) -> Bool {
            guard let status = targetStatus(at: indexPath),
                  let raw = draggingInfo.draggingPasteboard.string(forType: .string)
            else {
                clearDropPreview(animated: true)
                onEndDrag(false)
                return false
            }
            let ids = MyTasksDragPayload.decode(raw)
            guard !ids.isEmpty else {
                clearDropPreview(animated: true)
                onEndDrag(false)
                return false
            }
            let originals = ids.compactMap { appState.tasksById[$0] }
            let changing = originals.filter {
                $0.status.caseInsensitiveCompare(status.status) != .orderedSame
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Batched so every dropped row moves to the new group AT ONCE,
                // instead of one-per-network-round-trip (the ~1s/row cascade).
                let toMove = ids
                    .compactMap { id in self.appState.tasks.first(where: { $0.id == id }) }
                    .filter { $0.status.caseInsensitiveCompare(status.status) != .orderedSame }
                await self.appState.updateTaskStatuses(toMove, to: status, silent: true)
                if !changing.isEmpty {
                    self.appState.pushTaskStatusUndo(changing,
                        label: changing.count == 1
                            ? "Mover tarefa para \(status.status.uppercased())"
                            : "Mover \(changing.count) tarefas para \(status.status.uppercased())")
                }
                self.clearDropPreview(animated: true)
                self.onEndDrag(true)
            }
            return true
        }
    }
}

/// Native empty-canvas responder. Because it is the collection view's
/// background view, task/header cells remain the hit targets over content;
/// only genuinely empty space reaches this view and clears bulk selection.
private final class MyTasksSelectionBackgroundView: NSView {
    var onClearSelection: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onClearSelection?()
    }

    override func cancelOperation(_ sender: Any?) {
        onClearSelection?()
    }
}

/// Animated 42pt insertion slot shown while a drag is over a destination
/// status. It is a real collection item, so surrounding rows physically move
/// out of the way and the pending destination is unambiguous.
private final class MyTasksDropPlaceholderItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("MyTasksDropPlaceholderItem")
    private let slot = MyTasksDropPlaceholderView()
    override func loadView() { view = slot }
    func bind(status: CUStatus) { slot.bind(status: status) }
}

private final class MyTasksDropPlaceholderView: NSView {
    override var isFlipped: Bool { true }
    private let outline = CAShapeLayer()
    private let dot = CALayer()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        outline.fillColor = NSColor.clear.cgColor
        outline.lineDashPattern = [5, 4]
        outline.lineWidth = 1
        layer?.addSublayer(outline)
        layer?.addSublayer(dot)
        label.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        addSubview(label)
        alphaValue = 0
        DispatchQueue.main.async { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self?.animator().alphaValue = 1
            }
        }
    }
    required init?(coder: NSCoder) { nil }

    func bind(status: CUStatus) {
        let color = NSColor(Color(statusHex: status.displayHex))
        outline.strokeColor = color.withAlphaComponent(0.68).cgColor
        outline.backgroundColor = color.withAlphaComponent(0.055).cgColor
        dot.backgroundColor = color.cgColor
        label.stringValue = "SOLTAR EM \(status.status.uppercased())"
        label.textColor = color
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let rect = bounds.insetBy(dx: 44, dy: 4)
        outline.path = CGPath(roundedRect: rect, cornerWidth: 9,
                              cornerHeight: 9, transform: nil)
        outline.frame = bounds
        dot.frame = CGRect(x: rect.minX + 13, y: rect.midY - 3,
                           width: 6, height: 6)
        dot.cornerRadius = 3
        label.sizeToFit()
        label.frame.origin = CGPoint(x: rect.minX + 29,
                                     y: rect.midY - label.frame.height / 2)
    }
}

// MARK: - Exact native port of the previous My Tasks row

/// Recycled AppKit cell that preserves the previous SwiftUI row pixel model:
/// DONE circle | title | 112pt priority | 132pt avatar+assignee | 92pt date |
/// ellipsis. This is intentionally separate from the dashboard's generic
/// `TaskRowCellItem`; reusing that cell changed the layout and typography.
private final class MyTasksTaskItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("MyTasksTaskItem")

    private let row = MyTasksNativeRowView()
    private var task: CUTask?
    private weak var appState: AppState?

    var onRowClick: ((CUTask, CGRect) -> Void)?
    var onBeginDrag: ((CUTask) -> String?)?
    var onEndDrag: ((Bool) -> Void)?
    var onRequestStatusPicker: ((CUTask, NSView) -> Void)?
    var onMediaAction: ((CUTask, TaskMediaFlowMode) -> Void)?
    var contextActionsProvider: ((CUTask) -> [TaskContextAction]?)? {
        didSet { row.contextActionsProvider = contextActionsProvider }
    }

    override func loadView() {
        view = row
        row.onActivate = { [weak self] in
            guard let self, let task else { return }
            let rect = MouseOriginCapture.rectInMainWindow(for: row)
            onRowClick?(task, rect == .zero
                        ? MouseOriginCapture.currentClickRectInMainWindow()
                        : rect)
        }
        row.onStatusPicker = { [weak self] anchor in
            guard let self, let task else { return }
            onRequestStatusPicker?(task, anchor)
        }
        row.onMediaAction = { [weak self] mode in
            guard let self, let task else { return }
            onMediaAction?(task, mode)
        }
        row.onBeginDrag = { [weak self] in
            guard let self, let task else { return nil }
            return onBeginDrag?(task)
        }
        row.onEndDrag = { [weak self] completed in self?.onEndDrag?(completed) }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        task = nil
        appState = nil
        onRowClick = nil
        onBeginDrag = nil
        onEndDrag = nil
        onRequestStatusPicker = nil
        onMediaAction = nil
        contextActionsProvider = nil
        row.prepareForReuse()
    }

    func bind(task: CUTask, appState: AppState) {
        self.task = task
        self.appState = appState
        row.bind(task: task, appState: appState)
        row.contextActionsProvider = contextActionsProvider
    }

    func setBulkSelected(_ selected: Bool) { row.setBulkSelected(selected) }
}

private final class MyTasksMediaButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private var hoverTracking: NSTrackingArea?
    private(set) var isPointerInside = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        resetHover()
    }

    func resetHover() {
        guard isPointerInside else { return }
        isPointerInside = false
        onHover?(false)
    }
}

private final class MyTasksNativeRowView: NSView, NSDraggingSource {
    static let studioSource = StudioSourceLocation(file: String(describing: #fileID),
                                                   line: #line)
    private static weak var activeHoverRow: MyTasksNativeRowView?
    override var isFlipped: Bool { true }

    private enum ReviewVisualState: Equatable {
        case hidden
        case update
        case reviewed
    }

    private let hoverLayer = CALayer()
    private let rule = CALayer()
    private let done = MyTasksDoneCircle()
    private let title = NSTextField(labelWithString: "")
    private let priorityDot = CALayer()
    private let priority = NSTextField(labelWithString: "")
    private let avatar = MyTasksAvatarView()
    private let assignee = NSTextField(labelWithString: "")
    private let date = NSTextField(labelWithString: "")
    private let reviewTrackLayer = CALayer()
    private let review = MyTasksMediaButton()
    private let mediaTrackLayer = CALayer()
    private let mediaProgressLayer = CALayer()
    /// Máscara retangular que revela o preenchimento de progresso — a largura
    /// anima, o pill mantém o formato (nada de scale X deformando as pontas).
    private let mediaProgressMask = CALayer()
    private let media = MyTasksMediaButton()
    private let mediaBadge = NSTextField(labelWithString: "")
    private let more = NSButton()

    private var task: CUTask?
    private weak var appState: AppState?
    private var anyPopupCancellable: AnyCancellable?
    private var mediaCancellable: AnyCancellable?
    private var reviewCancellable: AnyCancellable?
    private var watchedReviewTaskId: String?
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var bulkSelected = false
    private var pressed = false
    private var dragStarted = false
    private var mouseDownTimestamp: TimeInterval?
    private var statusTint: NSColor = .systemGray
    private var mediaProgressFraction: CGFloat = 0
    private var mediaBaseBackground = NSColor.clear.cgColor
    private var mediaBaseTitleColor = NSColor.labelColor
    private var mediaUsesAccentFill = false
    private var reviewVisualState: ReviewVisualState = .hidden
    private var reviewAnimationGeneration = 0

    var onActivate: (() -> Void)?
    var onStatusPicker: ((NSView) -> Void)?
    var onMediaAction: ((TaskMediaFlowMode) -> Void)?
    var onBeginDrag: (() -> String?)?
    var onEndDrag: ((Bool) -> Void)?
    var contextActionsProvider: ((CUTask) -> [TaskContextAction]?)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        hoverLayer.cornerRadius = Editorial.notificationCapsuleRadius
        hoverLayer.cornerCurve = .continuous
        hoverLayer.masksToBounds = false
        layer?.addSublayer(hoverLayer)
        layer?.addSublayer(rule)
        for capsuleLayer in [reviewTrackLayer, mediaTrackLayer, mediaProgressLayer] {
            capsuleLayer.cornerRadius = 13
            capsuleLayer.cornerCurve = .continuous
            layer?.addSublayer(capsuleLayer)
        }
        reviewTrackLayer.masksToBounds = false
        mediaTrackLayer.masksToBounds = false
        mediaProgressLayer.masksToBounds = true
        // O preenchimento de progresso fica SEMPRE do tamanho do pill (raio 13
        // intacto) e é revelado por uma MÁSCARA retangular de largura animada.
        // Antes o pill era escalado no eixo X (transform.scale.x), o que
        // achatava as pontas arredondadas e deformava o botão durante o
        // PREPARANDO/ENVIANDO.
        mediaProgressMask.backgroundColor = NSColor.white.cgColor
        mediaProgressMask.anchorPoint = CGPoint(x: 0, y: 0.5)
        mediaProgressLayer.mask = mediaProgressMask

        done.setAccessibilityLabel("Mover tarefa para outro status")
        done.onActivate = { [weak self, weak done] in
            guard let self, let done else { return }
            self.onStatusPicker?(done)
        }
        addSubview(done)

        for field in [title, priority, assignee, date] {
            field.drawsBackground = false
            field.isBordered = false
            field.isBezeled = false
            field.maximumNumberOfLines = 1
            field.cell?.usesSingleLineMode = true
            field.cell?.lineBreakMode = .byTruncatingTail
            field.lineBreakMode = .byTruncatingTail
            addSubview(field)
        }
        layer?.addSublayer(priorityDot)
        addSubview(avatar)

        review.title = "VER REVIEW"
        review.font = NSFont.systemFont(ofSize: 9.2 * Editorial.typeScale, weight: .semibold)
        review.isBordered = false
        review.wantsLayer = false
        review.controlSize = .small
        review.focusRingType = .none
        review.target = self
        review.action = #selector(openReview(_:))
        review.setAccessibilityLabel("Ver nova review")
        review.toolTip = "Abrir a review atualizada"
        review.onHover = { [weak self] active in self?.setReviewHover(active) }
        review.isHidden = true
        addSubview(review)
        reviewTrackLayer.isHidden = true

        media.title = "ANEXAR"
        media.font = NSFont.systemFont(ofSize: 9.5 * Editorial.typeScale, weight: .semibold)
        media.isBordered = false
        media.wantsLayer = false
        media.controlSize = .small
        media.focusRingType = .none
        media.target = self
        media.action = #selector(openMedia(_:))
        media.setAccessibilityLabel("Anexar ou enviar vídeos")
        media.onHover = { [weak self] active in self?.setMediaHover(active) }
        addSubview(media)

        mediaBadge.alignment = .center
        mediaBadge.font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold)
        mediaBadge.isBordered = false
        mediaBadge.drawsBackground = false
        mediaBadge.wantsLayer = true
        mediaBadge.layer?.cornerRadius = 8
        mediaBadge.layer?.cornerCurve = .continuous
        mediaBadge.layer?.backgroundColor = NSColor.white.cgColor
        mediaBadge.textColor = .controlAccentColor
        mediaBadge.isHidden = true
        mediaBadge.setAccessibilityLabel("Quantidade de vídeos preparados")
        addSubview(mediaBadge)

        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Mais")
        more.imageScaling = .scaleProportionallyDown
        more.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        more.isBordered = false
        more.focusRingType = .none
        more.bezelStyle = .regularSquare
        more.target = self
        more.action = #selector(openMenu(_:))
        addSubview(more)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollDidBegin),
            name: .apolloScrollDidBegin,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollDidBegin),
            name: NSScrollView.willStartLiveScrollNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let watchedReviewTaskId {
            TaskReviewUpdateStore.shared.unwatch(taskId: watchedReviewTaskId)
        }
        watchedReviewTaskId = nil
        task = nil
        appState = nil
        mediaCancellable?.cancel()
        mediaCancellable = nil
        reviewCancellable?.cancel()
        reviewCancellable = nil
        reviewAnimationGeneration += 1
        reviewVisualState = .hidden
        review.isHidden = true
        review.isEnabled = false
        review.alphaValue = 1
        reviewTrackLayer.isHidden = true
        reviewTrackLayer.opacity = 1
        reviewTrackLayer.transform = CATransform3DIdentity
        reviewTrackLayer.shadowOpacity = 0
        avatar.prepareForReuse()
        hovered = false
        pressed = false
        dragStarted = false
        bulkSelected = false
        setHoverMotion(active: false, animated: false)
        applyBackground()
    }

    func bind(task: CUTask, appState: AppState) {
        if let watchedReviewTaskId, watchedReviewTaskId != task.id {
            TaskReviewUpdateStore.shared.unwatch(taskId: watchedReviewTaskId)
        }
        watchedReviewTaskId = task.id
        self.task = task
        self.appState = appState
        if anyPopupCancellable == nil {
            anyPopupCancellable = appState.$anyPopupOpen
                .receive(on: RunLoop.main)
                .sink { [weak self] open in
                    guard let self else { return }
                    self.done.isEnabled = !open
                    self.more.isEnabled = !open
                    self.review.isEnabled = !open && self.reviewVisualState == .update
                    self.media.isEnabled = !open
                    if open { self.forceExitAllInteraction() }
                }
        }
        done.isEnabled = !appState.anyPopupOpen
        more.isEnabled = !appState.anyPopupOpen
        review.isEnabled = !appState.anyPopupOpen && reviewVisualState == .update
        media.isEnabled = !appState.anyPopupOpen
        mediaCancellable?.cancel()
        mediaCancellable = appState.taskMediaTransfers.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self, weak appState] _ in
                DispatchQueue.main.async {
                    guard let self, let appState, self.task?.id == task.id else { return }
                    self.updateMediaButton(store: appState.taskMediaTransfers, taskId: task.id)
                }
            }
        updateMediaButton(store: appState.taskMediaTransfers, taskId: task.id)
        let reviewStore = TaskReviewUpdateStore.shared
        reviewStore.watch(task: task)
        reviewCancellable?.cancel()
        reviewCancellable = reviewStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.task?.id == task.id else { return }
                    self.updateReviewButton(taskId: task.id)
                }
            }
        updateReviewButton(taskId: task.id)
        title.stringValue = task.title
        title.toolTip = task.title
        title.font = NSFont.systemFont(ofSize: 15 * Editorial.typeScale,
                                       weight: .medium)
        title.textColor = NSColor(task.isCompleted ? Editorial.inkMute : Editorial.ink)

        if task.priority > 0 && task.priority <= 2 {
            priority.stringValue = task.priorityLabel.uppercased()
            priority.font = trackedFont(size: 9.5 * Editorial.typeScale,
                                        weight: .semibold, tracking: 0.9)
            let color = NSColor(Color(hex: task.priorityHex))
            priority.textColor = color
            priority.isHidden = false
            priorityDot.isHidden = true   // dot removed — the coloured label carries the signal
        } else {
            priority.stringValue = ""
            priority.isHidden = true
            priorityDot.isHidden = true
        }

        if let first = task.assignees.first {
            avatar.bind(assignee: first)
            avatar.isHidden = false
            assignee.stringValue = friendlyFirstName(first.username)
            assignee.isHidden = false
        } else {
            avatar.prepareForReuse()
            avatar.isHidden = true
            assignee.stringValue = ""
            assignee.isHidden = true
        }
        assignee.font = NSFont.systemFont(ofSize: 11.5 * Editorial.typeScale,
                                          weight: .regular)
        assignee.textColor = NSColor(Editorial.inkSoft)

        if let due = task.dueDate {
            date.stringValue = Self.relativeDate(due)
            let calendar = Calendar.current
            let today = calendar.isDateInToday(due)
            let overdue = due < calendar.startOfDay(for: Date()) && !task.isCompleted
            date.textColor = today ? .controlAccentColor
                : (overdue ? .systemRed : NSColor(Editorial.inkSoft))
            date.isHidden = false
        } else {
            date.stringValue = ""
            date.isHidden = true
        }
        date.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5 * Editorial.typeScale,
                                                     weight: .medium)

        done.bind(statusColor: NSColor(Color(statusHex: task.statusDisplayHex)),
                  completed: task.isCompleted)
        statusTint = NSColor(Color(statusHex: task.statusDisplayHex))
        more.contentTintColor = NSColor(Editorial.inkMute)
        rule.backgroundColor = resolvedCGColor(Editorial.rule.opacity(0.5))
        applyBackground()
        needsLayout = true
    }

    func setBulkSelected(_ selected: Bool) {
        guard bulkSelected != selected else { return }
        bulkSelected = selected
        applyBackground()
    }

    private func applyBackground() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer.backgroundColor = resolvedCGColor(
            bulkSelected ? Editorial.accent.opacity(0.075)
            : (hovered ? Editorial.card : Color.clear)
        )
        hoverLayer.borderWidth = bulkSelected ? 1 : 0
        hoverLayer.borderColor = resolvedCGColor(Editorial.accent.opacity(0.42))
        // Lists use neutral elevation. Semantic coloured shadows belong only
        // to Board cards, where they communicate the column/status context.
        hoverLayer.shadowColor = NSColor.black.cgColor
        hoverLayer.shadowOpacity = hovered ? 0.14 : 0
        hoverLayer.shadowRadius = hovered ? 4 : 0
        hoverLayer.shadowOffset = CGSize(
            width: 0,
            height: Editorial.nativeListShadowHoverY
        )
        rule.opacity = hovered ? 0 : 1
        CATransaction.commit()
    }

    /// Raise the hovered row above its neighbours without translating or
    /// scaling its geometry. Background, radius and shadow provide the hover
    /// feedback; the task must remain pixel-stable under the pointer.
    private func setHoverMotion(active: Bool, animated: Bool) {
        guard let layer else { return }
        layer.removeAnimation(forKey: "apolloCapsuleHover")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        layer.zPosition = active ? 20 : 0
        CATransaction.commit()
    }

    /// Native tracking areas continue receiving enter/exit notifications even
    /// when a SwiftUI view above them disables hit testing. A modal therefore
    /// has to reset the AppKit cell explicitly; otherwise the row under the
    /// popup can keep (or regain) its hover/press state.
    private func forceExitAllInteraction() {
        let needsUpdate = hovered || pressed || dragStarted
        hovered = false
        pressed = false
        dragStarted = false
        done.resetInteraction(animated: false)
        review.resetHover()
        setReviewHover(false)
        media.resetHover()
        setMediaHover(false)
        setHoverMotion(active: false, animated: false)
        if needsUpdate { applyBackground() }
        if Self.activeHoverRow === self { Self.activeHoverRow = nil }
    }

    @objc private func scrollDidBegin() {
        forceExitAllInteraction()
    }

    /// NSCollectionView can reposition a reused cell without dispatching
    /// `mouseExited` to tracking areas inside it. Clear transient visuals as
    /// soon as the row's canvas position changes; the next real pointer event
    /// will re-establish hover only for the control actually under the mouse.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let moved = frame.origin != newOrigin
        super.setFrameOrigin(newOrigin)
        guard moved else { return }
        let hadRowHover = hovered || pressed
        hovered = false
        pressed = false
        done.resetInteraction(animated: false)
        review.resetHover()
        setReviewHover(false)
        media.resetHover()
        setMediaHover(false)
        setHoverMotion(active: false, animated: false)
        if hadRowHover { applyBackground() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let task, let appState { bind(task: task, appState: appState) }
        else { applyBackground() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInKeyWindow, .mouseEnteredAndExited,
                                            .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard appState?.anyPopupOpen != true,
              !ScrollStateObserver.isScrollingNow,
              !ScrollGate.shared.active else {
            forceExitAllInteraction()
            return
        }
        if let previous = Self.activeHoverRow, previous !== self {
            previous.forceExitAllInteraction()
        }
        Self.activeHoverRow = self
        hovered = true
        applyBackground()
        setHoverMotion(active: true, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        pressed = false
        applyBackground()
        setHoverMotion(active: false, animated: true)
        if Self.activeHoverRow === self { Self.activeHoverRow = nil }
    }

    override func mouseDown(with event: NSEvent) {
        guard appState?.anyPopupOpen != true else { return }
        pressed = true
        dragStarted = false
        mouseDownTimestamp = event.timestamp
    }

    override func mouseDragged(with event: NSEvent) {
        guard appState?.anyPopupOpen != true,
              !dragStarted,
              let mouseDownTimestamp,
              TaskDragActivation.isReady(mouseDownTimestamp: mouseDownTimestamp,
                                         currentTimestamp: event.timestamp),
              let payload = onBeginDrag?(), !payload.isEmpty else { return }
        dragStarted = true
        pressed = false

        let pasteboard = NSPasteboardItem()
        pasteboard.setString(payload, forType: .string)
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        let ids = MyTasksDragPayload.decode(payload)
        if ids.count > 1 {
            let size = NSSize(width: min(300, max(240, bounds.width * 0.42)), height: 60)
            let image = multiTaskDragImage(count: ids.count, size: size)
            let frame = NSRect(x: max(0, bounds.midX - size.width / 2),
                               y: bounds.midY - size.height / 2,
                               width: size.width, height: size.height)
            item.setDraggingFrame(frame, contents: image)
        } else {
            let image = NSImage(size: bounds.size)
            if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
                cacheDisplay(in: bounds, to: rep)
                image.addRepresentation(rep)
            }
            item.setDraggingFrame(bounds, contents: image)
        }
        beginDraggingSession(with: [item], event: event, source: self)
    }

    private func multiTaskDragImage(count: Int, size: NSSize) -> NSImage {
        NSImage(size: size, flipped: true) { rect in
            let cardWidth = rect.width - 10
            for index in stride(from: 2, through: 0, by: -1) {
                let offset = CGFloat(index) * 4
                let card = NSRect(x: offset,
                                  y: CGFloat(2 - index) * 5,
                                  width: cardWidth - offset,
                                  height: 44)
                let path = NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12)
                NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
                path.fill()
                self.statusTint.withAlphaComponent(index == 0 ? 0.45 : 0.22).setStroke()
                path.lineWidth = index == 0 ? 1 : 0.7
                path.stroke()
            }

            self.statusTint.setFill()
            NSBezierPath(ovalIn: NSRect(x: 15, y: 18, width: 8, height: 8)).fill()
            let symbol = NSImage(systemSymbolName: "rectangle.stack.fill",
                                 accessibilityDescription: nil)
            symbol?.draw(in: NSRect(x: 31, y: 14, width: 16, height: 16))
            let text = "\(count) tarefas"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
            NSAttributedString(string: text, attributes: attrs)
                .draw(at: NSPoint(x: 56, y: 14))
            return true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressed = false
            mouseDownTimestamp = nil
        }
        guard appState?.anyPopupOpen != true else { return }
        guard !dragStarted else { dragStarted = false; return }
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onActivate?()
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        dragStarted = false
        mouseDownTimestamp = nil
        onEndDrag?(operation != [])
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard appState?.anyPopupOpen != true, let task else { return nil }
        let actions = contextActionsProvider?(task) ?? []
        return actions.isEmpty ? nil : TaskContextMenu.makeNSMenu(actions: actions)
    }

    @objc private func openMenu(_ sender: NSButton) {
        guard appState?.anyPopupOpen != true, let task else { return }
        let actions = contextActionsProvider?(task) ?? []
        guard !actions.isEmpty else { return }
        let menu = TaskContextMenu.makeNSMenu(actions: actions)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: sender.bounds.minX, y: sender.bounds.maxY + 3),
                   in: sender)
    }

    @objc private func openMedia(_ sender: NSButton) {
        guard appState?.anyPopupOpen != true, let task, let appState else { return }
        switch appState.taskMediaTransfers.phase(for: task.id) {
        case .ready:
            onMediaAction?(.send)
        case .partialFailure:
            var actions = [
                TaskContextAction(title: "Tentar novamente",
                                  systemImage: "arrow.clockwise",
                                  action: { [weak self] in self?.onMediaAction?(.send) })
            ]
            if appState.taskMediaTransfers.replaceablePendingCountByTask[task.id, default: 0] > 0 {
                actions.append(TaskContextAction(
                    title: "Substituir vídeos pendentes",
                    systemImage: "arrow.triangle.2.circlepath",
                    action: { [weak self] in self?.onMediaAction?(.replacePending) }
                ))
            }
            actions.append(TaskContextAction(
                title: "Descartar lote",
                systemImage: "trash",
                isDestructive: true,
                action: { [weak self] in
                    guard let self, let task = self.task else { return }
                    self.appState?.taskMediaTransfers.discard(taskId: task.id)
                }
            ))
            let menu = TaskContextMenu.makeNSMenu(actions: actions)
            menu.popUp(positioning: nil,
                       at: NSPoint(x: sender.bounds.minX, y: sender.bounds.maxY + 3),
                       in: sender)
        case .failed where appState.taskMediaTransfers.batches[task.id]?.total == 0:
            appState.taskMediaTransfers.discard(taskId: task.id)
            onMediaAction?(.add)
        case .preparing, .sending, .failed, .sent:
            onMediaAction?(.status)
        case nil:
            let taskId = task.id
            Task { @MainActor [weak self] in
                guard let self else { return }
                await appState.taskMediaTransfers.loadCatalog(for: task, appState: appState)
                guard self.task?.id == taskId,
                      appState.anyPopupOpen != true else { return }

                if appState.taskMediaTransfers.catalog(for: taskId)
                    .hasReplaceablePublishedMedia {
                    self.presentMediaEntryMenu(from: sender)
                } else {
                    // Empty tasks skip a menu with an impossible action and go
                    // straight to the system file picker.
                    self.onMediaAction?(.add)
                }
            }
        }
    }

    private func presentMediaEntryMenu(from sender: NSButton) {
        let actions = [
            TaskContextAction(title: "Adicionar arquivos",
                              systemImage: "plus.circle",
                              action: { [weak self] in self?.onMediaAction?(.add) }),
            TaskContextAction(title: "Substituir arquivo",
                              systemImage: "arrow.triangle.2.circlepath",
                              action: { [weak self] in self?.onMediaAction?(.replace) })
        ]
        let menu = TaskContextMenu.makeNSMenu(actions: actions)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: sender.bounds.minX, y: sender.bounds.maxY + 3),
                   in: sender)
    }

    @objc private func openReview(_ sender: NSButton) {
        guard appState?.anyPopupOpen != true,
              let task, let appState
        else { return }

        let updates = TaskReviewUpdateStore.shared.updates(for: task.id)
        guard !updates.isEmpty else { return }
        if updates.count > 1 {
            TaskReviewQueuePresenter.shared.present(task: task, updates: updates)
            return
        }
        guard let update = updates.first else { return }

        // Opening is not acknowledgement. Keep the update alive until the
        // reviewer explicitly concludes it and presses "Fechar" in ReviewKit.
        ReviewWatcher.shared.register(
            att: update.activeAtt,
            mediaUrl: update.attachment.url,
            ext: update.attachment.ext,
            taskId: task.id,
            title: update.attachment.title,
            uploaderId: update.attachment.uploaderId,
            tintHex: nil,
            currentUpdatedAt: update.meta.updatedAt,
            versionId: update.meta.evaluatedVersionId
        )
        let actorId = appState.clickUpAuthService.userId ?? 0
        let actorName = appState.availableMembers
            .first { $0.id == actorId }?.username ?? "Revisor"
        ReviewPresenter.shared.present(
            ReviewLink.params(attachment: update.attachment,
                              taskId: task.id,
                              listId: task.listId,
                              uploaderId: update.attachment.uploaderId,
                              actorId: actorId,
                              actorName: actorName,
                              reviewId: update.meta.reviewId,
                              versionId: update.meta.evaluatedVersionId
                                ?? update.meta.currentVersionId),
            completionAcknowledgement: ReviewCompletionAcknowledgement(
                taskId: task.id,
                activeAtt: update.activeAtt
            )
        )
    }

    private func updateReviewButton(taskId: String) {
        let next: ReviewVisualState
        switch TaskReviewUpdateStore.shared.capsuleState(for: taskId) {
        case .update?: next = .update
        case .reviewed?: next = .reviewed
        case nil: next = .hidden
        }

        guard next != reviewVisualState else { return }
        reviewAnimationGeneration += 1
        let generation = reviewAnimationGeneration
        let previous = reviewVisualState
        reviewVisualState = next

        switch next {
        case .update:
            presentReviewCapsule(
                title: "VER REVIEW",
                titleColor: .white,
                fill: .controlAccentColor,
                interactive: appState?.anyPopupOpen != true,
                from: previous,
                generation: generation
            )
        case .reviewed:
            presentReviewCapsule(
                title: "REVISADO",
                titleColor: reviewSuccessInk,
                fill: reviewSuccessFill,
                interactive: false,
                from: previous,
                generation: generation
            )
            pulseReviewSuccess(generation: generation)
        case .hidden:
            dismissReviewCapsule(taskId: taskId, generation: generation)
        }
        needsLayout = true
    }

    private var reviewSuccessFill: NSColor {
        NSColor(srgbRed: 0.84, green: 0.96, blue: 0.88, alpha: 1)
    }

    private var reviewSuccessInk: NSColor {
        NSColor(srgbRed: 0.045, green: 0.34, blue: 0.17, alpha: 1)
    }

    private func presentReviewCapsule(title: String,
                                      titleColor: NSColor,
                                      fill: NSColor,
                                      interactive: Bool,
                                      from previous: ReviewVisualState,
                                      generation: Int) {
        review.isHidden = false
        reviewTrackLayer.isHidden = false
        review.isEnabled = interactive
        review.setAccessibilityLabel(title == "REVISADO"
            ? "Review concluída"
            : "Ver nova review")
        review.toolTip = title == "REVISADO"
            ? "Review concluída"
            : "Abrir a review atualizada"

        let wasHidden = previous == .hidden
        if wasHidden {
            review.title = title
            setReviewTitleColor(titleColor)
            review.alphaValue = 0
            reviewTrackLayer.opacity = 0
            reviewTrackLayer.transform = CATransform3DMakeScale(0.94, 0.94, 1)
        } else {
            crossfadeReviewTitle(title, color: titleColor,
                                 generation: generation)
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(wasHidden ? 0.30 : 0.36)
        CATransaction.setAnimationTimingFunction(
            CAMediaTimingFunction(controlPoints: 0.18, 0.84, 0.24, 1.00)
        )
        reviewTrackLayer.backgroundColor = fill.cgColor
        reviewTrackLayer.opacity = 1
        reviewTrackLayer.transform = CATransform3DIdentity
        CATransaction.commit()

        if wasHidden {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.18, 0.84, 0.24, 1.00
                )
                review.animator().alphaValue = 1
            }
        }
    }

    private func crossfadeReviewTitle(_ title: String,
                                      color: NSColor,
                                      generation: Int) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            review.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self,
                      self.reviewAnimationGeneration == generation,
                      self.reviewVisualState != .hidden else { return }
                self.review.title = title
                self.setReviewTitleColor(color)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.24
                    context.timingFunction = CAMediaTimingFunction(
                        controlPoints: 0.18, 0.84, 0.24, 1.00
                    )
                    self.review.animator().alphaValue = 1
                }
            }
        }
    }

    private func pulseReviewSuccess(generation: Int) {
        reviewTrackLayer.shadowColor = NSColor.systemGreen.cgColor
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.30)
        CATransaction.setAnimationTimingFunction(
            CAMediaTimingFunction(controlPoints: 0.18, 0.84, 0.24, 1.00)
        )
        reviewTrackLayer.shadowOpacity = 0.18
        reviewTrackLayer.shadowRadius = 8
        reviewTrackLayer.shadowOffset = CGSize(width: 0, height: 2)
        CATransaction.commit()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.58) { [weak self] in
            guard let self,
                  self.reviewAnimationGeneration == generation,
                  self.reviewVisualState == .reviewed else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.42)
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(name: .easeOut)
            )
            self.reviewTrackLayer.shadowOpacity = 0.04
            self.reviewTrackLayer.shadowRadius = 3
            CATransaction.commit()
        }
    }

    private func dismissReviewCapsule(taskId: String, generation: Int) {
        review.isEnabled = false
        review.resetHover()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.26)
        CATransaction.setAnimationTimingFunction(
            CAMediaTimingFunction(controlPoints: 0.40, 0.00, 0.67, 1.00)
        )
        reviewTrackLayer.opacity = 0
        reviewTrackLayer.transform = CATransform3DMakeScale(0.96, 0.96, 1)
        reviewTrackLayer.shadowOpacity = 0
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            review.animator().alphaValue = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.27) { [weak self] in
            guard let self,
                  self.task?.id == taskId,
                  self.reviewAnimationGeneration == generation,
                  self.reviewVisualState == .hidden else { return }
            self.review.isHidden = true
            self.reviewTrackLayer.isHidden = true
            self.review.alphaValue = 1
            self.reviewTrackLayer.opacity = 1
            self.reviewTrackLayer.transform = CATransform3DIdentity
        }
    }

    private func updateMediaButton(store: TaskMediaTransferStore, taskId: String) {
        let phase = store.phase(for: taskId)
        let label = store.capsuleLabel(for: taskId)
        let composing = store.isComposing(for: taskId)
        // JUNTANDO (render hook+body) usa um accent clareado — a etapa é
        // visualmente distinta do ENVIANDO cheio e do PREPARANDO comum.
        let accentColor = composing
            ? (NSColor.controlAccentColor.blended(withFraction: 0.35, of: .white)
               ?? NSColor.controlAccentColor)
            : NSColor.controlAccentColor
        let accent = phase == .ready || phase == .sending || phase == .partialFailure
        let isActiveProgress = phase == .preparing || phase == .sending
        let progress = max(0, min(1, CGFloat(store.progress(for: taskId))))
        mediaUsesAccentFill = accent
        mediaBaseTitleColor = phase == .preparing
            ? accentColor
            : (accent ? NSColor.white : NSColor(Editorial.inkSoft))
        mediaBaseBackground = phase == .preparing
            ? accentColor.withAlphaComponent(composing ? 0.16 : 0.10).cgColor
            : (accent
                ? NSColor.controlAccentColor.withAlphaComponent(phase == .sending ? 0.36 : 1).cgColor
                : NSColor(Editorial.inkFaint.opacity(0.14)).cgColor)
        media.title = label
        setMediaTitleColor(mediaBaseTitleColor)
        mediaTrackLayer.backgroundColor = mediaBaseBackground
        mediaProgressLayer.backgroundColor = phase == .preparing
            ? accentColor.withAlphaComponent(composing ? 0.38 : 0.30).cgColor
            : NSColor.controlAccentColor.cgColor
        mediaProgressLayer.isHidden = !isActiveProgress
        setMediaProgress(isActiveProgress ? progress : (phase == .ready ? 1 : 0), animated: true)
        media.toolTip = media.title == "ANEXAR"
            ? "Adicionar HOOKs, BODYs ou vídeos completos"
            : media.title
        let badgeCount = store.batches[taskId].map {
            phase == .partialFailure ? $0.pendingCount : $0.total
        } ?? 0
        mediaBadge.isHidden = (phase != .ready && phase != .partialFailure) || badgeCount <= 0
        if !mediaBadge.isHidden {
            mediaBadge.stringValue = "\(badgeCount)"
        }
        needsLayout = true
    }

    private func setMediaProgress(_ fraction: CGFloat, animated: Bool) {
        let target = max(0, min(1, fraction))
        let fullWidth = mediaProgressLayer.bounds.width
        let currentWidth = (mediaProgressMask.presentation()?
            .value(forKeyPath: "bounds.size.width") as? NSNumber)
            .map(CGFloat.init(truncating:)) ?? (mediaProgressFraction * fullWidth)
        mediaProgressFraction = target
        let targetWidth = target * fullWidth
        // Largura da MÁSCARA anima; o pill do preenchimento nunca é escalado,
        // então o raio das pontas fica intacto (sem deformar o botão).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mediaProgressMask.bounds = CGRect(x: 0, y: 0,
                                          width: targetWidth,
                                          height: mediaProgressLayer.bounds.height)
        mediaProgressMask.position = .init(x: 0, y: mediaProgressLayer.bounds.midY)
        CATransaction.commit()
        guard animated, abs(currentWidth - targetWidth) > 0.5 else { return }
        let animation = CABasicAnimation(keyPath: "bounds.size.width")
        animation.fromValue = currentWidth
        animation.toValue = targetWidth
        animation.duration = 0.22
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        mediaProgressMask.add(animation, forKey: "apollo.media.progress")
    }

    private func setMediaTitleColor(_ color: NSColor) {
        let baseSize: CGFloat = media.title.count > 11 ? 8.0 : 9.5
        media.attributedTitle = NSAttributedString(
            string: media.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: baseSize * Editorial.typeScale,
                                         weight: .semibold),
                .foregroundColor: color
            ]
        )
    }

    private func setReviewTitleColor(_ color: NSColor) {
        review.attributedTitle = NSAttributedString(
            string: review.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 9.2 * Editorial.typeScale,
                                         weight: .semibold),
                .foregroundColor: color
            ]
        )
    }

    private func setReviewHover(_ active: Bool) {
        guard reviewVisualState == .update else {
            if reviewVisualState == .reviewed {
                reviewTrackLayer.backgroundColor = reviewSuccessFill.cgColor
                setReviewTitleColor(reviewSuccessInk)
            }
            return
        }
        let shouldActivate = active
            && review.isEnabled
            && !review.isHidden
            && appState?.anyPopupOpen != true
            && !ScrollStateObserver.isScrollingNow
            && !ScrollGate.shared.active
        CATransaction.begin()
        CATransaction.setAnimationDuration(shouldActivate ? 0.16 : 0.22)
        CATransaction.setAnimationTimingFunction(
            CAMediaTimingFunction(controlPoints: 0.20, 0.82, 0.24, 1.00)
        )
        reviewTrackLayer.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(shouldActivate ? 0.82 : 1).cgColor
        CATransaction.commit()
        setReviewTitleColor(.white)
    }

    private func setMediaHover(_ active: Bool) {
        let shouldActivate = active
            && media.isEnabled
            && appState?.anyPopupOpen != true
            && !ScrollStateObserver.isScrollingNow
            && !ScrollGate.shared.active
        CATransaction.begin()
        CATransaction.setAnimationDuration(shouldActivate ? 0.16 : 0.24)
        CATransaction.setAnimationTimingFunction(
            CAMediaTimingFunction(controlPoints: shouldActivate ? 0.20 : 0.32,
                                  shouldActivate ? 0.82 : 0.00,
                                  shouldActivate ? 0.24 : 0.67,
                                  1.00)
        )
        mediaTrackLayer.borderWidth = 0
        mediaTrackLayer.backgroundColor = shouldActivate
            ? (mediaUsesAccentFill
                ? NSColor.controlAccentColor.withAlphaComponent(0.84).cgColor
                : NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
            : mediaBaseBackground
        mediaTrackLayer.shadowColor = NSColor.black.cgColor
        mediaTrackLayer.shadowOpacity = shouldActivate ? 0.055 : 0
        mediaTrackLayer.shadowRadius = shouldActivate ? 3 : 0
        mediaTrackLayer.shadowOffset = CGSize(width: 0, height: shouldActivate ? 1 : 0)
        mediaTrackLayer.opacity = 1
        CATransaction.commit()
        setMediaTitleColor(shouldActivate && !mediaUsesAccentFill
            ? NSColor.controlAccentColor
            : mediaBaseTitleColor)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let centerY = h / 2
        // Previous hierarchy: LazyVStack horizontal 28 + row horizontal 16.
        let edge: CGFloat = 44
        hoverLayer.frame = CGRect(x: 28, y: 1, width: max(0, bounds.width - 56),
                                  height: max(0, h - 2))
        rule.frame = CGRect(x: 28, y: h - 0.5,
                            width: max(0, bounds.width - 56), height: 0.5)

        // Keep the previous 10pt visual circle, but expose a native 24pt hit
        // target. The old 10x10 NSControl was technically clickable yet far
        // too easy for the parent row gesture to win, making DONE appear
        // inoperative in normal use.
        done.frame = NSRect(x: edge - 7, y: centerY - 12, width: 24, height: 24)

        // Column x/widths come from the shared, user-resizable layout model so
        // the SwiftUI column header and these rows are always in lockstep.
        let m = MyTasksColumnLayout.shared.metrics(totalWidth: bounds.width)

        title.frame = NSRect(x: m.titleX, y: centeredY(for: title, at: centerY),
                             width: m.titleWidth, height: fittedHeight(title))

        review.frame = NSRect(x: m.reviewX, y: centerY - 13,
                              width: m.reviewWidth, height: 26)
        reviewTrackLayer.frame = review.frame
        reviewTrackLayer.shadowPath = CGPath(
            roundedRect: CGRect(origin: .zero, size: review.frame.size),
            cornerWidth: 13, cornerHeight: 13, transform: nil)

        media.frame = NSRect(x: m.mediaX, y: centerY - 13,
                             width: m.mediaWidth, height: 26)
        mediaTrackLayer.frame = media.frame
        mediaTrackLayer.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: media.frame.size),
                                            cornerWidth: 13, cornerHeight: 13,
                                            transform: nil)
        mediaProgressLayer.bounds = CGRect(origin: .zero, size: media.frame.size)
        mediaProgressLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        mediaProgressLayer.position = CGPoint(x: media.frame.minX, y: media.frame.midY)
        // Máscara acompanha o novo tamanho do pill mantendo a fração atual.
        mediaProgressMask.bounds = CGRect(x: 0, y: 0,
                                          width: media.frame.width * mediaProgressFraction,
                                          height: media.frame.height)
        mediaProgressMask.position = CGPoint(x: 0, y: media.frame.height / 2)
        mediaBadge.frame = NSRect(x: media.frame.maxX - 12,
                                  y: media.frame.minY - 6,
                                  width: 20, height: 16)

        priority.sizeToFit()
        let priorityH = priority.frame.height
        priority.frame = NSRect(x: m.priorityX, y: centerY - priorityH / 2,
                                width: max(0, m.priorityWidth), height: priorityH)

        avatar.frame = NSRect(x: m.assigneeX, y: centerY - 10, width: 20, height: 20)
        assignee.sizeToFit()
        let assigneeH = assignee.frame.height
        assignee.frame = NSRect(x: m.assigneeX + 27, y: centerY - assigneeH / 2,
                                width: max(0, m.assigneeWidth - 27), height: assigneeH)

        date.sizeToFit()
        let dateSize = date.frame.size
        date.frame = NSRect(x: m.dateX + max(0, m.dateWidth - dateSize.width),
                            y: centerY - dateSize.height / 2,
                            width: min(dateSize.width, m.dateWidth), height: dateSize.height)
        more.frame = NSRect(x: m.moreX, y: centerY - 9, width: 18, height: 18)
    }

    private func fittedHeight(_ field: NSTextField) -> CGFloat {
        field.sizeToFit()
        return max(1, field.frame.height)
    }

    private func centeredY(for field: NSTextField, at center: CGFloat) -> CGFloat {
        center - fittedHeight(field) / 2
    }

    private func trackedFont(size: CGFloat, weight: NSFont.Weight,
                             tracking: CGFloat) -> NSFont {
        // Tracking is applied through attributed strings below when needed;
        // the font remains a native SF Pro face at the exact prior size.
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    private func friendlyFirstName(_ raw: String) -> String {
        let beforeAt = raw.split(separator: "@").first.map(String.init) ?? raw
        let token = beforeAt.split(whereSeparator: { $0 == " " || $0 == "." })
            .first.map(String.init) ?? beforeAt
        guard let first = token.first else { return "" }
        return String(first).uppercased() + token.dropFirst().lowercased()
    }

    private static func relativeDate(_ value: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(value) { return "Hoje" }
        if calendar.isDateInYesterday(value) { return "Ontem" }
        if calendar.isDateInTomorrow(value) { return "Amanhã" }
        let days = calendar.dateComponents([.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: value)).day ?? 0
        if days > 1 && days < 7 { return "em \(days) dias" }
        if days < -1 && days > -7 { return "\(-days) dias atrás" }
        return SharedDateFormatters.dayOfMonthAbbrevPTBR.string(from: value)
    }
}

/// 10pt status-colored inner-shadow completion affordance from the previous
/// SwiftUI row, drawn directly in AppKit to avoid a hosting view per cell.
private final class MyTasksDoneCircle: NSControl {
    override var isFlipped: Bool { true }
    private var statusColor = NSColor.clear
    private var completed = false
    private var hovered = false
    private var pressed = false
    private var tracking: NSTrackingArea?
    var onActivate: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Mover tarefa para outro status")
        setAccessibilityHelp("Abre a lista de status disponíveis")
    }

    required init?(coder: NSCoder) { nil }

    func bind(statusColor: NSColor, completed: Bool) {
        let semanticStateChanged = !self.statusColor.isEqual(statusColor)
            || self.completed != completed
        self.statusColor = statusColor
        self.completed = completed
        if semanticStateChanged { resetInteraction(animated: false) }
        needsDisplay = true
    }

    func resetInteraction(animated: Bool) {
        let hadInteraction = hovered || pressed
        hovered = false
        pressed = false
        layer?.removeAnimation(forKey: "apollo.done.hover")
        if animated { animateScale(to: 1, duration: 0.14) }
        else { layer?.setValue(CGFloat(1), forKeyPath: "transform.scale") }
        if hadInteraction { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        // The control owns a 24pt hit target while the visible affordance
        // remains the exact prior 10pt circle, centred inside it.
        let visual = NSRect(x: bounds.midX - 5, y: bounds.midY - 5,
                            width: 10, height: 10)
        let rect = visual.insetBy(dx: 0.6, dy: 0.6)
        let path = NSBezierPath(ovalIn: rect)
        if completed {
            NSColor.systemGreen.setFill()
            path.fill()
            let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
            check?.isTemplate = true
            NSColor.white.set()
            check?.draw(in: visual.insetBy(dx: 2.1, dy: 2.1))
        } else {
            let paper = NSColor(Editorial.paper)
            let inner = statusColor.withAlphaComponent(hovered ? 0.88 : 0.62)
            NSGradient(starting: inner, ending: paper)?.draw(in: path,
                                                              relativeCenterPosition: .zero)
            (hovered ? statusColor : NSColor(Editorial.inkFaint.opacity(0.85))).setStroke()
            path.lineWidth = hovered ? 1.05 : 0.75
            path.stroke()

            if hovered {
                statusColor.withAlphaComponent(0.16).setFill()
                NSBezierPath(ovalIn: visual.insetBy(dx: -2.2, dy: -2.2)).fill()
                // Repaint the crisp core above the atmospheric hover halo.
                NSGradient(starting: inner, ending: paper)?.draw(in: path,
                                                                  relativeCenterPosition: .zero)
                statusColor.setStroke()
                path.stroke()
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInKeyWindow, .mouseEnteredAndExited,
                                            .inVisibleRect, .cursorUpdate],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled, !completed,
              !ScrollStateObserver.isScrollingNow,
              !ScrollGate.shared.active else {
            resetInteraction(animated: false)
            return
        }
        hovered = true
        animateScale(to: 1.16, duration: 0.16)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        pressed = false
        animateScale(to: 1, duration: 0.20)
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        (isEnabled && !completed ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, !completed else { return }
        pressed = true
        animateScale(to: 0.91, duration: 0.08)
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        animateScale(to: hovered ? 1.16 : 1, duration: 0.22, spring: true)
        guard isEnabled, !completed,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onActivate?()
    }

    /// Keep keyboard and accessibility activation on the exact same path as
    /// a pointer click. Without this override the custom-drawn NSControl was
    /// announced as an inert image and automation could not open its picker.
    override func performClick(_ sender: Any?) {
        guard isEnabled, !completed else { return }
        onActivate?()
    }

    private func animateScale(to value: CGFloat,
                              duration: CFTimeInterval,
                              spring: Bool = false) {
        guard let layer else { return }
        let animation: CABasicAnimation
        if spring {
            let bounce = CASpringAnimation(keyPath: "transform.scale")
            bounce.mass = 0.7
            bounce.stiffness = 310
            bounce.damping = 22
            bounce.initialVelocity = 2
            bounce.fromValue = layer.presentation()?.value(forKeyPath: "transform.scale") ?? value
            bounce.toValue = value
            bounce.duration = bounce.settlingDuration
            animation = bounce
        } else {
            let basic = CABasicAnimation(keyPath: "transform.scale")
            basic.fromValue = layer.presentation()?.value(forKeyPath: "transform.scale") ?? value
            basic.toValue = value
            basic.duration = duration
            basic.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animation = basic
        }
        layer.setValue(value, forKeyPath: "transform.scale")
        layer.add(animation, forKey: "apollo.done.hover")
    }
}

private final class MyTasksAvatarView: NSView {
    override var isFlipped: Bool { true }
    private let imageView = NSImageView()
    private let initials = NSTextField(labelWithString: "")
    private var loadTask: Task<Void, Never>?
    private var representedURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        imageView.imageScaling = .scaleAxesIndependently
        addSubview(initials)
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        representedURL = nil
        imageView.image = nil
        initials.stringValue = ""
    }

    func bind(assignee: CUTask.Assignee) {
        prepareForReuse()
        layer?.backgroundColor = resolvedCGColor(Color(hex: assignee.color ?? "#7A6597"))
        initials.stringValue = assignee.avatarInitials
        initials.font = NSFont.systemFont(ofSize: 8.4, weight: .bold)
        initials.textColor = .white
        initials.alignment = .center
        guard let url = assignee.photoURL else { return }
        representedURL = url
        if let cached = AvatarStore.shared.image(for: url) {
            imageView.image = cached
            return
        }
        loadTask = Task { [weak self] in
            let image = await AvatarStore.shared.load(url).value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.representedURL == url else { return }
                self.imageView.image = image
            }
        }
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        initials.frame = NSRect(x: 0, y: (bounds.height - 12) / 2,
                                width: bounds.width, height: 12)
        layer?.cornerRadius = bounds.width / 2
    }
}

private final class MyTasksHeaderItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("MyTasksHeaderItem")
    private let header = MyTasksHeaderView()
    override func loadView() { view = header }

    func bind(status: CUStatus, count: Int, collapsed: Bool, first: Bool,
              onToggle: @escaping () -> Void) {
        header.bind(status: status, count: count, collapsed: collapsed,
                    first: first, onToggle: onToggle)
    }
}

private final class MyTasksHeaderView: NSView {
    static let studioSource = StudioSourceLocation(file: String(describing: #fileID),
                                                   line: #line)
    override var isFlipped: Bool { true }
    private let chevron = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let rule = CALayer()
    private var onToggle: (() -> Void)?
    private var first = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        chevron.imageScaling = .scaleProportionallyDown
        addSubview(chevron)
        layer?.addSublayer(rule)
        for field in [title, count] {
            field.drawsBackground = false
            field.isBordered = false
            field.isBezeled = false
            field.maximumNumberOfLines = 1
            addSubview(field)
        }
    }

    required init?(coder: NSCoder) { nil }

    func bind(status: CUStatus, count value: Int, collapsed: Bool, first: Bool,
              onToggle: @escaping () -> Void) {
        self.first = first
        self.onToggle = onToggle
        let color = NSColor(Color(statusHex: status.displayHex))
        // Header glyphs stay geometrically fixed. Rotating a reused image
        // layer caused one section's spring/presentation transform to leak
        // into the next header and shifted the visual centre. The premium
        // motion belongs to the task cells inserted/deleted below, not here.
        chevron.image = NSImage(systemSymbolName: collapsed
                                    ? "chevron.right" : "chevron.down",
                                accessibilityDescription: nil)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        chevron.contentTintColor = NSColor(Editorial.inkMute)
        title.stringValue = status.status.uppercased()
        title.font = NSFont.systemFont(ofSize: 11.5 * Editorial.typeScale, weight: .semibold)
        title.textColor = color
        count.stringValue = "\(value)"
        count.font = NSFont.monospacedDigitSystemFont(ofSize: 11 * Editorial.typeScale,
                                                       weight: .medium)
        count.textColor = NSColor(Editorial.inkMute)
        rule.backgroundColor = resolvedCGColor(Editorial.ruleSoft)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Previous SwiftUI header: 28pt list gutter + 8pt internal padding,
        // 18pt spacer before every non-first group, and a 34pt header row.
        let centerY: CGFloat = first ? bounds.midY : 18 + 17
        chevron.frame = NSRect(x: 36, y: centerY - 6, width: 12, height: 12)
        title.sizeToFit()
        title.frame.origin = CGPoint(x: 58, y: centerY - title.frame.height / 2)
        count.sizeToFit()
        count.frame.origin = CGPoint(x: title.frame.maxX + 10,
                                     y: centerY - count.frame.height / 2)
        rule.frame = CGRect(x: 28, y: bounds.height - 0.5,
                            width: max(0, bounds.width - 56), height: 0.5)
    }

    override func mouseDown(with event: NSEvent) { onToggle?() }
}

#if DEBUG
/// Direct Xcode Canvas host for Apollo's production AppKit task viewport.
///
/// The preview renders the actual `NSCollectionView` headers, rows, hover
/// layers and drag/drop implementation. The fixture state is local-only and
/// never initializes ClickUp, Google Calendar, Keychain or synchronization.
@MainActor
private struct MyTasksAppKitListCanvasPreview: View {
    @StateObject private var appState = AppState.preview(.populated)

    private var sections: [MyTasksAppKitSection] {
        ApolloPreviewFixtures.statuses.map { status in
            MyTasksAppKitSection(
                status: status,
                tasks: appState.tasks.filter {
                    $0.status.caseInsensitiveCompare(status.status) == .orderedSame
                },
                collapsed: false
            )
        }
    }

    var body: some View {
        MyTasksAppKitList(
            sections: sections,
            selectedTaskIds: [],
            appState: appState,
            topContentInset: 24,
            bottomContentInset: 24,
            onActivate: { _, _, _ in },
            onToggleStatus: { _ in },
            onBeginDrag: { [$0.id] },
            onEndDrag: { _ in },
            onClearSelection: {},
            onMediaAction: { _, _ in }
        )
        .frame(width: 1_180, height: 780)
        .background(Editorial.paper)
        .preferredColorScheme(.light)
        .defaultAppStorage(ApolloPreviewFixtures.defaults)
    }
}

#Preview("AppKit real · Tarefas") {
    MyTasksAppKitListCanvasPreview()
}

#Preview("AppKit real · Tarefas dark") {
    MyTasksAppKitListCanvasPreview()
        .preferredColorScheme(.dark)
}
#endif
