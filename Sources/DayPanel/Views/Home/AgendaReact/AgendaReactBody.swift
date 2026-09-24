#if APOLLO_AGENDA_REACT
import AppKit
import Combine
import OSLog
import SwiftUI
import WebKit

// Apollo · Agenda body rendered by React (web/apollo-agenda) inside one
// transparent WKWebView: the forward-only event timeline, the column rule,
// the month grid and the selected day's panel. DEV-only
// (`-DAPOLLO_AGENDA_REACT`, script/build_dev_agenda_react.sh): production
// keeps TimelineView + AgendaMonthSurface and never compiles this file.
//
// Division of labour — same inputs and outputs as the native views:
// • Swift owns data (mergedEventsByDay, the month fetch), every date/label
//   computation, colours (resolved by AppKit under the view's appearance),
//   text metrics and every action (detail, NSMenu, conversion, deletion,
//   scroll commands from selectedDate / todayJumpToken).
// • React owns layout, painting, hover/press motion and day selection.
//   Scrolling is WebKit's threaded scrolling: nothing runs on the app's main
//   thread while either column moves.
// The floating shared-calendar search and the month spinner stay native.

/// `--agenda-renderer=native` restores the native views in this build (A/B).
enum AgendaRenderer {
    static let usesReact = !ProcessInfo.processInfo.arguments.contains("--agenda-renderer=native")
}

// MARK: - SwiftUI body

struct AgendaReactBody: View {
    @EnvironmentObject var appState: AppState
    @Binding var month: Date
    let agendaTopInset: CGFloat
    let inboxTopInset: CGFloat
    @StateObject private var loader = AgendaReactMonthLoader()
    @ObservedObject private var journal = SyncJournal.shared
    /// The page painted this mount (WebRevealGate).
    @State private var pageReady = false

    /// TimelineView.headerToFirstCardSpacing.
    private static let headerToFirstCardSpacing: CGFloat = 43

    var body: some View {
        GeometryReader { geo in
            let timelineW = AgendaLayout.timelineWidth(max(1, geo.size.width))
            let eventsTop = Self.headerToFirstCardSpacing + agendaTopInset
            AgendaReactView(month: month,
                            appState: appState,
                            loader: loader,
                            agendaTop: eventsTop,
                            monthTop: inboxTopInset,
                            occlusion: EditorialHomeHeader.chromeHeight,
                            onReadyChange: { pageReady = $0 })
                // TimelineView's floating "add coworker's calendar" search,
                // anchored to the events column's bottom-trailing corner.
                // It is page content: below the loading scene and hidden
                // with the page while the scene (or its grace) is up.
                .overlay(alignment: .bottomLeading) {
                    SharedCalendarSearchBar()
                        .environmentObject(appState)
                        .frame(width: max(220, timelineW * 0.85), alignment: .trailing)
                        .padding(.trailing, 14)
                        .padding(.bottom, 16)
                        .frame(width: timelineW, alignment: .trailing)
                }
                .opacity(showsLoading ? 0 : 1)
                .allowsHitTesting(!showsLoading)
                // Whenever the agenda has nothing real to show — the page is
                // not painted yet, or the events are still on their way —
                // the agenda loading scene covers it (after the shared 0.5 s
                // tolerance of SyncLoadingSurface).
                .overlay {
                    if showsLoading {
                        SyncLoadingSurface(scene: .agenda,
                                           agenda: .init(eventsTop: Double(eventsTop),
                                                         monthTop: Double(inboxTopInset)),
                                           monthLoading: loader.loading) {
                            AgendaLoadingPlaceholder(eventsTop: eventsTop,
                                                     monthTop: inboxTopInset,
                                                     timelineWidth: timelineW)
                        }
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.24), value: showsLoading)
                // AgendaMonthView's loading indicator.
                .overlay(alignment: .bottomTrailing) {
                    if loader.loading && !showsLoading {
                        ProgressView().controlSize(.small).padding(.trailing, 24).padding(.bottom, 24)
                    }
                }
        }
    }
}

extension AgendaReactBody {
    /// Events still coming: Google is connected and online, nothing has
    /// landed yet, and this session's calendar read has not finished.
    private var eventsLoading: Bool {
        guard appState.googleAuth.isConnected, appState.isOnline, appState.events.isEmpty else { return false }
        if case .active = journal.states[.calendar] { return true }
        return !journal.hasCompletedSync
    }

    fileprivate var showsLoading: Bool { !pageReady || eventsLoading }
}

/// Native lunar skeleton of the agenda (fallback of the web scene, same
/// geometry): the sync console and day-grouped event capsules in the
/// events column, the month grid and the day panel on the right.
private struct AgendaLoadingPlaceholder: View {
    let eventsTop: CGFloat
    let monthTop: CGFloat
    let timelineWidth: CGFloat

    /// No text block in the scenes (shapes only): capsules start at the top.
    static let consoleReserve: CGFloat = 0
    static let card: CGFloat = 47
    static let cardGap: CGFloat = 6
    static let groupGap: CGFloat = 18

    @State private var size: CGSize = .zero

    var body: some View {
        LunarSkeletonSurface {
            ZStack(alignment: .topLeading) {
                Color.clear
                timeline
                month
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .accessibilityElement()
        .accessibilityLabel("Carregando agenda")
    }

    private var timeline: some View {
        let top = eventsTop + Self.consoleReserve
        let groups = Self.groups(height: size.height - 24, top: top)
        return VStack(alignment: .leading, spacing: Self.groupGap) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, count in
                // Running row of this day's first capsule: the same cascade
                // as the web scene (capsule i lands i × 40 ms in).
                let first = groups.prefix(index).reduce(0, +)
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(LunarSkeleton.secondary)
                            .frame(width: 26, height: 7)
                        RoundedRectangle(cornerRadius: 5).fill(LunarSkeleton.primary)
                            .frame(width: 30, height: 22)
                    }
                    .frame(width: 55, alignment: .leading)
                    .cascadeAppear(index: first, step: 0.032, cap: 1)
                    VStack(spacing: Self.cardGap) {
                        ForEach(0..<count, id: \.self) { k in
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(LunarSkeleton.faint)
                                .frame(height: Self.card)
                                .cascadeAppear(index: first + k, step: 0.04, cap: 1)
                        }
                    }
                }
            }
        }
        .padding(.leading, 36)
        .frame(width: max(0, timelineWidth - 26), alignment: .leading)
        .padding(.top, top)
    }

    private var month: some View {
        let left = timelineWidth + 17
        let width = max(0, size.width - left - 12)
        let cell = max(0, (width - 6 * 6.5) / 7)
        return VStack(alignment: .leading, spacing: 6.5) {
            HStack(spacing: 6.5) {
                ForEach(0..<7, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 3).fill(LunarSkeleton.secondary)
                        .frame(width: 22, height: 7)
                        .frame(width: cell)
                }
            }
            .padding(.bottom, 6)
            ForEach(0..<5, id: \.self) { r in
                HStack(spacing: 6.5) {
                    ForEach(0..<7, id: \.self) { c in
                        // Diagonal wave from the first Monday, as the scene.
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LunarSkeleton.faint)
                            .frame(width: cell, height: 51)
                            .cascadeAppear(index: r + c, step: 0.035, cap: 1)
                    }
                }
            }
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LunarSkeleton.faint)
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .cascadeAppear(index: 1, step: 0.3, cap: 1)
                .padding(.top, 14)
                .padding(.bottom, 24)
        }
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, monthTop + 8)
        .padding(.leading, left)
    }

    /// Day groups of 3, 4, then 3s — whole capsules only (web: agendaGroups).
    static func groups(height: CGFloat, top: CGFloat) -> [Int] {
        var groups: [Int] = []
        var y = top
        while true {
            let wanted = groups.isEmpty ? 3 : (groups.count == 1 ? 4 : 3)
            if !groups.isEmpty { y += groupGap }
            let fit = Int((height - y + cardGap) / (card + cardGap))
            guard fit > 0 else { break }
            let rows = min(wanted, fit)
            groups.append(rows)
            y += CGFloat(rows) * (card + cardGap) - cardGap
            if rows < wanted { break }
        }
        return groups
    }
}

// MARK: - Month fetch (AgendaMonthView.loadMonth)

@MainActor
final class AgendaReactMonthLoader: ObservableObject {
    @Published private(set) var fetchedEvents: [CalendarEvent]?
    @Published private(set) var loading = false
    @Published private(set) var error: String?

    private struct Request: Equatable {
        let month: Date
        let revision: Int
        let connected: Bool
        let shared: [SharedCalendar]
    }
    private var request: Request?
    private var task: Task<Void, Never>?
    private var revision = 0

    /// `.task(id: request)`: restarts only when the request changes.
    func load(month: Date, appState: AppState) {
        let next = Request(month: month, revision: revision,
                           connected: appState.googleAuth.isConnected, shared: appState.sharedCalendars)
        guard next != request else { return }
        request = next
        task?.cancel()
        let model = AgendaMonth(containing: month)
        task = Task { [weak self, weak appState] in
            guard let self, let appState else { return }
            await self.run(model, appState: appState)
        }
    }

    /// `revision += 1` (sync finished, events changed, "Tentar novamente").
    func bump(month: Date, appState: AppState) {
        revision += 1
        load(month: month, appState: appState)
    }

    func cancel() {
        task?.cancel()
        task = nil
        request = nil
    }

    private func run(_ model: AgendaMonth, appState: AppState) async {
        fetchedEvents = nil
        error = nil
        loading = false
        guard !ApolloDevLaunchOptions.isFixtureMode, !ApolloRuntimeEnvironment.isStudio,
              !appState.showMockData, appState.googleAuth.isConnected else { return }
        loading = true
        do {
            var loaded = try await appState.googleCalendar.listEventsOnCalendar(
                calendarId: "primary", from: model.interval.start, to: model.interval.end)
            var sharedFailed = false
            for calendar in appState.sharedCalendars {
                try Task.checkCancellation()
                do {
                    let result = try await appState.googleCalendar.listSharedCalendar(
                        email: calendar.email, from: model.interval.start, to: model.interval.end,
                        contactColorHex: calendar.colorHex)
                    loaded += result.events
                } catch is CancellationError { throw CancellationError() }
                catch { sharedFailed = true }
            }
            try Task.checkCancellation()
            fetchedEvents = loaded
            error = sharedFailed ? "Algumas agendas compartilhadas não foram carregadas." : nil
            loading = false
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "Não foi possível atualizar os eventos deste mês."
            loading = false
        }
    }
}

// MARK: - Representable

struct AgendaReactView: NSViewRepresentable {
    let month: Date
    let appState: AppState
    let loader: AgendaReactMonthLoader
    let agendaTop: CGFloat
    let monthTop: CGFloat
    let occlusion: CGFloat
    /// False while the page has not painted this mount (loading scene covers it).
    var onReadyChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> AgendaReactCoordinator { AgendaReactCoordinator() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AgendaReactContainer,
                      context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func makeNSView(context: Context) -> AgendaReactContainer {
        let container = AgendaReactContainer()
        context.coordinator.attach(to: container, parent: self)
        return container
    }

    func updateNSView(_ container: AgendaReactContainer, context: Context) {
        context.coordinator.update(parent: self)
    }

    static func dismantleNSView(_ container: AgendaReactContainer, coordinator: AgendaReactCoordinator) {
        coordinator.detach()
    }
}

final class AgendaReactContainer: NSView {
    override var isFlipped: Bool { true }
}

final class AgendaReactWebView: WKWebView, HeaderOccludingViewport {
    var headerOcclusionHeight: CGFloat = 0
    var onAppearanceChange: (() -> Void)?

    /// Keyboard stays with the window/SwiftUI (⌘←/⌘→, Esc); the page has no
    /// text input. Mouse handling does not need first responder.
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

    // Nothing may be dropped into the agenda page.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
}

// MARK: - Host (one web process for the app's lifetime)

@MainActor
final class AgendaReactHost: NSObject {
    static let shared = AgendaReactHost()
    static let log = Logger(subsystem: "com.painellunar.app", category: "AgendaReact")

    private(set) var webView: AgendaReactWebView?
    private(set) var booted = false
    weak var client: AgendaReactCoordinator?
    private let avatars = AgendaAvatarSchemeHandler()

    func ensureWebView() -> AgendaReactWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(avatars, forURLScheme: AgendaAvatarSchemeHandler.scheme)
        configuration.userContentController.add(AgendaReactMessageProxy(host: self), name: "apolloAgenda")
        let webView = AgendaReactWebView(frame: .zero, configuration: configuration)
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

    /// The page header is SwiftUI material; WebKit's automatic top scroll
    /// pocket (macOS 26) would draw a second edge effect under it.
    private static func hideTopScrollPocket(_ webView: WKWebView) {
        let selector = NSSelectorFromString("_addReasonToHideTopScrollPocket:")
        guard webView.responds(to: selector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, UInt) -> Void
        let implementation = webView.method(for: selector)
        unsafeBitCast(implementation, to: Function.self)(webView, selector, 1 << 0)
    }

    private func load(_ webView: WKWebView) {
        booted = false
        #if APOLLO_DEV
        if let override = ProcessInfo.processInfo.environment["APOLLO_AGENDA_URL"],
           let url = URL(string: override) {
            webView.load(URLRequest(url: url))
            return
        }
        #endif
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html",
                                        subdirectory: "ApolloAgenda") else {
            Self.log.error("ApolloAgenda resource missing")
            return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func send(_ json: String) {
        guard booted, let webView else { return }
        webView.evaluateJavaScript("window.apolloAgenda.update(\(json))") { _, error in
            if let error { Self.log.error("update failed: \(error.localizedDescription, privacy: .public)") }
        }
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

extension AgendaReactHost: WKNavigationDelegate {
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
        if let override = ProcessInfo.processInfo.environment["APOLLO_AGENDA_URL"],
           let url, url.absoluteString.hasPrefix(override) {
            allowed = true
        }
        #endif
        decisionHandler(allowed ? .allow : .cancel)
    }
}

/// WKUserContentController retains its handlers; the proxy keeps that edge weak.
private final class AgendaReactMessageProxy: NSObject, WKScriptMessageHandler {
    weak var host: AgendaReactHost?
    init(host: AgendaReactHost) { self.host = host }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { host?.receive(message.body) }
    }
}

// MARK: - Payload (web/apollo-agenda/src/lib/types.ts)

struct AgendaReactEvent: Encodable, Equatable {
    let key: String
    let title: String
    let subtitle: String
    let detail: String
    let time: String
    let accepted: Bool
    let declined: Bool
    let cardc: String
    let dot: String
    let darkInk: Bool
    let monogram: String
    let initials: String?
    // Day panel (redesigned list under the month grid).
    let start: String
    let end: String
    let allDay: Bool
    let location: String?
    let join: AgendaReactJoin?
    let people: [AgendaReactPerson]
    /// "past" / "now" relative to the current minute; nil otherwise.
    let phase: String?
}

struct AgendaReactJoin: Encodable, Equatable {
    let label: String
}

struct AgendaReactPerson: Encodable, Equatable {
    let name: String
    let initials: String
    let color: String
    let photo: String?
    let organizer: Bool
}

struct AgendaReactDay: Encodable, Equatable {
    let key: String
    let label: String
    let day: String
    let today: Bool
    let past: Bool
    let events: [AgendaReactEvent]
}

struct AgendaReactCell: Encodable, Equatable {
    let key: String
    let number: String
    let monthLabel: String?
    let inMonth: Bool
    let today: Bool
    let title: String
    let relative: String
    let tooltip: String
    let a11y: String
    let events: [AgendaReactEvent]
}

struct AgendaReactMonth: Encodable, Equatable {
    let key: String
    let title: String
    let cells: [AgendaReactCell]
    let fallback: String
}

struct AgendaReactLayout: Encodable, Equatable {
    let agendaTop: CGFloat
    let monthTop: CGFloat
    let occlusion: CGFloat
}

struct AgendaReactScroll: Encodable, Equatable {
    let token: Int
    let day: String?
    let animated: Bool
}

struct AgendaReactGlyph: Encodable, Equatable {
    let url: String
    let width: CGFloat
    let height: CGFloat
}

struct AgendaReactPatch: Encodable {
    let seq: Int
    var theme: [String: String]?
    var dark: Bool?
    var metrics: [String: CGFloat]?
    var glyphs: [String: AgendaReactGlyph]?
    var layout: AgendaReactLayout?
    var timeline: [AgendaReactDay]?
    var month: AgendaReactMonth?
    var error: String??
    var reduceMotion: Bool?
    var todayToken: Int?
    var scroll: AgendaReactScroll?

    private enum CodingKeys: String, CodingKey {
        case seq, theme, dark, metrics, glyphs, layout, timeline, month, error, reduceMotion, todayToken, scroll
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encodeIfPresent(theme, forKey: .theme)
        try container.encodeIfPresent(dark, forKey: .dark)
        try container.encodeIfPresent(metrics, forKey: .metrics)
        try container.encodeIfPresent(glyphs, forKey: .glyphs)
        try container.encodeIfPresent(layout, forKey: .layout)
        try container.encodeIfPresent(timeline, forKey: .timeline)
        try container.encodeIfPresent(month, forKey: .month)
        // `error: null` clears the banner; an absent key leaves it alone.
        if let error { try container.encode(error, forKey: .error) }
        try container.encodeIfPresent(reduceMotion, forKey: .reduceMotion)
        try container.encodeIfPresent(todayToken, forKey: .todayToken)
        try container.encodeIfPresent(scroll, forKey: .scroll)
    }
}

// MARK: - Coordinator

@MainActor
final class AgendaReactCoordinator: NSObject {
    private var parent: AgendaReactView?
    private weak var container: AgendaReactContainer?
    private let host = AgendaReactHost.shared
    private var webView: AgendaReactWebView? { host.webView }
    private var cancellables: Set<AnyCancellable> = []
    private var refreshScheduled = false
    private let monthCache = AgendaMonthProjectionCache()

    // Last state sent to the page.
    private var needsFull = true
    private var seq = 0
    private let gate = WebRevealGate()
    private var sentTheme: [String: String]?
    private var sentScale: CGFloat?
    private var sentLayout: AgendaReactLayout?
    private var sentTimeline: [AgendaReactDay]?
    private var sentMonth: AgendaReactMonth?
    private var sentError: String??
    private var sentReduceMotion: Bool?
    private var pendingTodayToken: Int?
    private var pendingScroll: AgendaReactScroll?
    private var scrollToken = 0
    private var todayToken = 0

    // TimelineView state.
    private var suppressAutoScroll = false
    private var shownMonth: String?
    private var lastSelectedDate: Date?
    private var colorCache: [String: String] = [:]

    // Events behind the keys the page sends back.
    private var timelineEvents: [String: CalendarEvent] = [:]
    private var monthEvents: [String: CalendarEvent] = [:]

    // MARK: Lifecycle

    func attach(to container: AgendaReactContainer, parent: AgendaReactView) {
        self.parent = parent
        self.container = container
        let webView = host.ensureWebView()
        if let previous = host.client, previous !== self { previous.releaseWebView() }
        host.client = self
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        webView.onAppearanceChange = { [weak self] in self?.appearanceChanged() }
        // Hidden until the page has painted THIS mount: the shared page may
        // still hold the previous mount's scroll offset. Resent / revealed
        // by the gate if the confirmation never arrives.
        gate.resend = { [weak self] in
            self?.needsFull = true
            self?.refresh()
        }
        gate.onReadyChange = { [weak self] ready in self?.parent?.onReadyChange(ready) }
        gate.begin(hiding: webView)
        gate.armed(seq: .max)
        container.addSubview(webView)
        needsFull = true
        subscribe(parent.appState, loader: parent.loader)
        // TimelineView.onAppear: the Home agenda always opens on today.
        let appState = parent.appState
        lastSelectedDate = appState.selectedDate
        if !Calendar.current.isDateInToday(appState.selectedDate) {
            suppressAutoScroll = true
            appState.selectedDate = Calendar.current.startOfDay(for: Date())
        }
        update(parent: parent)
    }

    func detach() {
        gate.end()
        cancellables.removeAll()
        parent?.loader.cancel()
        releaseWebView()
        if host.client === self { host.client = nil }
        parent = nil
    }

    fileprivate func releaseWebView() {
        guard let webView, webView.superview === container else { return }
        webView.onAppearanceChange = nil
        webView.removeFromSuperview()
    }

    func update(parent: AgendaReactView) {
        self.parent = parent
        let monthKey = Self.dayKey(AgendaMonth(containing: parent.month).start)
        if let shownMonth, shownMonth != monthKey {
            // A different month's days replace the list: start at its top.
            queueScroll(day: nil, animated: false)
        }
        shownMonth = monthKey
        parent.loader.load(month: parent.month, appState: parent.appState)
        refresh()
    }

    func hostDidBoot() {
        needsFull = true
        refresh()
    }

    private func subscribe(_ appState: AppState, loader: AgendaReactMonthLoader) {
        cancellables.removeAll()
        let schedule: () -> Void = { [weak self] in self?.scheduleRefresh() }
        appState.$mergedEventsByDay.dropFirst().sink { _ in schedule() }.store(in: &cancellables)
        loader.objectWillChange.sink { _ in schedule() }.store(in: &cancellables)

        // AgendaMonthView: revision += 1 when a sync ends or events change.
        let bump: () -> Void = { [weak self] in
            guard let self, let parent = self.parent else { return }
            DispatchQueue.main.async { parent.loader.bump(month: parent.month, appState: parent.appState) }
        }
        appState.$activeSyncCount
            .map { $0 > 0 }
            .removeDuplicates()
            .scan((false, false)) { ($0.1, $1) }
            .dropFirst()
            .sink { old, new in if old && !new { bump() } }
            .store(in: &cancellables)
        appState.$events.removeDuplicates().dropFirst().sink { _ in bump() }.store(in: &cancellables)
        appState.$sharedEvents.removeDuplicates().dropFirst().sink { _ in bump() }.store(in: &cancellables)
        // The month request also depends on the connection and shared list.
        appState.googleAuth.$isConnected.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { if let parent = self?.parent { self?.update(parent: parent) } }
        }.store(in: &cancellables)
        appState.$sharedCalendars.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { if let parent = self?.parent { self?.update(parent: parent) } }
        }.store(in: &cancellables)

        // TimelineView.onChange(of: selectedDate) — willSet delivers the new value.
        appState.$selectedDate.dropFirst().sink { [weak self] date in self?.selectedDateChanged(date) }
            .store(in: &cancellables)
        appState.$todayJumpToken.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.jumpToToday() }
        }.store(in: &cancellables)

        // "Agora" / past rows follow the clock.
        Timer.publish(every: 60, on: .main, in: .common).autoconnect()
            .sink { _ in schedule() }.store(in: &cancellables)
        // Guest photos come from ClickUp members.
        appState.$availableMembers.dropFirst().sink { _ in schedule() }.store(in: &cancellables)
        let center = NotificationCenter.default
        center.publisher(for: .NSCalendarDayChanged).sink { _ in schedule() }.store(in: &cancellables)
        center.publisher(for: NSColor.systemColorsDidChangeNotification)
            .sink { [weak self] _ in self?.appearanceChanged() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .sink { _ in schedule() }
            .store(in: &cancellables)
    }

    private func selectedDateChanged(_ date: Date) {
        let old = lastSelectedDate
        lastSelectedDate = date
        if let old, Calendar.current.isDate(old, inSameDayAs: date) { return }
        if suppressAutoScroll { suppressAutoScroll = false; return }
        // forwardOnly: agendaScroll.scroll(to: day, animated: true)
        queueScroll(day: Self.dayKey(Calendar.current.startOfDay(for: date)), animated: true)
    }

    /// TimelineView + AgendaMonthView .onChange(of: todayJumpToken).
    private func jumpToToday() {
        guard let appState = parent?.appState else { return }
        let today = Calendar.current.startOfDay(for: Date())
        if !Calendar.current.isDate(appState.selectedDate, inSameDayAs: today) {
            suppressAutoScroll = true
            appState.selectedDate = today
        }
        queueScroll(day: nil, animated: false)
        todayToken += 1
        pendingTodayToken = todayToken
        scheduleRefresh()
    }

    private func queueScroll(day: String?, animated: Bool) {
        scrollToken += 1
        pendingScroll = AgendaReactScroll(token: scrollToken, day: day, animated: animated)
        scheduleRefresh()
    }

    private func appearanceChanged() {
        colorCache.removeAll()
        sentTheme = nil
        sentTimeline = nil
        sentMonth = nil
        scheduleRefresh()
    }

    /// Publishers fire in willSet; read their new values next turn.
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
        let appState = parent.appState
        let appearance = webView.effectiveAppearance
        var patch = AgendaReactPatch(seq: seq + 1)
        var changed = false

        appearance.performAsCurrentDrawingAppearance {
            let theme = buildTheme()
            if theme != sentTheme || needsFull {
                patch.theme = theme
                patch.dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                sentTheme = theme
                changed = true
            }
            let projection = monthCache.resolve(month: parent.month, primary: appState.events,
                                                shared: appState.sharedEvents,
                                                fetched: parent.loader.fetchedEvents)
            let timeline = buildTimeline(appState, projection: projection)
            if timeline != sentTimeline || needsFull {
                patch.timeline = timeline
                sentTimeline = timeline
                changed = true
            }
            let month = buildMonth(parent, projection: projection)
            if month != sentMonth || needsFull {
                patch.month = month
                sentMonth = month
                changed = true
            }
        }
        let error = parent.loader.error
        if sentError == nil || sentError! != error || needsFull {
            patch.error = .some(error)
            sentError = .some(error)
            changed = true
        }
        let layout = AgendaReactLayout(agendaTop: parent.agendaTop, monthTop: parent.monthTop,
                                       occlusion: parent.occlusion)
        if layout != sentLayout || needsFull {
            patch.layout = layout
            sentLayout = layout
            changed = true
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion != sentReduceMotion || needsFull {
            patch.reduceMotion = reduceMotion
            sentReduceMotion = reduceMotion
            changed = true
        }
        let scale = webView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if scale != sentScale || needsFull {
            patch.glyphs = AgendaReactResources.glyphs(scale: scale)
            patch.metrics = AgendaReactResources.metrics
            sentScale = scale
            changed = true
        }
        if let token = pendingTodayToken {
            patch.todayToken = token
            pendingTodayToken = nil
            changed = true
        }
        if let scroll = pendingScroll {
            patch.scroll = scroll
            pendingScroll = nil
            changed = true
        }
        let revealing = needsFull
        needsFull = false
        webView.headerOcclusionHeight = parent.occlusion
        guard changed else { return }
        seq = patch.seq
        guard let data = try? Self.encoder.encode(patch),
              let json = String(data: data, encoding: .utf8) else { return }
        host.send(json)
        if revealing { gate.armed(seq: patch.seq) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    private func buildTheme() -> [String: String] {
        let css = AgendaReactColor.css
        let components = AgendaReactColor.components
        let rule = NSColor(Editorial.rule).usingColorSpace(.displayP3)
        return [
            "paper": css(NSColor(Editorial.paper)),
            "paper-c": components(NSColor(Editorial.paper)),
            "page": css(NSColor(Editorial.page)),
            "ink": css(NSColor(Editorial.ink)),
            "ink-c": components(NSColor(Editorial.ink)),
            "ink-soft": css(NSColor(Editorial.inkSoft)),
            "ink-mute": css(NSColor(Editorial.inkMute)),
            "ink-faint": css(NSColor(Editorial.inkFaint)),
            "rule-c": components(NSColor(Editorial.rule)),
            "rule-a": String(format: "%.4f", rule?.alphaComponent ?? 0.1),
            "accent": css(.controlAccentColor),
            "accent-c": components(.controlAccentColor),
            "label": css(.labelColor),
            "secondary-label": css(.secondaryLabelColor),
            "orange": css(.systemOrange),
            "link": css(.linkColor),
        ]
    }

    // MARK: Timeline (TimelineView forwardOnly, limited to the selected month)

    /// Days of the month selected in the toolbar (‹ Hoje ›). The current
    /// month keeps the forward-only contract (today is the first row, up to
    /// the month's last day); any other month lists all of its days. Days
    /// inside the sync window read `mergedEventsByDay` as before; other
    /// months read the month grid's projection (the fetched month).
    private func buildTimeline(_ appState: AppState,
                               projection: AgendaMonthProjectionCache.Projection) -> [AgendaReactDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let model = projection.model
        let isCurrentMonth = model.calendar.isDate(today, equalTo: model.start, toGranularity: .month)
        let dates = model.monthDays.filter { !isCurrentMonth || $0 >= today }
        var map: [String: CalendarEvent] = [:]
        let days = dates.map { date -> AgendaReactDay in
            let events = isCurrentMonth
                ? appState.mergedEventsByDay[date] ?? []
                : projection.index[date] ?? []
            for event in events { map[event.calendarIdentity] = event }
            let isToday = calendar.isDateInToday(date)
            return AgendaReactDay(
                key: Self.dayKey(date),
                label: isToday ? "HOJE" : Self.weekdayLabel(date),
                day: date.formatted(.dateTime.day()),
                today: isToday,
                past: calendar.startOfDay(for: date) < today,
                events: events.map(payload))
        }
        timelineEvents = map
        return days
    }

    private static func weekdayLabel(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "pt_BR")))
            .uppercased()
            .replacingOccurrences(of: ".", with: "")
    }

    // MARK: Month (AgendaMonthView)

    private func buildMonth(_ parent: AgendaReactView,
                            projection: AgendaMonthProjectionCache.Projection) -> AgendaReactMonth {
        let model = projection.model
        let calendar = model.calendar
        let today = calendar.startOfDay(for: Date())
        var map: [String: CalendarEvent] = [:]
        let cells = model.days.map { day -> AgendaReactCell in
            let events = projection.index[day] ?? []
            for event in events { map[event.calendarIdentity] = event }
            let number = calendar.component(.day, from: day)
            let offset = calendar.dateComponents([.day], from: today, to: day).day ?? 0
            return AgendaReactCell(
                key: Self.dayKey(day),
                number: "\(number)",
                monthLabel: number == 1
                    ? AgendaReactFormat.shortMonth.string(from: day).replacingOccurrences(of: ".", with: "")
                    : nil,
                inMonth: calendar.isDate(day, equalTo: parent.month, toGranularity: .month),
                today: calendar.isDateInToday(day),
                title: AgendaReactFormat.capitalized(AgendaReactFormat.panelTitle.string(from: day)).uppercased(),
                relative: Self.relative(offset),
                tooltip: events.map { AgendaReactFormat.time.string(from: $0.startDate) + "  " + $0.title }
                    .joined(separator: "\n"),
                a11y: Self.accessibility(day, count: events.count),
                events: events.map(payload))
        }
        monthEvents = map
        let fallback = model.monthDays.contains(today) ? today : model.start
        return AgendaReactMonth(key: Self.dayKey(model.start), title: model.title,
                                cells: cells, fallback: Self.dayKey(fallback))
    }

    /// "Hoje", "Amanhã", "Ontem", "Em 5 dias", "Há 3 dias".
    private static func relative(_ offset: Int) -> String {
        switch offset {
        case 0: return "Hoje"
        case 1: return "Amanhã"
        case -1: return "Ontem"
        case let n where n > 1: return "Em \(n) dias"
        default: return "Há \(-offset) dias"
        }
    }

    private static func accessibility(_ day: Date, count: Int) -> String {
        let date = day.formatted(date: .complete, time: .omitted)
        switch count {
        case 0: return date + ", sem compromissos"
        case 1: return date + ", 1 compromisso"
        default: return date + ", \(count) compromissos"
        }
    }

    // MARK: Event payload

    private func payload(_ event: CalendarEvent) -> AgendaReactEvent {
        let myStatus = event.attendees.first { !$0.isOrganizer }?.status
        let accepted = event.attendees.isEmpty || myStatus == .accepted
        // AgendaEventCard.subtitle (location untrimmed) and
        // AgendaDayEventRow.detail (location trimmed).
        let range = AgendaReactFormat.timeRange(event)
        let location = event.location ?? ""
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let initials: String? = event.attendees.first.map { Self.initials($0.name) }
        let meeting = event.meetingURL?.absoluteString
        // A location that is only the meeting link is shown as the join tag.
        let place = trimmed.isEmpty || trimmed == meeting || trimmed.hasPrefix("http") ? nil : trimmed
        return AgendaReactEvent(
            key: event.calendarIdentity,
            title: event.title,
            subtitle: location.isEmpty ? range : range + " · " + location,
            detail: trimmed.isEmpty ? range : range + " · " + trimmed,
            time: AgendaReactFormat.time.string(from: event.startDate),
            accepted: accepted,
            declined: myStatus == .declined,
            cardc: cached("snap:\(event.colorHex)", components: true) { NSColor(Color(googleSnapHex: event.colorHex)) },
            dot: cached("status:\(event.colorHex)", components: false) { NSColor(Color(statusHex: event.colorHex)) },
            darkInk: Self.prefersDarkInk(event.colorHex),
            monogram: event.title.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "•",
            initials: initials,
            start: event.isAllDay ? "Dia" : AgendaReactFormat.time.string(from: event.startDate),
            end: event.isAllDay ? "inteiro" : AgendaReactFormat.time.string(from: event.endDate),
            allDay: event.isAllDay,
            location: place,
            join: Self.joinTag(event.meetingURL),
            people: people(event),
            phase: Self.phase(event))
    }

    private static func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined().uppercased()
    }

    /// Organizer first, then the other guests; meeting rooms are places,
    /// not people.
    private func people(_ event: CalendarEvent) -> [AgendaReactPerson] {
        let guests = event.attendees.filter {
            !($0.email ?? "").lowercased().hasSuffix("@resource.calendar.google.com")
        }
        let ordered = guests.filter(\.isOrganizer) + guests.filter { !$0.isOrganizer }
        let members = parent?.appState.availableMembers ?? []
        return ordered.map { attendee in
            let email = attendee.email?.lowercased()
            let member = email.flatMap { mail in members.first { $0.email?.lowercased() == mail } }
            let name = attendee.name.isEmpty ? (attendee.email ?? "?") : attendee.name
            let seed = email ?? name.lowercased()
            let hex = member?.color ?? Self.personPalette[Int(Self.stableHash(seed) % UInt64(Self.personPalette.count))]
            let photo = member?.profilePicture.flatMap(URL.init(string:)).map(AgendaAvatarSchemeHandler.url(for:))
            return AgendaReactPerson(
                name: attendee.isOrganizer ? name + " (organizador)" : name,
                initials: Self.initials(name).isEmpty ? "?" : String(Self.initials(name).prefix(2)),
                color: cached("person:\(hex)", components: false) { NSColor(Color(hex: hex)) },
                photo: photo,
                organizer: attendee.isOrganizer)
        }
    }

    /// Google Calendar's event palette: every guest keeps one colour.
    private static let personPalette = ["#039BE5", "#7986CB", "#33B679", "#8E24AA", "#E67C73",
                                        "#F4511E", "#0B8043", "#3F51B5", "#D50000", "#616161"]

    /// FNV-1a: stable across launches (String.hashValue is seeded).
    private static func stableHash(_ text: String) -> UInt64 {
        text.utf8.reduce(14_695_981_039_346_656_037 as UInt64) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    private static func joinTag(_ url: URL?) -> AgendaReactJoin? {
        guard let host = url?.host?.lowercased() else { return nil }
        if host.contains("meet.google") { return AgendaReactJoin(label: "Meet") }
        if host.contains("zoom") { return AgendaReactJoin(label: "Zoom") }
        if host.contains("teams") { return AgendaReactJoin(label: "Teams") }
        return AgendaReactJoin(label: "Entrar")
    }

    private static func phase(_ event: CalendarEvent) -> String? {
        guard !event.isAllDay else { return nil }
        let now = Date()
        if event.endDate <= now { return "past" }
        if event.startDate <= now { return "now" }
        return nil
    }

    private func cached(_ key: String, components: Bool, _ make: () -> NSColor) -> String {
        let cacheKey = (components ? "c:" : "") + key
        if let hit = colorCache[cacheKey] { return hit }
        let color = make()
        let value = components ? AgendaReactColor.components(color) : AgendaReactColor.css(color)
        colorCache[cacheKey] = value
        return value
    }

    /// Light calendar colours (yellow, pale green…) need dark ink.
    private static func prefersDarkInk(_ colorHex: String) -> Bool {
        let hex = colorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return false }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        return 0.299 * r + 0.587 * g + 0.114 * b > 0.72
    }

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    fileprivate static func dayKey(_ date: Date) -> String {
        dayKeyFormatter.timeZone = Calendar.current.timeZone
        return dayKeyFormatter.string(from: date)
    }

    // MARK: Messages

    func receive(type: String, message: [String: Any]) {
        guard let parent else { return }
        let appState = parent.appState
        let key = message["key"] as? String
        switch type {
        case "rendered":
            if let seq = message["seq"] as? Int { gate.acknowledge(seq: seq) }
        case "open", "openMonth":
            guard let key, let event = (type == "open" ? timelineEvents : monthEvents)[key] else { return }
            // Existing detail mutations update AppState's event cache. Seed
            // only the opened primary event when browsing beyond the sync window.
            if event.calendarId == "primary", !appState.events.contains(where: { $0.id == event.id }) {
                appState.events.append(event)
            }
            open(event, appState: appState)
        case "menu":
            guard let key, let event = timelineEvents[key],
                  let x = message["x"] as? Double, let y = message["y"] as? Double else { return }
            popUpMenu(for: event, at: NSPoint(x: x, y: y), appState: appState)
        case "join":
            guard let key, let event = (monthEvents[key] ?? timelineEvents[key]),
                  let url = event.meetingURL else { return }
            NSWorkspace.shared.open(url)
        case "retry":
            parent.loader.bump(month: parent.month, appState: appState)
        default:
            break
        }
    }

    private func open(_ event: CalendarEvent, appState: AppState) {
        appState.detailEventOrigin = MouseOriginCapture.currentClickRectInMainWindow()
        withAnimation(.spring(duration: 0.45, bounce: 0.35)) {
            appState.detailEvent = event
        }
    }

    /// AgendaEventCard.buildContextMenu, wired like AgendaTimelineEventRow.
    private func popUpMenu(for event: CalendarEvent, at point: NSPoint, appState: AppState) {
        guard let webView else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(MenuActionBox.invoke), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            let box = MenuActionBox(action)
            item.target = box
            item.representedObject = box
            return item
        }
        menu.addItem(item("Abrir evento", "doc.text.magnifyingglass") { [weak self] in
            self?.open(event, appState: appState)
        })
        if event.meetingURL != nil || !(event.location ?? "").isEmpty {
            menu.addItem(item("Copiar link", "link") {
                let url = event.meetingURL?.absoluteString ?? event.location ?? ""
                guard !url.isEmpty else { return }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(url, forType: .string)
                appState.notify(.success, title: "Link copiado", message: url)
            })
        }
        menu.addItem(.separator())
        menu.addItem(item("Transformar em tarefa", "arrow.2.squarepath") {
            appState.pendingConversion = event
        })
        menu.addItem(.separator())
        menu.addItem(item("Excluir evento", "trash") {
            Task { await appState.deleteEvent(event) }
        })
        // WKWebView is flipped: page coordinates map 1:1 onto the view.
        let viewPoint = webView.isFlipped ? point : NSPoint(x: point.x, y: webView.bounds.height - point.y)
        menu.popUp(positioning: nil, at: viewPoint, in: webView)
    }
}

// MARK: - Guest photos (AvatarStore through a private scheme)

@MainActor
final class AgendaAvatarSchemeHandler: NSObject, WKURLSchemeHandler {
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

// MARK: - Formatting (AgendaMonthView.AgendaFormat)

private enum AgendaReactFormat {
    static let locale = Locale(identifier: "pt_BR")

    static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = format
        return formatter
    }

    static let time = formatter("HH:mm")
    static let shortMonth = formatter("MMM")
    static let panelTitle = formatter("EEEE, d 'de' MMMM")

    static func timeRange(_ event: CalendarEvent) -> String {
        guard !event.isAllDay else { return "Dia inteiro" }
        return time.string(from: event.startDate) + " – " + time.string(from: event.endDate)
    }

    static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}

// MARK: - Colours, glyphs and text metrics

enum AgendaReactColor {
    /// Display-P3 keeps system colours exact; sRGB hex colours convert losslessly.
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
enum AgendaReactResources {
    private static var glyphCache: [CGFloat: [String: AgendaReactGlyph]] = [:]

    /// Template SF Symbols rendered once per backing scale; the page uses
    /// them as CSS masks tinted with the native colours.
    static func glyphs(scale: CGFloat) -> [String: AgendaReactGlyph] {
        if let hit = glyphCache[scale] { return hit }
        var out: [String: AgendaReactGlyph] = [:]
        let size = 11 * Editorial.typeScale
        if let base = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil),
           let image = base.withSymbolConfiguration(.init(pointSize: size, weight: .medium)) {
            out["warning"] = glyph(image, scale: max(scale, 2) * 1.5)
        }
        let symbol = { (name: String, size: CGFloat, weight: NSFont.Weight) -> AgendaReactGlyph? in
            guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
                  let image = base.withSymbolConfiguration(.init(pointSize: size, weight: weight)) else { return nil }
            return glyph(image, scale: max(scale, 2) * 1.5)
        }
        out["pin"] = symbol("mappin.and.ellipse", 9, .semibold)
        out["video"] = symbol("video.fill", 9, .semibold)
        out["sun"] = symbol("sun.max.fill", 9, .semibold)
        glyphCache[scale] = out
        return out
    }

    private static func glyph(_ image: NSImage, scale: CGFloat) -> AgendaReactGlyph? {
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
        return AgendaReactGlyph(url: "data:image/png;base64,\(png.base64EncodedString())",
                                width: size.width, height: size.height)
    }

    /// SwiftUI Text geometry for every text style the page draws, measured
    /// from the same Text/Font the native views use. SwiftUI gives each line
    /// its own rounded box (card 16 + 13, panel row 13 + 11) and puts the
    /// baseline on a whole point; CSS centres the glyphs in the line box.
    /// `<name>` is the box height, `<name>-dy` moves the CSS baseline onto
    /// SwiftUI's.
    private static var metricsCache: [String: CGFloat]?
    static var metrics: [String: CGFloat] {
        if let metricsCache { return metricsCache }
        let scale = Editorial.typeScale
        func nsFont(_ size: CGFloat, _ weight: NSFont.Weight, rounded: Bool = false,
                    italic: Bool = false) -> NSFont {
            var font = NSFont.systemFont(ofSize: size, weight: weight)
            if rounded, let descriptor = font.fontDescriptor.withDesign(.rounded) {
                font = NSFont(descriptor: descriptor, size: size) ?? font
            }
            if italic {
                font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? font
            }
            return font
        }
        var out: [String: CGFloat] = [:]
        func add(_ name: String, _ text: Text, _ font: NSFont) {
            let (box, baseline) = measure(text)
            let natural = font.ascender - font.descender + font.leading
            out[name] = box
            out[name + "-dy"] = baseline - ((box - natural) / 2 + font.ascender)
        }
        add("cardTitle", Text("Ág").font(.system(size: 13.8, weight: .semibold)), nsFont(13.8, .semibold))
        add("cardSubtitle", Text("Ág").font(.caption), nsFont(10, .regular))
        add("avatar", Text("ÁG").font(.system(size: 9, weight: .bold)), nsFont(9, .bold))
        add("dateLabel", Text("HOJE").font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(0.7),
            nsFont(9, .semibold, rounded: true))
        add("dateNumber", Text("24").font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit(),
            nsFont(24, .semibold, rounded: true))
        add("empty", Text("— Sem").font(Editorial.serif(13.5).italic()), nsFont(13.5 * scale, .regular, italic: true))
        add("weekday", Text("SEG").font(Editorial.sans(10, .semibold)).tracking(1.2), nsFont(10 * scale, .semibold))
        add("cellNumber", Text("24").font(Editorial.sans(12.5, .semibold)).monospacedDigit(),
            nsFont(12.5 * scale, .semibold))
        add("cellNumberToday", Text("24").font(Editorial.sans(12.5, .bold)).monospacedDigit(),
            nsFont(12.5 * scale, .bold))
        add("cellMonth", Text("set").font(Editorial.sans(11, .medium)), nsFont(11 * scale, .medium))
        add("folio", Text("QUI").font(Editorial.sans(10.5, .semibold)).tracking(1.4), nsFont(10.5 * scale, .semibold))
        add("relative", Text("Hoje").font(Editorial.sans(11, .medium)), nsFont(11 * scale, .medium))
        add("rowTitle", Text("Ág").font(Editorial.sans(12.5, .semibold)), nsFont(12.5 * scale, .semibold))
        add("rowDetail", Text("Ág").font(Editorial.sans(11, .medium)), nsFont(11 * scale, .medium))
        add("panelEmpty", Text("Ág").font(Editorial.sans(12, .medium)), nsFont(12 * scale, .medium))
        add("banner", Text("Ág").font(Editorial.sans(11, .medium)), nsFont(11 * scale, .medium))
        // AgendaEventDot / AgendaMoreDot glyphs (size × 0.56, × 0.5, × 0.42).
        for (name, size) in [("disc14", 14 * 0.56), ("disc22", 22 * 0.56), ("more", 14 * 0.5), ("moreSmall", 14 * 0.42)] {
            add(name, Text("R").font(.system(size: size, weight: .bold, design: .rounded)),
                nsFont(size, .bold, rounded: true))
        }
        metricsCache = out
        return out
    }

    /// Box height and first baseline of a single-line Text.
    private static func measure(_ text: Text) -> (CGFloat, CGFloat) {
        final class Probe: @unchecked Sendable { var baseline: CGFloat = 0 }
        let probe = Probe()
        let view = HStack(alignment: .top, spacing: 0) {
            text.alignmentGuide(.top) { dimensions in
                probe.baseline = dimensions[.firstTextBaseline]
                return dimensions[.top]
            }
            Color.clear.frame(width: 1, height: 1)
        }.fixedSize()
        let host = NSHostingView(rootView: view)
        let height = host.fittingSize.height
        host.frame = NSRect(x: 0, y: 0, width: 400, height: height)
        host.layoutSubtreeIfNeeded()
        return (height, probe.baseline)
    }
}
#endif
