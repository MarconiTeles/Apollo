import SwiftUI

/// Toolbar pill that surfaces the size of the offline-mutation
/// queue. Hidden when the queue is empty (the common case), so it
/// doesn't add chrome for users who are always online.
///
/// Wire-up: render somewhere visible inside the main toolbar bar
/// — `ContentView.toolbar` is the natural place, alongside the
/// sync-status indicator.
struct OfflineQueueIndicator: View {

    @ObservedObject private var queue = OfflineQueue.shared

    var body: some View {
        let count = queue.pending.count
        if count > 0 {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(count) " + (count == 1 ? "pendente" : "pendentes"))
                    .font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(Color.orange)
            .background(Color.orange.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.orange.opacity(0.4),
                                            lineWidth: 0.5))
            .help(tooltipText(count: count))
            .accessibilityLabel(
                "\(count) operações offline aguardando sincronização."
            )
            .transition(.scale.combined(with: .opacity))
            .animation(.spring(response: 0.4, dampingFraction: 0.85),
                       value: count)
        }
    }

    private func tooltipText(count: Int) -> String {
        if count == 1 {
            return "1 mudança ainda não sincronizou. Ela vai pro servidor assim que a internet voltar."
        }
        return "\(count) mudanças aguardando sincronização. Vão pro servidor automaticamente quando a internet voltar."
    }
}
