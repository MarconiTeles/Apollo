import SwiftUI

// Apollo · Editorial+ Home — unified Inbox column.
//
// The persistent `AppNotification` stream already merges remote ClickUp
// task changes with Apollo-only signals (reviews, calendar events, sync,
// updates and connectivity). Today surfaces that same truthful stream
// directly instead of duplicating the active task list.

struct EditorialHomeInboxColumn: View {
    @EnvironmentObject var appState: AppState
    var topInset: CGFloat = 14

    private var inboxNotifications: [AppNotification] {
        appState.notifications.filter(\.isHomeInboxEligible)
    }

    var body: some View {
        VStack(spacing: 0) {
            if inboxNotifications.isEmpty {
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
