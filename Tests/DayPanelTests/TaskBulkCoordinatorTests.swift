import XCTest
@testable import ApolloRuntime

@MainActor
final class TaskBulkCoordinatorTests: XCTestCase {
    private func task(_ id: String) -> CUTask {
        CUTask(id: id, title: id, status: "a editar", statusColor: "#F8AE00",
               priority: 3, priorityColor: "#9E9E9E", startDate: nil, dueDate: nil,
               listId: "L", listName: "Video", isCompleted: false)
    }
    private func file(_ name: String) -> TaskMediaSelection {
        .init(fileURL: URL(fileURLWithPath: "/tmp/\(name).mov"), role: .video, contentHash: name)
    }
    private func context() -> AppState {
        ApolloRuntimeEnvironment.activateStudio()
        return AppState(previewMode: true)
    }

    func testPartialRetryPreservesPublishedFilesAndSkipsCompletedTasks() async {
        let state = context(), store = TransferDouble()
        let coordinator = TaskBulkMediaCoordinator(store: store)
        store.failOnce = "a"
        await coordinator.project(tasks: [task("a"), task("b")],
            selectionsFor: { _ in [self.file("one"), self.file("two")] }, appState: state)
        await coordinator.sendAll(extraMentionMemberIds: [], appState: state)
        XCTAssertEqual(coordinator.phase, .partialFailure)
        let originalBatch = store.batches["a"]?.id
        // The real store removes completed batches after a short delay.
        store.batches["b"] = nil
        await coordinator.sendAll(extraMentionMemberIds: [], appState: state)
        XCTAssertEqual(coordinator.phase, .done)
        XCTAssertEqual(store.batches["a"]?.id, originalBatch)
        XCTAssertEqual(store.preparations, ["a": 1, "b": 1])
        XCTAssertEqual(store.uploads["a"], 2)
        XCTAssertEqual(store.uploads["b"], 2)
    }

    func testManifestRetryDoesNotUploadAnyVideoAgain() async {
        let state = context(), store = TransferDouble()
        let coordinator = TaskBulkMediaCoordinator(store: store)
        store.failOnce = "a"; store.failManifest = true
        await coordinator.project(tasks: [task("a")], selectionsFor: { _ in [self.file("one")] }, appState: state)
        await coordinator.sendAll(extraMentionMemberIds: [], appState: state)
        XCTAssertEqual(coordinator.phase, .partialFailure)
        await coordinator.sendAll(extraMentionMemberIds: [], appState: state)
        XCTAssertEqual(coordinator.phase, .done)
        XCTAssertEqual(store.preparations["a"], 1)
        XCTAssertEqual(store.uploads["a"], 1)
    }

    func testLatestProjectionWinsWhenOldCatalogRequestFinishesLast() async {
        let state = context(), store = TransferDouble()
        let coordinator = TaskBulkMediaCoordinator(store: store)
        let started = expectation(description: "old projection suspended")
        store.suspendNextLoad = { started.fulfill() }
        let old = Task { await coordinator.project(tasks: [self.task("old")],
            selectionsFor: { _ in [self.file("old")] }, appState: state) }
        await fulfillment(of: [started], timeout: 2)
        await coordinator.project(tasks: [task("new")], selectionsFor: { _ in [self.file("new")] }, appState: state)
        store.resumeLoad()
        let accepted = await old.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(coordinator.targets.map(\.id), ["new"])
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testProjectionSnapshotsEveryDestinationBeforeSuspending() async {
        let state = context(), store = TransferDouble()
        let coordinator = TaskBulkMediaCoordinator(store: store)
        let started = expectation(description: "catalog suspended")
        store.suspendNextLoad = { started.fulfill() }
        var chosen = [file("original")]
        let projection = Task { await coordinator.project(tasks: [self.task("a"), self.task("b")],
            selectionsFor: { _ in chosen }, appState: state) }
        await fulfillment(of: [started], timeout: 2)
        chosen = [file("changed")]
        store.resumeLoad()
        await projection.value
        XCTAssertEqual(coordinator.resolvedSelections["a"]?.first?.fileURL.lastPathComponent, "original.mov")
        XCTAssertEqual(coordinator.resolvedSelections["b"]?.first?.fileURL.lastPathComponent, "original.mov")
        XCTAssertEqual(store.hashCount, 1, "shared files are hashed once per projection")
    }

    func testRemovingAllFilesClearsThePreviousSendPlan() async {
        let state = context(), store = TransferDouble()
        let coordinator = TaskBulkMediaCoordinator(store: store)
        await coordinator.project(tasks: [task("a")], selectionsFor: { _ in [self.file("one")] }, appState: state)
        await coordinator.project(tasks: [task("a")], selectionsFor: { _ in [] }, appState: state)
        await coordinator.sendAll(extraMentionMemberIds: [], appState: state)
        XCTAssertEqual(coordinator.totalOutputs, 0)
        XCTAssertTrue(store.preparations.isEmpty)
    }

    func testExistingSingleTaskBatchIsNeitherOverwrittenNorDiscarded() async {
        let state = context(), store = TransferDouble()
        await store.prepareAdd(task: task("a"), selections: [file("single")], appState: state)
        let originalBatch = store.batches["a"]?.id
        let coordinator = TaskBulkMediaCoordinator(store: store)
        await coordinator.project(tasks: [task("a")], selectionsFor: { _ in [self.file("bulk")] }, appState: state)
        XCTAssertTrue(coordinator.sendableTargets.isEmpty)
        coordinator.discardAll()
        XCTAssertEqual(store.batches["a"]?.id, originalBatch)
    }

    func testNewPendingBatchAfterProjectionIsNotOverwrittenAtSend() async {
        let state = context(), store = TransferDouble()
        let coordinator = TaskBulkMediaCoordinator(store: store)
        await coordinator.project(tasks: [task("a")], selectionsFor: { _ in [self.file("bulk")] }, appState: state)
        await store.prepareAdd(task: task("a"), selections: [file("single")], appState: state)
        let originalBatch = store.batches["a"]?.id
        await coordinator.sendAll(extraMentionMemberIds: [], appState: state)
        coordinator.discardAll()
        XCTAssertEqual(store.batches["a"]?.id, originalBatch)
        XCTAssertTrue(store.uploads.isEmpty)
    }

    func testConcurrentSendDoesNotStartAnotherBatchOrChangeProjection() async {
        let state = context(), store = TransferDouble()
        let coordinator = TaskBulkMediaCoordinator(store: store)
        await coordinator.project(tasks: [task("a")], selectionsFor: { _ in [self.file("one")] }, appState: state)
        let started = expectation(description: "sending")
        store.suspendNextSend = { started.fulfill() }
        let sending = Task { await coordinator.sendAll(extraMentionMemberIds: [], appState: state) }
        await fulfillment(of: [started], timeout: 2)
        await coordinator.sendAll(extraMentionMemberIds: [], appState: state)
        let accepted = await coordinator.project(tasks: [], selectionsFor: { _ in [] }, appState: state)
        XCTAssertFalse(accepted)
        coordinator.discardAll()
        XCTAssertEqual(coordinator.phase, .sending)
        store.resumeSend()
        await sending.value
        XCTAssertEqual(coordinator.phase, .done)
        XCTAssertEqual(store.preparations["a"], 1)
        XCTAssertEqual(store.uploads["a"], 1)
    }
}

@MainActor
private final class TransferDouble: TaskBulkMediaTransferring {
    var batches: [String: TaskMediaTransferStore.BatchState] = [:]
    var preparations: [String: Int] = [:]
    var uploads: [String: Int] = [:]
    var hashCount = 0
    var failOnce: String?
    var failManifest = false
    var suspendNextLoad: (() -> Void)?
    var suspendNextSend: (() -> Void)?
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var sendContinuation: CheckedContinuation<Void, Never>?

    func loadCatalog(for task: CUTask, appState: AppState) async {
        if let suspended = suspendNextLoad {
            suspendNextLoad = nil
            await withCheckedContinuation { loadContinuation = $0; suspended() }
        }
    }
    func resumeLoad() { loadContinuation?.resume(); loadContinuation = nil }
    func resumeSend() { sendContinuation?.resume(); sendContinuation = nil }
    func catalog(for taskId: String) -> TaskMediaCatalog { .empty(taskId: taskId) }
    func hash(_ selections: [TaskMediaSelection]) async throws -> [TaskMediaSelection] {
        hashCount += selections.count
        return selections.map { original in
            var copy = original; copy.contentHash = original.fileURL.lastPathComponent; return copy
        }
    }
    func prepareAdd(task: CUTask, selections: [TaskMediaSelection], appState: AppState) async {
        preparations[task.id, default: 0] += 1
        let plan = try! TaskMediaPlanner.adding(selections: selections, to: catalog(for: task.id))
        let files = Dictionary(uniqueKeysWithValues: plan.outputs.map { ($0.id, URL(fileURLWithPath: "/tmp/\($0.id).mov")) })
        batches[task.id] = .init(id: UUID(), taskId: task.id, phase: .ready, plan: plan,
            preparedFiles: files, published: [:], completed: 0, total: plan.outputs.count,
            progress: 0, errorMessage: nil)
    }
    func send(task: CUTask, mentionMemberIds: [Int], outputNames: [UUID: String], appState: AppState) async {
        if let suspended = suspendNextSend {
            suspendNextSend = nil
            await withCheckedContinuation { sendContinuation = $0; suspended() }
        }
        guard var batch = batches[task.id] else { return }
        let shouldFail = failOnce == task.id
        if shouldFail { failOnce = nil }
        for output in batch.plan.outputs where batch.published[output.id]?.commentPosted != true {
            uploads[task.id, default: 0] += 1
            batch.published[output.id] = .init(attachmentId: "uploaded-\(output.id)",
                remoteURL: URL(string: "https://example.invalid/\(output.id)")!, commentPosted: true)
            if shouldFail && !failManifest { break }
        }
        batch.completed = batch.published.count
        batch.phase = shouldFail ? .partialFailure : .sent
        batch.progress = Double(batch.completed) / Double(batch.total)
        batches[task.id] = batch
    }
    func phase(for taskId: String) -> TaskMediaTransferStore.Phase? { batches[taskId]?.phase }
    func progress(for taskId: String) -> Double { batches[taskId]?.progress ?? 0 }
    func discard(taskId: String) { batches[taskId] = nil }
}
