import CryptoKit
import Foundation

@MainActor
final class TaskMediaTransferStore: ObservableObject {
    enum Phase: Equatable {
        case preparing
        case ready
        case sending
        case partialFailure
        case sent
        case failed
    }

    struct PublishedArtifact: Equatable, Sendable {
        let attachmentId: String?
        let remoteURL: URL
        var commentId: String?
        var commentPosted: Bool
    }

    struct BatchState {
        let id: UUID
        let taskId: String
        var phase: Phase
        var plan: TaskMediaPlan
        var preparedFiles: [UUID: URL]
        var published: [UUID: PublishedArtifact]
        var completed: Int
        var total: Int
        var progress: Double
        var errorMessage: String?

        var pendingCount: Int { max(0, total - completed) }
    }

    @Published private(set) var catalogs: [String: TaskMediaCatalog] = [:]
    @Published private(set) var batches: [String: BatchState] = [:]

    private let composer = TaskVideoComposer()
    private let fileManager = FileManager.default
    private static var cleanedWorkingDirectoriesForCurrentProcess = false

    init() {
        // Batches deliberately live in memory. After a fresh launch, previous
        // working directories are orphaned; remove them without touching the
        // persistent source cache or the synchronized catalogs.
        if !Self.cleanedWorkingDirectoriesForCurrentProcess {
            Self.cleanedWorkingDirectoriesForCurrentProcess = true
            Self.cleanupOrphanedWorkingDirectories()
        }
    }

    func catalog(for taskId: String) -> TaskMediaCatalog {
        catalogs[taskId] ?? loadLocalCatalog(taskId: taskId) ?? .empty(taskId: taskId)
    }

    func phase(for taskId: String) -> Phase? { batches[taskId]?.phase }

    func capsuleLabel(for taskId: String) -> String {
        guard let batch = batches[taskId] else {
            return Self.capsuleLabel(phase: nil, completed: 0, total: 0, pending: 0)
        }
        return Self.capsuleLabel(phase: batch.phase,
                                 completed: batch.completed,
                                 total: batch.total,
                                 pending: batch.pendingCount)
    }

    static func capsuleLabel(phase: Phase?, completed: Int,
                             total: Int, pending: Int) -> String {
        switch phase {
        case .preparing: return "PREPARANDO \(completed)/\(total)"
        case .ready: return "ENVIAR"
        case .sending: return "ENVIANDO \(completed)/\(total)"
        case .partialFailure: return pending > 0 ? "REPETIR \(pending)" : "FINALIZAR"
        case .sent: return "ENVIADO"
        case .failed: return "REPETIR"
        case nil: return "ANEXAR"
        }
    }

    static func canSend(phase: Phase, total: Int) -> Bool {
        phase == .ready || phase == .partialFailure || (phase == .failed && total > 0)
    }

    func progress(for taskId: String) -> Double { batches[taskId]?.progress ?? 0 }

    func loadCatalog(for task: CUTask, appState: AppState) async {
        await appState.hydrateTaskAttachments(taskId: task.id)
        let hydrated = appState.tasksById[task.id] ?? task
        let local = loadLocalCatalog(taskId: task.id)
        let remote = await loadRemoteCatalog(from: hydrated.attachments)
        var chosen: TaskMediaCatalog
        if let remote, remote.taskId == task.id,
           remote.sequence >= (local?.sequence ?? -1) {
            chosen = remote
        } else {
            chosen = local ?? .empty(taskId: task.id)
        }
        _ = chosen.importLegacyVideoAttachments(hydrated.attachments)
        catalogs[task.id] = chosen
        persistLocal(chosen)
        // Record which attachments are superseded versions so the detail's
        // attachment list can hide them (each composed video shows once, at its
        // newest version) — even for substitutions made before this shipped.
        // UserDefaults-only write: it must NOT trigger a re-hydrate here (that
        // mutates @Published state observed by the sheet that called this, which
        // caused a render loop). The list applies the filter read-only.
        AttachmentSupersession.syncFromCatalog(chosen, taskId: task.id)
    }

    func prepareAdd(task: CUTask, selections: [TaskMediaSelection],
                    appState: AppState) async {
        do {
            if catalogs[task.id] == nil { await loadCatalog(for: task, appState: appState) }
            let hashed = try await hash(selections)
            let plan = try TaskMediaPlanner.adding(selections: hashed, to: catalog(for: task.id))
            try await prepare(task: task, plan: plan)
        } catch {
            recordPreparationFailure(taskId: task.id, message: error.localizedDescription)
        }
    }

    func prepareReplacement(task: CUTask, assetId: UUID, replacementURL: URL,
                            appState: AppState) async {
        await prepareReplacements(task: task,
                                  replacementURLs: [assetId: replacementURL],
                                  appState: appState)
    }

    func prepareReplacements(task: CUTask, replacementURLs: [UUID: URL],
                             appState: AppState) async {
        do {
            if catalogs[task.id] == nil { await loadCatalog(for: task, appState: appState) }
            let current = catalog(for: task.id)
            var raw: [UUID: TaskMediaSelection] = [:]
            for (assetId, replacementURL) in replacementURLs {
                guard let asset = current.asset(id: assetId) else {
                    throw TaskMediaPlannerError.assetNotFound
                }
                raw[assetId] = TaskMediaSelection(fileURL: replacementURL, role: asset.role)
            }
            let hashedValues = try await hash(Array(raw.values))
            var hashedByURL: [URL: TaskMediaSelection] = [:]
            for selection in hashedValues { hashedByURL[selection.fileURL] = selection }
            let replacements = raw.compactMapValues { hashedByURL[$0.fileURL] }
            let plan = try TaskMediaPlanner.replacing(replacements: replacements,
                                                      in: current)
            try await prepare(task: task, plan: plan)
        } catch {
            recordPreparationFailure(taskId: task.id, message: error.localizedDescription)
        }
    }

    func send(task: CUTask, mentionMemberIds: [Int],
              outputNames: [UUID: String] = [:], appState: AppState) async {
        guard var batch = batches[task.id],
              Self.canSend(phase: batch.phase, total: batch.total) else { return }
        do {
            try applyOutputNames(outputNames, to: &batch)
        } catch {
            batch.errorMessage = error.localizedDescription
            batches[task.id] = batch
            return
        }
        batch.phase = .sending
        batch.errorMessage = nil
        batch.completed = batch.published.values.filter(\.commentPosted).count
        batch.progress = batch.total == 0 ? 0 : Double(batch.completed) / Double(batch.total)
        batches[task.id] = batch

        do {
            try await uploadPendingSources(task: task, appState: appState)
            try await publishOutputs(task: task, mentionMemberIds: mentionMemberIds,
                                     appState: appState)
            guard var completedBatch = batches[task.id] else { return }
            let allPosted = completedBatch.plan.outputs.allSatisfy {
                completedBatch.published[$0.id]?.commentPosted == true
            }
            guard allPosted else {
                completedBatch.phase = .partialFailure
                completedBatch.errorMessage = "Alguns vídeos não foram publicados."
                batches[task.id] = completedBatch
                return
            }

            var committed = completedBatch.plan.catalog
            for output in completedBatch.plan.outputs {
                guard let artifact = completedBatch.published[output.id] else { continue }
                if let videoId = output.videoAssetId,
                   let assetIndex = committed.assets.firstIndex(where: { $0.id == videoId }),
                   let revisionIndex = committed.assets[assetIndex].revisions.firstIndex(where: {
                       $0.id == committed.assets[assetIndex].activeRevisionId
                   }) {
                    committed.assets[assetIndex].revisions[revisionIndex].attachmentId = artifact.attachmentId
                    committed.assets[assetIndex].revisions[revisionIndex].remoteURL = artifact.remoteURL
                }
                let revisionIds = [output.hookAssetId, output.bodyAssetId, output.videoAssetId]
                    .compactMap { $0 }
                    .compactMap { committed.asset(id: $0)?.activeRevision?.id }
                committed.outputs.append(
                    TaskMediaOutputVersion(lineageId: output.lineage.id,
                                           version: output.version,
                                           fileName: output.displayFileName,
                                           sourceRevisionIds: revisionIds,
                                           attachmentId: artifact.attachmentId,
                                           remoteURL: artifact.remoteURL)
                )
            }
            committed.sequence += 1
            try await uploadManifest(committed, task: task, appState: appState)
            catalogs[task.id] = committed
            persistLocal(committed)
            // Record the just-superseded older versions so the attachment list
            // hides them (read-only filter). UserDefaults write only — no
            // re-hydrate here (that mutates state observed by this sheet).
            AttachmentSupersession.syncFromCatalog(committed, taskId: task.id)
            completedBatch.phase = .sent
            completedBatch.plan.catalog = committed
            completedBatch.completed = completedBatch.total
            completedBatch.progress = 1
            batches[task.id] = completedBatch
            cleanupPreparedFiles(completedBatch)
            // Belt-and-suspenders: sweep any attachment-less "copy" comment that
            // ClickUp may have left behind (its file embedded onto a sibling).
            let publishedIds = Set(completedBatch.published.values.compactMap(\.attachmentId))
            Task { await appState.reconcileMediaTransferComments(taskId: task.id,
                                                                 publishedAttachmentIds: publishedIds) }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.4))
                guard self?.batches[task.id]?.phase == .sent else { return }
                self?.batches[task.id] = nil
            }
        } catch {
            guard var failed = batches[task.id] else { return }
            failed.phase = failed.published.isEmpty ? .failed : .partialFailure
            failed.errorMessage = error.localizedDescription
            batches[task.id] = failed
        }
    }

    func discard(taskId: String) {
        if let batch = batches.removeValue(forKey: taskId) { cleanupPreparedFiles(batch) }
    }

    var replaceablePendingCountByTask: [String: Int] {
        batches.mapValues { batch in
            batch.plan.outputs.filter { batch.published[$0.id] == nil }.count
        }
    }

    func pendingOutputs(for taskId: String) -> [TaskMediaPlannedOutput] {
        guard let batch = batches[taskId] else { return [] }
        return batch.plan.outputs.filter { batch.published[$0.id]?.commentPosted != true }
    }

    func replacePendingOutputs(taskId: String, with urls: [URL]) async throws {
        guard var batch = batches[taskId] else { return }
        let outputIds = batch.plan.outputs
            .filter { batch.published[$0.id] == nil }
            .map(\.id)
        guard !outputIds.isEmpty, outputIds.count == urls.count else {
            throw TransferError.wrongReplacementCount(expected: outputIds.count)
        }
        for (outputId, source) in zip(outputIds, urls) {
            guard let current = batch.preparedFiles[outputId] else { continue }
            try await copyFile(from: source, to: current)
        }
        batch.phase = batch.published.isEmpty ? .ready : .partialFailure
        batch.errorMessage = nil
        batch.completed = batch.published.values.filter(\.commentPosted).count
        batch.progress = Double(batch.completed) / Double(max(1, batch.total))
        batches[taskId] = batch
    }

    private func applyOutputNames(_ names: [UUID: String], to batch: inout BatchState) throws {
        guard !names.isEmpty else { return }
        var used = Set(batch.plan.outputs.compactMap { output -> String? in
            guard batch.published[output.id]?.commentPosted == true else { return nil }
            let ext = batch.preparedFiles[output.id]?.pathExtension.isEmpty == false
                ? batch.preparedFiles[output.id]!.pathExtension : "mov"
            return TaskMediaOutputName.comparisonKey(output.displayFileName,
                                                     pathExtension: ext)
        })
        for index in batch.plan.outputs.indices {
            let output = batch.plan.outputs[index]
            guard batch.published[output.id]?.commentPosted != true else { continue }
            guard let requested = names[output.id] else { continue }
            let ext = batch.preparedFiles[output.id]?.pathExtension.isEmpty == false
                ? batch.preparedFiles[output.id]!.pathExtension : "mov"
            guard let finalName = TaskMediaOutputName.normalized(requested,
                                                                 pathExtension: ext),
                  let key = TaskMediaOutputName.comparisonKey(requested,
                                                              pathExtension: ext) else {
                throw TransferError.invalidFileName
            }
            guard used.insert(key).inserted else {
                throw TransferError.duplicateOutputName(finalName)
            }
            if let current = batch.preparedFiles[output.id],
               current.lastPathComponent != finalName {
                let destination = uniqueURL(in: current.deletingLastPathComponent(),
                                            fileName: finalName)
                try fileManager.moveItem(at: current, to: destination)
                batch.preparedFiles[output.id] = destination
            }
            batch.plan.outputs[index].displayFileName = finalName
        }
    }

    private func prepare(task: CUTask, plan: TaskMediaPlan) async throws {
        let id = UUID()
        let total = plan.outputs.count
        batches[task.id] = BatchState(id: id, taskId: task.id, phase: .preparing,
                                      plan: plan, preparedFiles: [:], published: [:],
                                      completed: 0, total: total, progress: 0,
                                      errorMessage: nil)
        let directory = try batchDirectory(taskId: task.id, batchId: id)
        for (index, output) in plan.outputs.enumerated() {
            guard batches[task.id]?.id == id else { throw CancellationError() }
            let destination = uniqueURL(in: directory, fileName: output.displayFileName)
            if let videoId = output.videoAssetId {
                let source = try await localURL(for: videoId, catalog: plan.catalog)
                try await copyFile(from: source, to: destination)
            } else if let hookId = output.hookAssetId, let bodyId = output.bodyAssetId {
                let hook = try await localURL(for: hookId, catalog: plan.catalog)
                let body = try await localURL(for: bodyId, catalog: plan.catalog)
                try await composer.compose(hookURL: hook, bodyURL: body,
                                           outputURL: destination) { [weak self] value in
                    Task { @MainActor in
                        guard let self, var state = self.batches[task.id], state.id == id else { return }
                        let aggregate = (Double(index) + value) / Double(max(1, total))
                        if abs(aggregate - state.progress) >= 0.01 || aggregate >= 1 {
                            state.progress = aggregate
                            self.batches[task.id] = state
                        }
                    }
                }
            }
            guard var state = batches[task.id], state.id == id else { throw CancellationError() }
            state.preparedFiles[output.id] = destination
            state.completed = index + 1
            state.progress = Double(index + 1) / Double(max(1, total))
            batches[task.id] = state
        }
        guard var ready = batches[task.id], ready.id == id else { throw CancellationError() }
        ready.phase = .ready
        ready.completed = 0
        ready.progress = 0
        batches[task.id] = ready
    }

    private func uploadPendingSources(task: CUTask, appState: AppState) async throws {
        guard var batch = batches[task.id] else { return }
        for assetIndex in batch.plan.catalog.assets.indices {
            guard batch.plan.catalog.assets[assetIndex].role != .video else { continue }
            guard let active = batch.plan.catalog.assets[assetIndex].activeRevision,
                  active.attachmentId == nil,
                  let local = active.localURL else { continue }
            let asset = batch.plan.catalog.assets[assetIndex]
            let technicalName = TaskMediaTechnicalName.source(asset: asset, revision: active)
            let staged = try await stagedCopy(of: local, named: technicalName,
                                              taskId: task.id, batchId: batch.id)
            guard let uploaded = await appState.uploadCommentAttachment(for: task,
                                                                         fileURL: staged,
                                                                         userFacing: false) else {
                throw TransferError.uploadFailed(active.originalFileName)
            }
            guard let revisionIndex = batch.plan.catalog.assets[assetIndex].revisions
                .firstIndex(where: { $0.id == active.id }) else { continue }
            batch.plan.catalog.assets[assetIndex].revisions[revisionIndex].attachmentId = uploaded.id
            batch.plan.catalog.assets[assetIndex].revisions[revisionIndex].remoteURL = uploaded.url
            batches[task.id] = batch
        }
    }

    private func publishOutputs(task: CUTask, mentionMemberIds: [Int],
                                appState: AppState) async throws {
        guard let snapshot = batches[task.id] else { return }
        let pending = snapshot.plan.outputs.filter {
            snapshot.published[$0.id]?.commentPosted != true
        }
        // Publish ONE output per round. Posting a comment+attachment pair
        // concurrently let ClickUp mis-associate both files onto whichever
        // comment it embedded first, leaving the other comment attachment-less
        // (it then rendered as a bare review link — the "comentário duplicado").
        // Serial keeps each attachment on its own comment.
        for start in stride(from: 0, to: pending.count, by: 1) {
            let chunk = Array(pending[start..<min(start + 1, pending.count)])
            let existingPublished = batches[task.id]?.published ?? [:]
            let results = await withTaskGroup(of: PublishResult.self, returning: [PublishResult].self) { group in
                for output in chunk {
                    guard let file = snapshot.preparedFiles[output.id] else { continue }
                    let existing = existingPublished[output.id]
                    group.addTask {
                        let versionText = "V\(output.version) · \(output.displayFileName)"
                        let artifact: PublishedArtifact
                        if let existing {
                            artifact = existing
                        } else {
                            guard let uploaded = await appState.uploadCommentAttachment(
                                for: task,
                                fileURL: file,
                                onProgress: { [weak self] fraction in
                                    // Live byte-level progress: already-posted
                                    // outputs + this file's upload fraction, so
                                    // the ring moves in real time instead of
                                    // sitting at 0% until the whole file lands.
                                    Task { @MainActor in
                                        guard let self, var s = self.batches[task.id] else { return }
                                        let done = Double(s.completed)
                                        s.progress = min((done + fraction) / Double(max(1, s.total)), 0.999)
                                        self.batches[task.id] = s
                                    }
                                }
                            ) else {
                                return .failure(output.id, "Falha ao enviar \(output.displayFileName)")
                            }
                            artifact = PublishedArtifact(attachmentId: uploaded.id,
                                                         remoteURL: uploaded.url,
                                                         commentId: nil,
                                                         commentPosted: false)
                        }
                        guard let comment = await appState.publishMediaTransferComment(
                            on: task,
                            text: versionText,
                            mentionMemberIds: mentionMemberIds,
                            attachmentId: artifact.attachmentId,
                            attachmentURL: artifact.remoteURL,
                            fileName: output.displayFileName,
                            fileExtension: file.pathExtension.lowercased()
                        ) else {
                            return .uploadedOnly(output.id, artifact)
                        }
                        var complete = artifact
                        complete.commentId = comment.id
                        complete.commentPosted = true
                        return .success(output.id, complete)
                    }
                }
                var values: [PublishResult] = []
                for await value in group { values.append(value) }
                return values
            }
            guard var state = batches[task.id] else { return }
            for result in results {
                switch result {
                case .success(let id, let artifact):
                    state.published[id] = artifact
                case .uploadedOnly(let id, let artifact):
                    state.published[id] = artifact
                    state.errorMessage = "O arquivo foi anexado, mas o comentário final não foi confirmado. Tente novamente."
                case .failure(_, let message):
                    state.errorMessage = message
                }
            }
            state.completed = state.published.values.filter(\.commentPosted).count
            state.progress = Double(state.completed) / Double(max(1, state.total))
            batches[task.id] = state
        }
    }

    private func uploadManifest(_ catalog: TaskMediaCatalog, task: CUTask,
                                appState: AppState) async throws {
        var remote = catalog
        for assetIndex in remote.assets.indices {
            for revisionIndex in remote.assets[assetIndex].revisions.indices {
                remote.assets[assetIndex].revisions[revisionIndex].localURL = nil
            }
        }
        let data = try JSONEncoder.pretty.encode(remote)
        let directory = try supportDirectory().appendingPathComponent("Manifests", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(TaskMediaTechnicalName.manifest(sequence: catalog.sequence))
        try data.write(to: url, options: .atomic)
        guard await appState.uploadCommentAttachment(for: task, fileURL: url,
                                                     userFacing: false) != nil else {
            throw TransferError.manifestFailed
        }
        try? fileManager.removeItem(at: url)
    }

    private func loadRemoteCatalog(from attachments: [CUTask.Attachment]) async -> TaskMediaCatalog? {
        guard let latest = attachments
            .filter({ $0.title.hasPrefix(TaskMediaTechnicalName.manifestPrefix) })
            .max(by: { $0.title < $1.title }),
              let url = URL(string: latest.url) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard Self.isSuccessful(response) else {
                throw TransferError.invalidRemoteResponse
            }
            return try JSONDecoder().decode(TaskMediaCatalog.self, from: data)
        } catch {
            Log.error("TaskMedia catalog remoto: \(error)")
            return nil
        }
    }

    private func localURL(for assetId: UUID, catalog: TaskMediaCatalog) async throws -> URL {
        guard let revision = catalog.asset(id: assetId)?.activeRevision else {
            throw TaskMediaPlannerError.assetNotFound
        }
        if let local = revision.localURL, fileManager.isReadableFile(atPath: local.path) { return local }
        guard let remote = revision.remoteURL else { throw TransferError.sourceUnavailable }
        let directory = try supportDirectory().appendingPathComponent("SourceCache", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = (revision.originalFileName as NSString).pathExtension
        let destination = directory.appendingPathComponent("\(revision.contentHash).\(ext.isEmpty ? "mov" : ext)")
        if fileManager.fileExists(atPath: destination.path) { return destination }
        let (temporary, response) = try await URLSession.shared.download(from: remote)
        guard Self.isSuccessful(response) else {
            try? fileManager.removeItem(at: temporary)
            throw TransferError.invalidRemoteResponse
        }
        try fileManager.moveItem(at: temporary, to: destination)
        return destination
    }

    private func hash(_ selections: [TaskMediaSelection]) async throws -> [TaskMediaSelection] {
        try await Task.detached(priority: .userInitiated) {
            try selections.map { selection in
                var copy = selection
                copy.contentHash = try Self.sha256(fileURL: selection.fileURL)
                return copy
            }
        }.value
    }

    nonisolated private static func sha256(fileURL: URL) throws -> String {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            throw TransferError.sourceUnavailable
        }
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func stagedCopy(of source: URL, named name: String,
                            taskId: String, batchId: UUID) async throws -> URL {
        let directory = try batchDirectory(taskId: taskId, batchId: batchId)
        let target = directory.appendingPathComponent(name)
        try await copyFile(from: source, to: target)
        return target
    }

    private func copyFile(from source: URL, to target: URL) async throws {
        try await Task.detached(priority: .utility) {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
        }.value
    }

    private func uniqueURL(in directory: URL, fileName: String) -> URL {
        let base = directory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: base.path) else { return base }
        let ext = base.pathExtension
        let stem = base.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(6)).\(ext)")
    }

    private func batchDirectory(taskId: String, batchId: UUID) throws -> URL {
        let directory = try supportDirectory()
            .appendingPathComponent("TaskMediaBatches", isDirectory: true)
            .appendingPathComponent(taskId.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
            .appendingPathComponent(batchId.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func supportDirectory() throws -> URL {
        let root = try fileManager.url(for: .applicationSupportDirectory,
                                       in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = root.appendingPathComponent("Apollo", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated private static func cleanupOrphanedWorkingDirectories() {
        let manager = FileManager.default
        guard let root = try? manager.url(for: .applicationSupportDirectory,
                                          in: .userDomainMask,
                                          appropriateFor: nil,
                                          create: true) else { return }
        let apollo = root.appendingPathComponent("Apollo", isDirectory: true)
        for name in ["TaskMediaBatches", "Manifests"] {
            try? manager.removeItem(at: apollo.appendingPathComponent(name, isDirectory: true))
        }
    }

    nonisolated static func isSuccessful(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return true }
        return (200..<300).contains(http.statusCode)
    }

    private func catalogURL(taskId: String) throws -> URL {
        let directory = try supportDirectory().appendingPathComponent("TaskMediaCatalogs", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = taskId.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safe).json")
    }

    private func loadLocalCatalog(taskId: String) -> TaskMediaCatalog? {
        guard let url = try? catalogURL(taskId: taskId),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TaskMediaCatalog.self, from: data)
    }

    private func persistLocal(_ catalog: TaskMediaCatalog) {
        guard let url = try? catalogURL(taskId: catalog.taskId),
              let data = try? JSONEncoder.pretty.encode(catalog) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func recordPreparationFailure(taskId: String, message: String) {
        let emptyPlan = TaskMediaPlan(catalog: catalog(for: taskId), newAssetIds: [],
                                      pendingRevisionAssetIds: [], outputs: [])
        batches[taskId] = BatchState(id: UUID(), taskId: taskId, phase: .failed,
                                     plan: emptyPlan, preparedFiles: [:], published: [:],
                                     completed: 0, total: 0, progress: 0,
                                     errorMessage: message)
    }

    private func cleanupPreparedFiles(_ batch: BatchState) {
        let directories = Set(batch.preparedFiles.values.map { $0.deletingLastPathComponent() })
        for directory in directories { try? fileManager.removeItem(at: directory) }
    }

    private enum PublishResult: Sendable {
        case success(UUID, PublishedArtifact)
        case uploadedOnly(UUID, PublishedArtifact)
        case failure(UUID, String)
    }

    private enum TransferError: LocalizedError {
        case uploadFailed(String)
        case manifestFailed
        case sourceUnavailable
        case invalidRemoteResponse
        case invalidFileName
        case duplicateOutputName(String)
        case wrongReplacementCount(expected: Int)

        var errorDescription: String? {
            switch self {
            case .uploadFailed(let name): return "Falha ao enviar \(name)."
            case .manifestFailed: return "Os vídeos foram enviados, mas o catálogo não foi sincronizado."
            case .sourceUnavailable: return "Uma fonte não está mais disponível."
            case .invalidRemoteResponse: return "O ClickUp não retornou um arquivo válido. Tente novamente."
            case .invalidFileName: return "Escolha um nome válido para cada vídeo."
            case .duplicateOutputName(let name): return "O nome \(name) está repetido."
            case .wrongReplacementCount(let expected):
                return "Escolha exatamente \(expected) vídeo\(expected == 1 ? "" : "s") para substituir os pendentes."
            }
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
