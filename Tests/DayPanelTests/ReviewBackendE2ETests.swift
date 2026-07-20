import XCTest
@testable import ApolloRuntime

/// E2E contra o Worker REAL (KV de produção, chaves sintéticas "teste3-…" —
/// nenhuma tarefa/anexo real é tocado). Rede é lenta/flaky pra CI, então só
/// roda com `REVIEW_E2E=1 swift test --filter ReviewBackendE2ETests`.
final class ReviewBackendE2ETests: XCTestCase {

    private var enabled: Bool { ProcessInfo.processInfo.environment["REVIEW_E2E"] == "1" }

    /// URL sintética única por execução (o hash dela é a chave legada).
    private func makeUrl(_ tag: String) -> String {
        "https://teste3.invalid/\(tag)/\(UUID().uuidString).mov"
    }

    private func seed(att: String, comments: [[String: Any]], status: String = "in_review") async {
        _ = await ReviewBackend.save(att: att, mirror: nil, status: status,
                                     comments: comments, clickupCommentId: nil)
    }

    private func comments(in data: Data) -> [[String: Any]] {
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (obj["comments"] as? [[String: Any]]) ?? []
    }

    /// Só-legada existe + id real conhecido → abre migrando pra canônica,
    /// legada vira espelho; comentários preservados nas DUAS chaves.
    func testOpenMigratesLegacyToCanonical() async throws {
        try XCTSkipUnless(enabled, "REVIEW_E2E=1 para rodar")
        let url = makeUrl("migra")
        let key = ReviewBackend.sessionKey(attachmentId: "teste3-canon-\(UUID().uuidString)",
                                           mediaUrl: url)
        await seed(att: key.legacy, comments: [["id": "c1", "body": "victor 1"],
                                               ["id": "c2", "body": "victor 2"]])

        let opened = await ReviewBackend.openSession(key: key, mediaUrl: url, ext: "mov",
                                                     title: "t", taskId: "TESTE3",
                                                     listId: nil, uploaderId: nil)
        XCTAssertEqual(opened?.att, key.canonical)
        XCTAssertEqual(opened?.mirror, key.legacy)
        XCTAssertEqual(comments(in: opened!.data).count, 2)

        // A canônica agora existe no KV com os mesmos comentários (é o que o
        // web novo vai abrir) e a legada continua viva pros links antigos.
        let mc = await ReviewBackend.meta(att: key.canonical!)
        let ml = await ReviewBackend.meta(att: key.legacy)
        XCTAssertEqual(mc?.exists, true)
        XCTAssertEqual(ml?.exists, true)
    }

    /// As duas existem com comentários diferentes → abre mesclado sem perda.
    func testOpenMergesDivergedSessions() async throws {
        try XCTSkipUnless(enabled, "REVIEW_E2E=1 para rodar")
        let url = makeUrl("merge")
        let key = ReviewBackend.sessionKey(attachmentId: "teste3-canon-\(UUID().uuidString)",
                                           mediaUrl: url)
        await seed(att: key.legacy, comments: [["id": "l1", "body": "só no legado"]])
        await seed(att: key.canonical!, comments: [["id": "w1", "body": "só no web"]],
                   status: "changes_requested")

        let opened = await ReviewBackend.openSession(key: key, mediaUrl: url, ext: "mov",
                                                     title: "t", taskId: "TESTE3",
                                                     listId: nil, uploaderId: nil)
        XCTAssertEqual(opened?.att, key.canonical)
        let ids = Set(comments(in: opened!.data).compactMap { $0["id"] as? String })
        XCTAssertEqual(ids, ["l1", "w1"], "merge não pode perder comentário de nenhum lado")
    }

    /// Nenhuma existe → cria SÓ a canônica (a legada não pode nascer junto).
    func testOpenCreatesOnlyCanonicalWhenFresh() async throws {
        try XCTSkipUnless(enabled, "REVIEW_E2E=1 para rodar")
        let url = makeUrl("fresh")
        let key = ReviewBackend.sessionKey(attachmentId: "teste3-canon-\(UUID().uuidString)",
                                           mediaUrl: url)
        let opened = await ReviewBackend.openSession(key: key, mediaUrl: url, ext: "mov",
                                                     title: "t", taskId: "TESTE3",
                                                     listId: nil, uploaderId: nil)
        XCTAssertEqual(opened?.att, key.canonical)
        XCTAssertNil(opened?.mirror)
        let ml = await ReviewBackend.meta(att: key.legacy)
        XCTAssertEqual(ml?.exists, false, "meta/open não podem criar a sessão legada")
    }

    /// Save com espelho: as duas chaves recebem o mesmo estado.
    func testSaveDualWritesToMirror() async throws {
        try XCTSkipUnless(enabled, "REVIEW_E2E=1 para rodar")
        let canon = "teste3-canon-\(UUID().uuidString)"
        let legacy = "teste3-legacy-\(UUID().uuidString)"
        _ = await ReviewBackend.save(att: canon, mirror: legacy, status: "approved",
                                     comments: [["id": "x", "body": "dual"]],
                                     clickupCommentId: nil)
        let mc = await ReviewBackend.meta(att: canon)
        let ml = await ReviewBackend.meta(att: legacy)
        XCTAssertEqual(mc?.exists, true)
        XCTAssertEqual(ml?.exists, true)
    }
}
