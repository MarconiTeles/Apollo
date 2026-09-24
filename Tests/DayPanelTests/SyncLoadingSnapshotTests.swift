import XCTest
@testable import ApolloRuntime

final class SyncLoadingSnapshotTests: XCTestCase {
    private func steps(_ states: [SyncLoadingSnapshot.StepState]) -> [SyncLoadingSnapshot.Step] {
        states.enumerated().map { .init(id: "s\($0.offset)", label: "", detail: nil, state: $0.element) }
    }

    // MARK: - Progress never claims unfinished work

    func testActiveStepOpensTheCeilingButAddsNoProgress() {
        let (progress, ceiling) = SyncLoadingSnapshot.progress(of: steps([.done, .active, .pending]), scan: nil)
        XCTAssertEqual(progress, 1.0 / 3, accuracy: 1e-9)
        XCTAssertLessThan(ceiling, 2.0 / 3)
        XCTAssertGreaterThan(ceiling, progress)
    }

    func testSkippedStepsDoNotCountAsWork() {
        let (progress, _) = SyncLoadingSnapshot.progress(of: steps([.done, .skipped, .active]), scan: nil)
        XCTAssertEqual(progress, 0.5, accuracy: 1e-9)
    }

    func testDeterminateScanFillsItsOwnSlice() {
        var list = steps([.done, .active, .pending])
        list[1].id = "read"
        let scan = SyncLoadingSnapshot.Scan(done: 45, target: 90, found: 2)
        let (progress, _) = SyncLoadingSnapshot.progress(of: list, scan: scan)
        XCTAssertEqual(progress, 1.0 / 3 + 1.0 / 6, accuracy: 1e-9)
    }

    func testAllDoneIsComplete() {
        let (progress, ceiling) = SyncLoadingSnapshot.progress(of: steps([.done, .done]), scan: nil)
        XCTAssertEqual(progress, 1)
        XCTAssertEqual(ceiling, 1)
    }

    // MARK: - Scenes say what is true

    func testTasksSceneReportsStreamedPagesWhileFetching() {
        var input = SyncLoadingInputs()
        input.journal = [.structure: .done(count: 6), .tasks: .active]
        input.streamedTasks = 200
        input.workspaceName = "Moon Ventures"
        input.listName = "Edição"
        let snapshot = SyncLoadingSnapshot.make(.tasks, input)
        XCTAssertEqual(snapshot.headline, "Sincronizando tarefas")
        XCTAssertEqual(snapshot.context, "Moon Ventures · Edição")
        XCTAssertEqual(snapshot.metric, .init(value: 200, label: "tarefas"))
        XCTAssertEqual(snapshot.steps.map(\.state), [.done, .done, .active])
        XCTAssertEqual(snapshot.steps[1].detail, "6 status")
        XCTAssertEqual(snapshot.steps[2].detail, "200 recebidas…")
    }

    func testTasksSceneShowsNoCountBeforeAnythingArrived() {
        var input = SyncLoadingInputs()
        input.journal = [.structure: .active, .tasks: .active]
        let snapshot = SyncLoadingSnapshot.make(.tasks, input)
        XCTAssertNil(snapshot.metric)
        XCTAssertEqual(snapshot.headline, "Lendo a estrutura da lista")
        XCTAssertEqual(snapshot.steps[2].detail, "Solicitando ao ClickUp")
    }

    func testConnectedAccountWithoutUserIdIsResolvingNotDisconnected() {
        var input = SyncLoadingInputs()
        input.resolvingIdentity = true
        let snapshot = SyncLoadingSnapshot.make(.comments, input)
        XCTAssertEqual(snapshot.headline, "Confirmando sua conta")
        XCTAssertEqual(snapshot.steps.first?.state, .active)
    }

    func testBoardUsesCardVocabularyAndColumns() {
        var input = SyncLoadingInputs()
        input.journal = [.structure: .cached(count: 5), .tasks: .done(count: 1)]
        input.statuses = [.init(name: "a fazer", color: "#87909E")]
        let snapshot = SyncLoadingSnapshot.make(.board, input)
        XCTAssertEqual(snapshot.metric, .init(value: 1, label: "cartão"))
        XCTAssertEqual(snapshot.steps[1].detail, "5 colunas · em cache")
        XCTAssertEqual(snapshot.columns, [.init(name: "a fazer", color: "#87909E")])
    }

    func testCommentsScanIsCappedAtTheAutoScanWindow() {
        var input = SyncLoadingInputs()
        input.commentsTotal = 214
        input.commentsScanned = 30
        input.commentsFound = 1
        input.commentsLoading = true
        let snapshot = SyncLoadingSnapshot.make(.comments, input)
        XCTAssertEqual(snapshot.scan, .init(done: 30, target: 90, found: 1))
        XCTAssertEqual(snapshot.steps[1].detail, "30 de 90")
        XCTAssertEqual(snapshot.metric, .init(value: 1, label: "encontrado"))
    }

    func testInboxExplainsTheFirstReadingAndDisconnectedSources() {
        var input = SyncLoadingInputs()
        input.journal = [.tasks: .done(count: 287), .calendar: .skipped, .changes: .pending]
        let snapshot = SyncLoadingSnapshot.make(.inbox, input)
        XCTAssertEqual(snapshot.context, "Primeira sincronização desta sessão")
        XCTAssertEqual(snapshot.steps[0].detail, "287 tarefas")
        XCTAssertEqual(snapshot.steps[1].detail, "Não conectado")
        XCTAssertEqual(snapshot.steps[1].state, .skipped)
        XCTAssertEqual(snapshot.steps[2].detail, "Primeira leitura: sem alertas")
    }

    func testOfflineInboxSaysSo() {
        var input = SyncLoadingInputs()
        input.online = false
        XCTAssertEqual(SyncLoadingSnapshot.make(.inbox, input).headline, "Sem conexão")
    }

    // MARK: - Journal

    @MainActor
    func testJournalRunLifecycle() {
        let journal = SyncJournal()
        journal.beginRun(stages: [.tasks, .changes])
        XCTAssertEqual(journal.state(of: .calendar), .skipped)
        XCTAssertEqual(journal.state(of: .tasks), .pending)
        journal.mark(.tasks, .active)
        journal.streamed(tasks: 100)
        XCTAssertEqual(journal.streamedTasks, 100)
        journal.failActiveStages()
        XCTAssertEqual(journal.state(of: .tasks), .failed)
        XCTAssertFalse(journal.hasCompletedSync)
        journal.finishRun()
        XCTAssertTrue(journal.hasCompletedSync)
    }
}

final class SyncLoadingLayoutTests: XCTestCase {
    func testOnlyWholeItemsFit() {
        // 800 pt board, cards from 150, capsule reserve 108: 4 whole cards.
        XCTAssertEqual(SyncLoadingLayout.fitting(bottom: 800 - 108, top: 150, size: 106, gap: 12), 4)
        // Exactly enough room for two items and their gap.
        XCTAssertEqual(SyncLoadingLayout.fitting(bottom: 100 + 58 * 2 + 9, top: 100, size: 58, gap: 9), 2)
        XCTAssertEqual(SyncLoadingLayout.fitting(bottom: 10, top: 100, size: 58, gap: 9), 1)
    }

    func testTaskGroupsNeverCutARow() {
        let top: CGFloat = 93
        for height in stride(from: CGFloat(300), through: 1600, by: 37) {
            let groups = SyncLoadingLayout.taskGroups(height: height, top: top)
            var y = top
            for (index, rows) in groups.enumerated() {
                if index > 0 { y += SyncLoadingLayout.taskGroupGap }
                y += SyncLoadingLayout.taskHeader + CGFloat(rows) * SyncLoadingLayout.taskRow
            }
            XCTAssertLessThanOrEqual(y, height, "height \(height)")
            XCTAssertGreaterThan(height - y, -1)
            XCTAssertTrue(groups.allSatisfy { $0 >= 1 })
        }
    }

    func testTaskGroupSequence() {
        XCTAssertEqual(SyncLoadingLayout.taskGroups(height: 2000, top: 93).prefix(3), [3, 6, 5])
    }
}

final class MyTasksLoadingGateTests: XCTestCase {
    private func gate(tasks: Bool, statuses: Bool, syncing: Bool, neverSynced: Bool = false,
                      completed: Bool, list: Bool = true) -> Bool {
        EditorialMyTasksView.isLoadingData(hasList: list, hasTasks: tasks, hasStatuses: statuses,
                                           isSyncing: syncing, neverSynced: neverSynced,
                                           completedSessionSync: completed)
    }

    func testCachedTasksWithoutStatusesAtLaunchIsLoading() {
        // The launch state behind "Status indisponíveis": tasks from disk,
        // statuses not fetched yet, first sync of the session running.
        XCTAssertTrue(gate(tasks: true, statuses: false, syncing: true, completed: false))
        // …and in the beat before that sync starts.
        XCTAssertTrue(gate(tasks: true, statuses: false, syncing: false, completed: false))
    }

    func testMissingStatusesAfterACompletedSyncIsARealEmptyState() {
        XCTAssertFalse(gate(tasks: true, statuses: false, syncing: false, completed: true))
    }

    func testEmptyListWhileSyncingIsLoading() {
        XCTAssertTrue(gate(tasks: false, statuses: true, syncing: true, completed: true))
        XCTAssertFalse(gate(tasks: false, statuses: true, syncing: false, completed: true))
    }

    func testReadyListIsNotLoading() {
        XCTAssertFalse(gate(tasks: true, statuses: true, syncing: true, completed: false))
    }

    func testOfflineIsNeverLoading() {
        XCTAssertFalse(EditorialMyTasksView.isLoadingData(hasList: true, online: false, hasTasks: true,
                                                          hasStatuses: false, isSyncing: false,
                                                          neverSynced: false, completedSessionSync: false))
    }

    func testNoSelectedListIsNeverLoading() {
        XCTAssertFalse(gate(tasks: false, statuses: false, syncing: true, completed: false, list: false))
    }
}

final class ListMetadataFallbackTests: XCTestCase {
    func testStatusesDerivedFromTasksKeepFirstSeenOrderAndColour() {
        let tasks = [
            CUTask(id: "1", title: "a", status: "em andamento", statusColor: "#5F55EE", priority: 0, priorityColor: "", startDate: nil, dueDate: nil, listId: "l", listName: "L", isCompleted: false),
            CUTask(id: "2", title: "b", status: "a fazer", statusColor: "#87909E", priority: 0, priorityColor: "", startDate: nil, dueDate: nil, listId: "l", listName: "L", isCompleted: false),
            CUTask(id: "3", title: "c", status: "Em andamento", statusColor: "#000000", priority: 0, priorityColor: "", startDate: nil, dueDate: nil, listId: "l", listName: "L", isCompleted: false),
            CUTask(id: "4", title: "d", status: "concluído", statusColor: "#008844", priority: 0, priorityColor: "", startDate: nil, dueDate: nil, listId: "l", listName: "L", isCompleted: true),
        ]
        let statuses = AppState.statuses(derivedFrom: tasks)
        XCTAssertEqual(statuses.map(\.status), ["em andamento", "a fazer", "concluído"])
        XCTAssertEqual(statuses.first?.color, "#5F55EE")
        XCTAssertEqual(statuses.last?.type, "closed")
    }

    // MARK: - Agenda

    func testAgendaSceneFollowsTheCalendarRead() {
        var input = SyncLoadingInputs()
        input.googleConnected = true
        input.journal[.calendar] = .active
        var snapshot = SyncLoadingSnapshot.make(.agenda, input)
        XCTAssertEqual(snapshot.headline, "Montando sua agenda")
        XCTAssertEqual(snapshot.steps.map(\.id), ["google", "events", "shared", "month"])
        XCTAssertEqual(snapshot.steps[1].state, .active)
        XCTAssertEqual(snapshot.steps[2].state, .active)
        XCTAssertNil(snapshot.metric)

        input.journal[.calendar] = .done(count: 12)
        snapshot = SyncLoadingSnapshot.make(.agenda, input)
        XCTAssertEqual(snapshot.metric?.value, 12)
        XCTAssertEqual(snapshot.steps[1].state, .done)
        XCTAssertEqual(snapshot.steps[3].state, .done)
    }

    func testAgendaWithoutGoogleSkipsTheAccount() {
        let snapshot = SyncLoadingSnapshot.make(.agenda, SyncLoadingInputs())
        XCTAssertEqual(snapshot.steps[0].state, .skipped)
    }
}
