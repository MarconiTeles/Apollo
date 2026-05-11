import SwiftUI

/// Persistent, non-modal banner that announces a pending Sparkle
/// update without grabbing focus. Sits as an overlay anchored to
/// the bottom-trailing corner of the main window so it doesn't
/// interfere with the dashboard scroll or filter pills at the top.
///
/// Lifecycle:
/// - Appears when `UpdateService.availableUpdate` becomes non-nil
///   (Sparkle's `didFindValidUpdate` delegate callback).
/// - "Atualizar" → calls `presentUpdateUI()` → Sparkle's standard
///   "found update / install / relaunch" flow.
/// - X / Esc → calls `dismissBanner()` → hides until the next
///   scheduled background check re-fires.
struct UpdateAvailableBanner: View {

    @ObservedObject var updateService: UpdateService

    /// Sliding fade animation when the banner enters/exits — paired
    /// with `.transition(.move(edge: .bottom).combined(with: .opacity))`
    /// inside the body so the same spring drives both.
    private let spring: Animation = .spring(response: 0.45, dampingFraction: 0.86)

    var body: some View {
        Group {
            if let update = updateService.availableUpdate {
                bannerBody(for: update)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal:   .opacity
                    ))
            }
        }
        .animation(spring, value: updateService.availableUpdate)
    }

    @ViewBuilder
    private func bannerBody(for update: AvailableUpdate) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: 28, height: 28)
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Apollo \(update.version) disponível")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(secondaryLine(for: update))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button("Atualizar") {
                updateService.presentUpdateUI()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.return, modifiers: [])

            Button {
                updateService.dismissBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.secondary.opacity(0.75))
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dispensar até a próxima verificação")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .frame(maxWidth: 360)
    }

    /// Secondary line — friendly relative date if we have a
    /// `pubDate`, otherwise a generic CTA.
    private func secondaryLine(for update: AvailableUpdate) -> String {
        guard let date = update.pubDate else {
            return "Toque em Atualizar para instalar"
        }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .full
        fmt.locale = Locale(identifier: "pt_BR")
        let rel = fmt.localizedString(for: date, relativeTo: Date())
        return "Lançada \(rel)"
    }
}
