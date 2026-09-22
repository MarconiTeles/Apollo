import Foundation
import XCTest
@testable import ApolloRuntime

final class ReviewApprovalPayloadTests: XCTestCase {
    func testReadsExplicitApprovalWithoutMutatingPayload() throws {
        let source: [String: Any] = [
            "reviewId": "review-1",
            "status": "approved",
            "comments": [["id": "comment-1", "body": "Ajustar corte"]],
            "versions": [["versionId": "v3", "mediaTitle": "BODY.mov"]],
            "futureField": ["kept": true],
        ]
        let data = try JSONSerialization.data(withJSONObject: source)
        XCTAssertTrue(ReviewBackend.payloadIsApproved(data))
        XCTAssertEqual(
            try JSONSerialization.data(withJSONObject: source),
            data,
            "Checking approval must never rewrite comments or versions"
        )
    }

    func testConclusionCannotImplicitlyApprove() throws {
        let pending = try JSONSerialization.data(withJSONObject: [
            "reviewId": "review-1",
            "status": "in_review",
            "comments": [],
        ])
        XCTAssertFalse(ReviewBackend.payloadIsApproved(pending))
        XCTAssertFalse(ReviewBackend.payloadIsApproved(Data("not-json".utf8)))
    }

    func testInlineApprovalChangesOnlyStatusAndPreservesSessionContent() throws {
        let source: [String: Any] = [
            "reviewId": "review-1",
            "versionId": "v4",
            "status": "in_review",
            "comments": [["id": "comment-1", "resolved": true]],
            "versions": [["versionId": "v3"], ["versionId": "v4"]],
            "futureField": ["kept": true],
        ]
        let data = try JSONSerialization.data(withJSONObject: source)
        let approved = try XCTUnwrap(
            ReviewBackend.payload(data, settingApproved: true)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: approved) as? [String: Any]
        )

        XCTAssertEqual(object["status"] as? String, "approved")
        XCTAssertEqual(object["versionId"] as? String, "v4")
        XCTAssertEqual((object["comments"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((object["versions"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((object["futureField"] as? [String: Bool])?["kept"], true)

        let reopened = try XCTUnwrap(
            ReviewBackend.payload(approved, settingApproved: false)
        )
        XCTAssertFalse(ReviewBackend.payloadIsApproved(reopened))
    }

    func testVersionMetaDoesNotMistakeCurrentRootForSubmittedVersion() throws {
        let resolved = try JSONSerialization.data(withJSONObject: [
            "reviewId": "review-1",
            "currentVersionId": "v3",
            "mediaTitle": "CURRENT.mov",
            "status": "in_review",
            "concludedAt": NSNull(),
            "comments": [],
            "versions": [
                ["versionId": "v2", "mediaTitle": "APPROVED.mov"],
                ["versionId": "v3", "mediaTitle": "CURRENT.mov"],
            ],
            "versionStates": [
                "v2": [
                    "status": "approved",
                    "concludedAt": "2026-07-19T22:57:23.000Z",
                    "updatedAt": "2026-07-19T22:57:23.000Z",
                    "comments": [["id": "c1"]],
                ],
                "v3": [
                    "status": "in_review",
                    "concludedAt": NSNull(),
                    "updatedAt": "2026-07-19T22:58:00.000Z",
                    "comments": [],
                ],
            ],
        ])

        let submitted = try XCTUnwrap(
            ReviewBackend.versionMeta(in: resolved, versionId: " V2 ")
        )
        XCTAssertTrue(submitted.isApprovedAndConcluded)
        XCTAssertEqual(submitted.evaluatedVersionId, "v2")
        XCTAssertEqual(submitted.currentVersionId, "v3")
        XCTAssertEqual(submitted.mediaTitle, "APPROVED.mov")
        XCTAssertEqual(submitted.commentCount, 1)

        let current = try XCTUnwrap(
            ReviewBackend.versionMeta(in: resolved, versionId: "v3")
        )
        XCTAssertFalse(current.isApprovedAndConcluded)
        XCTAssertNil(
            ReviewBackend.versionMeta(in: resolved, versionId: "v4"),
            "A missing version must never fall back to root/current state"
        )
    }

    func testPayloadIdentityIsNormalizedForVersionConfirmation() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "versionId": " V4 ",
            "status": " APPROVED ",
            "comments": [],
        ])
        XCTAssertEqual(ReviewBackend.payloadVersionId(payload), "v4")
        XCTAssertEqual(ReviewBackend.payloadStatus(payload), "approved")
    }
}
