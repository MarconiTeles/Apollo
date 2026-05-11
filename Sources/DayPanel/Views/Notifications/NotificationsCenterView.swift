import SwiftUI

// Notifications Center popup — opened via the bell icon in the toolbar.
// Lists every persisted in-app notification (newest first), with mark
// read / dismiss controls.

struct NotificationsCenterView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.windowSize) private var windowSize
    var onClose: () -> Void = {}

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    /// Cap the scrollable list relative to the window so the popup never
    /// pushes off-screen on small windows.
    private var maxScrollHeight: CGFloat {
        let h = windowSize.height
        guard h > 0 else { return 380 }
        // Two caps. The 70% taste cap is what we WANT, the safe-area
        // cap is what we MUST respect — otherwise the centered popup
        // would intrude on the macOS toolbar (~52pt) at the top of the
        // window. Whichever is smaller wins.
        let chrome: CGFloat = 110
        let preferred = max(220, h * 0.70 - chrome)
        let safeMax   = max(0,   h - 128 - chrome)   // 64pt top + 64pt bottom
        return min(preferred, safeMax)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            // Body + footer share a solid surface; header is
            // the only translucent area, matching the new
            // popup design language.
            VStack(spacing: 0) {
                if appState.notifications.isEmpty {
                    emptyState
                } else {
                ScrollablePopupContent(maxHeight: maxScrollHeight) {
                    // Spacing 10pt — gives the coloured drop shadows
                    // breathing room between rows so the halos read
                    // as separate cards instead of bleeding together.
                    VStack(spacing: 10) {
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
                                    // Insert: slides in from above + scales up + fades in
                                    insertion: .move(edge: .top)
                                        .combined(with: .scale(scale: 0.92))
                                        .combined(with: .opacity),
                                    // Remove: slides off to the trailing edge + fades out
                                    removal: .move(edge: .trailing)
                                        .combined(with: .opacity)
                                ))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    // Animate the ForEach contents whenever the
                    // notifications array changes (new arrival or
                    // user-dismiss). `value:` is just `count` —
                    // notifications only get appended at top or
                    // removed, so the count tracks every relevant
                    // mutation. Was `.map(\.id)` which allocated a
                    // fresh `[String]` on EVERY body re-eval, even
                    // when nothing had changed.
                    .animation(.spring(duration: 0.4, bounce: 0.22),
                               value: appState.notifications.count)
                }
            }

            if !appState.notifications.isEmpty {
                Divider().opacity(0.5)
                footer
            }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .popupGlass(shape)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15))
                Image(systemName: "bell.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.callout)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text("Notificações")
                    .font(.headline.weight(.semibold))
                if appState.unreadNotifications > 0 {
                    Text("\(appState.unreadNotifications) não lida\(appState.unreadNotifications == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !appState.notifications.isEmpty {
                    Text("Todas lidas")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain).focusEffectDisabled()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text("Nenhuma notificação ainda")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Atualizações de sincronização, eventos e tarefas vão aparecer aqui.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                appState.markAllNotificationsRead()
            } label: {
                Label("Marcar como lidas", systemImage: "checkmark.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .disabled(appState.unreadNotifications == 0)

            Spacer()

            Button {
                appState.clearAllNotifications()
            } label: {
                Label("Limpar tudo", systemImage: "trash")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain).focusEffectDisabled()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Single notification row

private struct NotificationRow: View, Equatable {
    @EnvironmentObject var appState: AppState
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

    /// Cached tint resolved once per row mount + on `targetId`
    /// change. The previous computed property did a
    /// `.first(where:)` linear scan over `appState.events` on
    /// EVERY body re-eval. With ~10 rows visible and
    /// `appState.events` typically holding 50–500 entries,
    /// that was O(rows × events) per scroll frame — the
    /// single biggest reason notifications scroll felt awful.
    @State private var cachedTargetTint: Color = .gray

    private func resolveTargetTint() -> Color {
        switch notification.targetKind {
        case .task:
            if let id = notification.targetId,
               let task = appState.tasksById[id] {
                return Color(hex: task.statusDisplayHex)
            }
        case .event:
            if let id = notification.targetId,
               let event = appState.events.first(where: { $0.id == id }) {
                return Color(hex: event.colorHex)
            }
        case .none:
            break
        }
        return notification.kind.tint
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: notification.kind.systemImage)
                        .font(.title3)
                        .foregroundStyle(cachedTargetTint)
                        .frame(width: 24, height: 24)
                    if !notification.read {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(.background, lineWidth: 1))
                            .offset(x: 4, y: -2)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(notification.title)
                        .font(.subheadline.weight(notification.read ? .regular : .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let s = notification.subtitle, !s.isEmpty {
                        Text(s)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary.opacity(0.85))
                            .lineLimit(1)
                    }
                    if let m = notification.message, !m.isEmpty {
                        // `attributedMessage` returns the message
                        // with status-name highlights baked in
                        // (each status pill colour applied to its
                        // own substring). Falls back to the plain
                        // string when no highlights were attached.
                        Text(notification.attributedMessage ?? AttributedString(m))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    HStack(spacing: 6) {
                        Text(relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if notification.hasTarget {
                            Label("abrir", systemImage: targetIcon)
                                .labelStyle(CompactLabel())
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .padding(4)
                }
                .buttonStyle(.plain).focusEffectDisabled()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                notification.read
                ? AnyShapeStyle(Color.clear)
                : AnyShapeStyle(cachedTargetTint.opacity(0.06)),
                in: RoundedRectangle(cornerRadius: 13.6, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13.6, style: .continuous)
                    .strokeBorder(cachedTargetTint.opacity(notification.read ? 0.05 : 0.20),
                                  lineWidth: 0.5)
            )
            // Coloured ambient shadow — same pattern as the task row
            // cards. Unread notifications get a stronger halo so the
            // bell-popup reads at a glance even before the user
            // starts scanning individual rows.
            // `.compositingGroup()` flattens the row's bg+border
            // into a single layer before the coloured shadow
            // composites against it. Without this, every scroll-Y
            // change forced the shadow's blur pass to re-render
            // the row's layered content from scratch.
            .compositingGroup()
            .shadow(color: cachedTargetTint.opacity(notification.read ? 0.18 : 0.45),
                    radius: 10, x: 0, y: 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onAppear { cachedTargetTint = resolveTargetTint() }
        .onChange(of: notification.targetId) { _, _ in
            cachedTargetTint = resolveTargetTint()
        }
        .onChange(of: notification.read) { _, _ in
            // `read` doesn't change the tint colour itself but
            // changes how alpha is applied — we recompute as a
            // safety net so the row's shadow opacity matches.
        }
    }

    /// Shared formatter — was being instantiated per row per
    /// render, plus a fresh `Locale` lookup. With 10+ rows
    /// re-evaluating on every `appState` mutation, that was a
    /// pile of allocations per scroll frame for what's
    /// effectively static configuration. The static let runs
    /// once per app launch.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale     = Locale(identifier: "pt-BR")
        return f
    }()

    private var relative: String {
        Self.relativeFormatter.localizedString(
            for: notification.date,
            relativeTo: Date()
        )
    }

    private var targetIcon: String {
        switch notification.targetKind {
        case .event: return "calendar"
        case .task:  return "checklist"
        default:     return "arrow.up.right.square"
        }
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
