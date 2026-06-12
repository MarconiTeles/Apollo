import Foundation

/// Disk cache for the launch snapshot (events + tasks +
/// assigned-to-me), rebuilt for performance:
///
///   • All encoding/writes run on a SERIAL background queue.
///     The old `save()` did a synchronous JSONEncoder pass over
///     the entire ~30 MB snapshot plus an atomic write on the
///     CALLER's thread — when that caller was `@MainActor`
///     (`persistAssignedToMeCache`) the UI visibly froze.
///   • The snapshot is SPLIT per section (events / tasks /
///     assigned + a tiny meta file), so updating one section no
///     longer re-encodes the other two.
///   • Each section keeps its last-written value (queue-
///     confined) and SKIPS the encode+write when nothing
///     changed — the 30s fast-sync used to rewrite all 30 MB
///     even when the server returned identical data.
///
/// `load()` prefers the split layout and falls back to the
/// legacy single `cache.json` (pre-split builds) so the first
/// launch after updating still paints instantly.
final class CacheManager {

    private let queue = DispatchQueue(label: "com.painellunar.cache",
                                      qos: .utility)

    /// lastSyncedAt lives in its own tiny file so bumping the
    /// timestamp (every sync) never drags a big encode along.
    private struct Meta: Codable {
        var lastSyncedAt: Date
    }

    // Queue-confined last-written snapshots for change detection.
    private var lastEvents:   [CalendarEvent]?
    private var lastTasks:    [CUTask]?
    private var lastAssigned: [CUTask]?

    /// Override for tests — keeps unit tests away from the real
    /// Application Support cache. `nil` (production) resolves to
    /// the standard DayPanel directory.
    private let directoryOverride: URL?
    init(directory: URL? = nil) {
        self.directoryOverride = directory
    }

    private var dir: URL? {
        if let directoryOverride { return directoryOverride }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("DayPanel")
    }
    private func fileURL(_ name: String) -> URL? {
        dir?.appendingPathComponent(name)
    }

    /// Test hook: blocks until every queued write has landed.
    func waitForPendingWrites() {
        queue.sync {}
    }

    // MARK: - Load (called once, off-main, from initialize())

    func load() -> AppCache? {
        // New split layout first.
        if let meta: Meta = read("cache-meta.json") {
            let events:   [CalendarEvent] = read("cache-events.json")   ?? []
            let tasks:    [CUTask]        = read("cache-tasks.json")    ?? []
            let assigned: [CUTask]        = read("cache-assigned.json") ?? []
            if !events.isEmpty || !tasks.isEmpty || !assigned.isEmpty {
                return AppCache(events: events,
                                tasks: tasks,
                                lastSyncedAt: meta.lastSyncedAt,
                                assignedToMeTasks: assigned)
            }
            // Meta present but sections empty/corrupt — fall
            // through to the legacy file rather than booting
            // with a blank slate.
        }
        // Legacy single-file layout (pre-split builds).
        guard let url = fileURL("cache.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppCache.self, from: data)
    }

    private func read<T: Decodable>(_ name: String) -> T? {
        guard let url = fileURL(name),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Save (non-blocking; encode+write on the queue)

    /// Full-snapshot save — same call shape `performSync` always
    /// used. Internally fans out to the per-section writers, so
    /// unchanged sections cost one array comparison and nothing
    /// else.
    func save(_ cache: AppCache) {
        queue.async { [weak self] in
            guard let self else { return }
            self.writeIfChanged(cache.events,            last: &self.lastEvents,   name: "cache-events.json")
            self.writeIfChanged(cache.tasks,             last: &self.lastTasks,    name: "cache-tasks.json")
            self.writeIfChanged(cache.assignedToMeTasks, last: &self.lastAssigned, name: "cache-assigned.json")
            self.write(Meta(lastSyncedAt: cache.lastSyncedAt), name: "cache-meta.json")
        }
    }

    /// Section save for the assigned-to-me snapshot. Replaces
    /// the old load-modify-save round-trip (decode 30 MB +
    /// re-encode 30 MB on the MainActor) with one queued write
    /// of just this section.
    func saveAssigned(_ assigned: [CUTask]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.writeIfChanged(assigned, last: &self.lastAssigned, name: "cache-assigned.json")
        }
    }

    // MARK: - Queue-confined plumbing

    private func writeIfChanged<T: Codable & Equatable>(_ value: T,
                                                        last: inout T?,
                                                        name: String) {
        if let last, last == value { return }
        write(value, name: name)
        last = value
    }

    private func write<T: Encodable>(_ value: T, name: String) {
        guard let url = fileURL(name) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
