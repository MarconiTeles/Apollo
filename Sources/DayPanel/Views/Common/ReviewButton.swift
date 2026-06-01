import SwiftUI

/// The red "REVIEW" pill with an "unseen update" badge. While on-screen it polls
/// the review's `updatedAt` (cheap /session/meta) and shows a dot when someone
/// changed the review since this user last opened it — so updates surface
/// without a manual refresh. Opening the review marks it seen. Shared by the
/// comment file card AND the attachments (ANEXOS) panel.
struct ReviewButton: View {
    let attachment: CUTask.Attachment
    let taskId: String
    let listId: String?
    let uploaderId: Int?
    let actorId: Int
    let actorName: String
    var commentId: String? = nil

    @State private var unseen = false
    @State private var remoteUpdatedAt: String?

    var body: some View {
        Button {
            // Opening = "seen": clear the dot, remember this version, and start
            // watching it so future changes fire a notification.
            ReviewBackend.markSeen(forMediaUrl: attachment.url, updatedAt: remoteUpdatedAt)
            ReviewWatcher.shared.register(
                att: ReviewBackend.att(forMediaUrl: attachment.url),
                mediaUrl: attachment.url, ext: attachment.ext, taskId: taskId,
                title: attachment.title, uploaderId: uploaderId, tintHex: nil,
                currentUpdatedAt: remoteUpdatedAt)
            unseen = false
            ReviewPresenter.shared.present(
                ReviewLink.params(attachment: attachment, taskId: taskId, listId: listId,
                                  uploaderId: uploaderId, actorId: actorId,
                                  actorName: actorName, commentId: commentId))
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text("REVIEW")
                    .font(Editorial.sans(9.5, .bold))
                    .tracking(0.4)
            }
            .foregroundStyle(Editorial.page)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(Editorial.accent))
            .overlay(alignment: .topTrailing) {
                if unseen {
                    Circle()
                        .fill(.white)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Editorial.accent, lineWidth: 1))
                        .offset(x: 3, y: -3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(unseen ? "Atualizado desde a última vez que você abriu" : "Abrir no Apollo Review")
        .task(id: attachment.url) {
            while !Task.isCancelled {
                if let meta = await ReviewBackend.meta(forMediaUrl: attachment.url) {
                    remoteUpdatedAt = meta.updatedAt
                    unseen = ReviewBackend.hasUnseenUpdate(meta: meta, mediaUrl: attachment.url)
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }
}
