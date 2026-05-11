import SwiftUI

struct StatusIndicator: View {
    let status: SyncStatus
    /// When false, renders only the colored dot (no "agora"/"sincronizando…" label).
    var showLabel: Bool = true

    private var dotColor: Color {
        switch status {
        case .idle:    return .gray.opacity(0.6)
        case .syncing: return .blue
        case .success: return .green
        case .error:   return .red
        case .offline: return .orange
        }
    }

    private var isPulsing: Bool { status.isAnimating }

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                // Glow for active states. The Circle always
                // occupies the slot — only its opacity changes —
                // so the ZStack's layout footprint stays fixed
                // at 10×10 in BOTH states. Previously the glow
                // was conditionally inserted, which made the
                // outer pill (bell + status dot in the toolbar)
                // grow/shrink every time sync flipped between
                // idle and syncing. The dot stayed in place but
                // the parent HStack reflowed.
                Circle()
                    .fill(dotColor.opacity(isPulsing ? 0.35 : 0))
                    .frame(width: 10, height: 10)
                    .blur(radius: 2)
                Circle()
                    .fill(dotColor)
                    .frame(width: 5.5, height: 5.5)
            }
            .frame(width: 10, height: 10)
            .animation(.easeInOut(duration: 0.4), value: dotColor)
            .animation(.easeInOut(duration: 0.4), value: isPulsing)

            if showLabel {
                Text(status.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 46, alignment: .leading)
            }
        }
    }
}
