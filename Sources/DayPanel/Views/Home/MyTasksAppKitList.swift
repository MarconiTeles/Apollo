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
    let onEndDrag: () -> Void

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

            var id: String {
                switch self {
                case .header(let status, _, _, _): return "h:\(status.id)"
                case .task(let task): return "t:\(task.id)"
                }
            }

            static func == (lhs: Row, rhs: Row) -> Bool {
                switch (lhs, rhs) {
                case let (.header(ls, lc, lx, lf), .header(rs, rc, rx, rf)):
                    return ls.id == rs.id && ls.status == rs.status
                        && ls.displayHex == rs.displayHex
                        && lc == rc && lx == rx && lf == rf
                case let (.task(l), .task(r)): return l == r
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
        private var onEndDrag: () -> Void
        private var statusPopover: NSPopover?
        weak var collection: NSCollectionView?

        init(parent: MyTasksAppKitList) {
            appState = parent.appState
            onActivate = parent.onActivate
            onToggleStatus = parent.onToggleStatus
            onBeginDrag = parent.onBeginDrag
            onEndDrag = parent.onEndDrag
        }

        func update(parent: MyTasksAppKitList, force: Bool = false) {
            appState = parent.appState
            onActivate = parent.onActivate
            onToggleStatus = parent.onToggleStatus
            onBeginDrag = parent.onBeginDrag
            onEndDrag = parent.onEndDrag
            let newRows = Self.flatten(parent.sections)
            let contentChanged = rows != newRows
            let selectionChanged = selectedIds != parent.selectedTaskIds
            selectedIds = parent.selectedTaskIds
            guard force || contentChanged || selectionChanged else { return }

            if contentChanged {
                let idsStable = rows.map(\.id) == newRows.map(\.id)
                rows = newRows
                if idsStable { rebindVisibleCells() }
                else { collection?.reloadData() }
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
            item.onEndDrag = { [weak self] in self?.onEndDrag() }
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
            statusPopover?.close()
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            let picker = StatusPickerPopover(statuses: appState.availableStatuses,
                                             currentStatusName: task.status) { [weak self, weak popover] status in
                guard let self else { return }
                Task { await self.appState.updateTaskStatus(task, to: status) }
                popover?.close()
            }
            let host = NSHostingController(rootView: picker)
            if #available(macOS 13.0, *) { host.sizingOptions = [.preferredContentSize] }
            popover.contentViewController = host
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            statusPopover = popover
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
            }
        }

        func collectionView(_ collectionView: NSCollectionView,
                            validateDrop draggingInfo: NSDraggingInfo,
                            proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                            dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
            guard draggingInfo.draggingPasteboard.string(forType: .string) != nil,
                  targetStatus(at: proposedDropIndexPath.pointee as IndexPath) != nil
            else { return [] }
            proposedDropOperation.pointee = .on
            return .move
        }

        func collectionView(_ collectionView: NSCollectionView,
                            acceptDrop draggingInfo: NSDraggingInfo,
                            indexPath: IndexPath,
                            dropOperation: NSCollectionView.DropOperation) -> Bool {
            guard let status = targetStatus(at: indexPath),
                  let raw = draggingInfo.draggingPasteboard.string(forType: .string)
            else { onEndDrag(); return false }
            let ids = MyTasksDragPayload.decode(raw)
            guard !ids.isEmpty else { onEndDrag(); return false }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for id in ids {
                    guard let task = self.appState.tasks.first(where: { $0.id == id }),
                          task.status.caseInsensitiveCompare(status.status) != .orderedSame
                    else { continue }
                    await self.appState.updateTaskStatus(task, to: status, silent: true)
                }
                self.onEndDrag()
            }
            return true
        }
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
    var onEndDrag: (() -> Void)?
    var contextActionsProvider: ((CUTask) -> [TaskContextAction]?)? {
        didSet { row.contextActionsProvider = contextActionsProvider }
    }

    override func loadView() {
        view = row
        row.onActivate = { [weak self] in
            guard let self, let task else { return }
            onRowClick?(task, MouseOriginCapture.currentClickRectInMainWindow())
        }
        row.onComplete = { [weak self] in
            guard let self, let task, let appState,
                  let target = appState.doneTargetByStatus[task.status]
                    ?? appState.doneTargetFallback else { return }
            Task { await appState.updateTaskStatus(task, to: target) }
        }
        row.onBeginDrag = { [weak self] in
            guard let self, let task else { return nil }
            return onBeginDrag?(task)
        }
        row.onEndDrag = { [weak self] in self?.onEndDrag?() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        task = nil
        appState = nil
        onRowClick = nil
        onBeginDrag = nil
        onEndDrag = nil
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

    var onActivate: (() -> Void)?
    var onComplete: (() -> Void)?
    var onBeginDrag: (() -> String?)?
    var onEndDrag: (() -> Void)?
    var contextActionsProvider: ((CUTask) -> [TaskContextAction]?)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        hoverLayer.cornerRadius = 10
        hoverLayer.cornerCurve = .continuous
        layer?.addSublayer(hoverLayer)
        layer?.addSublayer(rule)

        done.onActivate = { [weak self] in self?.onComplete?() }
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
        if needsUpdate { applyBackground() }
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
              !ScrollStateObserver.isScrollingNow else { return }
        hovered = true
        applyBackground()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        pressed = false
        applyBackground()
    }

    override func mouseDown(with event: NSEvent) {
        guard appState?.anyPopupOpen != true else { return }
        pressed = true
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard appState?.anyPopupOpen != true,
              !dragStarted, let payload = onBeginDrag?(), !payload.isEmpty else { return }
        dragStarted = true
        pressed = false

        let pasteboard = NSPasteboardItem()
        pasteboard.setString(payload, forType: .string)
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
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
        onEndDrag?()
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
    var onActivate: (() -> Void)?

    func bind(statusColor: NSColor, completed: Bool) {
        self.statusColor = statusColor
        self.completed = completed
        needsDisplay = true
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
            let inner = statusColor.withAlphaComponent(0.62)
            NSGradient(starting: inner, ending: paper)?.draw(in: path,
                                                              relativeCenterPosition: .zero)
            NSColor(Editorial.inkFaint.opacity(0.85)).setStroke()
            path.lineWidth = 0.75
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard !completed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onActivate?()
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
        chevron.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
                                accessibilityDescription: nil)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        chevron.contentTintColor = NSColor(Editorial.inkMute)
        chevron.layer?.transform = CATransform3DIdentity
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
