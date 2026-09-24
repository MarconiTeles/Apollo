import SwiftUI
import AppKit

// Agenda-style timeline modeled after Google Calendar's mobile "Agenda"
// view: each day is a row with its weekday/day-number on the left and a
// stacked list of event cards on the right. No hour grid, no positional
// time math — events are listed in chronological order, top-to-bottom.

struct TimelineView: View {
    @EnvironmentObject var appState: AppState

    /// When `true`, the timeline starts AT today and only goes
    /// forward (today + 30 days). Used by the Home/Hoje route
    /// where past days are noise. Default (false) preserves the
    /// legacy ±30-day window so the rest of the dashboard stays
    /// scrollable to recent past entries.
    var forwardOnly: Bool = false

    /// Extra resting reserve used when this recycled list sits below a pinned
    /// overlay. Because it is part of the scroll content (not the viewport),
    /// rows can still travel underneath the overlay during a scroll.
    var topContentInset: CGFloat = 0

    /// Visible date window. Past entries are dropped on the
    /// forward-only variant.
    private var dates: [Date] {
        let cal   = Calendar.current
        let today = cal.startOfDay(for: Date())
        let range = forwardOnly ? (0...30) : (-30...30)
        return range.compactMap { cal.date(byAdding: .day, value: $0, to: today) }
    }

    /// Approx. height per day section — used by scroll-position math to
    /// figure out which day is currently in view.
    private let sectionEstimate: CGFloat = 96
    /// Resting distance from the Agenda header to the first event row.
    private let headerToFirstCardSpacing: CGFloat = 43

    @State private var scrollLockUntil:    Date = .distantPast
    @State private var suppressAutoScroll: Bool = false
    @State private var didInitialScroll:   Bool = false
    /// Owns only the native scroll commands; event data stays in AppState.
    @State private var agendaScroll = AgendaScrollController()
    @State private var lastScrollIndex:    Int  = -1
    /// The date that the SCROLL POSITION currently points at,
    /// derived from the live `TimelineScrollOffsetKey`
    /// preference. Stays in local @State during active scroll
    /// so the per-frame preference change does NOT mutate
    /// `appState.selectedDate` — that mutation is a
    /// `@Published` write that triggers re-evaluation of every
    /// view in the app observing AppState, costing 30+ ms per
    /// frame and tanking scroll FPS to ~25. The local @State
    /// is committed to AppState only when scrolling settles
    /// (see the `.onReceive(ScrollStateObserver.shared
    /// .$isScrolling)` handler in `body`).
    @State private var pendingSelectedDate: Date? = nil
    /// Live-measured width of the timeline column. Captured
    /// via a `.background(GeometryReader { ... })` on the
    /// ScrollView so the floating search bar can size itself
    /// as a percentage of THIS column's width — not the
    /// whole-window width, which is what
    /// `containerRelativeFrame(.horizontal)` was incorrectly
    /// resolving to (overlays attached to a ScrollView count
    /// as outside the scroll-view container for that
    /// modifier, so it falls back to the window).
    @State private var timelineWidth:      CGFloat = 0

    /// The Home agenda is forward-only, so "today" is its first row.
    /// Anchoring a tall day at 20% could put its beginning above the
    /// viewport and make the page appear to start on tomorrow. Keep the
    /// current day at the top; the scroll-content inset below the Finder
    /// header supplies the visual breathing room.
    private let todayAnchor: UnitPoint = .top

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if forwardOnly {
                    AgendaNativeList(
                        rows: AgendaTimelineRow.makeRows(dates: dates,
                            eventsByDay: appState.mergedEventsByDay),
                        appState: appState,
                        topReserve: headerToFirstCardSpacing + topContentInset,
                        leading: 20, trailing: 16, controller: agendaScroll)
                } else {
                    // Each event is one recyclable row. A whole-day VStack forced
                    // List to measure/mount every card inside each materialized day.
                    List {
                        // A concrete first row is more reliable than
                        // `.contentMargins(.top:)` on macOS List/NSTableView. The
                        // latter is represented as a scroll-view inset and could
                        // consume the first real day while reporting the viewport at
                        // its top. This row guarantees that TODAY is physically the
                        // first agenda section below the pinned Finder header, then
                        // scrolls away with the rest of the content.
                        Color.clear
                            .frame(height: headerToFirstCardSpacing + topContentInset)
                            .id("apollo-agenda-top-reserve")
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())

                        ForEach(AgendaTimelineRow.makeRows(dates: dates,
                                                          eventsByDay: appState.mergedEventsByDay)) { row in
                            AgendaTimelineEventRow(row: row, appState: appState)
                                .equatable()
                                .id(row.id)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 0, leading: forwardOnly ? 20 : 26,
                                                          bottom: 0, trailing: forwardOnly ? 16 : 32))
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    // Sem barra de rolagem na agenda da Home (pedido de 20/jul) —
                    // o scroll segue funcionando por trackpad/wheel.
                    .scrollIndicators(.hidden)
                    // Match the previous `.padding(.top, 24)` /
                    // `.padding(.bottom, 60)`. `contentMargins` adds
                    // the space INSIDE the scroll area, so it scrolls
                    // with the content (the empty space above the
                    // first row scrolls upward and out of view, just
                    // like padding inside the LazyVStack).
                    .contentMargins(.bottom, 60, for: .scrollContent)
                }
            }
            // NSScrollView introspect — listens to the
            // underlying NSClipView's `boundsDidChange`
            // notification to read the scroll offset
            // directly. Replaces a GeometryReader +
            // PreferenceKey pair that was bouncing the
            // scroll offset up through SwiftUI's preference
            // machinery on every scroll tick.
            .background(
                ScrollOffsetIntrospect(normalizeInitialOffset: forwardOnly) { offset in
                    // Home is a forward-only agenda whose first row is always
                    // today. Letting passive scroll telemetry mutate the
                    // global selected date caused the following day to trigger
                    // a second programmatic jump immediately after launch.
                    // The legacy ±30-day timeline still synchronises its date
                    // selection from the scroll position.
                    guard !forwardOnly else { return }
                    // `offset` is `clipView.documentVisibleRect.minY`,
                    // i.e. how far down the user has scrolled.
                    guard Date() > scrollLockUntil else { return }
                    // Keep the date mapping anchored to the first real row.
                    // Home adds a scroll-content reserve for the translucent
                    // header; counting that reserve as a day used to advance
                    // the selected date before the first row reached the top.
                    let contentStart = headerToFirstCardSpacing + topContentInset
                    let approxIndex = Int(((offset - contentStart) / sectionEstimate).rounded(.down))
                    let clamped     = max(0, min(approxIndex, dates.count - 1))
                    guard clamped != lastScrollIndex else { return }
                    lastScrollIndex = clamped
                    // Stash in LOCAL @State only — the
                    // commit to `appState.selectedDate`
                    // happens after the scroll settles
                    // (see `ScrollStateObserver` handler
                    // below) to avoid a `@Published`
                    // cascade per scroll tick.
                    pendingSelectedDate = dates[clamped]
                }
            )
            // Bottom-edge fade — blurs the events that scroll
            // beneath the floating search bar so the chips +
            // input read cleanly. Pinned to `Editorial.paper`
            // (NOT `windowBackgroundColor`): the app is hard-
            // locked to the light Editorial appearance, so the
            // fade must always dissolve into the cream canvas.
            // Using the dynamic system color made the fade go
            // BLACK under macOS Dark Mode (it resolves against
            // the system appearance, bypassing the SwiftUI
            // colorScheme lock). Multi-stop curve creates a smooth
            // exponential ramp instead of a hard band, so
            // the fade reads as "content gracefully
            // dissolving into the background" rather than a
            // dark oil-stain overlay.
            .overlay(alignment: .bottom) {
                // PERF: 5-stop gradient → 2-stop gradient.
                // CoreAnimation interpolates a 2-stop linear
                // gradient natively (single rasterisation,
                // GPU-accelerated). 5+ stops force CA to fall
                // back to a CPU-rasterised gradient layer
                // recomputed every time the layer's bounds
                // change — which happens on every scroll
                // tick. The visual difference between linear
                // 2-stop and the previous multi-stop curve
                // is imperceptible at this size against the
                // window background.
                let bg = Editorial.paper
                LinearGradient(
                    colors: [bg.opacity(0.00), bg.opacity(0.92)],
                    startPoint: .top,
                    endPoint:   .bottom
                )
                .frame(height: 120)
                .allowsHitTesting(false)
                .drawingGroup()
            }
            // Width measurement for the floating search bar.
            // Lives in `.background` so it doesn't
            // contribute to the ScrollView's layout — pure
            // measurement, zero rendering cost. Re-fires
            // only when the timeline column's frame
            // actually changes (window resize), not on
            // every scroll tick.
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { timelineWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in
                            timelineWidth = w
                        }
                }
            )
            // Floating "add coworker's calendar" search,
            // anchored bottom-TRAILING of the scroll viewport
            // (NOT centered) so the collapsed "+" button
            // sits in the bottom-right corner of the events
            // column — matching the user's reference where
            // the button lines up with the rightmost avatar
            // column. When expanded, the bar grows leftward
            // from that anchor, filling 85% of the column
            // width while keeping its right edge pinned.
            //
            // The column width comes from the
            // `.background(GeometryReader { ... })` measurement
            // above; we can't use
            // `containerRelativeFrame(.horizontal)` here
            // because for overlays attached to a ScrollView,
            // that modifier resolves the container as the
            // window, not the ScrollView.
            .overlay(alignment: .bottomTrailing) {
                SharedCalendarSearchBar()
                    .environmentObject(appState)
                    // `alignment: .trailing` pins the inner
                    // VStack to the right edge of the 85%
                    // frame. Without this the .frame
                    // defaults to `.center` alignment — and
                    // when the SharedCalendarSearchBar's
                    // VStack has only the small button (no
                    // chips) its intrinsic width is just
                    // ~42pt, so the default-centered frame
                    // visually parked the button in the
                    // middle of the column despite the
                    // outer overlay being `.bottomTrailing`.
                    // With trailing alignment here the
                    // button hugs the right edge of the
                    // 85% frame, which itself hugs the
                    // right edge of the events column.
                    .frame(
                        width: max(220, timelineWidth * 0.85),
                        alignment: .trailing
                    )
                    .padding(.trailing, 14)
                    .padding(.bottom, 16)
            }
            .onAppear {
                let today = Calendar.current.startOfDay(for: Date())
                if !Calendar.current.isDateInToday(appState.selectedDate) {
                    suppressAutoScroll = true
                    appState.selectedDate = today
                }
                // In the forward-only Home agenda, today is already the first
                // row. Let the recycled List rest at its natural origin so its
                // top content margin stays intact. Programmatically scrolling
                // a variable-height first row could advance the viewport to
                // tomorrow. The legacy ±30-day timeline still needs an
                // explicit jump to today.
                if !forwardOnly {
                    scrollToDay(today, proxy: proxy, animate: false, anchor: todayAnchor)
                }
                if !appState.events.isEmpty { didInitialScroll = true }
            }
            .onChange(of: appState.events.count) { _, _ in
                guard !didInitialScroll, !appState.events.isEmpty else { return }
                // Scroll to TODAY explicitly here — `selectedDate`
                // could have been mutated by some other view
                // before events finished loading, which would
                // otherwise land the timeline on whatever date
                // the picker happens to be on instead of today.
                let today = Calendar.current.startOfDay(for: Date())
                if !forwardOnly {
                    scrollToDay(today, proxy: proxy, animate: true, anchor: todayAnchor)
                }
                didInitialScroll = true
            }
            .onChange(of: appState.selectedDate) { old, new in
                guard !Calendar.current.isDate(old, inSameDayAs: new) else { return }
                guard !suppressAutoScroll else { suppressAutoScroll = false; return }
                scrollToDay(new, proxy: proxy, animate: true)
            }
            .onChange(of: appState.todayJumpToken) { _, _ in
                let today = Calendar.current.startOfDay(for: Date())
                if !Calendar.current.isDate(appState.selectedDate, inSameDayAs: today) {
                    suppressAutoScroll = true
                    appState.selectedDate = today
                }
                // Restore the exact resting reserve without rebuilding cards.
                if forwardOnly {
                    agendaScroll.reset()
                    pendingSelectedDate = nil
                    lastScrollIndex = -1
                } else {
                    scrollToDay(today, proxy: proxy, animate: true, anchor: todayAnchor)
                }
            }
            // Commit `pendingSelectedDate` to AppState only
            // when the live scroll has ended. ScrollStateObserver
            // fires `false` ~180ms after the last scroll
            // event (momentum decay grace period) — by then
            // the user is no longer scrolling and the @Published
            // cascade is harmless. Net: zero AppState writes
            // during active scroll instead of one-per-day-
            // boundary-crossed.
            .onReceive(ScrollStateObserver.shared.$isScrolling) { scrolling in
                guard !forwardOnly, !scrolling,
                      let date = pendingSelectedDate
                else { return }
                if !Calendar.current.isDate(date, inSameDayAs: appState.selectedDate) {
                    suppressAutoScroll = true
                    appState.selectedDate = date
                }
                pendingSelectedDate = nil
            }
        }
    }

    private func scrollToDay(_ date: Date, proxy: ScrollViewProxy,
                             animate: Bool, anchor: UnitPoint = .top) {
        let dayStart = Calendar.current.startOfDay(for: date)
        if forwardOnly {
            agendaScroll.scroll(to: dayStart, animated: animate)
            return
        }
        let action: () -> Void = {
            // Match the concrete ID type used by the mixed day/event rows.
            proxy.scrollTo(AnyHashable(dayStart), anchor: anchor)
        }
        if animate {
            withAnimation(.easeInOut(duration: 0.35)) { action() }
        } else {
            action()
        }
    }
}

// MARK: - Scroll offset introspect (replaces TimelineScrollOffsetKey)

/// Hidden NSViewRepresentable that walks up to the enclosing
/// `NSScrollView`, registers for its `NSClipView`'s
/// `boundsDidChange` notification, and forwards the visible
/// rect's `minY` to the supplied closure.
///
/// Used by `TimelineView` to track the scroll position without
/// the per-frame cost of a `GeometryReader` + `PreferenceKey`
/// pair. The notification path is what AppKit uses internally
/// for scroll observers and is much cheaper than bouncing the
/// offset through SwiftUI's preference machinery on every
/// scroll tick.
private struct ScrollOffsetIntrospect: NSViewRepresentable {
    let normalizeInitialOffset: Bool
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let probe = NSView()
        // Defer the lookup until after the view is added to
        // its window — at `makeNSView` time the probe has no
        // superview yet.
        DispatchQueue.main.async { [weak probe] in
            guard let probe else { return }
            // Walk up until we find the enclosing NSScrollView.
            // SwiftUI's `ScrollView` becomes an NSScrollView
            // somewhere up the responder chain, with our probe
            // sitting inside the NSHostingView → NSClipView.
            var current: NSView? = probe.superview
            while let v = current {
                if let scroll = v as? NSScrollView {
                    context.coordinator.attach(to: scroll,
                                               normalizeInitialOffset: normalizeInitialOffset,
                                               callback: onChange)
                    return
                }
                current = v.superview
            }
        }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Refresh the closure on every parent re-render so it
        // captures the latest @State references / dates list.
        context.coordinator.callback = onChange
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var clipView: NSClipView?
        var callback: ((CGFloat) -> Void)?
        var observer: NSObjectProtocol?
        var normalizeInitialOffset = false
        var restingOffset: CGFloat?

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func attach(to scrollView: NSScrollView,
                    normalizeInitialOffset: Bool,
                    callback: @escaping (CGFloat) -> Void) {
            self.callback = callback
            self.normalizeInitialOffset = normalizeInitialOffset
            let clip = scrollView.contentView
            self.clipView = clip
            restingOffset = normalizeInitialOffset
                ? clip.documentVisibleRect.minY
                : nil
            clip.postsBoundsChangedNotifications = true
            self.observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clip,
                queue: .main
            ) { [weak self] _ in
                guard let self, let clip = self.clipView else { return }
                let raw = clip.documentVisibleRect.minY
                let offset = self.normalizeInitialOffset
                    ? raw - (self.restingOffset ?? raw)
                    : raw
                self.callback?(offset)
            }
        }
    }
}

// MARK: - Recyclable agenda rows

/// Day anchors retain the existing scrollTo(Date) contract. Other rows have
/// calendar-qualified identities, so a shared meeting remains a distinct card.
struct AgendaTimelineRow: Identifiable, Equatable {
    struct EventID: Hashable {
        let date: Date
        let calendarIdentity: String
    }
    let date: Date
    let event: CalendarEvent?
    let isFirst: Bool
    let isLast: Bool

    var id: AnyHashable {
        if isFirst { return AnyHashable(date) }
        return AnyHashable(EventID(date: date, calendarIdentity: event!.calendarIdentity))
    }

    static func makeRows(dates: [Date], eventsByDay: [Date: [CalendarEvent]]) -> [Self] {
        dates.flatMap { date -> [Self] in
            let events = eventsByDay[date] ?? []
            guard !events.isEmpty else {
                return [Self(date: date, event: nil, isFirst: true, isLast: true)]
            }
            return events.enumerated().map { index, event in
                Self(date: date, event: event, isFirst: index == 0,
                     isLast: index == events.count - 1)
            }
        }
    }
}

struct AgendaTimelineEventRow: View, Equatable {
    let row: AgendaTimelineRow
    let appState: AppState

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.appState === rhs.appState
    }

    private var isPast: Bool {
        Calendar.current.startOfDay(for: row.date)
            < Calendar.current.startOfDay(for: Date())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 17) {
            // The original gutter is 52pt tall but an event is 47pt. On busy
            // days the gutter must not increase the first card's 53pt stride.
            Color.clear.frame(width: 46, height: 0)
                .overlay(alignment: .top) {
                    if row.isFirst { AgendaDateColumn(date: row.date) }
                }
            if let event = row.event {
                AgendaEventCard(
                    event: event,
                    onTap: handleTap,
                    onConvert: { appState.pendingConversion = $0 },
                    onCopyLink: { ev in
                        let url = ev.meetingURL?.absoluteString ?? ev.location ?? ""
                        guard !url.isEmpty else { return }
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(url, forType: .string)
                        appState.notify(.success, title: "Link copiado", message: url)
                    },
                    onDelete: { ev in Task { await appState.deleteEvent(ev) } })
                    .equatable()
                    .transition(.opacity)
            } else {
                Text("— Sem compromissos")
                    .font(Editorial.serif(13.5).italic())
                    .foregroundStyle(Editorial.inkMute)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity,
               minHeight: row.isFirst && row.isLast ? 52 : nil, alignment: .topLeading)
        .opacity(isPast ? 0.55 : 1)
        .padding(.bottom, row.isLast ? 22 : 6)
        .background(AgendaRowClipping(clipsAtDayStart: row.isFirst))
    }

    private func handleTap(_ event: CalendarEvent) {
        // No click haptic — the trackpad's own click pulse is
        // the natural feedback for opening the event detail.
        appState.detailEventOrigin = MouseOriginCapture
            .currentClickRectInMainWindow()
        withAnimation(.spring(duration: 0.45, bounce: 0.35)) {
            appState.detailEvent = event
        }
    }
}

/// The old day-sized host allowed a later card's shadow into the preceding
/// 6pt gap. Native List rows otherwise clip that shadow at each event boundary.
/// Keep the original clip at the beginning of a day; leave the scroll viewport
/// untouched. Reapply on reuse so a former continuation can become a day start.
private struct AgendaRowClipping: NSViewRepresentable {
    let clipsAtDayStart: Bool

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.clipsAtDayStart = clipsAtDayStart
        view.updateRow()
    }

    final class Probe: NSView {
        var clipsAtDayStart = true

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // SwiftUI finishes assembling the row after attaching this probe.
            DispatchQueue.main.async { [weak self] in self?.updateRow() }
        }
        override func layout() {
            super.layout()
            updateRow()
        }

        func updateRow() {
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let row = view as? NSTableRowView {
                    if row.clipsToBounds != clipsAtDayStart {
                        row.clipsToBounds = clipsAtDayStart
                    }
                    if let layer = row.layer, layer.masksToBounds != clipsAtDayStart {
                        layer.masksToBounds = clipsAtDayStart
                    }
                    return
                }
                if view is NSTableView || view is NSClipView { return }
                ancestor = view.superview
            }
        }
    }
}

private struct AgendaDateColumn: View {
    let date: Date
    private var isToday: Bool { Calendar.current.isDateInToday(date) }

    var body: some View {
        // Flat calendar typography. Today is identified exclusively by the
        // HOJE label; a surrounding tile looked like a second selection
        // control and competed with the event cards beside it.
        VStack(spacing: 1) {
            Text(isToday ? "HOJE" : weekdayLabel)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(isToday ? Editorial.accent : Editorial.inkMute)

            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(Editorial.ink)
                .monospacedDigit()
        }
        .frame(width: 46, height: 46, alignment: .center)
        .padding(.top, 6)
    }

    private var weekdayLabel: String {
        date.formatted(.dateTime.weekday(.abbreviated)
            .locale(Locale(identifier: "pt_BR")))
            .uppercased()
            .replacingOccurrences(of: ".", with: "")
    }

}

// MARK: - Agenda-style event card (replaces the old positional EventBlock)

struct AgendaEventCard: View, Equatable {
    let event: CalendarEvent
    /// Click handler hoisted into a closure so the card itself
    /// does NOT need to depend on `@EnvironmentObject AppState`.
    /// Without this, every `@Published` change anywhere in
    /// AppState forces SwiftUI to re-evaluate every visible
    /// card's Equatable check — cheap individually but
    /// multiplied by 15+ visible cards × N AppState updates per
    /// second, it added measurable scroll overhead. The card
    /// now reads ZERO state from AppState; the parent
    /// `AgendaTimelineEventRow` wires the click action.
    let onTap: (CalendarEvent) -> Void
    /// Right-click context-menu actions. Closures keep the card
    /// free of `@EnvironmentObject AppState`, preserving the
    /// scroll-time Equatable short-circuit; the parent
    /// `AgendaTimelineEventRow` wires them to AppState.
    var onConvert: ((CalendarEvent) -> Void)? = nil
    var onCopyLink: ((CalendarEvent) -> Void)? = nil
    var onDelete: ((CalendarEvent) -> Void)? = nil

    /// Unrelated AppState updates skip unchanged cards. Comparing the full
    /// event also keeps retained actions current when only metadata changes.
    static func == (lhs: AgendaEventCard, rhs: AgendaEventCard) -> Bool {
        // Reused rows also hold the complete event for click/context-menu
        // actions. Preserve calendar identity, all-day labels, avatars and
        // action metadata when another calendar's copy changes.
        lhs.event == rhs.event
    }

    private var color: Color { Color(googleSnapHex: event.colorHex) }

    private var myStatus: CalendarEvent.Attendee.Status? {
        event.attendees.first { !$0.isOrganizer }?.status
    }

    private var isAccepted: Bool {
        if event.attendees.isEmpty { return true }
        return myStatus == .accepted
    }

    private var isDeclined: Bool { myStatus == .declined }

    private var timeRangeText: String {
        if event.isAllDay { return "Dia inteiro" }
        // Was `Date.FormatStyle` via `.formatted(date:time:)`,
        // which allocates a fresh format style + re-resolves the
        // locale on every call. With 15-20 visible event cards
        // re-evaluating on every scroll frame, that compounded
        // into 30+ FormatStyle allocations per frame. The
        // shared cached `DateFormatter` reuses one instance for
        // the life of the app — see `SharedDateFormatters`.
        let f = SharedDateFormatters.shortTime24h
        return "\(f.string(from: event.startDate)) – \(f.string(from: event.endDate))"
    }

    private var subtitle: String {
        var parts: [String] = [timeRangeText]
        if let loc = event.location, !loc.isEmpty { parts.append(loc) }
        return parts.joined(separator: " · ")
    }

    private var shape: RoundedRectangle {
        // 13pt = 10pt × 1.3 — softer pill silhouette per design tweak.
        RoundedRectangle(cornerRadius: 13, style: .continuous)
    }

    /// Filled card keeps a near-invisible dark hairline so the rounded
    /// corners read crisply against the agenda background. Outlined
    /// cards drop the stroke entirely — the calendar colour is conveyed
    /// by a coloured drop shadow instead, which renders much cleaner
    /// than a 1pt stroke at native pixel densities.
    private var borderColour: Color {
        isAccepted ? Color.black.opacity(0.08) : Color.clear
    }
    private var borderWidth: CGFloat {
        isAccepted ? 0.5 : 0
    }

    var body: some View {
        Button {
            onTap(event)
        } label: {
            // Restored from the final pre-Editorial-Calm implementation
            // (`474cdcb^`). It deliberately keeps the current data/state
            // plumbing while bringing back the compact, colour-tinted event
            // capsule that visually belongs with the current Apollo UI.
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.system(size: 13.8, weight: .semibold))
                        .foregroundStyle(isAccepted ? Color.white : .primary)
                        .strikethrough(isDeclined, color: .secondary)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(isAccepted
                            ? Color.white.opacity(0.85)
                            : .secondary)
                        .lineLimit(1)
                }
                .opacity(isDeclined ? 0.6 : 1)

                Spacer(minLength: 0)

                if let first = event.attendees.first {
                    avatar(for: first)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isAccepted {
                    shape.fill(color)
                } else {
                    shape.fill(color.opacity(0.14))
                }
            }
            .overlay {
                if borderWidth > 0 {
                    shape.strokeBorder(borderColour, lineWidth: borderWidth)
                }
            }
            .drawingGroup()
            .shadow(
                color: isAccepted ? .black.opacity(0.18) : color.opacity(0.45),
                radius: 4,
                x: 0,
                y: 1
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .interactivePillFeedback(
            accent: color,
            cornerRadius: 13,
            glow: true,
            hoverScale: 1.015,
            pulseFromClick: true
        )
        // Right-click context menu rendered via a native NSMenu
        // overlay rather than SwiftUI `.contextMenu`. The host
        // List would otherwise show its row-selection highlight
        // (blue rectangle around the WHOLE day section) on
        // right-click; the AppKit catcher intercepts the right-
        // click before the List sees it, so no row selection
        // is triggered. Left-clicks pass through untouched (the
        // catcher's `hitTest` returns nil unless a right button
        // is currently pressed).
        //
        // Mounted as an `.overlay` (in FRONT of the event Button),
        // not `.background`: as a background it sat BEHIND the
        // Button's hosting view, which won the hit-test for the
        // right-click so `rightMouseDown` never reached the catcher
        // and the menu silently never opened. In front, the catcher
        // wins right-clicks (its hitTest returns self only while the
        // secondary button is down) while still passing every
        // left-click through to the Button below.
        .overlay(
            EventRightClickCatcher { buildContextMenu() }
                .allowsHitTesting(true)
        )
    }

    /// Builds the native NSMenu for this event. Constructed once
    /// per right-click — items pull from the closures supplied by
    /// the parent so the menu mirrors the data on every open.
    private func buildContextMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false

        func item(_ title: String, _ symbol: String,
                  _ action: @escaping () -> Void) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: #selector(MenuActionBox.invoke),
                                keyEquivalent: "")
            it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            let box = MenuActionBox(action)
            it.target = box               // weak — retained by representedObject below
            it.representedObject = box
            return it
        }

        m.addItem(item("Abrir evento", "doc.text.magnifyingglass") { [event] in onTap(event) })

        let hasLink = event.meetingURL != nil
            || !(event.location ?? "").isEmpty
        if let onCopyLink, hasLink {
            m.addItem(item("Copiar link", "link") { [event] in onCopyLink(event) })
        }

        m.addItem(.separator())

        if let onConvert {
            m.addItem(item("Transformar em tarefa", "arrow.2.squarepath") { [event] in onConvert(event) })
        }

        if let onDelete {
            m.addItem(.separator())
            m.addItem(item("Excluir evento", "trash") { [event] in onDelete(event) })
        }
        return m
    }

    @ViewBuilder
    private func avatar(for attendee: CalendarEvent.Attendee) -> some View {
        let initials = attendee.name
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()

        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(isAccepted ? 0.35 : 0.20))

            Text(initials.isEmpty ? "?" : initials)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isAccepted ? Color.white : Color.accentColor)
        }
        .frame(width: 22, height: 22)
        .overlay(
            Circle().strokeBorder(
                isAccepted ? Color.white.opacity(0.5) : Color.clear,
                lineWidth: 0.5
            )
        )
    }
}

// MARK: - Shared glass section header (kept for TaskList)

struct GlassSectionHeader: View {
    let label: String
    let icon:  String
    let count: Int
    let tint:  Color

    var body: some View {
        HStack(spacing: 8) {
            Label(label, systemImage: icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .labelStyle(CompactLabelStyle())
                .tracking(0.4)

            Text("\(count)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(tint, in: Capsule())

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - Native right-click menu host
//
// SwiftUI's `.contextMenu` on a `List` row triggers the
// underlying NSTableView's row-selection highlight (a blue
// rectangle around the entire row) before the menu opens.
// For the timeline — where each List row contains a whole day
// section with multiple events — that meant right-clicking a
// single event lit up the WHOLE day. This catcher pops up the
// menu via AppKit before the List sees the event, so no row
// selection ever fires. `hitTest` is left-click-transparent
// (returns `nil` unless the secondary mouse button is currently
// pressed), so the SwiftUI Button below still receives normal
// taps untouched.

/// Reference box for a closure stored in an NSMenuItem's
/// `representedObject`.
///
/// BUGFIX: previously the closure was stored as a bare `() -> Void`
/// (`typealias MenuAction`). `representedObject` is `Any?` bridged to
/// the Objective-C `id` runtime, and a bare Swift function value does
/// NOT round-trip through that bridge — reading it back with
/// `as? () -> Void` returned `nil`, so every event context-menu item
/// silently did nothing. Wrapping the closure in an `NSObject`
/// subclass stores a real Objective-C object, which round-trips
/// reliably and fires the action.
final class MenuActionBox: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    /// The menu item's `action`. Unambiguous `@objc` selector, and the
    /// box is its OWN target — so there's no shared receiver and no
    /// `representedObject`-bridging round-trip to fail. (The item also
    /// keeps a STRONG ref to the box via `representedObject` because
    /// `NSMenuItem.target` is `weak`.)
    @objc func invoke() { run() }
}

struct EventRightClickCatcher: NSViewRepresentable {
    let menuBuilder: () -> NSMenu

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.menuBuilder = menuBuilder
        return v
    }
    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.menuBuilder = menuBuilder
    }

    final class CatcherView: NSView {
        var menuBuilder: () -> NSMenu = { NSMenu() }

        /// Be click-through for LEFT mouse events (so the
        /// SwiftUI Button underneath receives taps normally),
        /// but opaque for right-clicks so they hit this view
        /// and `rightMouseDown(with:)` fires instead of
        /// bubbling up to the host List. We can read the
        /// currently-pressed buttons from `NSEvent`; bit 1
        /// (value 2) is the secondary mouse button.
        override func hitTest(_ point: NSPoint) -> NSView? {
            if NSEvent.pressedMouseButtons & 2 == 2 {
                return self
            }
            return nil
        }

        override func rightMouseDown(with event: NSEvent) {
            let menu = menuBuilder()
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}
