import SwiftUI
import AppKit

// Mail-style two-finger trackpad swipe for SwiftUI rows on macOS.
//
// Architecture (post fix #1): the cell's hosting view IS the
// gesture recogniser. `SwipeAwareHostingView<Content>` subclasses
// `NSHostingView<Content>` and overrides `scrollWheel(with:)`,
// so each cell needs only ONE NSHostingView instead of the
// previous "wrap SwiftUI in custom NSView in another NSHostingView"
// double-hosting setup. Behaviourally identical: horizontal-
// dominant scroll wheel events get captured here and forwarded
// to the SwiftUI side via callbacks; vertical scrolls call
// `super.scrollWheel`, which bubbles the event up the responder
// chain to the enclosing NSScrollView so the list scrolls
// normally.
//
// SwiftUI side: a tiny `SwipeRegistration` view installed as a
// `.background(...)` writes its callbacks into the ancestor
// `SwipeAwareHosting` it walks the NSView superview chain to
// find. Re-runs on every SwiftUI update so a recycled cell
// always points at the latest TaskRowView's @State closures.

/// Type-erased entry point so a SwiftUI probe can find the
/// hosting view ancestor without knowing its `Content` generic.
protocol SwipeAwareHosting: AnyObject {
    var onSwipeProgress: ((CGFloat) -> Void)? { get set }
    var onSwipeEnd:      ((CGFloat) -> Void)? { get set }
}

/// `NSHostingView` subclass that captures horizontal trackpad
/// swipes. When neither callback is registered (the common case
/// for non-swipeable rows), the override falls through to
/// `super.scrollWheel` so vertical scroll continues to bubble
/// to the enclosing scroll view exactly as the default
/// hosting view would.
final class SwipeAwareHostingView<Content: View>:
    NSHostingView<Content>, SwipeAwareHosting
{
    var onSwipeProgress: ((CGFloat) -> Void)?
    var onSwipeEnd:      ((CGFloat) -> Void)?

    /// Cumulative horizontal translation since the gesture began.
    private var accumulated: CGFloat = 0
    /// Axis lock — set on the first non-trivial delta, kept
    /// until the gesture ends.
    private var axisLocked: Axis? = nil

    private enum Axis { case horizontal, vertical }

    required init(rootView: Content) { super.init(rootView: rootView) }
    @MainActor required dynamic init?(coder: NSCoder) { super.init(coder: coder) }

    override func scrollWheel(with event: NSEvent) {
        // No swipe handler attached → behave exactly like the
        // stock NSHostingView. Forwards everything up.
        guard onSwipeProgress != nil || onSwipeEnd != nil else {
            super.scrollWheel(with: event)
            return
        }
        // Mouse wheel events (no precise deltas) shouldn't trigger
        // row swipes — only trackpad gestures.
        guard event.hasPreciseScrollingDeltas else {
            super.scrollWheel(with: event)
            return
        }

        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        switch event.phase {
        case .began:
            accumulated = 0
            axisLocked = nil

        case .changed:
            if axisLocked == nil {
                let mag = max(abs(dx), abs(dy))
                guard mag > 0.5 else { return }
                axisLocked = abs(dx) > abs(dy) ? .horizontal : .vertical
            }
            switch axisLocked {
            case .horizontal:
                accumulated += dx
                onSwipeProgress?(accumulated)
            case .vertical:
                super.scrollWheel(with: event)
            case .none:
                break
            }

        case .ended, .cancelled:
            if axisLocked == .horizontal {
                onSwipeEnd?(accumulated)
            } else if axisLocked == .vertical {
                super.scrollWheel(with: event)
            }
            accumulated = 0
            axisLocked = nil

        default:
            // Momentum frames; let the parent scroll view consume
            // them so vertical inertia continues to drive list
            // scrolling.
            super.scrollWheel(with: event)
        }
    }
}

// MARK: - SwiftUI registration probe

/// Tiny NSView whose only job is to find its `SwipeAwareHosting`
/// ancestor and write the SwiftUI-side callbacks into it. Lives
/// in the view tree as a `.background(...)` of the swipeable
/// content so SwiftUI tears it down/rebuilds it together with
/// the content above.
final class SwipeRegistrationProbe: NSView {
    var onSwipeProgress: ((CGFloat) -> Void)?
    var onSwipeEnd:      ((CGFloat) -> Void)?

    /// Walks up the NSView superview chain until it finds the
    /// `SwipeAwareHosting` host (the cell's hosting view) and
    /// pushes the latest callbacks into it. Called whenever the
    /// probe enters the window or its closures change via
    /// `updateNSView`.
    func registerWithHost() {
        var current: NSView? = superview
        while let v = current {
            if let host = v as? SwipeAwareHosting {
                host.onSwipeProgress = onSwipeProgress
                host.onSwipeEnd      = onSwipeEnd
                return
            }
            current = v.superview
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWithHost()
    }
}

private struct SwipeRegistration: NSViewRepresentable {
    var onProgress: (CGFloat) -> Void
    var onEnd:      (CGFloat) -> Void

    func makeNSView(context: Context) -> SwipeRegistrationProbe {
        let probe = SwipeRegistrationProbe()
        probe.onSwipeProgress = onProgress
        probe.onSwipeEnd      = onEnd
        // Probe might not be in the window yet — `viewDidMoveToWindow`
        // will register once it lands. If it IS already in the window
        // (rare on first appear), register immediately too.
        probe.registerWithHost()
        return probe
    }

    func updateNSView(_ probe: SwipeRegistrationProbe, context: Context) {
        // Refresh closures on every SwiftUI update so the host
        // always points at the latest TaskRowView's @State
        // bindings (recycled cell binds with new closures).
        probe.onSwipeProgress = onProgress
        probe.onSwipeEnd      = onEnd
        probe.registerWithHost()
    }
}

// MARK: - Standalone swipe host (for SwiftUI LazyVStack lists)

/// Hosts arbitrary SwiftUI content inside a `SwipeAwareHostingView`
/// so the two-finger swipe works on pages that lay rows out with a
/// plain SwiftUI `ScrollView`/`LazyVStack` (e.g. "Hoje", "Minhas
/// Tarefas") instead of `NSCollectionListView`.
///
/// Why it's needed: `twoFingerSwipe` installs a `SwipeRegistrationProbe`
/// that walks the NSView superview chain looking for a
/// `SwipeAwareHosting` ancestor to wire its callbacks into. In the
/// collection-view list every cell is hosted by a `SwipeAwareHostingView`,
/// so the probe finds it. In a pure SwiftUI list there's no such
/// ancestor — the whole scroll content shares one stock hosting view —
/// so the callbacks were never connected and the swipe (plus its
/// haptic) silently did nothing. Wrapping each cell in its own
/// `SwipeAwareHostingView` restores the gesture.
///
/// Assumes FIXED-HEIGHT content (the task cell is single-line), so the
/// row height comes straight from the hosting view's intrinsic size and
/// doesn't depend on the proposed width. Pair with
/// `.frame(maxWidth: .infinity)` at the call site so the host fills the
/// column and the cell's own `maxWidth: .infinity` expands inside it.
struct SwipeCellHost<Content: View>: NSViewRepresentable {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    func makeNSView(context: Context) -> SwipeAwareHostingView<Content> {
        SwipeAwareHostingView(rootView: content)
    }

    func updateNSView(_ nsView: SwipeAwareHostingView<Content>, context: Context) {
        nsView.rootView = content
    }

    func sizeThatFits(_ proposal: ProposedViewSize,
                      nsView: SwipeAwareHostingView<Content>,
                      context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        let width  = proposal.width ?? intrinsic.width
        let height = intrinsic.height > 0 ? intrinsic.height
                                          : nsView.fittingSize.height
        return CGSize(width: width, height: height)
    }
}

extension View {
    /// Mail-style two-finger trackpad horizontal swipe. Unlike
    /// the previous wrapping container, this implementation
    /// piggybacks on the cell's existing `SwipeAwareHostingView`
    /// (set up by NSCollectionListView), so it adds NO extra
    /// NSHostingView per row — just a 0-pixel `SwipeRegistrationProbe`
    /// that wires the SwiftUI closures into the host. Visually
    /// the swipe behaves identically to before.
    func twoFingerSwipe(
        onProgress: @escaping (CGFloat) -> Void,
        onEnd:      @escaping (CGFloat) -> Void
    ) -> some View {
        background(
            SwipeRegistration(onProgress: onProgress, onEnd: onEnd)
        )
    }
}
