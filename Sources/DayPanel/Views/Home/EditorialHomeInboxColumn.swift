import SwiftUI

// Apollo · Editorial+ Home — unified Inbox column.
//
// The persistent `AppNotification` stream already merges remote ClickUp
// task changes with Apollo-only signals (reviews, calendar events, sync,
// updates and connectivity). Today surfaces that same truthful stream
// directly instead of duplicating the active task list.

struct EditorialHomeInboxColumn: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var journal = SyncJournal.shared
    var topInset: CGFloat = 14

    private var inboxNotifications: [AppNotification] {
        appState.notifications.filter(\.isHomeInboxEligible)
    }

    var body: some View {
        VStack(spacing: 0) {
            if inboxNotifications.isEmpty && isAwaitingFirstReading {
                SyncLoadingSurface(scene: .inbox) {
                    InboxLoadingFallback()
                }
                .padding(.top, topInset)
                .transition(.opacity)
            } else if inboxNotifications.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                InboxAppKitList(
                    notifications: inboxNotifications,
                    onDismiss: appState.removeNotification,
                    onTap: { notification in
                        if notification.hasTarget {
                            appState.openNotificationTarget(notification)
                        } else {
                            appState.markNotificationRead(notification.id)
                        }
                    },
                    topInset: topInset
                )
            }
        }
        .background(Editorial.paper)
        .apolloStudioNode("inbox.feed",
                          title: "Feed do Inbox",
                          kind: .list,
                          parent: "inbox.page",
                          properties: [
                            .init(kind: .verticalPadding,
                                  title: "Inset superior", value: topInset),
                            .init(kind: .backgroundColor,
                                  title: "Canvas", token: "Editorial.paper"),
                          ])
    }

    /// An empty Inbox only means "nothing new" after this session compared
    /// the sources at least once. Until then it is still listening.
    private var isAwaitingFirstReading: Bool {
        guard !journal.hasCompletedSync, appState.isOnline else { return false }
        let hasSource = appState.clickUpAuthService.isConnected || appState.googleAuth.isConnected
        return hasSource && (appState.isSyncing || appState.syncStatus == .idle)
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "tray")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Editorial.inkMute)
            Text("Inbox em dia")
                .font(Editorial.sans(16, .semibold))
                .foregroundStyle(Editorial.ink)
            Text("Atualizações do ClickUp e do Apollo aparecerão aqui.")
                .font(Editorial.sans(12))
                .foregroundStyle(Editorial.inkMute)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 64)
    }
}


/// Native stand-in for the Inbox scene: the notification capsules below the
/// space the scene's source ledger occupies (34 + 12 + 102.5 + 18 pt, see
/// `.inbox-head` in web/apollo-loading).
private struct InboxLoadingFallback: View {
    @State private var height: CGFloat = 0

    var body: some View {
        // As many whole capsules as the column holds, like the scene.
        let capsules = SyncLoadingLayout.fitting(bottom: height,
                                                 top: SyncLoadingLayout.inboxTop,
                                                 size: SyncLoadingLayout.inboxCapsule,
                                                 gap: SyncLoadingLayout.inboxGap)
        LunarSkeletonSurface {
            VStack(spacing: SyncLoadingLayout.inboxGap) {
                Color.clear.frame(height: SyncLoadingLayout.inboxTop - SyncLoadingLayout.inboxGap)
                ForEach(0..<capsules, id: \.self) { i in
                    capsule(i)
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
    }

    private func capsule(_ i: Int) -> some View {
        HStack(spacing: 12) {
            Circle().fill(LunarSkeleton.primary).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 7) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LunarSkeleton.primary)
                    .frame(width: [180, 140, 200, 150, 190][i % 5], height: 10)
                RoundedRectangle(cornerRadius: 4)
                    .fill(LunarSkeleton.secondary)
                    .frame(width: [90, 120, 80, 110, 95][i % 5], height: 8)
            }
            Spacer(minLength: 12)
            RoundedRectangle(cornerRadius: 4)
                .fill(LunarSkeleton.faint)
                .frame(width: 34, height: 8)
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(RoundedRectangle(cornerRadius: Editorial.notificationCapsuleRadius,
                                     style: .continuous)
            .fill(LunarSkeleton.faint.opacity(0.35)))
    }
}
