import AppKit
import Combine
import Foundation

/// One shared, serial review probe for the visible task rows.
///
/// The native task list recycles AppKit cells aggressively. Polling from each
/// cell would duplicate requests, retain stale tasks and hurt scroll FPS. Rows
/// only register the task they currently represent; this store deduplicates the
/// work, probes at most one task at a time and publishes a task-level result.
@MainActor
final class TaskReviewUpdateStore: ObservableObject {
    static let shared = TaskReviewUpdateStore()

    typealias FullTaskFetcher = (String) async -> CUTask?
    typealias CatalogFetcher = (String) -> TaskMediaCatalog?

    struct Update {
        let taskId: String
        let attachment: CUTask.Attachment
        let activeAtt: String
        let meta: ReviewBackend.Meta

        /// Prefer the current server title only when it carries real identity.
        /// Older/legacy review blobs were created with generic placeholders such
        /// as `Arquivo`; showing that value made a pending V4 look as if it had
        /// disappeared even though its durable latch was still present.
        var displayTitle: String {
            let remote = meta.mediaTitle?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !Self.placeholderTitles.contains(remote.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "pt_BR")
            )) {
                return remote
            }

            let local = attachment.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return local.isEmpty ? "Arquivo" : local
        }

        private static let placeholderTitles: Set<String> = [
            "", "arquivo", "file", "video"
        ]
    }

    /// Durable representation of an actionable review update. The server
    /// observation baseline advances while Apollo polls, so the row cannot
    /// reconstruct this latch from `reviewSeen`/`reviewObserved` after a
    /// relaunch. Persisting the latch separately guarantees that opening or
    /// closing Apollo never consumes VER REVIEW.
    private struct PersistedUpdate: Codable {
        let taskId: String
        let attachment: CUTask.Attachment
        let activeAtt: String
        let updatedAt: String?
        let status: String?
        let commentCount: Int
        let concludedAt: String?
        let reviewId: String?
        let currentVersionId: String?
        let mediaTitle: String?
        let evaluatedVersionId: String?
        /// Added after a regression where the background watcher persisted
        /// every session it polled, including a brand-new empty review. A
        /// missing value identifies records written by that unsafe build.
        let activityVerified: Bool?

        init(_ update: Update) {
            taskId = update.taskId
            attachment = update.attachment
            activeAtt = update.activeAtt
            updatedAt = update.meta.updatedAt
            status = update.meta.status
            commentCount = update.meta.commentCount
            concludedAt = update.meta.concludedAt
            reviewId = update.meta.reviewId
            currentVersionId = update.meta.currentVersionId
            mediaTitle = update.meta.mediaTitle
            evaluatedVersionId = update.meta.evaluatedVersionId
            activityVerified = true
        }

        /// Records are trusted only when their payload itself proves that a
        /// reviewer acted. `activityVerified` records from the affected builds
        /// are intentionally not exempt: those builds could verify a technical
        /// session/version timestamp as if it were human activity.
        var isTrustedPendingActivity: Bool {
            if commentCount > 0 { return true }
            if !(concludedAt?.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ?? true) { return true }
            let normalizedStatus = status?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return normalizedStatus != nil
                && normalizedStatus != ""
                && normalizedStatus != "in_review"
        }

        var update: Update {
            Update(
                taskId: taskId,
                attachment: attachment,
                activeAtt: activeAtt,
                meta: ReviewBackend.Meta(
                    exists: true,
                    updatedAt: updatedAt,
                    status: status,
                    commentCount: commentCount,
                    concludedAt: concludedAt,
                    reviewId: reviewId,
                    currentVersionId: currentVersionId,
                    mediaTitle: mediaTitle,
                    evaluatedVersionId: evaluatedVersionId
                )
            )
        }
    }

    enum CapsuleState {
        case update(Update)
        case reviewed
    }

    /// Pending reviews are keyed twice: task first, then the stable review
    /// session id. A task can legitimately contain several videos being
    /// reviewed at the same time; collapsing them into one task-level value
    /// made the newest video overwrite its siblings and made completion of
    /// one review consume (or resurrect) another.
    @Published private(set) var updatesByTask: [String: [String: Update]] = [:]
    @Published private(set) var reviewedTaskIds: Set<String> = []

    private struct WatchedTask {
        var task: CUTask
        var lastProbeAt: Date?
    }

    private var watched: [String: WatchedTask] = [:]
    private var queued: [String] = []
    private var queuedIds: Set<String> = []
    private var pumpTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var reviewedExpiryTasks: [String: Task<Void, Never>] = [:]

    /// The list endpoint deliberately omits attachments. Keep the full task
    /// payload outside recycled rows so review discovery can inspect the real
    /// media catalog without issuing one request on every bind/scroll tick.
    private struct HydratedTask {
        let attachments: [CUTask.Attachment]
        let sourceDateUpdated: Date?
    }
    private var hydratedTasks: [String: HydratedTask] = [:]
    private let fullTaskFetcher: FullTaskFetcher
    private let catalogFetcher: CatalogFetcher

    // A 30-second scan over every visible task exhausted the Worker's daily KV
    // allowance and made the reviewer unable to save. That ceiling died with
    // the D1 migration: 45s keeps "revisor concluiu na web → VER REVIEW some"
    // dentro de ~1 min sem chegar perto dos limites do D1 (linhas visíveis ×
    // ~2 leituras/min ≪ 5M/dia), e o cache do Worker absorve rajadas.
    private let refreshInterval: TimeInterval = 45
    private let reviewedDisplayDuration: TimeInterval
    private let defaults: UserDefaults
    private let pendingUpdatesKey = "taskReviewPendingUpdates.v1"

    init(reviewedDisplayDuration: TimeInterval = 2,
         defaults: UserDefaults = .standard,
         fullTaskFetcher: FullTaskFetcher? = nil,
         catalogFetcher: CatalogFetcher? = nil) {
        self.reviewedDisplayDuration = reviewedDisplayDuration
        self.defaults = defaults
        self.catalogFetcher = catalogFetcher
            ?? { TaskMediaTransferStore.persistedCatalog(for: $0) }
        if let fullTaskFetcher {
            self.fullTaskFetcher = fullTaskFetcher
        } else {
            // ClickUpAuthService reads the same configured credential store as
            // AppState. This does not start OAuth or synchronization; it only
            // enables the bounded single-task GET used for attachment hydration.
            let service = ClickUpService(auth: ClickUpAuthService())
            self.fullTaskFetcher = { taskId in
                try? await service.getTask(id: taskId)
            }
        }
        // O gesto clássico é concluir a review no navegador e voltar pro
        // Apollo: sondar as linhas visíveis na hora em que o app reativa
        // faz o VER REVIEW sumir imediatamente, sem esperar o próximo tick.
        // (Registrado por último — o closure captura self e o Swift exige
        // todas as stored properties inicializadas antes.)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.probeVisibleNow() }
        }
        if let data = defaults.data(forKey: pendingUpdatesKey) {
            if let records = try? JSONDecoder().decode([PersistedUpdate].self,
                                                       from: data) {
                let trusted = records.filter(\.isTrustedPendingActivity)
                Log.info("Review restore: \(records.count) registros, \(trusted.count) confiáveis")
                restorePersistedUpdates(trusted.map(\.update))
            } else {
                // A decode failure must NEVER silently wipe every pendency on
                // the next persist. Keep the raw data untouched and loud.
                Log.error("Review restore: decode dos latches persistidos FALHOU — \(data.count) bytes preservados")
            }
        }
    }

    func updates(for taskId: String) -> [Update] {
        let deduplicated = Dictionary(
            updatesByTask[taskId, default: [:]].values.map {
                (Self.logicalReviewId($0), $0)
            },
            uniquingKeysWith: { current, candidate in
                Self.isNewer(candidate, than: current) ? candidate : current
            }
        ).values
        return deduplicated.sorted {
            ($0.meta.updatedAt ?? "") > ($1.meta.updatedAt ?? "")
        }
    }

    /// Compatibility for the single-review path. Callers that need to decide
    /// between direct opening and the chooser must use `updates(for:)`.
    func update(for taskId: String) -> Update? { updates(for: taskId).first }

    func capsuleState(for taskId: String) -> CapsuleState? {
        if reviewedTaskIds.contains(taskId) { return .reviewed }
        return update(for: taskId).map(CapsuleState.update)
    }

    /// Refreshes the durable row latch after an inline approval change. This
    /// deliberately does not acknowledge or remove the review: approval and
    /// explicit conclusion are independent actions.
    @discardableResult
    func refreshPendingMetadata(taskId: String, activeAtt: String,
                                meta: ReviewBackend.Meta) -> Bool {
        guard let bucket = updatesByTask[taskId] else { return false }
        let reviewId = Self.nonBlank(meta.reviewId) ?? activeAtt
        let versionId = Self.authoritativeVersion(meta)
        guard let oldKey = bucket.first(where: { _, candidate in
            Self.logicalReviewId(candidate) == reviewId
                && Self.authoritativeVersion(candidate.meta) == versionId
        })?.key,
              let pending = bucket[oldKey]
        else { return false }
        let refreshed = Update(
            taskId: pending.taskId,
            attachment: pending.attachment,
            activeAtt: pending.activeAtt,
            meta: meta
        )
        let newKey = Self.pendingKey(for: refreshed)
        if oldKey != newKey { updatesByTask[taskId]?.removeValue(forKey: oldKey) }
        updatesByTask[taskId]?[newKey] = refreshed
        persistPendingUpdates()
        return true
    }

    /// Reconciles one exact media version after `/session/resolve` succeeded.
    /// This is the only safe way to remove a phantom latch: nil/transport
    /// failures never call this method, and activity from another version can
    /// neither create nor preserve the selected version's capsule.
    func reconcileOpenedVersion(taskId: String, activeAtt: String,
                                attachment: CUTask.Attachment,
                                meta: ReviewBackend.Meta) {
        guard let exactVersion = Self.authoritativeVersion(meta),
              let bucket = updatesByTask[taskId] else { return }

        let reviewId = Self.nonBlank(meta.reviewId) ?? activeAtt
        let matchingKeys = bucket.compactMap { key, pending -> String? in
            let pendingReviewId = Self.logicalReviewId(pending)
            let pendingVersion = Self.authoritativeVersion(pending.meta)
            let sameReview = key == activeAtt
                || pending.activeAtt == activeAtt
                || pendingReviewId == reviewId
            // A nil version is a contaminated pre-migration latch. An exact
            // read is authoritative and may safely repair/remove it.
            return sameReview
                && (pendingVersion == exactVersion || pendingVersion == nil)
                ? key : nil
        }

        if meta.isApprovedAndConcluded {
            let completed = Update(
                taskId: taskId, attachment: attachment,
                activeAtt: activeAtt, meta: meta
            )
            if !matchingKeys.isEmpty { _ = acknowledgeCompleted(completed) }
            return
        }

        if !meta.hasReviewerActivityEvidence {
            for key in matchingKeys {
                updatesByTask[taskId]?.removeValue(forKey: key)
            }
            if updatesByTask[taskId]?.isEmpty == true {
                updatesByTask.removeValue(forKey: taskId)
            }
            ReviewBackend.markObserved(
                att: ReviewBackend.observationKey(att: activeAtt,
                                                  versionId: exactVersion),
                meta: meta
            )
            persistPendingUpdates()
            return
        }

        let exact = canonicalized(Update(
            taskId: taskId, attachment: attachment,
            activeAtt: activeAtt, meta: meta
        ))
        let exactKey = Self.pendingKey(for: exact)
        for key in matchingKeys where key != exactKey {
            updatesByTask[taskId]?.removeValue(forKey: key)
        }
        updatesByTask[taskId, default: [:]][exactKey] = exact
        persistPendingUpdates()
    }

    /// Background review polling is independent from the task-list page. Feed
    /// discoveries into the same durable row latch so VER REVIEW appears even
    /// when Apollo was on Inbox/Quadro when the web activity happened.
    func recordDiscoveredUpdate(taskId: String, activeAtt: String,
                                mediaUrl: String, ext: String, title: String,
                                uploaderId: Int?, meta: ReviewBackend.Meta,
                                hasUnseenUpdate: Bool,
                                versionId: String? = nil) {
        if let identity = catalogFetcher(taskId)?.reviewIdentity(
            attachmentId: activeAtt,
            mediaURL: mediaUrl
        ), identity.reviewId != activeAtt {
            let requestedVersion = Self.normalizedVersion(versionId)
                ?? Self.authoritativeVersion(meta)
                ?? identity.versionId
            let selectedOutput = output(
                in: catalogFetcher(taskId),
                lineageId: identity.output.lineageId,
                versionId: requestedVersion
            ) ?? identity.output
            let selected = attachment(for: selectedOutput,
                                    fallbackTitle: title,
                                    fallbackURL: mediaUrl,
                                    fallbackExt: ext,
                                    uploaderId: uploaderId,
                                    commentCount: meta.commentCount)
            ReviewWatcher.shared.remap(
                from: activeAtt,
                to: identity.reviewId,
                mediaUrl: selected.url,
                ext: selected.ext,
                taskId: taskId,
                title: selected.title,
                uploaderId: selected.uploaderId,
                tintHex: nil,
                versionId: requestedVersion
            )
            // Never publish metadata read from the physical replacement id.
            // That id may host an old accidental duplicate session. Resolve
            // the canonical lineage and use only its authoritative document.
            Task { [weak self] in
                guard let canonicalMeta = await ReviewBackend.meta(
                    att: identity.reviewId,
                    versionId: requestedVersion
                )
                else { return }
                let observationKey = ReviewBackend.observationKey(
                    att: identity.reviewId,
                    versionId: requestedVersion
                )
                let canonicalUnseen = ReviewBackend.observe(
                    meta: canonicalMeta,
                    att: observationKey
                )
                await MainActor.run {
                    self?.recordDiscoveredUpdate(
                        taskId: taskId,
                        activeAtt: identity.reviewId,
                        mediaUrl: selected.url,
                        ext: selected.ext,
                        title: selected.title,
                        uploaderId: selected.uploaderId,
                        meta: canonicalMeta,
                        hasUnseenUpdate: canonicalUnseen,
                        versionId: requestedVersion
                    )
                }
            }
            return
        }
        let attachment = CUTask.Attachment(
            id: activeAtt, title: title, url: mediaUrl, ext: ext,
            sizeString: nil, totalComments: meta.commentCount,
            resolvedComments: nil, uploaderId: uploaderId
        )
        let requestedVersion = Self.normalizedVersion(versionId)
        let evaluatedVersion = Self.authoritativeVersion(meta)
        if let requestedVersion, evaluatedVersion != requestedVersion { return }
        if requiresExactVersion(taskId: taskId,
                                activeAtt: activeAtt,
                                mediaURL: mediaUrl),
           evaluatedVersion == nil {
            return
        }
        if !meta.hasReviewerActivityEvidence {
            removeNonActionableUpdate(
                taskId: taskId,
                activeAtt: activeAtt,
                mediaUrl: mediaUrl,
                reviewId: meta.reviewId,
                versionId: evaluatedVersion
            )
            return
        }
        if meta.isApprovedAndConcluded {
            // A remote reviewer explicitly concluded an approved review. Only
            // consume an already-actionable logical review. The same review
            // can be known by the canonical ClickUp attachment id or by the
            // historical URL hash; leaving either alias persisted made an
            // approved review reappear on the following poll/relaunch.
            // Superseded older-version latches count as consumable too — the
            // newest version's completion closes the whole lineage cycle.
            guard !consumableReviewKeys(
                taskId: taskId,
                activeAtt: activeAtt,
                mediaUrl: mediaUrl,
                reviewId: meta.reviewId,
                versionId: evaluatedVersion
            ).isEmpty else { return }
            acknowledgeCompleted(
                Update(taskId: taskId, attachment: attachment,
                       activeAtt: activeAtt, meta: meta)
            )
            return
        }
        // The watcher polls every registered link, including sessions created
        // by the upload/open flow. Only a positive activity decision may
        // create the durable VER REVIEW latch. Keeping this guard inside the
        // store prevents any caller from accidentally reintroducing the false
        // positive by publishing raw metadata directly.
        guard hasUnseenUpdate else { return }
        applyProbeResult(
            Update(taskId: taskId, attachment: attachment,
                   activeAtt: activeAtt, meta: meta),
            taskId: taskId,
            visibleAttachmentIds: [activeAtt]
        )
    }

    /// Called by a row whenever it binds/rebinds. The operation is synchronous
    /// and cheap; network work is queued once per task and processed serially.
    func watch(task: CUTask) {
        let now = Date()
        let prior = watched[task.id]
        watched[task.id] = WatchedTask(task: task, lastProbeAt: prior?.lastProbeAt)
        if let lastProbeAt = prior?.lastProbeAt {
            if now.timeIntervalSince(lastProbeAt) >= refreshInterval {
                enqueue(task.id)
            }
        } else {
            enqueue(task.id)
        }
        startTimerIfNeeded()
    }

    func unwatch(taskId: String) {
        watched.removeValue(forKey: taskId)
        if queuedIds.remove(taskId) != nil {
            queued.removeAll { $0 == taskId }
        }
    }

    /// The only public acknowledgement path. The caller must provide fresh
    /// server metadata proving both independent conditions: toggle approved
    /// AND explicit conclusion. Keeping the guard in the store means a stale
    /// UI snapshot can never consume `VER REVIEW` by mistake.
    @discardableResult
    func acknowledgeConfirmedCompletion(taskId: String,
                                        pendingActiveAtt: String,
                                        confirmedActiveAtt: String,
                                        meta: ReviewBackend.Meta) -> Bool {
        guard meta.isApprovedAndConcluded else { return false }
        // The pending latch is located by logical review identity, never by a
        // direct key lookup: the latch may be stored under `reviewId#versionId`
        // while the caller still holds the physical attachment id it opened.
        let reviewId = Self.nonBlank(meta.reviewId) ?? pendingActiveAtt
        let confirmedVersion = Self.authoritativeVersion(meta)
        let pending = updatesByTask[taskId]?.values.first { candidate in
            let sameReview = Self.logicalReviewId(candidate) == reviewId
                || candidate.activeAtt == pendingActiveAtt
            guard sameReview else { return false }
            // `currentVersionId` is deliberately not a fallback here: only the
            // server-evaluated version may consume a version-exact latch.
            let pendingVersion = Self.authoritativeVersion(candidate.meta)
            return pendingVersion == nil || pendingVersion == confirmedVersion
        }
        guard let pending else { return false }
        return acknowledgeCompleted(
            Update(taskId: taskId,
                   attachment: pending.attachment,
                   activeAtt: confirmedActiveAtt,
                   meta: meta)
        )
    }

    private static func normalizedVersion(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !value.isEmpty else { return nil }
        return value
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    /// Stable identity of the logical review a latch belongs to.
    private static func logicalReviewId(_ update: Update) -> String {
        nonBlank(update.meta.reviewId) ?? update.activeAtt
    }

    /// The only version the server actually evaluated. `currentVersionId`
    /// (which media is projected) must never leak in here — that fabrication
    /// is exactly what turned "V2 is current" into "V2 has review activity".
    private static func authoritativeVersion(
        _ meta: ReviewBackend.Meta
    ) -> String? {
        normalizedVersion(meta.evaluatedVersionId)
    }

    private static func pendingKey(reviewId: String,
                                   versionId: String?) -> String {
        guard let versionId = normalizedVersion(versionId) else { return reviewId }
        return "\(reviewId)#\(versionId)"
    }

    private static func pendingKey(for update: Update) -> String {
        pendingKey(reviewId: logicalReviewId(update),
                   versionId: authoritativeVersion(update.meta))
    }

    /// Exact catalog output for `lineageId` + normalized version ("v3" → 3).
    private func output(in catalog: TaskMediaCatalog?, lineageId: String,
                        versionId: String?) -> TaskMediaOutputVersion? {
        guard let catalog,
              let number = Self.versionNumber(Self.normalizedVersion(versionId))
        else { return nil }
        return catalog.outputs.first {
            $0.lineageId == lineageId && $0.version == number
        }
    }

    /// True when the catalog proves this attachment belongs to a lineage with
    /// more than one version. In that case a record without an authoritative
    /// `evaluatedVersionId` is ambiguous (it may carry V1 activity under a V2
    /// title) and must never become a pending latch.
    private func requiresExactVersion(taskId: String, activeAtt: String,
                                      mediaURL: String) -> Bool {
        guard let catalog = catalogFetcher(taskId),
              let identity = catalog.reviewIdentity(attachmentId: activeAtt,
                                                    mediaURL: mediaURL)
        else { return false }
        return catalog.outputs.lazy.filter {
            $0.lineageId == identity.output.lineageId
        }.count > 1
    }

    /// An authoritative empty read removes only the exact version's latch plus
    /// contaminated version-less aliases of the same review. Transport failures
    /// never reach this method, so a network error can delete nothing.
    private func removeNonActionableUpdate(taskId: String, activeAtt: String,
                                           mediaUrl: String, reviewId: String?,
                                           versionId: String?) {
        let keys = equivalentReviewKeys(taskId: taskId, activeAtt: activeAtt,
                                        mediaUrl: mediaUrl, reviewId: reviewId,
                                        versionId: versionId)
        guard !keys.isEmpty else { return }
        for key in keys { updatesByTask[taskId]?.removeValue(forKey: key) }
        if updatesByTask[taskId]?.isEmpty == true {
            updatesByTask.removeValue(forKey: taskId)
        }
        persistPendingUpdates()
    }

    @discardableResult
    func acknowledgeCompleted(_ update: Update) -> Bool {
        guard update.meta.isApprovedAndConcluded else { return false }
        let confirmedVersion = Self.authoritativeVersion(update.meta)
        let consumableKeys = consumableReviewKeys(
            taskId: update.taskId,
            activeAtt: update.activeAtt,
            mediaUrl: update.attachment.url,
            reviewId: update.meta.reviewId,
            versionId: confirmedVersion
        )
        // Advance the baseline for every known alias. `openSession` may
        // dual-write canonical + legacy sessions, so marking only the key used
        // by this particular opener lets the mirror look unseen next time.
        // The version-scoped observation key is included so the exact
        // `reviewId#versionId` baseline also stops re-alerting.
        var seenKeys = Set(consumableKeys + [
            update.activeAtt,
            ReviewBackend.att(forMediaUrl: update.attachment.url)
        ])
        if confirmedVersion != nil {
            seenKeys.formUnion(seenKeys.map {
                ReviewBackend.observationKey(att: $0,
                                             versionId: confirmedVersion)
            })
        }
        // Superseded older versions keep their own `att#version` baselines;
        // mark them too so their history can never re-alert after consumption.
        for key in consumableKeys {
            if let candidate = updatesByTask[update.taskId]?[key],
               let candidateVersion = Self.authoritativeVersion(candidate.meta) {
                seenKeys.insert(ReviewBackend.observationKey(
                    att: candidate.activeAtt, versionId: candidateVersion
                ))
            }
        }
        for key in seenKeys {
            ReviewBackend.markSeen(att: key,
                                   updatedAt: update.meta.updatedAt,
                                   commentCount: update.meta.commentCount,
                                   status: update.meta.status)
        }
        for key in consumableKeys {
            updatesByTask[update.taskId]?.removeValue(forKey: key)
        }
        if updatesByTask[update.taskId]?.isEmpty == true {
            updatesByTask.removeValue(forKey: update.taskId)
        }
        persistPendingUpdates()
        // If sibling videos still need review, keep the task-level VER REVIEW
        // capsule alive and do not cover it with the transient success state.
        guard updatesByTask[update.taskId]?.isEmpty != false else { return true }
        reviewedExpiryTasks[update.taskId]?.cancel()
        reviewedTaskIds.insert(update.taskId)

        let duration = max(0, reviewedDisplayDuration)
        reviewedExpiryTasks[update.taskId] = Task { [weak self] in
            if duration > 0 {
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            self.reviewedTaskIds.remove(update.taskId)
            self.reviewedExpiryTasks.removeValue(forKey: update.taskId)
            if var item = self.watched[update.taskId] {
                // The final save refreshes the seen baseline asynchronously.
                // Let the ordinary polling interval elapse before probing so
                // Apollo never races that write and re-lights its own update.
                item.lastProbeAt = Date()
                self.watched[update.taskId] = item
            }
        }
        return true
    }

    private func enqueue(_ taskId: String) {
        guard watched[taskId] != nil, !queuedIds.contains(taskId) else { return }
        queued.append(taskId)
        queuedIds.insert(taskId)
        guard pumpTask == nil else { return }
        pumpTask = Task { [weak self] in await self?.pump() }
    }

    private func pump() async {
        defer { pumpTask = nil }
        while !Task.isCancelled, !queued.isEmpty {
            let taskId = queued.removeFirst()
            queuedIds.remove(taskId)
            guard var item = watched[taskId] else { continue }

            let probeTask = await taskForProbe(item.task)
            let updates = await findUpdates(in: probeTask)
            // A recycled row may have stopped watching while the request was
            // in flight. Never publish its stale answer into the new row.
            guard watched[taskId] != nil else { continue }
            item.lastProbeAt = Date()
            watched[taskId] = item
            // Completion owns the row capsule for its full two-second beat.
            // An in-flight probe that started before acknowledgement must not
            // overwrite that deterministic success state.
            guard !reviewedTaskIds.contains(taskId) else { continue }
            let visibleIds = Set(probeTask.visibleAttachments.map(\.id))
            if updates.isEmpty {
                applyProbeResult(nil, taskId: taskId,
                                 visibleAttachmentIds: visibleIds)
            } else {
                // Preserve every independent video review in this task. The
                // old newest-only return value silently collapsed N reviews
                // into one and made the multi-review chooser incomplete.
                for update in updates {
                    applyProbeResult(update, taskId: taskId,
                                     visibleAttachmentIds: visibleIds)
                }
            }
        }
    }

    /// Resolves the compact list payload into a task containing attachments.
    /// A cached payload remains valid until ClickUp reports a newer
    /// `date_updated`; web-review comments do not mutate the attachment list,
    /// so the 30-second metadata probe remains cheap after this one fetch.
    func taskForProbe(_ task: CUTask) async -> CUTask {
        if !task.attachments.isEmpty {
            hydratedTasks[task.id] = HydratedTask(
                attachments: task.attachments,
                sourceDateUpdated: task.dateUpdated
            )
            return task
        }

        if let cached = hydratedTasks[task.id] {
            let cacheIsCurrent: Bool
            if let taskUpdated = task.dateUpdated,
               let cachedUpdated = cached.sourceDateUpdated {
                cacheIsCurrent = taskUpdated <= cachedUpdated
            } else {
                cacheIsCurrent = true
            }
            if cacheIsCurrent {
                var resolved = task
                resolved.attachments = cached.attachments
                return resolved
            }
        }

        guard let fullTask = await fullTaskFetcher(task.id) else { return task }
        let hydrated = HydratedTask(
            attachments: fullTask.attachments,
            sourceDateUpdated: fullTask.dateUpdated ?? task.dateUpdated
        )
        hydratedTasks[task.id] = hydrated
        var resolved = task
        resolved.attachments = hydrated.attachments
        return resolved
    }

    /// Publishes a newly discovered review without letting a later nil probe
    /// consume an already-visible action. Kept internal so the latch invariant
    /// can be regression-tested without performing network requests.
    func applyProbeResult(_ update: Update?, taskId: String,
                          visibleAttachmentIds _: Set<String>) {
        if let rawUpdate = update {
            // A pending latch may only exist for real reviewer activity. A
            // pristine `in_review` session (created by upload/open flows) must
            // be refused at the door, not filtered later.
            guard rawUpdate.meta.hasReviewerActivityEvidence else { return }
            // Every input path (visible-row probe, background watcher and
            // persisted migration) must converge on the catalog's stable
            // review id. Otherwise a physical V4 attachment can become a
            // second pending review beside the V1/V2/V3 lineage it belongs to.
            let update = canonicalized(rawUpdate)
            let physicalAlias = rawUpdate.activeAtt != update.activeAtt
            // Once the stable lineage is present, a stale physical V2/V3/V4
            // session is never authoritative. Its root may contain copied V1
            // comments and previously overwrote the correct canonical state.
            if physicalAlias,
               updatesByTask[taskId]?.values.contains(where: {
                   Self.logicalReviewId($0) == Self.logicalReviewId(update)
               }) == true {
                return
            }
            if update.meta.isApprovedAndConcluded {
                let pendingAliases = consumableReviewKeys(
                    taskId: taskId,
                    activeAtt: update.activeAtt,
                    mediaUrl: update.attachment.url,
                    reviewId: update.meta.reviewId,
                    versionId: Self.authoritativeVersion(update.meta)
                )
                if !pendingAliases.isEmpty {
                    acknowledgeCompleted(update)
                }
                return
            }
            let key = Self.pendingKey(for: update)
            let existing = updatesByTask[taskId]?[key]
            // A physical replacement may have been latched before the media
            // catalog finished loading. Once its stable lineage is known,
            // remove those aliases before inserting the canonical row.
            for alias in equivalentReviewKeys(
                taskId: taskId,
                activeAtt: update.activeAtt,
                mediaUrl: update.attachment.url,
                reviewId: update.meta.reviewId,
                versionId: Self.authoritativeVersion(update.meta)
            ) where alias != key {
                updatesByTask[taskId]?.removeValue(forKey: alias)
            }
            if existing == nil || Self.isNewer(update, than: existing!) {
                updatesByTask[taskId, default: [:]][key] = update
            }
            persistPendingUpdates()
        } else if updatesByTask[taskId]?.isEmpty == false {
            // Once an unseen review has been published into the row, it is
            // deliberately latched until the explicit
            // `Concluir review -> Fechar` acknowledgement. A later probe can
            // legitimately return nil while the review sheet is being opened
            // or reconciled (or during a transient metadata failure); treating
            // that as acknowledgement made VER REVIEW disappear after a plain
            // open/close or relaunch. Opening is never consumption. The
            // persisted attachment snapshot remains sufficient to reopen the
            // exact review even if a temporary task refresh omits attachments.
        }
    }

    private func persistPendingUpdates() {
        let records = updatesByTask.values.flatMap(\.values)
            .map(PersistedUpdate.init)
            .sorted {
                if $0.taskId == $1.taskId { return $0.activeAtt < $1.activeAtt }
                return $0.taskId < $1.taskId
            }
        if records.isEmpty {
            defaults.removeObject(forKey: pendingUpdatesKey)
        } else if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: pendingUpdatesKey)
        }
    }

    private func startTimerIfNeeded() {
        guard timerTask == nil else { return }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self else { return }
                self.enqueueVisibleTasks()
            }
        }
    }

    private func enqueueVisibleTasks() {
        let now = Date()
        for (taskId, item) in watched {
            if item.lastProbeAt == nil
                || now.timeIntervalSince(item.lastProbeAt!) >= refreshInterval {
                enqueue(taskId)
            }
        }
    }

    /// Sonda IMEDIATA de todas as linhas visíveis, ignorando o intervalo —
    /// usada quando o app volta ao primeiro plano (a conclusão pode ter
    /// acabado de acontecer na web). O cache curto do ReviewBackend segue
    /// deduplicando; isto nunca vira tempestade de requests.
    func probeVisibleNow() {
        for taskId in watched.keys { enqueue(taskId) }
    }

    private func findUpdates(in task: CUTask) async -> [Update] {
        var updates: [Update] = []
        for candidate in probeCandidates(in: task) {
            guard !Task.isCancelled else { return [] }
            let attachment = candidate.attachment
            let att: String
            let meta: ReviewBackend.Meta
            if let versionId = candidate.versionId {
                // Catalog lineages are probed through the stable review id AND
                // the exact version. `ReviewBackend.meta` refuses answers whose
                // `evaluatedVersionId` differs from the request, so an older
                // Worker (or the lineage root) can never masquerade as V2/V3.
                guard let exact = await ReviewBackend.meta(
                    att: candidate.reviewId, versionId: versionId
                ) else { continue }
                att = candidate.reviewId
                meta = exact
            } else {
                // Mono-version/legacy media keeps the dual-key lookup: reads
                // only, never creates a session.
                let key = ReviewBackend.sessionKey(
                    attachmentId: candidate.reviewId,
                    mediaUrl: attachment.url
                )
                (att, meta) = await ReviewBackend.activeMeta(key: key)
            }
            let observationKey = ReviewBackend.observationKey(
                att: att, versionId: candidate.versionId
            )
            let unseen = ReviewBackend.observe(meta: meta, att: observationKey)
            if meta.isApprovedAndConcluded {
                // Final remote state is not another VER REVIEW update. Feed it
                // to the durable latch so it can perform REVISADO -> disappear.
                await ReviewWatcher.shared.reportDiscoveredUpdate(
                    att: att,
                    mediaUrl: attachment.url,
                    ext: attachment.ext,
                    taskId: task.id,
                    title: attachment.title,
                    uploaderId: attachment.uploaderId,
                    tintHex: task.statusDisplayHex,
                    meta: meta,
                    hasUnseenUpdate: unseen,
                    versionId: candidate.versionId
                )
                continue
            }
            guard unseen else { continue }
            await ReviewWatcher.shared.reportDiscoveredUpdate(
                att: att,
                mediaUrl: attachment.url,
                ext: attachment.ext,
                taskId: task.id,
                title: attachment.title,
                uploaderId: attachment.uploaderId,
                tintHex: task.statusDisplayHex,
                meta: meta,
                hasUnseenUpdate: true,
                versionId: candidate.versionId
            )
            let candidate = Update(taskId: task.id, attachment: attachment,
                                   activeAtt: att, meta: meta)
            updates.append(candidate)
        }
        return updates.sorted { ($0.meta.updatedAt ?? "") > ($1.meta.updatedAt ?? "") }
    }

    private struct ProbeCandidate {
        let attachment: CUTask.Attachment
        let reviewId: String
        /// Exact version to probe ("v3"). nil = mono-version/legacy media whose
        /// session predates versioned lineages.
        let versionId: String?
    }

    /// A task may expose every physical replacement attachment. Only the
    /// newest attachment of each catalog lineage is probed, and it is probed
    /// through the stable review id. Older media remains selectable inside the
    /// review version picker; it is not another pending review row.
    private func probeCandidates(in task: CUTask) -> [ProbeCandidate] {
        let visible = task.visibleAttachments.filter {
            ReviewLink.isReviewable($0.ext)
        }
        guard let catalog = catalogFetcher(task.id) else {
            return visible.map {
                ProbeCandidate(attachment: $0, reviewId: $0.id, versionId: nil)
            }
        }

        var candidates: [String: ProbeCandidate] = [:]
        var catalogAttachmentIds: Set<String> = []
        var catalogURLs: Set<String> = []
        for identity in catalog.latestReviewIdentities() {
            for output in catalog.outputs where output.lineageId == identity.output.lineageId {
                if let id = output.attachmentId { catalogAttachmentIds.insert(id) }
                if let url = output.remoteURL?.absoluteString { catalogURLs.insert(url) }
            }
            let latest = identity.latestOutput
            let matching = visible.first {
                $0.id == latest.attachmentId || $0.url == latest.remoteURL?.absoluteString
            }
            let attachment = matching ?? self.attachment(
                for: latest,
                fallbackTitle: latest.fileName,
                fallbackURL: latest.remoteURL?.absoluteString ?? "",
                fallbackExt: (latest.fileName as NSString).pathExtension,
                uploaderId: nil,
                commentCount: 0
            )
            guard !attachment.url.isEmpty else { continue }
            candidates[identity.reviewId] = ProbeCandidate(
                attachment: attachment,
                reviewId: identity.reviewId,
                versionId: identity.versionId
            )
        }

        for attachment in visible
            where !catalogAttachmentIds.contains(attachment.id)
                && !catalogURLs.contains(attachment.url) {
            candidates[attachment.id] = ProbeCandidate(
                attachment: attachment,
                reviewId: attachment.id,
                versionId: nil
            )
        }
        return Array(candidates.values)
    }

    private func restorePersistedUpdates(_ records: [Update]) {
        struct Restored {
            let update: Update
            let wasCanonical: Bool
        }
        var restoredByTask: [String: [String: Restored]] = [:]
        for record in records {
            // Normalization never invents a version: a record that does not
            // know which version was evaluated stays version-less.
            let normalized = canonicalized(record)
            guard normalized.meta.hasReviewerActivityEvidence else { continue }
            // A version-less record for a multi-version lineage is ambiguous —
            // it may carry V1 activity under a V2 identity (the phantom
            // VER REVIEW). Discard it; the exact-version probe re-latches
            // whatever is genuinely pending.
            if Self.authoritativeVersion(normalized.meta) == nil,
               requiresExactVersion(taskId: normalized.taskId,
                                    activeAtt: normalized.activeAtt,
                                    mediaURL: normalized.attachment.url) {
                continue
            }
            let key = Self.pendingKey(for: normalized)
            let item = Restored(
                update: normalized,
                wasCanonical: record.activeAtt == normalized.activeAtt
            )
            let current = restoredByTask[normalized.taskId]?[key]
            let shouldReplace = current == nil
                || (!current!.wasCanonical && item.wasCanonical)
                || (current!.wasCanonical == item.wasCanonical
                    && Self.isNewer(item.update, than: current!.update))
            if shouldReplace {
                restoredByTask[normalized.taskId, default: [:]][key] = item
            }
        }
        updatesByTask = restoredByTask.mapValues { bucket in
            bucket.mapValues(\.update)
        }
        let restoredCount = updatesByTask.values.map(\.count).reduce(0, +)
        Log.info("Review restore: \(restoredCount) latches mantidos após saneamento")
        persistPendingUpdates()
    }

    private func canonicalized(_ update: Update) -> Update {
        guard let catalog = catalogFetcher(update.taskId),
              let identity = catalog.reviewIdentity(
            attachmentId: update.activeAtt,
            mediaURL: update.attachment.url
        ) else { return update }

        let cameFromPhysicalAlias = update.activeAtt != identity.reviewId
        // Only the server-evaluated version may select the exact catalog
        // output. `currentVersionId` (or the catalog's own numbering) merely
        // says which media is projected; treating it as evaluated is what
        // fabricated "V2 has review activity" out of "V2 is current".
        let evaluatedVersion = Self.authoritativeVersion(update.meta)
        let selected: TaskMediaOutputVersion
        if cameFromPhysicalAlias {
            // The physical attachment identifies its own exact catalog output;
            // its accidental server document often calls itself V1.
            selected = identity.output
        } else if let number = Self.versionNumber(evaluatedVersion),
                  let exact = catalog.outputs.first(where: {
                      $0.lineageId == identity.output.lineageId
                          && $0.version == number
                  }) {
            selected = exact
        } else {
            selected = identity.output
        }

        let exactAttachment = attachment(
            for: selected,
            fallbackTitle: update.attachment.title,
            fallbackURL: update.attachment.url,
            fallbackExt: update.attachment.ext,
            uploaderId: update.attachment.uploaderId,
            commentCount: update.meta.commentCount
        )
        // `currentVersionId`/`evaluatedVersionId` pass through untouched: a
        // record that does not know which version was evaluated stays version-
        // less and is handled as ambiguous downstream — never "repaired" here.
        let meta = ReviewBackend.Meta(
            exists: update.meta.exists,
            updatedAt: update.meta.updatedAt,
            status: update.meta.status,
            commentCount: update.meta.commentCount,
            concludedAt: update.meta.concludedAt,
            reviewId: identity.reviewId,
            currentVersionId: update.meta.currentVersionId,
            mediaTitle: selected.fileName,
            evaluatedVersionId: update.meta.evaluatedVersionId
        )
        return Update(taskId: update.taskId,
                      attachment: exactAttachment,
                      activeAtt: identity.reviewId,
                      meta: meta)
    }

    private static func versionNumber(_ normalizedVersion: String?) -> Int? {
        guard let normalizedVersion,
              normalizedVersion.hasPrefix("v") else { return nil }
        return Int(normalizedVersion.dropFirst())
    }

    private func attachment(for output: TaskMediaOutputVersion,
                            fallbackTitle: String,
                            fallbackURL: String,
                            fallbackExt: String,
                            uploaderId: Int?,
                            commentCount: Int) -> CUTask.Attachment {
        let title = output.fileName.isEmpty ? fallbackTitle : output.fileName
        let url = output.remoteURL?.absoluteString ?? fallbackURL
        let fileExt = (title as NSString).pathExtension.lowercased()
        return CUTask.Attachment(
            id: output.attachmentId ?? url,
            title: title,
            url: url,
            ext: fileExt.isEmpty ? fallbackExt.lowercased() : fileExt,
            sizeString: nil,
            totalComments: commentCount,
            resolvedComments: nil,
            uploaderId: uploaderId
        )
    }

    /// Everything a CONFIRMED approved+concluded completion may consume: the
    /// aliases of the exact version (`equivalentReviewKeys`) plus pendencies
    /// of STRICTLY OLDER versions of the same logical review. A new version
    /// supersedes its predecessors — once it is approved and explicitly
    /// concluded the lineage's cycle is closed, and an older latch would
    /// otherwise be immortal (older versions are never probed again).
    /// Concluding an OLD version still never consumes a newer pendency.
    private func consumableReviewKeys(taskId: String,
                                      activeAtt: String,
                                      mediaUrl: String,
                                      reviewId: String?,
                                      versionId: String?) -> [String] {
        var keys = equivalentReviewKeys(taskId: taskId, activeAtt: activeAtt,
                                        mediaUrl: mediaUrl, reviewId: reviewId,
                                        versionId: versionId)
        guard let confirmedNumber = Self.versionNumber(
                Self.normalizedVersion(versionId)),
              let bucket = updatesByTask[taskId]
        else { return keys }
        let logicalId = Self.nonBlank(reviewId) ?? activeAtt
        for (key, candidate) in bucket where !keys.contains(key) {
            guard Self.logicalReviewId(candidate) == logicalId,
                  let candidateNumber = Self.versionNumber(
                      Self.authoritativeVersion(candidate.meta)),
                  candidateNumber < confirmedNumber
            else { continue }
            keys.append(key)
        }
        return keys
    }

    /// All persisted keys that refer to the same logical review AND the same
    /// exact version. During the canonical-id migration the pending latch may
    /// have been captured before `openSession` moved the blob, so equality by
    /// key alone is insufficient. URL equality is safe here because each
    /// pending row describes one exact ClickUp attachment/media source.
    ///
    /// Version rule: a candidate matches when its authoritative version equals
    /// `versionId`, or when it has none (a version-less latch is a legacy or
    /// contaminated alias of this review, never an independent sibling). A
    /// version-exact sibling latch (V2 pending while V3 concludes) is never
    /// returned.
    private func equivalentReviewKeys(taskId: String,
                                      activeAtt: String,
                                      mediaUrl: String,
                                      reviewId: String?,
                                      versionId: String? = nil) -> [String] {
        guard let bucket = updatesByTask[taskId] else { return [] }
        let legacy = ReviewBackend.att(forMediaUrl: mediaUrl)
        let canonical = catalogFetcher(taskId)?.reviewIdentity(
            attachmentId: activeAtt,
            mediaURL: mediaUrl
        )?.reviewId
        let requestedVersion = Self.normalizedVersion(versionId)
        return bucket.compactMap { key, candidate in
            let candidateLegacy = ReviewBackend.att(
                forMediaUrl: candidate.attachment.url
            )
            let matches = key == activeAtt
                || key == legacy
                || candidate.activeAtt == activeAtt
                || candidate.activeAtt == legacy
                || candidate.attachment.id == activeAtt
                || candidate.attachment.url == mediaUrl
                || candidateLegacy == activeAtt
                || (canonical != nil && key == canonical)
                || (canonical != nil && candidate.activeAtt == canonical)
                || (reviewId != nil && candidate.meta.reviewId == reviewId)
            guard matches else { return nil }
            let candidateVersion = Self.authoritativeVersion(candidate.meta)
            if let requestedVersion {
                return (candidateVersion == nil
                            || candidateVersion == requestedVersion)
                    ? key : nil
            }
            return candidateVersion == nil ? key : nil
        }
    }

    private static func isNewer(_ candidate: Update, than current: Update) -> Bool {
        (candidate.meta.updatedAt ?? "") >= (current.meta.updatedAt ?? "")
    }
}
