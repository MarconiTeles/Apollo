import SwiftUI

// Apollo · Editorial+ Home — unified Inbox column.
//
// The persistent `AppNotification` stream already merges remote ClickUp
// task changes with Apollo-only signals (reviews, calendar events, sync,
// updates and connectivity). Today surfaces that same truthful stream
// directly instead of duplicating the active task list.

struct EditorialHomeInboxColumn: View {
    @EnvironmentObject var appState: AppState

    private var inboxNotifications: [AppNotification] {
        appState.notifications.filter(\.isHomeInboxEligible)
    }

    var body: some View {
        VStack(spacing: 0) {
            if inboxNotifications.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(inboxNotifications) { notification in
                            NotificationRow(
                                notification: notification,
                                onDismiss: {
                                    withAnimation(.spring(duration: 0.35, bounce: 0.18)) {
                                        appState.removeNotification(notification.id)
                                    }
                                },
                                onTap: {
                                    if notification.hasTarget {
                                        appState.openNotificationTarget(notification)
                                    } else {
                                        appState.markNotificationRead(notification.id)
                                    }
                                }
                            )
                            .equatable()
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity)
                            ))
                        }
                    }
                    .animation(.spring(duration: 0.4, bounce: 0.20),
                               value: inboxNotifications.count)
                    .padding(.bottom, 72)
                }
            }
        }
        .background(Editorial.paper)
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "tray")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Editorial.inkMute)
            Text("Inbox em dia")
                .font(Editorial.serif(16, .medium))
                .foregroundStyle(Editorial.ink)
            Text("Atualizações do ClickUp e do Apollo aparecerão aqui.")
                .font(Editorial.serif(12).italic())
                .foregroundStyle(Editorial.inkMute)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 64)
    }
}
