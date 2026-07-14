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
                // Prototype `pSlideIn`: rises 8pt + fades in.
                .transition(.asymmetric(
                    insertion: .offset(y: 8).combined(with: .opacity),
                    removal:   .opacity
                ))
            }
        }
        // Prototype `PToast`: anchored bottom-right.
        .padding(.bottom, 24)
        .padding(.trailing, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
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

    private var toneColor: Color {
        switch notification.kind {
        case .success: return Color(hex: "#1F7A3A")   // muted forest
        case .warning: return Color(hex: "#9C4A12")   // muted amber
        case .error:   return Editorial.accent        // cinnabar
        case .info:    return Editorial.ink
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(toneColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(notification.title)
                    .font(Editorial.sans(13.5, .semibold))
                    .foregroundStyle(Editorial.ink)
                if let s = notification.subtitle, !s.isEmpty {
                    Text(s)
                        .font(Editorial.sans(12))
                        .foregroundStyle(Editorial.inkSoft)
                        .lineLimit(1)
                }
                if let m = notification.message, !m.isEmpty {
                    // Same status-colour-aware rendering as the
                    // bell popup — see NotificationsCenterView.
                    Text(notification.attributedMessage ?? AttributedString(m))
                        .font(Editorial.sans(12))
                        .foregroundStyle(Editorial.inkSoft)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minWidth: 260, maxWidth: 380, alignment: .leading)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: Editorial.notificationCapsuleRadius,
                                 style: .continuous),
            tint: toneColor,
            tintOpacity: 0.022,
            interactive: false,
            lightweight: true
        )
        .contentShape(RoundedRectangle(cornerRadius: Editorial.notificationCapsuleRadius,
                                       style: .continuous))
        .capsuleHoverLift(tint: toneColor, scaleX: 1.008, scaleY: 1.025)
        .onTapGesture(perform: onDismiss)
    }
}
