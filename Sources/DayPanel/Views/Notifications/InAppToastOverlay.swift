import SwiftUI

// Top-right floating toast stack. Drains `appState.toastQueue` —
// anything pushed via `appState.notify(...)` slides into view, lives ~4
// seconds, then slides out. Up to 3 toasts visible simultaneously
// (oldest evicted as new ones arrive).

struct InAppToastOverlay: View {
    @EnvironmentObject var appState: AppState
    @State private var visible: [AppNotification] = []

    private let maxStack       = 3
    private let displaySeconds = 4.0

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(visible) { n in
                ToastCard(notification: n) {
                    dismiss(n.id)
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal:   .opacity
                ))
            }
        }
        .padding(.top, 60)         // clear the toolbar
        .padding(.trailing, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(!visible.isEmpty)
        .onChange(of: appState.toastQueue) { _, queue in
            // Drain anything new into the visible stack
            for n in queue where !visible.contains(where: { $0.id == n.id }) {
                push(n)
            }
            if !queue.isEmpty {
                Task { @MainActor in appState.toastQueue.removeAll() }
            }
        }
    }

    private func push(_ n: AppNotification) {
        withAnimation(.spring(duration: 0.35, bounce: 0.20)) {
            visible.append(n)
            if visible.count > maxStack {
                visible.removeFirst()
            }
        }
        // Schedule auto-dismiss
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(displaySeconds * 1_000_000_000))
            dismiss(n.id)
        }
    }

    private func dismiss(_ id: UUID) {
        guard visible.contains(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            visible.removeAll { $0.id == id }
        }
    }
}

// MARK: - Single toast card

private struct ToastCard: View {
    let notification: AppNotification
    let onDismiss:    () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notification.kind.systemImage)
                .font(.title3)
                .foregroundStyle(notification.kind.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(notification.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let s = notification.subtitle, !s.isEmpty {
                    Text(s)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1)
                }
                if let m = notification.message, !m.isEmpty {
                    // Same status-colour-aware rendering as the
                    // bell popup — see NotificationsCenterView.
                    Text(notification.attributedMessage ?? AttributedString(m))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 4)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(notification.kind.tint.opacity(0.30), lineWidth: 0.5)
        )
        .shadow(color: notification.kind.tint.opacity(0.15), radius: 4, x: 0, y: 2)
        .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
    }
}
