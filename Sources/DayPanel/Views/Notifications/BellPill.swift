import SwiftUI

// Dynamic-Island-style notification surface anchored to the bell button.
// Lives as an overlay aligned to the bell's trailing edge so it can grow
// LEFTWARD across the toolbar without affecting layout (the bell stays
// in place; the pill just paints over the gap to its left).
//
// The trailing edge reserves space for the bell icon itself.

struct BellPill: View {
    @Environment(\.colorScheme) private var colorScheme

    let notification: AppNotification
    let onTap:        () -> Void
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
        HStack(spacing: 14) {
            Circle()
                .fill(toneColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(notification.title)
                    .font(Editorial.sans(14, .semibold))
                    .foregroundStyle(Editorial.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let m = notification.message, !m.isEmpty {
                    Text(notification.attributedMessage ?? AttributedString(m))
                        .font(Editorial.sans(12.5))
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
        .padding(.leading, 17)
        .padding(.trailing, 14)
        .padding(.vertical, 16)
        .frame(minHeight: 58)
        .fixedSize(horizontal: true, vertical: false)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: Editorial.notificationCapsuleRadius,
                                 style: .continuous),
            tint: Editorial.notificationGlassTint(for: colorScheme),
            // O material acompanha o tema; a cor semântica fica apenas no dot.
            // Não usamos fill sob o vidro porque isso achata a refração nativa.
            tintOpacity: Editorial.notificationGlassTintOpacity,
            interactive: false,
            lightweight: true
        )
        .contentShape(RoundedRectangle(cornerRadius: Editorial.notificationCapsuleRadius,
                                       style: .continuous))
        .capsuleHoverLift(tint: toneColor, scaleX: 1.008, scaleY: 1.025)
        .onTapGesture { onTap() }
    }
}

/// Live counterpart of `BellPill` used while an attachment is actually being
/// transferred. The value is fed by `AppState.uploadActivities`, whose progress
/// comes from URLSession's byte counters — no timer or simulated percentage.
struct BellUploadPill: View {
    @Environment(\.colorScheme) private var colorScheme

    let upload: AppState.UploadActivity
    let onTap: () -> Void
    let onDismiss: () -> Void

    private var progress: Double {
        max(0, min(1, upload.progress))
    }

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(Color(hex: "#1F7A3A"))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(upload.taskTitle)
                        .font(Editorial.sans(14, .semibold))
                        .foregroundStyle(Editorial.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 8)

                    Text("\(Int((progress * 100).rounded()))%")
                        .font(Editorial.sans(11, .semibold))
                        .foregroundStyle(Editorial.inkSoft)
                        .monospacedDigit()
                }

                Text(upload.fileName)
                    .font(Editorial.sans(12.5))
                    .foregroundStyle(Editorial.inkSoft)
                    .lineLimit(1)
                    .truncationMode(.middle)

                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Color(hex: "#1F7A3A"))
                    .frame(height: 3)
                    .animation(.linear(duration: 0.12), value: progress)
            }
            .frame(width: 330, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Editorial.inkMute)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(.leading, 17)
        .padding(.trailing, 14)
        .padding(.vertical, 14)
        .frame(minHeight: 72)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: Editorial.notificationCapsuleRadius,
                                 style: .continuous),
            tint: Editorial.notificationGlassTint(for: colorScheme),
            tintOpacity: Editorial.notificationGlassTintOpacity,
            interactive: false,
            lightweight: true
        )
        .contentShape(RoundedRectangle(cornerRadius: Editorial.notificationCapsuleRadius,
                                       style: .continuous))
        .capsuleHoverLift(tint: Editorial.ink, scaleX: 1.006, scaleY: 1.018)
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Enviando \(upload.fileName), \(Int((progress * 100).rounded())) por cento")
    }
}
