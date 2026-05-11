import SwiftUI

struct SyncButton: View {
    let status: SyncStatus
    let action: () -> Void

    @State private var rotation: Double = 0

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .rotationEffect(.degrees(rotation))
                .frame(width: 28, height: 28)
                .background(.regularMaterial, in: Circle())
                .liquidGlassEdge(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(status.isAnimating)
        .help("Sincronizar agora (⌘R)")
        .onChange(of: status.isAnimating) { _, animating in
            if animating {
                withAnimation(.linear(duration: 0.7).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            } else {
                withAnimation(.default) { rotation = 0 }
            }
        }
    }
}
