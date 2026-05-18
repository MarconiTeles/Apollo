import SwiftUI

/// Welcome splash, editorial. Plays on every app open. The very
/// first open per install runs the full cinematic ~3s sequence
/// (wordmark → rule → tagline, a soft cinnabar halo breathing,
/// then fade out); every subsequent open runs a compressed ~1s
/// brand flash so the app still feels "stamped" on launch without
/// making the user wait.
///
/// Redesign: the Apollo brand mark IS the typographic wordmark —
/// no icon/tile. A calm paper screen with the big New York serif
/// "Apollo" logotype, the single cinnabar BETA tag, a short
/// accent rule, the italic tagline, and one whisper-soft cinnabar
/// halo that breathes (the only chromatic flourish).
struct WelcomeAnimationView: View {
    let isFirstLaunch: Bool
    let onComplete: () -> Void

    @State private var showHalo:    Bool = false
    @State private var showName:    Bool = false
    @State private var showTagline: Bool = false
    @State private var fadingOut:   Bool = false
    /// Toggled once a second so the halo behind the wordmark
    /// breathes instead of sitting flat.
    @State private var pulseAlive:  Bool = false

    var body: some View {
        ZStack {
            // Editorial page — warm paper, no gradient wash. The
            // surface is there before any choreographed element so
            // the dashboard is hidden from frame zero.
            Editorial.paper
                .ignoresSafeArea()

            // A single whisper-soft cinnabar halo that breathes —
            // the only chromatic element.
            RadialGradient(
                colors: [Editorial.accent.opacity(0.10), .clear],
                center: .center,
                startRadius: 10,
                endRadius: 460
            )
            .frame(width: 560, height: 560)
            .blur(radius: 36)
            .opacity(fadingOut ? 0 : (showHalo ? 1 : 0))
            .scaleEffect(pulseAlive ? 1.06 : 0.95)
            .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true),
                       value: pulseAlive)
            .animation(.easeInOut(duration: 0.55), value: showHalo)
            .animation(.easeInOut(duration: 0.55), value: fadingOut)
            .allowsHitTesting(false)

            VStack(spacing: 20) {
                // The Apollo brand mark IS the wordmark — big New
                // York serif logotype with the single cinnabar
                // BETA tag (the only pill, matching Settings).
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("Apollo")
                        .font(Editorial.serif(66))
                        .foregroundStyle(Editorial.ink)
                        .tracking(-1.6)
                    Text("BETA")
                        .font(Editorial.sans(11, .semibold))
                        .tracking(1.5)
                        .foregroundStyle(Editorial.page)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Editorial.accent,
                                    in: RoundedRectangle(cornerRadius: 2,
                                                         style: .continuous))
                }
                .opacity(showName ? 1 : 0)
                .offset(y: showName ? 0 : 16)
                .scaleEffect(showName ? 1.0 : 0.94)
                .animation(nameSpring, value: showName)

                // Short cinnabar rule — the editorial "stamp"
                // under the mark, drawn in from the centre.
                Rectangle().fill(Editorial.accent)
                    .frame(width: 56, height: 2)
                    .opacity(showTagline ? 1 : 0)
                    .scaleEffect(x: showTagline ? 1 : 0.15, anchor: .center)
                    .animation(.easeOut(duration: 0.42), value: showTagline)

                Text("uma agenda que lê")
                    .font(Editorial.serif(17).italic())
                    .foregroundStyle(Editorial.inkSoft)
                    .multilineTextAlignment(.center)
                    .opacity(showTagline ? 1 : 0)
                    .offset(y: showTagline ? 0 : 8)
                    .animation(.easeOut(duration: 0.45).delay(0.05),
                               value: showTagline)
                    .padding(.horizontal, 24)
            }
            .scaleEffect(fadingOut ? 1.04 : 1.0)
            .opacity(fadingOut ? 0 : 1)
            .animation(.easeInOut(duration: 0.5), value: fadingOut)
        }
        .opacity(fadingOut ? 0 : 1)
        .animation(.easeInOut(duration: 0.5), value: fadingOut)
        // Swallow stray clicks during the splash without falling
        // through to toolbar buttons underneath.
        .contentShape(Rectangle())
        .onTapGesture { /* no-op */ }
        .onAppear { runSequence() }
    }

    // MARK: - Animation timings

    private var nameSpring: Animation {
        isFirstLaunch
            ? .spring(response: 0.55, dampingFraction: 0.80)
            : .spring(response: 0.30, dampingFraction: 0.86)
    }

    // MARK: - Choreography

    /// First launch gets the full ~3s cinematic — wordmark, rule,
    /// tagline staggered in. Every later launch gets a ~1s flash
    /// (wordmark alone, brief hold, fade; rule + tagline skipped).
    private func runSequence() {
        showHalo   = true
        pulseAlive = true

        if isFirstLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showName    = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.80) { showTagline = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.50) { fadingOut   = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.00) { onComplete() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { showName  = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { fadingOut = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.00) { onComplete() }
        }
    }
}
