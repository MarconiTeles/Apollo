import Foundation
import CoreSpotlight
import UniformTypeIdentifiers
import Combine

/// Mirrors Apollo's task list into the macOS Spotlight index so
/// Cmd+Space → "Comprar leite" surfaces the matching task as a
/// first-class result. Clicking the Spotlight hit launches /
/// activates Apollo and routes through
/// `AppDelegate.application(_:continue:)` → `AppState.openTask(id:)`,
/// opening the task detail directly.
///
/// Design:
/// - Subscribes to `AppState.tasksById` via Combine, debounces 600ms,
///   and rebuilds the searchable item set whenever the snapshot
///   changes. Debouncing avoids hammering CoreSpotlight during the
///   high-volume optimistic-update bursts that follow a sync.
/// - Uses a single `domainIdentifier` ("com.painellunar.app.tasks")
///   so the index can be cleared in one call on logout / list switch.
/// - Each item carries the task title + description + status as
///   `contentDescription`/`keywords`, plus a stable
///   `uniqueIdentifier == task.id` so re-indexing the same task
///   replaces (not duplicates) the entry.
///
/// Not annotated `@MainActor` so AppDelegate's `lazy var` can build
/// it from a synchronous nonisolated context. The Combine
/// subscription pins itself to `DispatchQueue.main` and the
/// CSSearchableIndex APIs are safe to call from any queue.
final class SpotlightIndexer {

    /// One bucket per ClickUp list — keyed so we can drop the
    /// previous list's entries when the user switches lists in
    /// Settings without leaving stale tasks indexed.
    private let domainIdentifier = "com.painellunar.app.tasks"

    /// Single `CSSearchableIndex.default()` reference. The framework
    /// expects callers to interact with the default instance for
    /// app-wide indexing.
    private let index = CSSearchableIndex.default()

    /// Held to keep the debounced subscription alive for the
    /// service's lifetime.
    private var cancellables = Set<AnyCancellable>()

    /// All composition + diffing happens here, off the main
    /// thread. Building ~900 `CSSearchableItem`s (attribute sets,
    /// date formatting, keyword arrays) on the main queue caused
    /// a visible hitch after every sync burst.
    private let workQueue = DispatchQueue(label: "com.painellunar.spotlight",
                                          qos: .utility)

    /// Last indexed snapshot, keyed by task id — queue-confined.
    /// Lets the next pass index ONLY tasks that actually changed
    /// (typically 0-2 after a sync) instead of re-submitting the
    /// whole set, and detect deletions by key diff.
    private var lastIndexedTasks: [String: CUTask] = [:]

    /// Shared formatter — `DateFormatter()` allocation +
    /// configuration per task was pure churn. Read-only use,
    /// confined to `workQueue`.
    private static let dueFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "pt_BR")
        fmt.dateStyle = .medium
        return fmt
    }()

    /// Wire the subscription. Call once from `AppDelegate` after
    /// AppState is alive. Idempotent — calling twice replaces the
    /// subscription.
    func attach(to appState: AppState) {
        cancellables.removeAll()
        appState.$tasksById
            // Coalesce the optimistic-update burst that follows a
            // sync into a single index rebuild.
            .debounce(for: .milliseconds(600), scheduler: DispatchQueue.main)
            .sink { [weak self] dict in
                guard let self else { return }
                let snapshot = Array(dict.values)
                self.workQueue.async { self.reindex(tasks: snapshot) }
            }
            .store(in: &cancellables)
    }

    /// Drop every task we've indexed. Call on logout, list switch,
    /// or "Forget this device" so previous content stops showing up
    /// in Spotlight.
    func clearAll() {
        index.deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { error in
            if let error {
                NSLog("[Apollo] Spotlight clearAll failed: %@", error.localizedDescription)
            }
        }
        workQueue.async { self.lastIndexedTasks.removeAll() }
    }

    // MARK: - Private (workQueue-confined)

    private func reindex(tasks: [CUTask]) {
        let active = tasks.filter { !$0.archived && !$0.isCompleted }
        let activeById = Dictionary(
            active.map { ($0.id, $0) },
            uniquingKeysWith: { _, new in new }
        )

        // Incremental: only submit tasks that are new or whose
        // content actually changed since the last pass.
        let changed = active.filter { lastIndexedTasks[$0.id] != $0 }
        if !changed.isEmpty {
            let items: [CSSearchableItem] = changed.map { task in
                let attrs = CSSearchableItemAttributeSet(contentType: UTType.text)
                attrs.title              = task.title
                attrs.contentDescription = composeDescription(for: task)
                attrs.keywords           = composeKeywords(for: task)
                // Friendly subtitle visible in Spotlight's preview pane —
                // the status + due date is the most actionable info.
                attrs.displayName        = task.title
                return CSSearchableItem(
                    uniqueIdentifier: task.id,
                    domainIdentifier: domainIdentifier,
                    attributeSet:     attrs
                )
            }
            index.indexSearchableItems(items) { error in
                if let error {
                    NSLog("[Apollo] Spotlight indexSearchableItems failed: %@",
                          error.localizedDescription)
                }
            }
        }

        // Detect deletions: anything previously indexed that is no
        // longer in the active snapshot.
        let toDelete = Set(lastIndexedTasks.keys).subtracting(activeById.keys)
        if !toDelete.isEmpty {
            index.deleteSearchableItems(withIdentifiers: Array(toDelete)) { error in
                if let error {
                    NSLog("[Apollo] Spotlight delete failed: %@",
                          error.localizedDescription)
                }
            }
        }

        lastIndexedTasks = activeById
    }

    private func composeDescription(for task: CUTask) -> String {
        var pieces: [String] = []
        if !task.status.isEmpty {
            pieces.append("Status: \(task.status.uppercased())")
        }
        if let due = task.dueDate {
            pieces.append("Vence: \(Self.dueFormatter.string(from: due))")
        }
        if let desc = task.description, !desc.isEmpty {
            // Trim very long descriptions — Spotlight gives more
            // weight to title/keywords anyway.
            let trimmed = desc.prefix(280)
            pieces.append(String(trimmed))
        }
        return pieces.joined(separator: " · ")
    }

    private func composeKeywords(for task: CUTask) -> [String] {
        var keywords: [String] = ["apollo", "tarefa", "clickup"]
        if !task.status.isEmpty { keywords.append(task.status) }
        // Tag names — searchable on their own ("urgent", "design").
        keywords.append(contentsOf: task.tags.map(\.name))
        // Assignee handles — lets `@joao` searches find the task.
        keywords.append(contentsOf: task.assignees.map(\.username))
        return keywords
    }
}
