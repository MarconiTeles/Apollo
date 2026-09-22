import SwiftUI

// Apollo · global "something is syncing" indicator.
//
// A 2pt-tall accent stripe that animates across the top of the
// chrome whenever `appState.activeSyncCount > 0`. Universal — any
// async operation that calls `appState.tracked { … }` or manages
// the counter directly lights this up automatically, no per-view
// glue needed.
//
// Inspired by YouTube/Notion/Linear's indeterminate top progress
// bars: present when work is in flight, gracefully fades when
// it's gone, never blocks input.

struct EditorialSyncBar: View {
    @EnvironmentObject var appState: AppState

    /// Drives the animated stripe sweep. Restarts the loop each
    /// time `isSyncing` flips to true so we always begin at the
    /// leading edge — no half-finished sweep stranded mid-rail.
    @State private var phase: CGFloat = 0
    @State private var animating: Bool = false

    var body: some View {
        GeometryReader { geo in
            let width    = geo.size.width
            let stripeW  = width * 0.35      // 35% of bar
            ZStack(alignment: .leading) {
                // Track — barely-there hairline so the bar's
                // rail is visible even when no sync is running
                // (helps the eye anchor the sweep).
                Rectangle()
                    .fill(Editorial.rule.opacity(0.35))
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .center)

                // Sweep — accent gradient sliding L→R on loop
                // while `isSyncing` is true; gracefully fades on
                // completion via the outer opacity animation.
                LinearGradient(
                    colors: [
                        Editorial.accent.opacity(0.0),
                        Editorial.accent.opacity(0.85),
                        Editorial.accent.opacity(0.0),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: stripeW, height: 2)
                .offset(x: phase * (width + stripeW) - stripeW)
            }
            .opacity(appState.isSyncing ? 1 : 0)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.22), value: appState.isSyncing)
        .onChange(of: appState.isSyncing) { _, syncing in
            if syncing { startLoop() } else { stopLoop() }
        }
        .onAppear { if appState.isSyncing { startLoop() } }
    }

    private func startLoop() {
        guard !animating else { return }
        animating = true
        // Reset to leading then animate to trailing, repeating
        // forever (without auto-reverse — looks like a flowing
        // sweep, not a pendulum).
        phase = 0
        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }

    private func stopLoop() {
        animating = false
        // Snap back to leading so the next start is clean. No
        // animation block here — we want this to be invisible
        // (bar is already fading out via the opacity transition).
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { phase = 0 }
    }
}
