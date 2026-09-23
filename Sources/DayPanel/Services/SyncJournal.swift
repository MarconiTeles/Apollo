import Foundation

/// Live record of what the current sync is actually doing, stage by stage.
///
/// `AppState.activeSyncCount` only says *that* something is in flight; the
/// loading scenes (`SyncLoadingSurface`) need to say *what*: which source is
/// being read, what already landed and how much. Kept out of `AppState` on
/// purpose — stage flips happen several times per sync and must only redraw
/// the loading scenes that observe this object, never the whole app.
@MainActor
final class SyncJournal: ObservableObject {
    static let shared = SyncJournal()

    enum Stage: String, CaseIterable, Codable {
        /// Statuses, members and tags of the active list.
        case structure
        /// Task payload (full sync or a list switch).
        case tasks
        /// Google Calendar events.
        case calendar
        /// Diff against the previous sync → Inbox notifications.
        case changes
    }

    enum State: Equatable {
        case pending
        case active
        /// `count` is the number of items that landed, when meaningful.
        case done(count: Int?)
        /// Served from the in-session cache — nothing had to be fetched.
        case cached(count: Int?)
        case failed
        /// Source not connected / not part of this run.
        case skipped
    }

    @Published private(set) var states: [Stage: State] = [:]
    /// Items received so far while `tasks` is active (streamed list pages).
    @Published private(set) var streamedTasks: Int = 0
    @Published private(set) var startedAt: Date?
    @Published private(set) var finishedAt: Date?
    /// True once any full sync of this session completed — before that the
    /// Inbox has nothing to compare against and must say so.
    @Published private(set) var hasCompletedSync = false

    func state(of stage: Stage) -> State { states[stage] ?? .pending }

    /// A full sync is starting. Stages outside `stages` are marked skipped.
    func beginRun(stages: Set<Stage>) {
        var next: [Stage: State] = [:]
        for stage in Stage.allCases {
            next[stage] = stages.contains(stage) ? .pending : .skipped
        }
        states = next
        streamedTasks = 0
        startedAt = Date()
        finishedAt = nil
    }

    func mark(_ stage: Stage, _ state: State) {
        guard states[stage] != state else { return }
        if startedAt == nil { startedAt = Date() }
        states[stage] = state
        if stage == .tasks, state == .active { streamedTasks = 0 }
    }

    func streamed(tasks count: Int) {
        if streamedTasks != count { streamedTasks = count }
    }

    func finishRun() {
        finishedAt = Date()
        hasCompletedSync = true
    }

    /// A list switch fetches tasks only; the other stages keep their state.
    func beginListFetch() {
        if startedAt == nil || finishedAt != nil {
            startedAt = Date()
            finishedAt = nil
        }
        mark(.tasks, .active)
    }

    /// Marks every stage still `active` as failed (the run threw midway).
    func failActiveStages() {
        for (stage, state) in states where state == .active {
            states[stage] = .failed
        }
    }
}
