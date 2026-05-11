import SwiftUI
import AppKit

// SwiftUI ↔ AppKit bridge that renders an Identifiable list inside an
// `NSCollectionView` with cell recycling, instead of SwiftUI's
// `LazyVStack`. The motivation is the SwiftUI scroll-FPS ceiling: even
// after caching, drawingGroup, deferred AppState writes, and equatable
// short-circuits, the view tree still measured ~20ms per frame for
// ~30 visible rows. NSCollectionView reuses a small pool of
// `NSCollectionViewItem`s as the user scrolls, so SwiftUI never has
// to create or destroy more views than fit on screen — just re-bind
// the hosting view's root content to the next item.
//
// The wrapper is intentionally minimal: variable heights via
// auto-size hint + measured fitting size, no headers/footers, no
// section support. If the spike validates the FPS win we extend it.

struct NSCollectionListView<Item: Identifiable & Equatable, Cell: View>: NSViewRepresentable
where Item.ID: Hashable {
    /// Stable list of items to render. Diffed against the previous
    /// snapshot on every `updateNSView` call; only inserts/removes/
    /// reloads that actually changed propagate to the collection
    /// view, so identity-stable lists are basically free to refresh.
    let items: [Item]
    /// Fixed height for every row. Required for cell-recycling to
    /// stay cheap: with `estimatedItemSize` instead of a hard
    /// height, NSCollectionViewFlowLayout asks the delegate for
    /// each visible row's `sizeForItemAt`, and the delegate
    /// allocates a throwaway NSHostingView per row just to read
    /// its `fittingSize` — multiplied by ~30 visible rows per
    /// layout pass, that single bit alone made the spike SLOWER
    /// than LazyVStack. With a fixed height the layout skips
    /// measurement entirely and just multiplies row count × this
    /// number to compute content size.
    var rowHeight: CGFloat = 80
    /// Builds the SwiftUI view for a single item. Called once per
    /// recycled cell each time the cell binds to a new item — NOT
    /// per scroll frame, NOT per visible cell per frame. SwiftUI's
    /// own diff inside the cell handles the per-render work.
    let cellBuilder: (Item) -> Cell
    /// Extra space at the top of the scrollable content. Unlike
    /// SwiftUI's `safeAreaInset`, this lets rows scroll BEHIND the
    /// inset region rather than starting below it — so a row near
    /// the top of the document can disappear under a translucent
    /// toolbar / filter bar (with FrostedStrip fade) instead of
    /// terminating against a hard edge. `NSScrollView.contentInsets`
    /// is the AppKit equivalent of SwiftUI ScrollView's "scroll
    /// content extends into safe area" behaviour.
    var topContentInset: CGFloat = 0

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        // Push the initial scroll position down by `topContentInset`
        // so the first row sits below the toolbar + filter bar, while
        // still letting content scroll up behind those bars (the
        // FrostedStrip fade then dissolves them gracefully). Without
        // disabling automatic adjustment, AppKit will overwrite our
        // value based on the enclosing window's safe area.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: topContentInset, left: 0, bottom: 0, right: 0)
        // Keep overlay scroller pinned below the inset region —
        // otherwise the scroller's track starts at y=0 and renders
        // through the toolbar.
        scroll.scrollerInsets = NSEdgeInsets(top: topContentInset, left: 0, bottom: 0, right: 0)

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 2.8153125
        layout.minimumInteritemSpacing = 0
        layout.itemSize = NSSize(width: 320, height: rowHeight)
        layout.sectionInset = .init(top: 4, left: 0, bottom: 12, right: 0)

        let collection = WidthTrackingCollectionView(frame: .zero)
        collection.collectionViewLayout = layout
        collection.dataSource = context.coordinator
        collection.isSelectable = false
        collection.backgroundColors = [.clear]
        collection.register(
            ApolloHostingItem.self,
            forItemWithIdentifier: ApolloHostingItem.identifier
        )

        context.coordinator.collection = collection
        context.coordinator.rowHeight = rowHeight
        // Keep itemSize.width in sync with the collection view's
        // current bounds so cells always span the full width.
        // Updated whenever AppKit calls `layout()` on the
        // tracking subclass below.
        collection.onResize = { [weak collection] in
            guard let collection = collection,
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
        // Keep the scroll's top inset in sync if the value changes
        // at runtime (e.g. filter bar appears/disappears). Cheap to
        // re-set every update; AppKit no-ops if the value hasn't
        // changed.
        let inset = NSEdgeInsets(top: topContentInset, left: 0, bottom: 0, right: 0)
        if nsView.contentInsets.top != topContentInset {
            nsView.contentInsets = inset
            nsView.scrollerInsets = inset
        }
        context.coordinator.update(items: items, cellBuilder: cellBuilder)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject,
                             NSCollectionViewDataSource {
        var parent: NSCollectionListView
        weak var collection: NSCollectionView?
        var rowHeight: CGFloat = 80
        private var items: [Item] = []
        /// Latest cell builder closure. Stored separately from
        /// `parent` so it can be swapped per `updateNSView` without
        /// rebuilding the whole representable.
        private var cellBuilder: (Item) -> Cell

        init(parent: NSCollectionListView) {
            self.parent = parent
            self.cellBuilder = parent.cellBuilder
        }

        func update(items new: [Item], cellBuilder: @escaping (Item) -> Cell) {
            self.cellBuilder = cellBuilder
            // PERF: skip-fast path. `updateNSView` fires on EVERY
            // `@Published` mutation in `AppState` (selected date,
            // expanded task id, hover dictionaries, notification
            // poll, etc.) because the parent view body re-evaluates
            // and rebuilds the cell-builder closure with a new
            // identity. The vast majority of those pings don't
            // touch task content. Without this guard, we walked
            // every visible cell and rebuilt its SwiftUI root on
            // each ping — the most expensive thing we could do
            // for a "nothing changed" event.
            //
            // `Item: Equatable` lets us compare value-wise: if
            // every task is byte-identical to the previous snapshot,
            // we know the rendered output cannot differ and we
            // can return immediately. Cell layers stay untouched.
            if items == new { return }

            // IDs unchanged but content differs (status edit,
            // title rename, due-date change) — re-bind the visible
            // cells in place rather than `reloadData()`, which
            // resets scroll position and recycles all cells.
            if items.map(\.id) == new.map(\.id) {
                self.items = new
                refreshVisibleCells()
                return
            }

            // Inserts / removes / reorders — diff and apply via
            // `performBatchUpdates` so the affected cells animate
            // (deleted rows fade out, surviving rows above the
            // removed slot stay put while rows below slide up to
            // fill the gap; insertions reverse). Without this,
            // `reloadData()` would slam the new state in with no
            // motion at all — every row would jump to its new
            // position instantly.
            let oldIds = items.map(\.id)
            let newIds = new.map(\.id)
            self.items = new

            guard let collection = collection else { return }

            let diff = newIds.difference(from: oldIds)

            // `performBatchUpdates` requires the data source to
            // already reflect the new state when it's called —
            // we set `self.items = new` above, then pass the
            // differential operations so AppKit can animate them.
            // Wrapping in `NSAnimationContext.runAnimationGroup`
            // controls duration / easing globally for all the
            // affected cells in this batch.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                collection.animator().performBatchUpdates({
                    for change in diff {
                        switch change {
                        case .remove(let offset, _, _):
                            collection.animator()
                                .deleteItems(at: [IndexPath(item: offset, section: 0)])
                        case .insert(let offset, _, _):
                            collection.animator()
                                .insertItems(at: [IndexPath(item: offset, section: 0)])
                        }
                    }
                }, completionHandler: nil)
            }
        }

        /// Re-bind the hosting view of every visible cell so a
        /// list whose ITEM IDs are unchanged but whose item
        /// CONTENT changed (e.g. a status edit) still picks up
        /// the new SwiftUI view. Cheaper than `reloadData()` —
        /// touches only on-screen cells, never resets scroll
        /// position, never invalidates layout.
        private func refreshVisibleCells() {
            guard let cv = collection else { return }
            for indexPath in cv.indexPathsForVisibleItems() {
                guard let item = cv.item(at: indexPath) as? ApolloHostingItem else { continue }
                let model = items[indexPath.item]
                item.bind(content: cellBuilder(model))
            }
        }

        // MARK: NSCollectionViewDataSource

        func collectionView(_ collectionView: NSCollectionView,
                            numberOfItemsInSection section: Int) -> Int {
            items.count
        }

        func collectionView(_ collectionView: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(
                withIdentifier: ApolloHostingItem.identifier,
                for: indexPath
            ) as! ApolloHostingItem
            let model = items[indexPath.item]
            item.bind(content: cellBuilder(model))
            return item
        }
    }

}

// MARK: - Hosting item (file-scoped because static stored properties
// aren't allowed inside a generic type)

/// Single recycled cell. Holds a `SwipeAwareHostingView<AnyView>`
/// — an `NSHostingView` subclass that doubles as the two-finger
/// horizontal swipe recogniser. Using the subclass directly (vs
/// the previous "wrap content in custom NSView nested in another
/// NSHostingView" container) cuts one NSHostingView per cell:
/// with 30 visible rows that's 30 fewer SwiftUI hosting
/// boundaries to invalidate on every update, plus one less
/// CALayer on every scroll frame. The hosting view's `rootView`
/// is re-bound on every cell recycle to swap content.
///
/// `AnyView` keeps the hosting view's generic stable across
/// recyclings — swapping the root view's TYPE would force
/// AppKit to discard and rebuild the underlying NSView,
/// defeating the recycling.
final class ApolloHostingItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ApolloHostingItem")

    private var hostingView: SwipeAwareHostingView<AnyView>?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = .clear
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // Clear any leftover swipe callbacks so events arriving
        // between unbind and re-bind don't fire stale closures
        // captured for a previous task.
        hostingView?.onSwipeProgress = nil
        hostingView?.onSwipeEnd      = nil
        // Hosting view itself stays — the next `bind(content:)`
        // swaps `rootView` in place; tearing it down would lose
        // the SwiftUI render cache.
    }

    func bind<Content: View>(content: Content) {
        let wrapped = AnyView(content)
        if let hosting = hostingView {
            hosting.rootView = wrapped
        } else {
            let host = SwipeAwareHostingView(rootView: wrapped)
            host.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: view.topAnchor),
                host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            hostingView = host
        }
    }
}

// MARK: - Width-tracking collection view

/// `NSCollectionView` subclass that fires a callback whenever its
/// own bounds change, so the SwiftUI bridge can re-set the flow
/// layout's `itemSize.width` to match. Without this, a fixed
/// `itemSize` set at init time would lock the cell width to the
/// collection view's INITIAL width and never react to window
/// resizes.
final class WidthTrackingCollectionView: NSCollectionView {
    /// Called from `layout()` after AppKit recomputes our frame.
    /// Wired by `makeNSView` to update the flow layout's
    /// `itemSize.width`.
    var onResize: (() -> Void)?

    override func layout() {
        super.layout()
        onResize?()
    }
}
