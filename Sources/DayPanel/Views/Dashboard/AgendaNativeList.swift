import AppKit
import SwiftUI

@MainActor
final class AgendaScrollController {
    fileprivate weak var coordinator: AgendaNativeList.Coordinator?
    fileprivate var pending: (Date?, Bool)?

    func scroll(to date: Date, animated: Bool) {
        if let coordinator { coordinator.scroll(to: date, animated: animated) }
        else { pending = (date, animated) }
    }

    func reset() {
        if let coordinator { coordinator.scroll(to: nil, animated: false) }
        else { pending = (nil, false) }
    }
}

/// AppKit owns viewport sizing and recycling; the existing SwiftUI event row
/// still owns every visible pixel and interaction. Hosts never negotiate an
/// intrinsic size with NSTableView while it scrolls.
struct AgendaNativeList: NSViewRepresentable {
    let rows: [AgendaTimelineRow]
    let appState: AppState
    let topReserve: CGFloat
    let leading: CGFloat
    let trailing: CGFloat
    let controller: AgendaScrollController
    @Environment(\.colorScheme) fileprivate var colorScheme
    @Environment(\.accessibilityReduceMotion) fileprivate var reduceMotion

    func makeCoordinator() -> Coordinator { Coordinator() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView,
                      context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.verticalScroller?.alphaValue = 0
        scroll.verticalScrollElasticity = .automatic
        scroll.horizontalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 60, right: 0)

        let table = AgendaTableView()
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.gridStyleMask = []
        // Match the existing plain SwiftUI List: 17pt horizontal cell spacing
        // places content at x=8 and reserves 9pt at the trailing edge.
        table.intercellSpacing = NSSize(width: 17, height: 0)
        table.usesAutomaticRowHeights = false
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.allowsTypeSelect = false
        table.focusRingType = .none
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        let column = NSTableColumn(identifier: .init("agenda-content"))
        column.minWidth = 0
        column.maxWidth = .greatestFiniteMagnitude
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        scroll.documentView = table
        context.coordinator.table = table
        context.coordinator.scrollView = scroll
        context.coordinator.update(self)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        if coordinator.controller?.coordinator === coordinator {
            coordinator.controller?.coordinator = nil
        }
        coordinator.table?.delegate = nil
        coordinator.table?.dataSource = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        fileprivate weak var table: NSTableView?
        fileprivate weak var scrollView: NSScrollView?
        fileprivate weak var controller: AgendaScrollController?
        private var parent: AgendaNativeList?

        func update(_ next: AgendaNativeList) {
            guard let table else { return }
            let old = parent
            let dataChanged = old == nil || old!.rows != next.rows || old!.topReserve != next.topReserve
            let presentationChanged = old == nil || old!.leading != next.leading || old!.trailing != next.trailing
                || old!.colorScheme != next.colorScheme || old!.reduceMotion != next.reduceMotion
                || old!.appState !== next.appState
            var anchor: (AnyHashable, CGFloat)?
            if dataChanged, let old, let scrollView {
                let y = scrollView.contentView.bounds.minY
                let index = table.row(at: NSPoint(x: 0, y: y)) - 1
                if old.rows.indices.contains(index) {
                    anchor = (old.rows[index].id, y - table.rect(ofRow: index + 1).minY)
                }
            }
            parent = next
            if controller !== next.controller {
                controller?.coordinator = nil
                controller = next.controller
                next.controller.coordinator = self
            }
            if dataChanged {
                table.reloadData()
                if let (id, offset) = anchor, let index = next.rows.firstIndex(where: { $0.id == id }) {
                    setOffset(table.rect(ofRow: index + 1).minY + offset, animated: false)
                }
            } else if presentationChanged {
                table.enumerateAvailableRowViews { _, index in
                    if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? AgendaCell,
                       next.rows.indices.contains(index - 1) {
                        cell.bind(next.rows[index - 1], parent: next)
                    }
                }
            }
            if let pending = next.controller.pending {
                next.controller.pending = nil
                DispatchQueue.main.async { [weak self] in self?.scroll(to: pending.0, animated: pending.1) }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.map { $0.rows.count + 1 } ?? 0 }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard let parent else { return tableView.rowHeight }
            if row == 0 { return parent.topReserve }
            guard parent.rows.indices.contains(row - 1) else { return tableView.rowHeight }
            let item = parent.rows[row - 1]
            // Measured current card geometry: two single-line labels + 16pt
            // padding = 47pt; the original date gutter is 46 + 6 = 52pt.
            // Differential rendered tests protect this typography contract.
            let content: CGFloat = item.event == nil || (item.isFirst && item.isLast) ? 52 : 47
            return content + (item.isLast ? 22 : 6)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let parent else { return nil }
            if row == 0 {
                let id = NSUserInterfaceItemIdentifier("agenda-reserve")
                let view = tableView.makeView(withIdentifier: id, owner: self) ?? NSView()
                view.identifier = id
                return view
            }
            guard parent.rows.indices.contains(row - 1) else { return nil }
            let cell = tableView.makeView(withIdentifier: AgendaCell.reuseID, owner: self) as? AgendaCell ?? AgendaCell()
            cell.bind(parent.rows[row - 1], parent: parent)
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let id = NSUserInterfaceItemIdentifier("agenda-row")
            let view = tableView.makeView(withIdentifier: id, owner: self) as? AgendaRowView ?? AgendaRowView()
            view.identifier = id
            let clips = row == 0 || !(parent?.rows.indices.contains(row - 1) ?? false)
                || parent?.rows[row - 1].isFirst == true
            view.clipsToBounds = clips
            view.wantsLayer = true
            view.layer?.masksToBounds = clips
            return view
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        fileprivate func scroll(to date: Date?, animated: Bool) {
            guard let table, let parent else { return }
            guard let date else { setOffset(0, animated: false); return }
            let day = Calendar.current.startOfDay(for: date)
            guard let index = parent.rows.firstIndex(where: { $0.isFirst && $0.date == day }) else { return }
            setOffset(table.rect(ofRow: index + 1).minY, animated: animated && !parent.reduceMotion)
        }

        private func setOffset(_ y: CGFloat, animated: Bool) {
            guard let table, let scrollView else { return }
            let clip = scrollView.contentView
            let maximum = max(0, table.bounds.height - clip.bounds.height + scrollView.contentInsets.bottom)
            let point = NSPoint(x: clip.bounds.minX, y: min(max(0, y), maximum))
            guard abs(clip.bounds.minY - point.y) > 0.01 else { return }
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.35
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    clip.animator().setBoundsOrigin(point)
                }
            } else { clip.scroll(to: point) }
            scrollView.reflectScrolledClipView(clip)
        }
    }
}

private final class AgendaTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }

    override func prepareContent(in rect: NSRect) {
        let viewport = visibleRect
        guard viewport.height > 0 else {
            super.prepareContent(in: rect)
            return
        }
        // Keep one viewport ready on either side for trackpad momentum.
        // Bound AppKit's predictive requests too: a long jump must never
        // materialize the entire calendar's hosting views.
        let buffer = viewport.insetBy(dx: 0, dy: -viewport.height)
            .intersection(bounds)
        super.prepareContent(in: buffer)
    }
}

private final class AgendaRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
}

private final class AgendaCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("agenda-event")
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private var row: AgendaTimelineRow?
    private weak var appState: AppState?
    private var scheme: ColorScheme?
    private var reduceMotion = false
    private var leading: CGFloat = 0
    private var trailing: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseID
        clipsToBounds = false
        host.sizingOptions = []
        host.clipsToBounds = false
        addSubview(host)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    func bind(_ value: AgendaTimelineRow, parent: AgendaNativeList) {
        if leading != parent.leading || trailing != parent.trailing {
            leading = parent.leading
            trailing = parent.trailing
            needsLayout = true
        }
        guard row != value || appState !== parent.appState || scheme != parent.colorScheme
                || reduceMotion != parent.reduceMotion else { return }
        row = value
        appState = parent.appState
        scheme = parent.colorScheme
        reduceMotion = parent.reduceMotion
        host.rootView = AnyView(AgendaTimelineEventRow(row: value, appState: parent.appState)
            .id(AgendaTimelineRow.EventID(date: value.date,
                calendarIdentity: value.event?.calendarIdentity ?? ""))
            .environment(\.colorScheme, parent.colorScheme))
    }

    override func layout() {
        super.layout()
        let target = NSRect(x: leading, y: 0, width: max(0, bounds.width - leading - trailing), height: bounds.height)
        if host.frame != target { host.frame = target }
    }
}
