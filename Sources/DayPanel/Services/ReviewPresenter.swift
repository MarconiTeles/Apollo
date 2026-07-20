import ReviewKit
import SwiftUI

/// Identifiable wrapper so a SwiftUI `.sheet(item:)` can present a review —
/// either a fresh one (`params`) or a re-opened saved one (`savedJSON`).
struct ReviewRequest: Identifiable {
    let id = UUID()
    var params: OpenReviewParams? = nil
    var savedJSON: Data? = nil
    /// Set only when `VER REVIEW` in the task list opened an unseen update.
    /// That flow must remain unconsumed until completion is explicitly closed.
    var completionAcknowledgement: ReviewCompletionAcknowledgement? = nil
    /// ONE session context for the whole presentation, created here and never
    /// inside the sheet's view builder. SwiftUI re-evaluates that builder on
    /// any unrelated state change (a toast is enough); a per-render context
    /// loses `activeAtt` between load and submit, which silently pushed the
    /// conclusion into a payload-derived orphan key and made the confirmation
    /// step fail with "A review não foi salva" (bug de 20/jul, TESTE 04).
    var sessionContext: ReviewSessionContext? = nil
}

struct ReviewCompletionAcknowledgement: Equatable {
    let taskId: String
    let activeAtt: String
}

/// App-wide presenter for the EMBEDDED review workflow. Any REVIEW / "Ver
/// review" button (deep in the view tree, without AppState) calls present;
/// ContentView observes this and shows the ReviewKit sheet. Zero install/config.
final class ReviewPresenter: ObservableObject {
    static let shared = ReviewPresenter()
    @Published var request: ReviewRequest?
    private init() {}

    func present(_ params: OpenReviewParams,
                 completionAcknowledgement: ReviewCompletionAcknowledgement? = nil) {
        request = ReviewRequest(
            params: params,
            completionAcknowledgement: completionAcknowledgement,
            sessionContext: ReviewSessionContext(
                params: params,
                // Opening, closing the sheet or relaunching Apollo must never
                // consume a review update. The final onSubmit path is the sole
                // owner of `markSeen`.
                markSeenOnLoad: false
            )
        )
    }

    /// Re-open a saved review from inline JSON data (the `?z=` payload decoded
    /// from the comment link) — no download, works offline.
    func presentSaved(jsonData: Data) {
        request = ReviewRequest(savedJSON: jsonData)
    }

    /// Re-open a saved review from a JSON URL (legacy comments that linked an
    /// uploaded ClickUp attachment). Apollo can fetch it directly (no CORS).
    func presentSaved(jsonURL: URL) {
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: jsonURL) else { return }
            await MainActor.run { self.request = ReviewRequest(savedJSON: data) }
        }
    }
}

struct TaskReviewQueueRequest: Identifiable {
    let id = UUID()
    let task: CUTask
    let updates: [TaskReviewUpdateStore.Update]
}

/// App-wide bridge from recycled AppKit task rows to the SwiftUI review
/// chooser. The row only decides direct-open versus multi-review; SwiftUI owns
/// the sheet, state and animations.
@MainActor
final class TaskReviewQueuePresenter: ObservableObject {
    static let shared = TaskReviewQueuePresenter()
    @Published var request: TaskReviewQueueRequest?
    private init() {}

    func present(task: CUTask, updates: [TaskReviewUpdateStore.Update]) {
        request = TaskReviewQueueRequest(task: task, updates: updates)
    }
}

/// Where a comment's "Ver review" payload comes from:
///   • `.attLink`  the single live link (`?att=`) — resolves from KV + media
///   • `.data`     inline `?z=` snapshot (legacy)
///   • `.url`      a JSON URL (`?d=`, legacy)
/// Resolved by CommentBodyView.extractReview.
enum ReviewSource: Equatable {
    case attLink(String)
    case data(Data)
    case url(URL)
}

extension OpenReviewParams {
    /// Build params from a hosted `?att=` web link (the single-link reopen).
    /// The actor (who's opening) comes from the caller's context, not the link.
    init?(attLink: String, actorId: Int, actorName: String) {
        guard let comps = URLComponents(string: attLink) else { return nil }
        let q = comps.queryItems ?? []
        func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
        guard let att = v("att"), let media = v("m"), !media.isEmpty else { return nil }
        self.init(
            taskId: v("task") ?? "",
            listId: v("list"),
            attachmentId: att,
            mediaUrl: media,
            mediaTitle: v("t") ?? "Arquivo",
            ext: v("x") ?? "",
            uploaderId: v("up").flatMap { Int($0) },
            actorId: actorId,
            actorName: actorName,
            commentId: v("cmt")
        )
    }
}
