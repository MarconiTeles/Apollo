import XCTest
@testable import ApolloRuntime

/// Identidade da sessão de review (fix web × nativo divergindo em dois
/// documentos KV) — cobre a lógica PURA: normalização da SessionKey e a
/// mesclagem sem perda de dois blobs divergentes. Os caminhos de rede
/// (escolha/migração via /session/meta) são validados no roteiro manual
/// com a tarefa TESTE 3.
final class ReviewSessionKeyTests: XCTestCase {

    private let url = "https://p97.clickup.com/t/86ajj3w6k/video.mov"

    // ── SessionKey ───────────────────────────────────────────────────────────

    func testKeyWithRealAttachmentId() {
        let k = ReviewBackend.sessionKey(attachmentId: "abc-123.mov", mediaUrl: url)
        XCTAssertEqual(k.canonical, "abc-123.mov")
        XCTAssertEqual(k.legacy, AppState.stableId(url))
        XCTAssertEqual(k.creationTarget, "abc-123.mov")
    }

    func testKeyWithoutAttachmentIdFallsBackToLegacy() {
        for missing in [nil, "", "  "] {
            let k = ReviewBackend.sessionKey(attachmentId: missing, mediaUrl: url)
            XCTAssertNil(k.canonical)
            XCTAssertEqual(k.creationTarget, AppState.stableId(url))
        }
    }

    func testKeyCollapsesWhenIdEqualsLegacyHash() {
        // Links antigos punham o próprio hash como "attachmentId" — não pode
        // virar uma canônica separada igual à legada.
        let hash = AppState.stableId(url)
        let k = ReviewBackend.sessionKey(attachmentId: hash, mediaUrl: url)
        XCTAssertNil(k.canonical)
        XCTAssertEqual(k.creationTarget, hash)
    }

    func testStableIdIsDeterministic() {
        XCTAssertEqual(AppState.stableId(url), AppState.stableId(url))
        XCTAssertNotEqual(AppState.stableId(url), AppState.stableId(url + "x"))
    }

    // ── mergeSessions ────────────────────────────────────────────────────────

    private func comment(_ id: String, body: String = "c", resolved: Bool = false) -> [String: Any] {
        ["id": id, "body": body, "resolved": resolved]
    }

    func testMergeUnionsCommentsById() {
        let preferred: [String: Any] = ["status": "in_review",
                                        "comments": [comment("a"), comment("b")]]
        let other: [String: Any] = ["status": "in_review",
                                    "comments": [comment("b"), comment("c")]]
        let merged = ReviewBackend.mergeSessions(preferred: preferred, other: other)
        let ids = (merged["comments"] as! [[String: Any]]).map { $0["id"] as! String }
        XCTAssertEqual(ids, ["a", "b", "c"])
    }

    func testMergePrefersNewerVersionOnCollision() {
        let preferred: [String: Any] = ["comments": [comment("a", resolved: true)]]
        let other: [String: Any] = ["comments": [comment("a", resolved: false)]]
        let merged = ReviewBackend.mergeSessions(preferred: preferred, other: other)
        let a = (merged["comments"] as! [[String: Any]]).first!
        XCTAssertEqual(a["resolved"] as? Bool, true)
    }

    func testMergeKeepsPreferredStatusAndFallsBack() {
        var merged = ReviewBackend.mergeSessions(
            preferred: ["status": "approved", "comments": []],
            other: ["status": "in_review", "comments": []])
        XCTAssertEqual(merged["status"] as? String, "approved")

        merged = ReviewBackend.mergeSessions(
            preferred: ["comments": []],
            other: ["status": "changes_requested", "comments": []])
        XCTAssertEqual(merged["status"] as? String, "changes_requested")
    }

    func testMergePreservesClickupCommentIdFromEitherSide() {
        let merged = ReviewBackend.mergeSessions(
            preferred: ["comments": [], "clickupCommentId": NSNull()],
            other: ["comments": [], "clickupCommentId": "90210"])
        XCTAssertEqual(merged["clickupCommentId"] as? String, "90210")
    }

    func testMergeNeverDropsCommentsWithoutId() {
        let odd: [String: Any] = ["body": "sem id"]
        let merged = ReviewBackend.mergeSessions(
            preferred: ["comments": [comment("a")]],
            other: ["comments": [odd]])
        XCTAssertEqual((merged["comments"] as! [[String: Any]]).count, 2)
    }
}
