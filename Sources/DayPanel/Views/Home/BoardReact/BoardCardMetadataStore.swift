#if APOLLO_BOARD_REACT
import Foundation
import OSLog

/// Card metadata the list endpoint omits: attachments (count and ClickUp's
/// default cover — the first image or video attachment), and checklists.
///
/// Only cards the board reports as visible are hydrated, one `getTask` at a
/// time with spacing, and results persist in Caches keyed by task id plus
/// ClickUp's `date_updated`: scrolling back or relaunching costs no request
/// until the task changes. A card never hydrated reports "unknown" (nil),
/// never a false zero.
@MainActor
final class BoardCardMetadataStore: ObservableObject {
    static let shared = BoardCardMetadataStore()
    private static let log = Logger(subsystem: "com.painellunar.app", category: "BoardMetadata")

    struct Entry: Codable, Equatable {
        /// Structured ClickUp attachments, excluding Apollo's technical
        /// media records and links scraped from the description.
        var attachments: Int
        /// Preview of the first image/video attachment.
        var cover: String?
        var checklistDone: Int
        var checklistTotal: Int
        /// `date_updated` the entry was read at; newer task data refetches.
        var source: Date?
    }

    @Published private(set) var entries: [String: Entry] = [:]

    typealias Fetcher = (String) async -> CUTask?
    private var queue: [String] = []
    private var queued: Set<String> = []
    private var pump: Task<Void, Never>?
    private var pausedUntil: Date?
    private var saveTask: Task<Void, Never>?
    private let spacing: Duration = .milliseconds(320)
    /// Visible cards only; older requests are dropped when the user scrolls on.
    private let queueLimit = 48

    private init() { load() }

    // MARK: Derivation

    static func entry(from task: CUTask) -> Entry {
        // Description-derived links carry their URL as id; ClickUp's own
        // attachments have real ids. The card counts ClickUp attachments.
        let files = task.visibleAttachments.filter { $0.id != $0.url }
        let visual: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp",
                                   "mp4", "mov", "m4v", "avi", "mkv", "webm"]
        let cover = files
            .filter { $0.thumbnailURL != nil && visual.contains($0.ext) }
            .min { ($0.dateAdded ?? .distantFuture) < ($1.dateAdded ?? .distantFuture) }?
            .thumbnailURL
        let items = task.checklists.flatMap(\.items)
        return Entry(attachments: files.count,
                     cover: cover,
                     checklistDone: items.filter(\.resolved).count,
                     checklistTotal: items.count,
                     source: task.dateUpdated)
    }

    /// A task already hydrated elsewhere (detail view) refreshes its entry
    /// without a request.
    func ingest(_ task: CUTask) {
        guard !task.attachments.isEmpty else { return }
        store(Self.entry(from: task), for: task.id)
    }

    private func store(_ entry: Entry, for id: String) {
        guard entries[id] != entry else { return }
        entries[id] = entry
        scheduleSave()
    }

    func isCurrent(_ task: CUTask) -> Bool {
        guard let entry = entries[task.id] else { return false }
        guard let updated = task.dateUpdated, let source = entry.source else { return true }
        return updated <= source
    }

    // MARK: Hydration

    func request(_ tasks: [CUTask], fetch: @escaping Fetcher) {
        for task in tasks {
            ingest(task)
            guard !isCurrent(task), !queued.contains(task.id) else { continue }
            queue.append(task.id)
            queued.insert(task.id)
        }
        while queue.count > queueLimit {
            queued.remove(queue.removeFirst())
        }
        guard pump == nil, !queue.isEmpty else { return }
        pump = Task { [weak self] in
            await self?.drain(fetch)
            self?.pump = nil
        }
    }

    private func drain(_ fetch: Fetcher) async {
        while !queue.isEmpty, !Task.isCancelled {
            if let pausedUntil, pausedUntil > Date() {
                try? await Task.sleep(for: .seconds(pausedUntil.timeIntervalSinceNow))
            }
            // Newest requests first: the cards the user is looking at now.
            let id = queue.removeLast()
            queued.remove(id)
            if let task = await fetch(id) {
                store(Self.entry(from: task), for: id)
            } else {
                // Rate limit, offline or permission: back off the whole queue.
                pausedUntil = Date().addingTimeInterval(30)
                Self.log.debug("hydration paused after a failed getTask")
            }
            try? await Task.sleep(for: spacing)
        }
    }

    // MARK: Persistence

    private static var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ApolloBoard", isDirectory: true)
            .appendingPathComponent("card-metadata-v1.json")
    }

    private func load() {
        guard !ApolloDevLaunchOptions.isFixtureMode,
              let url = Self.fileURL, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = decoded
    }

    private func scheduleSave() {
        guard !ApolloDevLaunchOptions.isFixtureMode else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, let url = Self.fileURL,
                  let data = try? JSONEncoder().encode(self.entries) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Fixtures

    /// `--board-fixtures`: deterministic metadata (no network) so covers,
    /// counts and checklists can be inspected offline.
    func seedFixtures(_ tasks: [CUTask]) {
        for (index, task) in tasks.enumerated() where entries[task.id] == nil {
            let hasCover = index % 4 == 1
            entries[task.id] = Entry(
                attachments: hasCover ? 3 + index % 9 : (index % 5 == 0 ? 2 : 0),
                cover: hasCover ? "fixture:\(index % 6)" : nil,
                checklistDone: index % 7 == 3 ? 2 : 0,
                checklistTotal: index % 7 == 3 ? 5 : 0,
                source: task.dateUpdated)
        }
    }
}
#endif
