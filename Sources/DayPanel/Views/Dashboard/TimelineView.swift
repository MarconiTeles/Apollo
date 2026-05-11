import SwiftUI
import AppKit

// Agenda-style timeline modeled after Google Calendar's mobile "Agenda"
// view: each day is a row with its weekday/day-number on the left and a
// stacked list of event cards on the right. No hour grid, no positional
// time math — events are listed in chronological order, top-to-bottom.

struct TimelineView: View {
    @EnvironmentObject var appState: AppState

    /// 30 days back, 30 days forward.
    private var dates: [Date] {
        let cal   = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (-30...30).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
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
                    // Vertical insets total to 14pt between
                    // rows (7 + 7), matching LazyVStack's
                    // `spacing: 14`. Horizontal mirrors the
                    // previous `.padding(.horizontal, 14)`.
                    .listRowInsets(EdgeInsets(top: 7, leading: 14,
                                              bottom: 7, trailing: 14))
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
            .contentMargins(.top, 24, for: .scrollContent)
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
            // input read cleanly. Uses
            // `Color(NSColor.windowBackgroundColor)` so the
            // fade adapts to dark/light themes automatically:
            // dark windows fade to dark, light windows fade
            // to light. Multi-stop curve creates a smooth
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
                let bg = Color(NSColor.windowBackgroundColor)
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            dateColumn

            VStack(spacing: 6) {
                if events.isEmpty {
                    Text("Sem compromissos")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
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
                        AgendaEventCard(event: event, onTap: handleTap)
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
        // Today's section gets a bit of breathing room above
        // it so it stands apart from the previous day's
        // entries. Was 35pt; reduced 35% → ~23pt for a
        // tighter visual emphasis.
        .padding(.top, isToday ? 23 : 0)
    }

    private var dateColumn: some View {
        VStack(spacing: 2) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isToday ? Color.accentColor : .secondary)

            ZStack {
                if isToday {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 28, height: 28)
                        .shadow(color: Color.accentColor.opacity(0.35),
                                radius: 4, x: 0, y: 2)
                }
                Text(date.formatted(.dateTime.day()))
                    .font(.system(size: 16, weight: .semibold,
                                  design: .rounded))
                    .foregroundStyle(isToday ? Color.white : .primary)
                    .monospacedDigit()
            }
        }
        .frame(width: 44)
        .padding(.top, 4)
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
        Button {
            onTap(event)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        // .callout (12pt) × 1.15 = 13.8pt —
                        // event titles bumped 15% in lockstep
                        // with the task-list title bump.
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
            // Solid Google-palette fill when accepted;
            // tinted-color fill (not material) when not, so
            // `.drawingGroup()` below can rasterise the
            // tree without losing backdrop-material content.
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
            // PERF: `.drawingGroup()` rasterises the card's
            // visual tree into a Metal-backed texture that
            // gets reused across scroll frames. With
            // `Equatable + .equatable()` short-circuiting
            // body re-eval when the event's fields haven't
            // changed, the cached texture survives the
            // entire scroll session and shadow blur is
            // computed exactly once per card.
            .drawingGroup()
            .shadow(color: isAccepted ? .black.opacity(0.18)
                                      : color.opacity(0.45),
                    radius: 4, x: 0, y: 1)
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
    }

    @ViewBuilder
    private func avatar(for a: CalendarEvent.Attendee) -> some View {
        let initials = a.name
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
        ZStack {
            Circle().fill(Color.accentColor.opacity(isAccepted ? 0.35 : 0.20))
            Text(initials.isEmpty ? "?" : initials)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isAccepted ? Color.white : Color.accentColor)
        }
        .frame(width: 22, height: 22)
        .overlay(Circle().strokeBorder(
            isAccepted ? Color.white.opacity(0.5) : Color.clear,
            lineWidth: 0.5))
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
