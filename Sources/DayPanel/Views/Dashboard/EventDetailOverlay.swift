import SwiftUI

// Foreground modal that scales up from the tapped event pill's location
// with a spring-bounce, and scales back down on dismiss. Replaces the
// system .sheet so we can control the origin and easing.

struct EventDetailOverlay: View {
    @EnvironmentObject var appState: AppState
    let windowSize: CGSize

    var body: some View {
        ZStack {
            if let event = appState.detailEvent {
                // Backdrop fades — sliding the dim layer down
                // with the popup made it visibly drag across
                // the dashboard during dismiss, which read
                // worse than a clean fade-to-clear.
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { dismiss() }
                    // Empty `.onHover` registers an NSTrackingArea on
                    // the backdrop so hover events stop here instead
                    // of leaking through to the dashboard rows behind.
                    // SwiftUI's `.allowsHitTesting(false)` does NOT
                    // disable already-installed tracking areas on
                    // hosting views — the backdrop has to be the
                    // one swallowing hover for it to actually stop.
                    .onHover { _ in }

                // Popup centred in the app window with the
                // SAME slide-up-from-bottom animation as the
                // settings sheet (and now TaskDetail + Apollo
                // IA). Keeps every Editorial overlay on a
                // single, recognisable in/out cadence so the
                // chrome feels unified.
                // Explicit Y-offset transition (same reasoning
                // as FloatingModal.fromBottom): `.move(edge:)`
                // translates by the view's own height and the
                // popup gets stuck halfway. Window-height
                // travel guarantees a clean clearance.
                let travel = max(windowSize.height, 900)
                EventDetailView(event: event, onClose: dismiss)
                    .transition(.asymmetric(
                        insertion: .modifier(
                            active:   OffsetYModifier(y: travel),
                            identity: OffsetYModifier(y: 0)
                        ),
                        removal: .modifier(
                            active:   OffsetYModifier(y: travel),
                            identity: OffsetYModifier(y: 0)
                        )
                    ))
            }
        }
        // Bouncy spring on open (same beat as FloatingModal's
        // bottomAnim) so the rise feels alive instead of flat;
        // dismiss path below uses a clean ease so it doesn't
        // asymptote near the bottom of the slide.
        .animation(.spring(response: 0.34, dampingFraction: 0.86),
                   value: appState.detailEvent?.id)
    }

    private func dismiss() {
        withAnimation(.easeIn(duration: 0.30)) {
            appState.detailEvent = nil
        }
    }
}
