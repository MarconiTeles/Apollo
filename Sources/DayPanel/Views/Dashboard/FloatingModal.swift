import SwiftUI

// Generic centered modal overlay with dimmed backdrop and a spring scale-up
// transition. Used by the create-event and create-task forms so they share
// the same look and feel as `EventDetailOverlay` (without the pill anchor).

struct FloatingModal<Content: View>: View {
    enum BackdropStyle { case dim, blur, none }

    @Binding var isPresented: Bool
    var origin: CGRect = .zero
    var windowSize: CGSize = .zero
    var backdrop: BackdropStyle = .dim
    @ViewBuilder let content: () -> Content

    /// Pixel delta from the centre of the window (popup's resting place)
    /// to the centre of the trigger button. Used as a translation so the
    /// scaled-down popup sits exactly at the click point.
    private var offsetDelta: CGSize {
        guard windowSize.width  > 0,
              windowSize.height > 0,
              origin != .zero else { return .zero }
        return CGSize(
            width:  origin.midX - windowSize.width  / 2,
            height: origin.midY - windowSize.height / 2
        )
    }

    var body: some View {
        ZStack {
            if isPresented {
                // `.none` callers (e.g. onboarding) supply their own
                // backdrop higher up in the view tree, so we render
                // an invisible click-target instead — keeps "tap
                // outside to dismiss" working without painting an
                // extra layer of material.
                if case .none = backdrop {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture { dismiss() }
                        // Empty `.onHover` registers an NSTrackingArea
                        // on this layer so hover events stop here
                        // instead of passing through to the dashboard
                        // rows behind. SwiftUI's `.allowsHitTesting(false)`
                        // does NOT disable already-installed tracking
                        // areas on hosting views, so the backdrop has
                        // to be the one swallowing hover.
                        .onHover { _ in }
                } else {
                    backdropView
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture { dismiss() }
                        .onHover { _ in }   // see comment above
                }

                content()
                    .transition(popupTransition)
            }
        }
        .animation(.spring(duration: 0.45, bounce: 0.30), value: isPresented)
    }

    /// Light dim by default (cheap, doesn't compete with the popup) and
    /// a frosted blur when the caller explicitly opts in (e.g. onboarding,
    /// where the user should focus solely on the wizard).
    @ViewBuilder
    private var backdropView: some View {
        switch backdrop {
        case .dim:
            Color.black.opacity(0.08)
        case .blur:
            ZStack {
                Rectangle().fill(.regularMaterial)
                Color.black.opacity(0.04)
            }
        case .none:
            // Caller draws its own backdrop (e.g. ContentView's
            // persistent setup blur). The body has a separate
            // `.none` branch above that supplies the click-target,
            // so this is just a stub for the compiler's exhaustive
            // switch check.
            EmptyView()
        }
    }

    /// Combined scale + translate so the popup appears to fly out of the
    /// button position and grow into place.
    private var popupTransition: AnyTransition {
        let active   = PopupTransform(scale: 0.02, offset: offsetDelta, opacity: 0)
        let identity = PopupTransform(scale: 1.0,  offset: .zero,        opacity: 1)
        return .asymmetric(
            insertion: .modifier(active: active, identity: identity),
            removal:   .modifier(active: active, identity: identity)
        )
    }

    private func dismiss() {
        withAnimation(.spring(duration: 0.40, bounce: 0.20)) {
            isPresented = false
        }
    }
}

/// Modifier shared by `FloatingModal` and `EventDetailOverlay` to interpolate
/// between the "tiny + offset to click point" and "full-size + centred" states.
struct PopupTransform: ViewModifier {
    let scale:   CGFloat
    let offset:  CGSize
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)   // shrinks around its own centre
            .offset(offset)        // translates the (scaled) view to the click point
            .opacity(opacity)
    }
}

// MARK: - Frame capture helper

/// Tracks a view's frame in the `"appWindow"` coordinate space and writes
/// it to the supplied binding. Used to give popup-trigger buttons an
/// origin so the modal can scale up from the exact click position.
struct CaptureFrame: ViewModifier {
    @Binding var frame: CGRect

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { frame = geo.frame(in: .named("appWindow")) }
                    .onChange(of: geo.frame(in: .named("appWindow"))) { _, new in
                        frame = new
                    }
            }
        )
    }
}

extension View {
    func captureFrame(_ binding: Binding<CGRect>) -> some View {
        modifier(CaptureFrame(frame: binding))
    }
}
