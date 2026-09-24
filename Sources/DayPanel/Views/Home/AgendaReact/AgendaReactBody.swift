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

    /// TimelineView.headerToFirstCardSpacing.
    private static let headerToFirstCardSpacing: CGFloat = 43

    var body: some View {
        GeometryReader { geo in
            let timelineW = AgendaLayout.timelineWidth(max(1, geo.size.width))
            AgendaReactView(month: month,
                            appState: appState,
                            loader: loader,
                            agendaTop: Self.headerToFirstCardSpacing + agendaTopInset,
                            monthTop: inboxTopInset,
                            occlusion: EditorialHomeHeader.chromeHeight)
                // TimelineView's floating "add coworker's calendar" search,
                // anchored to the events column's bottom-trailing corner.
                .overlay(alignment: .bottomLeading) {
                    SharedCalendarSearchBar()
                        .environmentObject(appState)
                        .frame(width: max(220, timelineW * 0.85), alignment: .trailing)
                        .padding(.trailing, 14)
                        .padding(.bottom, 16)
                        .frame(width: timelineW, alignment: .trailing)
                }
                // AgendaMonthView's loading indicator.
                .overlay(alignment: .bottomTrailing) {
                    if loader.loading {
                        ProgressView().controlSize(.small).padding(.trailing, 24).padding(.bottom, 24)
                    }
                }
        }
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

    func ensureWebView() -> AgendaReactWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
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
    private var revealSeq: Int?
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
        // still hold the previous mount's scroll offset.
        webView.alphaValue = 0
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
            let timeline = buildTimeline(appState)
            if timeline != sentTimeline || needsFull {
                patch.timeline = timeline
                sentTimeline = timeline
                changed = true
            }
            let month = buildMonth(parent)
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
        if needsFull { revealSeq = patch.seq }
        needsFull = false
        webView.headerOcclusionHeight = parent.occlusion
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

    // MARK: Timeline (TimelineView forwardOnly: today … today + 30)

    private func buildTimeline(_ appState: AppState) -> [AgendaReactDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dates = (0...30).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        var map: [String: CalendarEvent] = [:]
        let days = dates.map { date -> AgendaReactDay in
            let events = appState.mergedEventsByDay[date] ?? []
            for event in events { map[event.calendarIdentity] = event }
            let isToday = calendar.isDateInToday(date)
            return AgendaReactDay(
                key: Self.dayKey(date),
                label: isToday ? "HOJE" : Self.weekdayLabel(date),
                day: date.formatted(.dateTime.day()),
                today: isToday,
                past: calendar.startOfDay(for: date) < calendar.startOfDay(for: Date()),
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

    private func buildMonth(_ parent: AgendaReactView) -> AgendaReactMonth {
        let appState = parent.appState
        let projection = monthCache.resolve(month: parent.month, primary: appState.events,
                                            shared: appState.sharedEvents,
                                            fetched: parent.loader.fetchedEvents)
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
        let initials: String? = event.attendees.first.map { attendee in
            attendee.name.split(separator: " ").prefix(2)
                .compactMap { $0.first.map(String.init) }
                .joined().uppercased()
        }
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
            initials: initials)
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
            if let revealSeq, let seq = message["seq"] as? Int, seq >= revealSeq {
                self.revealSeq = nil
                webView?.alphaValue = 1
            }
        case "open":
            guard let key, let event = timelineEvents[key] else { return }
            open(event, appState: appState)
        case "openMonth":
            guard let key, let event = monthEvents[key] else { return }
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

    /// SwiftUI Text line heights for every text style the page draws.
    static let metrics: [String: CGFloat] = {
        let layout = NSLayoutManager()
        let scale = Editorial.typeScale
        func line(_ font: NSFont) -> CGFloat { layout.defaultLineHeight(for: font) }
        func system(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont { .systemFont(ofSize: size, weight: weight) }
        func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        }
        func italic(_ size: CGFloat) -> NSFont {
            let base = NSFont.systemFont(ofSize: size)
            return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? base
        }
        return [
            "cardTitle": line(system(13.8, .semibold)),
            "cardSubtitle": line(system(10, .regular)),
            "avatar": line(system(9, .bold)),
            "dateLabel": line(rounded(9, .semibold)),
            "dateNumber": line(rounded(24, .semibold)),
            "empty": line(italic(13.5 * scale)),
            "weekday": line(system(10 * scale, .semibold)),
            "cellNumber": line(system(12.5 * scale, .bold)),
            "cellMonth": line(system(11 * scale, .medium)),
            "folio": line(system(10.5 * scale, .semibold)),
            "relative": line(system(11 * scale, .medium)),
            "rowTitle": line(system(12.5 * scale, .semibold)),
            "rowDetail": line(system(11 * scale, .medium)),
            "panelEmpty": line(system(12 * scale, .medium)),
            "banner": line(system(11 * scale, .medium)),
        ]
    }()
}
#endif
