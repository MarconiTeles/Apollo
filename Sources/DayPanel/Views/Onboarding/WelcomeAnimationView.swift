import SwiftUI

/// Welcome splash. Plays on every app open. The very first open per
/// install runs the full cinematic ~3s sequence (logo → wordmark →
/// tagline, halo breathing, then fade out); every subsequent open
/// runs a compressed ~1s brand flash so the app still feels
/// "stamped" on launch without making the user wait.
///
/// Each phase below flips a `@State` boolean; the body's
/// `.opacity` / `.scaleEffect` / `.offset` modifiers animate via
/// implicit `.animation(_:value:)`. After the final fade completes,
/// `onComplete` fires so the host can clear the overlay.
struct WelcomeAnimationView: View {
    let isFirstLaunch: Bool
    let onComplete: () -> Void

    @State private var showHalo:    Bool = false
    @State private var showLogo:    Bool = false
    @State private var showName:    Bool = false
    @State private var showTagline: Bool = false
    @State private var fadingOut:   Bool = false
    /// Toggled once a second so the radial halo behind the wordmark
    /// breathes instead of sitting flat.
    @State private var pulseAlive:  Bool = false

    var body: some View {
        ZStack {
            // Splash surface — a solid window-coloured base PLUS a
            // diagonal accent gradient on top so the welcome reads
            // as a dedicated branded screen rather than a
            // translucent overlay. Combined with `ContentView`'s
            // persistent blur underneath, the dashboard is fully
            // hidden from frame zero. No fade-in: the surface is
            // there before any of the choreographed elements
            // appear.
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.18),
                    Color(hex: "#FF8A4C").opacity(0.10),
                    Color(hex: "#3F51B5").opacity(0.14)
                ],
                startPoint: .topLeading,
                endPoint:   .bottomTrailing
            )
            .ignoresSafeArea()

            haloLayer
                .opacity(fadingOut ? 0 : (showHalo ? 1 : 0))
                .scaleEffect(pulseAlive ? 1.08 : 0.95)
                .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                           value: pulseAlive)
                .animation(.easeInOut(duration: 0.55), value: showHalo)
                .animation(.easeInOut(duration: 0.55), value: fadingOut)
                .blur(radius: 40)
                .allowsHitTesting(false)

            VStack(spacing: 18) {
                logoView
                    .opacity(showLogo ? 1 : 0)
                    .scaleEffect(showLogo ? 1.0 : 0.55)
                    .animation(logoSpring, value: showLogo)

                // Wordmark + Beta pill, baseline-aligned so the
                // pill sits inline with the descender of "Apollo"
                // instead of floating above it.
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Apollo")
                        .font(.system(size: 56, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .tracking(0.5)
                    Text("BETA")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            LinearGradient(
                                colors: [Color.accentColor, Color(hex: "#FF8A4C")],
                                startPoint: .topLeading,
                                endPoint:   .bottomTrailing
                            ),
                            in: Capsule()
                        )
                        .shadow(color: Color.accentColor.opacity(0.35),
                                radius: 8, x: 0, y: 2)
                }
                .opacity(showName ? 1 : 0)
                .offset(y: showName ? 0 : 14)
                .animation(nameSpring, value: showName)

                Text("Sua agenda + tarefas em um só lugar")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .opacity(showTagline ? 1 : 0)
                    .offset(y: showTagline ? 0 : 8)
                    .animation(.easeOut(duration: 0.45), value: showTagline)
                    .padding(.horizontal, 24)
            }
            .scaleEffect(fadingOut ? 1.05 : 1.0)
            .opacity(fadingOut ? 0 : 1)
            .animation(.easeInOut(duration: 0.5), value: fadingOut)
        }
        // Fade the entire splash (opaque base + gradient + halo + text)
        // out together so the dashboard reveals smoothly instead of
        // hard-cutting once the choreography ends.
        .opacity(fadingOut ? 0 : 1)
        .animation(.easeInOut(duration: 0.5), value: fadingOut)
        // Swallow stray clicks during the splash without falling
        // through to toolbar buttons underneath.
        .contentShape(Rectangle())
        .onTapGesture { /* no-op */ }
        .onAppear { runSequence() }
    }

    // MARK: - Animation timings
    //
    // Compressed mode shortens the spring response so the logo and
    // wordmark don't spend half the 1-second budget mid-bounce.
    // First-launch keeps the longer, more cinematic feel.

    private var logoSpring: Animation {
        isFirstLaunch
            ? .spring(response: 0.55, dampingFraction: 0.62)
            : .spring(response: 0.30, dampingFraction: 0.72)
    }

    private var nameSpring: Animation {
        isFirstLaunch
            ? .spring(response: 0.55, dampingFraction: 0.78)
            : .spring(response: 0.30, dampingFraction: 0.85)
    }

    // MARK: - Layers

    private var logoView: some View {
        // Loaded via `AppIconLoader` so SwiftUI picks the
        // highest-res rep from the bundled .icns — was using
        // `NSWorkspace.icon(forFile:)` which served the small
        // Finder cache rep and got upscaled into a blurry mess.
        AppIconLoader.image
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 128, height: 128)
            .shadow(color: Color.accentColor.opacity(0.45),
                    radius: 32, x: 0, y: 12)
            .shadow(color: .black.opacity(0.35),
                    radius: 14, x: 0, y: 6)
    }

    private var haloLayer: some View {
        ZStack {
            RadialGradient(
                colors: [Color.accentColor.opacity(0.45), .clear],
                center: .center,
                startRadius: 10,
                endRadius: 220
            )
            RadialGradient(
                colors: [Color(hex: "#FF8A4C").opacity(0.30), .clear],
                center: UnitPoint(x: 0.35, y: 0.35),
                startRadius: 10,
                endRadius: 180
            )
            RadialGradient(
                colors: [Color(hex: "#3F51B5").opacity(0.25), .clear],
                center: UnitPoint(x: 0.65, y: 0.65),
                startRadius: 10,
                endRadius: 200
            )
        }
        .frame(width: 520, height: 520)
    }

    // MARK: - Choreography

    /// Schedules each phase of the animation. The first launch gets
    /// the full ~3s cinematic — logo, wordmark, tagline staggered in
    /// — so the user has a moment to take in the brand. Every later
    /// launch gets a ~1s flash where the logo + wordmark appear
    /// almost together, hold briefly, and fade out (tagline is
    /// skipped — it would only have time to flicker).
    private func runSequence() {
        showHalo   = true
        pulseAlive = true

        if isFirstLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { showLogo    = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { showName    = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { showTagline = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.55) { fadingOut   = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.05) { onComplete() }
        } else {
            // Compressed flash: logo + wordmark land together almost
            // immediately, hold for ~0.45s, then fade out. Tagline
            // stays hidden — at this duration it would just flicker.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                showLogo = true
                showName = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { fadingOut = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.00) { onComplete() }
        }
    }
}
