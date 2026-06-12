import SwiftUI

// Notifications Center popup — opened via the bell icon in the toolbar.
// Lists every persisted in-app notification (newest first), with mark
// read / dismiss controls.

struct NotificationsCenterView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.windowSize) private var windowSize
    var onClose: () -> Void = {}

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
    }

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
        let chrome: CGFloat = 110
        return max(220, h - 86 - chrome)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Editorial.rule).frame(height: 1)

            VStack(spacing: 0) {
                if appState.notifications.isEmpty {
                    // Fill the remaining height so the header stays pinned to
                    // the top (the outer maxHeight frame would otherwise centre
                    // the short content, dropping the header to the middle).
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                ScrollablePopupContent(maxHeight: maxScrollHeight) {
                    // Flat editorial rows divided by hairlines
                    // (prototype `PNotifRow`) — no spacing, no
                    // coloured halos.
                    VStack(spacing: 0) {
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
                Rectangle().fill(Editorial.rule).frame(height: 1)
                footer
            }
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
        // Editorial card (prototype `PNotifs` / `PPopup`).
        .background(Editorial.popup, in: shape)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Editorial.rule, lineWidth: 1).allowsHitTesting(false) }
        .shadow(color: .black.opacity(0.22), radius: 50, x: 0, y: 40)
        .shadow(color: .black.opacity(0.08), radius: 24, x: 0, y: 8)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Editorial.inkSoft)
            Text("Notificações")
                .font(Editorial.serif(16, .medium))
                .foregroundStyle(Editorial.ink)
            if appState.unreadNotifications > 0 {
                Text(appState.unreadNotifications > 99
                     ? "99+" : "\(appState.unreadNotifications)")
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
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Editorial.inkMute)
            Text("Nenhuma notificação ainda")
                .font(Editorial.serif(15))
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
                return Color(statusHex: task.statusDisplayHex)
            }
        case .event:
            if let id = notification.targetId,
               let event = appState.events.first(where: { $0.id == id }) {
                return Color(hex: event.colorHex)
            }
        case .review:
            break   // review rows use the kind's default tint
        case .none:
            break
        }
        return notification.kind.tint
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                // Tone dot (prototype `PNotifRow`): solid muted
                // status/kind colour when unread, hollow ring when
                // already read.
                Circle()
                    .fill(notification.read ? Color.clear
                                            : cachedTargetTint.editorialMuted)
                    .frame(width: 6, height: 6)
                    .overlay(
                        Circle().strokeBorder(
                            notification.read ? Editorial.inkFaint : Color.clear,
                            lineWidth: 1.5
                        )
                    )
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 3) {
                    Text(notification.title)
                        // Sans (no serif) for the notification title.
                        .font(Editorial.sans(13.5, .semibold))
                        .foregroundStyle(notification.read
                                         ? Editorial.inkSoft : Editorial.ink)
                        .tracking(-0.1)
                        .lineLimit(2)
                    if let s = notification.subtitle, !s.isEmpty {
                        Text(s)
                            .font(Editorial.serif(12).italic())
                            .foregroundStyle(Editorial.inkSoft)
                            .lineLimit(1)
                    }
                    if let m = notification.message, !m.isEmpty {
                        // `attributedMessage` keeps the per-status
                        // colour highlights baked into the substring.
                        Text(notification.attributedMessage ?? AttributedString(m))
                            .font(Editorial.serif(12).italic())
                            .foregroundStyle(Editorial.inkSoft)
                            .lineLimit(3)
                    }
                    if notification.hasTarget {
                        Label("abrir", systemImage: targetIcon)
                            .labelStyle(CompactLabel())
                            .font(Editorial.sans(10.5, .medium))
                            .foregroundStyle(Editorial.accent)
                            .padding(.top, 1)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 6) {
                    Text(relative)
                        .font(Editorial.sans(10.5))
                        .foregroundStyle(Editorial.inkMute)
                        .fixedSize()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Editorial.inkMute)
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).focusEffectDisabled()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(notification.read ? Color.clear
                                          : cachedTargetTint.editorialMuted.opacity(0.05))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Editorial.ruleSoft).frame(height: 1)
            }
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
