import SwiftUI
import AppKit

// AppKit-native task list. Specialised counterpart to
// `NSCollectionListView` — uses `TaskRowCellItem` (full AppKit,
// no NSHostingView per cell) instead of the SwiftUI hosting cell.
//
// Phase 1 scope: data plumbing + static cells. Hover, click,
// swipe and slide-out animations come in subsequent phases —
// the cell already conforms to `SwipeAwareHosting` so phase 4
// just needs to wire the recogniser through.
struct TaskCollectionView: NSViewRepresentable {
    /// Now `[TaskListRow]` instead of `[CUTask]` so each
    /// row carries its indent depth + has-children flag.
    /// AppState's `flattenForList(_:)` expands the tree
    /// based on `expandedSubtaskIds` and produces this list.
    let items: [TaskListRow]
    /// Parent-task cell height. History:
    ///   • 80pt — original pre-tighten value
    ///   • 68pt — 80 × 0.85, set when the user wanted 15% shorter
    ///   • 78pt — 68 × 1.15, restored 15% taller (current).
    /// Internal `TaskRowContentView` constants (`verticalPad`,
    /// `titleMetaGap`) were restored alongside this bump so the
    /// math `14 + 20 + 8 + 22 + 14 = 78` fits exactly. Subtask
    /// rows (depth > 0) stay at 40pt via the per-row override
    /// in `sizeForItemAt` below — only the parent rows grow.
    var rowHeight: CGFloat = 78
    var topContentInset: CGFloat = 0
    /// Fires when the user clicks the row's content area
    /// (anywhere except the status pill). The closure receives
    /// the tapped task and the row's frame in window
    /// coordinates so the caller can scale the detail popup
    /// out of the click position.
    var onTapTask: (CUTask, CGRect) -> Void = { _, _ in }
    let appState: AppState

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller   = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground       = false
        scroll.borderType            = .noBorder
        scroll.scrollerStyle         = .overlay
        scroll.autohidesScrollers    = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets   = NSEdgeInsets(top: topContentInset, left: 0, bottom: 0, right: 0)
        scroll.scrollerInsets  = NSEdgeInsets(top: topContentInset, left: 0, bottom: 0, right: 0)

        let layout = SubtaskFadeLayout()
        layout.scrollDirection         = .vertical
        // Line spacing is BAKED INTO the cell heights — each
        // cell adds half its tier's gap on top + half on
        // bottom — so FlowLayout just stacks them with zero
        // spacing. This is the only way to get DIFFERENT gaps
        // between parents (14.8pt) vs. between subtasks
        // (2.96pt = 20% of parent) since FlowLayout's
        // `minimumLineSpacing` is a single section-wide
        // value. Parent gap preserved exactly: parent cell
        // adds `TaskRowCellItem.bakedVerticalGap / 2` of
        // padding on top + bottom, so two parents stacked
        // give 14.8pt of empty space between cards.
        layout.minimumLineSpacing      = 0
        layout.minimumInteritemSpacing = 0
        layout.itemSize                = NSSize(
            width: 320,
            height: rowHeight + TaskRowCellItem.bakedVerticalGap)
        layout.sectionInset            = .init(top: 4, left: 0, bottom: 12, right: 0)

        let collection = WidthTrackingCollectionView(frame: .zero)
        collection.collectionViewLayout = layout
        collection.dataSource           = context.coordinator
        collection.delegate             = context.coordinator
        collection.isSelectable         = true
        collection.allowsMultipleSelection = false
        collection.backgroundColors     = [.clear]
        collection.register(TaskRowCellItem.self,
                            forItemWithIdentifier: TaskRowCellItem.identifier)
        collection.register(SubtaskCellItem.self,
                            forItemWithIdentifier: SubtaskCellItem.identifier)

        context.coordinator.collection = collection
        context.coordinator.rowHeight  = rowHeight
        collection.onResize = { [weak collection] in
            guard let collection,
                  let flow = collection.collectionViewLayout as? NSCollectionViewFlowLayout
            else { return }
            let newWidth = collection.bounds.width
            guard newWidth > 0,
                  abs(flow.itemSize.width - newWidth) > 0.5 else { return }
            flow.itemSize = NSSize(width: newWidth, height: flow.itemSize.height)
            flow.invalidateLayout()
        }
        scroll.documentView = collection

        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let inset = NSEdgeInsets(top: topContentInset, left: 0, bottom: 0, right: 0)
        if nsView.contentInsets.top != topContentInset {
            nsView.contentInsets  = inset
            nsView.scrollerInsets = inset
        }
        context.coordinator.update(items: items, appState: appState, onTapTask: onTapTask)
    }

    final class Coordinator: NSObject,
                             NSCollectionViewDataSource,
                             NSCollectionViewDelegate,
                             NSCollectionViewDelegateFlowLayout {
        var parent: TaskCollectionView
        weak var collection: NSCollectionView?
        var rowHeight: CGFloat = 80
        private var items: [TaskListRow] = []
        private var appState: AppState
        private var onTapTask: (CUTask, CGRect) -> Void

        /// The currently-presented status-picker popover. Stored
        /// so we can dismiss it before showing a new one (NSPopover
        /// only allows one to be visible at a time anchored to a
        /// view).
        private var statusPickerPopover: NSPopover?

        /// Bumped on every `update(items:)` call. Pending
        /// staggered subtask inserts capture this token and
        /// abort if a newer update has fired in the meantime
        /// — prevents a stale dispatch from inserting into
        /// an outdated `items` array (e.g. user expands one
        /// parent, then immediately collapses or expands
        /// another before the cascade finishes).
        private var staggerGeneration: Int = 0
        /// Per-subtask delay between staggered inserts —
        /// small enough to read as a quick cascade, not as
        /// a slow waterfall.
        private let subtaskStagger: TimeInterval = 0.035

        init(parent: TaskCollectionView) {
            self.parent     = parent
            self.appState   = parent.appState
            self.onTapTask  = parent.onTapTask
        }

        func update(items new: [TaskListRow],
                    appState: AppState,
                    onTapTask: @escaping (CUTask, CGRect) -> Void) {
            self.appState   = appState
            self.onTapTask  = onTapTask

            if items == new { return }

            if items.map(\.id) == new.map(\.id) {
                // Same row ids, only payload changed (e.g.
                // status colour after a remote sync). Just
                // rebind visible cells — no layout work.
                self.items = new
                rebindVisibleCells()
                return
            }

            let oldIdSet = Set(items.map(\.id))
            guard let cv = collection else {
                self.items = new
                return
            }

            // Split the new state into two phases so that
            // newly-inserted SUBTASKS can cascade in with a
            // small per-row delay while everything else (cell
            // moves, parent inserts, every kind of remove)
            // happens in a single immediate batch.
            //
            //   Phase 1 — applied immediately:
            //     • removes (collapse / refresh / archive)
            //     • inserts at depth == 0 (rare; e.g. a
            //       freshly-synced parent task)
            //     • surviving cells slide via animator()
            //
            //   Phase 2 — staggered, one batch per subtask:
            //     • inserts at depth > 0 — the rows that
            //       appear when the user taps a parent's
            //       chevron. Each runs `subtaskStagger`
            //       seconds after the previous, producing a
            //       cascade rather than a synchronous burst.
            var stagOrder: [TaskListRow] = []
            for row in new where row.depth > 0 && !oldIdSet.contains(row.id) {
                stagOrder.append(row)
            }
            let stagIds = Set(stagOrder.map(\.id))
            let intermediate = new.filter { !stagIds.contains($0.id) }

            // Phase 1: diff old → intermediate.
            let oldIds = items.map(\.id)
            let intIds = intermediate.map(\.id)
            let phase1 = intIds.difference(from: oldIds)

            // Capture references to cells about to be
            // deleted in OLD indexPaths (the data source is
            // still on `items` at this point, so `cv.item(at:)`
            // resolves correctly). We also snapshot each
            // cell's CURRENT layer frame so we can lock the
            // position back to where the cell was BEFORE
            // the framework's batch-update layout pass —
            // otherwise `super.layoutAttributesForItem(at:
            // oldPath)` inside
            // `finalLayoutAttributesForDisappearingItem`
            // returns the attrs of whatever NEW item now
            // sits at that index path (the cells below
            // bumped up to fill the gap), and the
            // disappearing cell's layer model y silently
            // shifts to that wrong position — visually it
            // jumps down at the moment the fade starts.
            //
            // Sorted BOTTOM-UP — the row farthest from the
            // parent fades first, then each row above it
            // peels off in turn. Reads as the subtree
            // collapsing back UP into the parent (last
            // child gone first, deepest-last) instead of
            // the parent shedding rows top-down.
            var removingCells: [(cell: NSCollectionViewItem,
                                 frame: NSRect)] = []
            for change in phase1 {
                if case .remove(let off, _, _) = change {
                    let ip = IndexPath(item: off, section: 0)
                    if let cell = cv.item(at: ip) {
                        removingCells.append((cell, cell.view.frame))
                    }
                }
            }
            // Higher origin.y = lower on screen in the
            // flipped clip-view space NSCollectionView lays
            // out into. Descending sort puts the bottom-
            // most cell at index 0, so it gets delay 0 and
            // fades first.
            removingCells.sort { $0.frame.origin.y > $1.frame.origin.y }

            self.items = intermediate
            NSAnimationContext.runAnimationGroup({ ctx in
                // Phase 1 carries every removal (collapse,
                // archive, sync) AND the implicit slide of
                // every surviving cell that has to shift to
                // fill the vacated space — the parent and
                // every task BELOW the collapsed subtree.
                // Back-out bezier with a y-control of 1.25:
                // returning rows briefly overshoot their
                // resting y by a couple pt before settling
                // back, giving the collapse a soft elastic
                // landing without straying into bounciness
                // that would feel toy-like. Disappearing
                // cells ride the same curve and overshoot
                // their `exitDrift` slightly while fading
                // — invisible by then, so harmless.
                //
                // Duration 0.338s ≈ 0.26 × 1.30 — gives the
                // overshoot + settle enough room to read
                // without dragging the collapse out.
                ctx.duration = 0.338
                ctx.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.34, 1.25, 0.64, 1.0)
                cv.animator().performBatchUpdates({
                    for change in phase1 {
                        switch change {
                        case .remove(let off, _, _):
                            cv.animator().deleteItems(
                                at: [IndexPath(item: off, section: 0)])
                        case .insert(let off, _, _):
                            cv.animator().insertItems(
                                at: [IndexPath(item: off, section: 0)])
                        }
                    }
                }, completionHandler: nil)

                // Stagger the implicit slide of surviving
                // cells. `cv.animator().performBatchUpdates`
                // synchronously adds CABasicAnimations to
                // each cell layer for the position change;
                // we walk the visible cells in top-down order
                // and clone those animations with a per-row
                // `beginTime` offset, keeping `fillMode =
                // .backwards` so each cell holds at its OLD
                // position until its turn arrives. The result
                // is a soft cascade: the row immediately
                // below the collapsed subtree starts moving
                // first, then the next, then the next.
                self.applyPhase1Stagger(cv: cv)

                // Mirror the same stagger on the cells being
                // removed — the fade-out + drift the framework
                // queued for them gets cloned with an
                // incremental beginTime so the subtasks "peel
                // off" one after another instead of all
                // dissolving in unison. Same direction (top-
                // down) as the surviving slide so the whole
                // collapse reads as a single cascade.
                self.applyPhase1RemoveStagger(
                    captured: removingCells)
            }, completionHandler: nil)

            // Phase 2: schedule each staggered subtask.
            staggerGeneration += 1
            let myGen = staggerGeneration
            let stagger = subtaskStagger
            for (i, row) in stagOrder.enumerated() {
                let delay = Double(i) * stagger
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    [weak self] in
                    guard let self,
                          self.staggerGeneration == myGen,
                          let cv = self.collection else { return }
                    self.applyStaggeredInsert(row: row, target: new, cv: cv)
                }
            }
        }

        /// Per-cell delay applied to phase-1's implicit
        /// position slide so the surviving rows below a
        /// collapse cascade back into place instead of
        /// snapping in unison.
        private let phase1Stagger: TimeInterval = 0.022

        /// Walk every visible cell, find any "position" /
        /// "bounds" CABasicAnimations the framework just
        /// queued during `performBatchUpdates`, clone them
        /// with a staggered `beginTime`, and re-add them
        /// under the same key so ours wins. `fillMode =
        /// .backwards` is critical: it keeps each cell at
        /// its old presentation value until `beginTime`
        /// arrives, instead of snapping forward.
        ///
        /// Cells are walked in ascending index-path order,
        /// which is top-down on screen — exactly the order
        /// we want for the cascade (the row directly under
        /// the collapsed subtree moves first, then each row
        /// below waits its turn).
        private func applyPhase1Stagger(cv: NSCollectionView) {
            let baseTime = CACurrentMediaTime()
            let visible = cv.indexPathsForVisibleItems()
                .sorted { $0.item < $1.item }
            for (i, ip) in visible.enumerated() {
                guard let cell = cv.item(at: ip),
                      let layer = cell.view.layer,
                      let keys  = layer.animationKeys()
                else { continue }
                let delay = Double(i) * phase1Stagger
                if delay <= 0 { continue }
                for key in keys
                where key == "position"
                   || key == "bounds"
                   || key.hasPrefix("position.")
                   || key.hasPrefix("bounds.") {
                    guard let anim = layer.animation(forKey: key)
                            as? CABasicAnimation,
                          let copy = anim.copy() as? CABasicAnimation
                    else { continue }
                    copy.beginTime = baseTime + delay
                    copy.fillMode  = .backwards
                    layer.add(copy, forKey: key)
                }
            }
        }

        /// Replace whatever the framework queued on each
        /// disappearing cell with a single, stagger-aware
        /// **opacity-only** fade — locked to its ORIGINAL
        /// frame so the cell stays exactly where the user
        /// last saw it while it dissolves.
        ///
        /// Why pin the frame: the framework's batch update
        /// runs the layout AFTER the data source change,
        /// then calls
        /// `finalLayoutAttributesForDisappearingItem`. By
        /// that point `super.layoutAttributesForItem(at:
        /// oldPath)` returns the attrs of whatever NEW
        /// item now occupies that index — so the
        /// disappearing cell's frame model y silently
        /// shifts to the new occupant's y (which is lower
        /// on screen since the rows below moved up to fill
        /// the gap). `removeAllAnimations()` then snaps
        /// the layer to that wrong model value the moment
        /// the fade starts → the user sees the cell jump
        /// downward.
        ///
        /// Fix: pin the cell's frame back to the snapshot
        /// taken pre-batch (`captured.frame`) right after
        /// stripping animations. The cell stays in place
        /// for the whole fade.
        ///
        /// Other invariants:
        ///   • Stagger — `beginTime` shifted
        ///     `phase1Stagger × index` so rows fade in
        ///     cascade top-down.
        ///   • Short duration — 0.20s. Faster than the
        ///     surviving-rows slide so the gap closes
        ///     after the leaving rows are already gone.
        ///   • `fillMode = .both` + `isRemovedOnCompletion
        ///     = false` so the cell holds at alpha 0 after
        ///     the animation settles, never snapping back
        ///     to model value 1 mid-batch.
        ///   • `SubtaskCellItem.prepareForReuse` resets
        ///     `layer.opacity` + `removeAllAnimations()`
        ///     so a recycled cell doesn't reappear
        ///     invisible.
        private func applyPhase1RemoveStagger(
            captured: [(cell: NSCollectionViewItem, frame: NSRect)]
        ) {
            let baseTime = CACurrentMediaTime()
            let exitTiming = CAMediaTimingFunction(name: .easeOut)
            for (i, entry) in captured.enumerated() {
                let cell = entry.cell
                guard let layer = cell.view.layer else { continue }
                // 1. Strip every animation the framework
                //    queued — they include the wrong
                //    position interpolation we want to
                //    cancel.
                layer.removeAllAnimations()
                // 2. Pin the cell back to its original
                //    pre-batch frame. The framework may
                //    have already updated the model value
                //    to a new (incorrect) position; this
                //    reverts that.
                cell.view.frame = entry.frame

                // 3. Fade the cell out in place.
                let delay = Double(i) * phase1Stagger
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue           = 1
                fade.toValue             = 0
                fade.duration            = 0.20
                fade.beginTime           = baseTime + delay
                fade.fillMode            = .both
                fade.timingFunction      = exitTiming
                fade.isRemovedOnCompletion = false
                layer.add(fade, forKey: "exit.opacity")
            }
        }

        /// Insert `row` at the position implied by `target`
        /// (the desired final ordering). We find the closest
        /// predecessor in `target` that's already present in
        /// the live `items` array — that determines the
        /// insertion offset right now. Doing it dynamically
        /// each tick (instead of pre-computing offsets up
        /// front) is what lets multiple subtasks pile in
        /// over time without needing to track shifting
        /// indices manually.
        private func applyStaggeredInsert(row: TaskListRow,
                                          target: [TaskListRow],
                                          cv: NSCollectionView) {
            // If a newer update already wrote `row` into
            // `items`, skip — the framework will pick it up
            // through the next diff.
            if items.contains(where: { $0.id == row.id }) { return }
            guard let posInTarget = target.firstIndex(where: { $0.id == row.id })
            else { return }

            var insertAt = 0
            if posInTarget > 0 {
                for k in stride(from: posInTarget - 1, through: 0, by: -1) {
                    let predId = target[k].id
                    if let j = items.firstIndex(where: { $0.id == predId }) {
                        insertAt = j + 1
                        break
                    }
                }
            }

            items.insert(row, at: insertAt)
            NSAnimationContext.runAnimationGroup({ ctx in
                // Per-subtask entry — back-out bezier with
                // a y-control of 1.45. The curve overshoots
                // 1.0 briefly before settling, so the cell
                // drops past its resting frame, then springs
                // back the last few pt — a light bounce on
                // arrival without straying into cartoon
                // territory. Pairs with `enterDrift = 14`
                // in `SubtaskFadeLayout` for the visible
                // settle.
                ctx.duration = 0.20
                ctx.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.34, 1.45, 0.64, 1.0)
                cv.animator().performBatchUpdates({
                    cv.animator().insertItems(
                        at: [IndexPath(item: insertAt, section: 0)])
                }, completionHandler: nil)
            }, completionHandler: nil)
        }

        private func rebindVisibleCells() {
            guard let cv = collection else { return }
            for indexPath in cv.indexPathsForVisibleItems() {
                let row = items[indexPath.item]
                if let parentCell = cv.item(at: indexPath) as? TaskRowCellItem {
                    configure(cell: parentCell, with: row)
                } else if let subtaskCell = cv.item(at: indexPath) as? SubtaskCellItem {
                    subtaskCell.bind(task: row.task,
                                     appState: appState,
                                     depth: row.depth)
                }
            }
        }

        /// Bind a cell to a task AND wire its click callbacks.
        /// Centralised so `cellForItemAt` and `rebindVisibleCells`
        /// share the same setup — without this, refreshed cells
        /// would lose their click handlers because rebind via
        /// `bind(task:appState:)` doesn't reset the cell's
        /// `onRowClick` / `onStatusPillClick` (those are
        /// configured here, not inside `bind`).
        private func configure(cell: TaskRowCellItem, with row: TaskListRow) {
            let task = row.task
            cell.bind(task: task,
                      appState: appState,
                      depth: row.depth,
                      hasChildren: row.hasChildren,
                      isExpanded: row.isExpanded)
            cell.onRowClick = { [weak self] task, frame in
                guard let self else { return }
                if let popover = self.statusPickerPopover,
                   popover.isShown { return }
                // No click haptic — the trackpad's own click pulse
                // is the natural feedback for opening the popup.
                self.onTapTask(task, frame)
            }
            cell.onStatusPillClick = { [weak self] task, anchor in
                self?.showStatusPicker(for: task, anchorView: anchor)
            }
            // Toggle the row's expansion state in AppState.
            // Subtasks live INSIDE the parent cell now (not as
            // siblings in the collection view), so the toggle
            // mutates the row's `isExpanded` flag — which
            // `update(items:)` detects via the "same ids,
            // payload changed" branch and translates into a
            // layout invalidation. The cell then re-reports a
            // taller height and the framework animates the
            // resize.
            cell.onExpandClick = { [weak self] task in
                self?.appState.toggleSubtaskExpansion(task.id)
            }
        }

        /// Open an NSPopover hosting the existing SwiftUI
        /// `StatusPickerPopover` view, anchored to the pill the
        /// user clicked. Reuses the same picker the SwiftUI
        /// `TaskRowView` shows, so the dropdown UI stays
        /// pixel-identical to the legacy path.
        private func showStatusPicker(for task: CUTask, anchorView: NSView) {
            statusPickerPopover?.close()

            let appState = self.appState
            let popover = NSPopover()
            popover.behavior  = .transient
            popover.animates  = true
            let picker = StatusPickerPopover(
                statuses:          appState.availableStatuses,
                currentStatusName: task.status
            ) { [weak popover] selected in
                // No click haptic — the menu tap is its own
                // feedback via the trackpad click pulse.
                Task { await appState.updateTaskStatus(task, to: selected) }
                popover?.close()
            }
            let host = NSHostingController(rootView: picker)
            // Tell the hosting controller to track the SwiftUI
            // view's preferred size so the popover sizes itself
            // to fit the picker's content. Without this NSPopover
            // defaults to ~ 200x200 and the picker's rows get
            // squished or clipped.
            if #available(macOS 13.0, *) {
                host.sizingOptions = [.preferredContentSize]
            }
            popover.contentViewController = host

            // Anchor reasoning: the pill's NSView is flipped
            // (isFlipped = true), so the bounds rect we pass has
            // its origin at the pill's TOP-LEFT in flipped space.
            // NSPopover converts this to screen coords internally.
            // To make the popover appear directly BELOW the pill
            // (matching the SwiftUI row's `arrowEdge: .bottom`
            // semantic — arrow at top of popover, popover under
            // anchor), we ask for `.minY` of the source rect
            // which, after the framework's flip-aware conversion,
            // maps to the visible BOTTOM edge of the pill.
            popover.show(relativeTo: anchorView.bounds,
                         of: anchorView,
                         preferredEdge: .minY)
            statusPickerPopover = popover
        }

        // MARK: NSCollectionViewDataSource

        func collectionView(_ collectionView: NSCollectionView,
                            numberOfItemsInSection section: Int) -> Int {
            items.count
        }

        func collectionView(_ collectionView: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath)
        -> NSCollectionViewItem {
            let row = items[indexPath.item]
            // Top-level rows use the AppKit `TaskRowCellItem`.
            // Subtask rows (depth > 0) render the SAME SwiftUI
            // `SubtaskRow` the popup uses, hosted via
            // NSHostingView inside `SubtaskCellItem`.
            if row.depth > 0 {
                let item = collectionView.makeItem(
                    withIdentifier: SubtaskCellItem.identifier,
                    for: indexPath
                ) as! SubtaskCellItem
                item.bind(task: row.task,
                          appState: appState,
                          depth: row.depth)
                return item
            } else {
                let item = collectionView.makeItem(
                    withIdentifier: TaskRowCellItem.identifier,
                    for: indexPath
                ) as! TaskRowCellItem
                configure(cell: item, with: row)
                return item
            }
        }

        // MARK: NSCollectionViewDelegateFlowLayout — per-row height

        /// Top-level rows use the full 78pt parent pill;
        /// subtask rows (depth > 0) render in compact mode at
        /// 40pt. Subtasks are SEPARATE cells in the items
        /// array (depth-aware flatten in
        /// `AppState.flattenForList`).
        func collectionView(_ collectionView: NSCollectionView,
                            layout: NSCollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> NSSize {
            guard indexPath.item < items.count else {
                return NSSize(
                    width: collectionView.bounds.width,
                    height: rowHeight + TaskRowCellItem.bakedVerticalGap)
            }
            let row = items[indexPath.item]
            // Each cell type carries its own pre-baked
            // vertical gap (FlowLayout `minimumLineSpacing`
            // is 0 — see `makeNSView`). Parent: 78pt card +
            // 14.8pt baked gap. Subtask: 42pt SubtaskRow +
            // 2.96pt baked gap (20% of parent gap → 80%
            // tighter row-to-row spacing).
            let h: CGFloat = row.depth > 0
                ? 42 + SubtaskCellItem.bakedVerticalGap
                : rowHeight + TaskRowCellItem.bakedVerticalGap
            let w = collectionView.bounds.width
            return NSSize(width: w, height: h)
        }

        // MARK: NSCollectionViewDelegate

        func collectionView(_ collectionView: NSCollectionView,
                            didSelectItemsAt indexPaths: Set<IndexPath>) {
            // We handle clicks via the cell's own `mouseDown`
            // override (in TaskRowContentView / StatusPillView),
            // so collection-view selection is just visual chrome
            // — deselect immediately to avoid the persistent
            // blue selection ring.
            collectionView.deselectItems(at: indexPaths)
        }
    }
}

// MARK: - SubtaskCellItem
//
// Cell type for subtask rows (depth > 0) in the main task
// list. Just hosts the SAME SwiftUI `SubtaskRow` view the
// task popup uses — checkbox + title + status pill + due
// date — so the inline subtasks have identical functionality
// (hover-DONE pill, click-to-open, swipe, etc.) to the popup
// without any code duplication.
//
// Indent is applied via the leading constraint based on
// depth so grandchildren / great-grandchildren visually nest
// under their parent in the flat list.
final class SubtaskCellItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("SubtaskCell")

    /// Visual gap baked into the subtask cell's height so
    /// consecutive subtask rows sit close together
    /// (~2.96pt apart) — 20% of the parent line spacing
    /// (14.79768470pt). FlowLayout's `minimumLineSpacing`
    /// is set to 0 so cells contribute their own gap.
    /// Splitting it half on top + half on bottom keeps the
    /// SubtaskRow centered inside the cell.
    static let bakedVerticalGap: CGFloat = 14.79768470 * 0.20  // 2.95953694
    static var halfGap: CGFloat { bakedVerticalGap * 0.5 }

    private var hosting: NSHostingView<SubtaskRow>?
    private var leadingConstraint: NSLayoutConstraint?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = .clear
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hosting?.removeFromSuperview()
        hosting = nil
        leadingConstraint = nil
        // Reset visual state so a recycled cell doesn't
        // wake up still invisible from a previous fade-
        // out (`applyPhase1RemoveStagger` leaves alpha at
        // 0 with `isRemovedOnCompletion = false` so the
        // cell stays hidden through the rest of the
        // collapse batch — but on REUSE that residue
        // would render the next row's content as
        // invisible).
        view.layer?.removeAllAnimations()
        view.layer?.opacity = 1
    }

    func bind(task: CUTask, appState: AppState, depth: Int) {
        hosting?.removeFromSuperview()
        let host = NSHostingView(rootView: SubtaskRow(task: task,
                                                      appState: appState))
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        let leading = host.leadingAnchor.constraint(
            equalTo: view.leadingAnchor,
            constant: 12 + CGFloat(max(0, depth - 1)) * 16)
        let pad = SubtaskCellItem.halfGap
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: view.topAnchor,
                                       constant: pad),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor,
                                          constant: -pad),
            leading,
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor,
                                            constant: -12),
        ])
        hosting = host
        leadingConstraint = leading
    }
}

// MARK: - SubtaskFadeLayout
//
// FlowLayout subclass that supplies start / end attributes
// for inserting and removing items so NSCollectionView can
// animate them. macOS's `NSCollectionViewLayoutAttributes`
// only expose `frame`, `alpha`, `zIndex` and `isHidden` —
// no transforms — so the entry/exit motion is built out of
// those primitives.
//
// Coordinate note: the host NSCollectionView (and its
// document view inside the scroll view) use Cocoa's default
// non-flipped coordinate system — y grows UP, not down. So
// `origin.y -= n` moves a cell DOWNWARD on screen, and
// `origin.y += n` moves it UPWARD.
//
//   • Inserting a subtask cell: start at alpha=0 with the
//     frame shifted DOWN by `enterDrift`pt (origin.y -=).
//     Cells emerge from below their resting position and
//     drift up into place — pairs with the back-out
//     bezier in `applyStaggeredInsert` so the arrival
//     overshoots a touch before settling.
//   • Removing a subtask cell: end at alpha=0 with the
//     frame UNCHANGED — pure fade-out, no positional
//     drift. Earlier iterations drifted the cell upward
//     by 22pt while fading; the user found that motion
//     unnecessary on top of the surviving-rows slide and
//     the per-cell stagger, so the exit is now simply
//     "alpha → 0" decelerating with `easeOut` (set per
//     cell in `applyPhase1RemoveStagger`).
//
// Surviving cells (the parent that was tapped + every row
// below the inserted/removed slice) are not handled here
// — NSCollectionView's animator interpolates their frames
// automatically when wrapped in `NSAnimationContext`.
final class SubtaskFadeLayout: NSCollectionViewFlowLayout {
    /// Distance an inserting cell starts BELOW its final
    /// frame (non-flipped coords → smaller y is lower on
    /// screen). The animator drifts it upward into rest.
    private let enterDrift: CGFloat = 14
    /// Disappearing cells now fade out in place (no
    /// vertical drift) per user feedback — `0` means the
    /// `finalLayoutAttributesForDisappearingItem` only
    /// touches `alpha`, leaving the frame at its resting
    /// position. Kept as a named constant rather than a
    /// magic 0 so it's obvious where to dial back in if
    /// we ever want a hint of motion.
    private let exitDrift: CGFloat = 0

    override func initialLayoutAttributesForAppearingItem(
        at indexPath: IndexPath
    ) -> NSCollectionViewLayoutAttributes? {
        guard
            let attrs = super.layoutAttributesForItem(at: indexPath)?
                .copy() as? NSCollectionViewLayoutAttributes
        else {
            return super.initialLayoutAttributesForAppearingItem(at: indexPath)
        }
        attrs.alpha = 0
        // `-=` in non-flipped coords → start position is
        // BELOW the resting frame. Cell drifts UP into
        // place during the animation.
        attrs.frame.origin.y -= enterDrift
        return attrs
    }

    override func finalLayoutAttributesForDisappearingItem(
        at indexPath: IndexPath
    ) -> NSCollectionViewLayoutAttributes? {
        guard
            let attrs = super.layoutAttributesForItem(at: indexPath)?
                .copy() as? NSCollectionViewLayoutAttributes
        else {
            return super.finalLayoutAttributesForDisappearingItem(at: indexPath)
        }
        attrs.alpha = 0
        // Pure fade — no drift. `exitDrift` is `0`; if
        // someone re-enables a hint of motion later this
        // line still lifts the cell upward (`+=` in non-
        // flipped coords).
        attrs.frame.origin.y += exitDrift
        return attrs
    }
}
