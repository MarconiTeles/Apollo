import AppKit
import SwiftUI
import Combine

// AppKit-native task row — pixel-targeted port of `TaskRowView`.
// All visual values (fonts, paddings, slot widths, colours, shadow
// curve) read off the SwiftUI source so the AppKit cell drops in
// behind `NSCollectionListView` with no perceptible difference.
//
// Phase 1 scope: STATIC visuals only.
//   ✅ rounded card background (rowFill cache)
//   ✅ status-tinted drop shadow
//   ✅ checkbox icon (state-aware)
//   ✅ title (with strikethrough when completed)
//   ✅ status pill (color + capsule + chevron)
//   ✅ assignee first name
//   ✅ relative date label + calendar icon
//   ✅ priority flag
//
// Phase 2-4 will add: tap-to-open detail, hover halo, DONE pill
// reveal, status pill dropdown popover, two-finger swipe, slide-
// out commit animation.

// MARK: - Cell

final class TaskRowCellItem: NSCollectionViewItem, SwipeAwareHosting {
    static let identifier = NSUserInterfaceItemIdentifier("TaskRowCellItem")

    /// Visual gap baked into the parent cell's height so
    /// consecutive parent cards sit ~14.8pt apart even though
    /// FlowLayout's `minimumLineSpacing` is set to 0 (so the
    /// neighbouring SubtaskCellItem can carry its own,
    /// 80%-smaller gap). Half the gap goes on top, half on
    /// bottom; the inner `rowView` is inset by this padding so
    /// the rounded card itself stays at its original 78pt
    /// height regardless of the cell's outer height.
    static let bakedVerticalGap: CGFloat = 14.79768470
    static var halfGap: CGFloat { bakedVerticalGap * 0.5 }

    private(set) var rowView: TaskRowContentView!
    private let leftPanel  = SwipeActionPanelView(side: .leading)
    private let rightPanel = SwipeActionPanelView(side: .trailing)

    var onSwipeProgress: ((CGFloat) -> Void)?
    var onSwipeEnd:      ((CGFloat) -> Void)?
    var onRowClick: ((CUTask, CGRect) -> Void)?
    var onStatusPillClick: ((CUTask, NSView) -> Void)?
    /// Called when the user clicks the expand chevron at
    /// the top-right of the row. Wired up by the data source
    /// in `TaskCollectionView.configure(cell:with:)`.
    var onExpandClick: ((CUTask) -> Void)?

    /// Stored leading/trailing constraints for the inner
    /// `rowView` so we can shrink the visible card on
    /// subtask rows (the card itself becomes narrower at
    /// each nesting level — visual signal that this row is
    /// nested under a parent above).
    private var rowLeadingConstraint:  NSLayoutConstraint?
    private var rowTrailingConstraint: NSLayoutConstraint?
    /// Per-depth horizontal shrink applied to the rowView's
    /// constraints. depth=0 → base 12pt insets; each
    /// additional level adds this amount on the LEFT (so the
    /// card shifts right and shrinks visibly).
    private let subtaskCardLeadingExtra: CGFloat = 16
    /// Stored swipe panel constraints so they shrink in
    /// lockstep with the card — keeps the action panels
    /// visually aligned with the row they belong to.
    private var leftPanelLeading:  NSLayoutConstraint?
    private var leftPanelTrailing: NSLayoutConstraint?
    private var rightPanelLeading:  NSLayoutConstraint?
    private var rightPanelTrailing: NSLayoutConstraint?

    private var boundTask: CUTask?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = .clear

        // Action panels (swipe-reveal). Fill the same area
        // rowView occupies — inset by `halfGap` top/bottom so
        // they line up with the rounded card (the cell itself
        // is `bakedVerticalGap`pt taller than the card to
        // absorb the parent-row spacing).
        let pad = TaskRowCellItem.halfGap
        for panel in [leftPanel, rightPanel] {
            panel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(panel)
            let lead  = panel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12)
            let trail = panel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12)
            NSLayoutConstraint.activate([
                lead,
                trail,
                panel.topAnchor.constraint(equalTo: view.topAnchor,
                                           constant: pad),
                panel.bottomAnchor.constraint(equalTo: view.bottomAnchor,
                                              constant: -pad),
            ])
            if panel === leftPanel {
                leftPanelLeading  = lead
                leftPanelTrailing = trail
            } else {
                rightPanelLeading  = lead
                rightPanelTrailing = trail
            }
        }

        rowView = TaskRowContentView(frame: .zero)
        rowView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rowView)
        let rowLead  = rowView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12)
        let rowTrail = rowView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12)
        NSLayoutConstraint.activate([
            rowLead,
            rowTrail,
            rowView.topAnchor.constraint(equalTo: view.topAnchor,
                                         constant: pad),
            rowView.bottomAnchor.constraint(equalTo: view.bottomAnchor,
                                            constant: -pad),
        ])
        rowLeadingConstraint  = rowLead
        rowTrailingConstraint = rowTrail

        rowView.onClick = { [weak self] in
            guard let self, let task = self.boundTask else { return }
            let rect = MouseOriginCapture.currentClickRectInMainWindow()
            self.onRowClick?(task, rect)
        }
        rowView.statusPill.onClick = { [weak self] in
            guard let self, let task = self.boundTask else { return }
            self.onStatusPillClick?(task, self.rowView.statusPill)
        }
        // Chevron click → toggle subtask expansion. The
        // toggle calls `onExpandClick` which the data
        // source wires up in `configure(cell:with:)`.
        rowView.onExpandClick = { [weak self] in
            guard let self, let task = self.boundTask else { return }
            self.onExpandClick?(task)
        }

        // Reveal the action panels in proportion to the swipe
        // distance. Capped at 1.0 once the row has been pulled
        // ~100pt — past that the panel is fully visible and only
        // the row's continuing slide changes.
        // `duration > 0` (used on cancel/spring-back) animates
        // the alpha change over the same window the row uses
        // for its translation, so the panel never disappears
        // mid-row-animation.
        rowView.onSwipeProgress = { [weak self] dx, duration in
            guard let self else { return }
            let leftAlpha  = max(0, min(1, dx / 100))
            let rightAlpha = max(0, min(1, -dx / 100))
            if duration > 0 {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = duration
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.leftPanel.animator().alphaValue  = leftAlpha
                    self.rightPanel.animator().alphaValue = rightAlpha
                }
            } else {
                self.leftPanel.alphaValue  = leftAlpha
                self.rightPanel.alphaValue = rightAlpha
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onSwipeProgress    = nil
        onSwipeEnd         = nil
        onRowClick         = nil
        onStatusPillClick  = nil
        boundTask          = nil
        leftPanel.alphaValue  = 0
        rightPanel.alphaValue = 0
    }

    func bind(task: CUTask,
              appState: AppState,
              depth: Int = 0,
              hasChildren: Bool = false,
              isExpanded: Bool = false) {
        boundTask = task
        let extraLead = 12 + CGFloat(depth) * subtaskCardLeadingExtra
        rowLeadingConstraint?.constant   =  extraLead
        leftPanelLeading?.constant       =  extraLead
        rightPanelLeading?.constant      =  extraLead

        rowView.bind(task: task,
                     appState: appState,
                     depth: depth,
                     hasChildren: hasChildren,
                     isExpanded: isExpanded)

        // Configure the action panels for this task's neighbours
        // in the workflow.
        let target = appState.doneTargetByStatus[task.status]
            ?? appState.doneTargetFallback
        if let target {
            leftPanel.configure(
                iconName: "checkmark.circle.fill",
                text:     target.status.uppercased(),
                hex:      target.displayHex
            )
            leftPanel.isHidden = false
        } else {
            leftPanel.isHidden = true
        }

        let prev: CUStatus? = {
            let statuses = appState.availableStatuses
            guard let idx = statuses.firstIndex(where: { $0.status == task.status }),
                  idx > 0
            else { return nil }
            return statuses[idx - 1]
        }()
        if let prev {
            rightPanel.configure(
                iconName: "arrow.uturn.backward",
                text:     prev.status.uppercased(),
                hex:      prev.displayHex
            )
            rightPanel.isHidden = false
        } else {
            rightPanel.isHidden = true
        }

        leftPanel.alphaValue  = 0
        rightPanel.alphaValue = 0
    }
}

// MARK: - Row content view

final class TaskRowContentView: NSView {
    /// Top-down Y to match SwiftUI semantics.
    override var isFlipped: Bool { true }

    // MARK: Subviews

    private let checkboxIcon  = NSImageView()
    private let titleLabel    = NSTextField(labelWithString: "")
    /// Internal-access so the cell can install the click handler
    /// from `TaskRowCellItem`.
    let statusPill            = StatusPillView()
    private let assigneeLabel = NSTextField(labelWithString: "")
    private let dateIcon      = NSImageView()
    private let dateLabel     = NSTextField(labelWithString: "")
    private let priorityIcon  = NSImageView()

    // MARK: Click

    /// Fired when the user releases the mouse on the row's
    /// content area (and the cursor is still inside the row's
    /// bounds at release). Used by `TaskRowCellItem` to route
    /// to the detail-popup open path.
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        // Status pill / DONE pill have their own `mouseDown`
        // overrides and consume their events, so any mousedown
        // that reaches this method is on the row's content area.
        // Press-down compresses the cell slightly for tactile
        // feedback; the click action fires on `mouseUp` so the
        // user has a moment to drag away to cancel.
        isPressed = true
        updateScale()
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        updateScale()
        // Fire the click only if the cursor is still over the
        // row at release (Mail-style "drag-out cancels").
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) {
            onClick?()
        }
    }

    // MARK: Right-click → context menu
    //
    // AppKit calls `menu(for:)` automatically whenever a
    // right-click (or two-finger-tap) lands on a view, so
    // overriding here makes the entire row a context-menu
    // target without us needing to install an `NSMenu` per
    // bind. The menu itself is rebuilt every time from the
    // bound task + appState — that way the ✓ marks on
    // Status / Prioridade reflect the LATEST value, even
    // when the task's status changed since the row was
    // last bound.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let task = self.task,
              let appState = self.appState
        else { return nil }
        return TaskContextMenu.makeNSMenu(task: task,
                                           appState: appState)
    }

    // MARK: Two-finger trackpad swipe

    override func scrollWheel(with event: NSEvent) {
        // Mouse wheels (no precise deltas) shouldn't trigger
        // row swipes — only trackpad gestures.
        guard event.hasPreciseScrollingDeltas else {
            super.scrollWheel(with: event)
            return
        }
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        switch event.phase {
        case .began:
            swipeAccumulated = 0
            swipeAxisLocked = nil
            swipeArmedSide = 0

        case .changed:
            if swipeAxisLocked == nil {
                let mag = max(abs(dx), abs(dy))
                guard mag > 0.5 else { return }
                swipeAxisLocked = abs(dx) > abs(dy) ? .horizontal : .vertical
            }
            switch swipeAxisLocked {
            case .horizontal:
                swipeAccumulated += dx
                swipeOffset = swipeAccumulated
                applyTransform(animated: false)
                onSwipeProgress?(swipeOffset, 0)
                updateSwipeArmFeedback(offset: swipeAccumulated)
            case .vertical:
                super.scrollWheel(with: event)
            case .none:
                break
            }

        case .ended, .cancelled:
            if swipeAxisLocked == .horizontal {
                handleSwipeEnd(finalOffset: swipeAccumulated)
            } else if swipeAxisLocked == .vertical {
                super.scrollWheel(with: event)
            }
            swipeAccumulated = 0
            swipeAxisLocked = nil
            swipeArmedSide = 0

        default:
            super.scrollWheel(with: event)
        }
    }

    /// Threshold-crossing haptic. Fires once when the user passes
    /// the commit boundary (so they feel the action "arm"), and
    /// again — slightly softer feel via `.toggle` — when they
    /// retreat back inside it. The hysteresis flag prevents
    /// repeat firing while the user holds at the boundary
    /// jittering by a pixel or two.
    private func updateSwipeArmFeedback(offset: CGFloat) {
        let threshold: CGFloat = 220
        let side: Int
        if offset >  threshold, doneTargetForSwipe   != nil { side =  1 }
        else if offset < -threshold, previousStatus != nil { side = -1 }
        else { side = 0 }
        guard side != swipeArmedSide else { return }
        // Crossing INTO an armed zone → assertive double-thunk so
        // the user knows the action is locked in. Crossing OUT
        // back to neutral → softer single pulse to acknowledge
        // the disarm without competing with the drag.
        if side != 0 {
            Haptics.taskAction()
        } else {
            Haptics.toggle()
        }
        swipeArmedSide = side
    }

    /// Decide commit vs cancel based on the final translation.
    /// Threshold: 220pt (must drag the row almost off-screen
    /// to commit).
    private func handleSwipeEnd(finalOffset: CGFloat) {
        let threshold: CGFloat = 220
        // ~850ms post-release the haptic lands as a deliberate
        // commit confirmation — long after the row has flown
        // off-screen (180ms) and the user's finger has lifted,
        // so the pulse never blends with the gesture itself.
        if finalOffset > threshold, let target = doneTargetForSwipe {
            Haptics.taskAction(after: 0.85)
            commitSwipe(direction: 1, target: target)
        } else if finalOffset < -threshold, let prev = previousStatus {
            Haptics.taskAction(after: 0.85)
            commitSwipe(direction: -1, target: prev)
        } else {
            cancelSwipe()
        }
    }

    /// Resolved DONE-target status for the current task. Mirror
    /// of the SwiftUI `doneTargetStatus` fallback chain.
    private var doneTargetForSwipe: CUStatus? {
        guard let task, let appState else { return nil }
        return appState.doneTargetByStatus[task.status]
            ?? appState.doneTargetFallback
    }

    /// Status immediately preceding the current one in the
    /// workflow ordering. nil for the first status.
    private var previousStatus: CUStatus? {
        guard let task, let appState else { return nil }
        let statuses = appState.availableStatuses
        guard let idx = statuses.firstIndex(where: { $0.status == task.status }),
              idx > 0
        else { return nil }
        return statuses[idx - 1]
    }

    /// Public entry point for "advance status" via the
    /// checker-icon click (HoverZoneView.onClick). Reuses the
    /// same slide-out + commit + undo pipeline the right-
    /// direction swipe runs.
    func commitDoneAction() {
        guard let target = doneTargetForSwipe else { return }
        // No haptic on click-driven commit — the trackpad's own
        // click pulse already announces the action and a second
        // pulse stacking later read as noise. Swipe-driven
        // commits keep their haptic since there's no intrinsic
        // gesture pulse on a trackpad swipe.
        commitSwipe(direction: 1, target: target)
    }

    /// Commit the swipe action: slide the row off-screen, then
    /// apply the status mutation + push undo. The cell will be
    /// removed by the data update (NSCollectionView batch
    /// animation closes the gap).
    private func commitSwipe(direction: CGFloat, target: CUStatus) {
        guard let task, let appState else { return }
        let originalStatusName = task.status
        let originalTask = task

        swipeOffset = direction * 600
        applyTransform(animated: true, duration: 0.18, timingName: .easeIn)

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            // Reset BEFORE the data update so the recycled cell
            // doesn't inherit the off-screen offset.
            await MainActor.run {
                self?.swipeOffset = 0
                self?.applyTransform(animated: false)
                self?.onSwipeProgress?(0, 0)
            }
            await appState.updateTaskStatus(originalTask, to: target)
            appState.pushUndo(
                label: "“\(originalTask.title)” → \(originalStatusName.uppercased())"
            ) {
                if let restore = appState.availableStatuses
                    .first(where: { $0.status == originalStatusName }) {
                    await appState.updateTaskStatus(originalTask, to: restore)
                }
            }
        }
    }

    /// Released below the commit threshold — spring back to 0
    /// with a real bouncy settle. `CASpringAnimation` gives a
    /// physical spring (mass / stiffness / damping) that
    /// overshoots slightly past 0 and oscillates before
    /// settling, instead of the previous flat ease-out which
    /// just glided home.
    private func cancelSwipe() {
        guard let layer = self.layer else { return }
        swipeOffset = 0
        let scale = currentScaleValue
        let target = CATransform3DConcat(
            CATransform3DMakeScale(scale, scale, 1),
            CATransform3DIdentity
        )
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D:
            layer.presentation()?.transform ?? layer.transform)
        spring.toValue   = NSValue(caTransform3D: target)
        spring.mass             = 1
        spring.stiffness        = 220
        spring.damping          = 14    // lower → bouncier
        spring.initialVelocity  = 0
        spring.duration         = spring.settlingDuration
        layer.add(spring, forKey: "transform")
        layer.transform = target

        // Fade panels out over the same settle duration so the
        // colour disappears when the row finally lands at 0.
        onSwipeProgress?(0, spring.settlingDuration)
    }

    // MARK: State

    private var task: CUTask?
    private weak var appState: AppState?
    /// Subscription on `appState.$anyPopupOpen`. When that
    /// flips `true` (a SwiftUI popup or the command palette
    /// just opened) we force-exit every hover state on this
    /// cell so the row behind the popup goes inert. The
    /// guards inside `setHovered` / `applyAppearance` /
    /// the per-zone callbacks then prevent fresh hover
    /// events from re-arming the visuals while the popup
    /// is up. Stored so it survives across cell reuse —
    /// nilled in `prepareForReuse` and re-installed in
    /// `bind`.
    private var anyPopupCancellable: AnyCancellable?
    private var cachedScheme: ColorScheme = .light
    private var cachedStatusHex: String = "#87909E"
    /// True while the cursor is inside the cell's bounds (any
    /// region). Drives the cell's shadow boost AND scale lift.
    private var isHovered = false
    /// True between mouseDown and mouseUp. Drives the press
    /// scale-down feedback.
    private var isPressed = false

    // MARK: Swipe state

    /// Current horizontal translation applied to the row card
    /// (px). 0 at rest. Set by `scrollWheel` during a two-finger
    /// trackpad swipe and reset on commit / spring back.
    private var swipeOffset: CGFloat = 0
    private var swipeAccumulated: CGFloat = 0
    private enum SwipeAxis { case horizontal, vertical }
    private var swipeAxisLocked: SwipeAxis? = nil
    /// Hysteresis flag for the threshold-crossing haptic. Goes
    /// `true` the first time |offset| crosses the commit threshold
    /// during a drag, `false` again when the user pulls back
    /// below it. A pulse fires on each transition so the user
    /// feels the action arm / disarm without their finger lifting.
    private var swipeArmedSide: Int = 0   // -1, 0, +1

    /// Fired on every swipe progress + at end. The cell uses
    /// this to fade in/out the action panels behind the row.
    /// `duration > 0` means animate the change (used on
    /// cancel / commit reset so the panel fade syncs with the
    /// row's spring-back / slide-out instead of disappearing
    /// in a single frame while the row's still mid-animation).
    /// `duration == 0` is the instant per-frame update during
    /// the live drag.
    var onSwipeProgress: ((CGFloat, TimeInterval) -> Void)?
    /// True while the cursor is over the small zone around
    /// the checkbox icon itself.
    private var isIconHovered = false
    /// True while the cursor is over the DONE pill (when it's
    /// visible). The pill OWNS this state via its own
    /// tracking area — when cursor moves from icon onto pill
    /// body, the icon zone fires false but the pill fires true,
    /// keeping the OR-combined `isCheckboxHovered` true.
    private var isPillHovered = false
    /// Derived: OR of icon + pill hover. Drives the DONE pill
    /// reveal animation.
    private var isCheckboxHovered = false

    // MARK: Tracking areas

    /// Cell-wide tracking area (hover halo). Re-installed on
    /// every `updateTrackingAreas` so it always matches the
    /// current bounds.
    private var cellTrackingArea: NSTrackingArea?
    /// Sub-view that owns the checkbox/DONE-pill hover zone.
    /// Using a dedicated NSView (with its own `.inVisibleRect`
    /// tracking area) is more reliable than putting a custom-
    /// rect tracking area on the parent: AppKit guarantees the
    /// hover-zone view's tracking matches its actual frame,
    /// so the trigger area never extrapolates past where the
    /// view visually sits.
    let checkboxHoverZone = HoverZoneView()

    // MARK: DONE pill (revealed on checkbox hover)

    let donePill = DonePillView()

    // MARK: Layout constants — mirror SwiftUI exactly

    /// Outer leading/trailing padding inside the card (matches the
    /// SwiftUI `.padding(.leading, 14)` + `.padding(.trailing, 14)`
    /// on `compactRow`).
    private let leadingPad: CGFloat  = 14
    /// Per-row CONTENT-level indent applied INSIDE the
    /// rowView. Set to 0 because the whole rowView frame is
    /// now shifted/shrunk at the cell-item level
    /// (`subtaskCardLeadingExtra`). Keeping a non-zero value
    /// here would double-indent — the card moves AND the
    /// content moves, drifting the title way past the
    /// checkbox's expected column.
    private let subtaskIndent: CGFloat = 0
    /// Depth of this row in the subtask tree (0 for top-level
    /// tasks, 1 for direct subtasks, etc.). Updated via
    /// `bind(...)` and folded into `leadingPad` in `layout()`.
    private var depth: Int = 0
    /// True when this task has children — drives whether the
    /// expand chevron is visible at the top-right of the cell.
    private var hasChildren: Bool = false
    /// True when this row is currently expanded (its
    /// children are visible immediately below). Drives the
    /// chevron's rotation: 0° collapsed, 90° expanded.
    private var isExpanded: Bool = false
    /// Chevron NSImageView floating at the top-right of the
    /// cell. Rotates to indicate expanded/collapsed state.
    let expandPill = SubtaskExpandPill()
    /// Hover/click target for the chevron — sized larger
    /// than the icon itself so it's easier to hit. Custom
    /// subclass so `mouseDown` can fire `onExpandClick`
    /// without bubbling to the row's tap-to-open handler.
    let expandHitZone = ChevronHitView()
    /// Closure called when the user taps the chevron. Set by
    /// the `TaskRowCellItem` after init so the AppState
    /// expansion-toggle can run from outside.
    var onExpandClick: (() -> Void)?
    /// Top + bottom vertical padding on the parent-task layout.
    /// Tracks the parent cell height in `TaskCollectionView`:
    ///   • 14pt → original (cell 80pt)
    ///   • 9pt → tightened for the 68pt cell
    ///   • 14pt → restored for the 78pt cell (current).
    /// Total parent-cell vertical: 14 + 20 + 8 + 22 + 14 = 78pt
    /// — fits exactly in the 78pt slot. Subtask rows render via
    /// `compactRow` and ignore this constant.
    private let verticalPad: CGFloat = 14
    /// Width of the checkbox icon slot. Bumped 14 → 16.1pt
    /// (+15%) per user request; the SF Symbol point size below
    /// scales to match.
    private let checkSize: CGFloat   = 16.1
    /// Spacing between the checkbox group and the title VStack.
    private let titleGroupSpacing: CGFloat = 8
    /// Title label height — matches the SwiftUI title at .body
    /// font (13pt regular) on macOS, line height ~20pt.
    private let titleHeight: CGFloat = 20
    /// Vertical gap between title row and meta row. Tracks
    /// the parent-cell height: 8pt → 5pt for the 68pt cell,
    /// 8pt restored for the 78pt cell (current).
    private let titleMetaGap: CGFloat = 8
    /// Meta row height (status pill / assignee / date / priority).
    private let metaHeight: CGFloat = 22
    /// Leading nudge applied to BOTH the title and meta row
    /// (mirrors the SwiftUI VStack's `.padding(.leading, …)`).
    /// Reduced 10 → 0 per user request to drag the title +
    /// status pill ~20% closer to the checkbox / cell leading
    /// edge.
    private let metaNudge: CGFloat = 0
    /// Fixed 168pt slot the status pill lives in inside SwiftUI
    /// (`.frame(width: 168, alignment: .leading)`). The pill
    /// itself is sized to content; the slot just reserves space
    /// so the assignee always lands at a predictable X.
    private let statusSlotWidth: CGFloat = 168
    /// SwiftUI HStack(spacing: 4) between status slot and assignee.
    private let metaSpacing: CGFloat = 4
    /// Static -30pt offset on the assignee text in SwiftUI.
    private let assigneeNudge: CGFloat = -30
    /// Priority flag fixed slot 14×14.
    private let prioritySlot: CGFloat = 14

    // MARK: Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func commonInit() {
        wantsLayer = true
        layer?.cornerRadius  = 18
        layer?.cornerCurve   = .continuous
        layer?.masksToBounds = false   // shadow needs to escape

        // Force-reset hover state when a scroll starts. Without
        // this, a cell that was hovered just before the user
        // started scrolling keeps its DONE pill visible
        // throughout the scroll (mouseExited may not fire if
        // the cell is recycled before the cursor leaves its
        // tracking area). Listening to NSScrollView's
        // `willStartLiveScroll` is cheaper than a Combine sub
        // on `ScrollStateObserver.shared.$isScrolling` for
        // every cell.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollDidStart),
            name: NSScrollView.willStartLiveScrollNotification,
            object: nil
        )
        // Mirror notification for scroll END — used to turn
        // off the rasterization shortcut once the live scroll
        // settles (see `scrollDidEnd`).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollDidEnd),
            name: NSScrollView.didEndLiveScrollNotification,
            object: nil
        )
        // Match the host view's flipped coordinate system on the
        // backing layer too. Without this the layer renders in
        // macOS's default y-up space while the NSView treats
        // points as y-down (because of `isFlipped = true`),
        // causing the drop shadow's Y offset to point UP instead
        // of DOWN — visually leaving the shadow above the card
        // instead of below it like SwiftUI's `.shadow(y: 2)`.
        layer?.isGeometryFlipped = true

        // ── Checkbox icon ─────────────────────────────────────
        // Originally .font(.system(size: 14, weight: .regular)) —
        // bumped 14 → 16.1pt (+15%) per user request.
        checkboxIcon.imageScaling = .scaleProportionallyUpOrDown
        checkboxIcon.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 16.1, weight: .regular
        )
        addSubview(checkboxIcon)

        // ── Subtask expand pill ───────────────────────────────
        // Static icon-only capsule. Sits behind a
        // transparent `ChevronHitView` (`expandHitZone`)
        // that handles clicks and routes them to
        // `onExpandClick`. Both shown only when the task
        // has children — `bind()` flips their `isHidden`.
        expandPill.isHidden    = true
        expandHitZone.isHidden = true
        expandHitZone.onClick  = { [weak self] in
            self?.onExpandClick?()
        }
        addSubview(expandPill)
        addSubview(expandHitZone)

        // ── Title ─────────────────────────────────────────────
        // 13pt SEMIBOLD — matches the event-card title
        // weight (`.callout.weight(.semibold)` in
        // `AgendaEventCard`) so the two cards' titles read
        // as siblings visually.
        // 13 × 1.15 = 14.95pt — title fonts bumped 15% per
        // user request, in lockstep with the SwiftUI fallback
        // path (`TaskRowView.titleView`) and the AppKit
        // `.completed` attributed-string variant below.
        titleLabel.font  = NSFont.systemFont(ofSize: 14.95, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.cell?.lineBreakMode = .byTruncatingTail
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.drawsBackground = false
        titleLabel.isBordered = false
        titleLabel.isBezeled = false
        addSubview(titleLabel)

        // ── Status pill ───────────────────────────────────────
        addSubview(statusPill)

        // ── Assignee first name ───────────────────────────────
        // SwiftUI: .font(.caption2)  -> 11pt
        //          .foregroundStyle(.tertiary)
        assigneeLabel.font  = NSFont.systemFont(ofSize: 11, weight: .regular)
        assigneeLabel.textColor = .tertiaryLabelColor
        assigneeLabel.maximumNumberOfLines = 1
        assigneeLabel.cell?.usesSingleLineMode = true
        assigneeLabel.cell?.lineBreakMode = .byTruncatingTail
        assigneeLabel.lineBreakMode = .byTruncatingTail
        assigneeLabel.drawsBackground = false
        assigneeLabel.isBordered = false
        assigneeLabel.isBezeled = false
        addSubview(assigneeLabel)

        // ── Date icon (calendar) ──────────────────────────────
        // SwiftUI: Image("calendar").font(.system(size: 9, weight: .semibold))
        dateIcon.image = NSImage(systemSymbolName: "calendar",
                                 accessibilityDescription: nil)
        dateIcon.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 9, weight: .semibold
        )
        dateIcon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(dateIcon)

        // ── Date label ────────────────────────────────────────
        // SwiftUI: .font(.caption2.weight(.medium)) -> 11pt medium
        dateLabel.font  = NSFont.systemFont(ofSize: 11, weight: .medium)
        dateLabel.textColor = .secondaryLabelColor
        dateLabel.maximumNumberOfLines = 1
        dateLabel.cell?.usesSingleLineMode = true
        dateLabel.cell?.lineBreakMode = .byTruncatingTail
        dateLabel.lineBreakMode = .byTruncatingTail
        dateLabel.drawsBackground = false
        dateLabel.isBordered = false
        dateLabel.isBezeled = false
        addSubview(dateLabel)

        // ── Priority flag ─────────────────────────────────────
        // SwiftUI: Image("flag.fill").font(.system(size: 11, weight: .semibold))
        //         .frame(width: 14, height: 14)
        priorityIcon.image = NSImage(systemSymbolName: "flag.fill",
                                     accessibilityDescription: nil)
        priorityIcon.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 11, weight: .semibold
        )
        priorityIcon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(priorityIcon)

        // Drop shadow — colour set per task in `applyAppearance`.
        layer?.shadowOpacity = 0
        layer?.shadowRadius  = 3
        layer?.shadowOffset  = CGSize(width: 0, height: 2)

        // ── DONE pill (Phase 3) ───────────────────────────────
        // Hidden by default; revealed via `appear()` when the
        // cursor enters the checkbox/pill zone. Click handler
        // wired in `bind` (needs the bound task + appState).
        addSubview(donePill)
        donePill.resetHidden()

        // ── Checkbox hover zone ──────────────────────────────
        // Tiny invisible NSView sized EXACTLY to the checker
        // icon. Both the hover trigger AND the DONE click area
        // live here — clicks anywhere else (including the
        // visible body of the DONE pill, which is wider) DO
        // NOT trigger the DONE action.
        addSubview(checkboxHoverZone)
        checkboxHoverZone.onHoverChanged = { [weak self] hovered in
            guard let self else { return }
            // While a popup is up, ignore hover entries —
            // the DONE pill mustn't pop in over the row
            // sitting behind a popup. Exits still pass so
            // any pre-popup hover gets cleaned up.
            if hovered, self.appState?.anyPopupOpen == true {
                return
            }
            // Stronger feedback on the DONE-icon hover than on the
            // cell as a whole — this is an actionable target, so
            // a double-thunk announces "you've armed something
            // committable" the moment the cursor crosses in.
            //
            // No OFF→ON transition guard: NSTrackingArea sometimes
            // drops a `mouseExited` on fast cursor moves, leaving
            // `isIconHovered` stuck at `true`, which would silence
            // every subsequent hover. The natural debounce here
            // is the system's tracking-area enter event itself —
            // it doesn't refire while the cursor stays inside.
            // Still gated on scroll state so drive-by hovers
            // during a fling stay quiet.
            if hovered, !ScrollStateObserver.isScrollingNow {
                Haptics.taskAction()
            }
            self.isIconHovered = hovered
            self.recomputeCheckboxHovered()
        }
        checkboxHoverZone.onClick = { [weak self] in
            self?.commitDoneAction()
        }

        // Re-stack the subtask pill + its hit zone ON TOP
        // of every other subview so hit-testing reaches
        // them first. Without this the (later-added)
        // titleLabel covers the click area and swallows
        // the click before it gets to the hit zone.
        expandPill.removeFromSuperview()
        expandHitZone.removeFromSuperview()
        addSubview(expandPill)
        addSubview(expandHitZone)
    }

    // MARK: Tracking area lifecycle

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // NSCollectionView calls `updateTrackingAreas()`
        // every layout pass — many times per scroll. The
        // resulting `removeTrackingArea` + `addTrackingArea`
        // churn shows up as a measurable scroll-tick cost.
        // Skip the rebuild when the existing area still
        // covers the same `bounds` — `.inVisibleRect`
        // already keeps it pinned to the visible area, so
        // a bounds-equal area is exactly what we'd be
        // re-creating.
        if let existing = cellTrackingArea,
           existing.rect == bounds {
            return
        }
        if let a = cellTrackingArea { removeTrackingArea(a) }

        // Cell-wide hover for the shadow boost. `.inVisibleRect`
        // auto-tracks the cell's visible area regardless of
        // bounds changes — appropriate here since we genuinely
        // want the whole cell. (The checkbox sub-zone uses its
        // OWN HoverZoneView with its own tracking area, so the
        // two never conflict.)
        let cellArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: ["zone": "cell"]
        )
        addTrackingArea(cellArea)
        cellTrackingArea = cellArea
    }

    override func mouseEntered(with event: NSEvent) {
        // Suppress hover state changes during a live scroll.
        guard !ScrollStateObserver.isScrollingNow else { return }
        // Only the cell-wide tracking area lives here now —
        // checkbox hover is owned by `checkboxHoverZone`.
        if (event.trackingArea?.userInfo as? [String: String])?["zone"] == "cell" {
            setHovered(true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if (event.trackingArea?.userInfo as? [String: String])?["zone"] == "cell" {
            setHovered(false)
        }
    }

    // MARK: Hover state → visual transitions

    @objc private func scrollDidStart() {
        // Clear any latent hover state on the cell that was set
        // BEFORE the scroll began. Pairs with the
        // `mouseEntered` suppression during scroll so cells
        // never end up with a stuck DONE pill or boosted halo.
        if isHovered {
            isHovered = false
            animateShadowBoost(boosted: false)
            updateScale()
        }
        if isPressed {
            isPressed = false
            updateScale()
        }
        if isCheckboxHovered || isIconHovered || isPillHovered {
            isIconHovered = false
            isPillHovered = false
            isCheckboxHovered = false
            // Hard reset (no animation) — during scroll the
            // disappearance shouldn't compete with the layer
            // translation.
            donePill.resetHidden()
            resetContentSlide()
        }
        // Rasterize the cell's layer during live scroll —
        // CoreAnimation captures the cell's contents (text +
        // pill + shadow + bg) into a single bitmap once,
        // then translates that bitmap as the user scrolls.
        // Without rasterization, every subview / sublayer
        // recomposites per frame, which adds up across ~30
        // visible cells. `rasterizationScale` matches the
        // backing display so Retina text stays crisp.
        if let layer {
            layer.rasterizationScale = window?.backingScaleFactor ?? 2.0
            layer.shouldRasterize = true
        }
    }

    /// Drop every hover-derived visual immediately. Called
    /// when `appState.anyPopupOpen` flips `true` — popups
    /// must leave the content behind them inert, including
    /// any cells the cursor was already over when the
    /// popup opened (their `mouseExited` won't fire because
    /// the cursor didn't actually leave the cell — the
    /// popup just landed on top of it).
    ///
    /// Mirrors the cleanup in `scrollDidStart` since the
    /// "user is no longer interacting with this row" state
    /// is the same in both cases.
    private func forceExitAllHover() {
        if isHovered {
            isHovered = false
            animateShadowBoost(boosted: false)
            updateScale()
        }
        if isPressed {
            isPressed = false
            updateScale()
        }
        if isCheckboxHovered || isIconHovered || isPillHovered {
            isIconHovered = false
            isPillHovered = false
            isCheckboxHovered = false
            donePill.resetHidden()
            resetContentSlide()
        }
    }

    @objc private func scrollDidEnd() {
        // Drop rasterization once the scroll settles so
        // future state changes (hover halo, shadow boost,
        // status pill swaps, etc.) render live again.
        // Holding the rasterized bitmap forever would freeze
        // those animations and pile up GPU memory.
        layer?.shouldRasterize = false
    }

    private func setHovered(_ value: Bool) {
        // Skip incoming HOVER while a popup is up. Hover
        // EXITs (value=false) still pass through so any
        // pre-popup hover gets cleared cleanly.
        if value, appState?.anyPopupOpen == true { return }
        guard value != isHovered else { return }
        isHovered = value
        // No cell-hover haptic — sweeping the cursor across the
        // list machine-guns pulses and reads as noise. Hover
        // feedback is reserved for the DONE icon (an actionable
        // target), which still pulses via `checkboxHoverZone`.
        animateShadowBoost(boosted: value)
        updateScale()
    }

    private func updateScale() {
        let duration: TimeInterval = isPressed ? 0.10 : 0.25
        applyTransform(animated: true, duration: duration, timingName: .easeOut)
    }

    private var currentScaleValue: CGFloat {
        if isPressed { return 0.97 }
        if isHovered { return 1.01 }
        return 1.0
    }

    /// Single source of truth for the row card's transform.
    /// Combines hover/press scale with the swipe translation,
    /// so the two never fight over `layer.transform`.
    private func applyTransform(animated: Bool,
                                duration: TimeInterval = 0,
                                timingName: CAMediaTimingFunctionName = .easeOut) {
        guard let layer = self.layer else { return }
        let scale = currentScaleValue
        let target = CATransform3DConcat(
            CATransform3DMakeScale(scale, scale, 1),
            CATransform3DMakeTranslation(swipeOffset, 0, 0)
        )
        if animated {
            let anim = CABasicAnimation(keyPath: "transform")
            anim.fromValue = NSValue(caTransform3D:
                layer.presentation()?.transform ?? layer.transform)
            anim.toValue   = NSValue(caTransform3D: target)
            anim.duration  = duration
            anim.timingFunction = CAMediaTimingFunction(name: timingName)
            layer.add(anim, forKey: "transform")
        } else {
            // Disable implicit animations for direct sets so
            // per-frame swipe updates don't queue 60 anims/sec.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAnimation(forKey: "transform")
            CATransaction.commit()
        }
        layer.transform = target
    }

    private func recomputeCheckboxHovered() {
        if isIconHovered && ScrollStateObserver.isScrollingNow { return }
        guard isIconHovered != isCheckboxHovered else { return }
        isCheckboxHovered = isIconHovered
        animateDonePill(visible: isIconHovered)
        animateContentSlide(toRight: isIconHovered)
    }

    /// Animate `titleLabel`, `statusPill`, `expandPill`,
    /// `expandHitZone`, and `assigneeLabel` translating
    /// along X via CALayer transforms — purely visual,
    /// doesn't disturb the row's layout. Same spring-like
    /// curve as the DONE pill's `appear()` so the slide
    /// and the pill reveal feel like one synchronised
    /// motion.
    ///
    /// The subtask pill rides the same translation as the
    /// status pill it sits next to so the pair shifts as a
    /// unit when the DONE pill takes over the checkbox
    /// slot — without this, hovering the DONE pill left
    /// the subtask pill stranded behind it.
    private func animateContentSlide(toRight: Bool) {
        let dx: CGFloat = toRight ? 66 : 0
        let target = CATransform3DMakeTranslation(dx, 0, 0)
        let timing = CAMediaTimingFunction(controlPoints: 0.30, 1.4, 0.50, 1.0)
        let duration = 0.30

        let sliding: [NSView] = [
            titleLabel, statusPill, expandPill,
            expandHitZone, assigneeLabel,
        ]
        for view in sliding {
            guard let layer = view.layer else { continue }
            let anim = CABasicAnimation(keyPath: "transform")
            anim.fromValue = NSValue(caTransform3D:
                layer.presentation()?.transform ?? layer.transform)
            anim.toValue   = NSValue(caTransform3D: target)
            anim.duration  = duration
            anim.timingFunction = timing
            layer.add(anim, forKey: "slide")
            layer.transform = target
        }
    }

    /// Hard reset for the slide transforms — used on cell
    /// recycle (`bind`) and on scroll start so a recycled cell
    /// doesn't inherit the previous task's mid-slide position.
    private func resetContentSlide() {
        let sliding: [NSView] = [
            titleLabel, statusPill, expandPill,
            expandHitZone, assigneeLabel,
        ]
        for view in sliding {
            view.layer?.removeAnimation(forKey: "slide")
            view.layer?.transform = CATransform3DIdentity
        }
    }

    /// Animate the shadow's opacity, radius AND vertical offset
    /// between base (per-scheme) and a boosted state. The
    /// offset bumps proportionally with the radius (2 → 4) so
    /// the boosted shadow stays visually anchored BELOW the
    /// cell — matching the static shadow's "slightly downward"
    /// alignment instead of growing symmetrically (which read
    /// as "shadow recentred upward" on hover).
    private func animateShadowBoost(boosted: Bool) {
        guard let layer = self.layer else { return }
        // Dark-mode shadow opacities cut 35% per design tweak
        // (0.36 → 0.234, 0.55 → 0.3575). Light-mode values
        // unchanged.
        let baseOp:     Float   = cachedScheme == .dark ? 0.234  : 0.24
        let boostOp:    Float   = cachedScheme == .dark ? 0.3575 : 0.40
        let baseRad:    CGFloat = 3
        let boostRad:   CGFloat = 6
        let baseOffY:   CGFloat = 2
        let boostOffY:  CGFloat = 4
        let targetOp   = boosted ? boostOp   : baseOp
        let targetRad  = boosted ? boostRad  : baseRad
        let targetOffY = boosted ? boostOffY : baseOffY

        let opAnim = CABasicAnimation(keyPath: "shadowOpacity")
        opAnim.fromValue = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity
        opAnim.toValue   = targetOp
        opAnim.duration  = 0.25
        opAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(opAnim, forKey: "shadowOpacity")
        layer.shadowOpacity = targetOp

        let radAnim = CABasicAnimation(keyPath: "shadowRadius")
        radAnim.fromValue = layer.presentation()?.shadowRadius ?? layer.shadowRadius
        radAnim.toValue   = targetRad
        radAnim.duration  = 0.25
        radAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(radAnim, forKey: "shadowRadius")
        layer.shadowRadius = targetRad

        let offAnim = CABasicAnimation(keyPath: "shadowOffset")
        offAnim.fromValue = NSValue(size:
            layer.presentation()?.shadowOffset ?? layer.shadowOffset)
        offAnim.toValue   = NSValue(size: CGSize(width: 0, height: targetOffY))
        offAnim.duration  = 0.25
        offAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(offAnim, forKey: "shadowOffset")
        layer.shadowOffset = CGSize(width: 0, height: targetOffY)
    }

    /// Reveal/hide the DONE pill via `DonePillView`'s built-in
    /// scale + opacity animation (mirrors the SwiftUI
    /// `.transition(.scale(scale: 0.85, anchor: .leading)
    /// .combined(with: .opacity))`).
    private func animateDonePill(visible: Bool) {
        if visible {
            donePill.appear()
        } else {
            donePill.disappear()
        }
    }

    // MARK: Bind

    func bind(task: CUTask,
              appState: AppState,
              depth: Int = 0,
              hasChildren: Bool = false,
              isExpanded: Bool = false) {
        self.task     = task
        self.appState = appState
        self.depth        = depth
        self.hasChildren  = hasChildren
        self.isExpanded   = isExpanded

        // Watch for any popup opening — when it does, drop
        // every hover-derived visual on this cell so the
        // row behind the popup reads as inert. Doing it
        // here (per cell) is the right layer because
        // SwiftUI's `.allowsHitTesting(!anyPopupOpen)` on
        // the dashboard doesn't reach the AppKit
        // `NSTrackingArea`s these cells own — those fire
        // independently as long as the window is key.
        //
        // Subscribe ONCE per view lifetime, not on every
        // `bind`. NSCollectionView calls bind on every
        // recycle (so during a vertical scroll, every
        // newly-visible cell gets a fresh bind), which used
        // to rip down + rebuild this Combine pipeline per
        // recycle. Apollo only has a single `AppState`
        // instance, so the closure's captured reference
        // never goes stale, and re-subscribing wasn't
        // adding any value — just allocations and an
        // immediate sink-replay during a scroll burst.
        if anyPopupCancellable == nil {
            anyPopupCancellable = appState.$anyPopupOpen
                .receive(on: RunLoop.main)
                .sink { [weak self] open in
                    guard let self else { return }
                    if open { self.forceExitAllHover() }
                }
        }
        // Compact mode: subtask rows in the main list drop
        // the meta row (assignee/date/priority) and shrink
        // to ~40pt — visually distinct from top-level tasks
        // and matches the compact subtask layout used
        // inside the task detail popup. The status pill
        // stays as a read-only badge (its dropdown action
        // is suppressed below).
        let compact = depth > 0
        assigneeLabel.isHidden = compact
        dateIcon.isHidden      = compact
        dateLabel.isHidden     = compact
        priorityIcon.isHidden  = compact
        statusPill.isReadOnly  = compact
        // Dot-mode in compact rows — colour-only badge, no
        // status name. Top-level rows keep the textual pill.
        statusPill.dotMode     = compact
        // Subtask rows REPLACE the DONE checkbox with the
        // status-colour dot (the dot lives on the LEFT
        // where the checkbox normally sits). Hide the
        // checkbox icon + its hover zone so the row reads
        // as "indicator + title", not "click-to-done".
        checkboxIcon.isHidden     = compact
        checkboxHoverZone.isHidden = compact
        // Hide the subtask pill + its hit zone when the
        // task has no children; when it does, hand the
        // pill the task's status colour so it picks up
        // the row's existing accent (orange for DOING,
        // purple for REVIEW, etc.) and toggle its
        // expanded state.
        expandPill.isHidden    = !hasChildren
        expandHitZone.isHidden = !hasChildren
        if hasChildren {
            expandPill.tint = NSColor(Color(hex: task.statusDisplayHex))
        }
        expandPill.isExpanded = isExpanded
        self.cachedStatusHex = task.statusDisplayHex
        // Reset transient hover state so a recycled cell doesn't
        // inherit a leftover hover halo / DONE pill from the
        // previous task. CRITICAL: cancel any in-flight Core
        // Animation actions on the pill BEFORE setting alpha
        // back to 0 — without this a mid-fade animation
        // started by a previous cursor enter (just before the
        // cell was recycled) keeps running and lands the pill
        // at alpha 1 even though we've reset the @State.
        layer?.removeAnimation(forKey: "shadowOpacity")
        layer?.removeAnimation(forKey: "shadowRadius")
        layer?.removeAnimation(forKey: "shadowOffset")
        layer?.removeAnimation(forKey: "scale")
        layer?.removeAnimation(forKey: "transform")
        layer?.transform = CATransform3DIdentity
        // Reset shadow params to base so a recycled cell starts
        // with the static shadow geometry (not the boosted hover
        // values frozen on the previous task).
        layer?.shadowRadius = 3
        layer?.shadowOffset = CGSize(width: 0, height: 2)
        isHovered = false
        isIconHovered = false
        isPillHovered = false
        isCheckboxHovered = false
        isPressed = false
        swipeOffset = 0
        swipeAccumulated = 0
        swipeAxisLocked = nil
        onSwipeProgress?(0, 0)
        donePill.resetHidden()
        resetContentSlide()
        applyAppearance()
        configureDonePill()
        // Compact-mode override — must run AFTER
        // applyAppearance() because that method unhides
        // dateIcon/dateLabel/priorityIcon based on task data.
        if compact {
            assigneeLabel.isHidden = true
            dateIcon.isHidden      = true
            dateLabel.isHidden     = true
            priorityIcon.isHidden  = true
        }
        needsLayout = true
    }

    /// Resolve the DONE target status for the current task and
    /// pre-build the pill's label + colour so it's ready to
    /// reveal on hover. The pill stays alpha-0 until the user
    /// hovers the checkbox.
    private func configureDonePill() {
        guard let task, let appState else {
            donePill.isHidden = true
            return
        }
        // Pick the workflow's "next" status — same fallback
        // chain SwiftUI's `doneTargetStatus` uses.
        let target: CUStatus? =
            appState.doneTargetByStatus[task.status]
            ?? appState.doneTargetFallback
        if let target {
            donePill.isHidden = false
            donePill.configure(
                label: target.status.uppercased(),
                hex:   target.displayHex
            )
            donePill.onClick = { [weak self] in
                guard let self, let task = self.task,
                      let appState = self.appState else { return }
                // No click haptic — the trackpad's click pulse is
                // the action's natural feedback.
                Task { await appState.updateTaskStatus(task, to: target) }
            }
        } else {
            // No target → no pill (e.g. terminal status).
            donePill.isHidden = true
        }
    }

    // MARK: Appearance application

    private func applyAppearance() {
        guard let task else { return }
        let scheme: ColorScheme =
            (effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            ? .dark : .light
        cachedScheme = scheme

        // Card background (rowFill) — same cache the SwiftUI row uses.
        let bgColor = NSColor(Color.rowFill(forBaseHex: cachedStatusHex,
                                            scheme: scheme))
        layer?.backgroundColor = bgColor.cgColor

        // Drop shadow — same shadowTint cache. Always on now;
        // the historical "suppressed when expanded" branch
        // was for a separate halo decoration that's no longer
        // part of the architecture (subtasks live inside the
        // pill, so the pill IS the whole shape).
        let shadowColor = NSColor(Color.shadowTint(forBaseHex: cachedStatusHex,
                                                   scheme: scheme))
        layer?.shadowColor   = shadowColor.cgColor
        layer?.shadowOpacity = scheme == .dark ? 0.234 : 0.24

        // Checkbox icon
        let checkSymbol = task.isCompleted ? "checkmark.circle.fill" : "circle"
        checkboxIcon.image = NSImage(systemSymbolName: checkSymbol,
                                     accessibilityDescription: nil)
        checkboxIcon.contentTintColor = task.isCompleted
            ? NSColor(Color(hex: cachedStatusHex))
            : NSColor.secondaryLabelColor

        // Title — strikethrough + tertiary colour when completed
        // (SwiftUI applies via the title group's modifier chain).
        if task.isCompleted {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14.95, weight: .semibold),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: NSColor.tertiaryLabelColor,
            ]
            titleLabel.attributedStringValue = NSAttributedString(
                string: task.title, attributes: attrs
            )
        } else {
            titleLabel.stringValue = task.title
            titleLabel.textColor   = .labelColor
        }

        // Status pill
        statusPill.configure(label: task.status.uppercased(),
                             hex:   cachedStatusHex)

        // Assignee — parsed first name (matches SwiftUI's
        // recomputeAssigneeFirstName)
        assigneeLabel.stringValue = Self.firstName(for: task)

        // Date — relative ("Hoje", "Amanhã", "em N dias",
        // "N dias atrás", or short formatted date)
        if let due = task.dueDate {
            let overdue = due < Date() && !task.isCompleted
            let color: NSColor = overdue ? .systemRed : .secondaryLabelColor
            dateLabel.stringValue       = Self.relativeDateText(for: due)
            dateLabel.textColor         = color
            dateIcon.contentTintColor   = color
            dateIcon.isHidden  = false
            dateLabel.isHidden = false
        } else {
            dateLabel.stringValue = ""
            dateIcon.isHidden  = true
            dateLabel.isHidden = true
        }

        // Priority flag — only show if priority > 0
        if task.priority > 0 {
            priorityIcon.contentTintColor = NSColor(Color(hex: task.priorityHex))
            priorityIcon.isHidden = false
        } else {
            priorityIcon.isHidden = true
        }
    }

    /// Parse a friendly first-name token from the assignee's
    /// username. Matches the SwiftUI row's `recomputeAssigneeFirstName`.
    private static func firstName(for task: CUTask) -> String {
        guard let raw = task.assignees.first?.username,
              !raw.trimmingCharacters(in: .whitespaces).isEmpty
        else { return "" }
        let beforeAt = raw.split(separator: "@").first.map(String.init) ?? raw
        let firstToken = beforeAt
            .split(whereSeparator: { $0 == " " || $0 == "." })
            .first
            .map(String.init) ?? beforeAt
        guard let initial = firstToken.first else { return "" }
        return String(initial).uppercased() + firstToken.dropFirst().lowercased()
    }

    /// Mirror `TaskRowView.relativeDateText(for:)` so the date
    /// reads identically: "Hoje", "Amanhã", "Ontem", "em N dias",
    /// "N dias atrás", or short formatted date for distant dates.
    private static func relativeDateText(for date: Date) -> String {
        let cal = Calendar.current
        let today  = cal.startOfDay(for: Date())
        let target = cal.startOfDay(for: date)
        let days = cal.dateComponents([.day], from: today, to: target).day ?? 0
        switch days {
        case 0:           return "Hoje"
        case 1:           return "Amanhã"
        case -1:          return "Ontem"
        case 2...6:       return "em \(days) dias"
        case -6 ... -2:   return "\(-days) dias atrás"
        default:          return SharedDateFormatters.shortDayMonthPTBR.string(from: date)
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let w = bounds.width
        // Per-row indent for nested subtask rows. depth=0
        // gives the original layout; deeper rows shift right
        // by `depth * subtaskIndent` so the hierarchy is
        // visually obvious.
        let indent = CGFloat(depth) * subtaskIndent
        let compact = depth > 0

        // Pin the drop-shadow shape to the live bounds.
        // Without an explicit `shadowPath`, CoreAnimation
        // falls back to deriving the shadow from the
        // layer's alpha mask, which (a) is more expensive
        // and (b) sometimes paints a wider/duplicated band
        // when the layer's frame changes — that was the
        // visual artifact under "Teste / SUB TESTE" where
        // a phantom shadow leaked rightward past the card.
        // Setting the path explicitly anchors it to the
        // exact rounded rectangle we render.
        //
        // `CATransaction.setDisableActions(true)` suppresses
        // the implicit `shadowPath` animation CoreAnimation
        // would otherwise queue every time `layout()` runs.
        // During a scroll, every visible cell re-lays out
        // per tick — three or four implicit shadow
        // animations stacked behind the explicit hover-
        // boost ones used to fight for the same property
        // and cause visible post-scroll hitches.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth:  18,
            cornerHeight: 18,
            transform:    nil
        )
        CATransaction.commit()

        // ── Title row (top) ──────────────────────────────────
        // titleLabel on top; checkboxIcon vertically centred
        // in the PARENT-CONTENT area (the first
        // `parentRowHeight` pt of the cell) — NOT the whole
        // cell — `bounds.height` is now stable per cell type
        // (78pt for parents, 40pt for subtasks).
        let checkY = (bounds.height - checkSize) / 2
        let checkX = leadingPad + indent
        checkboxIcon.frame = NSRect(
            x: checkX,
            y: checkY,
            width:  checkSize,
            height: checkSize
        )
        // Place the checkbox HOVER ZONE here too — must run
        // BEFORE the compact-mode early return below or
        // subtask rows would inherit a stale (zero) frame
        // for the hit zone and the DONE click would silently
        // miss its target.
        checkboxHoverZone.frame = NSRect(
            x: checkX,
            y: checkY,
            width:  checkSize,
            height: checkSize
        )

        // Compact subtask layout — single horizontal line:
        //   status-dot (replaces DONE checkbox) | title | chevron
        // No status pill on the right, no meta row below.
        if compact {
            statusPill.sizeToFitContent()
            let dotSize = statusPill.frame.size  // 10×10 in dotMode
            // Dot replaces the checkbox at the LEADING
            // edge — same x slot the unchecked circle used
            // to occupy on top-level rows, so subtasks
            // line up vertically with their parent's
            // checkbox column.
            let dotSlotX = leadingPad + indent
            statusPill.frame = NSRect(
                x: dotSlotX + (checkSize - dotSize.width) / 2,
                y: (bounds.height - dotSize.height) / 2,
                width:  dotSize.width,
                height: dotSize.height
            )
            // Title fills the gap between the dot slot and
            // the chevron (or the cell's right edge when no
            // chevron is shown).
            let titleX = dotSlotX + checkSize + titleGroupSpacing
            // No top-right reservation needed any more —
            // the subtask pill now lives on the meta row
            // next to the status dot, not in the top-right.
            let titleRightInset: CGFloat = leadingPad
            let titleAvailable = max(0, w - titleX - titleRightInset)
            titleLabel.frame = NSRect(
                x: titleX,
                y: (bounds.height - titleHeight) / 2,
                width:  titleAvailable,
                height: titleHeight
            )
            // In the compact subtask branch the status
            // affordance is a dot (no meta row), so place
            // the subtask pill right after the dot.
            let subPillSize = SubtaskExpandPill.intrinsicSize
            let subPillGap: CGFloat = 5
            let subPillX = dotSlotX + checkSize + subPillGap
            let subPillY = (bounds.height - subPillSize.height) / 2
            let subPillFrame = NSRect(
                x: subPillX, y: subPillY,
                width:  subPillSize.width,
                height: subPillSize.height
            )
            expandPill.frame    = subPillFrame
            expandHitZone.frame = subPillFrame
            return
        }

        // ── Subtask expand pill (next to status) ─────────────
        // Static icon-only capsule placed immediately after
        // the row's status pill on the meta line. Same
        // vertical centre as the status pill so the two
        // read as a paired affordance. The transparent
        // `expandHitZone` matches the pill bounds — taps
        // anywhere on the capsule toggle expansion.
        // (Hidden in `bind` when the task has no children.)
        let subPillSize = SubtaskExpandPill.intrinsicSize
        let subPillGap: CGFloat = 5
        let subPillX = statusPill.frame.maxX + subPillGap
        // Centre on the status pill's vertical midpoint so
        // the two capsules share an optical baseline even
        // when their heights differ by a pixel or two.
        let subPillY = statusPill.frame.midY - subPillSize.height / 2
        let subPillFrame = NSRect(
            x: subPillX, y: subPillY,
            width:  subPillSize.width,
            height: subPillSize.height
        )
        expandPill.frame    = subPillFrame
        expandHitZone.frame = subPillFrame

        // Both title AND meta row share the same leading edge —
        // mirrors the SwiftUI structure where `.padding(.leading, 10)`
        // is applied to the VStack that wraps both, indenting them
        // together by `metaNudge` past the checkbox+spacing. Without
        // this the status pill rendered 10pt to the right of the
        // title, breaking the visual column alignment.
        let titleX = leadingPad + indent + checkSize + titleGroupSpacing + metaNudge
        let titleAvailable = max(0, w - titleX - leadingPad)
        titleLabel.frame = NSRect(
            x: titleX,
            y: verticalPad,
            width:  titleAvailable,
            height: titleHeight
        )

        // ── Meta row (below title) ───────────────────────────
        // statusPill (in a 168pt slot) | assignee | …spacer… | date | priority
        let metaY = verticalPad + titleHeight + titleMetaGap
        // Same X as the title — the SwiftUI VStack's leading
        // padding applies to both rows.
        let metaLeading = titleX

        // Status pill — sized to its content but positioned at
        // the slot's leading edge. The slot itself is 168pt
        // wide; the assignee is positioned RELATIVE TO THE SLOT
        // (not the pill), matching SwiftUI's `.frame(width:168)`.
        statusPill.sizeToFitContent()
        let pillSize = statusPill.frame.size
        statusPill.frame = NSRect(
            x: metaLeading,
            y: metaY + (metaHeight - pillSize.height) / 2,
            width:  pillSize.width,
            height: pillSize.height
        )

        // Assignee — positioned at slot.trailing + spacing(4) + nudge(-30)
        assigneeLabel.sizeToFit()
        let assigneeSize = assigneeLabel.frame.size
        let assigneeX = metaLeading + statusSlotWidth + metaSpacing + assigneeNudge
        assigneeLabel.frame = NSRect(
            x: assigneeX,
            y: metaY + (metaHeight - assigneeSize.height) / 2,
            width:  assigneeSize.width,
            height: assigneeSize.height
        )

        // Priority flag (right-anchored)
        priorityIcon.frame = NSRect(
            x: w - leadingPad - prioritySlot,
            y: metaY + (metaHeight - prioritySlot) / 2,
            width:  prioritySlot,
            height: prioritySlot
        )

        // Date (left of priority): calendar icon + label, spacing 3pt
        if !dateLabel.isHidden {
            dateLabel.sizeToFit()
            let dateSize = dateLabel.frame.size
            let iconSize: CGFloat = 9   // matches SwiftUI 9pt size
            let totalDateWidth = iconSize + 3 + dateSize.width
            let dateGroupX = (w - leadingPad - prioritySlot) - 8 - totalDateWidth
            dateIcon.frame = NSRect(
                x: dateGroupX,
                y: metaY + (metaHeight - iconSize) / 2,
                width:  iconSize,
                height: iconSize
            )
            dateLabel.frame = NSRect(
                x: dateGroupX + iconSize + 3,
                y: metaY + (metaHeight - dateSize.height) / 2,
                width:  dateSize.width,
                height: dateSize.height
            )
        }

        // (Hover zone frame already set near the top of
        // layout() — see the `checkX` block — so it's
        // populated for both regular and compact rows.)

        // DONE pill — anchored at the same X as the checkbox
        // icon (so its leading edge sits over the icon when
        // revealed) and centred vertically in the PARENT
        // content area (NOT the full cell). Same reasoning as
        // the checkbox positioning above: a tall expanded
        // cell shouldn't push the DONE pill down into the
        // subtask area.
        if !donePill.isHidden {
            donePill.sizeToFitContent()
            let pillSize = donePill.frame.size
            donePill.frame = NSRect(
                x: leadingPad,
                y: (bounds.height - pillSize.height) / 2,
                width:  pillSize.width,
                height: pillSize.height
            )
        }

        // Explicit shadow path — matches the rounded card shape
        // and avoids CoreAnimation having to compute the shadow
        // from the layer's alpha (slow + the alpha is just a
        // single solid rounded rect anyway, which won't include
        // any of the content's contribution the way SwiftUI's
        // `.shadow` does). Pinning the path also lets the shadow
        // diffuse properly past the rounded corners instead of
        // the slight CALayer pinching that an alpha-derived
        // shadow can show.
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: 18,
            cornerHeight: 18,
            transform: nil
        )
    }

    // Re-apply colours when system theme switches.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }
}

// MARK: - Status pill

/// Capsule with status-coloured stroke + tinted fill + 10pt bold
/// label + 7pt chevron. Matches the SwiftUI `statusBadge` static
/// visual exactly. The dropdown popover is added in phase 2.
final class StatusPillView: NSView {
    override var isFlipped: Bool { true }

    private let label = NSTextField(labelWithString: "")
    private let chevronIcon = NSImageView()
    private var hex: String = "#87909E"

    /// Fires on mousedown anywhere on the pill. The cell wires
    /// this to a callback that opens the status-picker popover
    /// anchored to this view.
    var onClick: (() -> Void)?

    /// When true, the pill is purely visual: the dropdown
    /// chevron is hidden and clicks fall through to the
    /// row's tap-to-open handler (no status-picker popover).
    /// Subtask rows in the main list use this so the pill
    /// reads as a read-only badge — matching the compact
    /// subtask design in the task detail popup.
    var isReadOnly: Bool = false {
        didSet {
            chevronIcon.isHidden = isReadOnly
            needsLayout = true
        }
    }
    /// When true, the pill collapses to a small filled
    /// circle (the status colour), no text, no chevron —
    /// the colour alone communicates the status. Used on
    /// subtask rows in the main list per the user's
    /// request: "as cores ja indicam, nao precisa colocar
    /// o nome da categoria".
    var dotMode: Bool = false {
        didSet {
            label.isHidden = dotMode
            chevronIcon.isHidden = dotMode || isReadOnly
            needsLayout = true
        }
    }

    /// `mouseDown` consumed here so the click does NOT bubble
    /// up to TaskRowContentView's `mouseDown` (which would open
    /// the detail popup instead of the picker). On read-only
    /// pills we DON'T consume — letting the click bubble to
    /// the row opens the task detail popup, which is the
    /// expected affordance for subtask rows.
    override func mouseDown(with event: NSEvent) {
        if isReadOnly {
            super.mouseDown(with: event)
            return
        }
        onClick?()
    }

    /// `mouseUp` MUST be consumed for clickable pills. On
    /// read-only pills (subtask rows), let it bubble so the
    /// row's tap-to-open-detail handler fires.
    override func mouseUp(with event: NSEvent) {
        if isReadOnly { super.mouseUp(with: event) }
        // else: consumed
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve  = .continuous
        layer?.borderWidth  = 1

        // SwiftUI: .font(.system(size: 10, weight: .bold))
        label.font  = NSFont.systemFont(ofSize: 10, weight: .bold)
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.cell?.lineBreakMode = .byTruncatingTail
        label.lineBreakMode = .byTruncatingTail
        label.drawsBackground = false
        label.isBordered = false
        label.isBezeled = false
        addSubview(label)

        // SwiftUI: .font(.system(size: 7, weight: .bold)).opacity(0.7)
        chevronIcon.image = NSImage(systemSymbolName: "chevron.down",
                                    accessibilityDescription: nil)
        chevronIcon.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 7, weight: .bold
        )
        chevronIcon.imageScaling = .scaleProportionallyUpOrDown
        chevronIcon.alphaValue = 0.7
        addSubview(chevronIcon)
    }

    /// Resize self to its label's natural width + padding.
    /// Caller must call this BEFORE positioning the pill so
    /// `frame.size` reflects the current label text. When
    /// `isReadOnly` is true the pill drops the chevron slot
    /// so it shrinks to just text + horizontal padding (the
    /// compact subtask-row look). When `dotMode` is true
    /// the pill collapses to a 10×10 colour dot.
    func sizeToFitContent() {
        if dotMode {
            let d: CGFloat = 10
            frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: d, height: d)
            layer?.cornerRadius = d / 2
            return
        }
        label.sizeToFit()
        // SwiftUI: .padding(.horizontal, 8) .padding(.vertical, 3)
        // HStack(spacing: 4) — text + chevron (chevron hidden
        // in read-only mode).
        let chev: CGFloat = 7
        let chevSlot: CGFloat = isReadOnly ? 0 : (4 + chev)
        let w = 8 + label.frame.width + chevSlot + 8
        let h = label.frame.height + 6
        frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: w, height: h)
        // Match capsule corner to live height
        layer?.cornerRadius = h / 2
    }

    func configure(label text: String, hex: String) {
        self.hex = hex
        self.label.stringValue = text
        let color = NSColor(Color(hex: hex))
        // SwiftUI: .foregroundStyle(color)
        self.label.textColor              = color
        self.chevronIcon.contentTintColor = color
        if dotMode {
            // Dot mode: solid filled circle, no border, no
            // tinted-translucent fill — just the status
            // colour as a small indicator.
            self.layer?.borderWidth     = 0
            self.layer?.backgroundColor = color.cgColor
        } else {
            // SwiftUI: .overlay(Capsule().strokeBorder(color.opacity(0.55), lineWidth: 1))
            self.layer?.borderWidth     = 1
            self.layer?.borderColor     = color.withAlphaComponent(0.55).cgColor
            // SwiftUI: .background(color.opacity(0.10), in: Capsule())
            self.layer?.backgroundColor = color.withAlphaComponent(0.10).cgColor
        }
        label.sizeToFit()
        layer?.cornerRadius = (label.frame.height + 6) / 2
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        label.sizeToFit()
        let labelSize = label.frame.size
        // SwiftUI: HStack(spacing: 4) — text 8H pad on left, then label, +4 spacing, then chevron, then 8H pad
        label.frame = NSRect(
            x: 8,
            y: (h - labelSize.height) / 2,
            width:  labelSize.width,
            height: labelSize.height
        )
        let chev: CGFloat = 7
        chevronIcon.frame = NSRect(
            x: label.frame.maxX + 4,
            y: (h - chev) / 2,
            width:  chev,
            height: chev
        )
    }
}

// MARK: - DONE pill (revealed on checkbox hover)

/// Simple, predictable visual:
///   • Translucent dark/light background (no NSVisualEffectView,
///     so no surprises from layer/flipped interaction).
///   • Single 1.2pt status-coloured border.
///   • A thin solid white highlight at low alpha (no gradient
///     pattern image — that was rendering with weird tiling).
///   • Status-coloured label (matches SwiftUI).
///   • Black 12% drop shadow.
///
/// Reveal: scale 0.85→1.0 anchored on leading edge + opacity
/// fade. Hover tracking on the pill itself is OWNED by this
/// view (NSTrackingArea on its bounds), reported via
/// `onHoverChanged` — combined with the checkbox icon's own
/// hover area in the parent so the cursor never loses hover
/// while sliding from icon onto pill body.
final class DonePillView: NSView {
    /// Use top-down coords for the SUBVIEW layout (label
    /// position). The LAYER stays in default orientation —
    /// no `isGeometryFlipped` — so the scale-from-leading
    /// transform and the drop shadow render correctly.
    override var isFlipped: Bool { true }

    private let label = NSTextField(labelWithString: "")
    /// Dedicated tracking area on the pill's bounds so the
    /// cursor moving onto the pill body keeps the reveal alive
    /// even after the icon's own hover zone exits.
    private var hoverArea: NSTrackingArea?

    var onClick: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        // Scale anchor on the leading edge so the appear
        // animation grows out from the LEFT (matching SwiftUI's
        // `.scale(scale: 0.85, anchor: .leading)`).
        layer?.anchorPoint = CGPoint(x: 0, y: 0.5)

        // Drop shadow — black 12% / radius 4 / y 2.
        layer?.shadowColor   = NSColor.black.cgColor
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius  = 4
        layer?.shadowOffset  = CGSize(width: 0, height: 2)
        layer?.masksToBounds = false
        layer?.borderWidth   = 1.2

        label.font            = NSFont.systemFont(ofSize: 10, weight: .heavy)
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.cell?.lineBreakMode = .byTruncatingTail
        label.lineBreakMode   = .byTruncatingTail
        label.drawsBackground = false
        label.isBordered      = false
        label.isBezeled       = false
        addSubview(label)

        // Resting state: hidden + scaled down.
        layer?.opacity = 0
        layer?.transform = CATransform3DMakeScale(0.85, 0.85, 1)
    }

    func configure(label text: String, hex: String) {
        self.label.stringValue = text
        let color = NSColor(Color(hex: hex))
        self.label.textColor = color
        // Translucent fill matches the "ultraThinMaterial" feel
        // without the NSVisualEffectView complexity. A bit of
        // the status hue mixed in keeps the pill on-brand.
        layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(0.92).cgColor
        layer?.borderColor = color.cgColor
        label.sizeToFit()
        needsLayout = true
    }

    func sizeToFitContent() {
        label.sizeToFit()
        let labelSize = label.frame.size
        // 9pt H pad each side, 3pt V pad each side (matches
        // SwiftUI `.padding(.horizontal, 9) .padding(.vertical, 3)`).
        let w = 9 + labelSize.width + 9
        let h = labelSize.height + 6
        frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: w, height: h)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        label.sizeToFit()
        let labelSize = label.frame.size
        label.frame = NSRect(
            x: 9,
            y: (h - labelSize.height) / 2,
            width:  labelSize.width,
            height: labelSize.height
        )
        // Capsule corner radius matches half the height.
        layer?.cornerRadius = h / 2
        layer?.cornerCurve  = .continuous
        // Pin the shadow path to the capsule so it doesn't
        // diffuse from the bounding rectangle.
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: h / 2, cornerHeight: h / 2,
            transform: nil
        )
    }

    // MARK: Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // See `TaskRowContentView.updateTrackingAreas` for
        // the rationale on the bounds-equality short-
        // circuit — same scroll-tick churn fix.
        if let existing = hoverArea, existing.rect == bounds {
            return
        }
        if let a = hoverArea { removeTrackingArea(a) }
        let opts: NSTrackingArea.Options = [
            .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect
        ]
        let a = NSTrackingArea(rect: bounds, options: opts,
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        hoverArea = a
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }
    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    // MARK: Show / hide animations

    func appear() {
        guard let layer = self.layer else { return }
        layer.removeAllAnimations()

        let scaleAnim = CABasicAnimation(keyPath: "transform")
        scaleAnim.fromValue = NSValue(caTransform3D:
            CATransform3DMakeScale(0.85, 0.85, 1))
        scaleAnim.toValue   = NSValue(caTransform3D: CATransform3DIdentity)
        scaleAnim.duration  = 0.30
        scaleAnim.timingFunction = CAMediaTimingFunction(controlPoints: 0.30, 1.4, 0.50, 1.0)

        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = 0
        opacityAnim.toValue   = 1
        opacityAnim.duration  = 0.22
        opacityAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

        layer.add(scaleAnim,   forKey: "scale")
        layer.add(opacityAnim, forKey: "opacity")
        layer.transform = CATransform3DIdentity
        layer.opacity   = 1
    }

    func disappear() {
        guard let layer = self.layer else { return }
        layer.removeAllAnimations()

        let scaleAnim = CABasicAnimation(keyPath: "transform")
        scaleAnim.fromValue = NSValue(caTransform3D:
            layer.presentation()?.transform ?? CATransform3DIdentity)
        scaleAnim.toValue   = NSValue(caTransform3D:
            CATransform3DMakeScale(0.85, 0.85, 1))
        scaleAnim.duration  = 0.18
        scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeIn)

        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = layer.presentation()?.opacity ?? 1
        opacityAnim.toValue   = 0
        opacityAnim.duration  = 0.18
        opacityAnim.timingFunction = CAMediaTimingFunction(name: .easeIn)

        layer.add(scaleAnim,   forKey: "scale")
        layer.add(opacityAnim, forKey: "opacity")
        layer.transform = CATransform3DMakeScale(0.85, 0.85, 1)
        layer.opacity   = 0
    }

    func resetHidden() {
        layer?.removeAllAnimations()
        layer?.transform = CATransform3DMakeScale(0.85, 0.85, 1)
        layer?.opacity = 0
    }

    /// Purely visual — no clicks. The DONE action's click area
    /// is the checker icon ONLY (handled by `HoverZoneView`'s
    /// mouseDown). Returning nil from `hitTest` means clicks
    /// landing on the visible pill body fall through to whatever
    /// is below: HoverZoneView for the checker portion, the
    /// row's TaskRowContentView for the rest. Per user
    /// requirement: "click area = check area".
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Hover zone

/// Invisible NSView whose only job is to host an NSTrackingArea
/// covering its own bounds. Used by `TaskRowContentView` to
/// scope the DONE pill reveal to a precise sub-region of the
/// row WITHOUT relying on a custom-rect tracking area on the
/// parent (which AppKit can be unreliable about resizing as
/// the view bounds change). Clicks pass through to whatever's
/// behind via `hitTest` returning nil — the zone only catches
/// `mouseEntered`/`mouseExited`.
final class HoverZoneView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    private var area: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Bounds-equality short-circuit, same as the
        // sibling overrides in `TaskRowContentView` —
        // avoids per-scroll-tick `addTrackingArea` churn.
        if let existing = area, existing.rect == bounds {
            return
        }
        if let a = area { removeTrackingArea(a) }
        let opts: NSTrackingArea.Options = [
            .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect
        ]
        let a = NSTrackingArea(
            rect: bounds, options: opts, owner: self, userInfo: nil
        )
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    /// Capture clicks within the zone's bounds and route to
    /// `onClick`. With this, a click on the checker icon (the
    /// only thing this zone covers) fires the DONE action — and
    /// stops there: `mouseUp` is consumed so it doesn't bubble
    /// to the row's `mouseUp` (which would also open the detail
    /// popup).
    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
    override func mouseUp(with event: NSEvent) { /* consumed */ }
}

// MARK: - Chevron hit zone (subtask expand toggle)

/// Tiny click target that wraps the expand chevron at the
/// top-right of a task row. Owns its own mouseDown so the
/// click toggles expansion WITHOUT bubbling to the row's
/// tap-to-open-detail handler. Also exposes `onHoverChanged`
/// so the parent can flip the backdrop circle visibility on
/// hover (avoids painting a permanent halo at rest).
final class ChevronHitView: NSView {
    var onClick: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    override var isFlipped: Bool { true }

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Bounds-equality short-circuit — see
        // `TaskRowContentView.updateTrackingAreas`.
        if let existing = trackingArea, existing.rect == bounds {
            return
        }
        if let a = trackingArea { removeTrackingArea(a) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent)  { onHoverChanged?(false) }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
    override func mouseUp(with event: NSEvent) { /* consumed */ }
}

// MARK: - Subtask expand pill
//
// Compact icon-only capsule shown on parent rows that have
// subtasks. Sits IMMEDIATELY beside the row's status pill
// on the meta line — same vertical alignment, just a small
// trailing button you tap to expand/collapse the subtree.
//
// Visual:
//   • Capsule sized to 22×18 (icon centred, no label)
//   • Fill + border tinted with the task's status colour
//     (passed in via `tint`), matching the row's existing
//     colour language so DOING tasks get an orange pill,
//     REVIEW gets purple, etc.
//   • Two states — `isExpanded` ON ⇒ stronger fill +
//     full-accent icon; OFF ⇒ subtler fill + slightly
//     dimmer icon.
//
// Clicks are handled by the surrounding `ChevronHitView`
// (`expandHitZone`), which `TaskRowContentView` sizes to
// match the pill bounds. The pill itself is purely
// visual — no tracking area, no `mouseDown`. Other
// elements on the row (titleLabel, statusPill,
// assigneeLabel, expandPill) translate to the right when
// the user hovers the checkbox to reveal the DONE pill —
// see `animateContentSlide` in `TaskRowContentView`.
final class SubtaskExpandPill: NSView {

    private let iconView   = NSImageView()
    private let bgLayer    = CALayer()
    private let borderLayer = CALayer()

    var isExpanded: Bool = false {
        didSet {
            if oldValue != isExpanded { updateAppearance() }
        }
    }

    /// Status-coloured accent for the pill — set in `bind`
    /// from the task's `statusDisplayHex` so the pill
    /// inherits the row's existing colour language (orange
    /// for DOING, purple for REVIEW, etc.). Both collapsed
    /// and expanded states tint from this base; only the
    /// alpha intensity changes between the two.
    var tint: NSColor = .controlAccentColor {
        didSet {
            if oldValue != tint { updateAppearance() }
        }
    }

    /// Intrinsic capsule dimensions — laid out by
    /// `TaskRowContentView.layout()` at this fixed size.
    /// Matches the height of the status pill (~18pt) so
    /// the two sit on the same optical baseline.
    static let intrinsicSize = NSSize(width: 22, height: 18)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        bgLayer.cornerRadius = Self.intrinsicSize.height / 2
        bgLayer.cornerCurve  = .continuous
        bgLayer.masksToBounds = true
        layer?.addSublayer(bgLayer)

        borderLayer.cornerRadius = Self.intrinsicSize.height / 2
        borderLayer.cornerCurve  = .continuous
        borderLayer.borderWidth  = 0.5
        layer?.addSublayer(borderLayer)

        iconView.image = NSImage(
            systemSymbolName: "list.bullet.indent",
            accessibilityDescription: nil
        )
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 9, weight: .semibold
        )
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .secondaryLabelColor
        addSubview(iconView)

        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { Self.intrinsicSize }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bgLayer.frame    = bounds
        borderLayer.frame = bounds
        bgLayer.cornerRadius     = bounds.height / 2
        borderLayer.cornerRadius = bounds.height / 2
        CATransaction.commit()

        let iconSize: CGFloat = 11
        iconView.frame = NSRect(
            x: (bounds.width  - iconSize) / 2,
            y: (bounds.height - iconSize) / 2,
            width:  iconSize,
            height: iconSize
        )
    }

    private func updateAppearance() {
        let appearance: NSAppearance = effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSAppearance(named: .darkAqua)!
            : NSAppearance(named: .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let (fill, border, fg): (NSColor, NSColor, NSColor)
            if isExpanded {
                fill   = tint.withAlphaComponent(0.22)
                border = tint.withAlphaComponent(0.55)
                fg     = tint
            } else {
                fill   = tint.withAlphaComponent(0.10)
                border = tint.withAlphaComponent(0.28)
                fg     = tint.withAlphaComponent(0.85)
            }
            bgLayer.backgroundColor    = fill.cgColor
            borderLayer.borderColor    = border.cgColor
            iconView.contentTintColor  = fg
            CATransaction.commit()
        }
    }
}

// MARK: - Swipe action panel

/// Coloured panel revealed behind the row card during a swipe.
/// Two instances per cell — one anchored to the leading edge
/// (DONE target, shown when row swipes RIGHT), one to the
/// trailing edge (previous status, shown on LEFT swipe).
final class SwipeActionPanelView: NSView {
    enum Side { case leading, trailing }

    override var isFlipped: Bool { true }

    private let icon  = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let side: Side

    init(side: Side) {
        self.side = side
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve  = .continuous
        // `masksToBounds = false` so the colored drop shadow
        // can extend BEYOND the panel bounds (matches the
        // cell's own halo). Content (icon, label) stays well
        // inside the rounded corners by virtue of layout
        // padding, so allowing the layer to render past bounds
        // doesn't cause visual overflow on the icon/label.
        layer?.masksToBounds = false
        layer?.shadowOffset  = CGSize(width: 0, height: 2)
        layer?.shadowRadius  = 6
        layer?.shadowOpacity = 0   // configured per task

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 16, weight: .semibold
        )
        icon.contentTintColor = .white
        addSubview(icon)

        label.font            = NSFont.systemFont(ofSize: 12, weight: .heavy)
        label.textColor       = .white
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.lineBreakMode   = .byTruncatingTail
        label.drawsBackground = false
        label.isBordered      = false
        label.isBezeled       = false
        addSubview(label)

        alphaValue = 0   // hidden at rest
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(iconName: String, text: String, hex: String) {
        icon.image = NSImage(systemSymbolName: iconName,
                             accessibilityDescription: nil)
        label.stringValue = text
        let color = NSColor(Color(hex: hex))
        layer?.backgroundColor = color.withAlphaComponent(0.92).cgColor

        // Colored drop shadow — same accent treatment as the
        // task row cards. Uses `Color.shadowTint` for the
        // brightness/saturation adjustment per scheme.
        let scheme: ColorScheme =
            (effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            ? .dark : .light
        let tint = NSColor(Color.shadowTint(forBaseHex: hex, scheme: scheme))
        layer?.shadowColor   = tint.cgColor
        layer?.shadowOpacity = scheme == .dark ? 0.3575 : 0.40
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Update shadow path to match the rounded shape so
        // shadow shape stays clean and CoreAnimation skips the
        // alpha-derived shape computation per frame.
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: 18, cornerHeight: 18,
            transform: nil
        )
        layoutContents()
    }

    private func layoutContents() {
        let h = bounds.height
        let iconSize: CGFloat = 16
        label.sizeToFit()
        let labelSize = label.frame.size
        let gap: CGFloat = 8
        let groupWidth = iconSize + gap + labelSize.width
        let pad: CGFloat = 24

        switch side {
        case .leading:
            icon.frame = NSRect(
                x: pad,
                y: (h - iconSize) / 2,
                width: iconSize, height: iconSize
            )
            label.frame = NSRect(
                x: pad + iconSize + gap,
                y: (h - labelSize.height) / 2,
                width: labelSize.width, height: labelSize.height
            )
        case .trailing:
            let trailingX = bounds.width - pad - groupWidth
            icon.frame = NSRect(
                x: trailingX,
                y: (h - iconSize) / 2,
                width: iconSize, height: iconSize
            )
            label.frame = NSRect(
                x: trailingX + iconSize + gap,
                y: (h - labelSize.height) / 2,
                width: labelSize.width, height: labelSize.height
            )
        }
    }

}

