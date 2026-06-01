import Foundation

/// Watches the reviews this user knows about (opened at least once) and fires a
/// native notification when one changes on the backend — so the Apollo user
/// learns "someone updated the link" without staring at the task. The dot on the
/// REVIEW button is the passive cue; this is the active one. A tap routes to the
/// task (where the badged REVIEW button lives).
///
/// Registry + dedup live in UserDefaults:
///   reviewWatchRegistry        → [att: Entry]   (what to poll)
///   reviewSeen.<att>           → updatedAt       (badge baseline, set on open)
///   reviewNotified.<att>       → updatedAt       (don't alert twice for one change)
final class ReviewWatcher {
    static let shared = ReviewWatcher()
    private init() {}

    private let regKey = "reviewWatchRegistry"
    private var started = false

    struct Entry: Codable {
        var mediaUrl: String
        var taskId: String
        var title: String
        var tintHex: String?
    }

    /// Called when the user opens a review — start watching it, and treat the
    /// version they just saw as already alerted so we only notify on FUTURE
    /// changes.
    func register(att: String, mediaUrl: String, taskId: String, title: String,
                  tintHex: String?, currentUpdatedAt: String?) {
        var reg = registry()
        reg[att] = Entry(mediaUrl: mediaUrl, taskId: taskId, title: title, tintHex: tintHex)
        save(reg)
        if let u = currentUpdatedAt {
            UserDefaults.standard.set(u, forKey: "reviewNotified.\(att)")
        }
    }

    /// Begins the background poll loop (idempotent).
    func start() {
        guard !started else { return }
        started = true
        Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s
                await self?.poll()
            }
        }
    }

    private func poll() async {
        for (att, entry) in registry() {
            guard let meta = await ReviewBackend.meta(forMediaUrl: entry.mediaUrl),
                  let remote = meta.updatedAt,
                  let seen = ReviewBackend.lastSeen(forMediaUrl: entry.mediaUrl)
            else { continue }
            let notified = UserDefaults.standard.string(forKey: "reviewNotified.\(att)")
            // Changed since the user last opened it, and not already alerted.
            guard remote > seen, remote != notified else { continue }
            NativeNotifier.shared.send(
                kind: .info,
                title: "Review atualizado",
                subtitle: entry.title.isEmpty ? nil : entry.title,
                body: "Alguém atualizou este review.",
                targetKind: .task,
                targetId: entry.taskId,
                tintHex: entry.tintHex
            )
            UserDefaults.standard.set(remote, forKey: "reviewNotified.\(att)")
        }
    }

    private func registry() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: regKey),
              let r = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return r
    }
    private func save(_ r: [String: Entry]) {
        if let d = try? JSONEncoder().encode(r) {
            UserDefaults.standard.set(d, forKey: regKey)
        }
    }
}
