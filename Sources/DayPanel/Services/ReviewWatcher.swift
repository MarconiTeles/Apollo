import Foundation
import ReviewKit

/// Watches reviews this user opened OR that the task list discovered with real
/// activity, and fires a
/// native notification when one changes on the backend — so the Apollo user
/// learns "someone updated the link" without staring at the task. The dot on the
/// REVIEW button is the passive cue; this is the active one. A tap routes to the
/// task (where the badged REVIEW button lives).
///
/// Registry + dedup live in UserDefaults:
///   reviewWatchRegistry        → [att: Entry]   (what to poll)
///   reviewSeen.<att>           → updatedAt       (badge baseline, set on completion)
///   reviewNotified.<att>       → updatedAt       (don't alert twice for one change)
final class ReviewWatcher {
    static let shared = ReviewWatcher(publishesToSharedTaskStore: true)
    private let defaults: UserDefaults
    private let publishesToSharedTaskStore: Bool

    init(defaults: UserDefaults = .standard,
         publishesToSharedTaskStore: Bool = false) {
        self.defaults = defaults
        self.publishesToSharedTaskStore = publishesToSharedTaskStore
    }

    private let regKey = "reviewWatchRegistry"
    private var started = false

    /// Posts the update notification. Injected by AppDelegate to route through
    /// `AppState.notify` so it lands BOTH in the in-app Notifications panel AND
    /// as a native macOS banner (notify() does both). `att` is the review key —
    /// the tap reopens that review. nil → no-op.
    var notify: ((_ title: String, _ subtitle: String?, _ att: String) -> Void)?

    struct Entry: Codable {
        var mediaUrl: String
        var ext: String
        var taskId: String
        var title: String
        var uploaderId: Int?
        var tintHex: String?
        /// Exact media state inside the stable review lineage. Older registry
        /// entries decode as nil and retain legacy single-version behavior.
        var versionId: String?
    }

    /// Called when the user opens a review — start watching it, and treat the
    /// version they just saw as already alerted so we only notify on FUTURE
    /// changes.
    func register(att: String, mediaUrl: String, ext: String, taskId: String,
                  title: String, uploaderId: Int?, tintHex: String?,
                  currentUpdatedAt: String?, versionId: String? = nil) {
        var reg = registry()
        reg[att] = Entry(mediaUrl: mediaUrl, ext: ext, taskId: taskId, title: title,
                         uploaderId: uploaderId, tintHex: tintHex,
                         versionId: versionId)
        save(reg)
        if let u = currentUpdatedAt {
            let observationKey = ReviewBackend.observationKey(
                att: att, versionId: versionId
            )
            defaults.set(u, forKey: "reviewNotified.\(observationKey)")
        }
    }

    /// Removes a physical replacement id from the watch registry and keeps
    /// only the stable review lineage. This also prevents a stale V4 watcher
    /// from recreating the duplicate session after Apollo relaunches.
    func remap(from oldAtt: String, to canonicalAtt: String,
               mediaUrl: String, ext: String, taskId: String,
               title: String, uploaderId: Int?, tintHex: String?,
               versionId: String? = nil) {
        guard oldAtt != canonicalAtt else { return }
        var reg = registry()
        reg.removeValue(forKey: oldAtt)
        reg[canonicalAtt] = Entry(
            mediaUrl: mediaUrl,
            ext: ext,
            taskId: taskId,
            title: title,
            uploaderId: uploaderId,
            tintHex: tintHex,
            versionId: versionId
        )
        save(reg)
        let canonicalObservationKey = ReviewBackend.observationKey(
            att: canonicalAtt, versionId: versionId
        )
        let oldObservationKey = ReviewBackend.observationKey(
            att: oldAtt, versionId: versionId
        )
        if defaults.string(forKey: "reviewNotified.\(canonicalObservationKey)") == nil,
           let oldRevision = defaults.string(forKey: "reviewNotified.\(oldObservationKey)") {
            defaults.set(oldRevision,
                         forKey: "reviewNotified.\(canonicalObservationKey)")
        }
        defaults.removeObject(forKey: "reviewNotified.\(oldObservationKey)")
    }

    /// Called by the shared visible-row probe only after it has established
    /// that the remote blob contains real unseen activity. Registering here is
    /// what lets a notification deep-link to a review that was updated on the
    /// web before it had ever been opened in native Apollo.
    func reportDiscoveredUpdate(att: String, mediaUrl: String, ext: String,
                                taskId: String, title: String,
                                uploaderId: Int?, tintHex: String?,
                                meta: ReviewBackend.Meta,
                                hasUnseenUpdate: Bool,
                                versionId: String? = nil) async {
        var reg = registry()
        let entry = Entry(mediaUrl: mediaUrl, ext: ext, taskId: taskId,
                          title: title, uploaderId: uploaderId, tintHex: tintHex,
                          versionId: versionId)
        reg[att] = entry
        save(reg)
        // Propagate state before notification dedup. In particular, an
        // approved + explicitly concluded review must consume a durable row
        // latch even after an app relaunch where this revision was observed.
        if publishesToSharedTaskStore {
            await MainActor.run {
                TaskReviewUpdateStore.shared.recordDiscoveredUpdate(
                    taskId: entry.taskId, activeAtt: att,
                    mediaUrl: entry.mediaUrl, ext: entry.ext, title: entry.title,
                    uploaderId: entry.uploaderId, meta: meta,
                    hasUnseenUpdate: hasUnseenUpdate,
                    versionId: entry.versionId
                )
            }
        }
        guard hasUnseenUpdate else { return }
        await emitIfNeeded(att: att, entry: entry, meta: meta)
    }

    /// Rebuild the params to reopen a watched review (tap on its notification).
    /// The actor (who's opening) comes from the caller; everything else from the
    /// registry captured when the review was opened.
    func openParams(att: String, actorId: Int, actorName: String) -> OpenReviewParams? {
        guard let e = registry()[att] else { return nil }
        return OpenReviewParams(
            taskId: e.taskId,
            attachmentId: att,
            mediaUrl: e.mediaUrl,
            mediaTitle: e.title,
            ext: e.ext,
            uploaderId: e.uploaderId,
            actorId: actorId,
            actorName: actorName,
            reviewId: att,
            versionId: e.versionId
        )
    }

    /// Begins the background poll loop (idempotent).
    func start() {
        guard !started else { return }
        started = true
        Task.detached { [weak self] in
            while !Task.isCancelled {
                // Visible rows perform the bounded first discovery pass; the
                // watcher waits before polling so app launch does not duplicate
                // those reads. 2 minutes keeps web activity (comentário/
                // conclusão de um revisor) visível em tempo útil — o backend
                // D1 removeu o teto diário que justificava os 15 minutos, e o
                // cache/dedup do ReviewBackend continua absorvendo rajadas.
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                await self?.poll()
            }
        }
    }

    private func poll() async {
        for (att, entry) in registry() {
            // `att` É a chave da sessão (fixada quando o review foi aberto) —
            // consultar por ela, nunca re-derivar da mediaUrl (a re-derivação
            // dava o hash legado e perdia sessões canônicas do fluxo novo).
            guard let meta = await ReviewBackend.meta(
                att: att, versionId: entry.versionId
            ) else { continue }
            let observationKey = ReviewBackend.observationKey(
                att: att, versionId: entry.versionId
            )
            let unseen = ReviewBackend.observe(meta: meta, att: observationKey)
            if publishesToSharedTaskStore {
                await MainActor.run {
                    TaskReviewUpdateStore.shared.recordDiscoveredUpdate(
                        taskId: entry.taskId, activeAtt: att,
                        mediaUrl: entry.mediaUrl, ext: entry.ext,
                        title: entry.title, uploaderId: entry.uploaderId,
                        meta: meta, hasUnseenUpdate: unseen,
                        versionId: entry.versionId
                    )
                }
            }
            guard unseen else { continue }
            await emitIfNeeded(att: att, entry: entry, meta: meta)
        }
    }

    private func emitIfNeeded(att: String, entry: Entry,
                              meta: ReviewBackend.Meta) async {
        guard let revision = notificationRevision(meta: meta) else { return }
        let observationKey = ReviewBackend.observationKey(
            att: att, versionId: entry.versionId
        )
        let key = "reviewNotified.\(observationKey)"
        guard defaults.string(forKey: key) != revision else { return }
        // Claim before presenting so the visible-row probe and the background
        // watcher cannot produce two notifications for the same server save.
        defaults.set(revision, forKey: key)
        let title = entry.title.isEmpty ? nil : entry.title
        await MainActor.run { notify?("Review atualizado", title, att) }
    }

    private func notificationRevision(meta: ReviewBackend.Meta) -> String? {
        guard meta.exists else { return nil }
        if let updatedAt = meta.updatedAt, !updatedAt.isEmpty { return updatedAt }
        return "\(meta.status ?? "")|\(meta.commentCount)"
    }

    private func registry() -> [String: Entry] {
        guard let data = defaults.data(forKey: regKey),
              let r = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return r
    }
    private func save(_ r: [String: Entry]) {
        if let d = try? JSONEncoder().encode(r) {
            defaults.set(d, forKey: regKey)
        }
    }
}
