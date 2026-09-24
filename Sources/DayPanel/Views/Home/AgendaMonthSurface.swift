import AppKit
import SwiftUI

/// Keep the month's scrolling graph independent from the window's chrome and
/// the other list. AppKit supplies its viewport; the original view draws it.
struct AgendaMonthSurface: NSViewRepresentable {
    @Binding var month: Date
    let topInset: CGFloat
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        host.safeAreaRegions = []
        context.coordinator.update(self, host: host)
        return host
    }

    func updateNSView(_ host: NSHostingView<AnyView>, context: Context) {
        context.coordinator.update(self, host: host)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<AnyView>,
                      context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    private var content: AnyView {
        AnyView(AgendaMonthView(month: $month, topInset: topInset)
            .environmentObject(appState)
            .environment(\.colorScheme, colorScheme))
    }

    @MainActor final class Coordinator {
        private var inputs: Inputs?
        private struct Inputs: Equatable {
            let month: Date
            let inset: CGFloat
            let state: ObjectIdentifier
            let scheme: ColorScheme
        }
        func update(_ parent: AgendaMonthSurface, host: NSHostingView<AnyView>) {
            let next = Inputs(month: parent.month, inset: parent.topInset,
                              state: ObjectIdentifier(parent.appState),
                              scheme: parent.colorScheme)
            guard inputs != next else { return }
            inputs = next
            host.rootView = parent.content
        }
    }
}
