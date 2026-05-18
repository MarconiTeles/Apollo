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
        // Prototype `PUpdateBanner`: ink surface, cream type, a
        // single cinnabar dot, and a page-on-ink "Atualizar"
        // button. No glass.
        HStack(spacing: 12) {
            Circle()
                .fill(Editorial.accent)
                .frame(width: 6, height: 6)

            (Text("Apollo ")
                .font(Editorial.serif(14).italic())
             + Text(update.version)
                .font(Editorial.serif(14, .medium))
             + Text(" disponível")
                .font(Editorial.serif(14).italic()))
                .foregroundStyle(Editorial.page)

            Text(secondaryLine(for: update))
                .font(Editorial.sans(11.5))
                .foregroundStyle(Editorial.page.opacity(0.5))
                .lineLimit(1)

            Spacer(minLength: 12)

            Button {
                updateService.presentUpdateUI()
            } label: {
                Text("Atualizar")
                    .font(Editorial.sans(12, .semibold))
                    .foregroundStyle(Editorial.ink)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Editorial.page))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .keyboardShortcut(.return, modifiers: [])

            Button {
                updateService.dismissBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Editorial.page.opacity(0.6))
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dispensar até a próxima verificação")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Editorial.ink)
        )
        .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
        .frame(maxWidth: 420)
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
