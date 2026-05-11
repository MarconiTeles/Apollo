import SwiftUI

// Dynamic-Island-style notification surface anchored to the bell button.
// Lives as an overlay aligned to the bell's trailing edge so it can grow
// LEFTWARD across the toolbar without affecting layout (the bell stays
// in place; the pill just paints over the gap to its left).
//
// The trailing edge reserves space for the bell icon itself.

struct BellPill: View {
    let notification: AppNotification
    let onTap:        () -> Void
    let onDismiss:    () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(notification.kind.tint.opacity(0.22))
                Image(systemName: notification.kind.systemImage)
                    .foregroundStyle(notification.kind.tint)
                    .font(.callout.weight(.semibold))
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(notification.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let m = notification.message, !m.isEmpty {
                    Text(notification.attributedMessage ?? AttributedString(m))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            // Cap the text column so very long messages can't bloat the
            // pill past a sensible width — anything longer truncates.
            .frame(maxWidth: 240, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            // Close button sits flush against the right edge of the pill.
            // (Visually it sits exactly where the bell icon was — the pill
            // covers the bell, so the X *is* the bell during expansion.)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(.secondary.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        // Pill sizes to its content (icon + capped text + close), so a
        // short notification stays compact while a longer one stretches
        // up to the text-column cap above.
        .frame(height: 44)
        .fixedSize(horizontal: true, vertical: false)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(notification.kind.tint.opacity(0.32), lineWidth: 1)
        )
        .shadow(color: notification.kind.tint.opacity(0.20), radius: 6, x: 0, y: 3)
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 5)
        .contentShape(Capsule())
        .onTapGesture { onTap() }
    }
}
