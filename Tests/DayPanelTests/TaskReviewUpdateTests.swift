import XCTest
@testable import ApolloRuntime

final class TaskReviewUpdateTests: XCTestCase {
    private func makeTask(id: String = "task-1",
                          updatedAt: Date? = nil,
                          attachments: [CUTask.Attachment] = []) -> CUTask {
        var task = CUTask(
            id: id, title: "TESTE 3", status: "review",
            statusColor: "#7A6597", priority: 0,
            priorityColor: "#9E9E9E", startDate: nil, dueDate: nil,
            listId: "list-1", listName: "Listas / Video",
            isCompleted: false
        )
        task.dateUpdated = updatedAt
        task.attachments = attachments
        return task
    }

    private var reviewAttachment: CUTask.Attachment {
        CUTask.Attachment(
            id: "attachment-review", title: "TESTE OFFICE 01 · V1.mov",
            url: "https://example.com/teste-office.mov", ext: "mov",
            sizeString: nil, totalComments: 2, resolvedComments: 0,
            uploaderId: 42
        )
    }

    @MainActor
    func testCompactListTaskHydratesAttachmentsOnlyOnce() async {
        var fetchCount = 0
        let full = makeTask(attachments: [reviewAttachment])
        let store = TaskReviewUpdateStore(fullTaskFetcher: { _ in
            fetchCount += 1
            return full
        })
        let compact = makeTask()

        let first = await store.taskForProbe(compact)
        let second = await store.taskForProbe(compact)

        XCTAssertEqual(first.visibleAttachments.map(\.id), ["attachment-review"])
        XCTAssertEqual(second.visibleAttachments.map(\.id), ["attachment-review"])
        XCTAssertEqual(fetchCount, 1,
                       "Recycled rows must reuse the hydrated attachment catalog")
    }

    @MainActor
    func testNewerClickUpTaskInvalidatesHydratedAttachmentCatalog() async {
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)
        var fetchCount = 0
        let store = TaskReviewUpdateStore(fullTaskFetcher: { _ in
            fetchCount += 1
            return self.makeTask(
                updatedAt: fetchCount == 1 ? firstDate : secondDate,
                attachments: [self.reviewAttachment]
            )
        })

        _ = await store.taskForProbe(makeTask(updatedAt: firstDate))
        _ = await store.taskForProbe(makeTask(updatedAt: secondDate))

        XCTAssertEqual(fetchCount, 2,
                       "A newer task payload may contain newly attached videos")
    }

    func testAttachCapsuleIsExactlyThirtyPercentNarrower() {
        XCTAssertEqual(MyTasksColumnLayout.mediaWidth, 92 * 0.70,
                       accuracy: 0.001)
    }

    @MainActor
    func testReviewSlotStaysImmediatelyLeftOfAttachWithoutMovingDataColumns() {
        let metrics = MyTasksColumnLayout.shared.metrics(totalWidth: 1_600)
        XCTAssertEqual(metrics.reviewX + metrics.reviewWidth
                       + MyTasksColumnLayout.reviewMediaGap,
                       metrics.mediaX, accuracy: 0.001)
        XCTAssertEqual(metrics.mediaX + metrics.mediaWidth
                       + MyTasksColumnLayout.gap,
                       metrics.priorityX, accuracy: 0.001)
    }

    func testNeverOpenedEmptySessionDoesNotCreateFalseReviewUpdate() {
        let att = "test-empty-\(UUID().uuidString)"
        clearSeen(att)
        let meta = ReviewBackend.Meta(exists: true,
                                      updatedAt: "2026-07-17T18:00:00.000Z",
                                      status: "in_review",
                                      commentCount: 0)
        XCTAssertFalse(ReviewBackend.observe(meta: meta, att: att))
        XCTAssertFalse(ReviewBackend.hasUnseenUpdate(meta: meta, att: att))
        clearSeen(att)
    }

    func testNeverOpenedCompletedReviewIsVisible() {
        let att = "test-completed-\(UUID().uuidString)"
        clearSeen(att)
        let meta = ReviewBackend.Meta(exists: true,
                                      updatedAt: "2026-07-18T14:20:00.000Z",
                                      status: "approved",
                                      commentCount: 0)
        XCTAssertTrue(ReviewBackend.observe(meta: meta, att: att))
        // Polling and opening do not consume the update; completion does.
        XCTAssertTrue(ReviewBackend.hasUnseenUpdate(meta: meta, att: att))
        ReviewBackend.markSeen(att: att, updatedAt: meta.updatedAt,
                               commentCount: meta.commentCount,
                               status: meta.status)
        XCTAssertFalse(ReviewBackend.hasUnseenUpdate(meta: meta, att: att))
        clearSeen(att)
    }

    func testFinalReviewRequiresBothApprovalAndExplicitConclusion() {
        let approvalOnly = ReviewBackend.Meta(
            exists: true, updatedAt: "2026-07-19T19:00:00.000Z",
            status: "approved", commentCount: 1
        )
        let conclusionOnly = ReviewBackend.Meta(
            exists: true, updatedAt: "2026-07-19T19:01:00.000Z",
            status: "in_review", commentCount: 1,
            concludedAt: "2026-07-19T19:01:00.000Z"
        )
        let approvedConclusion = ReviewBackend.Meta(
            exists: true, updatedAt: "2026-07-19T19:02:00.000Z",
            status: "approved", commentCount: 1,
            concludedAt: "2026-07-19T19:02:00.000Z"
        )

        XCTAssertFalse(approvalOnly.isApprovedAndConcluded)
        XCTAssertFalse(conclusionOnly.isApprovedAndConcluded)
        XCTAssertTrue(approvedConclusion.isApprovedAndConcluded)
    }

    @MainActor
    func testInlineApprovalRefreshesRowWithoutConsumingPendingReview() throws {
        let suite = "TaskReviewUpdateTests.inline-approval.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TaskReviewUpdateStore(defaults: defaults)
        let pending = TaskReviewUpdateStore.Update(
            taskId: "task-inline-approval",
            attachment: reviewAttachment,
            activeAtt: reviewAttachment.id,
            meta: ReviewBackend.Meta(
                exists: true, updatedAt: "2026-07-19T22:00:00.000Z",
                status: "in_review", commentCount: 2
            )
        )
        store.applyProbeResult(
            pending, taskId: pending.taskId,
            visibleAttachmentIds: [pending.activeAtt]
        )

        XCTAssertTrue(store.refreshPendingMetadata(
            taskId: pending.taskId,
            activeAtt: pending.activeAtt,
            meta: ReviewBackend.Meta(
                exists: true, updatedAt: "2026-07-19T22:01:00.000Z",
                status: "approved", commentCount: 2
            )
        ))

        let refreshed = try XCTUnwrap(store.update(for: pending.taskId))
        XCTAssertTrue(refreshed.meta.isApproved)
        XCTAssertFalse(refreshed.meta.isApprovedAndConcluded)
        XCTAssertEqual(store.updates(for: pending.taskId).count, 1,
                       "Approval alone must keep VER REVIEW pending")
    }

    @MainActor
    func testUnapprovedConcludedV4KeepsItsRealTitleAndPendingLatch() throws {
        let suite = "TaskReviewUpdateTests.unapproved-v4.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // catalogFetcher nil explícito: o fetcher default agora enxerga os
        // catálogos REAIS da máquina (fallback de container) e este fixture
        // usa um taskId real — o teste precisa ser determinístico.
        let store = TaskReviewUpdateStore(defaults: defaults,
                                          catalogFetcher: { _ in nil })
        let attachment = CUTask.Attachment(
            id: "0cf053fd-c483-4579-bc95-ad7859373bb4.mov",
            title: "THE_MINIMAL_V03 · V4.mov",
            url: "https://example.com/THE_MINIMAL_V03-V4.mov",
            ext: "mov", sizeString: nil, totalComments: 1,
            resolvedComments: 0, uploaderId: 42
        )
        let update = TaskReviewUpdateStore.Update(
            taskId: "86ajhqmw3", attachment: attachment,
            activeAtt: attachment.id,
            meta: ReviewBackend.Meta(
                exists: true,
                updatedAt: "2026-07-19T22:53:41.506Z",
                status: "in_review",
                commentCount: 1,
                concludedAt: "2026-07-19T21:56:09.799Z",
                reviewId: attachment.id,
                currentVersionId: "v1",
                mediaTitle: "Arquivo"
            )
        )

        store.applyProbeResult(update, taskId: update.taskId,
                               visibleAttachmentIds: [attachment.id])

        let pending = try XCTUnwrap(store.updates(for: update.taskId).first)
        XCTAssertEqual(pending.displayTitle, "THE_MINIMAL_V03 · V4.mov")
        XCTAssertFalse(pending.meta.isApprovedAndConcluded)

        let relaunched = TaskReviewUpdateStore(defaults: defaults,
                                               catalogFetcher: { _ in nil })
        let restored = try XCTUnwrap(relaunched.updates(for: update.taskId).first)
        XCTAssertEqual(restored.displayTitle, "THE_MINIMAL_V03 · V4.mov")
        XCTAssertEqual(relaunched.updates(for: update.taskId).count, 1)
    }

    @MainActor
    func testThirdIndependentUnapprovedReviewCannotDisappear() throws {
        let suite = "TaskReviewUpdateTests.third-pending.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TaskReviewUpdateStore(defaults: defaults,
                                          catalogFetcher: { _ in nil })
        let taskId = "86ajhqmw3"

        for index in 1...3 {
            let attachment = CUTask.Attachment(
                id: "pending-review-\(index).mov",
                title: "VIDEO \(index) · V\(index).mov",
                url: "https://example.com/video-\(index).mov",
                ext: "mov", sizeString: nil, totalComments: index,
                resolvedComments: 0, uploaderId: 42
            )
            let update = TaskReviewUpdateStore.Update(
                taskId: taskId, attachment: attachment,
                activeAtt: attachment.id,
                meta: ReviewBackend.Meta(
                    exists: true,
                    updatedAt: "2026-07-19T22:5\(index):00.000Z",
                    status: "in_review",
                    commentCount: index,
                    concludedAt: index == 3
                        ? "2026-07-19T22:59:00.000Z" : nil,
                    reviewId: attachment.id,
                    currentVersionId: "v1",
                    mediaTitle: attachment.title
                )
            )
            store.applyProbeResult(
                update, taskId: taskId,
                visibleAttachmentIds: [attachment.id]
            )
        }

        XCTAssertEqual(store.updates(for: taskId).map(\.displayTitle), [
            "VIDEO 3 · V3.mov", "VIDEO 2 · V2.mov", "VIDEO 1 · V1.mov"
        ])
        XCTAssertTrue(store.updates(for: taskId).allSatisfy {
            !$0.meta.isApprovedAndConcluded
        })

        let relaunched = TaskReviewUpdateStore(defaults: defaults,
                                               catalogFetcher: { _ in nil })
        XCTAssertEqual(relaunched.updates(for: taskId).count, 3)
        XCTAssertTrue(relaunched.updates(for: taskId).contains {
            $0.displayTitle == "VIDEO 3 · V3.mov"
        })
    }

    @MainActor
    func testRemoteApprovedConclusionConsumesPendingReview() async {
        let suite = "TaskReviewUpdateTests.remote-final.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TaskReviewUpdateStore(
            reviewedDisplayDuration: 0.04, defaults: defaults
        )
        let attachment = reviewAttachment
        let pending = TaskReviewUpdateStore.Update(
            taskId: "task-remote-final", attachment: attachment,
            activeAtt: attachment.id,
            meta: ReviewBackend.Meta(
                exists: true, updatedAt: "2026-07-19T19:00:00.000Z",
                status: "in_review", commentCount: 1
            )
        )
        store.applyProbeResult(
            pending, taskId: pending.taskId,
            visibleAttachmentIds: [attachment.id]
        )

        store.recordDiscoveredUpdate(
            taskId: pending.taskId, activeAtt: attachment.id,
            mediaUrl: attachment.url, ext: attachment.ext,
            title: attachment.title, uploaderId: attachment.uploaderId,
            meta: ReviewBackend.Meta(
                exists: true, updatedAt: "2026-07-19T19:05:00.000Z",
                status: "approved", commentCount: 1,
                concludedAt: "2026-07-19T19:05:00.000Z"
            ),
            hasUnseenUpdate: false
        )

        guard case .reviewed? = store.capsuleState(for: pending.taskId) else {
            return XCTFail("Approved remote conclusion must show REVISADO")
        }
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertNil(store.capsuleState(for: pending.taskId))
        XCTAssertNil(TaskReviewUpdateStore(defaults: defaults)
            .capsuleState(for: pending.taskId))
    }

    @MainActor
    func testRemoteUnapprovedConclusionKeepsPendingReview() throws {
        let suite = "TaskReviewUpdateTests.remote-unapproved.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TaskReviewUpdateStore(defaults: defaults)
        let attachment = reviewAttachment
        let taskId = "task-remote-unapproved-\(UUID().uuidString)"
        let pending = TaskReviewUpdateStore.Update(
            taskId: taskId, attachment: attachment,
            activeAtt: attachment.id,
            meta: ReviewBackend.Meta(
                exists: true, updatedAt: "2026-07-19T19:00:00.000Z",
                status: "in_review", commentCount: 1
            )
        )
        store.applyProbeResult(
            pending, taskId: taskId, visibleAttachmentIds: [attachment.id]
        )
        store.recordDiscoveredUpdate(
            taskId: taskId, activeAtt: attachment.id,
            mediaUrl: attachment.url, ext: attachment.ext,
            title: attachment.title, uploaderId: attachment.uploaderId,
            meta: ReviewBackend.Meta(
                exists: true, updatedAt: "2026-07-19T19:05:00.000Z",
                status: "in_review", commentCount: 1,
                concludedAt: "2026-07-19T19:05:00.000Z"
            ),
            hasUnseenUpdate: true
        )

        guard case .update? = store.capsuleState(for: taskId) else {
            return XCTFail("Unapproved conclusion must keep VER REVIEW")
        }
    }

    @MainActor
    func testPristineUnreviewedDiscoveryCannotCreateVerReview() throws {
        let suite = "TaskReviewUpdateTests.pristine-discovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TaskReviewUpdateStore(defaults: defaults)
        let taskId = "task-pristine-\(UUID().uuidString)"
        let attachment = CUTask.Attachment(
            id: "attachment-pristine", title: "VIDEO NOVO.mov",
            url: "https://example.com/video-novo.mov", ext: "mov",
            sizeString: nil, totalComments: 0, resolvedComments: 0,
            uploaderId: 42
        )

        store.recordDiscoveredUpdate(
            taskId: taskId, activeAtt: attachment.id,
            mediaUrl: attachment.url, ext: attachment.ext,
            title: attachment.title, uploaderId: attachment.uploaderId,
            meta: ReviewBackend.Meta(
                exists: true, updatedAt: "2026-07-19T22:00:00.000Z",
                status: "in_review", commentCount: 0
            ),
            hasUnseenUpdate: false
        )

        XCTAssertNil(store.capsuleState(for: taskId),
                     "A new empty session is not a reviewed video")
        XCTAssertNil(TaskReviewUpdateStore(defaults: defaults)
            .capsuleState(for: taskId),
                     "The false positive must never become durable")
    }

    @MainActor
    func testLegacyEmptyFalseLatchIsRemovedButRealCommentSurvives() throws {
        let suite = "TaskReviewUpdateTests.legacy-pristine.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TaskReviewUpdateStore(defaults: defaults)
        let emptyTaskId = "task-legacy-empty-\(UUID().uuidString)"
        let activeTaskId = "task-legacy-active-\(UUID().uuidString)"
        let empty = TaskReviewUpdateStore.Update(
            taskId: emptyTaskId,
            attachment: CUTask.Attachment(
                id: "legacy-empty", title: "SEM REVIEW.mov",
                url: "https://example.com/sem-review.mov", ext: "mov",
                sizeString: nil, totalComments: 0, resolvedComments: 0,
                uploaderId: 42
            ),
            activeAtt: "legacy-empty",
            meta: ReviewBackend.Meta(
                exists: true, updatedAt: "2026-07-19T22:00:00.000Z",
                status: "in_review", commentCount: 0
            )
        )
        let active = TaskReviewUpdateStore.Update(
            taskId: activeTaskId,
            attachment: CUTask.Attachment(
                id: "legacy-active", title: "COM REVIEW.mov",
                url: "https://example.com/com-review.mov", ext: "mov",
                sizeString: nil, totalComments: 1, resolvedComments: 0,
                uploaderId: 42
            ),
            activeAtt: "legacy-active",
            meta: ReviewBackend.Meta(
                exists: true, updatedAt: "2026-07-19T22:01:00.000Z",
                status: "in_review", commentCount: 1
            )
        )
        store.applyProbeResult(empty, taskId: emptyTaskId,
                               visibleAttachmentIds: [empty.activeAtt])
        store.applyProbeResult(active, taskId: activeTaskId,
                               visibleAttachmentIds: [active.activeAtt])

        let key = "taskReviewPendingUpdates.v1"
        let encoded = try XCTUnwrap(defaults.data(forKey: key))
        var records = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [[String: Any]]
        )
        for index in records.indices {
            records[index].removeValue(forKey: "activityVerified")
        }
        defaults.set(try JSONSerialization.data(withJSONObject: records),
                     forKey: key)

        let relaunched = TaskReviewUpdateStore(defaults: defaults)
        XCTAssertNil(relaunched.capsuleState(for: emptyTaskId),
                     "Unsafe legacy empty latches must be migrated away")
        XCTAssertNotNil(relaunched.capsuleState(for: activeTaskId),
                        "A legacy review with a real comment must remain")
    }

    func testRepeatedEmptySessionSaveIsNotReviewerActivity() {
        let att = "test-observed-\(UUID().uuidString)"
        clearSeen(att)
        let opened = ReviewBackend.Meta(exists: true,
                                        updatedAt: "2026-07-18T14:20:00.000Z",
                                        status: "in_review",
                                        commentCount: 0)
        XCTAssertFalse(ReviewBackend.observe(meta: opened, att: att))

        let saved = ReviewBackend.Meta(exists: true,
                                       updatedAt: "2026-07-18T14:21:00.000Z",
                                       status: "in_review",
                                       commentCount: 0)
        XCTAssertFalse(ReviewBackend.observe(meta: saved, att: att),
                       "A technical timestamp change is not a review")
        clearSeen(att)
    }

    func testPristineVersionRegistrationIsNotReviewerActivity() {
        let att = "test-version-registration-\(UUID().uuidString)"
        clearSeen(att)
        ReviewBackend.markSeen(att: att,
                               updatedAt: "2026-07-18T14:20:00.000Z",
                               commentCount: 0,
                               status: "in_review")
        let registered = ReviewBackend.Meta(
            exists: true,
            updatedAt: "2026-07-18T14:21:00.000Z",
            status: "in_review",
            commentCount: 0,
            currentVersionId: "v2"
        )
        XCTAssertFalse(ReviewBackend.observe(meta: registered, att: att),
                       "Registering media must not manufacture VER REVIEW")
        clearSeen(att)
    }

    func testConclusionWithoutCommentsIsReviewerActivity() {
        let att = "test-empty-conclusion-\(UUID().uuidString)"
        clearSeen(att)
        let concluded = ReviewBackend.Meta(
            exists: true,
            updatedAt: "2026-07-18T14:21:00.000Z",
            status: "in_review",
            commentCount: 0,
            concludedAt: "2026-07-18T14:21:00.000Z"
        )
        XCTAssertTrue(ReviewBackend.observe(meta: concluded, att: att),
                      "Explicit conclusion is human activity even unapproved")
        clearSeen(att)
    }

    @MainActor
    func testRelaunchPurgesVerifiedButPristineFalseLatch() throws {
        let suite = "TaskReviewUpdateTests.verified-pristine.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let taskId = "task-verified-pristine-\(UUID().uuidString)"
        let attachment = CUTask.Attachment(
            id: "verified-pristine", title: "VIDEO SEM AVALIACAO.mov",
            url: "https://example.com/sem-avaliacao.mov", ext: "mov",
            sizeString: nil, totalComments: 0, resolvedComments: 0,
            uploaderId: 42
        )
        let store = TaskReviewUpdateStore(defaults: defaults)
        store.applyProbeResult(
            TaskReviewUpdateStore.Update(
                taskId: taskId,
                attachment: attachment,
                activeAtt: attachment.id,
                meta: ReviewBackend.Meta(
                    exists: true,
                    updatedAt: "2026-07-19T22:00:00.000Z",
                    status: "in_review",
                    commentCount: 0
                )
            ),
            taskId: taskId,
            visibleAttachmentIds: [attachment.id]
        )
        XCTAssertNil(store.capsuleState(for: taskId),
                     "A pristine session must be refused at the door now")

        // Reproduce the durable latch written by the unsafe builds: a real
        // latch whose persisted payload is verified-but-pristine.
        store.applyProbeResult(
            TaskReviewUpdateStore.Update(
                taskId: taskId,
                attachment: attachment,
                activeAtt: attachment.id,
                meta: ReviewBackend.Meta(
                    exists: true,
                    updatedAt: "2026-07-19T22:00:00.000Z",
                    status: "in_review",
                    commentCount: 1
                )
            ),
            taskId: taskId,
            visibleAttachmentIds: [attachment.id]
        )
        XCTAssertNotNil(store.capsuleState(for: taskId))
        let key = "taskReviewPendingUpdates.v1"
        let encoded = try XCTUnwrap(defaults.data(forKey: key))
        var records = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [[String: Any]]
        )
        for index in records.indices {
            records[index]["commentCount"] = 0
            records[index]["activityVerified"] = true
        }
        defaults.set(try JSONSerialization.data(withJSONObject: records),
                     forKey: key)

        XCTAssertNil(TaskReviewUpdateStore(defaults: defaults)
            .capsuleState(for: taskId),
            "Relaunch must purge a verified but pristine false latch")
    }

    func testResolvedCheckboxWithSameCommentCountIsActivity() {
        let att = "test-resolved-\(UUID().uuidString)"
        clearSeen(att)
        ReviewBackend.markSeen(att: att,
                               updatedAt: "2026-07-18T14:20:00.000Z",
                               commentCount: 2,
                               status: "in_review")
        let resolved = ReviewBackend.Meta(exists: true,
                                          updatedAt: "2026-07-18T14:21:00.000Z",
                                          status: "in_review",
                                          commentCount: 2)
        XCTAssertTrue(ReviewBackend.observe(meta: resolved, att: att))
        clearSeen(att)
    }

    func testCommentOnNeverOpenedReviewIsVisibleThenConsumed() {
        let att = "test-comment-\(UUID().uuidString)"
        clearSeen(att)
        let meta = ReviewBackend.Meta(exists: true,
                                      updatedAt: "2026-07-17T18:00:00.000Z",
                                      status: "in_review",
                                      commentCount: 2)
        XCTAssertTrue(ReviewBackend.hasUnseenUpdate(meta: meta, att: att))

        ReviewBackend.markSeen(att: att, updatedAt: meta.updatedAt,
                               commentCount: meta.commentCount)
        XCTAssertFalse(ReviewBackend.hasUnseenUpdate(meta: meta, att: att))
        clearSeen(att)
    }

    func testPreviouslyOpenedReviewSurfacesLaterNonCommentUpdate() {
        let att = "test-status-\(UUID().uuidString)"
        clearSeen(att)
        ReviewBackend.markSeen(att: att,
                               updatedAt: "2026-07-17T18:00:00.000Z",
                               commentCount: 1)
        let newer = ReviewBackend.Meta(exists: true,
                                       updatedAt: "2026-07-17T18:01:00.000Z",
                                       status: "concluded",
                                       commentCount: 1)
        XCTAssertTrue(ReviewBackend.hasUnseenUpdate(meta: newer, att: att))
        clearSeen(att)
    }

    @MainActor
    func testCompletedReviewShowsTransientReviewedStateThenDisappears() async {
        let activeAtt = "test-reviewed-capsule-\(UUID().uuidString)"
        clearSeen(activeAtt)
        defer { clearSeen(activeAtt) }
        let store = TaskReviewUpdateStore(reviewedDisplayDuration: 0.04)
        let attachment = CUTask.Attachment(
            id: "attachment-1",
            title: "Video V1.mov",
            url: "https://example.com/video.mov",
            ext: "mov",
            sizeString: nil,
            totalComments: 1,
            resolvedComments: 1,
            uploaderId: 42
        )
        let meta = ReviewBackend.Meta(exists: true,
                                      updatedAt: "2026-07-18T14:57:18.408Z",
                                      status: "approved",
                                      commentCount: 1,
                                      concludedAt: "2026-07-18T14:57:18.408Z")
        let update = TaskReviewUpdateStore.Update(taskId: "task-1",
                                                  attachment: attachment,
                                                  activeAtt: activeAtt,
                                                  meta: meta)

        XCTAssertTrue(store.acknowledgeCompleted(update))
        guard case .reviewed? = store.capsuleState(for: "task-1") else {
            return XCTFail("Completion must immediately publish REVISADO")
        }
        XCTAssertFalse(ReviewBackend.hasUnseenUpdate(meta: meta, att: activeAtt))

        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertNil(store.capsuleState(for: "task-1"))
    }

    @MainActor
    func testPublishedReviewSurvivesNilProbeUntilExplicitAcknowledgement() throws {
        let suite = "TaskReviewUpdateTests.latch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TaskReviewUpdateStore(defaults: defaults)
        let attachment = CUTask.Attachment(
            id: "attachment-latched",
            title: "Video V1.mov",
            url: "https://example.com/video.mov",
            ext: "mov",
            sizeString: nil,
            totalComments: 1,
            resolvedComments: 0,
            uploaderId: 42
        )
        let update = TaskReviewUpdateStore.Update(
            taskId: "task-latched",
            attachment: attachment,
            activeAtt: "review-latched",
            meta: ReviewBackend.Meta(
                exists: true,
                updatedAt: "2026-07-18T15:10:00.000Z",
                status: "in_review",
                commentCount: 1
            )
        )

        store.applyProbeResult(
            update,
            taskId: update.taskId,
            visibleAttachmentIds: [attachment.id]
        )
        store.applyProbeResult(
            nil,
            taskId: update.taskId,
            visibleAttachmentIds: [attachment.id]
        )

        guard case .update? = store.capsuleState(for: update.taskId) else {
            return XCTFail("A plain open/close or nil probe must not consume VER REVIEW")
        }

        store.applyProbeResult(
            nil,
            taskId: update.taskId,
            visibleAttachmentIds: []
        )
        guard case .update? = store.capsuleState(for: update.taskId) else {
            return XCTFail("Attachment refresh must not consume VER REVIEW")
        }

        let confirmed = ReviewBackend.Meta(
            exists: true,
            updatedAt: "2026-07-18T15:11:00.000Z",
            status: "approved",
            commentCount: 1,
            concludedAt: "2026-07-18T15:11:00.000Z"
        )
        XCTAssertTrue(store.acknowledgeConfirmedCompletion(
            taskId: update.taskId,
            pendingActiveAtt: update.activeAtt,
            confirmedActiveAtt: update.activeAtt,
            meta: confirmed
        ))
        XCTAssertNil(TaskReviewUpdateStore(defaults: defaults)
            .capsuleState(for: update.taskId))
    }

    @MainActor
    func testPublishedReviewSurvivesAppRelaunchUntilExplicitCompletion() throws {
        let suite = "TaskReviewUpdateTests.pending.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let attachment = CUTask.Attachment(
            id: "attachment-persisted",
            title: "Updated Video V1.mov",
            url: "https://example.com/updated.mov",
            ext: "mov",
            sizeString: nil,
            totalComments: 2,
            resolvedComments: 0,
            uploaderId: 42
        )
        let update = TaskReviewUpdateStore.Update(
            taskId: "task-persisted",
            attachment: attachment,
            activeAtt: "review-persisted",
            meta: ReviewBackend.Meta(
                exists: true,
                updatedAt: "2026-07-19T18:42:00.000Z",
                status: "in_review",
                commentCount: 2
            )
        )

        let firstLaunch = TaskReviewUpdateStore(defaults: defaults)
        firstLaunch.applyProbeResult(
            update,
            taskId: update.taskId,
            visibleAttachmentIds: [attachment.id]
        )

        let secondLaunch = TaskReviewUpdateStore(defaults: defaults)
        guard case .update? = secondLaunch.capsuleState(for: update.taskId) else {
            return XCTFail("Relaunch must preserve VER REVIEW")
        }

        // A later nil probe/open-close still cannot consume the durable latch.
        secondLaunch.applyProbeResult(
            nil,
            taskId: update.taskId,
            visibleAttachmentIds: [attachment.id]
        )
        let thirdLaunch = TaskReviewUpdateStore(defaults: defaults)
        guard case .update? = thirdLaunch.capsuleState(for: update.taskId) else {
            return XCTFail("Open/close and relaunch must preserve VER REVIEW")
        }

        let confirmed = ReviewBackend.Meta(
            exists: true,
            updatedAt: "2026-07-19T18:43:00.000Z",
            status: "approved",
            commentCount: 2,
            concludedAt: "2026-07-19T18:43:00.000Z"
        )
        XCTAssertTrue(thirdLaunch.acknowledgeConfirmedCompletion(
            taskId: update.taskId,
            pendingActiveAtt: update.activeAtt,
            confirmedActiveAtt: update.activeAtt,
            meta: confirmed
        ))
        let afterCompletion = TaskReviewUpdateStore(defaults: defaults)
        XCTAssertNil(afterCompletion.capsuleState(for: update.taskId))
    }

    @MainActor
    func testMultipleReviewsOnOneTaskPersistAndCompleteIndependently() throws {
        let suite = "TaskReviewUpdateTests.multiple.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let taskId = "task-multiple"
        let firstAttachment = reviewAttachment
        let secondAttachment = CUTask.Attachment(
            id: "attachment-review-2", title: "TESTE OFFICE 02 · V1.mov",
            url: "https://example.com/teste-office-2.mov", ext: "mov",
            sizeString: nil, totalComments: 1, resolvedComments: 0,
            uploaderId: 42
        )
        let first = TaskReviewUpdateStore.Update(
            taskId: taskId, attachment: firstAttachment,
            activeAtt: "review-1",
            meta: ReviewBackend.Meta(exists: true,
                                     updatedAt: "2026-07-19T21:00:00.000Z",
                                     status: "in_review", commentCount: 2)
        )
        let second = TaskReviewUpdateStore.Update(
            taskId: taskId, attachment: secondAttachment,
            activeAtt: "review-2",
            meta: ReviewBackend.Meta(exists: true,
                                     updatedAt: "2026-07-19T21:01:00.000Z",
                                     status: "in_review", commentCount: 1)
        )

        let firstLaunch = TaskReviewUpdateStore(defaults: defaults)
        firstLaunch.applyProbeResult(first, taskId: taskId,
                                     visibleAttachmentIds: [firstAttachment.id])
        firstLaunch.applyProbeResult(second, taskId: taskId,
                                     visibleAttachmentIds: [secondAttachment.id])
        XCTAssertEqual(firstLaunch.updates(for: taskId).count, 2)

        let secondLaunch = TaskReviewUpdateStore(defaults: defaults)
        XCTAssertEqual(secondLaunch.updates(for: taskId).map(\.activeAtt),
                       ["review-2", "review-1"])

        let didCompleteFirst = secondLaunch.acknowledgeConfirmedCompletion(
            taskId: taskId,
            pendingActiveAtt: "review-1",
            confirmedActiveAtt: "review-1",
            meta: ReviewBackend.Meta(
                exists: true,
                updatedAt: "2026-07-19T21:02:00.000Z",
                status: "approved",
                commentCount: 2,
                concludedAt: "2026-07-19T21:02:00.000Z",
                reviewId: "review-1"
            )
        )
        XCTAssertTrue(didCompleteFirst)
        XCTAssertEqual(secondLaunch.updates(for: taskId).map(\.activeAtt),
                       ["review-2"])
        guard case .update? = secondLaunch.capsuleState(for: taskId) else {
            return XCTFail("Completing one video must keep VER REVIEW for its sibling")
        }

        let thirdLaunch = TaskReviewUpdateStore(defaults: defaults)
        XCTAssertEqual(thirdLaunch.updates(for: taskId).map(\.activeAtt),
                       ["review-2"])
    }

    @MainActor
    func testApprovedConcludedSnapshotCannotReappearAsPending() throws {
        let suite = "TaskReviewUpdateTests.final-does-not-return.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TaskReviewUpdateStore(defaults: defaults)
        let final = TaskReviewUpdateStore.Update(
            taskId: "task-final", attachment: reviewAttachment,
            activeAtt: "review-final",
            meta: ReviewBackend.Meta(
                exists: true, updatedAt: "2026-07-19T21:05:00.000Z",
                status: "approved", commentCount: 2,
                concludedAt: "2026-07-19T21:05:00.000Z"
            )
        )

        store.applyProbeResult(final, taskId: final.taskId,
                               visibleAttachmentIds: [reviewAttachment.id])
        XCTAssertTrue(store.updates(for: final.taskId).isEmpty)
        XCTAssertNil(TaskReviewUpdateStore(defaults: defaults)
            .capsuleState(for: final.taskId))
    }

    @MainActor
    func testApprovedConclusionConsumesCanonicalAndLegacyAliasesOnly() throws {
        let suite = "TaskReviewUpdateTests.alias-final.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TaskReviewUpdateStore(defaults: defaults)
        let taskId = "task-alias-final"
        let canonical = reviewAttachment.id
        let legacy = ReviewBackend.att(forMediaUrl: reviewAttachment.url)
        let siblingAttachment = CUTask.Attachment(
            id: "sibling-canonical", title: "OUTRO VIDEO.mov",
            url: "https://example.com/outro-video.mov", ext: "mov",
            sizeString: nil, totalComments: 1, resolvedComments: 0,
            uploaderId: 42
        )
        let legacyPending = TaskReviewUpdateStore.Update(
            taskId: taskId, attachment: reviewAttachment, activeAtt: legacy,
            meta: ReviewBackend.Meta(
                exists: true, updatedAt: "2026-07-19T21:00:00.000Z",
                status: "in_review", commentCount: 2
            )
        )
        let sibling = TaskReviewUpdateStore.Update(
            taskId: taskId, attachment: siblingAttachment,
            activeAtt: siblingAttachment.id,
            meta: ReviewBackend.Meta(
                exists: true, updatedAt: "2026-07-19T21:01:00.000Z",
                status: "in_review", commentCount: 1
            )
        )
        store.applyProbeResult(legacyPending, taskId: taskId,
                               visibleAttachmentIds: [canonical])
        store.applyProbeResult(sibling, taskId: taskId,
                               visibleAttachmentIds: [siblingAttachment.id])

        // The server now reports the canonical id after migration. It must
        // consume the old URL-hash latch, but never the independent sibling.
        store.recordDiscoveredUpdate(
            taskId: taskId, activeAtt: canonical,
            mediaUrl: reviewAttachment.url, ext: reviewAttachment.ext,
            title: reviewAttachment.title,
            uploaderId: reviewAttachment.uploaderId,
            meta: ReviewBackend.Meta(
                exists: true, updatedAt: "2026-07-19T21:05:00.000Z",
                status: "approved", commentCount: 2,
                concludedAt: "2026-07-19T21:05:00.000Z"
            ),
            hasUnseenUpdate: false
        )

        XCTAssertEqual(store.updates(for: taskId).map(\.activeAtt),
                       [siblingAttachment.id])
        let relaunched = TaskReviewUpdateStore(defaults: defaults)
        XCTAssertEqual(relaunched.updates(for: taskId).map(\.activeAtt),
                       [siblingAttachment.id],
                       "The legacy alias must not return after relaunch")
    }

    @MainActor
    func testV3AndPhysicalV4CollapseIntoOnePendingReviewAcrossRelaunch() throws {
        let suite = "TaskReviewUpdateTests.lineage-dedupe.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = replacementCatalog()
        let store = TaskReviewUpdateStore(
            defaults: defaults,
            catalogFetcher: { _ in catalog }
        )
        let v3 = replacementAttachment(
            id: "review-v3", title: "BODY BALDA · V3.mov",
            url: "https://files.test/v3.mov"
        )
        let v4 = replacementAttachment(
            id: "attachment-v4", title: "THE_MINIMAL_V03 · V4.mov",
            url: "https://files.test/v4.mov"
        )

        // The new probe path always reads the exact version, so the server
        // answer carries an authoritative `evaluatedVersionId`. The client is
        // forbidden from fabricating it out of `currentVersionId`/catalog.
        store.applyProbeResult(
            .init(
                taskId: catalog.taskId, attachment: v3, activeAtt: v3.id,
                meta: .init(exists: true,
                            updatedAt: "2026-07-19T20:30:00.000Z",
                            status: "in_review", commentCount: 1,
                            reviewId: v3.id, currentVersionId: "v3",
                            mediaTitle: v3.title, evaluatedVersionId: "v3")
            ),
            taskId: catalog.taskId,
            visibleAttachmentIds: [v3.id, v4.id]
        )
        store.applyProbeResult(
            .init(
                taskId: catalog.taskId, attachment: v4, activeAtt: v4.id,
                meta: .init(exists: true,
                            updatedAt: "2026-07-19T20:31:00.000Z",
                            status: "in_review", commentCount: 1,
                            reviewId: v4.id, currentVersionId: "v1",
                            mediaTitle: v4.title)
            ),
            taskId: catalog.taskId,
            visibleAttachmentIds: [v3.id, v4.id]
        )

        let pending = try XCTUnwrap(store.updates(for: catalog.taskId).first)
        XCTAssertEqual(store.updates(for: catalog.taskId).count, 1)
        XCTAssertEqual(pending.activeAtt, "review-v3")
        XCTAssertEqual(pending.displayTitle, "BODY BALDA · V3.mov")
        XCTAssertEqual(pending.meta.currentVersionId, "v3")
        XCTAssertEqual(pending.meta.evaluatedVersionId, "v3")

        let relaunched = TaskReviewUpdateStore(
            defaults: defaults,
            catalogFetcher: { _ in catalog }
        )
        XCTAssertEqual(relaunched.updates(for: catalog.taskId).count, 1)
        XCTAssertEqual(relaunched.updates(for: catalog.taskId).first?.activeAtt,
                       "review-v3")
        XCTAssertEqual(relaunched.updates(for: catalog.taskId).first?.displayTitle,
                       "BODY BALDA · V3.mov")
        XCTAssertEqual(relaunched.updates(for: catalog.taskId).first?
            .meta.evaluatedVersionId, "v3")
    }

    @MainActor
    func testExactEmptyV4RepairsContaminatedV3LatchWithoutDeletingSibling() throws {
        let suite = "TaskReviewUpdateTests.exact-version-reconcile.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = replacementCatalog()
        let store = TaskReviewUpdateStore(
            defaults: defaults,
            catalogFetcher: { _ in catalog }
        )
        let v4 = replacementAttachment(
            id: "attachment-v4", title: "THE_MINIMAL_V03 · V4.mov",
            url: "https://files.test/v4.mov"
        )
        let sibling = replacementAttachment(
            id: "independent-review", title: "OUTRO VIDEO · V1.mov",
            url: "https://files.test/sibling.mov"
        )

        // Reproduces the persisted corruption found in TESTE 04: the stable
        // lineage points at V4, but carries the two comments/conclusion from
        // an older V3 state.
        store.applyProbeResult(
            .init(
                taskId: catalog.taskId, attachment: v4,
                activeAtt: "review-v3",
                meta: .init(
                    exists: true,
                    updatedAt: "2026-07-20T01:55:26.332Z",
                    status: "in_review", commentCount: 2,
                    concludedAt: "2026-07-20T01:55:26.332Z",
                    reviewId: "review-v3", currentVersionId: "v2",
                    mediaTitle: v4.title, evaluatedVersionId: "v4"
                )
            ),
            taskId: catalog.taskId,
            visibleAttachmentIds: [v4.id]
        )
        store.applyProbeResult(
            .init(
                taskId: catalog.taskId, attachment: sibling,
                activeAtt: sibling.id,
                meta: .init(
                    exists: true,
                    updatedAt: "2026-07-20T01:56:00.000Z",
                    status: "in_review", commentCount: 1,
                    reviewId: sibling.id, currentVersionId: "v1",
                    mediaTitle: sibling.title, evaluatedVersionId: "v1"
                )
            ),
            taskId: catalog.taskId,
            visibleAttachmentIds: [sibling.id]
        )

        XCTAssertEqual(Set(store.updates(for: catalog.taskId).map(\.activeAtt)),
                       Set(["review-v3", sibling.id]))

        // A successful exact-version read is authoritative: V4 has no human
        // activity, so only the contaminated V4 latch disappears. A nil or
        // failed read never reaches this API and therefore deletes nothing.
        store.reconcileOpenedVersion(
            taskId: catalog.taskId,
            activeAtt: "review-v3",
            attachment: v4,
            meta: .init(
                exists: true,
                updatedAt: "2026-07-20T02:00:00.000Z",
                status: "in_review", commentCount: 0,
                reviewId: "review-v3", currentVersionId: "v4",
                mediaTitle: v4.title, evaluatedVersionId: "v4"
            )
        )

        XCTAssertEqual(store.updates(for: catalog.taskId).map(\.activeAtt),
                       [sibling.id])
        XCTAssertEqual(TaskReviewUpdateStore(
            defaults: defaults,
            catalogFetcher: { _ in catalog }
        ).updates(for: catalog.taskId).map(\.activeAtt), [sibling.id])
    }

    @MainActor
    func testLateCatalogMigrationRemovesAlreadyLatchedPhysicalV4Alias() throws {
        let suite = "TaskReviewUpdateTests.late-catalog.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var catalog: TaskMediaCatalog?
        let store = TaskReviewUpdateStore(
            defaults: defaults,
            catalogFetcher: { _ in catalog }
        )
        let v4 = replacementAttachment(
            id: "attachment-v4", title: "THE_MINIMAL_V03 · V4.mov",
            url: "https://files.test/v4.mov"
        )
        let physical = TaskReviewUpdateStore.Update(
            taskId: "86ajhqmw3", attachment: v4, activeAtt: v4.id,
            meta: .init(exists: true,
                        updatedAt: "2026-07-19T20:31:00.000Z",
                        status: "in_review", commentCount: 1,
                        reviewId: v4.id, currentVersionId: "v1",
                        mediaTitle: v4.title)
        )
        store.applyProbeResult(
            physical,
            taskId: physical.taskId,
            visibleAttachmentIds: [v4.id]
        )
        XCTAssertEqual(store.updates(for: physical.taskId).map(\.activeAtt),
                       ["attachment-v4"])

        catalog = replacementCatalog()
        store.applyProbeResult(
            physical,
            taskId: physical.taskId,
            visibleAttachmentIds: [v4.id]
        )

        XCTAssertEqual(store.updates(for: physical.taskId).count, 1)
        XCTAssertEqual(store.updates(for: physical.taskId).first?.activeAtt,
                       "review-v3")
        XCTAssertEqual(store.updates(for: physical.taskId).first?.displayTitle,
                       "THE_MINIMAL_V03 · V4.mov")
    }

    // ── Identidade reviewId#versionId (regras do handoff 20/jul) ─────────────

    @MainActor
    func testEmptyExactV2DiscoveryCannotCreateVerReview() throws {
        let suite = "TaskReviewUpdateTests.empty-exact-v2.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = twoVersionCatalog()
        let store = TaskReviewUpdateStore(defaults: defaults,
                                          catalogFetcher: { _ in catalog })

        // V2 registrada e projetada, mas sem qualquer atividade de revisor.
        store.recordDiscoveredUpdate(
            taskId: catalog.taskId, activeAtt: "review-lineage",
            mediaUrl: "https://files.test/lin-v2.mov", ext: "mov",
            title: "VIDEO · V2.mov", uploaderId: 42,
            meta: .init(exists: true, updatedAt: "2026-07-20T05:00:00.000Z",
                        status: "in_review", commentCount: 0,
                        reviewId: "review-lineage", currentVersionId: "v2",
                        mediaTitle: "VIDEO · V2.mov", evaluatedVersionId: "v2"),
            hasUnseenUpdate: false, versionId: "v2"
        )

        XCTAssertNil(store.capsuleState(for: catalog.taskId),
                     "Uma V2 exata e vazia jamais cria VER REVIEW")
        XCTAssertNil(TaskReviewUpdateStore(defaults: defaults,
                                           catalogFetcher: { _ in catalog })
            .capsuleState(for: catalog.taskId))
    }

    @MainActor
    func testV1ActivityDoesNotContaminateEmptyV2() throws {
        let suite = "TaskReviewUpdateTests.v1-not-v2.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = twoVersionCatalog()
        let store = TaskReviewUpdateStore(defaults: defaults,
                                          catalogFetcher: { _ in catalog })

        store.recordDiscoveredUpdate(
            taskId: catalog.taskId, activeAtt: "review-lineage",
            mediaUrl: "https://files.test/lin-v1.mov", ext: "mov",
            title: "VIDEO · V1.mov", uploaderId: 42,
            meta: .init(exists: true, updatedAt: "2026-07-20T05:01:00.000Z",
                        status: "in_review", commentCount: 2,
                        reviewId: "review-lineage", currentVersionId: "v2",
                        mediaTitle: "VIDEO · V1.mov", evaluatedVersionId: "v1"),
            hasUnseenUpdate: true, versionId: "v1"
        )
        store.recordDiscoveredUpdate(
            taskId: catalog.taskId, activeAtt: "review-lineage",
            mediaUrl: "https://files.test/lin-v2.mov", ext: "mov",
            title: "VIDEO · V2.mov", uploaderId: 42,
            meta: .init(exists: true, updatedAt: "2026-07-20T05:02:00.000Z",
                        status: "in_review", commentCount: 0,
                        reviewId: "review-lineage", currentVersionId: "v2",
                        mediaTitle: "VIDEO · V2.mov", evaluatedVersionId: "v2"),
            hasUnseenUpdate: false, versionId: "v2"
        )

        let updates = store.updates(for: catalog.taskId)
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.meta.evaluatedVersionId, "v1",
                       "A pendência real da V1 sobrevive à leitura vazia da V2")
    }

    @MainActor
    func testCurrentVersionWithoutEvaluationIsNotV2Activity() throws {
        let suite = "TaskReviewUpdateTests.current-not-evaluated.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = twoVersionCatalog()
        let store = TaskReviewUpdateStore(defaults: defaults,
                                          catalogFetcher: { _ in catalog })

        // `currentVersionId = v2` diz apenas qual vídeo está projetado. Sem
        // `evaluatedVersionId` numa linhagem multiversão, o registro é ambíguo
        // e não pode virar pendência.
        store.recordDiscoveredUpdate(
            taskId: catalog.taskId, activeAtt: "review-lineage",
            mediaUrl: "https://files.test/lin-v2.mov", ext: "mov",
            title: "VIDEO · V2.mov", uploaderId: 42,
            meta: .init(exists: true, updatedAt: "2026-07-20T05:03:00.000Z",
                        status: "in_review", commentCount: 2,
                        reviewId: "review-lineage", currentVersionId: "v2",
                        mediaTitle: "VIDEO · V2.mov"),
            hasUnseenUpdate: true
        )

        XCTAssertNil(store.capsuleState(for: catalog.taskId))
    }

    @MainActor
    func testAmbiguousLegacyLatchOnMultiversionLineageIsPurgedOnRelaunch() throws {
        let suite = "TaskReviewUpdateTests.ambiguous-legacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = twoVersionCatalog()
        let store = TaskReviewUpdateStore(defaults: defaults,
                                          catalogFetcher: { _ in catalog })
        let attachment = replacementAttachment(
            id: "att-v2", title: "VIDEO · V2.mov",
            url: "https://files.test/lin-v2.mov"
        )

        // Latch escrito por uma build antiga: atividade real, mas sem saber
        // qual versão foi avaliada — exatamente o estado do TESTE 04.
        store.applyProbeResult(
            .init(taskId: catalog.taskId, attachment: attachment,
                  activeAtt: "review-lineage",
                  meta: .init(exists: true,
                              updatedAt: "2026-07-20T05:04:00.000Z",
                              status: "in_review", commentCount: 2,
                              reviewId: "review-lineage",
                              currentVersionId: "v2",
                              mediaTitle: attachment.title)),
            taskId: catalog.taskId,
            visibleAttachmentIds: [attachment.id]
        )
        XCTAssertNotNil(store.capsuleState(for: catalog.taskId))

        let relaunched = TaskReviewUpdateStore(defaults: defaults,
                                               catalogFetcher: { _ in catalog })
        XCTAssertNil(relaunched.capsuleState(for: catalog.taskId),
                     "Latch ambíguo de linhagem multiversão não volta no relaunch")
    }

    @MainActor
    func testRealCommentOnV2CreatesExactlyOnePendingForV2Only() throws {
        let suite = "TaskReviewUpdateTests.comment-v2.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = twoVersionCatalog()
        let store = TaskReviewUpdateStore(defaults: defaults,
                                          catalogFetcher: { _ in catalog })

        store.recordDiscoveredUpdate(
            taskId: catalog.taskId, activeAtt: "review-lineage",
            mediaUrl: "https://files.test/lin-v2.mov", ext: "mov",
            title: "VIDEO · V2.mov", uploaderId: 42,
            meta: .init(exists: true, updatedAt: "2026-07-20T05:05:00.000Z",
                        status: "in_review", commentCount: 1,
                        reviewId: "review-lineage", currentVersionId: "v2",
                        mediaTitle: "VIDEO · V2.mov", evaluatedVersionId: "v2"),
            hasUnseenUpdate: true, versionId: "v2"
        )

        let updates = store.updates(for: catalog.taskId)
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.activeAtt, "review-lineage")
        XCTAssertEqual(updates.first?.meta.evaluatedVersionId, "v2",
                       "O comentário na V2 pertence à V2, nunca reabre a V1")
    }

    @MainActor
    func testApprovedConclusionOfNewestVersionConsumesSupersededPendencies() throws {
        let suite = "TaskReviewUpdateTests.conclude-newest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = twoVersionCatalog()
        let store = TaskReviewUpdateStore(reviewedDisplayDuration: 0,
                                          defaults: defaults,
                                          catalogFetcher: { _ in catalog })

        for (version, url, count) in [("v1", "https://files.test/lin-v1.mov", 2),
                                      ("v2", "https://files.test/lin-v2.mov", 1)] {
            store.recordDiscoveredUpdate(
                taskId: catalog.taskId, activeAtt: "review-lineage",
                mediaUrl: url, ext: "mov",
                title: "VIDEO · \(version.uppercased()).mov", uploaderId: 42,
                meta: .init(exists: true,
                            updatedAt: "2026-07-20T05:06:00.000Z",
                            status: "in_review", commentCount: count,
                            reviewId: "review-lineage", currentVersionId: "v2",
                            mediaTitle: "VIDEO · \(version.uppercased()).mov",
                            evaluatedVersionId: version),
                hasUnseenUpdate: true, versionId: version
            )
        }

        // Aprovar + concluir a versão MAIS NOVA fecha o ciclo da linhagem:
        // a V2 substitui a V1, então a pendência superada da V1 é consumida
        // junto — senão ela ficaria imortal (versões antigas nunca mais são
        // sondadas). Era exatamente o VER REVIEW eterno do TESTE 04 (20/jul).
        store.recordDiscoveredUpdate(
            taskId: catalog.taskId, activeAtt: "review-lineage",
            mediaUrl: "https://files.test/lin-v2.mov", ext: "mov",
            title: "VIDEO · V2.mov", uploaderId: 42,
            meta: .init(exists: true, updatedAt: "2026-07-20T05:07:00.000Z",
                        status: "approved", commentCount: 1,
                        concludedAt: "2026-07-20T05:07:00.000Z",
                        reviewId: "review-lineage", currentVersionId: "v2",
                        mediaTitle: "VIDEO · V2.mov", evaluatedVersionId: "v2"),
            hasUnseenUpdate: false, versionId: "v2"
        )

        XCTAssertTrue(store.updates(for: catalog.taskId).isEmpty,
                      "Concluir a versão final consome as pendências superadas")
        XCTAssertTrue(TaskReviewUpdateStore(defaults: defaults,
                                            catalogFetcher: { _ in catalog })
            .updates(for: catalog.taskId).isEmpty,
                      "O consumo é durável — nada volta no relaunch")
    }

    @MainActor
    func testApprovedConclusionOfOlderVersionKeepsNewerPendency() throws {
        let suite = "TaskReviewUpdateTests.conclude-older.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = twoVersionCatalog()
        let store = TaskReviewUpdateStore(defaults: defaults,
                                          catalogFetcher: { _ in catalog })

        for (version, url, count) in [("v1", "https://files.test/lin-v1.mov", 2),
                                      ("v2", "https://files.test/lin-v2.mov", 1)] {
            store.recordDiscoveredUpdate(
                taskId: catalog.taskId, activeAtt: "review-lineage",
                mediaUrl: url, ext: "mov",
                title: "VIDEO · \(version.uppercased()).mov", uploaderId: 42,
                meta: .init(exists: true,
                            updatedAt: "2026-07-20T05:06:00.000Z",
                            status: "in_review", commentCount: count,
                            reviewId: "review-lineage", currentVersionId: "v2",
                            mediaTitle: "VIDEO · \(version.uppercased()).mov",
                            evaluatedVersionId: version),
                hasUnseenUpdate: true, versionId: version
            )
        }

        // Concluir uma versão ANTIGA jamais consome a pendência da mais nova.
        store.recordDiscoveredUpdate(
            taskId: catalog.taskId, activeAtt: "review-lineage",
            mediaUrl: "https://files.test/lin-v1.mov", ext: "mov",
            title: "VIDEO · V1.mov", uploaderId: 42,
            meta: .init(exists: true, updatedAt: "2026-07-20T05:07:00.000Z",
                        status: "approved", commentCount: 2,
                        concludedAt: "2026-07-20T05:07:00.000Z",
                        reviewId: "review-lineage", currentVersionId: "v2",
                        mediaTitle: "VIDEO · V1.mov", evaluatedVersionId: "v1"),
            hasUnseenUpdate: false, versionId: "v1"
        )

        let remaining = store.updates(for: catalog.taskId)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.meta.evaluatedVersionId, "v2",
                       "A pendência da versão mais nova sobrevive")
    }

    private func twoVersionCatalog() -> TaskMediaCatalog {
        let videoId = UUID(uuidString: "9B1DEB4D-3B7D-4BAD-9BDD-2B0D7B3DCB6D")!
        let lineage = TaskMediaOutputLineage.direct(video: videoId)
        return TaskMediaCatalog(
            taskId: "task-linhagem",
            sequence: 2,
            assets: [],
            lineages: [lineage],
            outputs: [
                .init(
                    lineageId: lineage.id, version: 1,
                    fileName: "VIDEO · V1.mov", sourceRevisionIds: [],
                    attachmentId: "att-v1",
                    remoteURL: URL(string: "https://files.test/lin-v1.mov"),
                    reviewId: "review-lineage"
                ),
                .init(
                    lineageId: lineage.id, version: 2,
                    fileName: "VIDEO · V2.mov", sourceRevisionIds: [],
                    attachmentId: "att-v2",
                    remoteURL: URL(string: "https://files.test/lin-v2.mov"),
                    reviewId: "review-lineage"
                ),
            ]
        )
    }

    private func replacementCatalog() -> TaskMediaCatalog {
        let videoId = UUID(uuidString: "CFBFD99D-5961-5A17-83A1-C786C2E40BDA")!
        let lineage = TaskMediaOutputLineage.direct(video: videoId)
        return TaskMediaCatalog(
            taskId: "86ajhqmw3",
            sequence: 4,
            assets: [],
            lineages: [lineage],
            outputs: [
                .init(
                    lineageId: lineage.id, version: 3,
                    fileName: "BODY BALDA · V3.mov", sourceRevisionIds: [],
                    attachmentId: "review-v3",
                    remoteURL: URL(string: "https://files.test/v3.mov")
                ),
                .init(
                    lineageId: lineage.id, version: 4,
                    fileName: "THE_MINIMAL_V03 · V4.mov", sourceRevisionIds: [],
                    attachmentId: "attachment-v4",
                    remoteURL: URL(string: "https://files.test/v4.mov"),
                    reviewId: "review-v3"
                ),
            ]
        )
    }

    private func replacementAttachment(id: String, title: String,
                                       url: String) -> CUTask.Attachment {
        CUTask.Attachment(
            id: id, title: title, url: url, ext: "mov",
            sizeString: nil, totalComments: 1, resolvedComments: 0,
            uploaderId: 42
        )
    }

    private func clearSeen(_ att: String) {
        UserDefaults.standard.removeObject(forKey: "reviewSeen.\(att)")
        UserDefaults.standard.removeObject(forKey: "reviewCommentSeen.\(att)")
        UserDefaults.standard.removeObject(forKey: "reviewObserved.\(att)")
        UserDefaults.standard.removeObject(forKey: "reviewObservedStatus.\(att)")
        UserDefaults.standard.removeObject(forKey: "reviewObservedComments.\(att)")
    }
}

final class ReviewWatcherDiscoveryTests: XCTestCase {
    @MainActor
    func testDiscoveredWebUpdateNotifiesOnceAndCanDeepLink() async throws {
        let suite = "ReviewWatcherDiscoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let watcher = ReviewWatcher(defaults: defaults)
        var notifications: [(String, String?, String)] = []
        watcher.notify = { notifications.append(($0, $1, $2)) }
        let att = "attachment-123"
        let meta = ReviewBackend.Meta(exists: true,
                                      updatedAt: "2026-07-18T14:20:00.000Z",
                                      status: "approved",
                                      commentCount: 1)

        await watcher.reportDiscoveredUpdate(
            att: att, mediaUrl: "https://example.com/video.mov", ext: "mov",
            taskId: "task-123", title: "Video V1.mov", uploaderId: 42,
            tintHex: "#7A6597", meta: meta, hasUnseenUpdate: true)
        await watcher.reportDiscoveredUpdate(
            att: att, mediaUrl: "https://example.com/video.mov", ext: "mov",
            taskId: "task-123", title: "Video V1.mov", uploaderId: 42,
            tintHex: "#7A6597", meta: meta, hasUnseenUpdate: true)

        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.0, "Review atualizado")
        XCTAssertEqual(notifications.first?.2, att)
        let params = try XCTUnwrap(watcher.openParams(att: att,
                                                       actorId: 7,
                                                       actorName: "Marconi"))
        XCTAssertEqual(params.taskId, "task-123")
        XCTAssertEqual(params.attachmentId, att)
    }
}
