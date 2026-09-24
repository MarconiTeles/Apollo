#if APOLLO_TASKS_REACT
import AppKit
import Combine
import OSLog
import SwiftUI
import WebKit

// Apollo · Tarefas rendered by React (web/apollo-tasks) inside a transparent
// WKWebView. DEV-only (`-DAPOLLO_TASKS_REACT`, script/build_dev_tasks_react.sh):
// production keeps MyTasksAppKitList and never compiles this file.
//
// Division of labour — identical inputs and outputs to MyTasksAppKitList:
// • Swift owns data, colours (resolved by AppKit under the view's appearance),
//   SF Symbols, text-cell metrics and every action (NSMenu, status bubble,
//   media/review flows, status moves + undo, Finder file drops).
// • React owns layout, painting, hover/press motion, task drags and the
//   insertion slot. Scrolling is WebKit's threaded scrolling: no row work
//   happens on the app's main thread while the list moves.

/// `--tasks-renderer=appkit` restores the native viewport in this build (A/B).
enum MyTasksRenderer {
    static let usesReact = !ProcessInfo.processInfo.arguments.contains("--tasks-renderer=appkit")
}

// MARK: - Representable

struct MyTasksReactList: NSViewRepresentable {
    let sections: [MyTasksAppKitSection]
    let selectedTaskIds: Set<String>
    let appState: AppState
    var headerOcclusionHeight: CGFloat = 0
    var topContentInset: CGFloat = 72
    var bottomContentInset: CGFloat = 112
    let onActivate: (CUTask, NSEvent.ModifierFlags, CGRect) -> Void
    let onToggleStatus: (String) -> Void
    let onBeginDrag: (CUTask) -> [String]
    let onEndDrag: (Bool) -> Void
    let onClearSelection: () -> Void
    let onMediaAction: (CUTask, TaskMediaFlowMode) -> Void
    let onBulkMediaAction: () -> Void
    let onFileDrop: (CUTask, [URL]) -> Void
    /// Finder files hovering the list while 2+ tasks are selected.
    let onListFileDragChanged: (Bool) -> Void
    /// Finder files dropped on the list while 2+ tasks are selected.
    let onListFileDrop: ([URL]) -> Void

    func makeCoordinator() -> MyTasksReactCoordinator { MyTasksReactCoordinator() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MyTasksReactContainer,
                      context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func makeNSView(context: Context) -> MyTasksReactContainer {
        let container = MyTasksReactContainer()
        context.coordinator.attach(to: container, parent: self)
        return container
    }

    func updateNSView(_ container: MyTasksReactContainer, context: Context) {
        context.coordinator.update(parent: self)
    }

    static func dismantleNSView(_ container: MyTasksReactContainer,
                                coordinator: MyTasksReactCoordinator) {
        coordinator.detach()
    }
}

/// Owns the shared web view while the list is on screen. Like the native
/// viewport, it becomes first responder on an empty-area click.
final class MyTasksReactContainer: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

// MARK: - Web view

@MainActor
protocol MyTasksReactFileDropDelegate: AnyObject {
    func fileDragUpdated(_ info: NSDraggingInfo) -> NSDragOperation
    func fileDragExited()
    func performFileDrop(_ info: NSDraggingInfo) -> Bool
}

final class MyTasksReactWebView: WKWebView, HeaderOccludingViewport {
    var headerOcclusionHeight: CGFloat = 0
    weak var fileDropDelegate: MyTasksReactFileDropDelegate?
    var onAppearanceChange: (() -> Void)?

    /// Keyboard stays with the window/SwiftUI (⌘Z, Esc monitors); the page
    /// has no text input. Mouse handling does not need first responder.
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let windowPoint = superview?.convert(point, to: nil) ?? point
        guard !isBehindPageHeader(windowPoint: windowPoint) else { return nil }
        return super.hitTest(point)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    // Finder files never reach the page (WebKit would try to open them);
    // task drags between rows stay HTML5 and go through WebKit.
    private static func carriesFiles(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.carriesFiles(sender) else { return super.draggingEntered(sender) }
        return fileDropDelegate?.fileDragUpdated(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.carriesFiles(sender) else { return super.draggingUpdated(sender) }
        return fileDropDelegate?.fileDragUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let sender, !Self.carriesFiles(sender) {
            super.draggingExited(sender)
            return
        }
        fileDropDelegate?.fileDragExited()
        if sender == nil { super.draggingExited(sender) }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard Self.carriesFiles(sender) else { return super.prepareForDragOperation(sender) }
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard Self.carriesFiles(sender) else { return super.performDragOperation(sender) }
        return fileDropDelegate?.performFileDrop(sender) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if let sender, Self.carriesFiles(sender) { return }
        super.concludeDragOperation(sender)
    }
}

// MARK: - Host (one web process for the app's lifetime)

@MainActor
final class MyTasksReactHost: NSObject {
    static let shared = MyTasksReactHost()
    static let log = Logger(subsystem: "com.painellunar.app", category: "TasksReact")

    private(set) var webView: MyTasksReactWebView?
    private(set) var booted = false
    weak var client: MyTasksReactCoordinator?
    private var pending: [String] = []
    private let avatars = MyTasksAvatarSchemeHandler()

    /// Starts the web process during the route's mount delay so the list is
    /// ready by the time SwiftUI swaps the skeleton out.
    func prewarm() { _ = ensureWebView() }

    func ensureWebView() -> MyTasksReactWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(avatars, forURLScheme: MyTasksAvatarSchemeHandler.scheme)
        configuration.userContentController.add(MyTasksReactMessageProxy(host: self), name: "apolloTasks")
        let webView = MyTasksReactWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = self
        Self.hideTopScrollPocket(webView)
        self.webView = webView
        load(webView)
        return webView
    }

    /// The list supplies its own Liquid Glass header. WebKit's automatic top
    /// scroll pocket (macOS 26) would draw a second, opaque edge effect under
    /// it; hide it the same way WebKit does for full screen.
    static var supportsObscuredInsets: Bool {
        WKWebView.instancesRespond(to: NSSelectorFromString("_addReasonToHideTopScrollPocket:"))
    }

    private static func hideTopScrollPocket(_ webView: WKWebView) {
        let selector = NSSelectorFromString("_addReasonToHideTopScrollPocket:")
        if webView.responds(to: selector) {
            typealias Function = @convention(c) (AnyObject, Selector, UInt) -> Void
            let implementation = webView.method(for: selector)
            unsafeBitCast(implementation, to: Function.self)(webView, selector, 1 << 0)
        }
        // Sticky group headers sit at the obscured edge; WebKit would extend
        // their colour into the header band above. The glass header owns it.
        let suppress = NSSelectorFromString("_setShouldSuppressTopColorExtensionView:")
        if webView.responds(to: suppress) {
            typealias Function = @convention(c) (AnyObject, Selector, Bool) -> Void
            let implementation = webView.method(for: suppress)
            unsafeBitCast(implementation, to: Function.self)(webView, suppress, true)
        }
    }

    private func load(_ webView: WKWebView) {
        booted = false
        #if APOLLO_DEV
        // `APOLLO_TASKS_URL` = Vite dev server or a file:// index.html, so
        // the page can iterate without rebuilding the app.
        if let override = ProcessInfo.processInfo.environment["APOLLO_TASKS_URL"],
           let url = URL(string: override) {
            if url.isFileURL {
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                webView.load(URLRequest(url: url))
            }
            return
        }
        #endif
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html",
                                        subdirectory: "ApolloTasks") else {
            Self.log.error("ApolloTasks resource missing")
            return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func send(_ json: String) {
        guard booted, let webView else {
            pending.append(json)
            return
        }
        webView.evaluateJavaScript("window.apolloTasks.update(\(json))") { _, error in
            if let error { Self.log.error("update failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func evaluate(_ script: String, completion: ((Any?) -> Void)? = nil) {
        guard booted, let webView else { completion?(nil); return }
        webView.evaluateJavaScript(script) { result, _ in completion?(result) }
    }

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "boot":
            booted = true
            // Anything queued before the page existed is superseded by the
            // full snapshot the client sends on boot.
            pending.removeAll()
            client?.hostDidBoot()
        case "error":
            Self.log.error("script error: \(message["message"] as? String ?? "?", privacy: .public)")
        default:
            client?.receive(type: type, message: message)
        }
    }
}

extension MyTasksReactHost: WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Self.log.error("web content process terminated — reloading")
        load(webView)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Only the list document itself; never navigate to dropped/linked content.
        let url = navigationAction.request.url
        var allowed = url?.isFileURL == true
        #if APOLLO_DEV
        if let override = ProcessInfo.processInfo.environment["APOLLO_TASKS_URL"],
           let url, url.absoluteString.hasPrefix(override) {
            allowed = true
        }
        #endif
        decisionHandler(allowed ? .allow : .cancel)
    }
}

/// WKUserContentController retains its handlers; the proxy keeps that edge weak.
private final class MyTasksReactMessageProxy: NSObject, WKScriptMessageHandler {
    weak var host: MyTasksReactHost?
    init(host: MyTasksReactHost) { self.host = host }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { host?.receive(message.body) }
    }
}

// MARK: - Payload (web/apollo-tasks/src/lib/types.ts)

struct MyTasksReactMedia: Encodable, Equatable {
    let label: String
    let phase: String?
    let progress: Double
    let showProgress: Bool
    let badge: Int
    let small: Bool
    let usesAccent: Bool
    let titleColor: String
    let background: String
    let progressColor: String
    let hoverBackground: String
    let hoverTitleColor: String
}

struct MyTasksReactRow: Encodable, Equatable {
    struct Priority: Encodable, Equatable { let label: String; let color: String }
    struct Assignee: Encodable, Equatable {
        let name: String
        let initials: String
        let background: String
        let photo: String?
    }
    struct DueDate: Encodable, Equatable { let text: String; let tone: String }

    let k: String
    let id: String
    var title: String
    var status: String
    var sc: String
    // Task
    var completed: Bool?
    var priority: Priority?
    var assignee: Assignee?
    var date: DueDate?
    var media: MyTasksReactMedia?
    var review: String?
    // Header
    var color: String?
    var count: Int?
    /// Open tasks past due, summarised next to a collapsed group's count.
    var overdue: Int?
    var collapsed: Bool?
    var first: Bool?

    var key: String { "\(k):\(id)" }
}

struct MyTasksReactGlyph: Encodable, Equatable {
    let url: String
    let width: CGFloat
    let height: CGFloat
}

struct MyTasksReactInsets: Encodable, Equatable {
    let top: CGFloat
    let bottom: CGFloat
    let occlusion: CGFloat
    let mode: String
}

struct MyTasksReactFonts: Encodable, Equatable {
    let title: CGFloat
    let priority: CGFloat
    let assignee: CGFloat
    let date: CGFloat
    let headerTitle: CGFloat
    let headerCount: CGFloat
    let slot: CGFloat
}

struct MyTasksReactPatch: Encodable {
    let seq: Int
    var reset: Bool?
    var order: [String]?
    var upsert: [MyTasksReactRow]?
    var remove: [String]?
    var selected: [String]?
    var popupOpen: Bool?
    var windowKey: Bool?
    var theme: [String: String]?
    var dark: Bool?
    var widths: MyTasksColumnLayout.Widths?
    var insets: MyTasksReactInsets?
    var glyphs: [String: MyTasksReactGlyph]?
    var fonts: MyTasksReactFonts?
    var animate: Bool?
    var resetScroll: Bool?
}

// MARK: - Coordinator

@MainActor
final class MyTasksReactCoordinator: NSObject, MyTasksReactFileDropDelegate {
    private var parent: MyTasksReactList?
    private weak var container: MyTasksReactContainer?
    private let host = MyTasksReactHost.shared
    private var webView: MyTasksReactWebView? { host.webView }

    // Last state the page acknowledged receiving.
    private var sentRows: [String: MyTasksReactRow] = [:]
    private var sentOrder: [String] = []
    private var sentSelected: [String]?
    private var sentPopup: Bool?
    private var sentWindowKey: Bool?
    private var sentTheme: [String: String]?
    private var sentWidths: MyTasksColumnLayout.Widths?
    private var sentInsets: MyTasksReactInsets?
    private var sentScale: CGFloat?
    private var needsFull = true
    private var pendingResetScroll = true
    private var seq = 0
    private var revealSeq: Int?

    private var tasksById: [String: CUTask] = [:]
    private var orderedTasks: [CUTask] = []
    private var watchedTasks: [String: CUTask] = [:]
    private var colorCache: [String: String] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var refreshScheduled = false

    private let statusBubble = StatusPickerBubblePresenter()
    private let statusAnchor = MyTasksReactAnchor()
    private let originAnchor = MyTasksReactAnchor()

    // Finder file drag state.
    private var fileDropTaskId: String?
    private var fileDragPoint: NSPoint?
    private var listFileDragActive = false

    // MARK: Lifecycle

    func attach(to container: MyTasksReactContainer, parent: MyTasksReactList) {
        self.parent = parent
        self.container = container
        container.onCancel = { [weak self] in self?.parent?.onClearSelection() }
        let webView = host.ensureWebView()
        if let previous = host.client, previous !== self { previous.releaseWebView() }
        host.client = self
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        webView.fileDropDelegate = self
        webView.onAppearanceChange = { [weak self] in self?.appearanceChanged() }
        // Hidden until the page has painted THIS list: the shared page may
        // still hold the previous mount's rows and scroll offset.
        webView.alphaValue = 0
        container.addSubview(webView)
        for anchor in [statusAnchor, originAnchor] where anchor.superview !== webView {
            webView.addSubview(anchor)
        }
        needsFull = true
        pendingResetScroll = true
        subscribe()
        update(parent: parent)
    }

    func detach() {
        cancellables.removeAll()
        statusBubble.dismiss(animated: false)
        for id in watchedTasks.keys { TaskReviewUpdateStore.shared.unwatch(taskId: id) }
        watchedTasks.removeAll()
        if listFileDragActive { parent?.onListFileDragChanged(false) }
        listFileDragActive = false
        fileDropTaskId = nil
        releaseWebView()
        if host.client === self { host.client = nil }
        parent = nil
    }

    fileprivate func releaseWebView() {
        guard let webView, webView.superview === container else { return }
        webView.fileDropDelegate = nil
        webView.onAppearanceChange = nil
        webView.removeFromSuperview()
    }

    func update(parent: MyTasksReactList) {
        self.parent = parent
        refresh()
    }

    func hostDidBoot() {
        needsFull = true
        pendingResetScroll = true
        refresh()
    }

    private func subscribe() {
        cancellables.removeAll()
        guard let appState = parent?.appState else { return }
        let schedule: () -> Void = { [weak self] in self?.scheduleRefresh() }
        appState.taskMediaTransfers.$batches.sink { _ in schedule() }.store(in: &cancellables)
        TaskReviewUpdateStore.shared.$updatesByTask.sink { _ in schedule() }.store(in: &cancellables)
        TaskReviewUpdateStore.shared.$reviewedTaskIds.sink { _ in schedule() }.store(in: &cancellables)
        appState.$anyPopupOpen.sink { _ in schedule() }.store(in: &cancellables)
        MyTasksColumnLayout.shared.$widths.sink { _ in schedule() }.store(in: &cancellables)
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            center.publisher(for: name).sink { _ in schedule() }.store(in: &cancellables)
        }
        center.publisher(for: NSColor.systemColorsDidChangeNotification)
            .sink { [weak self] _ in self?.appearanceChanged() }
            .store(in: &cancellables)
    }

    private func appearanceChanged() {
        colorCache.removeAll()
        sentTheme = nil
        scheduleRefresh()
    }

    /// Store publishers fire in willSet; read their new values next turn.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    // MARK: Snapshot → patch

    private func refresh() {
        guard let parent, let webView, host.booted else { return }
        let appearance = webView.effectiveAppearance
        var patch = MyTasksReactPatch(seq: seq + 1)
        var changed = false

        var rows: [MyTasksReactRow] = []
        appearance.performAsCurrentDrawingAppearance {
            rows = buildRows(parent)
            let theme = buildTheme(appearance)
            if theme != sentTheme || needsFull {
                patch.theme = theme
                patch.dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                sentTheme = theme
                changed = true
            }
        }

        let order = rows.map(\.key)
        let next = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        if needsFull {
            patch.reset = true
            patch.order = order
            patch.upsert = rows
            changed = true
        } else {
            let upserts = rows.filter { sentRows[$0.key] != $0 }
            let removed = sentRows.keys.filter { next[$0] == nil }
            if order != sentOrder { patch.order = order }
            if !upserts.isEmpty { patch.upsert = upserts }
            if !removed.isEmpty { patch.remove = removed }
            if patch.order != nil || patch.upsert != nil || patch.remove != nil {
                patch.animate = true
                changed = true
            }
        }
        sentRows = next
        sentOrder = order

        let selected = orderedTasks.map(\.id).filter(parent.selectedTaskIds.contains)
            + parent.selectedTaskIds.subtracting(orderedTasks.map(\.id)).sorted()
        if selected != sentSelected || needsFull {
            patch.selected = selected
            sentSelected = selected
            changed = true
        }
        let popupOpen = parent.appState.anyPopupOpen
        if popupOpen != sentPopup || needsFull {
            patch.popupOpen = popupOpen
            sentPopup = popupOpen
            changed = true
        }
        let windowKey = webView.window?.isKeyWindow ?? true
        if windowKey != sentWindowKey || needsFull {
            patch.windowKey = windowKey
            sentWindowKey = windowKey
            changed = true
        }
        let widths = MyTasksColumnLayout.shared.widths
        if widths != sentWidths || needsFull {
            patch.widths = widths
            sentWidths = widths
            changed = true
        }
        let insets = applyInsets(parent, to: webView)
        if insets != sentInsets || needsFull {
            patch.insets = insets
            sentInsets = insets
            changed = true
        }
        let scale = webView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if scale != sentScale || needsFull {
            patch.glyphs = MyTasksReactResources.glyphs(scale: scale)
            patch.fonts = MyTasksReactResources.fonts
            sentScale = scale
            changed = true
        }
        if pendingResetScroll {
            patch.resetScroll = true
            pendingResetScroll = false
            revealSeq = patch.seq
        }
        needsFull = false
        webView.headerOcclusionHeight = parent.headerOcclusionHeight
        updateWatchedContent()
        guard changed else { return }
        seq = patch.seq
        guard let data = try? Self.encoder.encode(patch),
              let json = String(data: data, encoding: .utf8) else { return }
        host.send(json)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    private func applyInsets(_ parent: MyTasksReactList, to webView: WKWebView) -> MyTasksReactInsets {
        let obscured = MyTasksReactHost.supportsObscuredInsets
        // Only the page header is obscured. WebKit clips sticky layers at the
        // obscured edge, so the 10pt breathing room before the first group
        // (topContentInset − occlusion) is page padding instead: group bands
        // then stick flush under the header rule.
        let value = obscured
            ? NSEdgeInsets(top: parent.headerOcclusionHeight, left: 0,
                           bottom: parent.bottomContentInset, right: 0)
            : NSEdgeInsets()
        let current = webView.obscuredContentInsets
        if current.top != value.top || current.bottom != value.bottom
            || current.left != value.left || current.right != value.right {
            webView.obscuredContentInsets = value
        }
        return MyTasksReactInsets(top: parent.topContentInset,
                                  bottom: parent.bottomContentInset,
                                  occlusion: parent.headerOcclusionHeight,
                                  mode: obscured ? "obscured" : "padding")
    }

    private func buildRows(_ parent: MyTasksReactList) -> [MyTasksReactRow] {
        let appState = parent.appState
        let batches = appState.taskMediaTransfers.batches
        let reviews = TaskReviewUpdateStore.shared
        var rows: [MyTasksReactRow] = []
        var byId: [String: CUTask] = [:]
        var ordered: [CUTask] = []
        rows.reserveCapacity(parent.sections.reduce(0) { $0 + $1.tasks.count + 1 })
        let startOfToday = Calendar.current.startOfDay(for: Date())
        for (index, section) in parent.sections.enumerated() {
            let status = section.status
            let color = statusColor(status.displayHex)
            rows.append(MyTasksReactRow(
                k: "h", id: status.id,
                title: status.status.uppercased(),
                status: status.status.lowercased(),
                sc: color.components,
                color: color.css,
                count: section.tasks.count,
                overdue: section.tasks.reduce(0) { total, task in
                    guard let due = task.dueDate, !task.isCompleted, due < startOfToday else { return total }
                    return total + 1
                },
                collapsed: section.collapsed,
                first: index == 0))
            for task in section.tasks { byId[task.id] = task }
            guard !section.collapsed else { continue }
            for task in section.tasks {
                ordered.append(task)
                rows.append(taskRow(task, batch: batches[task.id], reviews: reviews))
            }
        }
        tasksById = byId
        orderedTasks = ordered
        return rows
    }

    private func taskRow(_ task: CUTask,
                         batch: TaskMediaTransferStore.BatchState?,
                         reviews: TaskReviewUpdateStore) -> MyTasksReactRow {
        var row = MyTasksReactRow(k: "t", id: task.id, title: task.title,
                                  status: task.status.lowercased(),
                                  sc: statusColor(task.statusDisplayHex).components)
        row.completed = task.isCompleted
        if task.priority > 0 && task.priority <= 2 {
            row.priority = .init(label: task.priorityLabel.uppercased(),
                                 color: cached("hex:\(task.priorityHex)") { NSColor(Color(hex: task.priorityHex)) })
        }
        if let first = task.assignees.first {
            let hex = first.color ?? "#7A6597"
            row.assignee = .init(name: Self.friendlyFirstName(first.username),
                                 initials: first.avatarInitials,
                                 background: cached("hex:\(hex)") { NSColor(Color(hex: hex)) },
                                 photo: first.photoURL.map(MyTasksAvatarSchemeHandler.url(for:)))
        }
        if let due = task.dueDate {
            let calendar = Calendar.current
            let today = calendar.isDateInToday(due)
            let overdue = due < calendar.startOfDay(for: Date()) && !task.isCompleted
            row.date = .init(text: Self.relativeDate(due),
                             tone: today ? "today" : (overdue ? "overdue" : "soft"))
        }
        row.media = media(MyTasksMediaPresentation(batch: batch))
        switch reviews.capsuleState(for: task.id) {
        case .update?: row.review = "update"
        case .reviewed?: row.review = "reviewed"
        case nil: row.review = "hidden"
        }
        return row
    }

    /// updateMediaButton + setMediaHover, resolved to colours.
    private func media(_ presentation: MyTasksMediaPresentation) -> MyTasksReactMedia {
        let phase = presentation.phase
        let composing = presentation.composing
        let base = NSColor.controlAccentColor
        let accentColor = composing ? (base.blended(withFraction: 0.35, of: .white) ?? base) : base
        let accent = phase == .ready || phase == .sending || phase == .partialFailure
        let activeProgress = phase == .preparing || phase == .sending
        let title: NSColor = phase == .preparing
            ? accentColor : (accent ? .white : NSColor(Editorial.inkSoft))
        let background: NSColor = phase == .preparing
            ? accentColor.withAlphaComponent(composing ? 0.16 : 0.10)
            : (accent ? base.withAlphaComponent(phase == .sending ? 0.36 : 1)
                      : NSColor(Editorial.inkFaint.opacity(0.14)))
        let fill: NSColor = phase == .preparing
            ? accentColor.withAlphaComponent(composing ? 0.38 : 0.30) : base
        let key = "media:\(String(describing: phase)):\(composing)"
        return MyTasksReactMedia(
            label: presentation.label,
            phase: phase.map(Self.phaseName),
            progress: Double(activeProgress ? presentation.progress : (phase == .ready ? 1 : 0)),
            showProgress: activeProgress,
            badge: presentation.badgeCount,
            small: presentation.label.count > 11,
            usesAccent: accent,
            titleColor: cached("\(key):title") { title },
            background: cached("\(key):bg") { background },
            progressColor: cached("\(key):fill") { fill },
            hoverBackground: cached("\(key):hbg") { base.withAlphaComponent(accent ? 0.84 : 0.12) },
            hoverTitleColor: cached("\(key):htitle") { accent ? title : base })
    }

    private static func phaseName(_ phase: TaskMediaTransferStore.Phase) -> String {
        switch phase {
        case .preparing: "preparing"
        case .ready: "ready"
        case .sending: "sending"
        case .partialFailure: "partialFailure"
        case .sent: "sent"
        case .failed: "failed"
        }
    }

    private func buildTheme(_ appearance: NSAppearance) -> [String: String] {
        let css = MyTasksReactColor.css
        let accent = NSColor.controlAccentColor
        let green = NSColor.systemGreen
        let orange = NSColor.systemOrange
        return [
            "paper": css(NSColor(Editorial.paper)),
            "card": css(NSColor(Editorial.card)),
            "ink": css(NSColor(Editorial.ink)),
            "ink-soft": css(NSColor(Editorial.inkSoft)),
            "ink-mute": css(NSColor(Editorial.inkMute)),
            "ink-faint": css(NSColor(Editorial.inkFaint)),
            "ink-faint-85": css(NSColor(Editorial.inkFaint.opacity(0.85))),
            "rule-50": css(NSColor(Editorial.rule.opacity(0.5))),
            "rule-soft": css(NSColor(Editorial.ruleSoft)),
            "accent": css(accent),
            "accent-075": css(NSColor(Editorial.accent.opacity(0.075))),
            "accent-042": css(NSColor(Editorial.accent.opacity(0.42))),
            "accent-082": css(accent.withAlphaComponent(0.82)),
            "red": css(.systemRed),
            "green": css(green),
            "green-18": css(green.withAlphaComponent(0.18)),
            "green-04": css(green.withAlphaComponent(0.04)),
            "orange": css(orange),
            "orange-16": css(orange.withAlphaComponent(0.16)),
            "success-fill": css(NSColor(srgbRed: 0.84, green: 0.96, blue: 0.88, alpha: 1)),
            "success-ink": css(NSColor(srgbRed: 0.045, green: 0.34, blue: 0.17, alpha: 1)),
            "window-94": css(NSColor.windowBackgroundColor.withAlphaComponent(0.94)),
            "label": css(.labelColor),
        ]
    }

    private func statusColor(_ hex: String) -> (css: String, components: String) {
        let css = cached("status:\(hex)") { NSColor(Color(statusHex: hex)) }
        let components = cached("status-components:\(hex)", raw: true) {
            MyTasksReactColor.components(NSColor(Color(statusHex: hex)))
        }
        return (css, components)
    }

    private func cached(_ key: String, _ make: () -> NSColor) -> String {
        if let hit = colorCache[key] { return hit }
        let value = MyTasksReactColor.css(make())
        colorCache[key] = value
        return value
    }

    private func cached(_ key: String, raw: Bool, _ make: () -> String) -> String {
        if let hit = colorCache[key] { return hit }
        let value = make()
        colorCache[key] = value
        return value
    }

    private static func friendlyFirstName(_ raw: String) -> String {
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

    // MARK: Review watching (native bind/unbind parity)

    private func updateVisible(_ ids: [String]) {
        let next = Set(ids)
        let store = TaskReviewUpdateStore.shared
        for id in watchedTasks.keys where !next.contains(id) {
            store.unwatch(taskId: id)
            watchedTasks[id] = nil
        }
        for id in ids where watchedTasks[id] == nil {
            guard let task = tasksById[id] else { continue }
            store.watch(task: task)
            watchedTasks[id] = task
        }
    }

    /// A rebind with new task content re-registers the watch, as the row did.
    private func updateWatchedContent() {
        let store = TaskReviewUpdateStore.shared
        for (id, watched) in watchedTasks {
            guard let current = tasksById[id] else {
                store.unwatch(taskId: id)
                watchedTasks[id] = nil
                continue
            }
            if current != watched {
                store.watch(task: current)
                watchedTasks[id] = current
            }
        }
    }

    // MARK: Messages

    func receive(type: String, message: [String: Any]) {
        guard let parent else { return }
        let appState = parent.appState
        let task = (message["id"] as? String).flatMap { tasksById[$0] }
        switch type {
        case "rendered":
            if let revealSeq, let seq = message["seq"] as? Int, seq >= revealSeq {
                self.revealSeq = nil
                webView?.alphaValue = 1
            }
        case "activate":
            guard let task, !appState.anyPopupOpen else { return }
            var flags: NSEvent.ModifierFlags = []
            if message["shift"] as? Bool == true { flags.insert(.shift) }
            if message["command"] as? Bool == true { flags.insert(.command) }
            let rect = originRect(message["rect"])
            parent.onActivate(task, flags, rect == .zero
                              ? MouseOriginCapture.currentClickRectInMainWindow() : rect)
        case "toggle":
            if let status = message["status"] as? String { parent.onToggleStatus(status) }
        case "statusPicker":
            guard let task, !appState.anyPopupOpen else { return }
            place(statusAnchor, at: message["rect"])
            statusBubble.show(statuses: appState.availableStatuses,
                              currentStatusName: task.status,
                              anchoredTo: statusAnchor) { status in
                Task { await appState.updateTaskStatus(task, to: status) }
            }
        case "media":
            guard let task, !appState.anyPopupOpen else { return }
            openMedia(task, rect: Self.rect(message["rect"]))
        case "review":
            guard let task, !appState.anyPopupOpen else { return }
            openReview(task, appState: appState)
        case "menu":
            guard let task, !appState.anyPopupOpen,
                  let x = message["x"] as? Double, let y = message["y"] as? Double else { return }
            popUpContextMenu(for: task, at: NSPoint(x: x, y: y))
        case "more":
            guard let task, !appState.anyPopupOpen, let rect = Self.rect(message["rect"]) else { return }
            popUpContextMenu(for: task, at: NSPoint(x: rect.minX, y: rect.maxY + 3))
        case "clearSelection":
            container?.window?.makeFirstResponder(container)
            parent.onClearSelection()
        case "dragBegin":
            if let task { _ = parent.onBeginDrag(task) }
        case "dragEnd":
            parent.onEndDrag(message["completed"] as? Bool == true)
        case "drop":
            acceptDrop(raw: message["raw"] as? String ?? "", statusKey: message["status"] as? String ?? "")
        case "visible":
            updateVisible(message["ids"] as? [String] ?? [])
        default:
            break
        }
    }

    private static func rect(_ value: Any?) -> NSRect? {
        guard let dict = value as? [String: Any],
              let x = dict["x"] as? Double, let y = dict["y"] as? Double,
              let width = dict["width"] as? Double, let height = dict["height"] as? Double
        else { return nil }
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func place(_ anchor: NSView, at value: Any?) {
        guard let rect = Self.rect(value), let webView else { return }
        // WKWebView is flipped: page coordinates map 1:1 onto the view.
        anchor.frame = webView.isFlipped ? rect
            : NSRect(x: rect.minX, y: webView.bounds.height - rect.maxY,
                     width: rect.width, height: rect.height)
    }

    /// MouseOriginCapture.rectInMainWindow(for: row) for a page rect.
    private func originRect(_ value: Any?) -> CGRect {
        guard Self.rect(value) != nil else { return .zero }
        place(originAnchor, at: value)
        return MouseOriginCapture.rectInMainWindow(for: originAnchor)
    }

    private func viewPoint(_ point: NSPoint) -> NSPoint {
        guard let webView, !webView.isFlipped else { return point }
        return NSPoint(x: point.x, y: webView.bounds.height - point.y)
    }

    private func contextActions(for clicked: CUTask) -> [TaskContextAction] {
        guard let appState = parent?.appState else { return [] }
        let selectedIds = parent?.selectedTaskIds ?? []
        guard selectedIds.contains(clicked.id) else {
            return TaskContextMenu.actions(for: clicked, appState: appState)
        }
        let selected = orderedTasks.filter { selectedIds.contains($0.id) }
        return TaskBulkActions.actions(for: selected, appState: appState)
    }

    private func popUpContextMenu(for task: CUTask, at point: NSPoint) {
        guard let webView else { return }
        let actions = contextActions(for: task)
        guard !actions.isEmpty else { return }
        TaskContextMenu.makeNSMenu(actions: actions)
            .popUp(positioning: nil, at: viewPoint(point), in: webView)
    }

    private func popUp(_ actions: [TaskContextAction], below rect: NSRect?) {
        guard let webView, let rect else { return }
        TaskContextMenu.makeNSMenu(actions: actions)
            .popUp(positioning: nil, at: viewPoint(NSPoint(x: rect.minX, y: rect.maxY + 3)), in: webView)
    }

    // MARK: Media (MyTasksNativeRowView.openMedia)

    private func openMedia(_ task: CUTask, rect: NSRect?) {
        guard let parent else { return }
        let appState = parent.appState
        let store = appState.taskMediaTransfers
        let selectedIds = parent.selectedTaskIds
        if store.phase(for: task.id) == nil,
           selectedIds.contains(task.id), selectedIds.count >= 2 {
            parent.onBulkMediaAction()
            return
        }
        switch store.phase(for: task.id) {
        case .ready:
            parent.onMediaAction(task, .send)
        case .partialFailure:
            var actions = [
                TaskContextAction(title: "Tentar novamente",
                                  systemImage: "arrow.clockwise",
                                  action: { [weak self] in self?.parent?.onMediaAction(task, .send) })
            ]
            if store.replaceablePendingCountByTask[task.id, default: 0] > 0 {
                actions.append(TaskContextAction(
                    title: "Substituir vídeos pendentes",
                    systemImage: "arrow.triangle.2.circlepath",
                    action: { [weak self] in self?.parent?.onMediaAction(task, .replacePending) }))
            }
            actions.append(TaskContextAction(
                title: "Descartar lote",
                systemImage: "trash",
                isDestructive: true,
                action: { [weak self] in self?.parent?.appState.taskMediaTransfers.discard(taskId: task.id) }))
            popUp(actions, below: rect)
        case .failed where store.batches[task.id]?.total == 0:
            store.discard(taskId: task.id)
            parent.onMediaAction(task, .add)
        case .preparing, .sending, .failed, .sent:
            parent.onMediaAction(task, .status)
        case nil:
            let taskId = task.id
            Task { @MainActor [weak self] in
                await store.loadCatalog(for: task, appState: appState)
                guard let self, self.tasksById[taskId] != nil,
                      appState.anyPopupOpen != true else { return }
                if store.catalog(for: taskId).hasReplaceablePublishedMedia {
                    self.popUp([
                        TaskContextAction(title: "Adicionar arquivos",
                                          systemImage: "plus.circle",
                                          action: { [weak self] in self?.parent?.onMediaAction(task, .add) }),
                        TaskContextAction(title: "Substituir arquivo",
                                          systemImage: "arrow.triangle.2.circlepath",
                                          action: { [weak self] in self?.parent?.onMediaAction(task, .replace) }),
                    ], below: rect)
                } else {
                    self.parent?.onMediaAction(task, .add)
                }
            }
        }
    }

    // MARK: Review (MyTasksNativeRowView.openReview)

    private func openReview(_ task: CUTask, appState: AppState) {
        let updates = TaskReviewUpdateStore.shared.updates(for: task.id)
        guard !updates.isEmpty else { return }
        if updates.count > 1 {
            TaskReviewQueuePresenter.shared.present(task: task, updates: updates)
            return
        }
        guard let update = updates.first else { return }
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

    // MARK: Status drops (MyTasksAppKitList.Coordinator.acceptDrop)

    private func resolveStatus(_ key: String) -> CUStatus? {
        guard let appState = parent?.appState else { return nil }
        if let status = appState.availableStatuses.first(where: { $0.status.lowercased() == key }) {
            return status
        }
        guard let task = tasksById.values.first(where: { $0.status.lowercased() == key }) else { return nil }
        return CUStatus(status: task.status, color: task.statusColor,
                        type: task.isCompleted ? "closed" : "custom")
    }

    private func acceptDrop(raw: String, statusKey: String) {
        guard let parent else { return }
        let appState = parent.appState
        let ids = MyTasksDragPayload.decode(raw)
        guard let status = resolveStatus(statusKey), !ids.isEmpty else {
            parent.onEndDrag(false)
            return
        }
        let changing = ids.compactMap { appState.tasksById[$0] }.filter {
            $0.status.caseInsensitiveCompare(status.status) != .orderedSame
        }
        Task { @MainActor [weak self] in
            // Batched so every dropped row moves to the new group AT ONCE.
            let toMove = ids
                .compactMap { id in appState.tasks.first(where: { $0.id == id }) }
                .filter { $0.status.caseInsensitiveCompare(status.status) != .orderedSame }
            await appState.updateTaskStatuses(toMove, to: status, silent: true)
            if !changing.isEmpty {
                appState.pushTaskStatusUndo(changing,
                    label: changing.count == 1
                        ? "Mover tarefa para \(status.status.uppercased())"
                        : "Mover \(changing.count) tarefas para \(status.status.uppercased())")
            }
            self?.parent?.onEndDrag(true)
        }
    }

    // MARK: Finder file drops (MyTasksNativeRowView file-drop target)

    private var selectionCount: Int { parent?.selectedTaskIds.count ?? 0 }

    private func canAcceptFileDrop(on taskId: String?) -> CUTask? {
        guard let parent, selectionCount < 2, let taskId, let task = tasksById[taskId],
              !parent.appState.anyPopupOpen else { return nil }
        if let phase = parent.appState.taskMediaTransfers.phase(for: taskId), phase != .sent {
            return nil // Preserve a prepared or partially published batch for retry.
        }
        return task
    }

    func fileDragUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let parent, let webView else { return [] }
        if selectionCount >= 2 {
            if !listFileDragActive {
                listFileDragActive = true
                parent.onListFileDragChanged(true)
            }
            return .copy
        }
        let point = webView.convert(info.draggingLocation, from: nil)
        let pagePoint = webView.isFlipped ? point : NSPoint(x: point.x, y: webView.bounds.height - point.y)
        if pagePoint != fileDragPoint {
            fileDragPoint = pagePoint
            host.evaluate("window.apolloTasks.taskAt(\(pagePoint.x), \(pagePoint.y))") { [weak self] result in
                guard let self, self.fileDragPoint == pagePoint else { return }
                let target = self.canAcceptFileDrop(on: result as? String)?.id
                guard target != self.fileDropTaskId else { return }
                self.fileDropTaskId = target
                self.setFileDropHighlight(target)
            }
        }
        return fileDropTaskId == nil ? [] : .copy
    }

    func fileDragExited() {
        fileDragPoint = nil
        if fileDropTaskId != nil {
            fileDropTaskId = nil
            setFileDropHighlight(nil)
        }
        if listFileDragActive {
            listFileDragActive = false
            parent?.onListFileDragChanged(false)
        }
    }

    func performFileDrop(_ info: NSDraggingInfo) -> Bool {
        defer { fileDragExited() }
        guard let parent else { return false }
        let urls = (info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if selectionCount >= 2 {
            guard !urls.isEmpty else { return false }
            parent.onListFileDrop(urls)
            return true
        }
        guard let task = canAcceptFileDrop(on: fileDropTaskId) else { return false }
        let videos = urls.filter {
            ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains($0.pathExtension.lowercased())
        }
        guard !videos.isEmpty else { return false }
        parent.onFileDrop(task, videos)
        return true
    }

    private func setFileDropHighlight(_ id: String?) {
        let argument = id.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) } ?? "null"
        host.evaluate("window.apolloTasks.setFileDrop(\(argument))")
    }
}

/// Invisible positioning helper for AppKit presenters that need an NSView.
private final class MyTasksReactAnchor: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Colours, glyphs and text metrics

enum MyTasksReactColor {
    /// Display-P3 keeps system colours (accent, red, green…) exact; sRGB
    /// hex colours convert losslessly.
    static func css(_ color: NSColor) -> String {
        guard let p3 = color.usingColorSpace(.displayP3) else { return "transparent" }
        return String(format: "color(display-p3 %.5f %.5f %.5f / %.4f)",
                      p3.redComponent, p3.greenComponent, p3.blueComponent, p3.alphaComponent)
    }

    static func components(_ color: NSColor) -> String {
        guard let p3 = color.usingColorSpace(.displayP3) else { return "0 0 0" }
        return String(format: "%.5f %.5f %.5f", p3.redComponent, p3.greenComponent, p3.blueComponent)
    }
}

@MainActor
enum MyTasksReactResources {
    private static var glyphCache: [CGFloat: [String: MyTasksReactGlyph]] = [:]

    /// Template SF Symbols rendered once per backing scale; the page uses
    /// them as CSS masks tinted with the native colours.
    static func glyphs(scale: CGFloat) -> [String: MyTasksReactGlyph] {
        if let hit = glyphCache[scale] { return hit }
        let render = { (name: String, configuration: NSImage.SymbolConfiguration?) -> MyTasksReactGlyph? in
            guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
            let image = configuration.flatMap { base.withSymbolConfiguration($0) } ?? base
            return glyph(image, scale: max(scale, 2) * 1.5)
        }
        var out: [String: MyTasksReactGlyph] = [:]
        out["chevronRight"] = render("chevron.right", .init(pointSize: 9, weight: .semibold))
        out["chevronDown"] = render("chevron.down", .init(pointSize: 9, weight: .semibold))
        out["ellipsis"] = render("ellipsis", .init(pointSize: 12, weight: .medium))
        out["checkmark"] = render("checkmark", nil)
        out["stack"] = render("rectangle.stack.fill", nil)
        glyphCache[scale] = out
        return out
    }

    private static func glyph(_ image: NSImage, scale: CGFloat) -> MyTasksReactGlyph? {
        let size = image.size
        let pixelsWide = Int(ceil(size.width * scale)), pixelsHigh = Int(ceil(size.height * scale))
        guard pixelsWide > 0, pixelsHigh > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return MyTasksReactGlyph(url: "data:image/png;base64,\(png.base64EncodedString())",
                                 width: size.width, height: size.height)
    }

    /// NSTextField(labelWithString:) cell heights for each row font.
    static var fonts: MyTasksReactFonts {
        if let cachedFonts { return cachedFonts }
        let scale = Editorial.typeScale
        func height(_ font: NSFont) -> CGFloat {
            let field = NSTextField(labelWithString: "Ag")
            field.font = font
            return field.cell?.cellSize.height ?? ceil(font.ascender - font.descender)
        }
        let fonts = MyTasksReactFonts(
            title: height(.systemFont(ofSize: 15 * scale, weight: .medium)),
            priority: height(.systemFont(ofSize: 9.5 * scale, weight: .semibold)),
            assignee: height(.systemFont(ofSize: 11.5 * scale, weight: .regular)),
            date: height(.monospacedDigitSystemFont(ofSize: 11.5 * scale, weight: .medium)),
            headerTitle: height(.systemFont(ofSize: 11.5 * scale, weight: .semibold)),
            headerCount: height(.monospacedDigitSystemFont(ofSize: 11 * scale, weight: .medium)),
            slot: height(.systemFont(ofSize: 10.5, weight: .medium)))
        cachedFonts = fonts
        return fonts
    }
    private static var cachedFonts: MyTasksReactFonts?
}

// MARK: - Avatars (AvatarStore through a private scheme)

@MainActor
final class MyTasksAvatarSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "apollo-avatar"
    private var running: [ObjectIdentifier: Task<Void, Never>] = [:]

    static func url(for photo: URL) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "avatar"
        components.queryItems = [URLQueryItem(name: "u", value: photo.absoluteString)]
        return components.string ?? ""
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let raw = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "u" })?.value,
              let photo = URL(string: raw) else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let key = ObjectIdentifier(urlSchemeTask)
        running[key] = Task { @MainActor [weak self] in
            var image = AvatarStore.shared.image(for: photo)
            if image == nil { image = await AvatarStore.shared.load(photo).value }
            guard let self, self.running.removeValue(forKey: key) != nil else { return }
            guard let image, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                urlSchemeTask.didFailWithError(URLError(.cannotDecodeContentData))
                return
            }
            urlSchemeTask.didReceive(URLResponse(url: requestURL, mimeType: "image/png",
                                                 expectedContentLength: png.count, textEncodingName: nil))
            urlSchemeTask.didReceive(png)
            urlSchemeTask.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        running.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
}
#endif
