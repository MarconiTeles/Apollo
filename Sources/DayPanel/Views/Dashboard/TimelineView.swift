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

    @State private var scrollLockUntil:    Date = .distantPast
    @State private var suppressAutoScroll: Bool = false
    @State private var didInitialScroll:   Bool = false
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

    /// Where today lands in the visible scroll area on app
    /// launch and when the user taps "Hoje" — vertically centred
    /// then nudged 30% up (so y = 0.5 − 0.3 = 0.2). Past events
    /// stay just-visible above; upcoming events fill the rest
    /// of the screen.
    private let todayAnchor: UnitPoint = UnitPoint(x: 0.5, y: 0.20)

    var body: some View {
        ScrollViewReader { proxy in
            // ── List, not ScrollView+LazyVStack ──────────────
            //
            // We need a SLIDING WINDOW of mounted rows: at most
            // ~25 day-sections in memory at any time, with
            // rows recycling as the user scrolls. `LazyVStack`
            // only DEFERS the initial mount — once a row has
            // appeared, it stays in the SwiftUI hierarchy and
            // its layers stay on the GPU. With a 61-day range
            // (30 back + 30 forward) and busy days carrying 4-
            // 6 event cards each, that meant the GPU was
            // accumulating well over 100 rendered cell layers
            // by the time the user scrolled the full timeline.
            //
            // SwiftUI `List` is backed by `NSTableView` on
            // macOS, which has built-in row recycling: it
            // mounts rows just-in-time as they enter the
            // viewport (plus a small buffer above and below)
            // and tears them down — releasing their layers —
            // when they scroll past. The reuse pool stays
            // bounded regardless of total row count, so
            // memory + GPU stay flat as the user scrolls.
            //
            // To preserve the existing visual + behaviour:
            //   • `.listStyle(.plain)` strips the default
            //     macOS sidebar styling.
            //   • `.scrollContentBackground(.hidden)` lets the
            //     window background show through (matches
            //     ScrollView behaviour — the bottom-edge fade
            //     overlay only works against the canvas).
            //   • `.listRowBackground(.clear)` /
            //     `.listRowSeparator(.hidden)` /
            //     `.listRowInsets(...)` per row reproduce the
            //     LazyVStack's spacing + horizontal padding.
            //   • `.contentMargins(.top: 24, .bottom: 60)`
            //     replaces the LazyVStack's top/bottom padding
            //     and applies them inside the scroll content
            //     so they participate in the scroll area
            //     (rather than capping the list at the edges).
            List {
                ForEach(dates, id: \.self) { date in
                    let dayStart = Calendar.current.startOfDay(for: date)
                    AgendaDaySection(
                        date: date,
                        events: appState.mergedEventsByDay[dayStart] ?? [],
                        appState: appState
                    )
                    .equatable()
                    .id(date)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    // Left gutter between the window edge and the
                    // events list (17 → 26, +50%). Inter-day gap is
                    // the day row's own `marginBottom: 22`.
                    .listRowInsets(EdgeInsets(top: 0, leading: 26,
                                              bottom: 0, trailing: 32))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Match the previous `.padding(.top, 24)` /
            // `.padding(.bottom, 60)`. `contentMargins` adds
            // the space INSIDE the scroll area, so it scrolls
            // with the content (the empty space above the
            // first row scrolls upward and out of view, just
            // like padding inside the LazyVStack).
            .contentMargins(.top, 28, for: .scrollContent)
            .contentMargins(.bottom, 60, for: .scrollContent)
            // NSScrollView introspect — listens to the
            // underlying NSClipView's `boundsDidChange`
            // notification to read the scroll offset
            // directly. Replaces a GeometryReader +
            // PreferenceKey pair that was bouncing the
            // scroll offset up through SwiftUI's preference
            // machinery on every scroll tick.
            .background(
                ScrollOffsetIntrospect { offset in
                    // `offset` is `clipView.documentVisibleRect.minY`,
                    // i.e. how far down the user has scrolled.
                    guard Date() > scrollLockUntil else { return }
                    let approxIndex = Int(((offset - 24) / sectionEstimate).rounded(.down))
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
                // App opens at the same position as clicking "Hoje" —
                // today vertically positioned slightly above centre.
                scrollToDay(today, proxy: proxy, animate: false, anchor: todayAnchor)
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
                scrollToDay(today, proxy: proxy, animate: true, anchor: todayAnchor)
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
                // "Hoje" puts today at `todayAnchor` (vertically centred,
                // shifted 30% up) so the user sees what's just before AND
                // just after right now.
                scrollToDay(today, proxy: proxy, animate: true, anchor: todayAnchor)
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
                guard !scrolling, let date = pendingSelectedDate else { return }
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
        let action: () -> Void = {
            proxy.scrollTo(dayStart, anchor: anchor)
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
                    context.coordinator.attach(to: scroll, callback: onChange)
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

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func attach(to scrollView: NSScrollView, callback: @escaping (CGFloat) -> Void) {
            self.callback = callback
            let clip = scrollView.contentView
            self.clipView = clip
            clip.postsBoundsChangedNotifications = true
            self.observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clip,
                queue: .main
            ) { [weak self] _ in
                guard let clip = self?.clipView else { return }
                self?.callback?(clip.documentVisibleRect.minY)
            }
        }
    }
}

// MARK: - One day in agenda layout

private struct AgendaDaySection: View, Equatable {
    let date: Date
    /// Pre-merged & pre-sorted events for this day, supplied by
    /// the parent `TimelineView`. Previously the section pulled
    /// the array from `@EnvironmentObject AppState` via a
    /// computed `mergedEventsByDay[dayStart]` lookup — but that
    /// observer registration meant EVERY @Published mutation in
    /// AppState (sync ticks, attachment hydration, notification
    /// arrivals, expandedTaskId, etc.) re-ran every visible
    /// section's body, regardless of whether the events for
    /// that day actually changed.
    ///
    /// Passing `events` as a plain prop + holding `appState` as
    /// a `let` reference lets us mark the view `Equatable` and
    /// short-circuit re-renders when neither the date nor the
    /// events for it changed. AppState lookup is uncached but
    /// non-reactive — same pattern `TaskRowView` uses.
    let events: [CalendarEvent]
    /// Plain reference (not `@EnvironmentObject`) — used only
    /// inside the click handler to write `detailEvent` /
    /// `detailEventOrigin`. Reads of `appState.<property>` see
    /// live values; the section just doesn't re-render on
    /// unrelated `@Published` changes.
    let appState: AppState

    /// Equatable: `date` is value-stable, `events` compares
    /// element-wise (CalendarEvent is Equatable). `appState`
    /// is a stable singleton reference and never affects the
    /// diff. Combined with `.equatable()` at the call site,
    /// the section body skips re-evaluation when AppState
    /// mutates something irrelevant to this day.
    static func == (lhs: AgendaDaySection, rhs: AgendaDaySection) -> Bool {
        lhs.date == rhs.date && lhs.events == rhs.events
    }

    private var isToday: Bool { Calendar.current.isDateInToday(date) }

    /// `EditorialMainV2.EditorialDayRow`: past days dim to 0.55.
    private var isPast: Bool {
        Calendar.current.startOfDay(for: date)
            < Calendar.current.startOfDay(for: Date())
    }

    var body: some View {
        // Date column + gap trimmed from the prototype's `72px`/
        // gap-24; the day-number→time gap is now 17 (11 → 17,
        // +50%) and the column 48pt.
        HStack(alignment: .top, spacing: 17) {
            dateColumn

            VStack(spacing: 0) {
                if events.isEmpty {
                    Text("— Sem compromissos")
                        .font(Editorial.serif(13.5).italic())
                        .foregroundStyle(Editorial.inkMute)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 10)
                } else {
                    // Sequential vertical stack — events sorted
                    // by startDate (already sorted upstream by
                    // `events` accessor). Earlier experiment
                    // with multi-column overlap clustering via
                    // an inline GeometryReader broke layout
                    // inside the LazyVStack scroll context
                    // (estimated stack heights drifted from
                    // actual pill heights, producing overlaps
                    // and gaps). Reverted to the predictable
                    // single-column layout; multi-column would
                    // need a custom `Layout` protocol impl,
                    // not an inline GR.
                    ForEach(events) { event in
                        AgendaEventCard(
                            event:       event,
                            onTap:       handleTap,
                            onConvert:   { appState.pendingConversion = $0 },
                            onCopyLink:  { ev in
                                let url = ev.meetingURL?.absoluteString
                                    ?? ev.location ?? ""
                                guard !url.isEmpty else { return }
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(url, forType: .string)
                                appState.notify(.success,
                                                title: "Link copiado",
                                                message: url)
                            },
                            onDelete:    { ev in
                                Task { await appState.deleteEvent(ev) }
                            })
                            .equatable()
                            // Smooth fade-in when an overlay
                            // calendar adds a new event to the
                            // day, or fade-out when removed.
                            // Plain `.opacity` (no scale/move)
                            // because spatial transitions can
                            // get re-fired by SwiftUI during
                            // window resize, which produced
                            // visible "rubber-banding" of the
                            // pills as the column width
                            // changed.
                            .transition(.opacity)
                    }
                }
            }
            // Removed the spring `.animation(value: events.map(\.id))`
            // that was here — `events.map(\.id)` allocates a fresh
            // `[String]` on every body re-eval, and during a resize
            // the body re-runs many times per second. Although the
            // arrays compare equal across renders for stable data,
            // SwiftUI's animation pipeline still occasionally
            // interpolated between them, producing the visible
            // graphical jitter during window resize. The
            // `.transition(.opacity)` per card is enough to handle
            // genuine list mutations (overlay add/remove, edits)
            // without dragging in geometry-driven re-layouts.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // macOS `List` rows hug their content — without this the
        // day row never stretches to the column width, so the
        // event title's `1fr` collapsed and truncated to a few
        // characters with dead space after it. Force the row to
        // fill the full column so the title uses all the space
        // (prototype grid `72px 1fr`).
        .frame(maxWidth: .infinity, alignment: .leading)
        // Prototype: each day row has `marginBottom: 22` and
        // past days fade to 0.55.
        .opacity(isPast ? 0.55 : 1)
        .padding(.bottom, 22)
    }

    private var dateColumn: some View {
        // Editorial: small-caps weekday, an outsized serif
        // numeral, and — for today — a cinnabar underline plus
        // an italic "↳ hoje" cue. No filled accent disc.
        VStack(alignment: .leading, spacing: 4) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)
                .locale(Locale(identifier: "pt_BR")))
                .uppercased()
                .replacingOccurrences(of: ".", with: ""))
                .font(Editorial.sans(10.5, .semibold))
                .tracking(1.2)
                .foregroundStyle(isToday ? Editorial.accent : Editorial.inkMute)

            Text(date.formatted(.dateTime.day()))
                .font(Editorial.serif(38))
                .foregroundStyle(Editorial.ink)
                .tracking(-1.4)
                .monospacedDigit()
                // Prototype `lineHeight: 0.95` — clip the serif's
                // natural leading so the numeral doesn't inflate
                // the row's height.
                .padding(.vertical, -4)
                .overlay(alignment: .bottom) {
                    if isToday {
                        Rectangle()
                            .fill(Editorial.accent)
                            .frame(height: 2)
                            .offset(y: 6)
                    }
                }

            if isToday {
                Text("↳ hoje")
                    .font(Editorial.serif(11).italic())
                    .foregroundStyle(Editorial.accent)
                    .padding(.top, 2)
            }
        }
        // 72 → 48: just wide enough for the serif day numeral +
        // weekday, killing the unused trailing slack in the
        // column (kept fixed so the time column stays aligned
        // across single- and two-digit days).
        .frame(width: 48, alignment: .leading)
        .padding(.top, 6)
    }

    /// Click handler for `AgendaEventCard`. Lives on the
    /// section (which already observes `appState`) so the card
    /// itself can stay free of `@EnvironmentObject` and the
    /// re-render cascade that comes with it. Section instances
    /// are themselves cheap (date-only fields), so the
    /// closure capture cost is negligible.
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
    /// `AgendaDaySection` wires the click action.
    let onTap: (CalendarEvent) -> Void
    /// Right-click context-menu actions. Closures keep the card
    /// free of `@EnvironmentObject AppState`, preserving the
    /// scroll-time Equatable short-circuit; the parent
    /// `AgendaDaySection` wires them to AppState.
    var onConvert: ((CalendarEvent) -> Void)? = nil
    var onCopyLink: ((CalendarEvent) -> Void)? = nil
    var onDelete: ((CalendarEvent) -> Void)? = nil

    /// Editorial hover wash (not compared by `==` — @State is
    /// intentionally excluded from the Equatable short-circuit).
    @State private var hover = false

    /// PERF: Equatable short-circuits SwiftUI body re-evaluation
    /// when the event hasn't changed. With ~15-20 cards visible
    /// during scroll and the parent `appState` driving many
    /// unrelated `@Published` updates per second, this single
    /// conformance cuts the bulk of redundant scroll-time
    /// renders. We compare the fields that actually drive the
    /// card's visuals — id, title, time range, color, and the
    /// current user's RSVP status — instead of the whole event
    /// (recurring rules, raw EKEvent ref, etc.) so unrelated
    /// metadata changes don't invalidate the cache.
    static func == (lhs: AgendaEventCard, rhs: AgendaEventCard) -> Bool {
        // CRITICAL: the attendee status comparison must use the
        // SAME selector the render uses (`first non-organizer`),
        // not `first` outright. When the organizer is the first
        // attendee in the list (the usual case for invites),
        // `first?.status` is the organizer's accepted status,
        // which never changes when the LOCAL user RSVPs. The
        // comparison would then return true even though the
        // user's own attendee just flipped to `.accepted` — so
        // `.equatable()` short-circuited the re-render and the
        // pill stayed in its old visual state until app restart.
        let lhsMine = lhs.event.attendees.first(where: { !$0.isOrganizer })?.status
        let rhsMine = rhs.event.attendees.first(where: { !$0.isOrganizer })?.status
        return lhs.event.id == rhs.event.id
            && lhs.event.title  == rhs.event.title
            && lhs.event.startDate == rhs.event.startDate
            && lhs.event.endDate   == rhs.event.endDate
            && lhs.event.colorHex  == rhs.event.colorHex
            && lhs.event.location  == rhs.event.location
            && lhs.event.attendees.count == rhs.event.attendees.count
            && lhsMine == rhsMine
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
        // EXPERIMENT (REVERTED): tried replacing this view
        // tree with a single `Canvas { context, size in … }`
        // that drew background, border, title, subtitle, and
        // avatar via `GraphicsContext` primitives. Hypothesis
        // was that a single Canvas would dodge SwiftUI's
        // per-child view diff overhead.
        //
        // Result was a clear REGRESSION (Animation Hitches
        // trace):
        //   • drawingGroup version: 20.6ms · 70% @ 60Hz
        //   • Canvas version:       27.0ms · 56% @ 60Hz
        //
        // Canvas redraws from scratch every render: its
        // closure has to call `context.resolve(Text…)` and
        // `text.measure(in:)` per card per frame, which
        // turns out to be more expensive than letting SwiftUI
        // diff a tree that's already short-circuited by
        // `.equatable()`. `.drawingGroup()` wins by caching
        // the Metal texture between renders — when the
        // event's fields don't change (which is true for
        // the entire scroll), the cached texture is just
        // re-blitted instead of re-rasterised. Reverted.
        // Exact prototype `PEventLine`:
        //   grid 88 | 1fr | auto · gap 16 · baseline ·
        //   padding 10px 8px · margin 0 -8px · borderRadius 4 ·
        //   borderTop 1px ruleSoft · hover → bg E.card.
        // The 88pt time column WRAPS "HH:MM → HH:MM" to two lines
        // ("09:30 →" / "10:00"). The title is serif 16/500 and
        // WRAPS naturally (never tail-truncated); the location
        // rides inline as an italic Caption and wraps onto its
        // own line. The avatar is a SOLID colour disc.
        Button {
            onTap(event)
        } label: {
            // spacing 0 + explicit leading paddings so the
            // time→title gap (2) and title→avatar gap (16) are
            // tuned independently — the prototype's uniform 16
            // left too much air between the time and the title.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                // Times are ALWAYS stacked one above the other,
                // matching the prototype's `PEventLine`. The old
                // single `Text("HH:MM → HH:MM")` relied on the
                // 88pt column being narrow enough to force a
                // natural wrap — but 13 chars at sans 12 fit on a
                // single line, so the wrap silently never fired.
                // An explicit VStack guarantees the layout
                // regardless of column width.
                Group {
                    if event.isAllDay {
                        Text("Dia inteiro")
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(timeStart) →")
                            Text(timeEnd)
                        }
                    }
                }
                .font(Editorial.sans(12, .medium))
                .monospacedDigit()
                .tracking(0.3)
                .foregroundStyle(isDeclined ? Editorial.inkMute
                                            : Editorial.inkSoft)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                // Trimmed 10pt — was 88, now 78. Pulls the event
                // title closer to the time column so the meta
                // ("09:30 →") and the title read as a single
                // unit instead of being separated by a wide gutter.
                .frame(width: 78, alignment: .leading)

                titleParagraph
                    .multilineTextAlignment(.leading)
                    // An event is at most 2 lines: the title wraps
                    // once, then tail-truncates (the inline italic
                    // location rides along and truncates with it).
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.leading, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                avatarDisc
                    .padding(.leading, 16)
                    .alignmentGuide(.firstTextBaseline) {
                        $0[VerticalAlignment.center] + 5
                    }
            }
            .opacity(isDeclined ? 0.45 : 1)
            .padding(.vertical, 10)
            // Fill the events column so the title (1fr) uses ALL
            // remaining width — no dead gap before the avatar.
            .frame(maxWidth: .infinity, alignment: .leading)
            // Prototype `padding:10px 8px; margin:0 -8px` — the
            // hover wash + top rule bleed 8pt into the gutter on
            // each side while the content stays at the column
            // edge (background/overlay extended, not the content).
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(hover ? Editorial.card : Color.clear)
                    .padding(.horizontal, -8)
            )
            .overlay(alignment: .top) {
                Rectangle().fill(Editorial.ruleSoft).frame(height: 1)
                    .padding(.horizontal, -8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        // Scroll-aware hover — drops the halo on/off updates
        // while a live NSScrollView scroll is in progress and
        // force-resets `hover` the instant a scroll starts.
        // The shared `ScrollStateObserver` already listens to
        // every NSScrollView in the app via NotificationCenter,
        // so the timeline gets covered automatically.
        .scrollAwareOnHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { hover = hovering }
        }
        // Right-click context menu rendered via a native NSMenu
        // overlay rather than SwiftUI `.contextMenu`. The host
        // List would otherwise show its row-selection highlight
        // (blue rectangle around the WHOLE day section) on
        // right-click; the AppKit overlay intercepts the right-
        // click before the List sees it, so no row selection
        // is triggered. Left-clicks pass through untouched (the
        // overlay's `hitTest` returns nil unless a right button
        // is currently pressed).
        .background(
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

        let openItem = NSMenuItem(title: "Abrir evento",
                                  action: nil, keyEquivalent: "")
        openItem.image = NSImage(systemSymbolName: "doc.text.magnifyingglass",
                                 accessibilityDescription: nil)
        openItem.target = MenuActionTarget.shared
        openItem.action = #selector(MenuActionTarget.perform(_:))
        openItem.representedObject = { [event] in onTap(event) } as MenuAction
        m.addItem(openItem)

        let hasLink = event.meetingURL != nil
            || !(event.location ?? "").isEmpty
        if let onCopyLink, hasLink {
            let copy = NSMenuItem(title: "Copiar link",
                                  action: nil, keyEquivalent: "")
            copy.image = NSImage(systemSymbolName: "link",
                                 accessibilityDescription: nil)
            copy.target = MenuActionTarget.shared
            copy.action = #selector(MenuActionTarget.perform(_:))
            copy.representedObject = { [event] in onCopyLink(event) } as MenuAction
            m.addItem(copy)
        }

        m.addItem(.separator())

        if let onConvert {
            let conv = NSMenuItem(title: "Transformar em tarefa",
                                  action: nil, keyEquivalent: "")
            conv.image = NSImage(systemSymbolName: "arrow.2.squarepath",
                                 accessibilityDescription: nil)
            conv.target = MenuActionTarget.shared
            conv.action = #selector(MenuActionTarget.perform(_:))
            conv.representedObject = { [event] in onConvert(event) } as MenuAction
            m.addItem(conv)
        }

        if let onDelete {
            m.addItem(.separator())
            let del = NSMenuItem(title: "Excluir evento",
                                 action: nil, keyEquivalent: "")
            del.image = NSImage(systemSymbolName: "trash",
                                accessibilityDescription: nil)
            del.target = MenuActionTarget.shared
            del.action = #selector(MenuActionTarget.perform(_:))
            del.representedObject = { [event] in onDelete(event) } as MenuAction
            m.addItem(del)
        }
        return m
    }

    /// Time pieces (the column wraps the two on its own).
    private var timeStart: String {
        event.isAllDay ? "Dia inteiro"
            : SharedDateFormatters.shortTime24h.string(from: event.startDate)
    }
    private var timeEnd: String {
        event.isAllDay ? ""
            : SharedDateFormatters.shortTime24h.string(from: event.endDate)
    }

    /// Sans title + inline italic "· local", as one wrapping
    /// paragraph. Serif on the home page reads as decorative
    /// when there are dozens of rows; SF Pro keeps the dense
    /// list legible.
    private var titleParagraph: Text {
        var t = Text(event.title)
            .font(Editorial.sans(14, .semibold))
            .foregroundColor(Editorial.ink)
            .tracking(-0.1)
        if isDeclined {
            t = t.strikethrough(true, color: Editorial.inkMute)
        }
        if let loc = event.location, !loc.isEmpty {
            t = t + Text("  ·  \(loc)")
                .font(Editorial.sans(12))
                .foregroundColor(Editorial.inkSoft)
        }
        return t
    }

    /// Colour disc with a letter. Confirmed (RSVP accepted, or
    /// no attendees so nothing to confirm) → SOLID fill, white
    /// letter. Not yet confirmed → HOLLOW: paper fill, a 1.5pt
    /// ring in the colour, the letter in the colour.
    private var avatarDisc: some View {
        let letter: String = {
            if let n = event.attendees.first?.name,
               let c = n.split(separator: " ").first?.first {
                return String(c).uppercased()
            }
            return String(event.title.first ?? "•").uppercased()
        }()
        return Group {
            if isAccepted {
                Circle()
                    .fill(color)
                    .overlay(
                        Text(letter)
                            .font(Editorial.sans(9.5, .semibold))
                            .foregroundStyle(.white)
                    )
            } else {
                Circle()
                    .fill(Editorial.paper)
                    .overlay(Circle().strokeBorder(color, lineWidth: 1.5))
                    .overlay(
                        Text(letter)
                            .font(Editorial.sans(9.5, .semibold))
                            .foregroundStyle(color)
                    )
            }
        }
        .frame(width: 20, height: 20)
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

/// A closure stored in an NSMenuItem's `representedObject`.
/// Retained boxed by reference inside the target's `perform`.
typealias MenuAction = () -> Void

/// Single shared @objc target used as the action receiver for
/// every dynamically-built NSMenuItem. Reads the item's
/// `representedObject` (the closure) and invokes it.
final class MenuActionTarget: NSObject {
    static let shared = MenuActionTarget()
    @objc func perform(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?()
    }
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


