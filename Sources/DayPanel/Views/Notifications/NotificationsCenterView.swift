import SwiftUI

// Notifications Center popup — opened via the bell icon in the toolbar.
// Lists every persisted in-app notification (newest first), with mark
// read / dismiss controls.

struct NotificationsCenterView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var updateService: UpdateService
    @Environment(\.windowSize) private var windowSize
    var onClose: () -> Void = {}

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Editorial.popupRadius(6), style: .continuous)
    }

    private var topBarShape: UnevenRoundedRectangle {
        let radius = Editorial.popupRadius(6)
        return UnevenRoundedRectangle(topLeadingRadius: radius,
                                      bottomLeadingRadius: 0,
                                      bottomTrailingRadius: 0,
                                      topTrailingRadius: radius,
                                      style: .continuous)
    }

    private var bottomBarShape: UnevenRoundedRectangle {
        let radius = Editorial.popupRadius(6)
        return UnevenRoundedRectangle(topLeadingRadius: 0,
                                      bottomLeadingRadius: radius,
                                      bottomTrailingRadius: radius,
                                      topTrailingRadius: 0,
                                      style: .continuous)
    }

    private let topBarHeight: CGFloat = 58
    private let bottomBarHeight: CGFloat = 54

    /// Cap the scrollable list relative to the window so the
    /// panel never pushes off-screen on small windows. Side-
    /// panel mode (current) uses almost the full window height
    /// — the wrapper in ContentView reserves the toolbar band
    /// at the top and a small bottom margin; here we just
    /// subtract the chrome (header + footer + dividers) so the
    /// scroll region exactly fits the rest.
    private var maxScrollHeight: CGFloat {
        let h = windowSize.height
        guard h > 0 else { return 380 }
        // ~62pt toolbar reserve + 24pt bottom = 86pt outer
        // wrapper. Internal chrome (header + footer + borders)
        // ≈ 110pt. The rest is the scrollable list.
        return max(220, h - 86)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if let activity = updateService.backgroundActivity {
                    ScrollablePopupContent(maxHeight: maxScrollHeight,
                                           clipDisabled: true) {
                        LazyVStack(spacing: 9) {
                            Color.clear.frame(height: topBarHeight + 14)
                            BackgroundUpdateNotificationRow(
                                activity: activity,
                                onOpen: { updateService.presentUpdateUI() }
                            )
                            uploadRows
                            notificationRows
                            Color.clear.frame(height: footerReserve + 14)
                        }
                        .padding(.horizontal, 20)
                    }
                }
                else if appState.notifications.isEmpty
                            && appState.uploadActivities.isEmpty {
                    // Fill the remaining height so the header stays pinned to
                    // the top (the outer maxHeight frame would otherwise centre
                    // the short content, dropping the header to the middle).
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, topBarHeight)
                } else if appState.uploadActivities.isEmpty {
                    // Same recycled native feed used by the Home Inbox.
                    // Header/footer remain the only Liquid Glass layers and
                    // the collection scrolls underneath them. The larger top
                    // and bottom insets are transparent reserves, not nested
                    // panels, so rows remain visible through the glass while
                    // avoiding one SwiftUI hover/shadow graph per item.
                    InboxAppKitList(
                        notifications: appState.notifications,
                        onDismiss: appState.removeNotification,
                        onTap: { notification in
                            if notification.hasTarget {
                                appState.openNotificationTarget(notification)
                                onClose()
                            } else {
                                appState.markNotificationRead(notification.id)
                            }
                        },
                        topInset: topBarHeight + 14,
                        bottomInset: footerReserve + 14,
                        horizontalInset: 20
                    )
                } else {
                    // Upload progress rows are intentionally kept in the
                    // mixed SwiftUI feed: they are few, transient and update
                    // live. The common notification-only path above carries
                    // the potentially large history in a recycled viewport.
                    ScrollablePopupContent(maxHeight: maxScrollHeight,
                                           clipDisabled: true) {
                        LazyVStack(spacing: 9) {
                            Color.clear.frame(height: topBarHeight + 14)
                            uploadRows
                            notificationRows
                            Color.clear.frame(height: footerReserve + 14)
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }

            header
                .frame(height: topBarHeight)
                // Material OFICIAL do header (mesma receita de Tarefas).
                .officialHeaderMaterial(in: topBarShape)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Editorial.rule).frame(height: 1)
                }
                .zIndex(30)

            if hasFeedContent {
                footer
                    .frame(height: bottomBarHeight)
                    .officialHeaderMaterial(in: bottomBarShape)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Editorial.rule).frame(height: 1)
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .zIndex(30)
            }
        }
        // Tall side-panel layout (was a compact dropdown). Width
        // bumped from 360 → 440 for breathing room and the
        // vertical sizing flips to fill the available height —
        // the wrapper in ContentView pads top/bottom so the
        // panel hangs from below the toolbar to near the window
        // bottom, matching the prototype's right-side rail.
        .frame(width: 440)
        .frame(maxHeight: .infinity)
        .solidPopupSurface(in: shape)
        .apolloStudioNode("notifications.feed",
                          title: "Feed de notificações",
                          kind: .list,
                          parent: "notifications.panel",
                          properties: [
                            .init(kind: .width, title: "Largura", value: 440),
                            .init(kind: .cornerRadius,
                                  title: "Raio", token: "Editorial.popupRadius"),
                          ])
    }

    private var footerReserve: CGFloat {
        hasFeedContent ? bottomBarHeight : 0
    }

    private var hasFeedContent: Bool {
        !appState.notifications.isEmpty || !appState.uploadActivities.isEmpty
    }

    @ViewBuilder
    private var notificationRows: some View {
        ForEach(appState.notifications) { n in
            NotificationRow(notification: n,
                            onDismiss: {
                                withAnimation(.spring(duration: 0.35, bounce: 0.20)) {
                                    appState.removeNotification(n.id)
                                }
                            },
                            onTap: {
                                if n.hasTarget {
                                    appState.openNotificationTarget(n)
                                    onClose()
                                } else {
                                    appState.markNotificationRead(n.id)
                                }
                            })
                .equatable()
                .transition(.asymmetric(
                    insertion: .move(edge: .top)
                        .combined(with: .scale(scale: 0.92))
                        .combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
        }
    }

    @ViewBuilder
    private var uploadRows: some View {
        ForEach(appState.uploadActivities) { upload in
            UploadActivityRow(upload: upload)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Editorial.inkSoft)
            Text("Notificações")
                .font(Editorial.sans(16, .semibold))
                .foregroundStyle(Editorial.ink)
            if headerBadgeCount > 0 {
                Text(headerBadgeCount > 99 ? "99+" : "\(headerBadgeCount)")
                    .font(Editorial.sans(10.5, .bold))
                    .foregroundStyle(Editorial.page)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Editorial.accent))
            }
            Spacer(minLength: 0)
            Button {
                appState.markAllNotificationsRead()
            } label: {
                Text("Marcar lidas")
                    .font(Editorial.sans(12, .medium))
                    .foregroundStyle(appState.unreadNotifications == 0
                                     ? Editorial.inkMute : Editorial.ink)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .liquidGlassCapsule(tint: Editorial.ink, tintOpacity: 0.07)
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .glassHover()
            .disabled(appState.unreadNotifications == 0)

            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Editorial.inkSoft)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .apolloStudioNode("notifications.header",
                          title: "Barra superior de notificações",
                          kind: .header,
                          parent: "notifications.panel",
                          properties: [
                            .init(kind: .horizontalPadding,
                                  title: "Padding horizontal", value: 20),
                            .init(kind: .verticalPadding,
                                  title: "Padding vertical", value: 14),
                            .init(kind: .material,
                                  title: "Material", token: "Materials.popupBar"),
                          ])
    }

    private var headerBadgeCount: Int {
        appState.unreadNotifications
            + appState.uploadActivities.filter { $0.state == .uploading }.count
            + (updateService.backgroundActivity == nil ? 0 : 1)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Editorial.inkMute)
            Text("Nenhuma notificação ainda")
                .font(Editorial.sans(15, .semibold))
                .foregroundStyle(Editorial.ink)
            Caption("Atualizações de sincronização, eventos e tarefas vão aparecer aqui.",
                    size: 12.5)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                appState.markAllNotificationsRead()
            } label: {
                Text("Marcar como lidas")
                    .font(Editorial.sans(12, .medium))
                    .foregroundStyle(appState.unreadNotifications == 0
                                     ? Editorial.inkMute : Editorial.ink)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .liquidGlassCapsule(tint: Editorial.ink, tintOpacity: 0.07)
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .glassHover()
            .disabled(appState.unreadNotifications == 0)

            Spacer(minLength: 0)

            Button {
                appState.clearAllNotifications()
            } label: {
                Text("Limpar tudo")
                    .font(Editorial.sans(12, .medium))
                    .foregroundStyle(Editorial.ink)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .liquidGlassCapsule(tint: Editorial.ink, tintOpacity: 0.07)
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .glassHover()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - Single notification row

struct NotificationRow: View, Equatable {
    let notification: AppNotification
    let onDismiss: () -> Void
    let onTap:     () -> Void

    /// Compare only the value-typed `notification` — closures
    /// can't be compared, but they're stable for the row's
    /// lifetime anyway. `.equatable()` on the ForEach side
    /// short-circuits SwiftUI body re-evaluation when the
    /// notification hasn't changed, so unrelated `appState`
    /// mutations don't re-render every visible row.
    static func == (lhs: NotificationRow, rhs: NotificationRow) -> Bool {
        lhs.notification == rhs.notification
    }

    /// Resolve exclusively from the immutable notification payload. Keeping
    /// `AppState` out of every row prevents unrelated sync/progress mutations
    /// from invalidating all visible Inbox capsules while they scroll.
    private var targetTint: Color {
        if notification.targetKind == .task,
           let hex = notification.messageHighlights?.last?.hex {
            return Color(statusHex: hex)
        }
        return notification.kind.tint
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    // Exactly two visual lines. Source, title, time and
                    // dismiss live on line one; contextual copy and the
                    // target action share line two. Long ClickUp titles
                    // truncate instead of making the inbox row grow.
                    HStack(spacing: 7) {
                        Text(sourceLabel)
                            .font(Editorial.sans(8.5, .semibold))
                            .tracking(1.0)
                            .foregroundStyle(targetTint.editorialMuted)
                            .fixedSize()
                        Text(notification.title)
                            .font(Editorial.sans(13.5, .semibold))
                            .foregroundStyle(notification.read
                                             ? Editorial.inkSoft : Editorial.ink)
                            .tracking(-0.1)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(notification.date, style: .relative)
                            .font(Editorial.sans(10.5))
                            .foregroundStyle(Editorial.inkMute)
                            .fixedSize()
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Editorial.inkMute)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }

                    HStack(spacing: 8) {
                        Text(secondaryLine)
                            .font(Editorial.sans(11.5))
                            .foregroundStyle(Editorial.inkSoft)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        if notification.hasTarget {
                            Label("abrir", systemImage: targetIcon)
                                .labelStyle(CompactLabel())
                                .font(Editorial.sans(10.5, .medium))
                                .foregroundStyle(Editorial.accent)
                                .fixedSize()
                        }
                    }
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .frame(minHeight: 58)
            .frame(maxWidth: .infinity, alignment: .leading)
            // One native glass surface belongs to the outer notification
            // panel. Repeating a glassEffect for ~100 rows creates ~100 live
            // blur/refraction passes and destroys scroll FPS. Inner capsules
            // are cheap opaque-adaptive surfaces instead.
            .background {
                let capsule = RoundedRectangle(
                    cornerRadius: Editorial.notificationCapsuleRadius,
                    style: .continuous
                )
                ZStack {
                    capsule.fill(Editorial.card.opacity(notification.read ? 0.62 : 0.86))
                    capsule.fill(targetTint.opacity(notification.read ? 0.018 : 0.035))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Editorial.notificationCapsuleRadius,
                                 style: .continuous)
                    .strokeBorder(Editorial.rule.opacity(0.72), lineWidth: 0.6)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: Editorial.notificationCapsuleRadius,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .capsuleHoverLift(tint: targetTint)
        .apolloStudioNode(
            StudioNodeID(rawValue: "notifications.row.\(notification.id.uuidString)"),
            title: notification.title,
            kind: .row,
            parent: "notifications.feed",
            properties: [
                .init(kind: .horizontalPadding, title: "Padding H", value: 15),
                .init(kind: .verticalPadding, title: "Padding V", value: 9),
                .init(kind: .height, title: "Altura mínima", value: 58),
                .init(kind: .cornerRadius, title: "Raio", token: "Editorial.notificationCapsuleRadius"),
            ]
        )
    }

    private var targetIcon: String {
        switch notification.targetKind {
        case .event: return "calendar"
        case .task:  return "checklist"
        default:     return "arrow.up.right.square"
        }
    }

    private var sourceLabel: String {
        notification.targetKind == .task ? "CLICKUP" : "APOLLO"
    }

    private var secondaryLine: String {
        [notification.subtitle, notification.message]
            .compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: " · ")
    }
}

// MARK: - Live upload queue

private struct UploadActivityRow: View {
    let upload: AppState.UploadActivity

    private var stateLabel: String {
        switch upload.state {
        case .uploading: return "Enviando"
        case .completed: return "Concluído"
        case .failed: return "Falhou"
        }
    }

    private var stateIcon: String {
        switch upload.state {
        case .uploading: return "arrow.up.doc"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var stateColor: Color {
        switch upload.state {
        case .uploading: return Editorial.accent
        case .completed: return .green
        case .failed: return .red
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: stateIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(stateColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(upload.fileName)
                        .font(Editorial.sans(12.5, .semibold))
                        .foregroundStyle(Editorial.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(upload.state == .uploading
                         ? "\(Int(upload.progress * 100))%"
                         : stateLabel)
                        .font(Editorial.sans(10.5, .semibold))
                        .foregroundStyle(stateColor)
                        .monospacedDigit()
                }

                Text(upload.taskTitle)
                    .font(Editorial.sans(10.5))
                    .foregroundStyle(Editorial.inkMute)
                    .lineLimit(1)

                ProgressView(value: upload.progress)
                    .progressViewStyle(.linear)
                    .tint(stateColor)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .background {
            let capsule = RoundedRectangle(
                cornerRadius: Editorial.notificationCapsuleRadius,
                style: .continuous
            )
            ZStack {
                capsule.fill(Editorial.card.opacity(0.88))
                capsule.fill(stateColor.opacity(0.04))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Editorial.notificationCapsuleRadius,
                             style: .continuous)
                .strokeBorder(Editorial.rule.opacity(0.72), lineWidth: 0.6)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.04), radius: 1.5, y: 0.75)
    }
}

/// Live, non-persisted updater state pinned above notification history. It is
/// deliberately two lines tall: progress remains visible after the updater
/// window hides, without turning each Sparkle callback into noisy inbox rows.
private struct BackgroundUpdateNotificationRow: View {
    let activity: UpdateService.BackgroundActivity
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                statusIcon
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text("ATUALIZAÇÃO DO APOLLO")
                            .font(Editorial.sans(9.5, .bold))
                            .tracking(1.25)
                            .foregroundStyle(Editorial.inkSoft)
                        Spacer(minLength: 6)
                        Text(detail)
                            .font(Editorial.sans(10.5, .medium))
                            .foregroundStyle(Editorial.inkMute)
                    }

                    HStack(spacing: 10) {
                        Text(title)
                            .font(Editorial.sans(13, .semibold))
                            .foregroundStyle(isFailure ? Color.red : Editorial.ink)
                            .lineLimit(1)
                        if let fraction {
                            ProgressView(value: fraction)
                                .progressViewStyle(.linear)
                                .tint(Editorial.accent)
                                .frame(maxWidth: 145)
                        }
                        Spacer(minLength: 0)
                        Text("abrir")
                            .font(Editorial.sans(11.5, .semibold))
                            .foregroundStyle(Editorial.accent)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let capsule = RoundedRectangle(
                    cornerRadius: Editorial.notificationCapsuleRadius,
                    style: .continuous
                )
                ZStack {
                    capsule.fill(Editorial.card.opacity(0.86))
                    capsule.fill((isFailure ? Color.red : Editorial.accent).opacity(0.035))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Editorial.notificationCapsuleRadius,
                                 style: .continuous)
                    .strokeBorder(Editorial.rule.opacity(0.72), lineWidth: 0.6)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: Editorial.notificationCapsuleRadius,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .capsuleHoverLift(tint: isFailure ? .red : Editorial.accent)
    }

    @ViewBuilder
    private var statusIcon: some View {
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
                .tint(Editorial.accent)
        }
    }

    private var fraction: Double? {
        switch activity {
        case let .downloading(value): return value
        case let .extracting(value): return value
        case .installing, .ready, .failed: return nil
        }
    }

    private var title: String {
        switch activity {
        case .downloading: return "Baixando em segundo plano"
        case .extracting: return "Preparando atualização"
        case .installing: return "Instalando atualização"
        case .ready: return "Pronta para instalar e reiniciar"
        case .failed: return "Falha no download"
        }
    }

    private var detail: String {
        switch activity {
        case let .downloading(value):
            return value.map { "\(Int($0 * 100))%" } ?? "iniciando"
        case let .extracting(value): return "\(Int(value * 100))%"
        case .installing: return "aguarde"
        case let .ready(version): return version.isEmpty ? "concluído" : "v\(version)"
        case .failed: return "atenção"
        }
    }

    private var isFailure: Bool {
        if case .failed = activity { return true }
        return false
    }
}

/// Inline icon+label with no extra spacing — used as the "abrir" hint on
/// rows whose notification has a target.
private struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.caption2)
            configuration.title
        }
    }
}
