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
    /// When true, the panel enters/exits with a Genie-style
    /// funnel-and-twist toward the trigger button instead of the
    /// plain scale-bounce. (A SwiftUI approximation of the macOS
    /// Dock genie — the literal OS warp is a private non-affine
    /// effect; this combines anisotropic shrink + perspective
    /// twist + funnel translation, which reads as the genie suck.)
    var genie: Bool = false
    /// When true, the panel enters/exits as a sheet of paper
    /// being placed on the desk — a calm "Editorial" settle:
    /// drops in a touch larger and higher with a slight 3D fall
    /// tilt and a hand-placed skew that straightens as it lands,
    /// with a soft shadow that tightens on touchdown. Takes
    /// precedence over `genie` when both are set.
    var paper: Bool = false
    /// When true, the panel slides UP from the bottom of the
    /// window (and slides back down on dismiss) — a sheet-from-
    /// footer entrance. Takes precedence over `paper` / `genie`
    /// when set.
    var fromBottom: Bool = false
    /// When true, the panel scales OUT OF (and back into) the
    /// `origin` rectangle with NO opacity fade — the popup grows
    /// from the clicked spot to full size and shrinks back into
    /// it on dismiss. Used by the Quadro board so the popup
    /// reads as the clicked card unfurling. Takes precedence
    /// over `fromBottom` / `paper` / `genie`.
    var scaleFromOrigin: Bool = false
    @ViewBuilder let content: () -> Content

    /// Genie timing — a fast, non-bouncy curve that accelerates
    /// the panel into / out of the button (springs read wrong for
    /// a "suck into the dock" motion).
    private var genieAnim: Animation {
        // Suction curve: a long, gentle hold near the wide end
        // then a hard acceleration into the focal point — the
        // characteristic "lingers, then gets yanked into the
        // Dock" cadence of the OS genie. Slightly longer than a
        // plain ease (0.55s) so the funnel/stretch phases have
        // room to read instead of blurring past.
        .timingCurve(0.45, 0.0, 0.15, 1.0, duration: 0.55)
    }

    /// Paper-settle timing — a calm spring with a hint of flex on
    /// touchdown (the sheet gives slightly as it meets the desk,
    /// then stills). Low bounce keeps it "Editorial Calm", not
    /// springy.
    private var paperAnim: Animation {
        .spring(response: 0.52, dampingFraction: 0.74)
    }

    /// Removal is quicker and damped flat — the sheet is lifted
    /// cleanly off the desk, no flex.
    private var paperDismissAnim: Animation {
        .spring(response: 0.40, dampingFraction: 0.92)
    }

    /// Slide-up-from-bottom timing — a calm spring with a hint
    /// of bounce at the top of the rise so the sheet "lands".
    /// Brought back after a brief ease-out experiment: the
    /// bounceless ease read as flat / cheap. Open and close
    /// durations are now in the same ~0.30 s ballpark; the
    /// spring is just under-damped enough to settle with a
    /// soft micro-bounce.
    private var bottomAnim: Animation {
        .spring(response: 0.34, dampingFraction: 0.86)
    }

    /// Dismiss for `fromBottom`: a smooth ease-in fall back down.
    /// Sprung dismisses asymptote near the end of the curve so
    /// the popup never visibly clears the window edge; a plain
    /// ease keeps the motion at full velocity through the bottom.
    private var bottomDismissAnim: Animation {
        .easeIn(duration: 0.30)
    }

    /// Scale-from-origin (Quadro morph) timing — symmetric
    /// spring for In and Out so the popup unfurls out of the
    /// card and folds back into it with matching cadence.
    /// Damping 0.86 keeps the bounce subtle (half of the
    /// previous 0.72) so the morph reads as crisp, not springy.
    private var scaleAnim: Animation {
        .spring(response: 0.34, dampingFraction: 0.86)
    }
    private var scaleDismissAnim: Animation {
        .spring(response: 0.34, dampingFraction: 0.96)
    }

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
                        // Backdrop fades — letting it slide
                        // down with the popup made the dim
                        // layer drag visibly across the
                        // dashboard during dismiss, which read
                        // worse than a clean fade-to-clear.
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
                        .transition(.opacity)   // see comment above
                        .onTapGesture { dismiss() }
                        .onHover { _ in }
                }

                content()
                    .transition(popupTransition)
            }
        }
        .animation(scaleFromOrigin
                    ? (isPresented ? scaleAnim : scaleDismissAnim)
                    : (fromBottom
                        ? (isPresented ? bottomAnim : bottomDismissAnim)
                        : (paper
                            ? (isPresented ? paperAnim : paperDismissAnim)
                            : (genie ? genieAnim
                                     // Default scale popup — bouncy
                                     // spring on open (same beat as
                                     // bottomAnim) and a clean ease
                                     // on dismiss so the popup never
                                     // hangs near zero scale.
                                     : (isPresented
                                         ? .spring(response: 0.34, dampingFraction: 0.86)
                                         : .easeIn(duration: 0.30))))),
                   value: isPresented)
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
        if scaleFromOrigin {
            // Standard scale-from-click-point transition with
            // opacity fade. Popup grows out of the clicked
            // BoardCard's centre (origin rect) from a small
            // scale to full size, and reverses on dismiss.
            // No "morph" — just the original scale animation.
            let active   = PopupTransform(scale: 0.05,
                                          offset: offsetDelta,
                                          opacity: 0)
            let identity = PopupTransform(scale: 1.0,
                                          offset: .zero,
                                          opacity: 1)
            return .asymmetric(
                insertion: .modifier(active: active, identity: identity),
                removal:   .modifier(active: active, identity: identity)
            )
        }
        if fromBottom {
            // Explicit Y-offset transition. `.move(edge: .bottom)`
            // translates the view by its OWN height, which for a
            // centred popup leaves the top edge still on-screen
            // at the end of the spring (the math is correct, the
            // optics aren't — looks like the sheet "stuck"
            // halfway). Using the window height as the travel
            // distance guarantees the sheet clears the visible
            // area in one straight motion, no opacity fade.
            let travel = max(windowSize.height, 900)
            return .asymmetric(
                insertion: .modifier(
                    active:   OffsetYModifier(y:  travel),
                    identity: OffsetYModifier(y:  0)
                ),
                removal: .modifier(
                    active:   OffsetYModifier(y:  travel),
                    identity: OffsetYModifier(y:  0)
                )
            )
        }
        if paper {
            let incoming = PaperSettleModifier(progress: 0, focal: offsetDelta)
            let resting  = PaperSettleModifier(progress: 1, focal: offsetDelta)
            return .asymmetric(
                insertion: .modifier(active: incoming, identity: resting),
                removal:   .modifier(active: incoming, identity: resting)
            )
        }
        if genie {
            // Entry inverts BOTH the rotation direction and its
            // easing curve (see GenieEffect); the exit keeps the
            // original suck so only the "fly out" spins the other
            // way, with the opposite curve.
            let inActive   = GenieModifier(progress: 0, focal: offsetDelta,
                                           invertRotation: true)
            let inIdentity = GenieModifier(progress: 1, focal: offsetDelta,
                                           invertRotation: true)
            let outActive  = GenieModifier(progress: 0, focal: offsetDelta,
                                           invertRotation: false)
            let outIdentity = GenieModifier(progress: 1, focal: offsetDelta,
                                            invertRotation: false)
            return .asymmetric(
                insertion: .modifier(active: inActive,  identity: inIdentity),
                removal:   .modifier(active: outActive, identity: outIdentity)
            )
        }
        let active   = PopupTransform(scale: 0.02, offset: offsetDelta, opacity: 0)
        let identity = PopupTransform(scale: 1.0,  offset: .zero,        opacity: 1)
        return .asymmetric(
            insertion: .modifier(active: active, identity: identity),
            removal:   .modifier(active: active, identity: identity)
        )
    }

    private func dismiss() {
        withAnimation(scaleFromOrigin
                        ? scaleDismissAnim
                        : (fromBottom
                            ? bottomDismissAnim
                            : (paper ? paperDismissAnim
                                     : (genie ? genieAnim
                                              // Default scale dismiss
                                              // is a clean ease so the
                                              // popup never hangs near
                                              // zero scale.
                                              : .easeIn(duration: 0.30))))) {
            isPresented = false
        }
    }
}

// MARK: - Paper-settle transition

/// "Editorial Calm" entrance: the panel is a sheet of paper drawn
/// out of the trigger button and set down on the desk. It emerges
/// small from the click point and grows into place while a gentle
/// 3-D fall tilt and a small hand-placed skew level out, and a
/// soft ink shadow tightens onto the page as it touches down.
/// Reversing the same modifier on removal pulls the sheet back
/// down into the button.
private struct PaperSettleModifier: ViewModifier, Animatable {
    /// 0 = incoming (small, at the click point), 1 = resting
    /// (full size, centred, flat on the desk).
    var progress: CGFloat
    /// Pixel delta from window centre → trigger-button centre, so
    /// the sheet flies in from / out to the exact click origin.
    let focal: CGSize

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = min(1, max(0, progress))
        let r = 1 - p                      // distance from the desk

        // Quick, soft fade so the sheet is readable almost
        // immediately and only the motion sells the entrance.
        let fade = Double(min(1, p * 2.4))

        // Scale: emerges as a small sheet from the button and
        // grows to full size. Stays large enough (0.30, not a
        // pinpoint) so it still reads as paper, not a dot.
        let startScale: CGFloat = 0.30
        let scale = startScale + (1 - startScale) * p

        // Position: travels from the click origin to the centred
        // resting place. `focal · r` puts the (scaled) sheet over
        // the trigger button at the start and at zero when settled.
        let dx = focal.width  * r
        let dy = focal.height * r

        // Fall tilt (top edge pitched back toward you) eases out as
        // it lands; small in-plane skew straightens on touchdown.
        let pitch = 11 * r                 // degrees, X axis
        let skew  = -2.2 * r               // degrees, Z axis

        // Shadow: large/soft/offset while airborne, tightening and
        // settling close as it meets the desk.
        let shadowRadius = 6 + 26 * r
        let shadowY      = 5 + 20 * r
        let shadowOpacity = 0.22 - 0.10 * r

        return content
            .rotation3DEffect(.degrees(pitch),
                              axis: (x: 1, y: 0, z: 0),
                              anchor: .center,
                              perspective: 0.55)
            .rotationEffect(.degrees(skew))
            .scaleEffect(scale)
            .offset(x: dx, y: dy)
            .shadow(color: Editorial.ink.opacity(shadowOpacity),
                    radius: shadowRadius, x: 0, y: shadowY)
            .opacity(fade)
    }
}

// MARK: - Genie transition

/// SwiftUI approximation of the macOS Dock "genie" — the panel
/// funnels toward the trigger button while narrowing horizontally
/// faster than vertically, with a perspective twist so it reads as
/// being *sucked* into the button rather than just scaled. Paired
/// with the non-bouncy `genieAnim` timing curve.
private struct GenieModifier: ViewModifier, Animatable {
    var progress: CGFloat          // 1 = full/centred, 0 = collapsed into focal
    let focal: CGSize              // delta from window centre → button centre
    /// On entry we flip the spin direction AND invert its easing
    /// curve so the surface unwinds the opposite way as it flies
    /// out of the button. Constant across a transition pair.
    var invertRotation: Bool = false

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let pc = min(1, max(0, progress))
        return content
            .modifier(GenieEffect(progress: progress, focal: focal,
                                  invertRotation: invertRotation))
            // Motion blur: scales with how far the surface is from
            // its resting state, so it smears while flying/funnelling
            // and resolves to perfectly crisp the instant it settles
            // (radius = 0 exactly at p = 1). The 1.3 power keeps the
            // blur subtle through the middle and only heavy near the
            // button, reading as speed rather than a soft focus.
            .blur(radius: 11 * pow(1 - pc, 1.3))
            // Stay almost fully opaque while it funnels — the OS
            // genie keeps the surface readable and only winks out
            // in the final ~18% as it disappears into the Dock.
            .opacity(Double(min(1, max(0, (progress - 0.02) * 5.5))))
    }
}

private struct GenieEffect: GeometryEffect {
    var progress: CGFloat
    let focal: CGSize
    var invertRotation: Bool = false

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let p  = max(0.0001, min(1, progress))
        let c  = 1 - p                       // collapse amount (0 full → 1 sucked in)

        // ── 1. Anisotropic shrink with a vertical STRETCH bump.
        // The width pinches hard and early (the "neck"); the
        // height first ELONGATES past 1.0 around the middle of
        // the collapse — the genie stretches tall and thin as it
        // gets sucked — then snaps down to nothing. `sin(π·c)`
        // peaks at the midpoint and is 0 at both ends, so the
        // resting state (p=1) is untouched.
        let sx      = pow(p, 2.4)
        let stretch = 1.0 + 0.42 * sin(.pi * c) * p
        let sy      = pow(p, 0.55) * stretch

        // ── 2. Curved funnel path toward the focal point.
        // A blend of linear + quadratic pull so the surface
        // *arcs* into the button (accelerating at the end)
        // instead of sliding there in a straight line.
        let c2 = c * c
        let tx = focal.width  * (0.30 * c + 0.70 * c2)
        let ty = focal.height * (0.24 * c + 0.76 * c2)

        let cx = size.width  / 2
        let cy = size.height / 2
        let dir = atan2(focal.height, focal.width)   // toward the trigger

        var m = CATransform3DIdentity
        // ── 3. Deep, eased perspective → the trailing edge
        // keystones into a trapezoid (the funnel taper) and the
        // whole surface reads as being pulled *through* a hole
        // rather than uniformly scaled. Ramps in on a 1.4 power
        // so the wide end stays flat and the spout bends late.
        m.m34 = -1.0 / 620.0 * pow(c, 1.4)
        m = CATransform3DTranslate(m, cx + tx, cy + ty, 0)
        m = CATransform3DScale(m, sx, sy, 1)
        // The spout curl (rotation about Y) + a slight lean toward
        // the focal direction (rotation about Z) so the funnel
        // bends the way the OS genie does — toward the Dock point,
        // not straight down.
        //
        // Exit keeps the original feel: linear Y, ease-in (c²) Z —
        // the twist stays put then resolves late as it sucks in.
        // ENTRY inverts the sign (it unwinds the other way) and is
        // WINDOWED to the first half of the flight: the rotation
        // is fully resolved by the animation midpoint (p = 0.5)
        // and stays at zero for the second half — the surface
        // finishes straightening out while it's still growing into
        // place. Within that first half it rides an ease-out curve
        // (the inverted complement of the exit's ease-in) so the
        // spin decelerates as it resolves instead of snapping.
        let rotSign: CGFloat = invertRotation ? -1 : 1
        // Windowed phase: 1 at p=0 → 0 at p≥0.5 (entry only).
        let rPhase   = max(0, min(1, (0.5 - p) / 0.5))
        let rEaseOut = rPhase * (2 - rPhase)             // ease-out of rPhase
        let yDrive: CGFloat  = invertRotation ? rEaseOut : c
        let zDrive: CGFloat  = invertRotation ? rEaseOut : c2
        m = CATransform3DRotate(m, rotSign * yDrive * 0.62,            0, 1, 0)
        m = CATransform3DRotate(m, rotSign * zDrive * 0.30 * sin(dir), 0, 0, 1)
        m = CATransform3DTranslate(m, -cx, -cy, 0)
        return ProjectionTransform(m)
    }
}

/// Animatable Y-offset modifier — used by the `fromBottom`
/// transition to translate the popup by the full window height
/// instead of `.move(edge:)`'s view-height default. Conforming
/// to `Animatable` lets the spring/ease driver interpolate the
/// `y` value smoothly each frame.
struct OffsetYModifier: ViewModifier, Animatable {
    var y: CGFloat

    var animatableData: CGFloat {
        get { y }
        set { y = newValue }
    }

    func body(content: Content) -> some View {
        content.offset(y: y)
    }
}

// (MorphFromRectModifier removed — Quadro now uses the standard
// scale-from-origin transition via PopupTransform.)

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
