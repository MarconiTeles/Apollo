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
            if let activity = updateService.backgroundActivity {
                activityBody(activity)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
            } else if let update = updateService.availableUpdate {
                bannerBody(for: update)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal:   .opacity
                    ))
            }
        }
        .animation(spring, value: updateService.availableUpdate)
        .animation(spring, value: updateService.backgroundActivity)
    }

    @ViewBuilder
    private func activityBody(_ activity: UpdateService.BackgroundActivity) -> some View {
        HStack(spacing: 12) {
            activityIndicator(activity)

            VStack(alignment: .leading, spacing: 3) {
                Text(activityTitle(activity))
                    .font(Editorial.sans(12.5, .semibold))
                    .foregroundStyle(Editorial.page)
                if let fraction = activity.fraction {
                    GeometryReader { geo in
                        Capsule()
                            .fill(Editorial.page.opacity(0.18))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(Editorial.page)
                                    .frame(width: max(4, geo.size.width * CGFloat(fraction)))
                            }
                    }
                    .frame(width: 170, height: 4)
                    .animation(.easeOut(duration: 0.18), value: fraction)
                }
            }

            Spacer(minLength: 8)

            Button("Abrir") { updateService.presentUpdateUI() }
                .font(Editorial.sans(12, .semibold))
                .foregroundStyle(Editorial.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Editorial.page, in: RoundedRectangle(cornerRadius: 3,
                                                                  style: .continuous))
                .buttonStyle(.plain)
                .focusEffectDisabled()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Editorial.ink, in: RoundedRectangle(cornerRadius: 4,
                                                         style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
        .frame(maxWidth: 420)
    }

    @ViewBuilder
    private func activityIndicator(_ activity: UpdateService.BackgroundActivity) -> some View {
        switch activity {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.red)
        case .downloading, .extracting, .installing:
            ProgressView()
                .controlSize(.small)
                .tint(Editorial.page)
        }
    }

    private func activityTitle(_ activity: UpdateService.BackgroundActivity) -> String {
        switch activity {
        case let .downloading(fraction):
            guard let fraction else { return "Iniciando download em segundo plano…" }
            return "Baixando atualização · \(Int(fraction * 100))%"
        case let .extracting(fraction):
            return "Preparando atualização · \(Int(fraction * 100))%"
        case .installing:
            return "Instalando atualização…"
        case let .ready(version):
            return version.isEmpty
                ? "Atualização pronta para instalar"
                : "Apollo \(version) pronto para instalar"
        case .failed:
            return "Falha ao baixar atualização"
        }
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

private extension UpdateService.BackgroundActivity {
    var fraction: Double? {
        switch self {
        case let .downloading(value): return value
        case let .extracting(value): return value
        case .installing, .ready, .failed: return nil
        }
    }
}
