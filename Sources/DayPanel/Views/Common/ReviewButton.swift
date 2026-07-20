import SwiftUI

/// The red "REVIEW" pill with an "unseen update" badge. While on-screen it polls
/// the review's `updatedAt` (cheap /session/meta) and shows a dot when someone
/// changed the review since this user last completed it — so updates surface
/// without a manual refresh. Opening is deliberately non-destructive: only an
/// explicit completed review advances the seen baseline. Shared by the comment
/// file card AND the attachments (ANEXOS) panel.
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
    /// Chave KV viva deste anexo (canônica = id real quando existe sessão
    /// nela; senão a legada hash-da-URL). Descoberta pelo poll do badge; o
    /// clique registra o watcher NESTA chave — a mesma que o sheet vai abrir —
    /// para badge, notificação e sessão nunca divergirem.
    @State private var activeAtt: String?

    var body: some View {
        Button {
            // A physical replacement attachment (V2/V3…) must open its STABLE
            // lineage session, never a per-file duplicate — writing into the
            // duplicate leaves the canonical version's pendency alive. The
            // persisted media catalog resolves that identity; media without a
            // catalog keeps the historical key selection.
            let identity = TaskMediaTransferStore.persistedCatalog(for: taskId)?
                .reviewIdentity(attachmentId: attachment.id,
                                mediaURL: attachment.url)
            // Opening is never acknowledgement. Register the review for future
            // notifications, but keep the current update pending until the
            // explicit completion callback marks the final saved revision.
            let att = identity?.reviewId
                ?? activeAtt
                ?? ReviewBackend.att(forMediaUrl: attachment.url)
            ReviewWatcher.shared.register(
                att: att,
                mediaUrl: attachment.url, ext: attachment.ext, taskId: taskId,
                title: attachment.title, uploaderId: uploaderId, tintHex: nil,
                currentUpdatedAt: remoteUpdatedAt,
                versionId: identity?.versionId)
            ReviewPresenter.shared.present(
                ReviewLink.params(attachment: attachment, taskId: taskId, listId: listId,
                                  uploaderId: uploaderId, actorId: actorId,
                                  actorName: actorName,
                                  reviewId: identity?.reviewId,
                                  versionId: identity?.versionId,
                                  commentId: commentId))
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
            let key = ReviewBackend.sessionKey(attachmentId: attachment.id,
                                               mediaUrl: attachment.url)
            while !Task.isCancelled {
                let (att, meta) = await ReviewBackend.activeMeta(key: key)
                activeAtt = att
                remoteUpdatedAt = meta.updatedAt
                unseen = ReviewBackend.observe(meta: meta, att: att)
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }
}
