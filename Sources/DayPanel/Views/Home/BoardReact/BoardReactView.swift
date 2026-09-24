#if APOLLO_BOARD_REACT
import AppKit
import Combine
import OSLog
import SwiftUI
import WebKit

// Apollo · Quadro rendered by React (web/apollo-board) inside a transparent
// WKWebView, rebuilt for parity with ClickUp's Board view. DEV-only
// (`-DAPOLLO_BOARD_REACT`, script/build_dev_board_react.sh): production keeps
// BoardAppKitViewport and never compiles this file.
//
// Division of labour (same model as MyTasksReactList):
// • Swift owns the task universe, colours (resolved by AppKit under the view's
//   appearance), card metadata hydration, cover images, context menus,
//   preferences and every mutation (AppState, with undo where it exists).
// • React owns grouping, sorting, local search, cards, composers, field
//   pickers, drag & drop and motion. Scrolling is WebKit's threaded scrolling.

/// `--board-renderer=appkit|swiftui` restores a native board in this build (A/B).
enum BoardReactRenderer {
    static var usesReact: Bool { ApolloDevLaunchOptions.boardRenderer == nil }
}

// MARK: - Representable

struct BoardReactView: NSViewRepresentable {
    let appState: AppState
    let selectedTaskIds: Set<String>
    var topInset: CGFloat = 52
    var bottomInset: CGFloat = 24
    /// Floating chrome over the lanes' bottom (bulk toolbar): scroll room
    /// only, the layout does not shrink.
    var overlayInset: CGFloat = 0
    /// Resolved click: open (plain, no selection) or select (⌘/⇧).
    let onActivate: (CUTask, NSEvent.ModifierFlags, CGRect, [CUTask]) -> Void
    let onSetSelection: (Set<String>, String?) -> Void
    let onClearSelection: () -> Void
    /// Native horizontal scroll offset, for the header pills.
    var onHorizontalScroll: (CGFloat) -> Void = { _ in }
    /// False while the page has not painted this mount (loading scene covers it).
    var onReadyChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> BoardReactCoordinator { BoardReactCoordinator() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BoardReactContainer,
                      context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func makeNSView(context: Context) -> BoardReactContainer {
        let container = BoardReactContainer()
        context.coordinator.attach(to: container, parent: self)
        return container
    }

    func updateNSView(_ container: BoardReactContainer, context: Context) {
        context.coordinator.update(parent: self)
    }

    static func dismantleNSView(_ container: BoardReactContainer,
                                coordinator: BoardReactCoordinator) {
        coordinator.detach()
    }
}

/// Hosts the page inside a native horizontal NSScrollView, like the native
/// board's viewport: the columns pan with AppKit scrolling (rubber band,
/// momentum) and the SwiftUI group pills in the header follow the clip view
/// in the same frame. Each column's vertical scroll stays in the page.
final class BoardReactContainer: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var onCancel: (() -> Void)?
    /// Clip view x after every scroll (header pills track it).
    var onHorizontalScroll: ((CGFloat) -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    let scrollView = NSScrollView()
    let document = BoardReactDocumentView()
    /// Width of the page's columns (reported by the page).
    var contentWidth: CGFloat = 0 {
        didSet { if contentWidth != oldValue { needsLayout = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = document
        addSubview(scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(clipDidScroll),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func clipDidScroll() {
        onHorizontalScroll?(scrollView.contentView.bounds.origin.x)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let width = max(contentWidth, bounds.width)
        let size = NSSize(width: width, height: bounds.height)
        if document.frame.size != size { document.frame = NSRect(origin: .zero, size: size) }
        for view in document.subviews { view.frame = document.bounds }
    }

    func scrollToLeading() {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Visible part of the document (clip view bounds) in document coordinates.
    var visibleDocumentRect: NSRect { scrollView.contentView.bounds }
}

final class BoardReactDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// The page takes the keyboard only while one of its text fields is focused
/// (search, composer, picker search); otherwise ⌘Z, Esc and the app's menu
/// shortcuts keep reaching the window, as with the native board.
final class BoardReactWebView: WKWebView {
    var allowsKeyboard = false
    var onAppearanceChange: (() -> Void)?

    override var acceptsFirstResponder: Bool { allowsKeyboard }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    // MARK: Horizontal panning belongs to the native scroll view

    /// Axis of the current trackpad gesture (latched at its first event, kept
    /// through momentum) so a diagonal swipe never scrolls both ways.
    private var horizontalGesture = false

    override func scrollWheel(with event: NSEvent) {
        let starts = event.phase.contains(.began) || event.phase.contains(.mayBegin)
            || (event.phase.isEmpty && event.momentumPhase.isEmpty)
        if starts {
            horizontalGesture = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        }
        if horizontalGesture, let scrollView = enclosingScrollView {
            scrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    // MARK: Drags: files stay out; card drags pan near the edges

    private static func carriesFiles(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true])
    }

    /// Leading edge that counts as "the edge": the floating sidebar covers
    /// the first 220pt of the board.
    var leadingObscured: CGFloat = 220
    private var dragPoint: NSPoint?
    private var panTimer: Timer?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Finder files never reach the page: WebKit would try to open them.
        if Self.carriesFiles(sender) { return [] }
        trackDrag(sender)
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.carriesFiles(sender) { return [] }
        trackDrag(sender)
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        stopPanning()
        super.draggingExited(sender)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        stopPanning()
        super.concludeDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        stopPanning()
        return super.performDragOperation(sender)
    }

    private func trackDrag(_ info: NSDraggingInfo) {
        dragPoint = info.draggingLocation
        guard panTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.panStep() }
        }
        RunLoop.main.add(timer, forMode: .common)
        panTimer = timer
    }

    private func stopPanning() {
        panTimer?.invalidate()
        panTimer = nil
        dragPoint = nil
    }

    private func panStep() {
        guard let dragPoint, let scrollView = enclosingScrollView, let window else { return }
        let clip = scrollView.contentView
        let point = clip.convert(dragPoint, from: nil)
        let visible = clip.bounds
        let band: CGFloat = 56
        let left = visible.minX + leadingObscured
        var dx: CGFloat = 0
        if point.x < left + band, point.x > visible.minX { dx = -ceil((left + band - point.x) / 4) }
        else if point.x > visible.maxX - band { dx = ceil((point.x - (visible.maxX - band)) / 4) }
        guard dx != 0, window.isVisible else { return }
        let maxX = max(0, (scrollView.documentView?.frame.width ?? 0) - visible.width)
        let x = min(max(0, visible.minX + dx), maxX)
        guard x != visible.minX else { return }
        clip.scroll(to: NSPoint(x: x, y: 0))
        scrollView.reflectScrolledClipView(clip)
    }
}

// MARK: - Host (one web process for the app's lifetime)

@MainActor
final class BoardReactHost: NSObject {
    static let shared = BoardReactHost()
    static let log = Logger(subsystem: "com.painellunar.app", category: "BoardReact")

    private(set) var webView: BoardReactWebView?
    private(set) var booted = false
    weak var client: BoardReactCoordinator?
    private let avatars = MyTasksAvatarSchemeHandler()
    private let covers = BoardCoverSchemeHandler()

    func prewarm() { _ = ensureWebView() }

    func ensureWebView() -> BoardReactWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(avatars, forURLScheme: MyTasksAvatarSchemeHandler.scheme)
        configuration.setURLSchemeHandler(covers, forURLScheme: BoardCoverSchemeHandler.scheme)
        configuration.userContentController.add(BoardReactMessageProxy(host: self), name: "apolloBoard")
        let webView = BoardReactWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = self
        self.webView = webView
        load(webView)
        return webView
    }

    private func load(_ webView: WKWebView) {
        booted = false
        #if APOLLO_DEV
        // `APOLLO_BOARD_URL` = Vite dev server, so the page can iterate
        // without rebuilding the app (`npm run dev` in web/apollo-board).
        if let override = ProcessInfo.processInfo.environment["APOLLO_BOARD_URL"],
           let url = URL(string: override) {
            webView.load(URLRequest(url: url))
            return
        }
        #endif
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html",
                                        subdirectory: "ApolloBoard") else {
            Self.log.error("ApolloBoard resource missing")
            return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func send(_ json: String) {
        guard booted, let webView else { return }
        webView.evaluateJavaScript("window.apolloBoard.update(\(json))") { _, error in
            if let error { Self.log.error("update failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func evaluate(_ script: String) {
        guard booted, let webView else { return }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "boot":
            booted = true
            client?.hostDidBoot()
        case "error":
            Self.log.error("script error: \(message["message"] as? String ?? "?", privacy: .public)")
        default:
            client?.receive(type: type, message: message)
        }
    }
}

extension BoardReactHost: WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Self.log.error("web content process terminated — reloading")
        load(webView)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        var allowed = url?.isFileURL == true
        #if APOLLO_DEV
        if let override = ProcessInfo.processInfo.environment["APOLLO_BOARD_URL"],
           let url, url.absoluteString.hasPrefix(override) {
            allowed = true
        }
        #endif
        decisionHandler(allowed ? .allow : .cancel)
    }
}

private final class BoardReactMessageProxy: NSObject, WKScriptMessageHandler {
    weak var host: BoardReactHost?
    init(host: BoardReactHost) { self.host = host }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { host?.receive(message.body) }
    }
}

// MARK: - Payload (web/apollo-board/src/lib/types.ts)

struct BoardReactCard: Encodable, Equatable {
    struct Checklist: Encodable, Equatable { let done: Int; let total: Int }

    let id: String
    var title: String
    var status: String
    var closed: Bool
    var priority: Int
    var assignees: [Int]
    var tags: [String]
    var due: Double?
    var start: Double?
    var created: Double?
    var updated: Double?
    var hasDescription: Bool
    var attachments: Int?
    var checklist: Checklist?
    var cover: String?
    var parentId: String?
    var parentTitle: String?
    var otherList: String?
    /// "WORKSPACE · LIST", the native card's breadcrumb.
    var crumb: String?
}

struct BoardReactStatus: Encodable, Equatable {
    let key: String
    let name: String
    let color: String
    let sc: String
    let closed: Bool
}

struct BoardReactPerson: Encodable, Equatable {
    let id: Int
    let name: String
    let initials: String
    let background: String
    let photo: String?
}

struct BoardReactTag: Encodable, Equatable {
    let name: String
    let fg: String
    let bg: String
}

struct BoardReactInsets: Encodable, Equatable {
    let top: CGFloat
    let leading: CGFloat
    let bottom: CGFloat
    let overlay: CGFloat
}

struct BoardReactPatch: Encodable {
    let seq: Int
    var reset: Bool?
    var upsert: [BoardReactCard]?
    var remove: [String]?
    var order: [String]?
    var statuses: [BoardReactStatus]?
    var members: [BoardReactPerson]?
    var tags: [BoardReactTag]?
    var orders: [String: [String]]?
    var prefs: BoardReactPreferences.Prefs?
    var selected: [String]?
    var me: Int?
    var listName: String?
    var popupOpen: Bool?
    var windowKey: Bool?
    var theme: [String: String]?
    var dark: Bool?
    var insets: BoardReactInsets?
    var resetScroll: Bool?
    var subtaskComposer: String?
    /// Toolbar search text.
    var query: String?
    /// One-shot command from a native control ("collapseAll", "compose:<gk>"…).
    var command: String?
}

// MARK: - Coordinator

@MainActor
final class BoardReactCoordinator: NSObject {
    private var parent: BoardReactView?
    private weak var container: BoardReactContainer?
    private let host = BoardReactHost.shared
    private var webView: BoardReactWebView? { host.webView }
    private let metadata = BoardCardMetadataStore.shared
    private let preferences = BoardReactPreferences.shared

    // Last state the page received.
    private var sentCards: [String: BoardReactCard] = [:]
    private var sentOrder: [String] = []
    private var sentStatuses: [BoardReactStatus]?
    private var sentMembers: [BoardReactPerson]?
    private var sentTags: [BoardReactTag]?
    private var sentOrders: [String: [String]]?
    private var sentPrefs: BoardReactPreferences.Prefs?
    private var sentSelected: [String]?
    private var sentPopup: Bool?
    private var sentWindowKey: Bool?
    private var sentTheme: [String: String]?
    private var sentInsets: BoardReactInsets?
    private var sentListId: String?
    private var sentQuery: String?
    private var pendingCommands: [String] = []
    private var popover: NSPopover?
    private var needsFull = true
    private var seq = 0
    private let gate = WebRevealGate()
    private var pendingSubtaskComposer: String?

    private var scope: [String: CUTask] = [:]
    private var colorCache: [String: String] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var refreshScheduled = false
    private let menuAnchor = BoardReactAnchor()

    private var listId: String { parent?.appState.activeListId ?? "" }

    // MARK: Lifecycle

    func attach(to container: BoardReactContainer, parent: BoardReactView) {
        self.parent = parent
        self.container = container
        container.onCancel = { [weak self] in self?.parent?.onClearSelection() }
        let webView = host.ensureWebView()
        if let previous = host.client, previous !== self { previous.releaseWebView() }
        host.client = self
        webView.removeFromSuperview()
        webView.autoresizingMask = []
        webView.onAppearanceChange = { [weak self] in self?.appearanceChanged() }
        // Hidden until the page has painted THIS board; the loading scene
        // covers the wait, with resend and a guaranteed reveal.
        gate.onReadyChange = { [weak self] ready in self?.parent?.onReadyChange(ready) }
        gate.resend = { [weak self] in
            self?.needsFull = true
            self?.refresh()
        }
        gate.begin(hiding: webView)
        gate.armed(seq: .max)
        container.document.addSubview(webView)
        container.onHorizontalScroll = { [weak self] x in self?.parent?.onHorizontalScroll(x) }
        container.needsLayout = true
        if menuAnchor.superview !== webView { webView.addSubview(menuAnchor) }
        if ApolloDevLaunchOptions.isFixtureMode {
            metadata.seedFixtures(parent.appState.tasks)
        }
        needsFull = true
        subscribe()
        update(parent: parent)
    }

    func detach() {
        gate.end()
        cancellables.removeAll()
        popover?.close()
        releaseWebView()
        if host.client === self { host.client = nil }
        parent = nil
    }

    fileprivate func releaseWebView() {
        guard let webView, webView.superview === container?.document else { return }
        webView.onAppearanceChange = nil
        webView.allowsKeyboard = false
        webView.removeFromSuperview()
    }

    func update(parent: BoardReactView) {
        self.parent = parent
        refresh()
    }

    func hostDidBoot() {
        needsFull = true
        refresh()
    }

    private func subscribe() {
        cancellables.removeAll()
        guard let appState = parent?.appState else { return }
        let schedule: () -> Void = { [weak self] in self?.scheduleRefresh() }
        metadata.$entries.sink { _ in schedule() }.store(in: &cancellables)
        preferences.$current.sink { _ in schedule() }.store(in: &cancellables)
        preferences.$query.sink { _ in schedule() }.store(in: &cancellables)
        preferences.commands.sink { [weak self] command in
            self?.pendingCommands.append(command)
            self?.scheduleRefresh()
        }.store(in: &cancellables)
        appState.$anyPopupOpen.sink { _ in schedule() }.store(in: &cancellables)
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
        // Status/member/tag colours are resolved per appearance too.
        needsFull = true
        scheduleRefresh()
    }

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

    private func scopeTasks(_ appState: AppState, prefs: BoardReactPreferences.Prefs) -> [CUTask] {
        let listId = appState.activeListId
        // Board scope, not the shared `TaskSurfaceScope.openTasks`: closed
        // tasks are a board option and tasks added to this list from another
        // home list (Tasks in Multiple Lists) belong to it too.
        let scoped = appState.tasks.filter { task in
            guard !task.archived, prefs.showClosed || !task.isCompleted else { return false }
            return listId.isEmpty || task.listId == listId
                || task.locations.contains { $0.id == listId }
        }
        return appState.taskFilters.applying(to: scoped)
    }

    private func refresh() {
        guard let parent, let webView, host.booted else { return }
        let appState = parent.appState
        let appearance = webView.effectiveAppearance
        if sentListId != appState.activeListId {
            sentListId = appState.activeListId
            needsFull = true
        }
        if preferences.listId != appState.activeListId {
            // Publishing from inside a view update is not allowed; the
            // `$current` subscription refreshes again once it lands.
            let listId = appState.activeListId
            DispatchQueue.main.async { [preferences] in preferences.activate(listId: listId) }
        }
        let prefs = preferences.current
        var patch = BoardReactPatch(seq: seq + 1)
        var changed = false

        var cards: [BoardReactCard] = []
        var statuses: [BoardReactStatus] = []
        var members: [BoardReactPerson] = []
        var tags: [BoardReactTag] = []
        appearance.performAsCurrentDrawingAppearance {
            let tasks = scopeTasks(appState, prefs: prefs)
            scope = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            cards = tasks.map { card($0, appState: appState) }
            statuses = buildStatuses(appState)
            members = buildMembers(appState, tasks: tasks)
            tags = buildTags(appState, tasks: tasks)
            let theme = buildTheme()
            if theme != sentTheme || needsFull {
                patch.theme = theme
                patch.dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                sentTheme = theme
                changed = true
            }
        }

        // Cards: diff by id; order = Swift scope order (manual fallback).
        let order = cards.map(\.id)
        var seen = Set<String>()
        let unique = cards.filter { seen.insert($0.id).inserted }
        let next = Dictionary(unique.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if needsFull {
            patch.reset = true
            patch.upsert = unique
            patch.order = order
            changed = true
        } else {
            let upserts = unique.filter { sentCards[$0.id] != $0 }
            let removed = sentCards.keys.filter { next[$0] == nil }
            if !upserts.isEmpty { patch.upsert = upserts }
            if !removed.isEmpty { patch.remove = removed }
            if order != sentOrder { patch.order = order }
            if patch.upsert != nil || patch.remove != nil || patch.order != nil { changed = true }
        }
        sentCards = next
        sentOrder = order

        if statuses != sentStatuses || needsFull {
            patch.statuses = statuses
            sentStatuses = statuses
            changed = true
        }
        if members != sentMembers || needsFull {
            patch.members = members
            patch.me = appState.clickUpAuthService.userId
            sentMembers = members
            changed = true
        }
        if tags != sentTags || needsFull {
            patch.tags = tags
            sentTags = tags
            changed = true
        }
        let orders = preferences.orders(for: listId, statusKeys: statuses.map(\.key))
        if orders != sentOrders || needsFull {
            patch.orders = orders
            sentOrders = orders
            changed = true
        }
        if prefs != sentPrefs || needsFull {
            patch.prefs = prefs
            sentPrefs = prefs
            changed = true
        }
        let selected = parent.selectedTaskIds.sorted()
        if selected != sentSelected || needsFull {
            patch.selected = selected
            sentSelected = selected
            changed = true
        }
        let popupOpen = appState.anyPopupOpen
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
        // Columns start 10pt past the native board's `leadingMargin` (the
        // header's leading group moved by the same 10pt); the page adds the
        // 10pt card inset inside each column.
        let insets = BoardReactInsets(top: parent.topInset,
                                      leading: BoardViewportView.leadingMargin + 10,
                                      bottom: parent.bottomInset,
                                      overlay: parent.overlayInset)
        if insets != sentInsets || needsFull {
            patch.insets = insets
            sentInsets = insets
            changed = true
        }
        if needsFull {
            patch.listName = appState.activeListName
            patch.resetScroll = true
            container?.scrollToLeading()
        }
        let query = preferences.query
        if query != sentQuery || needsFull {
            patch.query = query
            sentQuery = query
            changed = true
        }
        if !pendingCommands.isEmpty {
            // One per patch keeps each command's token distinct in the page.
            patch.command = pendingCommands.removeFirst()
            changed = true
            if !pendingCommands.isEmpty { scheduleRefresh() }
        }
        if let pendingSubtaskComposer {
            patch.subtaskComposer = pendingSubtaskComposer
            self.pendingSubtaskComposer = nil
            changed = true
        }
        needsFull = false
        guard changed else { return }
        seq = patch.seq
        guard let data = try? Self.encoder.encode(patch),
              let json = String(data: data, encoding: .utf8) else { return }
        host.send(json)
        if patch.reset == true { gate.armed(seq: patch.seq) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    private static func ms(_ date: Date?) -> Double? {
        date.map { ($0.timeIntervalSince1970 * 1000).rounded() }
    }

    private func card(_ task: CUTask, appState: AppState) -> BoardReactCard {
        let entry = metadata.entries[task.id]
        let parentTask = task.parentId.flatMap { appState.tasksById[$0] }
        let description = task.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var card = BoardReactCard(
            id: task.id,
            title: task.title,
            status: task.status.lowercased(),
            closed: task.isCompleted,
            priority: (1...4).contains(task.priority) ? task.priority : 0,
            assignees: task.assignees.map(\.id),
            tags: task.tags.map(\.name),
            due: Self.ms(task.dueDate),
            start: Self.ms(task.startDate),
            created: Self.ms(task.dateCreated),
            updated: Self.ms(task.dateUpdated),
            hasDescription: !description.isEmpty,
            attachments: entry?.attachments,
            checklist: entry.flatMap { $0.checklistTotal > 0
                ? .init(done: $0.checklistDone, total: $0.checklistTotal) : nil },
            cover: entry?.cover.map(BoardCoverSchemeHandler.url(for:)),
            parentId: task.parentId,
            parentTitle: parentTask?.title)
        if !listId.isEmpty, task.listId != listId, !task.listName.isEmpty {
            card.otherList = task.listName
        }
        card.crumb = BoardCardFormatting.breadcrumb(
            workspace: appState.clickUpAuthService.workspaceName ?? "", listName: task.listName)
        return card
    }

    private func buildStatuses(_ appState: AppState) -> [BoardReactStatus] {
        let statuses = appState.availableStatuses.isEmpty
            ? BoardOrdering.fallbackStatuses : appState.availableStatuses
        return statuses.map { status in
            // Apollo's status palette with the dark-mode vibrancy, exactly
            // as the native board, Tarefas and the status menus paint it.
            let hex = status.displayHex
            let color = cachedColor("status:\(hex)") { NSColor(Color(statusHex: hex)) }
            let components = cachedRaw("status-components:\(hex)") {
                MyTasksReactColor.components(NSColor(Color(statusHex: hex)))
            }
            return BoardReactStatus(key: status.status.lowercased(),
                                    name: status.status.uppercased(),
                                    color: color, sc: components,
                                    closed: status.isClosed)
        }
    }

    private func buildMembers(_ appState: AppState, tasks: [CUTask]) -> [BoardReactPerson] {
        var out: [Int: BoardReactPerson] = [:]
        func person(id: Int, name: String, initials: String, colorHex: String?, photo: String?) -> BoardReactPerson {
            let hex = colorHex ?? "#7A6597"
            return BoardReactPerson(
                id: id, name: name, initials: initials,
                background: cachedColor("hex:\(hex)") { NSColor(Color(hex: hex)) },
                photo: photo.flatMap { $0.isEmpty ? nil : URL(string: $0) }
                    .map(MyTasksAvatarSchemeHandler.url(for:)))
        }
        for member in appState.availableMembers {
            let assignee = CUTask.Assignee(id: member.id, username: member.username,
                                           initials: member.initials, color: member.color,
                                           profilePicture: member.profilePicture)
            out[member.id] = person(id: member.id, name: member.username,
                                    initials: assignee.avatarInitials,
                                    colorHex: member.color, photo: member.profilePicture)
        }
        for task in tasks {
            for assignee in task.assignees where out[assignee.id] == nil {
                out[assignee.id] = person(id: assignee.id, name: assignee.username,
                                          initials: assignee.avatarInitials,
                                          colorHex: assignee.color, photo: assignee.profilePicture)
            }
        }
        return out.values.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private func buildTags(_ appState: AppState, tasks: [CUTask]) -> [BoardReactTag] {
        var out: [String: CUTask.Tag] = [:]
        for tag in appState.availableTags { out[tag.name] = tag }
        for task in tasks { for tag in task.tags where out[tag.name] == nil { out[tag.name] = tag } }
        return out.values
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            .map { tag in
                BoardReactTag(name: tag.name,
                              fg: cachedColor("hex:\(tag.foreground)") { NSColor(Color(hex: tag.foreground)) },
                              bg: cachedColor("hex:\(tag.background)") { NSColor(Color(hex: tag.background)) })
            }
    }

    /// macOS semantic colours, resolved under the view's appearance, so
    /// text, separators, fills and the accent follow the system exactly.
    /// The canvas and card keep Apollo's paper/page like the other screens.
    private func buildTheme() -> [String: String] {
        let css = MyTasksReactColor.css
        let priority = { (hex: String) in css(NSColor(Color(hex: hex))) }
        return [
            "paper": css(NSColor(Editorial.paper)),
            "page": css(NSColor(Editorial.page)),
            "ink": css(NSColor(Editorial.ink)),
            "ink-soft": css(NSColor(Editorial.inkSoft)),
            "ink-mute": css(NSColor(Editorial.inkMute)),
            "ink-faint": css(NSColor(Editorial.inkFaint)),
            "rule": css(NSColor(Editorial.rule)),
            "rule-soft": css(NSColor(Editorial.ruleSoft)),
            "accent": css(NSColor(Editorial.accent)),
            "on-accent": css(.alternateSelectedControlTextColor),
            "overdue": css(NSColor(Editorial.overdue)),
            // CUTask.priorityHex: the muted editorial flags.
            "prio-1": priority("#A8392A"),
            "prio-2": priority("#9A7B1F"),
            "prio-3": priority("#56708A"),
            "prio-4": priority("#7C7E84"),
        ]
    }

    private func cachedColor(_ key: String, _ make: () -> NSColor) -> String {
        if let hit = colorCache[key] { return hit }
        let value = MyTasksReactColor.css(make())
        colorCache[key] = value
        return value
    }

    private func cachedRaw(_ key: String, _ make: () -> String) -> String {
        if let hit = colorCache[key] { return hit }
        let value = make()
        colorCache[key] = value
        return value
    }

    // MARK: Messages

    func receive(type: String, message: [String: Any]) {
        guard let parent else { return }
        let appState = parent.appState
        let task = (message["id"] as? String).flatMap { scope[$0] ?? appState.tasksById[$0] }
        switch type {
        case "rendered":
            if let seq = message["seq"] as? Int { gate.acknowledge(seq: seq) }
        case "activate":
            guard let task, !appState.anyPopupOpen else { return }
            var flags: NSEvent.ModifierFlags = []
            if message["shift"] as? Bool == true { flags.insert(.shift) }
            if message["command"] as? Bool == true { flags.insert(.command) }
            parent.onActivate(task, flags, originRect(message["rect"]), orderedTasks(message["ordered"]))
        case "select":
            let ids = (message["ids"] as? [String] ?? []).filter { scope[$0] != nil }
            let additive = message["additive"] as? Bool == true
            parent.onSetSelection((additive ? parent.selectedTaskIds : []).union(ids), ids.last)
        case "clearSelection":
            container?.window?.makeFirstResponder(container)
            parent.onClearSelection()
        case "menu":
            guard let task, !appState.anyPopupOpen,
                  let x = message["x"] as? Double, let y = message["y"] as? Double else { return }
            popUpContextMenu(for: task, at: NSPoint(x: x, y: y))
        case "field":
            guard let task, !appState.anyPopupOpen, let rect = Self.rect(message["rect"]),
                  let field = message["field"] as? String else { return }
            openField(field, for: task, below: rect, appState: appState)
        case "columnMenu":
            guard !appState.anyPopupOpen, let rect = Self.rect(message["rect"]) else { return }
            popUpColumnMenu(message, below: rect)
        case "layout":
            applyLayout(message)
        case "summary":
            if let total = message["total"] as? Int, preferences.total != total {
                preferences.total = total
            }
        case "create":
            create(message, appState: appState)
        case "createSubtask":
            guard let task = (message["parent"] as? String).flatMap({ scope[$0] ?? appState.tasksById[$0] }),
                  let title = message["title"] as? String,
                  let token = message["token"] as? String else { return }
            Task { @MainActor [weak self] in
                let created: CUTask? = await appState.createSubtask(parent: task, title: title)
                self?.resolveCreate(token, ok: created != nil)
            }
        case "drop":
            acceptDrop(message, appState: appState)
        case "prefs":
            guard let raw = message["prefs"],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let prefs = try? JSONDecoder().decode(BoardReactPreferences.Prefs.self, from: data)
            else { return }
            sentPrefs = prefs
            preferences.update { $0 = prefs }
        case "visible":
            let ids = message["ids"] as? [String] ?? []
            guard !ApolloDevLaunchOptions.isFixtureMode else { return }
            let tasks = ids.compactMap { scope[$0] }
            let service = appState.clickUpService
            metadata.request(tasks) { id in try? await service.getTask(id: id) }
        case "editing":
            setEditing(message["active"] as? Bool == true)
        default:
            break
        }
    }

    /// Page geometry: document width for the native scroll view, and the
    /// group headers for the native pill track.
    private func applyLayout(_ message: [String: Any]) {
        if let width = message["width"] as? Double { container?.contentWidth = CGFloat(width) }
        let headers = (message["headers"] as? [[String: Any]] ?? []).compactMap { raw -> BoardReactHeader? in
            guard let gk = raw["gk"] as? String, let x = raw["x"] as? Double,
                  let width = raw["w"] as? Double else { return nil }
            return BoardReactHeader(gk: gk, key: raw["key"] as? String ?? "",
                                    kind: raw["kind"] as? String ?? "status",
                                    title: raw["title"] as? String ?? "",
                                    count: raw["count"] as? Int ?? 0,
                                    x: CGFloat(x), width: CGFloat(width),
                                    collapsed: raw["collapsed"] as? Bool == true,
                                    canCreate: raw["canCreate"] as? Bool == true,
                                    ids: raw["ids"] as? [String] ?? [])
        }
        if preferences.headers != headers { preferences.headers = headers }
    }

    /// Header "…" (native pill track): same menu as before, at the click.
    func popUpColumnMenu(for header: BoardReactHeader) {
        guard let webView, let window = webView.window else { return }
        let local = webView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let rect = NSRect(x: local.x - 8, y: local.y, width: 16, height: 1)
        let pageRect = webView.isFlipped ? rect
            : NSRect(x: rect.minX, y: webView.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        popUpColumnMenu(["gk": header.gk, "title": header.title, "canCreate": header.canCreate,
                         "ids": header.ids], below: pageRect)
    }

    private func setEditing(_ active: Bool) {
        guard let webView else { return }
        webView.allowsKeyboard = active
        if active {
            webView.window?.makeFirstResponder(webView)
        } else if webView.window?.firstResponder === webView {
            webView.window?.makeFirstResponder(container)
        }
    }

    private func orderedTasks(_ value: Any?) -> [CUTask] {
        (value as? [String] ?? []).compactMap { scope[$0] }
    }

    private static func rect(_ value: Any?) -> NSRect? {
        guard let dict = value as? [String: Any],
              let x = dict["x"] as? Double, let y = dict["y"] as? Double,
              let width = dict["width"] as? Double, let height = dict["height"] as? Double
        else { return nil }
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// MouseOriginCapture.rectInMainWindow(for:) for a page rect, so the
    /// detail popup morphs out of the card.
    private func originRect(_ value: Any?) -> CGRect {
        guard let rect = Self.rect(value), let webView else {
            return MouseOriginCapture.currentClickRectInMainWindow()
        }
        menuAnchor.frame = webView.isFlipped ? rect
            : NSRect(x: rect.minX, y: webView.bounds.height - rect.maxY,
                     width: rect.width, height: rect.height)
        return MouseOriginCapture.rectInMainWindow(for: menuAnchor)
    }

    /// Page coordinates → web view coordinates.
    private func viewPoint(_ point: NSPoint) -> NSPoint {
        guard let webView, !webView.isFlipped else { return point }
        return NSPoint(x: point.x, y: webView.bounds.height - point.y)
    }

    // MARK: Context menu

    private func popUpContextMenu(for task: CUTask, at point: NSPoint) {
        guard let parent, let webView else { return }
        let appState = parent.appState
        let selected = parent.selectedTaskIds
        var actions: [TaskContextAction]
        if selected.contains(task.id), selected.count > 1 {
            actions = TaskBulkActions.actions(for: selected.compactMap { scope[$0] }, appState: appState)
        } else {
            actions = TaskContextMenu.actions(for: task, appState: appState)
            // Board-only: create a subtask from the card (Q38).
            let index = actions.firstIndex { $0.isSeparator } ?? actions.count
            actions.insert(TaskContextAction(
                title: "Nova subtarefa",
                systemImage: "arrow.turn.down.right",
                action: { [weak self] in
                    self?.pendingSubtaskComposer = task.id
                    self?.scheduleRefresh()
                }), at: index)
        }
        guard !actions.isEmpty else { return }
        TaskContextMenu.makeNSMenu(actions: actions).popUp(positioning: nil, at: viewPoint(point), in: webView)
    }

    // MARK: Create in context (Q17/Q18)

    private func resolveCreate(_ token: String, ok: Bool) {
        let argument = (try? String(data: JSONEncoder().encode(token), encoding: .utf8)) ?? "\"\""
        host.evaluate("window.apolloBoard.created(\(argument), \(ok))")
    }

    private func create(_ message: [String: Any], appState: AppState) {
        guard let title = message["title"] as? String, let token = message["token"] as? String,
              let groupBy = message["groupBy"] as? String, let group = message["group"] as? String
        else { return }
        var status: String?
        var priority = 0
        var due: Date?
        var assignees: [Int] = []
        var tags: [String] = []
        switch groupBy {
        case "status":
            status = resolveStatus(group, appState: appState)?.status
        case "priority":
            priority = Int(group) ?? 0
        case "assignee":
            if let id = Int(group) { assignees = [id] }
        case "tag":
            if group != "none" { tags = [group] }
        case "due":
            due = Self.bucketDate(group)
        default:
            break
        }
        let listId = listId
        let position = message["position"] as? String ?? "bottom"
        Task { @MainActor [weak self] in
            let created = await appState.createTask(title: title, status: status, priority: priority,
                                                    dueDate: due, assigneeIds: assignees, tagNames: tags)
            guard let self else { return }
            if let created {
                // Land where the composer was: top or end of the group.
                let key = "\(groupBy):\(group)"
                var ids = self.preferences.orders(for: listId, statusKeys: [])[key] ?? []
                ids.removeAll { $0 == created.id }
                if position == "top" { ids.insert(created.id, at: 0) } else { ids.append(created.id) }
                self.preferences.setOrder(ids, group: key, listId: listId)
                self.scheduleRefresh()
            }
            self.resolveCreate(token, ok: created != nil)
        }
    }

    private static func bucketDate(_ key: String) -> Date? {
        let calendar = Calendar.current
        let days: Int
        switch key {
        case "today": days = 0
        case "tomorrow": days = 1
        default: return nil
        }
        guard let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: Date()))
        else { return nil }
        return calendar.date(bySettingHour: 23, minute: 59, second: 0, of: day)
    }

    // MARK: Drops (status or the grouped field, plus manual order)

    private func resolveStatus(_ key: String, appState: AppState) -> CUStatus? {
        appState.availableStatuses.first { $0.status.lowercased() == key }
            ?? BoardOrdering.fallbackStatuses.first { $0.status.lowercased() == key }
    }

    private func acceptDrop(_ message: [String: Any], appState: AppState) {
        guard let ids = message["ids"] as? [String], !ids.isEmpty,
              let groupBy = message["groupBy"] as? String, let to = message["to"] as? String
        else { return }
        let from = message["from"] as? String
        let listId = listId
        if let order = message["order"] as? [String] {
            preferences.setOrder(order, group: "\(groupBy):\(to)", listId: listId)
        }
        if let from, let sourceOrder = message["sourceOrder"] as? [String] {
            preferences.setOrder(sourceOrder, group: "\(groupBy):\(from)", listId: listId)
        }
        NotificationCenter.default.post(name: .apolloTaskDropCompleted, object: nil)
        scheduleRefresh()
        guard from != to else { return }
        let tasks = ids.compactMap { appState.tasksById[$0] }
        let label = tasks.count == 1 ? "Mover tarefa" : "Mover \(tasks.count) tarefas"
        switch groupBy {
        case "status":
            guard let status = resolveStatus(to, appState: appState) else { return }
            let changing = tasks.filter { $0.status.caseInsensitiveCompare(status.status) != .orderedSame }
            guard !changing.isEmpty else { return }
            Task {
                await appState.updateTaskStatuses(changing, to: status, silent: true)
                appState.pushTaskStatusUndo(changing, label: "\(label) para \(status.status.uppercased())")
            }
        case "priority":
            let value = Int(to) ?? 0
            Task {
                for task in tasks { await appState.updateTaskPriority(task, to: value) }
                appState.pushTaskSnapshotUndo(tasks, label: label)
            }
        case "assignee":
            // Replace only the assignee of the source column; others stay.
            Task {
                for task in tasks {
                    var next = Set(task.assignees.map(\.id))
                    if let from, let old = Int(from) { next.remove(old) }
                    if let new = Int(to) { next.insert(new) }
                    await appState.updateTaskAssignees(task, to: next)
                }
                appState.pushTaskSnapshotUndo(tasks, label: label)
            }
        case "tag":
            Task {
                for task in tasks {
                    var next = Set(task.tags.map(\.name))
                    if let from, from != "none" { next.remove(from) }
                    if to != "none" { next.insert(to) }
                    await appState.updateTaskTags(task, to: next)
                }
                appState.pushTaskSnapshotUndo(tasks, label: label)
            }
        case "due":
            guard to == "none" || Self.bucketDate(to) != nil else { return }
            let date = Self.bucketDate(to)
            Task {
                for task in tasks { await appState.updateTaskDueDate(task, to: date) }
                appState.pushTaskSnapshotUndo(tasks, label: label)
            }
        default:
            break
        }
    }
}

// MARK: - Native field editors and column menu

extension BoardReactCoordinator {
    /// Page rect → web view rect (WKWebView is flipped on macOS).
    private func viewRect(_ rect: NSRect) -> NSRect {
        guard let webView, !webView.isFlipped else { return rect }
        return NSRect(x: rect.minX, y: webView.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func popUp(_ menu: NSMenu, below rect: NSRect) {
        guard let webView else { return }
        let r = viewRect(rect)
        let point = webView.isFlipped ? NSPoint(x: r.minX, y: r.maxY + 4) : NSPoint(x: r.minX, y: r.minY - 4)
        menu.popUp(positioning: nil, at: point, in: webView)
    }

    /// Priority, tags and assignees are native menus (tags and people toggle
    /// one entry per pick, like Finder's tag menu); the due date is a native
    /// popover with the graphical calendar.
    fileprivate func openField(_ field: String, for task: CUTask, below rect: NSRect, appState: AppState) {
        switch field {
        case "priority":
            popUp(priorityMenu(task, appState: appState), below: rect)
        case "tags":
            popUp(tagMenu(task, appState: appState), below: rect)
        case "assignee":
            popUp(assigneeMenu(task, appState: appState), below: rect)
        case "due":
            showDuePopover(task, below: rect, appState: appState)
        default:
            break
        }
    }

    private func priorityMenu(_ task: CUTask, appState: AppState) -> NSMenu {
        let menu = NSMenu(title: "Prioridade")
        menu.autoenablesItems = false
        for (value, title) in BoardReactNative.priorities {
            let item = BoardMenuItem(title: title) {
                Task { await appState.updateTaskPriority(task, to: value) }
            }
            item.image = BoardReactNative.flag(value)
            item.state = task.priority == value ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = BoardMenuItem(title: "Limpar prioridade") {
            Task { await appState.updateTaskPriority(task, to: 0) }
        }
        clear.isEnabled = (1...4).contains(task.priority)
        menu.addItem(clear)
        return menu
    }

    private func tagMenu(_ task: CUTask, appState: AppState) -> NSMenu {
        let menu = NSMenu(title: "Etiquetas")
        menu.autoenablesItems = false
        var tags: [String: CUTask.Tag] = [:]
        for tag in appState.availableTags { tags[tag.name] = tag }
        for tag in task.tags where tags[tag.name] == nil { tags[tag.name] = tag }
        let current = Set(task.tags.map(\.name))
        let sorted = tags.values.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        for tag in sorted {
            let item = BoardMenuItem(title: tag.name) {
                var next = current
                if next.contains(tag.name) { next.remove(tag.name) } else { next.insert(tag.name) }
                Task { await appState.updateTaskTags(task, to: next) }
            }
            item.image = BoardReactNative.dot(NSColor(Color(hex: tag.background)))
            item.state = current.contains(tag.name) ? .on : .off
            menu.addItem(item)
        }
        if sorted.isEmpty {
            let empty = NSMenuItem(title: "Nenhuma etiqueta nesta lista", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        if !current.isEmpty {
            menu.addItem(.separator())
            menu.addItem(BoardMenuItem(title: "Remover todas") {
                Task { await appState.updateTaskTags(task, to: []) }
            })
        }
        return menu
    }

    private func assigneeMenu(_ task: CUTask, appState: AppState) -> NSMenu {
        let menu = NSMenu(title: "Responsáveis")
        menu.autoenablesItems = false
        let me = appState.clickUpAuthService.userId
        let current = Set(task.assignees.map(\.id))
        var people: [Int: CUTask.Assignee] = [:]
        for member in appState.availableMembers {
            people[member.id] = CUTask.Assignee(id: member.id, username: member.username,
                                               initials: member.initials, color: member.color,
                                               profilePicture: member.profilePicture)
        }
        for assignee in task.assignees where people[assignee.id] == nil { people[assignee.id] = assignee }
        let sorted = people.values.sorted {
            if $0.id == me { return true }
            if $1.id == me { return false }
            return $0.username.localizedCompare($1.username) == .orderedAscending
        }
        for person in sorted {
            let item = BoardMenuItem(title: person.id == me ? "\(person.username) (eu)" : person.username) {
                var next = current
                if next.contains(person.id) { next.remove(person.id) } else { next.insert(person.id) }
                Task { await appState.updateTaskAssignees(task, to: next) }
            }
            item.image = BoardReactNative.avatar(person)
            item.state = current.contains(person.id) ? .on : .off
            menu.addItem(item)
        }
        if !current.isEmpty {
            menu.addItem(.separator())
            menu.addItem(BoardMenuItem(title: "Remover todos") {
                Task { await appState.updateTaskAssignees(task, to: []) }
            })
        }
        return menu
    }

    private func showDuePopover(_ task: CUTask, below rect: NSRect, appState: AppState) {
        guard let webView else { return }
        popover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: BoardDuePicker(
            initial: task.dueDate,
            onPick: { [weak self, weak popover] date in
                popover?.close()
                self?.popover = nil
                Task { await appState.updateTaskDueDate(task, to: date) }
            }))
        self.popover = popover
        popover.show(relativeTo: viewRect(rect), of: webView, preferredEdge: .maxY)
    }

    /// The group "…" menu (Q19): create, select all, collapse.
    fileprivate func popUpColumnMenu(_ message: [String: Any], below rect: NSRect) {
        guard let gk = message["gk"] as? String else { return }
        let ids = message["ids"] as? [String] ?? []
        let menu = NSMenu(title: message["title"] as? String ?? "")
        menu.autoenablesItems = false
        if message["canCreate"] as? Bool == true {
            let add = BoardMenuItem(title: "Adicionar tarefa") { [weak self] in
                self?.preferences.commands.send("compose:\(gk)")
            }
            add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
            menu.addItem(add)
        }
        let select = BoardMenuItem(title: "Selecionar todas (\(ids.count))") { [weak self] in
            guard let self, let parent = self.parent else { return }
            let valid = ids.filter { self.scope[$0] != nil }
            parent.onSetSelection(parent.selectedTaskIds.union(valid), valid.last)
        }
        select.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        select.isEnabled = !ids.isEmpty
        menu.addItem(select)
        menu.addItem(.separator())
        let collapse = BoardMenuItem(title: "Recolher grupo") { [weak self] in
            self?.preferences.update { prefs in
                if !prefs.collapsed.contains(gk) { prefs.collapsed.append(gk) }
            }
        }
        collapse.image = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: nil)
        menu.addItem(collapse)
        let empty = BoardMenuItem(title: "Recolher grupos vazios") { [weak self] in
            self?.preferences.update { $0.collapseEmpty.toggle() }
        }
        empty.state = preferences.current.collapseEmpty ? .on : .off
        menu.addItem(empty)
        popUp(menu, below: rect)
    }
}

/// Closure-backed menu item (TaskContextMenu keeps its own private one).
private final class BoardMenuItem: NSMenuItem {
    private let closure: () -> Void
    init(title: String, closure: @escaping () -> Void) {
        self.closure = closure
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func invoke() { closure() }
}

@MainActor
enum BoardReactNative {
    /// ClickUp's priority flags (Urgente red, Alta yellow, Normal blue, Baixa grey).
    static let priorities: [(Int, String)] = [(1, "Urgente"), (2, "Alta"), (3, "Normal"), (4, "Baixa")]
    static let priorityColors: [Int: NSColor] = [
        1: NSColor(srgbRed: 0.94, green: 0.27, blue: 0.23, alpha: 1),
        2: NSColor(srgbRed: 0.96, green: 0.71, blue: 0, alpha: 1),
        3: NSColor(srgbRed: 0.27, green: 0.66, blue: 0.90, alpha: 1),
        4: NSColor(srgbRed: 0.65, green: 0.67, blue: 0.70, alpha: 1),
    ]

    static func flag(_ priority: Int) -> NSImage? {
        guard let color = priorityColors[priority] else { return nil }
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        return NSImage(systemSymbolName: "flag.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
    }

    /// Photo from AvatarStore when already cached, else the initials disc.
    static func avatar(_ person: CUTask.Assignee) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let photo = person.photoURL.flatMap { AvatarStore.shared.image(for: $0) }
        if let url = person.photoURL, photo == nil { _ = AvatarStore.shared.load(url) }
        let background = NSColor(Color(hex: person.color ?? "#7A6597"))
        return NSImage(size: size, flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect)
            if let photo {
                NSGraphicsContext.saveGraphicsState()
                circle.addClip()
                photo.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                background.setFill()
                circle.fill()
                let text = person.avatarInitials as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 7.5, weight: .semibold),
                    .foregroundColor: NSColor.white,
                ]
                let bounds = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2),
                          withAttributes: attributes)
            }
            return true
        }
    }
}

/// Native due-date editor: ClickUp's quick choices beside the macOS
/// graphical calendar, in a system popover.
private struct BoardDuePicker: View {
    let initial: Date?
    let onPick: (Date?) -> Void
    @State private var date: Date

    init(initial: Date?, onPick: @escaping (Date?) -> Void) {
        self.initial = initial
        self.onPick = onPick
        _date = State(initialValue: initial ?? Date())
    }

    private static func endOfDay(_ day: Date) -> Date {
        let calendar = Calendar.current
        return calendar.date(bySettingHour: 23, minute: 59, second: 0, of: calendar.startOfDay(for: day)) ?? day
    }

    private var quick: [(String, Date)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let add = { (days: Int) in calendar.date(byAdding: .day, value: days, to: today) ?? today }
        return [
            ("Hoje", today),
            ("Amanhã", add(1)),
            ("Este fim de semana", add((7 - weekday + 7) % 7 == 0 ? 7 : (7 - weekday + 7) % 7)),
            ("Próxima semana", add((9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7)),
            ("Em 2 semanas", add(14)),
        ]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(quick, id: \.0) { item in
                    Button {
                        onPick(Self.endOfDay(item.1))
                    } label: {
                        HStack {
                            Text(item.0)
                            Spacer(minLength: 12)
                            Text(item.1, format: .dateTime.day().month(.abbreviated))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.accessoryBar)
                }
                Spacer(minLength: 8)
                if initial != nil {
                    Button("Remover data", role: .destructive) { onPick(nil) }
                        .buttonStyle(.accessoryBar)
                }
            }
            .frame(width: 190)
            .padding(10)
            Divider()
            DatePicker("Vencimento", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(10)
                .onChange(of: date) { _, value in onPick(Self.endOfDay(value)) }
        }
        .fixedSize()
    }
}

/// Invisible positioning helper for AppKit presenters that need an NSView.
private final class BoardReactAnchor: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Covers (ClickUp thumbnails through a private scheme)

/// `apollo-cover://cover?u=<thumbnail>`: downloads ClickUp's attachment
/// preview off the main thread with a bounded on-disk cache, so the page
/// never touches the network and a reused card can't show another task's
/// image (the URL is the key). `fixture:<n>` renders an offline cover.
@MainActor
final class BoardCoverSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "apollo-cover"
    private var running: [ObjectIdentifier: Task<Void, Never>] = [:]

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ApolloBoard/Covers", isDirectory: true)
        configuration.urlCache = URLCache(memoryCapacity: 24 << 20, diskCapacity: 256 << 20,
                                          directory: directory)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    static func url(for source: String) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "cover"
        components.queryItems = [URLQueryItem(name: "u", value: source)]
        return components.string ?? ""
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let source = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "u" })?.value else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let key = ObjectIdentifier(urlSchemeTask)
        running[key] = Task { @MainActor [weak self] in
            let result: (Data, String)?
            if source.hasPrefix("fixture:") {
                result = Self.fixture(Int(source.dropFirst(8)) ?? 0).map { ($0, "image/png") }
            } else if let url = URL(string: source), url.scheme == "https" {
                let response = try? await Self.session.data(from: url)
                let mime = response?.1.mimeType ?? "image/jpeg"
                result = response.flatMap { (200..<300).contains(($0.1 as? HTTPURLResponse)?.statusCode ?? 0)
                    ? ($0.0, mime) : nil }
            } else {
                result = nil
            }
            guard let self, self.running.removeValue(forKey: key) != nil else { return }
            guard let (data, mime) = result else {
                urlSchemeTask.didFailWithError(URLError(.cannotLoadFromNetwork))
                return
            }
            urlSchemeTask.didReceive(URLResponse(url: requestURL, mimeType: mime,
                                                 expectedContentLength: data.count, textEncodingName: nil))
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        running.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    /// Deterministic offline cover for `--board-fixtures`.
    private static func fixture(_ index: Int) -> Data? {
        let size = NSSize(width: 480, height: 270)
        let hues: [(CGFloat, CGFloat)] = [(0.02, 0.06), (0.60, 0.66), (0.08, 0.12), (0.78, 0.88), (0.45, 0.52), (0.95, 0.99)]
        let (a, b) = hues[index % hues.count]
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(hue: a, saturation: 0.7, brightness: 0.25, alpha: 1),
                                NSColor(hue: b, saturation: 0.8, brightness: 0.62, alpha: 1)])?
                .draw(in: rect, angle: -35)
            NSColor.black.withAlphaComponent(0.22).setFill()
            NSBezierPath(ovalIn: NSRect(x: 290, y: 90, width: 140, height: 140)).fill()
            let text = ["BLACK FRIDAY", "MINIMAL CLUB", "É FEITA", "NOVA COLEÇÃO", "UGC", "TAKE 2"][index % 6]
            (text as NSString).draw(at: NSPoint(x: 34, y: 28), withAttributes: [
                .font: NSFont.systemFont(ofSize: 34, weight: .heavy),
                .foregroundColor: NSColor.white,
            ])
            return true
        }
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }
}
#endif
