import SwiftUI

// Lunar loading placeholders.
//
// Every skeleton on screen is lit by the SAME light: a curved terminator
// front — the edge of sunlight crossing the moon, as in the launch splash —
// sweeping across the window from the left on one global clock. Rows,
// cards and columns rendered by different views light up in sequence as
// the front passes, so the whole page reads as one surface being revealed
// rather than a dozen independent shimmers.
//
// Usage: draw the placeholder *shapes* with `LunarSkeleton` fills (they are
// a mask — only their alpha matters) inside `LunarSkeletonSurface { … }`.
// The surface paints the resting tone and the moving light through them.

enum LunarSkeleton {
    /// Mask fills. Alpha sets each shape's tone relative to the base rule.
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.62)
    static let faint = Color.white.opacity(0.42)

    /// Sweep timing: 2.1 s crossing + 0.7 s of rest, looping.
    static let sweepDuration: TimeInterval = 2.1
    static let period: TimeInterval = 2.8

    /// The terminator is an arc of a huge circle centred far off-screen to
    /// the left, so its front is gently curved, like the real one.
    static let centre = CGPoint(x: -1400, y: 380)
    static let startRadius: CGFloat = 1300
    static let travel: CGFloat = 3200

    /// Progress of the front at `date`, 0…1, or nil while resting. Derived
    /// from wall-clock time, so every surface agrees without coordination.
    static func sweepProgress(at date: Date) -> CGFloat? {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        guard t < sweepDuration else { return nil }
        return CGFloat(t / sweepDuration)
    }
}

struct LunarSkeletonSurface<Shapes: View>: View {
    @ViewBuilder var shapes: Shapes

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var frame: CGRect = .zero
    @State private var shown = false
    @State private var breathing = false

    var body: some View {
        // Laid out by the shapes themselves (hidden), with the fill drawn
        // over exactly that box: the surface is as tall as its content, and
        // content taller than its container overflows downward from the top
        // (to be clipped by the caller) instead of being centred.
        shapes
            .hidden()
            .overlay(alignment: .top) {
                if reduceMotion {
                    // Reduced motion: no travelling light — a slow, gentle
                    // opacity breath still says "loading".
                    Rectangle()
                        .fill(Editorial.rule)
                        .mask(alignment: .top) { shapes }
                        .opacity(breathing ? 1 : 0.55)
                        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                                   value: breathing)
                        .onAppear { breathing = true }
                } else {
                    // Qualified: the app defines its own `TimelineView` (calendar).
                    SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                        ZStack {
                            Rectangle().fill(Editorial.rule)
                            if let progress = LunarSkeleton.sweepProgress(at: context.date) {
                                terminator(progress: progress)
                            }
                        }
                        .mask(alignment: .top) { shapes }
                    }
                }
            }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        // Held back 120 ms so fast loads never flash a placeholder, then
        // faded in. Opacity only — the layout is already in place.
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.24).delay(0.12)) {
                shown = true
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func terminator(progress: CGFloat) -> some View {
        let radius = LunarSkeleton.startRadius + LunarSkeleton.travel * progress
        let outer = radius + 90
        let glow = colorScheme == .dark
            ? Color(red: 0.80, green: 0.93, blue: 1.0).opacity(0.24)
            : Color.white.opacity(0.9)
        let size = CGSize(width: max(frame.width, 1), height: max(frame.height, 1))
        let centre = UnitPoint(
            x: (LunarSkeleton.centre.x - frame.minX) / size.width,
            y: (LunarSkeleton.centre.y - frame.minY) / size.height
        )
        // Long soft lit side behind the front, crisp leading edge ahead of it.
        return RadialGradient(
            stops: [
                .init(color: glow.opacity(0), location: max(0, (radius - 360) / outer)),
                .init(color: glow.opacity(0.55), location: (radius - 60) / outer),
                .init(color: glow, location: radius / outer),
                .init(color: glow.opacity(0), location: 1),
            ],
            center: centre,
            startRadius: 0,
            endRadius: outer
        )
    }
}
