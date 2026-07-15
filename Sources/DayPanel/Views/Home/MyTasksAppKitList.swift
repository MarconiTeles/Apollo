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
        layout.sectionInset = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
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
        context.coordinator.update(parent: self, force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        applyInsets(to: scroll)
        context.coordinator.update(parent: self)
    }

    private func applyInsets(to scroll: NSScrollView) {
        let value = NSEdgeInsets(top: topContentInset, left: 0,
                                 bottom: bottomContentInset, right: 0)
        let current = scroll.contentInsets
        if current.top != value.top || current.left != value.left
            || current.bottom != value.bottom || current.right != value.right {
            scroll.contentInsets = value
            scroll.scrollerInsets = value
        }
    }

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
        private let statusBubble = StatusPickerBubblePresenter()
        weak var collection: NSCollectionView?

        init(parent: MyTasksAppKitList) {
            appState = parent.appState
            onActivate = parent.onActivate
            onToggleStatus = parent.onToggleStatus
            onBeginDrag = parent.onBeginDrag
            onEndDrag = parent.onEndDrag
            onClearSelection = parent.onClearSelection
        }

        func update(parent: MyTasksAppKitList, force: Bool = false) {
            appState = parent.appState
            onActivate = parent.onActivate
            onToggleStatus = parent.onToggleStatus
            onBeginDrag = parent.onBeginDrag
            onEndDrag = parent.onEndDrag
            onClearSelection = parent.onClearSelection
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
            let height: CGFloat
            switch rows[indexPath.item] {
            // Exact SwiftUI geometry from the previous list:
            // header line ~=14pt + 10pt vertical padding; every following
            // group carries the former 18pt inter-section spacer.
            case .header(_, _, _, let first): height = first ? 34 : 52
            case .task: height = 42
            case .dropPlaceholder: height = 42
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
                for id in ids {
                    guard let task = self.appState.tasks.first(where: { $0.id == id }),
                          task.status.caseInsensitiveCompare(status.status) != .orderedSame
                    else { continue }
                    await self.appState.updateTaskStatus(task, to: status, silent: true)
                }
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

private final class MyTasksNativeRowView: NSView, NSDraggingSource {
    private static weak var activeHoverRow: MyTasksNativeRowView?
    override var isFlipped: Bool { true }

    private let hoverLayer = CALayer()
    private let rule = CALayer()
    private let done = MyTasksDoneCircle()
    private let title = NSTextField(labelWithString: "")
    private let priorityDot = CALayer()
    private let priority = NSTextField(labelWithString: "")
    private let avatar = MyTasksAvatarView()
    private let assignee = NSTextField(labelWithString: "")
    private let date = NSTextField(labelWithString: "")
    private let more = NSButton()

    private var task: CUTask?
    private weak var appState: AppState?
    private var anyPopupCancellable: AnyCancellable?
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var bulkSelected = false
    private var pressed = false
    private var dragStarted = false
    private var mouseDownTimestamp: TimeInterval?
    private var statusTint: NSColor = .systemGray

    var onActivate: (() -> Void)?
    var onStatusPicker: ((NSView) -> Void)?
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

        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Mais")
        more.imageScaling = .scaleProportionallyDown
        more.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        more.isBordered = false
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
        task = nil
        appState = nil
        avatar.prepareForReuse()
        hovered = false
        pressed = false
        dragStarted = false
        bulkSelected = false
        setHoverMotion(active: false, animated: false)
        applyBackground()
    }

    func bind(task: CUTask, appState: AppState) {
        self.task = task
        self.appState = appState
        if anyPopupCancellable == nil {
            anyPopupCancellable = appState.$anyPopupOpen
                .receive(on: RunLoop.main)
                .sink { [weak self] open in
                    guard let self else { return }
                    self.done.isEnabled = !open
                    self.more.isEnabled = !open
                    if open { self.forceExitAllInteraction() }
                }
        }
        done.isEnabled = !appState.anyPopupOpen
        more.isEnabled = !appState.anyPopupOpen
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
            priorityDot.backgroundColor = resolvedCGColor(Color(nsColor: color))
            priorityDot.cornerRadius = 3
            priority.isHidden = false
            priorityDot.isHidden = false
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

    /// Elastic no-reflow lift matching the supplied hover reference. The
    /// collection layout remains unchanged; only this recycled row's layer
    /// scales around its centre and temporarily rises above its neighbours.
    private func setHoverMotion(active: Bool, animated: Bool) {
        guard let layer else { return }
        let target = CATransform3DMakeScale(active ? 1.008 : 1,
                                            active ? 1.025 : 1,
                                            1)
        if animated {
            let spring = CASpringAnimation(keyPath: "transform")
            spring.fromValue = layer.presentation()?.value(forKeyPath: "transform")
                ?? NSValue(caTransform3D: layer.transform)
            spring.toValue = NSValue(caTransform3D: target)
            spring.mass = 0.8
            spring.stiffness = 230
            spring.damping = 22
            spring.initialVelocity = 0
            spring.duration = min(0.42, spring.settlingDuration)
            layer.add(spring, forKey: "apolloCapsuleHover")
        } else {
            layer.removeAnimation(forKey: "apolloCapsuleHover")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = target
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

        let moreWidth: CGFloat = 18
        let gap: CGFloat = 14
        let dateWidth: CGFloat = 92
        let assigneeWidth: CGFloat = 132
        let priorityWidth: CGFloat = 112
        let moreX = bounds.width - edge - moreWidth
        let dateX = moreX - gap - dateWidth
        let assigneeX = dateX - gap - assigneeWidth
        let priorityX = assigneeX - gap - priorityWidth
        let titleX = edge + 10 + 12

        title.frame = NSRect(x: titleX, y: centeredY(for: title, at: centerY),
                             width: max(0, priorityX - gap - titleX), height: fittedHeight(title))

        priority.sizeToFit()
        let priorityH = priority.frame.height
        priorityDot.frame = CGRect(x: priorityX, y: centerY - 3, width: 6, height: 6)
        priority.frame = NSRect(x: priorityX + 11, y: centerY - priorityH / 2,
                                width: max(0, priorityWidth - 11), height: priorityH)

        avatar.frame = NSRect(x: assigneeX, y: centerY - 10, width: 20, height: 20)
        assignee.sizeToFit()
        let assigneeH = assignee.frame.height
        assignee.frame = NSRect(x: assigneeX + 27, y: centerY - assigneeH / 2,
                                width: assigneeWidth - 27, height: assigneeH)

        date.sizeToFit()
        let dateSize = date.frame.size
        date.frame = NSRect(x: dateX + max(0, dateWidth - dateSize.width),
                            y: centerY - dateSize.height / 2,
                            width: min(dateSize.width, dateWidth), height: dateSize.height)
        more.frame = NSRect(x: moreX, y: centerY - 9, width: 18, height: 18)
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
