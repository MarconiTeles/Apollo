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

    /// Prototype `PToast` tone colours — the 3px left bar is the
    /// only chromatic element; everything else is editorial paper +
    /// ink. No saturated web hues, no tinted glow.
    private var toneColor: Color {
        switch notification.kind {
        case .success: return Color(hex: "#1F7A3A")   // muted forest
        case .warning: return Color(hex: "#9C4A12")   // muted amber
        case .error:   return Editorial.accent        // cinnabar
        case .info:    return Editorial.ink
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(notification.title)
                    .font(Editorial.serif(15, .medium))
                    .foregroundStyle(Editorial.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let m = notification.message, !m.isEmpty {
                    Text(notification.attributedMessage ?? AttributedString(m))
                        .font(Editorial.serif(13).italic())
                        .foregroundStyle(Editorial.inkSoft)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            // Cap the text column so very long messages can't bloat the
            // pill past a sensible width — anything longer truncates.
            .frame(maxWidth: 360, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Editorial.inkMute)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(.leading, 22)
        .padding(.trailing, 14)
        .padding(.vertical, 16)
        .frame(minHeight: 58)
        .fixedSize(horizontal: true, vertical: false)
        .background(Editorial.card)
        .overlay(alignment: .leading) {
            // 4px tone bar — the prototype's only chromatic cue.
            Rectangle().fill(toneColor).frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Editorial.rule, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.20), radius: 28, x: 0, y: 10)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}
