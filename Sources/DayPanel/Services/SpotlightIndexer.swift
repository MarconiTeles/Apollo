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

    /// Last set of task IDs we indexed. Used to detect deletions —
    /// the next index pass diffs against this and removes any IDs
    /// that have disappeared from the live snapshot.
    private var lastIndexedIDs = Set<String>()

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
                self?.reindex(tasks: Array(dict.values))
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
        lastIndexedIDs.removeAll()
    }

    // MARK: - Private

    private func reindex(tasks: [CUTask]) {
        let active = tasks.filter { !$0.archived && !$0.isCompleted }
        let activeIDs = Set(active.map(\.id))

        // Build searchable items.
        let items: [CSSearchableItem] = active.map { task in
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

        // Detect deletions: anything previously indexed that is no
        // longer in the active snapshot.
        let toDelete = lastIndexedIDs.subtracting(activeIDs)
        if !toDelete.isEmpty {
            index.deleteSearchableItems(withIdentifiers: Array(toDelete)) { error in
                if let error {
                    NSLog("[Apollo] Spotlight delete failed: %@",
                          error.localizedDescription)
                }
            }
        }

        lastIndexedIDs = activeIDs
    }

    private func composeDescription(for task: CUTask) -> String {
        var pieces: [String] = []
        if !task.status.isEmpty {
            pieces.append("Status: \(task.status.uppercased())")
        }
        if let due = task.dueDate {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "pt_BR")
            fmt.dateStyle = .medium
            pieces.append("Vence: \(fmt.string(from: due))")
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
