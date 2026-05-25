import ReviewKit
import SwiftUI

/// Identifiable wrapper so a SwiftUI `.sheet(item:)` can present a review —
/// either a fresh one (`params`) or a re-opened saved one (`savedJSON`).
struct ReviewRequest: Identifiable {
    let id = UUID()
    var params: OpenReviewParams? = nil
    var savedJSON: Data? = nil
}

/// App-wide presenter for the EMBEDDED review workflow. Any REVIEW / "Ver
/// review" button (deep in the view tree, without AppState) calls present;
/// ContentView observes this and shows the ReviewKit sheet. Zero install/config.
final class ReviewPresenter: ObservableObject {
    static let shared = ReviewPresenter()
    @Published var request: ReviewRequest?
    private init() {}

    func present(_ params: OpenReviewParams) {
        request = ReviewRequest(params: params)
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

/// Where a comment's "Ver review" payload comes from: inline data (new, `?z=`)
/// or a JSON URL (legacy). Resolved by CommentBodyView.extractReview.
enum ReviewSource: Equatable {
    case data(Data)
    case url(URL)
}
