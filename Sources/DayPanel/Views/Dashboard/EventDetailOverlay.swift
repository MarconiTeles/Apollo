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

                // Popup centred in the app window — was previously
                // translated to the tapped pill's origin via
                // `offsetDelta`, but the bigger popup made that
                // off-centre placement read as misaligned. Now
                // it springs out from the window centre, which
                // matches `TaskDetailSheet` (also centred) and
                // gives every event the same calm landing spot.
                EventDetailView(event: event, onClose: dismiss)
                    .transition(.asymmetric(
                        insertion: .modifier(
                            active:   PopupTransform(scale: 0.02, offset: .zero, opacity: 0),
                            identity: PopupTransform(scale: 1.0,  offset: .zero, opacity: 1)
                        ),
                        removal: .modifier(
                            active:   PopupTransform(scale: 0.02, offset: .zero, opacity: 0),
                            identity: PopupTransform(scale: 1.0,  offset: .zero, opacity: 1)
                        )
                    ))
            }
        }
        .animation(.spring(duration: 0.45, bounce: 0.30), value: appState.detailEvent?.id)
    }

    private func dismiss() {
        withAnimation(.spring(duration: 0.40, bounce: 0.20)) {
            appState.detailEvent = nil
        }
    }
}
