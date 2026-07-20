import XCTest
@testable import ApolloRuntime

@MainActor
final class TaskMediaTransferStoreTests: XCTestCase {
    func testCapsuleLabelsRepresentEveryTransferPhase() {
        XCTAssertEqual(TaskMediaTransferStore.capsuleLabel(
            phase: nil, completed: 0, total: 0, pending: 0), "ANEXAR")
        XCTAssertEqual(TaskMediaTransferStore.capsuleLabel(
            phase: .preparing, completed: 2, total: 5, pending: 3), "PREPARANDO 2/5")
        XCTAssertEqual(TaskMediaTransferStore.capsuleLabel(
            phase: .ready, completed: 0, total: 5, pending: 5), "ENVIAR")
        XCTAssertEqual(TaskMediaTransferStore.capsuleLabel(
            phase: .sending, completed: 3, total: 5, pending: 2), "ENVIANDO 3/5")
        XCTAssertEqual(TaskMediaTransferStore.capsuleLabel(
            phase: .partialFailure, completed: 3, total: 5, pending: 2), "REPETIR 2")
        XCTAssertEqual(TaskMediaTransferStore.capsuleLabel(
            phase: .partialFailure, completed: 5, total: 5, pending: 0), "FINALIZAR")
        XCTAssertEqual(TaskMediaTransferStore.capsuleLabel(
            phase: .sent, completed: 5, total: 5, pending: 0), "ENVIADO")
        XCTAssertEqual(TaskMediaTransferStore.capsuleLabel(
            phase: .failed, completed: 0, total: 5, pending: 5), "REPETIR")
    }

    func testRemoteFilesRejectHTTPFailuresBeforeDecodeOrComposition() throws {
        let url = try XCTUnwrap(URL(string: "https://files.example.com/video.mov"))
        let ok = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200,
                                               httpVersion: nil, headerFields: nil))
        let missing = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 404,
                                                    httpVersion: nil, headerFields: nil))
        let serverFailure = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 503,
                                                          httpVersion: nil, headerFields: nil))
        XCTAssertTrue(TaskMediaTransferStore.isSuccessful(ok))
        XCTAssertFalse(TaskMediaTransferStore.isSuccessful(missing))
        XCTAssertFalse(TaskMediaTransferStore.isSuccessful(serverFailure))
    }

    func testPreparedBatchCanRetryAfterCompleteOrPartialFailure() {
        XCTAssertTrue(TaskMediaTransferStore.canSend(phase: .ready, total: 3))
        XCTAssertTrue(TaskMediaTransferStore.canSend(phase: .partialFailure, total: 3))
        XCTAssertTrue(TaskMediaTransferStore.canSend(phase: .failed, total: 3))
        XCTAssertFalse(TaskMediaTransferStore.canSend(phase: .failed, total: 0))
        XCTAssertFalse(TaskMediaTransferStore.canSend(phase: .preparing, total: 3))
        XCTAssertFalse(TaskMediaTransferStore.canSend(phase: .sending, total: 3))
    }

    func testPublishedMediaRequiresBothAttachmentAndReviewLink() {
        let attachment = CUTask.Attachment(
            id: "attachment-42",
            title: "Video V2.mov",
            url: "https://files.example.com/video-v2.mov",
            ext: "mov",
            sizeString: "20 MB",
            totalComments: 0,
            resolvedComments: 0,
            uploaderId: 42
        )
        let complete = comment(text: "V2\nREVISAR", attachments: [attachment])
        let missingLink = comment(text: "V2", attachments: [attachment])
        let missingAttachment = comment(text: "V2\nREVISAR", attachments: [])

        XCTAssertTrue(AppState.isCompleteMediaTransferComment(
            complete, attachmentId: attachment.id))
        XCTAssertFalse(AppState.isCompleteMediaTransferComment(
            missingLink, attachmentId: attachment.id))
        XCTAssertFalse(AppState.isCompleteMediaTransferComment(
            missingAttachment, attachmentId: attachment.id))
    }

    func testVerificationAcceptsSegmentIdsAndExtensionInsensitiveMatch() {
        // ClickUp may return the comment's file as an id-only segment
        // (`attachment: null`, no url) and suffix the id with the file
        // extension — the upload response id has neither. Verification must
        // still recognize the comment as complete.
        var idOnly = comment(text: "V2 · Campanha · V2.mov\nREVISAR", attachments: [])
        idOnly.attachmentIds = ["5f74e849-fc75-4dcc-b626-6689e67a0c93.mov"]
        XCTAssertTrue(AppState.isCompleteMediaTransferComment(
            idOnly, attachmentId: "5f74e849-fc75-4dcc-b626-6689e67a0c93"))
        XCTAssertFalse(AppState.isCompleteMediaTransferComment(
            idOnly, attachmentId: "outro-id"))

        XCTAssertTrue(AppState.mediaAttachmentIdMatches("abc.mov", "abc"))
        XCTAssertTrue(AppState.mediaAttachmentIdMatches("abc", "abc.mov"))
        XCTAssertTrue(AppState.mediaAttachmentIdMatches("abc", "abc"))
        XCTAssertFalse(AppState.mediaAttachmentIdMatches("abc", "abd"))
        XCTAssertFalse(AppState.mediaAttachmentIdMatches("", "abc"))
    }

    func testOnlyOwnedPlaceholderCommentsAreEligibleForRetryCleanup() {
        let ownedPlaceholder = comment(text: "V2 · Campanha · V2.mov", attachments: [], userId: 42)
        let otherUser = comment(text: "V2 · Campanha · V2.mov", attachments: [], userId: 99)
        let finalComment = comment(text: "V2 · Campanha · V2.mov\nREVISAR", attachments: [], userId: 42)
        let ordinary = comment(text: "Ficou ótimo, aprovado!", attachments: [], userId: 42)

        XCTAssertTrue(AppState.isIncompleteMediaTransferComment(ownedPlaceholder, uploaderId: 42))
        XCTAssertFalse(AppState.isIncompleteMediaTransferComment(otherUser, uploaderId: 42))
        XCTAssertFalse(AppState.isIncompleteMediaTransferComment(finalComment, uploaderId: 42))
        XCTAssertFalse(AppState.isIncompleteMediaTransferComment(ordinary, uploaderId: 42))
    }

    func testCleanupRemovesApolloPlaceholdersOfAnyVersion() {
        // An orphaned V2 placeholder must not survive just because the next
        // publish is a V1 or V3 — the safe rule is author + full Apollo
        // pattern + zero attachments + no REVISAR, regardless of version.
        let staleV2 = comment(text: "V2 · Testes · V2.mov", attachments: [], userId: 7)
        let staleV3 = comment(text: "V3 · Testes · V3.mov", attachments: [], userId: 7)
        var withSegmentFile = comment(text: "V2 · Testes · V2.mov", attachments: [], userId: 7)
        withSegmentFile.attachmentIds = ["file-1.mov"]

        XCTAssertTrue(AppState.isIncompleteMediaTransferComment(staleV2, uploaderId: 7))
        XCTAssertTrue(AppState.isIncompleteMediaTransferComment(staleV3, uploaderId: 7))
        XCTAssertFalse(AppState.isIncompleteMediaTransferComment(staleV2, uploaderId: 8))
        // A comment that provably carries a file is never cleanup material,
        // even when its text looks like a placeholder.
        XCTAssertFalse(AppState.isIncompleteMediaTransferComment(withSegmentFile, uploaderId: 7))
    }

    private func comment(text: String,
                         attachments: [CUTask.Attachment],
                         userId: Int = 1) -> CUComment {
        CUComment(id: UUID().uuidString, text: text, date: Date(),
                  userId: userId, userName: "Apollo", userEmail: nil,
                  userColor: nil, initials: "AP", profilePic: nil,
                  resolved: false, reactions: [], replyCount: 0,
                  attachments: attachments)
    }
}
