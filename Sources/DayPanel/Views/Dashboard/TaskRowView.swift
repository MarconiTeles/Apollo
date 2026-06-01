import SwiftUI

struct TaskRowView: View, Equatable {
    /// AppState held as a plain reference, NOT `@EnvironmentObject`.
    /// `@EnvironmentObject` registers the view as a subscriber to
    /// `AppState.objectWillChange`, so EVERY one of AppState's
    /// 41 `@Published` properties (selectedDate, expandedTaskId,
    /// notification arrivals, sync status, attachment hydration…)
    /// invalidates the row's body — even though most of them have
    /// nothing to do with this row's render. With ~30 visible rows
    /// each individually subscribed, that single line was the
    /// dominant cost on every keystroke and notification poll.
    ///
    /// Holding `appState` as a `let` cuts the subscription. The
    /// row's body only re-evaluates when:
    ///   • the parent re-binds the cell with a new `task` arg
    ///     (NSCollectionListView's equality guard already filters
    ///     this to "tasks actually changed"), or
    ///   • the row's own `@State` changes (hover, completing,
    ///     dragOffset, etc).
    ///
    /// Reads of `appState.<property>` still see live values —
    /// reference-type access is uncached, just non-reactive. For
    /// values that the row CACHES into `@State` (statusDisplayHex,
    /// assigneeFirstName), the `.onChange(of: task.…)` hooks
    /// refresh them when the task itself changes.
    let appState: AppState
    let task: CUTask

    init(task: CUTask, appState: AppState) {
        self.task = task
        self.appState = appState
    }

    /// Equatable conformance — used by `.equatable()` at the
    /// `TaskListView` call site to short-circuit re-renders
    /// when the same task is presented unchanged. Comparing
    /// only `task` is correct because the parent
    /// `pendingTasksCached` array is rebuilt synchronously
    /// when `appState.tasks` mutates: any real change to a
    /// task lands in pendingTasksCached, which feeds a new
    /// `task` value into this view, which then fails the
    /// `==` and re-renders. AppState (the reference) is a
    /// stable singleton — never participates in the diff.
    static func == (lhs: TaskRowView, rhs: TaskRowView) -> Bool {
        lhs.task == rhs.task
    }

    @State private var completing        = false
    @State private var titleDraft        = ""
    @State private var editingTitle      = false      // gates TextField creation
    @State private var showStatusMenu    = false
    @State private var dragOffset:    CGFloat = 0
    @State private var hoveringCheckbox  = false
    /// Row-level hover — drives the editorial background wash
    /// (transparent at rest → `Editorial.card` on hover). Replaced
    /// the old status-tinted glass card + glow feedback.
    @State private var rowHover          = false
    /// Cached `task.statusDisplayHex` value. The computed
    /// property allocates a fresh `CUStatus` each call, and the
    /// row reads it 3× per render (drop shadow + status pill
    /// fill + hover-DONE pill colour). With 50 visible rows
    /// that's ~150 `CUStatus` allocations per re-render trigger.
    /// Caching here costs one `@State` slot per row but cuts
    /// every read after the first to a `String` member access.
    /// Refreshed via `.onAppear` and `.onChange(of:
    /// task.statusDisplayHex)`.
    @State private var cachedStatusHex: String = "#87909E"
    /// Cached version of the assignee first-name parse. The
    /// raw computation splits on @, space, and dot, calls
    /// dropFirst/lowercased — cheap on its own, but the body
    /// re-evaluates on every parent `@Published` mutation, so
    /// 50 visible rows × N substring allocations per scroll
    /// frame compounded into measurable scroll-time CPU.
    /// Refreshed via `.onAppear` and `.onChange(of:
    /// task.assignees)`.
    @State private var cachedAssigneeFirstName: String? = nil
    @FocusState private var titleFocused: Bool

    /// The status to apply when the user clicks the DONE pill. Looked up
    /// per task's *current* status, so each category can have its own
    /// "next stop" (e.g. DOING → REVIEW, REVIEW → COMPLETE). Falls back
    /// to the "__default__" map entry, then to whichever status contains
    /// "review", then nil.
    private var doneTargetStatus: CUStatus? {
        // O(1) lookup against AppState's pre-resolved index.
        // Was an O(n) walk of `availableStatuses` per render —
        // ran once per row per scroll frame. The cached index
        // is rebuilt only when `availableStatuses` or
        // `doneActionByStatus` actually mutate.
        if let direct = appState.doneTargetByStatus[task.status] {
            return direct
        }
        return appState.doneTargetFallback
    }

    /// The DONE pill mirrors the colour of the configured status's filter
    /// pill (so REVIEW → light purple, COMPLETE → green, DOING → orange…).
    /// Falls back to system blue if no target status is resolved.
    private var doneColor: Color {
        if let hex = doneTargetStatus?.displayHex { return Color(hex: hex) }
        return .blue
    }

    /// Read-only accessor for the cached assignee first name.
    /// The body reads `assigneeFirstName` exactly as before;
    /// the actual parse runs once per assignee change via
    /// `recomputeAssigneeFirstName()` below.
    private var assigneeFirstName: String? { cachedAssigneeFirstName }

    /// Computes the human-friendly first token from the
    /// assignee's username/email. ClickUp's
    /// `assignees[].username` can be a real name ("João Silva")
    /// or an email ("joao.silva@minimalclub.com.br"). Split on
    /// both space and "." (and strip any "@…" suffix) to
    /// surface a single capitalised first token.
    private func recomputeAssigneeFirstName() -> String? {
        guard let raw = task.assignees.first?.username,
              !raw.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        let beforeAt = raw.split(separator: "@").first.map(String.init) ?? raw
        let firstToken = beforeAt
            .split(whereSeparator: { $0 == " " || $0 == "." })
            .first
            .map(String.init) ?? beforeAt
        guard let initial = firstToken.first else { return nil }
        return String(initial).uppercased() + firstToken.dropFirst().lowercased()
    }

    // MARK: - Swipe support (universal — Mail-style two-finger trackpad)

    /// Previous status in the workflow — the target a leftward swipe
    /// reverts the task to. Resolved by looking up the current
    /// status's index in `appState.availableStatuses` (which is
    /// ordered by ClickUp's own `orderindex`) and stepping back
    /// one slot. Returns nil for the first status (nothing to
    /// revert to) or when the current status isn't in the list.
    private var previousStatus: CUStatus? {
        let statuses = appState.availableStatuses
        guard let idx = statuses.firstIndex(where: { $0.status == task.status }),
              idx > 0
        else { return nil }
        return statuses[idx - 1]
    }

    /// Animates the row off-screen in `direction` (+1 = right, -1 =
    /// left) and then commits the status mutation. Pushes a
    /// reversible action onto the undo stack so Cmd+Z restores
    /// the previous status. Used by both the swipe gesture (when
    /// the user drags past the commit threshold) and the DONE
    /// pill button — same visual cue in both paths.
    private func commitStatusChange(to target: CUStatus, direction: CGFloat) {
        let originalStatusName = task.status
        let originalTask       = task
        withAnimation(.easeIn(duration: 0.18)) {
            dragOffset = direction * 600
        }
        Task {
            // Wait for the slide-out to almost finish so the row
            // visibly leaves before the data update kicks the
            // collection-view diff animation that closes the gap.
            try? await Task.sleep(nanoseconds: 180_000_000)
            // CRITICAL: reset dragOffset to 0 BEFORE the data
            // update lands. NSCollectionView recycles cells, and
            // a recycled cell carries its old SwiftUI `@State`
            // forward when re-bound (NSHostingView replaces the
            // rootView in place rather than discarding it). If
            // we leave `dragOffset = 600` here, then later — when
            // either Cmd+Z restores this same task or a different
            // task lands in the recycled cell — the new content
            // appears with a +600pt offset, exposing the colored
            // swipe-action background as a stuck purple/green
            // pill in the slot. Resetting now happens in the
            // single frame between "slide-out finished" and "data
            // update removes this row from the list", so the
            // visible jump is at most one frame and the row is
            // about to be unmounted anyway.
            dragOffset = 0
            await appState.updateTaskStatus(task, to: target)
            appState.pushUndo(
                label: "“\(originalTask.title)” → \(originalStatusName.uppercased())"
            ) {
                if let prev = appState.availableStatuses
                    .first(where: { $0.status == originalStatusName }) {
                    await appState.updateTaskStatus(originalTask, to: prev)
                }
            }
        }
    }

    var body: some View {
        ZStack {
            // Behind the card: action background ALWAYS in the view
            // tree only when a swipe is in progress. The `if
            // dragOffset != 0` removes the two action panels
            // (each carrying a full-area HStack + frame +
            // background fill) in the COMMON CASE where no
            // gesture is active — saves ~6 layers per cell at
            // rest, multiplied by all visible rows.
            //
            // Earlier this was always-rendered to avoid the
            // "abrupt fade" when the spring-back set dragOffset
            // = 0 and SwiftUI removed the conditional view in
            // the SAME frame the offset started its animation.
            // The new design fixes that two ways: `.transition(.opacity)`
            // gives SwiftUI an explicit removal animation to
            // run, AND every state-write that flips dragOffset
            // back to 0 happens inside a `withAnimation(...)`
            // block (see swipe `onEnd` — both the spring path
            // and the commit path either keep the panel
            // rendered for the duration of their slide-out or
            // arrive at 0 in a context where instant removal
            // is acceptable because the row itself is about to
            // unmount).
            if dragOffset != 0 {
                swipeActionBackground
                    .transition(.opacity)
            }

            // The actual card — slides on the X axis during a
            // swipe gesture. Inline-expand was removed: clicking
            // the row now opens the detail popup directly. The
            // chevron button is gone too.
            VStack(spacing: 0) {
                compactRow
            }
            // Pin the card to the panel's proposed width. Without
            // this the VStack sizes to its widest child, and when
            // the DONE checkbox grows from a 14pt icon into the
            // ~60pt "REVIEW" pill the inner `.fixedSize(horizontal:
            // true)` on the button forces compactRow to grow with
            // it — making the entire card stretch horizontally on
            // hover. Forcing `maxWidth: .infinity` here means any
            // expansion must instead redistribute space *within*
            // the card via the inner Spacer, leaving the card edges
            // exactly where they were.
            .frame(maxWidth: .infinity, alignment: .leading)
            // Solid OPAQUE fill — `.opacity(0.62)` triggered an
            // alpha-blend pass per row per frame; flat opaque
            // colour skips that entirely. With per-row shadow
            // removed (above), the row becomes a single fully-
            // opaque rectangle and Core Animation can use the
            // fast-path opaque texture upload — the GPU just
            // copies pixels instead of blending them.
            //
            // Visual change: ~3% lighter than before (the prior
            // 0.62 alpha let the panel background show through
            // very faintly). Imperceptible in practice.
            // PERF: status-coloured CONTOUR (strokeBorder)
            // replaced with status-coloured FILL TINT layered
            // on the background. Stroke is materially more
            // expensive than fill: the renderer has to anti-
            // alias the curved path edge per pixel along the
            // 18pt corner radius × 4 corners × every visible
            // row × every scroll frame. A second filled
            // RoundedRectangle at low opacity skips the
            // path-edge AA entirely — the GPU just composites
            // a tinted rect over the base, which is the same
            // operation Core Animation already does for any
            // background blend.
            //
            // Visual change: lost the crisp 0.7pt outline
            // around each row, gained a soft accent wash
            // tinting the whole pill in the status colour.
            // The status badge inside still carries the full-
            // saturation colour so identity reads at a glance.
            // PERF: collapsed `ZStack { 2× RoundedRectangle.fill }`
            // into a single fill with a pre-blended colour
            // (computed once per `(hex, scheme)` pair, cached).
            // Saves one CALayer per cell × 30 visible cells = 30
            // fewer layers each compositor pass, and one fewer
            // `.fill` evaluation per body re-render. Visual
            // result is identical: the dark card stays neutral
            // (windowBg + 4% white) and the light card carries
            // the same status wash (controlBg + 13% saturation-
            // bumped fillTint).
            // Editorial: no status-tinted glass card. The row is
            // a paper line — transparent at rest, a soft cream
            // wash on hover, separated by a hairline rule. The
            // AppKit cell port (TaskRowCellView) paints a slim
            // 4pt category-colour stripe on the leading edge for
            // the dashboard's NSCollectionListView path; this
            // SwiftUI fallback keeps the editorial baseline.
            .background(rowHover ? Editorial.card : Color.clear)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Editorial.rule).frame(height: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            // Hover lift: a thin drop shadow tinted with the task's status
            // accent (applied AFTER the clip so the halo isn't cropped).
            .shadow(
                color: rowHover ? Color(hex: cachedStatusHex).opacity(0.55) : .clear,
                radius: rowHover ? 3 : 0, x: 0, y: 1
            )
            .animation(.easeInOut(duration: 0.18), value: rowHover)
            // PERF: outer `.clipShape(RoundedRectangle)` removed.
            // It forced an offscreen mask pass per cell (one of
            // CoreAnimation's more expensive ops) — and was
            // largely REDUNDANT here:
            //   • The background fill paints rounded already
            //     (the fill shape itself does the rounding).
            //   • `swipeActionBackground` carries its own
            //     `.clipShape(RoundedRectangle)` so the action
            //     panels stay rounded when revealed.
            //   • `interactivePillFeedback`'s click-pulse uses
            //     its own `.mask(RoundedRectangle)` to keep the
            //     ripple inside the silhouette.
            //   • compactRow's content (text, badges, icons)
            //     stays well inside the corner radius via its
            //     14pt leading padding — nothing visually
            //     reaches the corners that would need clipping.
            // Net result: -1 offscreen pass per cell × every
            // scroll frame.
            // PERF: tried `.drawingGroup()` here too —
            // regressed scroll mean to 34ms (vs 20ms without).
            // Why TaskRowView is different from
            // AgendaEventCard: 30+ rows × Metal-texture
            // allocation, plus hover-state changes (DONE pill
            // appearance, status pill dropdown, swipe gesture)
            // invalidate each row's cached texture frequently.
            // For TaskRowView, traditional layered rendering
            // beats Metal rasterisation. Leaving the row
            // tree without an explicit compositingGroup or
            // drawingGroup — the per-row shadow has already
            // been removed at rest, so there's no per-card
            // blur work to flatten anyway.
            // `compositingGroup()` flattens every sub-element of
            // the row into a SINGLE offscreen buffer BEFORE the
            // shadow is rendered. Without it, SwiftUI runs the
            // shadow blur once per child layer that has its own
            // backing — so a row with checkbox + title +
            // status-pill + avatar + due-date badge + chevron
            // would request 6+ shadow blur passes per frame.
            // After compositingGroup, the whole row is one
            // texture and the shadow blur is computed exactly
            // once.
            //
            // Combined with cutting `radius: 8` → `radius: 4`,
            // the GPU work for shadows on a 30-row list drops
            // by an order of magnitude. A 4pt blur is still
            // visually a soft halo at this size; the difference
            // from radius-8 is barely perceptible against the
            // shadow's own opacity falloff but the cost
            // delta is significant (Gaussian blur is O(radius²)
            // in samples per pixel).
            // PERF: per-row drop-shadow REMOVED at rest. Even
            // with `compositingGroup()` flattening the row to
            // a single offscreen buffer, a Gaussian blur (the
            // shadow) on N visible rows is one of the most
            // expensive things in the SwiftUI render path —
            // each row's buffer needs a separate texture +
            // separate blur pass + separate composite, and
            // the cost scales linearly with rows visible.
            // For a 30-row scroll viewport, that's a 30×
            // multiplier on every recomposite (any hover,
            // any small layer change, every scroll frame).
            //
            // The status-coloured glow that used to live here
            // is reproduced on hover/active by the
            // `interactivePillFeedback` modifier below — so
            // the row's identity is preserved when the user
            // is actually engaging with it, while the resting
            // state pays no GPU cost. This single change
            // unlocks 120Hz scroll on ProMotion displays.
            // Hover/click feedback — boosts the existing
            // status-coloured halo and adds a brief light flash
            // on click. `hoverScale: 1.012` keeps the lift
            // subtle so a row hover doesn't visually shove its
            // neighbours in the tight stack.
            //
            //  • `pressScales: false` removes the click dip-
            //    scale; the row keeps its size on tap and only
            //    the coloured light pulses.
            //  • `glow: true` and `hoverScale: 1.012`
            //    SUPPRESSED to 0 / 1.0 when the cursor is on
            //    the DONE checkbox. With the row's structural
            //    width now locked (title slides via
            //    `.offset(x:)`, not `.padding`, so the row's
            //    intrinsic width is invariant on hover), the
            //    colored halo + 1.012 lift can come back for
            //    general row hover without re-creating the
            //    "pill is growing" regression. But the user
            //    still wants ONLY the DONE pill to animate
            //    when the cursor is over the DONE checkbox —
            //    so over that specific area we strip both
            //    the glow halo and the scale lift, leaving
            //    just the slot reveal + label slide as the
            //    visible feedback. The pill click pulse
            //    (`pulseFromClick: true`) is unconditional.
            .offset(x: dragOffset)
            // Editorial replaces the status-glow/scale feedback
            // with a calm cream hover wash. Scroll-aware like the
            // checkbox handler so a cursor sweeping rows during a
            // scroll doesn't thrash the state.
            .onHover { hovering in
                if ScrollStateObserver.shared.isScrolling {
                    if rowHover { rowHover = false }
                    return
                }
                rowHover = hovering
            }
        }
        // Mail-style two-finger trackpad swipe wraps the entire
        // ZStack so scroll wheel events are reliably delivered to
        // OUR NSView before bubbling up to the enclosing scroll
        // view. Putting this as a `.background(...)` (sibling)
        // never received events because AppKit routes scrollWheel
        // up via the responder chain — the SwiftUI hosting view
        // in front consumed the event before any sibling could
        // see it. Wrapping makes us the parent on the chain.
        //
        // `dragOffset` updates instantly with each delta (no
        // explicit animation — the gesture should feel "stuck
        // to the fingers"). On release, a spring snaps the row
        // back to zero AND, if the final translation crossed
        // ±80pt, fires the corresponding status mutation.
        .twoFingerSwipe(
            onProgress: { delta in
                // No clamp during the gesture — the row tracks the
                // fingers all the way to either edge. Pulling
                // further past the commit threshold reads as
                // intent ("yes, I really want this action") and
                // makes the snap-out at release feel earned.
                dragOffset = delta
            },
            onEnd: { final in
                // Commit threshold: the user must drag the card
                // almost completely off the visible row strip
                // (≈220pt) before the action fires. Anything
                // short of that springs back as a "peek".
                let commitThreshold: CGFloat = 220
                if final > commitThreshold, let target = doneTargetStatus {
                    commitStatusChange(to: target, direction: 1)
                } else if final < -commitThreshold, let prev = previousStatus {
                    commitStatusChange(to: prev, direction: -1)
                } else {
                    // Spring-back tuned to match Mail's feel:
                    // ~0.45s response with a 0.72 damping factor
                    // gives a slightly elastic settle (not over-
                    // bouncy, but you can see the row "land"),
                    // matching the rubbery undamped quality of
                    // Mail's row-action spring. Faster damping
                    // (>0.85) read as too snappy/digital; slower
                    // response (>0.55) read as sluggish.
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) {
                        dragOffset = 0
                    }
                }
            }
        )
        .onAppear {
            // The `expandedTaskId → openDetail` routing used to live
            // here as a per-row `.onChange(of: appState.expandedTaskId)`,
            // which forced every visible row to subscribe to AppState.
            // Moved up to TaskListView (single global handler) so this
            // row stays free of `@Published` reactivity.
            cachedStatusHex = task.statusDisplayHex
            cachedAssigneeFirstName = recomputeAssigneeFirstName()
        }
        .onChange(of: task.statusDisplayHex) { _, new in
            cachedStatusHex = new
        }
        .onChange(of: task.assignees) { _, _ in
            cachedAssigneeFirstName = recomputeAssigneeFirstName()
        }
        // Belt-and-suspenders against the recycled-cell bug: if
        // NSCollectionView re-binds this hosting view to a
        // DIFFERENT task while transient swipe state lingers
        // (dragOffset, completing flag), reset that state so the
        // new task doesn't render with the previous task's
        // mid-swipe offset.
        .onChange(of: task.id) { _, _ in
            dragOffset = 0
            completing = false
        }
        // Right-click → full task context menu. Same actions
        // surfaced by the AppKit `TaskRowCellItem` (via
        // `menu(for:)`) and the popup `SubtaskRow`. Building
        // from the shared `TaskContextMenu.actions` spec
        // keeps the three surfaces in lockstep.
        .taskContextMenu(task: task, appState: appState)
    }

    // MARK: - Swipe action background

    private var swipeActionBackground: some View {
        // Opacity is the animatable handle. By keeping both panels
        // in the view tree at all times and using opacity = 0 / 1
        // tied to dragOffset, SwiftUI's animation system can
        // interpolate the panels' visibility together with the
        // row's `.offset(x: dragOffset)` during a spring-back.
        // Earlier the panels were conditionally inserted via
        // `if dragOffset > 0 / < 0`; conditionals are NOT
        // animatable, so they snapped on/off at the start of the
        // animation while the row continued sliding smoothly.
        let rightProgress = max(0, min(1, dragOffset / 100))
        let leftProgress  = max(0, min(1, -dragOffset / 100))
        return ZStack {
            if let target = doneTargetStatus {
                // Right swipe → DONE (next status). Exposed on the
                // LEFT as the row moves right. Coloured with the
                // target status's accent so the user sees what
                // they're advancing into.
                HStack(spacing: 0) {
                    actionLabel(
                        icon:  "checkmark.circle.fill",
                        text:  target.status.uppercased(),
                        color: .white
                    )
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(statusHex: target.displayHex).opacity(0.92))
                .opacity(rightProgress)
            }
            if let prev = previousStatus {
                // Left swipe → previous status (revert one slot).
                // Exposed on the RIGHT as the row moves left.
                HStack(spacing: 0) {
                    Spacer()
                    actionLabel(
                        icon:  "arrow.uturn.backward",
                        text:  prev.status.uppercased(),
                        color: .white
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(statusHex: prev.displayHex).opacity(0.92))
                .opacity(leftProgress)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func actionLabel(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.title3)
            Text(text).font(.system(size: 12, weight: .heavy))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 24)
    }

    // (Old `swipeGesture` — workspace-gated 1-finger DragGesture
    // mapping right→REVIEW / left→COMPLETE — removed. Replaced by
    // the universal `TwoFingerSwipeRecognizer` background above
    // which routes right→DONE / left→previous status using the
    // workflow ordering, with no workspace restriction.)

    // MARK: - Compact row (collapsed state)

    private var compactRow: some View {
        // The DONE pill is attached as `.overlay` on the row
        // content. Overlays paint on top WITHOUT
        // participating in the host's layout sizing — that's
        // the structural guarantee that the pill's
        // `.fixedSize()` intrinsic width cannot push the row
        // card wider.
        //
        // The HStack inside the overlay positions the pill
        // EXPLICITLY: a 14pt-wide `Color.clear` placeholder
        // mirrors the row's outer `.padding(.leading, 14)`,
        // pushing `donePillOverlay`'s leading edge to land
        // exactly at the icon's leading edge. A trailing
        // `Spacer` consumes the rest of the row's width.
        // This is more robust than relying on
        // `.overlay(alignment: .leading)` with
        // `.padding(.leading, 14)` — the overlay system
        // sometimes anchors the overlay's CENTER (not its
        // leading edge) to the host's leading guide when the
        // overlay's content uses `.fixedSize()`, producing
        // the regression where the DOING pill stuck out
        // past the row's left border.
        compactRowContent
            .overlay(alignment: .leading) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: 14)
                    donePillOverlay
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
    }

    /// The actual row content (icon + title VStack +
    /// trailing meta cluster). Used to be `compactRow`'s
    /// body directly — extracted into its own computed
    /// property so the parent `compactRow` can wrap it in a
    /// ZStack and overlay the DONE pill as a layout-
    /// independent sibling.
    private var compactRowContent: some View {
        // Two-side HStack, top-aligned, so the trailing button column
        // (which has a fixed 50pt height — 2 buttons + 6pt spacer) can
        // grow taller than the title row WITHOUT inflating it. Stripe
        // and title now live in the SAME sub-HStack, so the stripe's
        // vertical span is dictated by the title's content height
        // (not by the button column).
        HStack(alignment: .top, spacing: 0) {

            // ── Title group ────────────────────────────────────────
            // Stripe + checkbox + title VStack. ALWAYS center-aligned
            // now that the trailing button column lives in a separate
            // sibling HStack — the title group's intrinsic height is
            // exactly the title's content height, so the stripe and
            // checkbox center on the title in both states.
            HStack(alignment: .center, spacing: 8) {
                // Status color used to live as a 3pt stripe here; it's
                // now expressed as a coloured drop shadow on the whole
                // row card (see `.shadow(...)` below) so the row reads
                // as a "tinted card" instead of needing a vertical
                // accent bar to communicate status.
                checkboxButton

                // Spacing 8pt between title and meta row gives the
                // title clear breathing room — at 3pt the meta pills
                // were touching the title's descenders.
                //
                // Animated leading padding on the title VStack is
                // what makes the title + status pill slide rightward
                // when the user hovers DONE. The checkbox slot
                // itself is LOCKED at 14pt regardless of hover (see
                // `checkboxButton` — DONE pill is rendered as an
                // overlay that overflows the slot's bounds, NOT by
                // growing the slot). Keeping the slot at 14pt means
                // the row's content has the SAME intrinsic width
                // whether hovered or not, so the row card cannot
                // grow horizontally. The 66pt padding here is the
                // delta needed to clear the DONE pill's natural
                // intrinsic width — same offset the title would
                // have received if the slot had grown to 80pt, but
                // applied via padding instead of slot growth so
                // the row card's outer dimensions stay invariant.
                VStack(alignment: .leading, spacing: 1.44) {
                    // Title slides RIGHT on DONE hover via
                    // `.offset(x:)` — visual-only shift, doesn't
                    // affect layout sizing. 66pt clears the DONE
                    // pill's intrinsic width.
                    titleView
                        .offset(x: hoveringCheckbox && !task.isCompleted && !completing ? 66 : 0)
                        .animation(.spring(response: 0.30, dampingFraction: 0.82),
                                   value: hoveringCheckbox)

                    // Fixed-width slots so variable content (status
                    // name, due-date label) doesn't push the avatar /
                    // date / priority around between rows.
                    //
                    // Always show the trailing meta cluster — the
                    // inline-expand UX was removed, so there's no
                    // alternate "expanded" view to swap to.
                    do {
                        // Tighter inter-cell spacing (4pt) for the
                        // trailing cluster — at 8pt the assignee
                        // name sat far from its avatar and the date
                        // sat far from the priority flag, leaving
                        // the "who/when" group feeling sparse.
                        HStack(spacing: 4) {
                            // Order swapped: status pill on the LEFT
                            // (it's the row's primary state badge —
                            // colored, eye-catching, deserves the
                            // leading anchor that aligns with the
                            // title above), assignee text follows
                            // on the right as secondary metadata.
                            // Status badge slides right with the
                            // title on DONE hover.
                            statusBadge
                                .frame(width: 168, alignment: .leading)
                                .offset(x: hoveringCheckbox && !task.isCompleted && !completing ? 66 : 0)
                                .animation(.spring(response: 0.30, dampingFraction: 0.82),
                                           value: hoveringCheckbox)

                            // Assignee first name — sits to the RIGHT
                            // of the status pill. Intrinsic width,
                            // left-aligned so the name reads
                            // naturally "STATUS · Marconi" left-to-
                            // right. Slides with the status on DONE
                            // hover so the pair stays visually
                            // grouped.
                            Text(assigneeFirstName ?? "")
                                .font(Editorial.serif(12.5).italic())
                                .foregroundStyle(Editorial.inkSoft)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .fixedSize(horizontal: true, vertical: false)
                                .opacity(hoveringCheckbox ? 0 : 1)
                                // Static -60pt shift — pulls "Marconi"
                                // tight up against the status pill's
                                // trailing edge. Iteratively widened
                                // from the original -30: a single 35%
                                // step left only consumed half the
                                // visible gap, so this doubles it for
                                // the cumulative "35% more left" pass.
                                // `.offset` is composed (not replaced)
                                // by the hover-slide offset below, so
                                // both transforms stack cleanly.
                                .offset(x: -60)
                                .offset(x: hoveringCheckbox && !task.isCompleted && !completing ? 66 : 0)
                                .animation(.spring(response: 0.30, dampingFraction: 0.82),
                                           value: hoveringCheckbox)

                            // Spacer pushes the trailing meta cluster
                            // (assignee name, avatar, date, priority)
                            // against the right edge of the card,
                            // away from the status pill on the left.
                            Spacer(minLength: 4)

                            // Trailing meta cluster — the GROUP is
                            // right-anchored against the row's
                            // trailing edge, but every cell inside
                            // is left-aligned within a fixed-width
                            // slot. This keeps the leading edge of
                            // each piece of info (assignee text,
                            // avatar, date) consistent across rows
                            // — natural reading direction — while
                            // the cluster as a whole hugs the right
                            // side of the card.
                            //
                            // Hidden while the DONE checkbox is in
                            // its expanded "REVIEW" pill state — at
                            // the minimum panel width (480pt) the
                            // sum of fixed slots overflows the
                            // available column once the checkbox
                            // grows from 14pt to ~60pt, which would
                            // otherwise stretch the entire card.
                            // Yielding the assignee slot is enough
                            // to keep the row width pinned.
                            // ─────────────────────────────────────
                            // Trailing meta cluster wrapped in its
                            // own fixed-width container so the
                            // avatar lands at the SAME absolute X
                            // for every row. Previously each cell
                            // had a fixed slot but the cluster as
                            // a whole had no width lock — when one
                            // row's date or priority rendered with
                            // slightly different intrinsic content,
                            // the Spacer above absorbed the diff
                            // and the entire cluster (name + photo
                            // included) drifted right or left,
                            // visually misaligning across rows
                            // with different assignees.
                            //
                            // Now: photo + name pinned to a 90pt
                            // sub-block right-aligned to the
                            // cluster's leading edge; date and
                            // priority occupy their own fixed
                            // slots after. Cluster total = 178pt,
                            // independent of content.
                            HStack(spacing: 4) {
                                Group {
                                    if let due = task.dueDate {
                                        metaDateBadge(due: due)
                                    }
                                }
                                .frame(width: 78, alignment: .leading)

                                priorityBadge
                            }
                            // Right-anchor the cluster against the
                            // FULL row width — without `maxWidth:
                            // .infinity` here, the meta HStack's
                            // width is dictated by the widest sibling
                            // in the title VStack (the title text
                            // itself), so rows with different title
                            // lengths landed the cluster (and thus
                            // the avatar) at different X positions.
                            // Forcing infinity makes the meta row
                            // always span the available width and
                            // pins the cluster's trailing edge to a
                            // single column.
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: -8)),
                            removal:   .opacity.combined(with: .offset(y: 8))
                        ))
                    }
                }
                // Nudges title + assignee/status row 10pt to the
                // right (a small "10%" visual offset) so both
                // labels share the same leading X and sit slightly
                // inside the row instead of crowding the checkbox.
                .padding(.leading, 10)

                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
            .padding(.vertical, 14)

            // Trailing button column was removed: the row's tap
            // gesture (below) opens the same popup the explicit
            // expand button used to. With inline-expand gone,
            // there's only one detail-view path — the duplicate
            // affordance was just visual noise.
            Spacer().frame(width: 14)
        }
        // Tap anywhere on the row (outside the inner buttons)
        // opens the detail popup. Inline-expand was removed —
        // every row interaction now lives in the popup.
        .contentShape(Rectangle())
        .onTapGesture {
            appState.detailTaskOrigin = MouseOriginCapture
                .currentClickRectInMainWindow()
            appState.detailTask = task
        }
        // Force the row to its intrinsic content height — without
        // this the parent VStack can propose a much larger height
        // and the trailing buttons VStack would absorb it.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var checkIcon: String {
        if task.isCompleted { return "checkmark.circle.fill" }
        if completing       { return "circle.dotted" }
        return "circle"
    }

    /// Title cell — Text by default, TextField only after the user
    /// double-clicks. Avoids the N×NSTextField cost during scroll.
    ///
    /// Title rendering: SINGLE line with tail-truncation when the row
    /// Always single-line (the popup carries the full text).
    /// Double-click switches to a single-line TextField for
    /// quick rename in place.
    @ViewBuilder
    private var titleView: some View {
        if editingTitle {
            TextField("", text: $titleDraft)
                .textFieldStyle(.plain)
                .focused($titleFocused)
                .focusEffectDisabled()
                .font(Editorial.sans(15, .medium))
                .foregroundStyle(Editorial.ink)
                .lineLimit(1)
                .onAppear {
                    titleDraft   = task.title
                    titleFocused = true
                }
                .onSubmit { commitTitleEdit() }
                .onChange(of: titleFocused) { _, focused in
                    if !focused { commitTitleEdit() }
                }
        } else {
            Text(task.title)
                .font(Editorial.sans(15, .medium))
                .strikethrough(task.isCompleted, color: Editorial.inkMute)
                .foregroundStyle(task.isCompleted ? Editorial.inkMute : Editorial.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(task.title)   // tooltip shows full title on hover
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    titleDraft   = task.title
                    editingTitle = true
                }
        }
    }

    private func commitTitleEdit() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != task.title {
            Task { await appState.updateTaskTitle(task, to: trimmed) }
        }
        editingTitle = false
        titleFocused = false
    }

    // MARK: - Hover-to-COMPLETE checkbox
    //
    // Default state is just a small grey circle. On hover (when the task
    // isn't already completed), the circle expands to the right into a
    // pill that shows "COMPLETE" with the same green border + ultraThin
    // material + bevel + shadows used by the COMPLETE filter pill. Layout
    // reserves only the collapsed width so the title beside it doesn't
    // shift — the expanded pill simply overflows over the title area.

    private var checkboxButton: some View {
        // The checkbox slot is now JUST the 14pt circle icon.
        // The DONE pill is rendered as a SIBLING in the
        // parent compactRow's ZStack (see `compactRow` —
        // `donePillOverlay` is added there). This keeps the
        // pill's `.fixedSize()` intrinsic width OUT of this
        // button's layout entirely, so the slot is provably
        // 14pt regardless of hover state.
        Button {
            guard !task.isCompleted, !completing else { return }
            guard let target = doneTargetStatus else { return }
            completing = true
            // Same slide-out + commit + undo path as the swipe
            // gesture. Direction = +1 so the row flies right
            // (matches the visual semantics of "advance"),
            // mirroring how a right-swipe commits.
            commitStatusChange(to: target, direction: 1)
        } label: {
            Image(systemName: checkIcon)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(task.isCompleted
                                 ? Editorial.statusColor("complete")
                                 : Editorial.inkFaint)
                .symbolEffect(.bounce, value: task.isCompleted)
                .frame(width: 14, height: 14)
                .opacity(hoveringCheckbox && !task.isCompleted && !completing ? 0 : 1)
                .animation(.easeInOut(duration: 0.18),
                           value: hoveringCheckbox)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(task.isCompleted || completing || doneTargetStatus == nil)
        // Scroll-aware hover: while the list is being
        // scrolled, the cursor sweeps across many rows in
        // quick succession. Firing the DONE-pill reveal
        // (slot animation, label slide, scale springs) on
        // every transient hover would cost frames during
        // the scroll. Skip the state update while
        // `ScrollStateObserver.shared.isScrolling` is true,
        // and force-reset any latent `hoveringCheckbox` so
        // a row that was hovered when the user started
        // scrolling doesn't keep its DONE pill visible
        // through the scroll.
        .onHover { hover in
            if ScrollStateObserver.shared.isScrolling {
                if hoveringCheckbox { hoveringCheckbox = false }
                return
            }
            hoveringCheckbox = hover
        }
        .onReceive(ScrollStateObserver.shared.$isScrolling) { scrolling in
            if scrolling, hoveringCheckbox { hoveringCheckbox = false }
        }
    }

    /// The DONE pill itself, rendered as a SIBLING of the
    /// row's content HStack inside `compactRow`'s ZStack.
    /// Lives outside the checkbox button so its `.fixedSize()`
    /// intrinsic width never influences the layout of the
    /// content row — the pill is purely visual at this level
    /// and SwiftUI's ZStack alignment positions it precisely
    /// at x=14 (icon's leading edge after the row's leading
    /// padding) without any layout participation.
    ///
    /// Hover detection: the pill ALSO updates `hoveringCheckbox`
    /// on `.onHover`. Without this, moving the cursor from the
    /// 14pt icon onto the wider pill area would fire the
    /// icon's `onHover(false)`, hiding the pill mid-interaction
    /// because the cursor would be on the pill but the icon
    /// reports "not hovered". With both views participating in
    /// the hover state, the pill stays visible while the cursor
    /// traverses either the icon or the pill body.
    @ViewBuilder
    private var donePillOverlay: some View {
        let isHover = hoveringCheckbox && !task.isCompleted && !completing
        let pillColor = doneColor
        let pillLabel = (doneTargetStatus?.status ?? "DONE").uppercased()
        // PERF: the EXPENSIVE pill content (Text + Capsule.fill
        // with `.ultraThinMaterial` backdrop blur + 2× strokeBorder
        // overlays + shadow) is rendered ONLY while hovered.
        // Previously the entire stack lived in the cell at
        // opacity 0 — SwiftUI doesn't optimise away opacity-0
        // views, so each of the ~30 visible cells carried a
        // backdrop-blur layer + 5 sublayers, blended every
        // scroll frame. Conditionally rendering inside the
        // Button's label keeps the button shell stable (so
        // hover tracking keeps working as the cursor crosses
        // from the icon onto the pill body) while the heavy
        // content only mounts when actually visible.
        Button {
            guard !task.isCompleted, !completing else { return }
            guard let target = doneTargetStatus else { return }
            completing = true
            // Same slide-out animation as the swipe. The DONE pill
            // fires the same `commitStatusChange` so visual
            // feedback (row flying out + list closing the gap)
            // is identical regardless of which control the user
            // tapped.
            commitStatusChange(to: target, direction: 1)
        } label: {
            ZStack {
                if isHover {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(pillColor)
                            .frame(width: 6, height: 6)
                        Text(pillLabel)
                            .font(Editorial.sans(10, .semibold))
                            .foregroundStyle(Editorial.ink)
                            .tracking(0.4)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Editorial.page))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Editorial.rule, lineWidth: 1))
                    .fixedSize()
                        // Match the prior visual: scale up from 0.85
                        // anchored to the leading edge, fade in.
                        .transition(
                            .scale(scale: 0.85, anchor: .leading)
                            .combined(with: .opacity)
                        )
                } else {
                    // Empty placeholder keeps the Button's frame
                    // stable when the pill is gone — without it
                    // the Button would collapse to zero size and
                    // the hover-area would disappear, defeating
                    // the cursor-transition guard the dual-onHover
                    // pattern was designed for.
                    Color.clear.frame(width: 14, height: 22)
                }
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .allowsHitTesting(isHover)
        // Animation context for the conditional pill's
        // `.transition` — applied on the modifier here so the
        // insertion/removal animates on hover state changes.
        .animation(.spring(response: 0.30, dampingFraction: 0.78),
                   value: isHover)
        // Same scroll-aware pattern as `checkboxButton`'s
        // hover handler — skip state updates while scrolling
        // so the pill reveal/scale springs don't run for every
        // row the cursor sweeps across.
        .onHover { hover in
            if ScrollStateObserver.shared.isScrolling {
                if hoveringCheckbox { hoveringCheckbox = false }
                return
            }
            hoveringCheckbox = hover
        }
    }

    // MARK: - Status badge with dropdown

    @ViewBuilder
    private var statusBadge: some View {
        // Editorial status: a dot in the status's real ClickUp
        // colour + the word, never a filled pill. Keeps Apollo's
        // per-status palette (not the prototype's 8 mock families)
        // but adopts the editorial *form*. A faint chevron hints
        // it's still a dropdown.
        let color = Color(hex: cachedStatusHex)
        let pill = HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(task.status.uppercased())
                .font(Editorial.sans(10.5, .semibold))
                .foregroundStyle(color)            // status's own accent colour
                .tracking(0.6)                     // editorial all-caps tracking
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Editorial.inkFaint)
        }

        if appState.availableStatuses.isEmpty {
            pill
        } else {
            Button { showStatusMenu.toggle() } label: { pill }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .popover(isPresented: $showStatusMenu, arrowEdge: .top) {
                    StatusPickerPopover(
                        statuses:          appState.availableStatuses,
                        currentStatusName: task.status
                    ) { status in
                        Task { await appState.updateTaskStatus(task, to: status) }
                        showStatusMenu = false
                    }
                }
        }
    }

    // MARK: - Compact-row meta badges (date, priority)

    private func metaDateBadge(due: Date) -> some View {
        let overdue = due < Date() && !task.isCompleted
        return VStack(alignment: .leading, spacing: 1) {
            Text(relativeDateText(for: due))
                .font(Editorial.sans(12, .medium))
                .foregroundStyle(overdue ? Editorial.accent : Editorial.inkSoft)
                .monospacedDigit()
            if overdue {
                Text("atrasada")
                    .font(Editorial.serif(10.5).italic())
                    .foregroundStyle(Editorial.accent)
            }
        }
    }

    private func relativeDateText(for date: Date) -> String {
        // Today's startOfDay is computed once and shared via a static
        // cache that auto-refreshes when the day changes — avoids a
        // Calendar lookup + dateComponents call for every row in every
        // render frame during scroll.
        let now      = TodayCache.startOfToday
        let target   = TodayCache.calendar.startOfDay(for: date)
        let days     = TodayCache.calendar
            .dateComponents([.day], from: now, to: target).day ?? 0
        switch days {
        case 0:           return "Hoje"
        case 1:           return "Amanhã"
        case -1:          return "Ontem"
        case 2...6:       return "em \(days) dias"
        case -6 ... -2:   return "\(-days) dias atrás"
        default:
            // Was `.formatted(.dateTime.day().month(.abbreviated))`
            // — convenient but builds a fresh FormatStyle and
            // resolves the user's locale on every call. With 30+
            // rows visible in the task list, that's hundreds of
            // redundant locale lookups per scroll frame. The
            // shared `DateFormatter` is created once.
            return SharedDateFormatters.shortDayMonthPTBR.string(from: date)
        }
    }

    @ViewBuilder
    private var priorityBadge: some View {
        // Icon-only — the textual label ("Normal", "Alta", etc.) is
        // dropped so the meta row's right side stays compact and the
        // row's vertical height stays exactly the line height of the
        // other badges. The flag colour alone communicates priority.
        // Fixed frame so the slot reserves the same space whether or
        // not the task has a priority assigned, preventing the meta
        // row from shifting when priorities flip.
        Group {
            if task.priority > 0 {
                Image(systemName: "flag.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hex: task.priorityHex))
            }
        }
        .frame(width: 14, height: 14, alignment: .center)
        .help(task.priority > 0 ? task.priorityLabel : "Sem prioridade")
    }
}
