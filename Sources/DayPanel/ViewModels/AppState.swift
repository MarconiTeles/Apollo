import Foundation
import Combine
import AppKit
import SwiftUI   // for withAnimation in openNotificationTarget
import ReviewKit // ReviewHandoff (inline review payload codec)

final class AppState: ObservableObject {

    // MARK: - Core data
    //
    // The two `@Published` collections have `didSet` hooks that rebuild
    // matching indices (`eventsByDay`, `tasksById`) below. Views read from
    // the indices so per-render filtering / linear-scan goes from
    // O(events × days) and O(tasks × visible-rows) down to O(1) lookups.

    @Published var events:            [CalendarEvent] = [] {
        didSet { rebuildEventIndex() }
    }
    @Published var tasks:             [CUTask]        = [] {
        didSet { rebuildTaskIndex() }
    }
    /// Events grouped by `startOfDay(startDate)` for the timeline.
    @Published private(set) var eventsByDay: [Date: [CalendarEvent]] = [:]

    /// Final per-day list the timeline actually renders —
    /// own events + shared-calendar overlays, merged and
    /// pre-sorted by start time. Built ONCE per change of
    /// `events`/`sharedEvents` (see `rebuildMergedEventIndex`)
    /// instead of being computed on every `AgendaDaySection`
    /// body re-eval. With a 60-day window and several shared
    /// calendars, the per-render cost was O(days × shared)
    /// per scroll frame; the cache makes the section's
    /// `events` lookup O(1).
    @Published private(set) var mergedEventsByDay: [Date: [CalendarEvent]] = [:]
    /// Roster of "contacts" derived from past + current calendar
    /// event attendees. Each entry is a unique (name, email)
    /// pair extracted from `events[*].attendees`. Used by the AI
    /// agent to resolve guest names ("convida o João") into the
    /// e-mail addresses needed by EventKit when creating events.
    /// Built alongside `eventsByDay` in `rebuildEventIndex`.
    @Published private(set) var calendarContacts: [CalendarContact] = []

    /// Google Workspace meeting rooms (resource calendars) seen
    /// as attendees on loaded events — emails ending in
    /// `@resource.calendar.google.com`. Powers the LOCAL field's
    /// room autocomplete so the integration matches Google
    /// Calendar's own room picker. Built in `rebuildEventIndex`.
    @Published private(set) var calendarRooms: [CalendarRoom] = []

    // MARK: - Shared (overlay) calendars
    //
    // Apollo can surface other people's calendars as ghost
    // rows on the timeline. Each entry in `sharedCalendars`
    // holds an email + a stable color, persisted in
    // UserDefaults. On every `sync()` the events for those
    // contacts are pulled (full detail when shared at "see
    // all event details", or opaque "Ocupado" blocks via
    // free/busy) and stored in `sharedEvents` keyed by
    // email — so the timeline can render multiple rows
    // tinted by contact without re-fetching on scroll.
    @Published var sharedCalendars: [SharedCalendar] = SharedCalendar.loadFromDefaults() {
        didSet {
            SharedCalendar.persist(sharedCalendars)
        }
    }
    @Published private(set) var sharedEvents: [String: [CalendarEvent]] = [:]
    /// Set of emails that returned 403 on `events.list` —
    /// for those we only have free/busy (no titles). Used by
    /// the timeline UI to show a "(somente disponibilidade)"
    /// hint next to the contact's name.
    @Published private(set) var sharedCalendarsLimitedAccess: Set<String> = []

    /// Lightweight contact record. Has just enough fields to
    /// support the AI's lookup paths (exact name, first-name,
    /// substring) and to surface as a row in any future "who's
    /// in your address book" UI.
    struct CalendarContact: Identifiable, Hashable {
        var id: String { email.lowercased() }
        let name: String
        let email: String
    }
    /// A bookable Google Workspace resource (meeting room). The
    /// `email` is the `@resource.calendar.google.com` address
    /// that must be added as an attendee for Google to actually
    /// book the room; `name` is the human label ("3. Sala…").
    struct CalendarRoom: Identifiable, Hashable {
        var id: String { email.lowercased() }
        let name: String
        let email: String
    }
    /// True for Google Workspace resource-calendar addresses.
    static func isRoomEmail(_ email: String) -> Bool {
        email.lowercased().hasSuffix("@resource.calendar.google.com")
    }
    /// Tasks keyed by id so a TaskRowView can read the latest version
    /// without scanning the whole array.
    @Published private(set) var tasksById:   [String: CUTask]        = [:]
    /// Cached partitions so the task list view doesn't recompute a filter
    /// of the whole array on every render (which used to happen because
    /// SwiftUI re-evaluates `body` aggressively during scrolling).
    @Published private(set) var pendingTasksCached:   [CUTask] = []
    @Published private(set) var completedTasksCached: [CUTask] = []

    /// Set of task ids whose subtask tree is currently
    /// expanded inline in the task list. When a task with
    /// children is expanded, its subtasks (and any expanded
    /// grandchildren, recursively) render as nested rows
    /// directly below it — same hierarchy view ClickUp
    /// shows in its main list.
    ///
    /// `didSet` invalidates the flatten cache so the next
    /// `flattenForList(_:)` recomputes — the cache key
    /// includes this set's identity so without invalidation
    /// the cache would just compare equal sets and serve
    /// stale output (the toggle wouldn't take effect).
    @Published var expandedSubtaskIds: Set<String> = [] {
        didSet {
            if oldValue != expandedSubtaskIds {
                flattenCacheKey = nil
            }
        }
    }

    /// Toggle the expanded state for a task with children.
    /// No-op if the task has no subtasks (avoids littering
    /// the set with leaves whose chevron isn't even visible).
    func toggleSubtaskExpansion(_ taskId: String) {
        guard !subtasks(of: taskId).isEmpty else { return }
        if expandedSubtaskIds.contains(taskId) {
            expandedSubtaskIds.remove(taskId)
        } else {
            expandedSubtaskIds.insert(taskId)
        }
    }

    /// Flatten a list of top-level tasks into a depth-aware
    /// row sequence — each parent emits one row at depth 0,
    /// and any task whose id is in `expandedSubtaskIds`
    /// recursively emits its visible descendants at
    /// `depth + 1`, depth-first. NSCollectionView consumes
    /// this flat list directly: subtasks are SEPARATE cells
    /// inserted between the parent and the next top-level
    /// task, so the framework's batch-update animation
    /// machinery handles inserts / deletes natively.
    ///
    /// Memoised on (`flattenCacheVersion`, top-level task
    /// ids, `expandedSubtaskIds`) — `@Published` properties
    /// unrelated to the task tree trigger view re-renders
    /// dozens of times per second; without this cache each
    /// one would re-traverse the tree.
    func flattenForList(_ tasks: [CUTask]) -> [TaskListRow] {
        let topIds = tasks.map(\.id)
        let key = (flattenCacheVersion, topIds, expandedSubtaskIds)
        if let cached = flattenCacheKey,
           cached.0 == key.0,
           cached.1 == key.1,
           cached.2 == key.2 {
            return flattenCacheValue
        }
        var out: [TaskListRow] = []
        out.reserveCapacity(tasks.count)
        for t in tasks {
            appendRows(of: t, depth: 0, into: &out)
        }
        // Mark the last row of each expanded subtree: a depth>0
        // row immediately followed by a top-level (depth 0) row,
        // or the final row. That row carries the hairline that
        // closes the subtree off from the next mother task.
        for i in out.indices where out[i].depth > 0 {
            let isLast = (i == out.count - 1) || out[i + 1].depth == 0
            if isLast { out[i].isLastInSubtree = true }
        }
        flattenCacheKey   = key
        flattenCacheValue = out
        return out
    }

    private func appendRows(of task: CUTask,
                            depth: Int,
                            into out: inout [TaskListRow]) {
        let kids = subtasks(of: task.id)
        out.append(TaskListRow(task: task,
                               depth: depth,
                               hasChildren: !kids.isEmpty,
                               isExpanded: expandedSubtaskIds.contains(task.id)))
        // Top-level (depth=0) honours `expandedSubtaskIds` —
        // the chevron on the parent card toggles inclusion of
        // its subtree. Once we're inside that subtree
        // (depth>=1) we ALWAYS recurse: there's no per-row
        // expand affordance on the inline `SubtaskRow`, so a
        // single click on the parent's chevron must reveal
        // children, grandchildren and beyond as a flat,
        // depth-indented list.
        let shouldRecurse = depth == 0
            ? expandedSubtaskIds.contains(task.id)
            : true
        if shouldRecurse {
            for kid in kids {
                appendRows(of: kid, depth: depth + 1, into: &out)
            }
        }
    }
    @Published var availableStatuses: [CUStatus]      = [] {
        didSet { rebuildDoneTargetIndex() }
    }
    @Published var availableMembers:  [CUMember]      = []
    @Published var availableTags:     [CUTask.Tag]    = []
    @Published var selectedTaskStatus: String?        = nil   // active status filter (nil = all)
    @Published var taskFilters:        TaskFilters    = TaskFilters()  // priority/assignee/tags/due

    /// Which task source the right column shows.
    ///   • `.activeList` — tasks of the single ClickUp list the
    ///     user picked (the historical behavior).
    ///   • `.myWork` — every task across the workspace assigned
    ///     to the connected user, regardless of list. Uses the
    ///     filtered team-tasks endpoint.
    /// Toggled from the toolbar; persisted so the choice
    /// survives relaunch.
    enum TaskViewMode: String { case activeList, myWork }
    /// Pinned to `.activeList` for now: picking a list must show
    /// ALL of its tasks, not only the ones assigned to the
    /// connected user. The toolbar "Meu trabalho" toggle was
    /// removed in the editorial redesign; until it's
    /// re-implemented we ignore any stale persisted `myWork`
    /// value so the user is never stranded in an assignee-
    /// filtered view with no way out. The `didSet` still
    /// persists, so a future re-added toggle keeps working.
    @Published var taskViewMode: TaskViewMode = .activeList {
        didSet {
            UserDefaults.standard.set(taskViewMode.rawValue,
                                      forKey: "dp_task_view_mode")
        }
    }
    /// Which dimension drives the horizontal pill bar. Switching this
    /// re-renders the bar (Status / Prioridade / Etiquetas / Responsável)
    /// and clears any active selection in the previous dimension so the
    /// list isn't filtered by something the user can't see anymore.
    @Published var taskPillDimension: TaskPillDimension = .status

    /// Event detail overlay — set when user taps an event pill. The
    /// origin frame is the pill's bounds in window coordinates so the
    /// overlay can scale from exactly that position.
    @Published var detailEvent:        CalendarEvent? = nil
    @Published var detailEventOrigin:  CGRect         = .zero
    /// Set to a calendar event to surface the global "transform
    /// into task" sheet (rendered by `ContentView`). Triggered
    /// from the event detail header AND the right-click menu on
    /// any timeline event card. Cleared when the sheet dismisses.
    @Published var pendingConversion:  CalendarEvent? = nil
    /// Task detail popup — opened from the new "open" button on a task
    /// row (the one above the inline-expand chevron). Same pattern as
    /// the event overlay so the popup scales out of the button.
    @Published var detailTask:         CUTask?       = nil
    @Published var detailTaskOrigin:   CGRect        = .zero
    /// Subtask popup that mounts ON TOP of `detailTask` when
    /// the user drills into a subtask from inside an already-
    /// open parent task popup. The parent stays rendered
    /// behind (no close animation), and the subtask overlay
    /// gets its own spring-zoom in/out. When empty the app
    /// behaves like before — only `detailTask` shows.
    ///
    /// Was a single `detailSubtaskOverlay: CUTask?`. Promoted
    /// to a stack so the user can drill into nested subtasks
    /// (sub-subtasks, etc. — ClickUp supports unlimited
    /// depth) and the back button pops one level at a time
    /// instead of jumping all the way back to the root.
    @Published var detailSubtaskStack: [CUTask] = []
    /// Convenience read accessor for the topmost subtask
    /// currently visible on screen. Read-only on purpose —
    /// callers should use `pushDetailSubtask` /
    /// `popDetailSubtask` / `closeAllDetailSubtasks` to
    /// mutate the stack so the semantics stay explicit.
    var detailSubtaskOverlay: CUTask? { detailSubtaskStack.last }

    /// Push a subtask onto the navigation stack — drills the
    /// detail view one level deeper. If the same task id is
    /// already on top (e.g. attachmentHydration mutates and
    /// passes a fresh copy), update in place instead of
    /// duplicating.
    func pushDetailSubtask(_ task: CUTask) {
        if detailSubtaskStack.last?.id == task.id {
            detailSubtaskStack[detailSubtaskStack.count - 1] = task
        } else {
            detailSubtaskStack.append(task)
        }
    }

    /// Pop one level. Used by the back button in
    /// `TaskDetailSheet` so the user retraces their path
    /// through nested subtasks instead of jumping all the
    /// way back to the root.
    func popDetailSubtask() {
        if !detailSubtaskStack.isEmpty {
            detailSubtaskStack.removeLast()
        }
    }

    /// Close every overlay at once. Used when the user
    /// dismisses the popup via Esc / tap-outside / close
    /// button — the entire chain collapses, regardless of
    /// depth.
    func closeAllDetailSubtasks() {
        detailSubtaskStack.removeAll()
    }
    @Published var syncStatus:        SyncStatus      = .idle
    @Published var isOnline:          Bool            = true
    @Published var selectedDate:      Date            = Date()
    @Published var showMockData:      Bool            = false
    /// Bumped every time the user clicks "Hoje" so the timeline scrolls to
    /// today even if `selectedDate` was already set to today (just on a
    /// different scroll position within the day).
    @Published var todayJumpToken:    Int             = 0

    // MARK: - Notifications
    //
    // Persistent log of in-app notifications shown in the bell-icon
    // popover, plus a transient `toastQueue` that the InAppToastOverlay
    // drains to render fade-in/out cards in the corner of the window.

    @Published private(set) var notifications: [AppNotification] = []
    @Published var toastQueue: [AppNotification] = []
    private let notifsKey = "dp_notifications_v1"
    private let notifsCap = 100

    /// Set when the user clicks a notification whose target is a task —
    /// TaskRowView observes this and auto-expands the matching row.
    /// Cleared once the row picks it up so a second click re-fires.
    @Published var expandedTaskId: String?

    // MARK: - Undo stack (Cmd+Z)
    //
    // Lightweight LIFO of "undo this last action" closures. Each
    // entry carries a human-readable label (used by toast feedback)
    // and an async closure that reverses the action. Currently
    // populated by status changes (swipe / DONE pill / picker) —
    // can be extended to title edits, priority changes, etc.
    //
    // Capped at 30 actions. Older entries drop off the bottom so
    // memory stays bounded on long sessions.

    /// One reversible action recorded on the undo stack.
    struct UndoableAction: Identifiable {
        let id = UUID()
        let label: String
        let undo: @MainActor () async -> Void
    }

    /// Backing store. Public reads are fine but mutations should
    /// always go through `pushUndo` / `undoLastAction` so the cap
    /// stays enforced.
    @Published private(set) var undoStack: [UndoableAction] = []

    /// Cap on undo history. Past this point the OLDEST entry is
    /// discarded on push so the array doesn't grow unbounded.
    private let undoStackCap = 30

    /// Append a new reversible action to the stack. The closure
    /// runs when the user invokes Cmd+Z and should restore the
    /// state mutated by the original action (e.g. revert a
    /// status change to its pre-change value).
    func pushUndo(label: String,
                  undo: @escaping @MainActor () async -> Void) {
        undoStack.append(UndoableAction(label: label, undo: undo))
        if undoStack.count > undoStackCap {
            undoStack.removeFirst(undoStack.count - undoStackCap)
        }
    }

    /// Pops the most recent action and runs its undo closure.
    /// No-op when the stack is empty. Surfaces a toast so the
    /// user gets feedback about what was reverted.
    @MainActor
    func undoLastAction() async {
        guard let last = undoStack.popLast() else { return }
        await last.undo()
        notify(.info, title: "Desfeito", message: last.label)
    }

    // MARK: - Diff-detection state
    //
    // Snapshots of the last known SERVER state of tasks/events. After a
    // local mutation we patch these so the diff doesn't re-fire for the
    // user's own action. Anything that doesn't match after a sync is
    // treated as a remote change and surfaced as a notification.

    private var previousTaskSnapshots:  [String: TaskSnapshot]?
    private var previousEventSnapshots: [String: EventSnapshot]?

    // MARK: - Comment notification state
    //
    // Per-task latest-seen comment id. Drives the new-comment
    // notifier — comments newer than the stored id fire a
    // banner; the field is updated after each diff so the
    // next sync only sees genuinely new posts.
    //
    // Persisted via UserDefaults so a comment posted while
    // Apollo was closed doesn't re-notify when the user
    // reopens the app — the latest-seen id was captured the
    // last time the app ran, and any post LATER than that is
    // genuinely new.
    /// Per-attachment last-seen `total_comments` count. Drives
    /// the proofing-comment notifier — every sync diffs the
    /// current `attachment.totalComments` against this baseline
    /// and fires a banner only when the number went UP on an
    /// attachment that the CURRENT user uploaded (we don't want
    /// to ping the user about strangers leaving comments on
    /// teammates' uploads). The map is rebuilt at the end of
    /// each sync so the next pass only catches genuinely new
    /// comments. Lives in-memory only — a stale entry surviving
    /// across launches just means the first sync after a
    /// restart re-baselines without notifications, which is
    /// the right call (the user already saw or missed those
    /// comments before quitting).
    private var lastSeenProofingCounts: [String: Int] = [:]

    private var lastSeenCommentByTask: [String: String] = [:]
    /// Cooldown timestamp per task. Without this, the 30s
    /// fast-sync would refetch every assigned/created task's
    /// comments twice a minute — wasted bandwidth and
    /// dangerously close to ClickUp's rate limit. Polls
    /// throttle to once per 60s per task.
    private var lastCommentPollAt: [String: Date] = [:]
    private static let commentSeenKey = "dp_lastSeenCommentByTask"

    // MARK: - Pending RSVPs
    //
    // After the user clicks Sim/Não/Talvez, we set their attendee status
    // optimistically so the pill repaints immediately. EventKit takes a
    // few seconds (sometimes minutes) to round-trip the response through
    // CalDAV → Google → CalDAV → EventKit. Without this overlay, the
    // very next sync clobbers the optimistic update with stale upstream
    // data and the pill flickers back to "needs response". We hold the
    // override for up to 5 minutes; once a sync returns matching data,
    // the entry is cleared.
    private struct PendingRSVP {
        let status: CalendarEvent.Attendee.Status
        let setAt:  Date
    }
    private var pendingRSVPs: [String: PendingRSVP] = [:]
    private let pendingRSVPTTL: TimeInterval = 300  // 5 minutes

    fileprivate struct TaskSnapshot: Equatable {
        let status:      String
        let assigneeIds: Set<Int>
        let dueDate:     Date?
        let priority:    Int
        let title:       String

        init(_ t: CUTask) {
            self.status      = t.status
            self.assigneeIds = Set(t.assignees.map(\.id))
            self.dueDate     = t.dueDate
            self.priority    = t.priority
            self.title       = t.title
        }
    }

    fileprivate struct EventSnapshot: Equatable {
        let title:         String
        let startDate:     Date
        let endDate:       Date
        let location:      String?
        let organizerName: String?

        init(_ e: CalendarEvent) {
            self.title         = e.title
            self.startDate     = e.startDate
            self.endDate       = e.endDate
            self.location      = e.location
            self.organizerName = e.organizerName
        }

        /// Same shape as `CalendarEvent.organizerSuffix` so a
        /// cancelled event (where the live model is gone) can still
        /// attribute the change to the organizer.
        var organizerSuffix: String? {
            guard let raw = organizerName else { return nil }
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : "Por \(name)"
        }
    }

    // MARK: - Preferences (UserDefaults)
    @Published var menuBarMode:         Bool
    @Published var autoSyncInterval:    Int      // minutes, 0 = disabled
    @Published var selectedCalendarIds: [String]
    /// Per-current-status mapping that the "DONE" hover-pill on a task row
    /// follows. Key = the task's *current* status name (e.g. "to do");
    /// value = the status to move it to when DONE is clicked. Configurable
    /// per category from Settings → Ação do botão Done.
    @Published var doneActionByStatus:  [String: String] = [:] {
        didSet { rebuildDoneTargetIndex() }
    }
    /// Pre-resolved DONE-target status keyed by the task's current
    /// status. Each value is the actual `CUStatus` to apply (the
    /// hex, the type, the display name) — already filtered against
    /// `availableStatuses` and falling through `__default__` →
    /// "review" search → nil. Each `TaskRowView` / `SubtaskRow` /
    /// `TaskChatPill` previously did this lookup itself by walking
    /// `availableStatuses` per render. With 30+ rows visible during
    /// scroll the same scan ran dozens of times per frame; now
    /// it's an O(1) Dictionary read against a snapshot rebuilt
    /// only when the source data actually changes.
    @Published private(set) var doneTargetByStatus: [String: CUStatus] = [:]
    /// Fallback target used when a task's status isn't in
    /// `doneTargetByStatus` (e.g. an exotic status the user
    /// hasn't configured). Same lookup as before but materialised
    /// once instead of per-row.
    @Published private(set) var doneTargetFallback: CUStatus? = nil
    /// Mirror in-app notifications to macOS Notification Center?
    /// Off by default — opt-in from Settings. First flip triggers a
    /// permission request via UNUserNotificationCenter.
    @Published var nativeNotificationsEnabled: Bool = false

    /// Free-text search query for tasks. Bound to the toolbar
    /// search field. Non-empty values narrow the list down to
    /// tasks whose title, description, status, assignee or tag
    /// contains the query (case-insensitive). Lives on AppState
    /// rather than the view so the search state survives panel
    /// resizing, status-pill changes, etc.
    @Published var searchQuery: String = ""

    /// Bumped every time something asks the UI to reveal the
    /// settings sheet (currently: the command palette's "Abrir
    /// configurações" entry). `ContentView` watches this token
    /// and flips its local `showSettings` flag whenever the
    /// counter changes — using a token instead of a `Bool`
    /// avoids the "stuck open" bug you'd get if the command
    /// palette set `showSettings = true` while ContentView's
    /// own state was already true.
    @Published var openSettingsToken: Int = 0
    func requestOpenSettings() { openSettingsToken += 1 }

    /// Same pattern as `openSettingsToken`, for the
    /// onboarding wizard. Bumped by the command palette's
    /// "Reabrir tutorial" entry so the user can revisit
    /// the swipe + ⌘K demos at any time without waiting
    /// for a connection state to drop. ContentView watches
    /// this and force-flips its local `showOnboarding` —
    /// bypassing the usual `needsCalendar/ClickUp/list`
    /// gating that would otherwise refuse to open the
    /// wizard for an already-connected user.
    @Published var openOnboardingToken: Int = 0
    func requestOpenOnboarding() { openOnboardingToken += 1 }

    // ── Popup-open signals ──────────────────────────────
    //
    // Two independent writers, one combined readable flag.
    // Splitting the writes keeps each owner from clobbering
    // the other's state — ContentView only knows about the
    // SwiftUI popups stacked inside its window, and the
    // CommandPaletteController only knows about its NSPanel.
    // Joining them into a single `anyPopupOpen` lets every
    // hover surface (SwiftUI `.onHover`, AppKit
    // `NSTrackingArea`-driven cells) read one value.
    //
    // `anyPopupOpen` is `@Published` rather than computed so
    // Combine sinks (e.g. inside `TaskRowCellItem`) can
    // subscribe to a single publisher; the `didSet`s on
    // each input keep it in sync without needing
    // `Publishers.CombineLatest`.

    /// Set by `ContentView` whenever its local stack of
    /// SwiftUI popups (FloatingModal sheets — task detail,
    /// event detail, settings, list picker, onboarding,
    /// new-event, new-task, welcome) toggles non-empty
    /// vs. empty.
    @Published var swiftUIPopupOpen: Bool = false {
        didSet { recomputeAnyPopupOpen() }
    }
    /// Set by `CommandPaletteController` when its borderless
    /// NSPanel opens / closes. Lives in a separate window,
    /// so SwiftUI's `.allowsHitTesting(!anyPopupOpen)` on
    /// the dashboard wouldn't catch it without this signal.
    @Published var commandPaletteOpen: Bool = false {
        didSet { recomputeAnyPopupOpen() }
    }

    /// True iff ANY popup surface is up. Read by hover
    /// handlers across SwiftUI + AppKit to short-circuit
    /// hover visuals on the content sitting behind a popup.
    /// Updated by `recomputeAnyPopupOpen`.
    @Published private(set) var anyPopupOpen: Bool = false

    private func recomputeAnyPopupOpen() {
        let next = swiftUIPopupOpen || commandPaletteOpen
        if anyPopupOpen != next { anyPopupOpen = next }
    }

    // MARK: - Services
    //
    // Calendar source-of-truth: Google Calendar via REST API
    // (see `googleCalendar` below). EventKit was removed in
    // favour of a single canonical path — keeping both led to
    // race conditions where the EventKit mirror lagged behind
    // the Google API by 30-60s on event creation/edit/delete,
    // and EventKit on macOS can't transmit attendees, so the
    // whole "invitations" feature only ever worked through
    // Google. Do NOT reintroduce CalendarService.
    let clickUpAuthService = ClickUpAuthService()
    let networkMonitor     = NetworkMonitor()
    /// OAuth + Google Calendar API client. Sole calendar
    /// backend now. Reads, writes, deletes and RSVPs all
    /// route through this service.
    let googleAuth         = GoogleAuthService()
    lazy var googleCalendar: GoogleCalendarService = GoogleCalendarService(auth: googleAuth)
    /// In-app AI agent. Reads tasks/events from this AppState and
    /// answers user questions via the configured LLM provider.
    /// Backend (Gemini cloud / Ollama local) is read from
    /// UserDefaults at init and is switchable via Settings.
    let aiAgent            = AIAgentService()

    private let cache       = CacheManager()
    private lazy var cuSvc: ClickUpService = ClickUpService(auth: clickUpAuthService)
    /// Public accessor for the ClickUp service so the AI agent's
    /// fetch-on-demand actions (list workspaces, deep-fetch a
    /// task, etc.) can talk to ClickUp without `AppState`
    /// growing wrapper methods for every read.
    var clickUpService: ClickUpService { cuSvc }

    private var cancellables         = Set<AnyCancellable>()
    private var syncTimerCancellable: AnyCancellable?
    /// Faster polling that runs only while the app window is in focus —
    /// catches ClickUp-side edits (status changes, new tasks) within ~30s
    /// without burning the long-interval timer.
    private var fastSyncCancellable:  AnyCancellable?

    /// Drives the upcoming-event / due-soon-task reminder check on a
    /// 60-second cadence. Independent of the sync timer so reminders
    /// keep firing even while polling is paused.
    private var reminderTickerCancellable: AnyCancellable?
    /// IDs that already triggered a reminder this session — kept in
    /// memory only (rebuilt on launch) but pruned every tick so an
    /// item that gets pushed back out of the window can re-fire later.
    private var firedEventReminders: Set<String> = []
    private var firedTaskReminders:  Set<String> = []
    /// How far ahead we look. Conservative defaults that match what
    /// users typically expect from "in a few minutes" notifications;
    /// can be exposed as preferences later if needed.
    private let eventReminderLead: TimeInterval = 10 * 60   // 10 minutes
    private let taskReminderLead:  TimeInterval = 60 * 60   // 1 hour

    // MARK: - Init

    init() {
        menuBarMode         = UserDefaults.standard.bool(forKey: "dp_menuBarMode")
        let saved           = UserDefaults.standard.object(forKey: "dp_autoSyncInterval") as? Int
        autoSyncInterval    = saved ?? 5
        selectedCalendarIds = UserDefaults.standard.stringArray(forKey: "dp_selectedCalendarIds") ?? ["primary"]
        // Restore the comment-seen ledger so a comment posted
        // during the time Apollo was closed doesn't fire a
        // duplicate notification on relaunch (the previous
        // session's latest-seen id was persisted and any new
        // comment is correctly compared against it).
        if let stored = UserDefaults.standard.dictionary(forKey: Self.commentSeenKey)
            as? [String: String] {
            lastSeenCommentByTask = stored
        }
        // Load per-status DONE-action mapping (JSON {currentStatus: targetStatus}).
        if let data = UserDefaults.standard.data(forKey: "dp_doneActionByStatus"),
           let map  = try? JSONDecoder().decode([String: String].self, from: data) {
            doneActionByStatus = map
        }
        // Migrate legacy single-value setting (`dp_doneActionStatus`) into
        // the new per-status map so existing users don't lose their pick.
        else if let legacy = UserDefaults.standard.string(forKey: "dp_doneActionStatus") {
            doneActionByStatus = ["__default__": legacy]
            UserDefaults.standard.removeObject(forKey: "dp_doneActionStatus")
        }
        // Native notifications default to ON — `UserDefaults.bool` would
        // return `false` if the key was never set, which made the
        // feature silently opt-in. Detect "never set" explicitly so
        // first-launch users get macOS banners as soon as macOS grants
        // permission.
        if let stored = UserDefaults.standard.object(forKey: "dp_nativeNotifs") as? Bool {
            nativeNotificationsEnabled = stored
        } else {
            nativeNotificationsEnabled = true
            UserDefaults.standard.set(true, forKey: "dp_nativeNotifs")
        }
        loadNotifications()
        updateDockBadge()

        // Request macOS notification authorization eagerly when the
        // user hasn't been asked yet. Silent if already authorized
        // or already denied — denial flips our preference off so
        // we stop trying.
        Task { @MainActor in
            await self.bootstrapNativeNotificationAuthorization()
        }
    }

    /// On first launch (or whenever the macOS auth status is still
    /// `.notDetermined`), request authorization from
    /// `UNUserNotificationCenter`. If the user denies, flip our local
    /// preference off so the next sync doesn't try to send banners
    /// that won't be delivered anyway.
    @MainActor
    private func bootstrapNativeNotificationAuthorization() async {
        let status = await NativeNotifier.shared.authorizationStatus()
        NSLog("[Apollo] bootstrap auth status=%d localFlag=%d", status.rawValue, nativeNotificationsEnabled ? 1 : 0)
        switch status {
        case .authorized, .provisional:
            // System already granted — make sure our local toggle
            // reflects that, even if a previous launch left it off.
            // Also clear any stale `userOptedOut` on the notifier
            // singleton (it reads UserDefaults at init time, so a
            // launch before today's fix could have left it `true`).
            if !nativeNotificationsEnabled {
                nativeNotificationsEnabled = true
                UserDefaults.standard.set(true, forKey: "dp_nativeNotifs")
            }
            NativeNotifier.shared.userOptedOut = false
        case .notDetermined:
            // Only ask once. If the user has explicitly turned the
            // toggle off, respect that and don't prompt.
            guard nativeNotificationsEnabled else {
                NativeNotifier.shared.userOptedOut = true
                return
            }
            let granted = await NativeNotifier.shared.requestAuthorization()
            if granted {
                NativeNotifier.shared.userOptedOut = false
            } else {
                nativeNotificationsEnabled = false
                UserDefaults.standard.set(false, forKey: "dp_nativeNotifs")
                NativeNotifier.shared.userOptedOut = true
            }
        case .denied:
            // User has denied at the OS level. Reflect locally so
            // we stop trying to send banners that won't be delivered.
            if nativeNotificationsEnabled {
                nativeNotificationsEnabled = false
                UserDefaults.standard.set(false, forKey: "dp_nativeNotifs")
            }
            NativeNotifier.shared.userOptedOut = true
        default:
            break
        }
    }

    /// Deep-links the user to the macOS Notifications pane in
    /// System Settings, scrolled to Apollo's row when possible.
    /// Used when permissions need to be re-granted manually
    /// (after a previous deny, the system prompt never re-fires).
    static func openSystemNotificationsSettings() {
        // Try Apollo-specific deep link first (macOS 13+); fall
        // back to the general Notifications pane if the bundle
        // ID isn't recognised by the URL handler.
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleId)",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for raw in candidates {
            if let url = URL(string: raw) {
                if NSWorkspace.shared.open(url) { return }
            }
        }
    }

    func setNativeNotificationsEnabled(_ value: Bool) {
        nativeNotificationsEnabled = value
        UserDefaults.standard.set(value, forKey: "dp_nativeNotifs")
        // Sync the singleton's silence flag immediately. We no
        // longer gate `notify()` on `nativeNotificationsEnabled`
        // (the macOS auth status is the canonical gate), so the
        // user-facing toggle takes effect through this property.
        NativeNotifier.shared.userOptedOut = !value
        if value {
            // Trigger system permission prompt the first time the user
            // toggles it on. After the user denies it ONCE, macOS won't
            // ever re-show the prompt — `requestAuthorization` just
            // returns false silently. In that case we deep-link them
            // straight to the Notifications pane in System Settings
            // since that's the only place they can flip it back on.
            Task {
                let statusBefore = await NativeNotifier.shared.authorizationStatus()
                let granted = await NativeNotifier.shared.requestAuthorization()
                if !granted {
                    notify(.warning,
                           title: "Permissão negada",
                           message: "Abrindo Configurações do Sistema → Notificações.")
                    // If the prompt was simply suppressed (user
                    // denied previously), guide them straight to
                    // the system pane so the toggle has somewhere
                    // to go. Skipped on `.notDetermined` →
                    // `.denied` transitions where the user just
                    // saw and answered the live prompt — opening
                    // settings on top of their fresh "no" would
                    // feel pushy.
                    if statusBefore == .denied {
                        await MainActor.run {
                            Self.openSystemNotificationsSettings()
                        }
                    }
                }
            }
        } else {
            // Explicit opt-out: drop any banners we already posted
            // so the user sees the toggle take effect immediately.
            NativeNotifier.shared.removeAllDelivered()
        }
    }

    // MARK: - Notification API

    var unreadNotifications: Int {
        notifications.lazy.filter { !$0.read }.count
    }

    /// Public entry point — call this from anywhere with a kind + title
    /// (and optional message). Surfaces a toast immediately AND adds to
    /// the persistent log behind the bell icon.
    ///
    /// `title` is the bold headline (the entity's name when the
    /// notification targets a task/event), `subtitle` is the action
    /// verb that explains *what* happened, and `message` carries the
    /// supplementary details. macOS Notification Center renders
    /// title/subtitle/body distinctly, so all three are surfaced
    /// natively when populated.
    func notify(_ kind: AppNotification.Kind,
                title: String,
                subtitle: String? = nil,
                message: String? = nil,
                messageHighlights: [AppNotification.Highlight]? = nil,
                targetKind: AppNotification.TargetKind? = nil,
                targetId:   String? = nil) {
        let n = AppNotification(kind: kind,
                                title: title,
                                subtitle: subtitle,
                                message: message,
                                messageHighlights: messageHighlights,
                                targetKind: targetKind,
                                targetId:   targetId)
        Task { @MainActor in
            notifications.insert(n, at: 0)
            if notifications.count > notifsCap {
                notifications = Array(notifications.prefix(notifsCap))
            }
            toastQueue.append(n)
            saveNotifications()
            updateDockBadge()
            // Always attempt the native banner. `NativeNotifier.send`
            // gates internally on the live macOS authorization status
            // (the source of truth) — relying on a separately tracked
            // flag here introduced a class of state-sync bugs where
            // `nativeNotificationsEnabled` could be stale (e.g. the
            // user granted permission at the OS level but the local
            // mirror still read `false` from a previous launch). The
            // local toggle is now respected as an explicit opt-out
            // only via `setNativeNotificationsEnabled(false)`, which
            // also clears any in-flight banners.
            NSLog("[Apollo] notify -> %@ (%@) target=%@ id=%@",
                  title,
                  String(describing: kind),
                  targetKind.map(String.init(describing:)) ?? "none",
                  targetId ?? "—")
            // Resolve the per-row tint exactly as
            // `NotificationsCenterView.targetTint` does, so the macOS
            // banner thumbnail uses the same colour as the in-app
            // entry: tasks → status pill colour, events → calendar
            // colour, fallback to the kind's static tint.
            let tintHex: String? = {
                switch targetKind {
                case .task:
                    if let id = targetId, let task = self.tasksById[id] {
                        return task.statusDisplayHex
                    }
                case .event:
                    if let id = targetId,
                       let event = self.events.first(where: { $0.id == id }) {
                        return event.colorHex
                    }
                case .none:
                    break
                }
                return nil
            }()
            NativeNotifier.shared.send(
                appNotifId: n.id,
                kind:       kind,
                title:      title,
                subtitle:   subtitle,
                body:       message,
                targetKind: targetKind,
                targetId:   targetId,
                tintHex:    tintHex
            )
        }
    }

    /// Resolves the canonical accent hex for a status name —
    /// case-insensitive, against the workspace's
    /// `availableStatuses` roster. Returns nil for unknown
    /// names so callers can fall back to a default colour
    /// (often the live task's `statusDisplayHex`, which still
    /// works even when the diff is comparing against a
    /// since-renamed status).
    private func hexForStatusName(_ name: String) -> String? {
        let lc = name.lowercased()
        return availableStatuses.first { $0.status.lowercased() == lc }?.displayHex
    }

    /// Looks up the in-app notification matching a UNNotification id
    /// and routes it through the same `openNotificationTarget` flow
    /// used by clicking the bell-popup row. Called by AppDelegate
    /// when the user clicks a macOS Notification Center banner.
    @MainActor
    func handleNativeNotificationTap(appNotifId: UUID?,
                                     targetKindRaw: String?,
                                     targetId: String?) {
        // Activate the app + bring the window forward.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)

        if let id = appNotifId, let n = notifications.first(where: { $0.id == id }) {
            openNotificationTarget(n)
            return
        }
        // Fallback: build a minimal notification stand-in from the
        // userInfo so click-through still works for banners that
        // outlived the in-app row (e.g. user cleared notifications).
        let kind: AppNotification.TargetKind?
        switch targetKindRaw {
        case "task":  kind = .task
        case "event": kind = .event
        default:      kind = nil
        }
        guard let kind, let id = targetId else { return }
        openNotificationTarget(
            AppNotification(kind: .info, title: "",
                            targetKind: kind, targetId: id)
        )
    }

    /// Convenience overloads with a typed target.
    func notifyTask(_ kind: AppNotification.Kind,
                    title: String,
                    subtitle: String? = nil,
                    message: String? = nil,
                    messageHighlights: [AppNotification.Highlight]? = nil,
                    taskId: String) {
        notify(kind, title: title, subtitle: subtitle, message: message,
               messageHighlights: messageHighlights,
               targetKind: .task, targetId: taskId)
    }

    func notifyEvent(_ kind: AppNotification.Kind,
                     title: String,
                     subtitle: String? = nil,
                     message: String? = nil,
                     eventId: String) {
        notify(kind, title: title, subtitle: subtitle, message: message,
               targetKind: .event, targetId: eventId)
    }

    /// Called when the user clicks a notification row. Opens the related
    /// task / event popup if the target still exists.
    func openNotificationTarget(_ n: AppNotification) {
        markNotificationRead(n.id)
        guard let kind = n.targetKind, let id = n.targetId else { return }
        Task { @MainActor in
            switch kind {
            case .event:
                if let event = events.first(where: { $0.id == id }) {
                    detailEventOrigin = .zero          // origin unknown — popup centres
                    withAnimation(.spring(duration: 0.45, bounce: 0.3)) {
                        detailEvent = event
                    }
                }
            case .task:
                // Open the focused popup version instead of inline
                // expansion — `TaskDetailSheet` gives the user a full
                // editing surface (metadata + description + chat-style
                // comments column) without forcing the surrounding
                // task list to scroll-to-row + push siblings down.
                if let task = tasksById[id] {
                    detailTaskOrigin = .zero          // origin unknown — popup centres
                    withAnimation(.spring(duration: 0.45, bounce: 0.30)) {
                        detailTask = task
                    }
                }
            }
        }
    }

    /// Surface a task popup from outside the dashboard — used by
    /// the Spotlight deep-link, AI agent CREATE_TASK echoes, and
    /// any other "show task X now" trigger. No-op if the id is
    /// unknown (the task may not have been fetched yet on a fresh
    /// launch; the caller can retry after the next sync).
    func openTask(id: String) {
        Task { @MainActor in
            guard let task = tasksById[id] else { return }
            detailTaskOrigin = .zero
            withAnimation(.spring(duration: 0.45, bounce: 0.30)) {
                detailTask = task
            }
        }
    }

    func markNotificationRead(_ id: UUID) {
        Task { @MainActor in
            if let idx = notifications.firstIndex(where: { $0.id == id }) {
                notifications[idx].read = true
                saveNotifications()
                updateDockBadge()
            }
        }
    }

    func markAllNotificationsRead() {
        Task { @MainActor in
            for i in notifications.indices { notifications[i].read = true }
            saveNotifications()
            updateDockBadge()
        }
    }

    func clearAllNotifications() {
        Task { @MainActor in
            // Drop any matching banners from macOS Notification Center
            // so the system tray stays in sync with the in-app list.
            let ids = notifications.map { $0.id }
            for id in ids { NativeNotifier.shared.remove(appNotifId: id) }
            notifications.removeAll()
            saveNotifications()
            updateDockBadge()
        }
    }

    func removeNotification(_ id: UUID) {
        Task { @MainActor in
            NativeNotifier.shared.remove(appNotifId: id)
            notifications.removeAll { $0.id == id }
            saveNotifications()
            updateDockBadge()
        }
    }

    private func loadNotifications() {
        guard let data = UserDefaults.standard.data(forKey: notifsKey),
              let list = try? JSONDecoder().decode([AppNotification].self, from: data)
        else { return }
        notifications = list
    }

    private func saveNotifications() {
        if let data = try? JSONEncoder().encode(notifications) {
            UserDefaults.standard.set(data, forKey: notifsKey)
        }
    }

    private func updateDockBadge() {
        let n = unreadNotifications
        DispatchQueue.main.async {
            NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
        }
    }

    // MARK: - Index rebuilding (perf: O(1) lookups instead of O(n) per render)

    private func rebuildEventIndex() {
        let cal = Calendar.current
        var map: [Date: [CalendarEvent]] = [:]
        map.reserveCapacity(events.count)
        // Contacts harvested from event attendees. A flat
        // dictionary keyed by lowercased email avoids
        // duplicates when the same person is on multiple
        // events. Names are kept as-typed (the first time we
        // see each email) so display order is the user's own.
        var contactsByEmail: [String: String] = [:]
        // Resource calendars (meeting rooms) harvested the same
        // way — kept OUT of `contactsByEmail` so rooms don't
        // pollute the people roster (AI @-mentions, guest
        // picker) and instead feed the LOCAL room autocomplete.
        var roomsByEmail: [String: String] = [:]

        for e in events {
            let day = cal.startOfDay(for: e.startDate)
            map[day, default: []].append(e)

            for attendee in e.attendees {
                guard let email = attendee.email,
                      !email.isEmpty
                else { continue }
                let key = email.lowercased()
                if Self.isRoomEmail(email) {
                    if roomsByEmail[key] == nil {
                        // Google sends the room's label as
                        // displayName; fall back to the local
                        // part if a name is somehow missing.
                        roomsByEmail[key] = attendee.name.isEmpty
                            ? String(email.split(separator: "@").first
                                ?? "Sala")
                            : attendee.name
                    }
                    continue
                }
                guard !attendee.name.isEmpty else { continue }
                if contactsByEmail[key] == nil {
                    contactsByEmail[key] = attendee.name
                }
            }
        }
        // Sort once per bucket so DaySection doesn't re-sort every render.
        for k in map.keys {
            map[k]?.sort { $0.startDate < $1.startDate }
        }
        eventsByDay = map

        // Materialise the contact roster sorted by name —
        // alphabetical reads predictably in the AI prompt and
        // (eventually) any future contacts UI.
        calendarContacts = contactsByEmail
            .map { (email, name) in
                CalendarContact(name: name, email: email)
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }

        calendarRooms = roomsByEmail
            .map { (email, name) in
                CalendarRoom(name: name, email: email)
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }

        rebuildMergedEventIndex()
    }

    /// Rebuilds `mergedEventsByDay` from `eventsByDay` plus
    /// every overlay roster in `sharedEvents`. Should be
    /// called after either index changes — `rebuildEventIndex`
    /// calls it for own-event mutations, the shared-calendar
    /// sync path calls it after fetching/clearing rosters.
    /// O(N) over total events; cheaper than letting the
    /// timeline section recompute the merge on every render.
    func rebuildMergedEventIndex() {
        let cal = Calendar.current
        var merged = eventsByDay   // start with the user's own bucketed events
        for arr in sharedEvents.values {
            for ev in arr {
                let day = cal.startOfDay(for: ev.startDate)
                merged[day, default: []].append(ev)
            }
        }
        // Sort each bucket once so the section's body just
        // returns the cached array as-is.
        for k in merged.keys {
            merged[k]?.sort { $0.startDate < $1.startDate }
        }
        mergedEventsByDay = merged
    }

    /// Materialise the DONE-target lookup table. Runs whenever
    /// either source signal mutates (`availableStatuses` or
    /// `doneActionByStatus`). The cost is paid once per change;
    /// every row read is then O(1).
    ///
    /// New default behaviour: DONE advances the task to the
    /// **next status in the list's natural workflow** as
    /// configured in ClickUp (BACKLOG → TO DO → DOING →
    /// REVIEW → LIBERADO → CONCLUÍDO). The user's per-status
    /// override map (`doneActionByStatus` from Settings) still
    /// wins when it has an entry for the current status, so
    /// previously-customised mappings don't get silently
    /// overridden.
    ///
    /// Resolution order:
    ///   1. User-configured target for the task's current status
    ///   2. Next status in the ClickUp workflow (NEW default)
    ///   3. User-configured `__default__` fallback
    ///   4. Last status in the workflow (so a task already at
    ///      the end still has a sensible "complete" action)
    ///   5. nil (no target → DONE button disabled on that row)
    private func rebuildDoneTargetIndex() {
        // Build a fast name → status index over the available
        // statuses, then walk the configured map and resolve
        // each entry against it.
        var byName: [String: CUStatus] = [:]
        byName.reserveCapacity(availableStatuses.count)
        for s in availableStatuses { byName[s.status] = s }

        var resolved: [String: CUStatus] = [:]
        // Seed from the workflow-derived defaults so EVERY
        // status that has a successor gets a valid DONE target
        // out of the box — no Settings configuration required.
        for (idx, s) in availableStatuses.enumerated()
        where idx < availableStatuses.count - 1 {
            resolved[s.status] = availableStatuses[idx + 1]
        }
        // Then overlay the user's explicit per-status mappings
        // so any custom configuration in Settings still wins.
        for (currentStatus, targetName) in doneActionByStatus
        where currentStatus != "__default__" {
            if let target = byName[targetName] {
                resolved[currentStatus] = target
            }
        }
        doneTargetByStatus = resolved

        // Fallback chain for statuses NOT in `resolved` (e.g.
        // tasks whose current status was renamed or removed
        // from the list config since they were last touched).
        if let defaultName = doneActionByStatus["__default__"],
           let target = byName[defaultName] {
            doneTargetFallback = target
        } else if let last = availableStatuses.last {
            // Default to the terminal status in the workflow
            // — usually CONCLUÍDO/CANCELADO. Better than the
            // old "find a status with 'review' in name" which
            // misfired on lists without a review stage.
            doneTargetFallback = last
        } else {
            doneTargetFallback = nil
        }
    }

    private func rebuildTaskIndex() {
        var map: [String: CUTask] = [:]
        map.reserveCapacity(tasks.count)
        var pend: [CUTask] = []
        var done: [CUTask] = []
        var children: [String: [String]] = [:]   // parentId → child ids
        // Pill-bar counters — accumulated in the same pass
        // so we don't walk `tasks` four extra times in
        // `TaskListView.statusPills/priorityPills/tagCounts/
        // assigneeCounts`. Each `Dictionary(grouping:by:)`
        // call there was running once per `body` re-eval,
        // which the filter bar does on every AppState
        // mutation (hover, scroll, detail popup) — i.e.,
        // many times per second during scroll. Moving the
        // O(n) walk here means the pill bar only needs to
        // read pre-built dicts.
        var statusCt: [String: Int] = [:]
        var priorityCt: [Int: Int] = [:]
        var tagCt: [String: Int] = [:]
        var assigneeCt: [Int: Int] = [:]
        pend.reserveCapacity(tasks.count)
        for t in tasks {
            map[t.id] = t
            if t.parentId == nil {
                if t.isCompleted { done.append(t) } else { pend.append(t) }
            }
            if let pid = t.parentId {
                children[pid, default: []].append(t.id)
            }
            // Counter accumulation. Pill bar counts ONLY
            // top-level pending tasks for status / priority
            // / tags / assignees (matches the previous
            // logic in `TaskListView`, which used
            // `pendingTasks` for assignee counts and
            // `appState.tasks` for the others — but the
            // user only ever sees parent rows in the
            // filter pills, so we standardise on top-level
            // + uncompleted across all four dimensions).
            guard t.parentId == nil, !t.isCompleted else { continue }
            statusCt[t.status, default: 0] += 1
            priorityCt[t.priority, default: 0] += 1
            for tag in t.tags {
                tagCt[tag.name, default: 0] += 1
            }
            for a in t.assignees {
                assigneeCt[a.id, default: 0] += 1
            }
        }
        tasksById            = map
        pendingTasksCached   = sortByDeadlineThenPriority(pend)
        completedTasksCached = done
        subtasksByParentId   = children
        taskStatusCounts     = statusCt
        taskPriorityCounts   = priorityCt
        taskTagCounts        = tagCt
        taskAssigneeCounts   = assigneeCt

        // Pre-sort each parent's subtasks ONCE here instead
        // of re-sorting on every `subtasks(of:)` call. The
        // task list view's tree-flatten calls
        // `subtasks(of:)` recursively across hundreds of
        // parents per render — without this cache that's
        // O(n log n) per parent per render, which dominated
        // scroll/expand FPS. With the cache it's O(1)
        // dictionary lookup.
        var sortedCache: [String: [CUTask]] = [:]
        sortedCache.reserveCapacity(children.count)
        for (pid, ids) in children {
            let resolved = ids.compactMap { map[$0] }
            sortedCache[pid] = resolved.sorted(by: subtaskOrdering)
        }
        sortedSubtasksCache = sortedCache

        // Invalidate the flatten cache — task tree changed.
        flattenCacheVersion &+= 1
    }

    /// Pre-built pill-bar counters. Re-computed in
    /// `rebuildTaskIndex` whenever `tasks` mutates; cells
    /// that read these never trigger a fresh
    /// `Dictionary(grouping:by:)` on the main thread.
    /// Scope: TOP-LEVEL, NON-COMPLETED tasks only — the
    /// filter pills surface "what's in front of me to
    /// work on", so subtasks + done tasks don't pollute
    /// the counts.
    @Published private(set) var taskStatusCounts:   [String: Int] = [:]
    @Published private(set) var taskPriorityCounts: [Int:    Int] = [:]
    @Published private(set) var taskTagCounts:      [String: Int] = [:]
    @Published private(set) var taskAssigneeCounts: [Int:    Int] = [:]

    /// Pre-sorted subtasks per parent id. Built once in
    /// `rebuildTaskIndex` (which fires whenever `tasks`
    /// mutates) so `subtasks(of:)` can be O(1).
    private var sortedSubtasksCache: [String: [CUTask]] = [:]

    /// Bumps every time the task tree changes — combined
    /// with `expandedSubtaskIds`'s identity, used to
    /// memoize `flattenForList`'s output.
    private var flattenCacheVersion: Int = 0
    private var flattenCacheKey: (Int, [String], Set<String>)?
    private var flattenCacheValue: [TaskListRow] = []

    /// Stable comparator extracted from the previous inline
    /// closure so both the per-render call site and the
    /// pre-sort cache share it.
    private func subtaskOrdering(_ lhs: CUTask, _ rhs: CUTask) -> Bool {
        switch (lhs.dueDate, rhs.dueDate) {
        case let (l?, r?):
            if l != r { return l < r }
        case (_?, nil): return true
        case (nil, _?): return false
        default:        break
        }
        switch (lhs.dateCreated, rhs.dateCreated) {
        case let (l?, r?):
            if l != r { return l < r }
        case (_?, nil): return true
        case (nil, _?): return false
        default:        break
        }
        return lhs.title < rhs.title
    }

    /// Adjacency map (parent task id → child task ids) rebuilt
    /// every time `tasks` changes. Used by the task detail
    /// popup's Subtarefas section to render children inline.
    @Published private(set) var subtasksByParentId: [String: [String]] = [:]

    /// Returns the subtasks of `parentId` as full `CUTask`
    /// instances, sorted by **due date** (earliest first).
    /// Subtasks without a due date sink to the end of the
    /// list; among those, ties break by creation date
    /// (oldest first), then alphabetical title — so the
    /// ordering stays stable across renders even when the
    /// data is sparse. Was sorted by creation date alone,
    /// which made the list read randomly relative to
    /// deadlines (29 abr → 4 mai → 30 abr → 5 mai…) and
    /// hid the user's actual time pressure.
    func subtasks(of parentId: String) -> [CUTask] {
        // O(1) — pre-sorted cache built in `rebuildTaskIndex`.
        sortedSubtasksCache[parentId] ?? []
    }


    // MARK: - Preference setters (persist + react)

    func setMenuBarMode(_ value: Bool) {
        menuBarMode = value
        UserDefaults.standard.set(value, forKey: "dp_menuBarMode")
    }

    func setAutoSyncInterval(_ value: Int) {
        autoSyncInterval = value
        UserDefaults.standard.set(value, forKey: "dp_autoSyncInterval")
        restartAutoSync()
    }

    func setSelectedCalendars(_ ids: [String]) {
        selectedCalendarIds = ids.isEmpty ? ["primary"] : ids
        UserDefaults.standard.set(selectedCalendarIds, forKey: "dp_selectedCalendarIds")
    }

    /// Sets (or clears, when target == nil) the DONE-button target for a
    /// specific current status. Persists the whole map as JSON.
    func setDoneAction(forStatus current: String, to target: String?) {
        if let target {
            doneActionByStatus[current] = target
        } else {
            doneActionByStatus.removeValue(forKey: current)
        }
        if let data = try? JSONEncoder().encode(doneActionByStatus) {
            UserDefaults.standard.set(data, forKey: "dp_doneActionByStatus")
        }
    }

    // MARK: - Lifecycle

    func initialize() async {
        // Wire the AI agent so its system prompt can read live
        // tasks/events from this AppState.
        await MainActor.run { aiAgent.bind(to: self) }

        // Forward `aiAgent.objectWillChange` up to AppState so
        // SwiftUI views observing `@EnvironmentObject AppState`
        // re-render when properties of the nested `aiAgent` flip
        // (e.g., `backend` changing in the Settings picker).
        // Without this bridge the picker's tab visually didn't
        // switch — the data was correct but the View tree
        // didn't know to redraw.
        await MainActor.run {
            aiAgent.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        if let cached = cache.load(), !cached.events.isEmpty || !cached.tasks.isEmpty {
            await MainActor.run {
                events     = cached.events
                tasks      = cached.tasks
                syncStatus = .success(cached.lastSyncedAt)
            }
        } else {
            await MainActor.run {
                showMockData = true
                events = CalendarEvent.mock()
                tasks  = CUTask.mock()
            }
        }

        // Calendar permission: handled exclusively by
        // GoogleAuthService now (OAuth flow). No EventKit
        // permission probe — Google connection state is the
        // only gate.
        clickUpAuthService.checkAuthState()
        networkMonitor.start()

        networkMonitor.$isOnline
            .receive(on: DispatchQueue.main)
            .dropFirst()      // skip the initial value — only react to changes
            .sink { [weak self] online in
                guard let self else { return }
                let wasOnline = self.isOnline
                self.isOnline = online
                if !online {
                    self.syncStatus = .offline
                    self.notify(.warning,
                                title: "Sem conexão",
                                message: "Apollo está offline.")
                } else if !wasOnline {
                    self.notify(.success, title: "De volta ao online")
                    // Drain the offline queue first so any pending
                    // mutations land BEFORE the sync fetches fresh
                    // state — otherwise the sync would overwrite
                    // the user's local edits with pre-mutation
                    // server data. Permanent failures fall out via
                    // the `onPermanentFailure` callback.
                    Task { @MainActor in
                        OfflineQueue.shared.drain(
                            executor: { [weak self] op in
                                try await self?.replayOfflineOp(op)
                            },
                            onPermanentFailure: { [weak self] mut, error in
                                self?.handleOfflineDrainFailure(mut, error: error)
                            }
                        )
                        await self.sync()
                    }
                }
            }
            .store(in: &cancellables)

        // EventKit permission-denial subscription removed —
        // calendar access is now signalled via Google OAuth
        // connection state, not a system-permission flag.

        // ClickUp connect / disconnect events.
        clickUpAuthService.$isConnected
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self else { return }
                if connected {
                    let user = self.clickUpAuthService.userName ?? "ClickUp"
                    self.notify(.success,
                                title: "ClickUp conectado",
                                message: user)
                } else {
                    self.notify(.info, title: "ClickUp desconectado")
                }
            }
            .store(in: &cancellables)

        // Connection-failure messages from the ClickUp auth flow.
        clickUpAuthService.$connectionError
            .dropFirst()
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] err in
                self?.notify(.error,
                             title: "Erro na conexão ClickUp",
                             message: err)
            }
            .store(in: &cancellables)

        if await MainActor.run(body: { isOnline }) { await sync() }

        restartAutoSync()
        await MainActor.run { self.startReminderTicker() }
    }

    // MARK: - Auto-sync timer

    func restartAutoSync() {
        syncTimerCancellable?.cancel()
        guard autoSyncInterval > 0 else { return }
        syncTimerCancellable = Timer.publish(every: Double(autoSyncInterval) * 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in Task { await self?.sync() } }
    }

    // MARK: - Fast (focus-aware) sync

    /// Starts a 30-second polling loop. Called when the app window comes
    /// to the foreground so ClickUp-side edits surface quickly. The slower
    /// `restartAutoSync` timer keeps running underneath for inactive
    /// periods.
    func enableFastSync() {
        fastSyncCancellable?.cancel()
        fastSyncCancellable = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in Task { await self?.sync() } }
    }

    func disableFastSync() {
        fastSyncCancellable?.cancel()
        fastSyncCancellable = nil
    }

    // MARK: - Upcoming-reminders ticker

    /// Starts a 60-second loop that checks for events about to begin
    /// and tasks whose due date is approaching. Runs once immediately
    /// so a freshly launched app surfaces anything currently inside
    /// the lead window.
    func startReminderTicker() {
        reminderTickerCancellable?.cancel()
        reminderTickerCancellable = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.checkUpcomingReminders() }
        checkUpcomingReminders()
    }

    func stopReminderTicker() {
        reminderTickerCancellable?.cancel()
        reminderTickerCancellable = nil
    }

    /// Walks the current `events` and `tasks` arrays and fires a
    /// reminder for anything inside its lead window that hasn't
    /// already been reminded this session. Pruning at the end keeps
    /// the "fired" sets aligned with the visible scope so an item
    /// that was rescheduled out of (and back into) the window can
    /// re-fire.
    private func checkUpcomingReminders() {
        let now = Date()

        // Events about to begin. Skip all-day entries — their
        // `startDate` is midnight and the user has nothing concrete
        // to be reminded about ten minutes ahead of "midnight".
        for event in events where !event.isAllDay {
            let secondsUntil = event.startDate.timeIntervalSince(now)
            guard secondsUntil > 0,
                  secondsUntil <= eventReminderLead,
                  !firedEventReminders.contains(event.id)
            else { continue }
            firedEventReminders.insert(event.id)
            let minutes = max(1, Int(round(secondsUntil / 60)))
            let when = event.startDate
                .formatted(.dateTime.hour().minute())
            let body = [
                "Às \(when)",
                event.organizerSuffix
            ].compactMap { $0 }.joined(separator: " · ")
            notifyEvent(.info,
                        title:    event.title,
                        subtitle: "Começa em \(minutes) min",
                        message:  body,
                        eventId:  event.id)
        }

        // Tasks with a due date approaching. Skip completed tasks
        // and ones the user already shipped — they're no longer
        // actionable and we'd just nag.
        for task in tasks {
            guard !task.isCompleted, let due = task.dueDate else { continue }
            let secondsUntil = due.timeIntervalSince(now)
            guard secondsUntil > 0,
                  secondsUntil <= taskReminderLead,
                  !firedTaskReminders.contains(task.id)
            else { continue }
            firedTaskReminders.insert(task.id)
            let minutes = max(1, Int(round(secondsUntil / 60)))
            let label: String = {
                if minutes >= 60 { return "Vence em ~1 hora" }
                if minutes >= 30 { return "Vence em \(minutes) min" }
                return "Vence em \(minutes) min · urgente"
            }()
            notifyTask(.warning,
                       title:    task.title,
                       subtitle: label,
                       message:  task.notificationDetails,
                       taskId:   task.id)
        }

        // User-set per-task reminders (Apollo-native — ClickUp's
        // API doesn't expose readable reminders, so these live
        // locally). One-shot: fire through the same path as the
        // due-date reminders, then delete so it can't refire.
        for r in TaskReminders.due(asOf: now) {
            notifyTask(.info,
                       title:    r.taskTitle,
                       subtitle: "Lembrete",
                       message:  (r.note?.isEmpty == false) ? r.note : nil,
                       taskId:   r.taskId)
            TaskReminders.remove(id: r.id)
        }

        // Prune so items that drift out of the window (event passed,
        // task completed, due date pushed forward) can fire again
        // later if they re-enter the window. Also bounds the sets.
        firedEventReminders = firedEventReminders.intersection(
            Set(events.lazy
                .filter { $0.startDate.timeIntervalSince(now) <= self.eventReminderLead
                          && $0.startDate > now }
                .map(\.id))
        )
        firedTaskReminders = firedTaskReminders.intersection(
            Set(tasks.lazy
                .filter {
                    !$0.isCompleted
                    && ($0.dueDate.map { $0.timeIntervalSince(now) <= self.taskReminderLead
                                          && $0 > now } ?? false)
                }
                .map(\.id))
        )
    }

    /// Team/workspace id for the cross-list "Meu trabalho" query.
    /// New connections capture it at connect time; connections
    /// that predate that capture would otherwise make the toggle a
    /// silent no-op, so resolve it once on demand and cache it.
    private func resolveWorkspaceId() async -> String? {
        if let cached = KeychainHelper.load(for: KeychainHelper.Keys.clickupWorkspaceId) {
            return cached
        }
        guard let ws = try? await cuSvc.getWorkspaces().first else { return nil }
        KeychainHelper.save(ws.id, for: KeychainHelper.Keys.clickupWorkspaceId)
        return ws.id
    }

    // MARK: - Sync

    func sync() async {
        let online = await MainActor.run { isOnline }
        guard online else { await MainActor.run { syncStatus = .offline }; return }

        let googleConnected = await MainActor.run { googleAuth.isConnected }
        // Calendar source = Google only. EventKit fallback
        // was removed — keeping a hybrid path created drift
        // between the two stores and EventKit can't carry
        // attendees on macOS anyway. ClickUp still syncs
        // independently below.
        let calConfigured = googleConnected
        let cuConfigured  = clickUpAuthService.isConnected &&
                            KeychainHelper.load(for: KeychainHelper.Keys.clickupListId) != nil
        guard calConfigured || cuConfigured else { return }

        await MainActor.run { syncStatus = .syncing }

        var fetched:      [CalendarEvent] = []
        var fetchedTasks: [CUTask]        = []
        var hadError = false

        if calConfigured {
            // Fetch 60-day range (-30…+30 from today) so the timeline can
            // scroll continuously through past and future days.
            let cal   = Calendar.current
            let today = cal.startOfDay(for: Date())
            let start = cal.date(byAdding: .day, value: -30, to: today)!
            let end   = cal.date(byAdding: .day, value:  31, to: today)!

            // Single source of truth: Google Calendar API.
            do {
                fetched = try await googleCalendar.listEvents(from: start, to: end)
            } catch {
                hadError = true
                Log.error("Google Calendar list failed: \(error)")
            }
        }
        if cuConfigured {
            do {
                // Task source depends on the view mode. "Meu
                // trabalho" hits the cross-list team endpoint
                // filtered by the connected user; "Lista ativa"
                // hits the single picked list. Statuses/members/
                // tags still come from the active-list space
                // either way — they drive the filter pills, and
                // a cross-list status set would be a noisy union.
                let mode = await MainActor.run { taskViewMode }

                async let statusesReq = cuSvc.getListStatuses()
                async let membersReq  = cuSvc.getMembers()
                async let tagsReq     = cuSvc.getSpaceTags()

                let t: [CUTask]
                if mode == .myWork,
                   let uid  = clickUpAuthService.userId,
                   let wsId = await resolveWorkspaceId() {
                    t = try await cuSvc.listMyTasks(workspaceId: wsId,
                                                    userId: uid)
                } else {
                    t = try await cuSvc.listTasks()
                }
                let (s, m, tg) = try await (statusesReq, membersReq, tagsReq)
                fetchedTasks = t
                await MainActor.run {
                    availableStatuses = s
                    availableMembers  = m
                    availableTags     = tg
                }
            } catch { hadError = true; Log.error("ClickUp: \(error)") }
        }

        let now = Date()
        cache.save(AppCache(events: fetched, tasks: fetchedTasks, lastSyncedAt: now))

        // Diff against the snapshot from the previous sync — surfaces
        // changes that came from elsewhere (a teammate moved a task, an
        // event got rescheduled in Google Calendar, etc.). Suppressed on
        // the very first sync of the session so we don't notify "Nova
        // tarefa" for everything that already exists.
        await MainActor.run {
            diffAndNotifyRemoteChanges(newTasks: fetchedTasks, newEvents: fetched)
        }

        await MainActor.run {
            showMockData = false
            events       = applyPendingRSVPs(to: fetched)
            // Preserve hydrated per-task fields that the LIST
            // endpoint doesn't return. Specifically:
            //
            //   • `attachments`: ClickUp's `getList` payload
            //     never includes attachments. Wholesale-
            //     replacing `tasks` with `fetchedTasks` was
            //     wiping them every 30s when fast-sync fired,
            //     producing the visible "anexos somem" glitch
            //     in an open detail popup. Per-task hydration
            //     populates them and we shouldn't clobber that.
            //
            // We only preserve when the local copy has a non-
            // empty value AND the fresh copy has empty — that
            // way an actual remote attachment-removal still
            // propagates (next hydration re-fetches the per-
            // task and gets the real empty list).
            let oldById = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
            tasks = fetchedTasks.map { fresh in
                guard let existing = oldById[fresh.id] else { return fresh }
                var merged = fresh
                if merged.attachments.isEmpty && !existing.attachments.isEmpty {
                    merged.attachments = existing.attachments
                }
                return merged
            }
            syncStatus   = hadError ? .error("Algumas fontes falharam") : .success(now)
            // Re-baseline the snapshots to the just-synced state.
            // EventKit can hand back multiple occurrences of a
            // recurring event sharing the same `eventIdentifier`,
            // and ClickUp's pagination has occasionally returned a
            // task twice. Both make `uniqueKeysWithValues:` trap
            // fatally — collapse duplicates with last-wins instead.
            previousTaskSnapshots = Dictionary(
                fetchedTasks.map { ($0.id, TaskSnapshot($0)) },
                uniquingKeysWith: { _, new in new }
            )
            previousEventSnapshots = Dictionary(
                fetched.map { ($0.id, EventSnapshot($0)) },
                uniquingKeysWith: { _, new in new }
            )
        }
        if hadError {
            notify(.error,
                   title: "Falha na sincronização",
                   message: "Algumas fontes (Calendário ou ClickUp) não responderam.")
        }
        // Shared overlay calendars — fetched AFTER the main
        // sync so the timeline already has primary events
        // rendered while these load. Each contact is queried
        // independently; failures don't block the main sync.
        if googleConnected, !sharedCalendars.isEmpty {
            await syncSharedCalendars()
        } else if !googleConnected {
            await MainActor.run {
                sharedEvents = [:]
                sharedCalendarsLimitedAccess = []
                rebuildMergedEventIndex()
            }
        }

        // Fire-and-forget comment polling. We don't await
        // because it runs N HTTP fetches per call (one per
        // assigned task, capped at 30) and the user expects
        // `sync()` to complete in well under a second to
        // unfreeze the syncStatus pill. Notifications surface
        // when each fetch completes, asynchronously.
        Task { await self.pollCommentNotifications() }
    }

    /// Pulls events for every contact in `sharedCalendars`
    /// in parallel. Stores results in `sharedEvents` keyed
    /// by email; errors per contact are swallowed (one bad
    /// email shouldn't crater the whole overlay) and just
    /// leave that key empty.
    private func syncSharedCalendars() async {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -30, to: today)!
        let end   = cal.date(byAdding: .day, value:  31, to: today)!

        let snapshot = await MainActor.run { sharedCalendars }

        await withTaskGroup(of: (String, [CalendarEvent], Bool).self) { group in
            for contact in snapshot {
                group.addTask {
                    do {
                        let result = try await self.googleCalendar.listSharedCalendar(
                            email: contact.email,
                            from: start, to: end,
                            contactColorHex: contact.colorHex
                        )
                        return (contact.email, result.events, result.hadFullAccess)
                    } catch {
                        // Total failure (network, auth) —
                        // empty out the contact's slot.
                        return (contact.email, [], false)
                    }
                }
            }
            var newEvents: [String: [CalendarEvent]] = [:]
            var limited:   Set<String> = []
            for await (email, events, hadFull) in group {
                newEvents[email] = events
                if !hadFull { limited.insert(email) }
            }
            await MainActor.run {
                self.sharedEvents = newEvents
                self.sharedCalendarsLimitedAccess = limited
                // Re-merge the per-day index so the timeline
                // sees the new overlay events without
                // recomputing on every body re-eval.
                self.rebuildMergedEventIndex()
            }
        }
    }

    /// Adds a contact's email to the overlay roster. Idempotent
    /// — duplicates are silently ignored. Triggers an immediate
    /// background sync of just that contact so the timeline
    /// reflects the new overlay without waiting for the next
    /// full `sync()`.
    func addSharedCalendar(email: String, name: String? = nil) {
        let trimmed = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty, trimmed.contains("@") else { return }
        guard !sharedCalendars.contains(where: { $0.email.lowercased() == trimmed })
        else { return }
        let trimmedName = name?.trimmingCharacters(in: .whitespaces)
        let displayName = (trimmedName?.isEmpty == false ? trimmedName : nil)
            ?? trimmed.split(separator: "@").first.map(String.init)
            ?? trimmed
        let entry = SharedCalendar(
            email:    trimmed,
            name:     displayName,
            colorHex: SharedCalendar.paletteColor(for: trimmed)
        )
        sharedCalendars.append(entry)
        Task { await syncSharedCalendars() }
    }

    /// Removes a contact from the overlay roster.
    func removeSharedCalendar(email: String) {
        let key = email.lowercased()
        sharedCalendars.removeAll { $0.email.lowercased() == key }
        sharedEvents[key] = nil
        sharedCalendarsLimitedAccess.remove(key)
        rebuildMergedEventIndex()
    }

    private func diffAndNotifyRemoteChanges(newTasks: [CUTask],
                                            newEvents: [CalendarEvent]) {
        // Tasks
        // The connected user's own ClickUp id — used to suppress
        // notifications for changes the user made themselves
        // (whether via Apollo, clickup.com, or the mobile app). Apollo
        // already patches the snapshot for in-app mutations via
        // `bumpTaskSnapshot`, but external edits leak through unless
        // we compare `last_editor` / `creator` against the user.
        let me = clickUpAuthService.userId

        if let prevSnaps = previousTaskSnapshots {
            let newMap = Dictionary(
                newTasks.map { ($0.id, $0) },
                uniquingKeysWith: { _, new in new }
            )
            for (id, task) in newMap {
                // If ClickUp told us who last edited and that's the
                // connected user, skip every "X mudou" notification.
                let editedByMe: Bool = {
                    if let editor = task.lastEditorId, let me { return editor == me }
                    return false
                }()
                if let prev = prevSnaps[id] {
                    if editedByMe { continue }
                    let curr = TaskSnapshot(task)
                    if curr != prev {
                        // For every change kind, the headline (bold
                        // title) is the task name, the subtitle is
                        // the action verb, and the message carries
                        // change-specific detail joined with the
                        // canonical priority + status tag line.
                        if curr.status != prev.status {
                            let prevLabel = prev.status.uppercased()
                            let currLabel = curr.status.uppercased()
                            let body = [
                                "\(prevLabel) → \(currLabel)",
                                (1...4).contains(task.priority) ? task.priorityLabel : nil
                            ].compactMap { $0 }.joined(separator: " · ")
                            // Paint each status name in its own
                            // accent. Lookup is by case-insensitive
                            // status name against `availableStatuses`,
                            // which carries the canonical hex ClickUp
                            // returns (`displayHex`). For statuses no
                            // longer in the workspace's roster (rare,
                            // but happens after a status rename) we
                            // fall back to the live task's
                            // `statusDisplayHex` for the curr label —
                            // covers the most common case where the
                            // newly-applied status IS still active.
                            let prevHex = hexForStatusName(prev.status)
                                ?? "#87909E"
                            let currHex = hexForStatusName(curr.status)
                                ?? task.statusDisplayHex
                            notifyTask(.info,
                                       title:    task.title,
                                       subtitle: "Status alterado",
                                       message:  body,
                                       messageHighlights: [
                                           .init(text: prevLabel, hex: prevHex),
                                           .init(text: currLabel, hex: currHex),
                                       ],
                                       taskId:   task.id)
                        } else if curr.assigneeIds != prev.assigneeIds {
                            notifyTask(.info,
                                       title:    task.title,
                                       subtitle: "Atribuição alterada",
                                       message:  task.notificationDetails,
                                       taskId:   task.id)
                        } else if curr.dueDate != prev.dueDate {
                            notifyTask(.info,
                                       title:    task.title,
                                       subtitle: "Vencimento alterado",
                                       message:  task.notificationDetails,
                                       taskId:   task.id)
                        } else if curr.priority != prev.priority {
                            notifyTask(.info,
                                       title:    task.title,
                                       subtitle: "Prioridade alterada",
                                       message:  task.notificationDetails,
                                       taskId:   task.id)
                        } else if curr.title != prev.title {
                            // Renames are the one case where the
                            // headline can't be the (now stale)
                            // previous title — surface the new one
                            // and keep the old in the body so the
                            // user can spot the change.
                            notifyTask(.info,
                                       title:    task.title,
                                       subtitle: "Tarefa renomeada",
                                       message:  "Antes: \(prev.title) · \(task.notificationDetails)",
                                       taskId:   task.id)
                        }
                    }
                } else {
                    // Don't notify for tasks the connected user
                    // created themselves elsewhere (e.g. on
                    // clickup.com). Falls back to checking creator
                    // when `lastEditorId` isn't available.
                    let createdByMe: Bool = {
                        if let me {
                            if let cid = task.creator?.id { return cid == me }
                            if let editor = task.lastEditorId { return editor == me }
                        }
                        return false
                    }()
                    if createdByMe { continue }
                    // Skip backlog noise: a teammate's task that was
                    // created before today shouldn't pop "Nova tarefa"
                    // just because Apollo's first sync of the day saw
                    // it for the first time. We only flag genuinely
                    // recent additions.
                    if let created = task.dateCreated,
                       created < Calendar.current.startOfDay(for: Date()) {
                        continue
                    }
                    notifyTask(.info,
                               title:    task.title,
                               subtitle: "Nova tarefa",
                               message:  task.notificationDetails,
                               taskId:   task.id)
                }
            }
        }

        // Events — mirror the task diff: report changes (rename,
        // reschedule, cancellation) on existing entries plus brand
        // new ones that appeared since the last sync.
        if let prevSnaps = previousEventSnapshots {
            let newMap = Dictionary(
                newEvents.map { ($0.id, $0) },
                uniquingKeysWith: { _, new in new }
            )

            // Cancellations — events that disappeared from the new
            // payload. Useful when a teammate deletes a meeting on
            // Google Calendar; otherwise the user only finds out the
            // pill silently vanished. Headline carries the (now
            // deleted) event name so the user can spot which one;
            // no `eventId:` because the deep-link target is gone.
            for (id, prev) in prevSnaps where newMap[id] == nil {
                let when = prev.startDate
                    .formatted(.dateTime.day().month(.abbreviated).hour().minute())
                let body = [
                    when,
                    prev.organizerSuffix
                ].compactMap { $0 }.joined(separator: " · ")
                notify(.info,
                       title:    prev.title,
                       subtitle: "Evento cancelado",
                       message:  body)
            }

            // Existing events: detect rename / time shift / location
            // change. We only fire one banner per event per sync to
            // mirror the task diff's "if/else if" cascade.
            for (id, event) in newMap {
                let curr = EventSnapshot(event)
                if let prev = prevSnaps[id] {
                    guard curr != prev else { continue }
                    if curr.title != prev.title {
                        let body = [
                            "Antes: \(prev.title)",
                            event.organizerSuffix
                        ].compactMap { $0 }.joined(separator: " · ")
                        notifyEvent(.info,
                                    title:    event.title,
                                    subtitle: "Evento renomeado",
                                    message:  body,
                                    eventId:  event.id)
                    } else if curr.startDate != prev.startDate
                              || curr.endDate != prev.endDate {
                        let when = curr.startDate
                            .formatted(.dateTime.day().month(.abbreviated).hour().minute())
                        let body = [
                            "Agora começa em \(when)",
                            event.organizerSuffix
                        ].compactMap { $0 }.joined(separator: " · ")
                        notifyEvent(.info,
                                    title:    event.title,
                                    subtitle: "Horário alterado",
                                    message:  body,
                                    eventId:  event.id)
                    } else if curr.location != prev.location {
                        let body = [
                            curr.location ?? "Sem local",
                            event.organizerSuffix
                        ].compactMap { $0 }.joined(separator: " · ")
                        notifyEvent(.info,
                                    title:    event.title,
                                    subtitle: "Local alterado",
                                    message:  body,
                                    eventId:  event.id)
                    }
                } else {
                    // Same backlog-suppression as the task diff:
                    // events that already started before today (e.g.
                    // the first sync after reopening Apollo on a new
                    // day surfaces last week's stand-ups as "new")
                    // shouldn't fire "Novo evento". Future events
                    // and items starting later today are still
                    // surfaced normally.
                    if event.startDate < Calendar.current.startOfDay(for: Date()) {
                        continue
                    }
                    let when = event.startDate
                        .formatted(.dateTime.day().month(.abbreviated).hour().minute())
                    let body = [
                        when,
                        event.organizerSuffix
                    ].compactMap { $0 }.joined(separator: " · ")
                    notifyEvent(.info,
                                title:    event.title,
                                subtitle: "Novo evento",
                                message:  body,
                                eventId:  event.id)
                }
            }
        }

        // ── Proofing comments diff ────────────────────────
        //
        // For every attachment uploaded by the connected user,
        // compare current `total_comments` against the
        // last-seen baseline. Strictly greater → fire a "novos
        // comentários de revisão" notification deep-linked
        // straight at the proofing view.
        //
        // We only re-baseline AFTER scanning so the first sync
        // post-launch doesn't notify for comments that were
        // already there (the baseline is empty → the strict-
        // greater check skips everything on the first pass).
        // From the second sync onwards, only genuinely new
        // counts trigger.
        if let me = me {
            var freshCounts: [String: Int] = [:]
            for task in newTasks {
                for att in task.attachments {
                    guard let total = att.totalComments,
                          let uploader = att.uploaderId,
                          uploader == me
                    else { continue }
                    freshCounts[att.id] = total
                    let prev = lastSeenProofingCounts[att.id]
                    if let prev, total > prev {
                        let delta = total - prev
                        notifyTask(
                            .info,
                            title:    task.title,
                            subtitle: "Novos comentários de revisão",
                            message:  "\(delta) " +
                                (delta == 1 ? "comentário novo no anexo "
                                            : "comentários novos no anexo ") +
                                "\(att.title). Clique pra abrir a tarefa e ir pro proofing.",
                            taskId:   task.id
                        )
                    }
                }
            }
            lastSeenProofingCounts = freshCounts
        }
    }

    /// Replays a queued offline op against the real services. The
    /// queue's drain loop hands ops back here in FIFO order and
    /// expects the call to throw `APIError` on transient failures
    /// (so the op stays at the head) or any other error on
    /// permanent failures (so the op is dropped + reported).
    private func replayOfflineOp(_ op: PendingMutation.Op) async throws {
        switch op {
        case .updateTaskStatus(let id, let status):
            try await cuSvc.updateTaskStatus(id: id, to: status)
            await MainActor.run { bumpTaskSnapshot(for: id) }
        case .completeTask(let id):
            try await cuSvc.completeTask(id: id)
            await MainActor.run { bumpTaskSnapshot(for: id) }
        case .patchTaskFields(let id, let fields):
            let json = fields.mapValues(\.jsonValue)
            try await cuSvc.updateTask(id: id, fields: json)
            await MainActor.run { bumpTaskSnapshot(for: id) }
        }
    }

    /// Surfaces a queued mutation that the drain loop decided is
    /// unrecoverable — usually a 401 (the token rotted while
    /// offline) or a 404 (the task was deleted on another device).
    /// We notify the user with the underlying APIError's
    /// human-readable copy so they know which mutation got dropped.
    private func handleOfflineDrainFailure(_ mut: PendingMutation,
                                           error: Error) {
        Task { @MainActor in
            let api = (error as? APIError)
            let title = api?.userFacingTitle ?? "Operação descartada"
            let msg   = api?.userFacingMessage
                        ?? "Uma mudança em fila foi rejeitada pelo servidor."
            notify(.warning, title: title, message: msg)
        }
    }

    /// Patches a task snapshot after a local mutation so the next sync
    /// doesn't fire diff-detection for the user's own change.
    private func bumpTaskSnapshot(for taskId: String) {
        guard previousTaskSnapshots != nil,
              let updated = tasksById[taskId] else { return }
        previousTaskSnapshots?[taskId] = TaskSnapshot(updated)
    }

    // MARK: - Task operations

    // MARK: - Inline task editing

    private func patchTask(_ task: CUTask,
                           field: String = "alteração",
                           apply local: @escaping (inout CUTask) -> Void,
                           remote:  @escaping () async throws -> Void) async {
        // Apply the optimistic mutation unconditionally — the UI
        // should reflect the user's intent even if the server hop
        // can't happen yet. We then either fire the remote call
        // immediately (online), or queue it via `OfflineQueue` so
        // it replays when connectivity returns.
        let original = task
        await MainActor.run {
            if let idx = tasks.firstIndex(where: { $0.id == task.id }) { local(&tasks[idx]) }
        }

        let online = await MainActor.run { isOnline }
        guard online else {
            // Caller must use `patchTaskFields` to get true offline
            // queueing — `patchTask` with an opaque closure can't
            // be serialized for replay. We keep the optimistic
            // mutation visible and flag the limitation so the user
            // knows the change won't sync until they're back online
            // AND the app is running.
            notifyTask(.warning,
                       title:    task.title,
                       subtitle: "Salva localmente",
                       message:  "Reabra com internet pra sincronizar a \(field).",
                       taskId:   task.id)
            return
        }
        do {
            try await remote()
            await MainActor.run { bumpTaskSnapshot(for: task.id) }
        } catch let api as APIError where api.isTransient {
            // Transient → keep the optimistic state and surface
            // the offline-style toast (the actual queue replay is
            // done by callers that route through `patchTaskFields`).
            notifyTask(.info,
                       title:    task.title,
                       subtitle: api.userFacingTitle,
                       message:  api.userFacingMessage,
                       taskId:   task.id)
        } catch {
            Log.error("patchTask: \(error)")
            await MainActor.run {
                if let idx = tasks.firstIndex(where: { $0.id == task.id }) { tasks[idx] = original }
            }
            let title = (error as? APIError)?.userFacingTitle ?? "Falha ao salvar \(field)"
            let msg   = (error as? APIError)?.userFacingMessage ?? task.notificationDetails
            notifyTask(.error,
                       title:    task.title,
                       subtitle: title,
                       message:  msg,
                       taskId:   task.id)
        }
    }

    /// Offline-aware structured variant of `patchTask`. Use this
    /// whenever the patch can be expressed as a flat `[String: Any]`
    /// payload against `cuSvc.updateTask(id:fields:)` — it lets the
    /// OfflineQueue serialize and replay the mutation when
    /// connectivity returns, even across app restarts.
    private func patchTaskFields(_ task: CUTask,
                                 field: String,
                                 fields: [String: Any],
                                 apply local: @escaping (inout CUTask) -> Void) async {
        let original = task
        await MainActor.run {
            if let idx = tasks.firstIndex(where: { $0.id == task.id }) { local(&tasks[idx]) }
        }

        let online = await MainActor.run { isOnline }
        let queuePayload = fields.mapValues(PlainValue.from)

        guard online else {
            await OfflineQueue.shared.enqueue(
                .patchTaskFields(taskId: task.id, fields: queuePayload),
                originatingFromOfflineState: true
            )
            notifyTask(.info,
                       title:    task.title,
                       subtitle: "Na fila offline",
                       message:  "A \(field) sincroniza quando a internet voltar.",
                       taskId:   task.id)
            return
        }
        do {
            try await cuSvc.updateTask(id: task.id, fields: fields)
            await MainActor.run { bumpTaskSnapshot(for: task.id) }
        } catch let api as APIError where api.isTransient {
            // Server-flaky or rate-limited → push onto queue and
            // let the next reconnect drain attempt it again.
            await OfflineQueue.shared.enqueue(
                .patchTaskFields(taskId: task.id, fields: queuePayload)
            )
            notifyTask(.info,
                       title:    task.title,
                       subtitle: api.userFacingTitle,
                       message:  api.userFacingMessage,
                       taskId:   task.id)
        } catch {
            await MainActor.run {
                if let idx = tasks.firstIndex(where: { $0.id == task.id }) { tasks[idx] = original }
            }
            let title = (error as? APIError)?.userFacingTitle ?? "Falha ao salvar \(field)"
            let msg   = (error as? APIError)?.userFacingMessage ?? task.notificationDetails
            notifyTask(.error,
                       title:    task.title,
                       subtitle: title,
                       message:  msg,
                       taskId:   task.id)
        }
    }

    func updateTaskTitle(_ task: CUTask, to title: String) async {
        guard title != task.title, !title.isEmpty else { return }
        // `patchTaskFields` (vs `patchTask`) routes through the
        // offline queue when there's no connectivity, so a title
        // edit made on the subway survives all the way to the
        // server once we're back online.
        await patchTaskFields(task, field: "título",
            fields: ["name": title],
            apply: { $0.title = title })
    }

    func updateTaskDescription(_ task: CUTask, to description: String) async {
        guard description != (task.description ?? "") else { return }
        await patchTaskFields(task, field: "descrição",
            fields: ["description": description],
            apply: { $0.description = description.isEmpty ? nil : description })
    }

    func updateTaskPriority(_ task: CUTask, to priority: Int) async {
        guard priority != task.priority else { return }
        await patchTaskFields(task, field: "prioridade",
            fields: ["priority": priority],
            apply: { $0.priority = priority })
    }

    func updateTaskStartDate(_ task: CUTask, to date: Date?) async {
        var fields: [String: Any] = [:]
        if let date {
            fields["start_date"] = Int(date.timeIntervalSince1970 * 1000)
            fields["start_date_time"] = true
        } else {
            fields["start_date"] = NSNull()
        }
        await patchTaskFields(task, field: "data de início",
            fields: fields,
            apply: { $0.startDate = date })
    }

    func updateTaskDueDate(_ task: CUTask, to date: Date?) async {
        var fields: [String: Any] = [:]
        if let date {
            fields["due_date"] = Int(date.timeIntervalSince1970 * 1000)
            fields["due_date_time"] = true
        } else {
            fields["due_date"] = NSNull()
        }
        await patchTaskFields(task, field: "data de vencimento",
            fields: fields,
            apply: { $0.dueDate = date })
    }

    func updateTaskAssignees(_ task: CUTask, to newIds: Set<Int>) async {
        let oldIds = Set(task.assignees.map(\.id))
        let toAdd  = Array(newIds.subtracting(oldIds))
        let toRem  = Array(oldIds.subtracting(newIds))
        guard !toAdd.isEmpty || !toRem.isEmpty else { return }

        await patchTask(task, field: "responsáveis",
            apply: { t in
                t.assignees = self.availableMembers
                    .filter { newIds.contains($0.id) }
                    .map {
                        CUTask.Assignee(id: $0.id, username: $0.username,
                                        initials: $0.initials, color: $0.color,
                                        profilePicture: $0.profilePicture)
                    }
            },
            remote: {
                let body: [String: Any] = ["assignees": ["add": toAdd, "rem": toRem]]
                try await self.cuSvc.updateTask(id: task.id, fields: body)
            })
    }

    func updateTaskTags(_ task: CUTask, to newNames: Set<String>) async {
        let oldNames = Set(task.tags.map(\.name))
        let toAdd = newNames.subtracting(oldNames)
        let toRem = oldNames.subtracting(newNames)
        guard !toAdd.isEmpty || !toRem.isEmpty else { return }

        await patchTask(task, field: "etiquetas",
            apply: { t in
                t.tags = self.availableTags.filter { newNames.contains($0.name) }
            },
            remote: {
                for name in toAdd { try await self.cuSvc.addTaskTag(id: task.id, tag: name) }
                for name in toRem { try await self.cuSvc.removeTaskTag(id: task.id, tag: name) }
            })
    }

    func updateTaskStatus(_ task: CUTask, to status: CUStatus) async {
        // Optimistic state lands immediately — the UI shouldn't
        // wait for the server even when we're online.
        let original = task
        await MainActor.run {
            if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[idx].status      = status.status
                tasks[idx].statusColor = status.color
                tasks[idx].isCompleted = status.isClosed
            }
        }

        let online = await MainActor.run { isOnline }
        guard online else {
            // No network → push onto durable queue (survives
            // relaunch). When `NetworkMonitor.isOnline` flips back,
            // the reconnect handler drains every queued op in FIFO
            // order via `OfflineQueue.shared.drain(executor:)`.
            await OfflineQueue.shared.enqueue(
                .updateTaskStatus(taskId: task.id, status: status.status),
                originatingFromOfflineState: true
            )
            notifyTask(.info,
                       title:    task.title,
                       subtitle: "Status na fila offline",
                       message:  "\(original.status.uppercased()) → \(status.status.uppercased()) sincroniza quando a internet voltar.",
                       taskId:   task.id)
            return
        }

        do {
            try await cuSvc.updateTaskStatus(id: task.id, to: status.status)
            await MainActor.run { bumpTaskSnapshot(for: task.id) }
            notifyTask(.success,
                       title:    task.title,
                       subtitle: "Status atualizado",
                       message:  "\(original.status.uppercased()) → \(status.status.uppercased())"
                                 + ((1...4).contains(task.priority) ? " · \(task.priorityLabel)" : ""),
                       taskId:   task.id)
        } catch let api as APIError where api.isTransient {
            // Transient — keep the optimistic state and queue.
            await OfflineQueue.shared.enqueue(
                .updateTaskStatus(taskId: task.id, status: status.status)
            )
            notifyTask(.info,
                       title:    task.title,
                       subtitle: api.userFacingTitle,
                       message:  api.userFacingMessage,
                       taskId:   task.id)
        } catch {
            Log.error("updateTaskStatus: \(error)")
            // Permanent — roll back the optimistic state.
            await MainActor.run {
                if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
                    tasks[idx].status      = original.status
                    tasks[idx].statusColor = original.statusColor
                    tasks[idx].isCompleted = original.isCompleted
                }
            }
            let title = (error as? APIError)?.userFacingTitle ?? "Falha ao mudar status"
            let msg   = (error as? APIError)?.userFacingMessage ?? original.notificationDetails
            notifyTask(.error,
                       title:    task.title,
                       subtitle: title,
                       message:  msg,
                       taskId:   task.id)
        }
    }

    func completeTask(_ task: CUTask) async {
        // Optimistic mark-complete lands first, independent of
        // connectivity.
        await MainActor.run {
            if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[idx].isCompleted = true
                tasks[idx].status      = "complete"
                tasks[idx].statusColor = "#6BC950"
            }
        }

        let online = await MainActor.run { isOnline }
        guard online else {
            await OfflineQueue.shared.enqueue(
                .completeTask(taskId: task.id),
                originatingFromOfflineState: true
            )
            notifyTask(.info,
                       title:    task.title,
                       subtitle: "Conclusão na fila offline",
                       message:  "Sincroniza quando a internet voltar.",
                       taskId:   task.id)
            return
        }

        do {
            try await cuSvc.completeTask(id: task.id)
            await MainActor.run { bumpTaskSnapshot(for: task.id) }
            notifyTask(.success,
                       title:    task.title,
                       subtitle: "Tarefa concluída",
                       message:  task.notificationDetails,
                       taskId:   task.id)
        } catch let api as APIError where api.isTransient {
            await OfflineQueue.shared.enqueue(.completeTask(taskId: task.id))
            notifyTask(.info,
                       title:    task.title,
                       subtitle: api.userFacingTitle,
                       message:  api.userFacingMessage,
                       taskId:   task.id)
        } catch {
            Log.error("completeTask: \(error)")
            // Roll back optimistic conclusion.
            await MainActor.run {
                if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
                    tasks[idx].isCompleted = task.isCompleted
                    tasks[idx].status      = task.status
                    tasks[idx].statusColor = task.statusColor
                }
            }
            let title = (error as? APIError)?.userFacingTitle ?? "Falha ao concluir tarefa"
            let msg   = (error as? APIError)?.userFacingMessage ?? task.notificationDetails
            notifyTask(.error,
                       title:    task.title,
                       subtitle: title,
                       message:  msg,
                       taskId:   task.id)
        }
    }

    // MARK: - Extended task mutations (agent surface)

    /// Permanently deletes a task. Used by the AI agent's
    /// `[[DELETE_TASK …]]` marker. Optimistically removes the
    /// task from local state; on API failure, re-runs sync to
    /// refetch authoritative state.
    func deleteTask(_ task: CUTask) async {
        do {
            try await cuSvc.deleteTask(id: task.id)
            await MainActor.run {
                tasks.removeAll { $0.id == task.id }
            }
            notifyTask(.success, title: task.title,
                       subtitle: "Tarefa apagada",
                       message: task.notificationDetails,
                       taskId: task.id)
        } catch {
            Log.error("deleteTask: \(error)")
            await sync()
        }
    }

    /// Archives a task. Reversible from the ClickUp web UI;
    /// the API just sets `archived: true`.
    func archiveTask(_ task: CUTask) async {
        do {
            try await cuSvc.archiveTask(id: task.id)
            await MainActor.run {
                if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
                    tasks[idx].archived = true
                }
                bumpTaskSnapshot(for: task.id)
            }
            notifyTask(.success, title: task.title,
                       subtitle: "Tarefa arquivada",
                       message: task.notificationDetails,
                       taskId: task.id)
        } catch {
            Log.error("archiveTask: \(error)")
        }
    }

    /// Toggle a checklist item resolved/unresolved with an
    /// optimistic local flip + ClickUp PUT. Rolls back the
    /// local state if the request fails. Mutates the matching
    /// item inside `tasks[idx].checklists` so the detail
    /// popup's checkbox updates instantly.
    func toggleChecklistItem(taskId: String,
                             checklistId: String,
                             itemId: String,
                             to resolved: Bool) async {
        // Optimistic local flip.
        await MainActor.run {
            guard let tIdx = tasks.firstIndex(where: { $0.id == taskId })
            else { return }
            guard let cIdx = tasks[tIdx].checklists
                    .firstIndex(where: { $0.id == checklistId })
            else { return }
            guard let iIdx = tasks[tIdx].checklists[cIdx].items
                    .firstIndex(where: { $0.id == itemId })
            else { return }
            tasks[tIdx].checklists[cIdx].items[iIdx].resolved = resolved
        }

        do {
            try await cuSvc.setChecklistItem(
                checklistId: checklistId,
                itemId:      itemId,
                resolved:    resolved
            )
            await MainActor.run { bumpTaskSnapshot(for: taskId) }
        } catch {
            Log.error("toggleChecklistItem: \(error)")
            // Roll back.
            await MainActor.run {
                guard let tIdx = tasks.firstIndex(where: { $0.id == taskId }),
                      let cIdx = tasks[tIdx].checklists
                          .firstIndex(where: { $0.id == checklistId }),
                      let iIdx = tasks[tIdx].checklists[cIdx].items
                          .firstIndex(where: { $0.id == itemId })
                else { return }
                tasks[tIdx].checklists[cIdx].items[iIdx].resolved = !resolved
            }
            let api = error as? APIError
            notifyTask(.error,
                       title: tasksById[taskId]?.title ?? "Tarefa",
                       subtitle: api?.userFacingTitle ?? "Falha no checklist",
                       message: api?.userFacingMessage
                            ?? "Não consegui atualizar o item.",
                       taskId: taskId)
        }
    }

    /// Duplicates a task by reading its fields and creating a
    /// new one with the same metadata. ClickUp's native
    /// duplicate endpoint isn't part of the public v2 API on
    /// every plan tier, so this is a manual clone — works
    /// universally.
    @discardableResult
    func duplicateTask(_ task: CUTask, newTitle: String? = nil) async -> CUTask? {
        let title = newTitle ?? "\(task.title) (cópia)"
        return await createTask(
            title: title,
            description: task.description,
            status: task.status,
            priority: task.priority,
            startDate: task.startDate,
            dueDate: task.dueDate,
            assigneeIds: task.assignees.map(\.id),
            tagNames: task.tags.map(\.name)
        )
    }

    /// Moves a task to a different list within the same
    /// workspace. Doesn't change the active list — user has
    /// to switch manually if they want to follow the task.
    func moveTaskToList(_ task: CUTask, toListId: String) async {
        do {
            try await cuSvc.moveTask(id: task.id, toListId: toListId)
            await MainActor.run {
                tasks.removeAll { $0.id == task.id }
            }
            notifyTask(.success, title: task.title,
                       subtitle: "Movida para outra lista",
                       message: task.notificationDetails,
                       taskId: task.id)
        } catch {
            Log.error("moveTaskToList: \(error)")
        }
    }

    /// Posts a comment on the user's behalf. Wrapper over the
    /// existing `postComment` so the agent surface stays in
    /// sync with the UI surface.
    @discardableResult
    func addComment(to task: CUTask, text: String) async -> CUComment? {
        await postComment(on: task, text: text)
    }

    /// Wraps the ClickUp service's `createSubtask` call and
    /// re-syncs so the new subtask shows up in the parent's
    /// detail popup immediately.
    @discardableResult
    func createSubtask(parent: CUTask,
                       title: String,
                       priority: Int = 0,
                       dueDate: Date? = nil,
                       assigneeIds: [Int] = []) async -> CUTask? {
        do {
            let sub = try await cuSvc.createSubtask(
                parentId: parent.id,
                title: title,
                priority: priority,
                dueDate: dueDate,
                assigneeIds: assigneeIds
            )
            await MainActor.run {
                tasks.append(sub)
            }
            return sub
        } catch {
            Log.error("createSubtask: \(error)")
            return nil
        }
    }

    // MARK: - Calendar mutations (agent surface)

    /// Drag-to-reschedule + agent helper. Patches an event via
    /// the Google Calendar REST API and updates the local
    /// cache. EventKit equivalent was removed — Google is the
    /// single source of truth.
    @discardableResult
    func updateEvent(_ event: CalendarEvent,
                     newStart: Date? = nil,
                     newEnd: Date? = nil,
                     newTitle: String? = nil,
                     newLocation: String? = nil,
                     attendees: [String]? = nil) async -> CalendarEvent? {
        let googleConnected = await MainActor.run { googleAuth.isConnected }
        guard googleConnected else {
            notify(.warning,
                   title: "Conecte o Google",
                   message: "Edição de eventos requer conta Google conectada.")
            return nil
        }
        do {
            try await googleCalendar.updateEvent(
                eventId:    event.id,
                calendarId: event.calendarId.isEmpty
                    ? "primary" : event.calendarId,
                title:      newTitle,
                startDate:  newStart,
                endDate:    newEnd,
                location:   newLocation,
                notes:      nil,
                attendees:  attendees
            )
            // Build the patched local copy from the original
            // + applied deltas. Google's PATCH response is
            // discarded here; the next sync tick will reconcile.
            var updated = event
            if let newTitle    { updated.title     = newTitle }
            if let newStart    { updated.startDate = newStart }
            if let newEnd      { updated.endDate   = newEnd }
            if let newLocation { updated.location  = newLocation }
            await MainActor.run {
                if let idx = events.firstIndex(where: { $0.id == event.id }) {
                    events[idx] = updated
                }
            }
            return updated
        } catch {
            Log.error("updateEvent: \(error)")
            return nil
        }
    }

    /// RSVP wrapper. Routes exclusively through the Google
    /// REST API. Agent-callable so the user can say
    /// "recusa o convite X". EventKit RSVP path was removed —
    /// it never worked reliably on macOS (no public API for
    /// participant-status mutation).
    func respondToEvent(_ event: CalendarEvent,
                        status: CalendarEvent.Attendee.Status) async {
        let googleConnected = await MainActor.run { googleAuth.isConnected }
        guard googleConnected else {
            notify(.warning,
                   title: "Conecte o Google",
                   message: "Responder a convites requer conta Google conectada.")
            return
        }
        do {
            try await googleCalendar.respondToEvent(
                eventId: event.id,
                attendees: event.attendees,
                newStatus: status
            )
        } catch {
            Log.error("respondToEvent (Google): \(error)")
            notify(.error,
                   title: "Não consegui atualizar a presença",
                   message: error.localizedDescription)
            return
        }
        // Optimistic update of local cache. Match by the
        // canonical `isCurrentUser` flag (set by the Google
        // parser from each attendee's `self: true` field) —
        // the previous name-based match against
        // `clickUpAuthService.userName` was failing silently
        // when the ClickUp display name didn't equal the
        // Google attendee row's name, leaving the UI stuck
        // on the old status.
        await MainActor.run {
            if let idx = events.firstIndex(where: { $0.id == event.id }) {
                events[idx].attendees = events[idx].attendees.map { att in
                    if att.isCurrentUser {
                        return CalendarEvent.Attendee(
                            name: att.name,
                            email: att.email,
                            status: status,
                            isOrganizer: att.isOrganizer,
                            isCurrentUser: true
                        )
                    }
                    return att
                }
            }
        }
    }

    // MARK: - UI control surface (agent-driven)

    /// Switches the active ClickUp list by name. Looks up the
    /// matching list via the workspace tree, persists the new
    /// id+name to keychain, and re-runs sync. Loose match
    /// (case-insensitive contains) so the agent doesn't have
    /// to know the exact spelling.
    func switchList(named name: String) async -> Bool {
        do {
            let workspaces = try await cuSvc.getWorkspaces()
            for ws in workspaces {
                let spaces = (try? await cuSvc.getSpaces(workspaceId: ws.id)) ?? []
                for sp in spaces {
                    let lists = (try? await cuSvc.getLists(spaceId: sp.id)) ?? []
                    let needle = name.lowercased()
                    if let match = lists.first(where: {
                        $0.name.lowercased() == needle
                    }) ?? lists.first(where: {
                        $0.name.lowercased().contains(needle)
                    }) {
                        KeychainHelper.save(match.id, for: KeychainHelper.Keys.clickupListId)
                        KeychainHelper.save(match.name, for: KeychainHelper.Keys.clickupListName)
                        await sync()
                        return true
                    }
                }
            }
            return false
        } catch {
            Log.error("switchList: \(error)")
            return false
        }
    }

    /// Clears every task filter dimension. Used by the agent
    /// when the user says "tira os filtros" / "mostra tudo".
    @MainActor
    func clearAllFilters() {
        selectedTaskStatus = nil
        taskFilters = TaskFilters()
        searchQuery = ""
    }

    // MARK: - Comments

    func loadComments(for task: CUTask) async -> [CUComment] {
        do {
            return try await cuSvc.getTaskComments(taskId: task.id)
        } catch {
            Log.error("loadComments: \(error)")
            return []
        }
    }

    // MARK: - Comment notifications
    //
    // Polled at the tail of each `sync()` so a teammate's
    // comment / @-mention surfaces as a macOS banner without
    // the user having to open the task. Scope is intentionally
    // narrow — we only poll tasks the user has skin in (an
    // assignee or the creator) so we stay well under
    // ClickUp's 100-call/minute rate limit, and we throttle
    // per-task to once a minute. Mentions in tasks the user
    // is NOT involved in still surface — but only when the
    // user opens that task's popup (the timeline already
    // fetches comments at that point).
    private func saveCommentSeen() {
        UserDefaults.standard.set(lastSeenCommentByTask,
                                  forKey: Self.commentSeenKey)
    }

    /// Polls comments for tasks the connected user is involved
    /// in, throttled to once per task per minute. Called at
    /// the end of `sync()` as a fire-and-forget Task — the
    /// main sync doesn't await this so the syncStatus pill
    /// flips back to .success without waiting on N HTTP
    /// round-trips.
    func pollCommentNotifications() async {
        guard let me = clickUpAuthService.userId else { return }

        let now = Date()
        let throttle: TimeInterval = 60
        let candidates: [CUTask] = await MainActor.run {
            tasks.filter { task in
                let isAssignee = task.assignees.contains { $0.id == me }
                let isCreator  = task.creator?.id == me
                guard isAssignee || isCreator else { return false }
                let last = lastCommentPollAt[task.id] ?? .distantPast
                return now.timeIntervalSince(last) >= throttle
            }
        }
        // Hard cap so a sudden jump in eligible tasks (e.g.
        // bulk-assign) doesn't spike the API bill.
        let capped = Array(candidates.prefix(30))
        guard !capped.isEmpty else { return }

        await MainActor.run {
            for task in capped { lastCommentPollAt[task.id] = now }
        }

        // Limited concurrency — running all 30 fetches at once
        // can briefly stall the network queue. 4 in flight is
        // a safe sweet spot.
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            for task in capped {
                if inFlight >= 4 { _ = await group.next(); inFlight -= 1 }
                group.addTask { [weak self] in
                    await self?.checkComments(forTask: task)
                }
                inFlight += 1
            }
        }
    }

    /// Pulls comments for one task, diffs against the
    /// persisted latest-seen id, and fires a notification per
    /// brand-new entry. First-time tasks (no entry in
    /// `lastSeenCommentByTask`) bootstrap silently — they
    /// record the latest id without notifying so the user
    /// isn't blasted with old comments on first launch / new
    /// task assignment.
    private func checkComments(forTask task: CUTask) async {
        guard let comments = try? await cuSvc.getTaskComments(taskId: task.id),
              !comments.isEmpty
        else { return }
        // Comments arrive newest-first from ClickUp, but normalise
        // anyway so the diff math is unambiguous.
        let sorted = comments.sorted { $0.date > $1.date }
        let latestId = sorted[0].id

        await MainActor.run {
            let prev = lastSeenCommentByTask[task.id]
            // Always record the latest BEFORE notifying so a
            // crash mid-loop doesn't replay the same set on
            // next launch.
            lastSeenCommentByTask[task.id] = latestId
            saveCommentSeen()

            guard let prev else { return }   // bootstrap silent
            // Newest-first: notify everything BEFORE we hit the
            // previously-seen id. If the prev id was deleted on
            // the server, fall back to notifying just the
            // single latest comment so the user isn't silently
            // catching up.
            if let cutoff = sorted.firstIndex(where: { $0.id == prev }) {
                for c in sorted.prefix(cutoff) {
                    handleNewComment(c, on: task)
                }
            } else {
                handleNewComment(sorted[0], on: task)
            }
        }
    }

    /// Fires the macOS banner for one new comment. Skips the
    /// connected user's own posts (otherwise typing in the
    /// composer would trigger your own ping) and chooses
    /// between two flavours: an explicit "Você foi mencionado"
    /// when the body contains `@<your username>`, or a milder
    /// "Novo comentário" otherwise. Click-through is wired via
    /// `notifyTask(taskId:)` — the existing
    /// `openNotificationTarget` flow opens the task popup; for
    /// subtasks (which carry their own task id) it opens the
    /// subtask directly.
    private func handleNewComment(_ c: CUComment, on task: CUTask) {
        let me = clickUpAuthService.userId
        if let me, c.userId == me { return }

        // Locate the connected user's username so we can
        // detect "@<username>" anywhere in the comment body.
        // Case-insensitive match because ClickUp's mention
        // syntax preserves the user's display casing but
        // people sometimes type the wrong case manually.
        let myUsername = availableMembers.first { $0.id == me }?.username ?? ""
        let isMention = !myUsername.isEmpty
            && c.text.range(of: "@\(myUsername)",
                            options: .caseInsensitive) != nil

        let subtitle = isMention
            ? "Você foi mencionado em um comentário"
            : "Novo comentário"
        let preview: String = {
            let body = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let author = c.userName ?? "Alguém"
            // Trim long comments so the banner stays readable.
            // 200 chars is well past the truncation point macOS
            // applies to the body line, but generous enough that
            // most comments fit verbatim.
            let max = 200
            let snippet = body.count > max
                ? body.prefix(max) + "…"
                : Substring(body)
            return "\(author): \(snippet)"
        }()

        notifyTask(.info,
                   title:    task.title,
                   subtitle: subtitle,
                   message:  preview,
                   taskId:   task.id)
    }

    /// Loads the typed activity log (status changes, uploads,
    /// assignment events, etc.) for a task. Powers the
    /// unified Activity timeline in the task popup —
    /// `TaskActivitySection` interleaves these events with the
    /// comment stream so the user sees one chronological
    /// thread, identical in shape to ClickUp's own panel.
    ///
    /// Errors are swallowed and surfaced as an empty array,
    /// matching `loadComments`'s pattern — the timeline
    /// degrades to comments-only rather than blocking the
    /// popup with a spinner if the history endpoint hiccups.
    func loadActivity(for task: CUTask) async -> [TaskActivityEvent] {
        do {
            return try await cuSvc.getTaskActivity(id: task.id)
        } catch {
            Log.error("loadActivity: \(error)")
            return []
        }
    }

    /// Re-fetches a single task via the per-task ClickUp endpoint
    /// (which, unlike the list endpoint, includes the full
    /// `attachments` array) and merges the result back into
    /// `tasks`. Called when the user opens the task detail popup
    /// so the "Anexos" section reflects every file the task
    /// actually has — including ones uploaded via the web "+
    /// Anexar" button that the list endpoint silently omits.
    /// Also keeps `detailTask` in sync so the popup view re-renders.
    /// On-screen diagnostic for the attachment hydration.
    /// Drives a small banner in the task detail popup so the
    /// user can see what's happening without the console:
    ///   • `.loading` while the request is in flight
    ///   • `.loaded(N)` after a successful fetch
    ///   • `.error(msg)` if the API call failed
    enum HydrationStatus: Equatable {
        case loading
        case loaded(count: Int)
        case error(String)
    }
    @Published var attachmentHydration: [String: HydrationStatus] = [:]

    @MainActor
    func hydrateTaskAttachments(taskId: String) async {
        attachmentHydration[taskId] = .loading
        do {
            let fresh = try await cuSvc.getTask(id: taskId)
            // Merge into the main array so later interactions
            // (e.g. closing the popup and re-opening it) see the
            // hydrated attachments without an extra fetch.
            if let idx = tasks.firstIndex(where: { $0.id == taskId }) {
                // Preserve list-endpoint-only fields by copying
                // attachments onto the existing task rather than
                // wholesale replacing it. Status/dates may have
                // moved on locally via optimistic updates.
                var merged = tasks[idx]
                merged.attachments = fresh.attachments
                // Checklists + custom fields + dependencies are
                // ALSO list-endpoint-omitted (or value-less) —
                // the same getTask call carries them, so hydrate
                // them in the same pass instead of extra
                // round-trips.
                merged.checklists     = fresh.checklists
                merged.customFields   = fresh.customFields
                merged.dependencies   = fresh.dependencies
                merged.linkedTaskIds  = fresh.linkedTaskIds
                tasks[idx] = merged
            }
            // If the popup is currently showing this task, swap
            // the snapshot it holds so the SwiftUI body
            // recomputes with the freshly-loaded files +
            // checklists + custom fields.
            if detailTask?.id == taskId {
                var copy = detailTask!
                copy.attachments   = fresh.attachments
                copy.checklists    = fresh.checklists
                copy.customFields  = fresh.customFields
                copy.dependencies  = fresh.dependencies
                copy.linkedTaskIds = fresh.linkedTaskIds
                detailTask = copy
            }
            // Update any task in the subtask navigation stack
            // (not just the topmost), so freshly hydrated data
            // propagates to whichever level the user navigates
            // back to next.
            for i in detailSubtaskStack.indices where detailSubtaskStack[i].id == taskId {
                var copy = detailSubtaskStack[i]
                copy.attachments   = fresh.attachments
                copy.checklists    = fresh.checklists
                copy.customFields  = fresh.customFields
                copy.dependencies  = fresh.dependencies
                copy.linkedTaskIds = fresh.linkedTaskIds
                detailSubtaskStack[i] = copy
            }
            attachmentHydration[taskId] = .loaded(count: fresh.attachments.count)
            // Time tracking lives on a separate endpoint — fetch
            // it without blocking the attachment banner.
            Task { await hydrateTaskTime(taskId: taskId) }
            // Resolve titles/status for the tasks this one
            // depends on / links to, for the dependencies UI.
            let depIds = Set(fresh.dependencies.map(\.otherTaskId))
                .union(fresh.linkedTaskIds)
            if !depIds.isEmpty {
                Task { await resolveDependencyTasks(Array(depIds)) }
            }
        } catch {
            attachmentHydration[taskId] = .error("\(error)")
        }
    }

    // MARK: - Time tracking

    struct RunningTimer: Equatable {
        let taskId: String
        let startedAt: Date
    }

    /// Total tracked milliseconds per task id (hydrated lazily
    /// when the detail popup opens). Drives the "tempo
    /// registrado" line.
    @Published var taskTrackedMs: [String: Int] = [:]
    /// The connected user's single running timer, if any.
    /// ClickUp allows only one at a time per user.
    @Published var runningTimer: RunningTimer? = nil

    // MARK: - Dependency task resolution

    /// Resolved snapshots (title + status) of tasks referenced
    /// by a dependency / linked-task relation, keyed by id. Lets
    /// the dependencies UI show a real title + status pill
    /// instead of a bare id. Filled best-effort.
    @Published var depTaskCache: [String: CUTask] = [:]

    /// Populates `depTaskCache` for the given ids: cheap hits
    /// from the already-loaded set first, then a bounded set of
    /// getTask calls for the rest (capped so a pathological
    /// dependency fan-out can't storm the API). Read-only.
    @MainActor
    func resolveDependencyTasks(_ ids: [String]) async {
        let missing = ids.filter {
            depTaskCache[$0] == nil
        }
        // Fast path: anything already in the main set.
        for id in missing {
            if let t = tasksById[id] { depTaskCache[id] = t }
        }
        let stillMissing = missing.filter { depTaskCache[$0] == nil }
        // Bounded fetch — dependency lists are tiny in practice;
        // the cap is just a safety valve.
        for id in stillMissing.prefix(12) {
            if let t = try? await cuSvc.getTask(id: id) {
                depTaskCache[id] = t
            }
        }
    }

    /// Fetches the task's tracked total and refreshes the
    /// running-timer state. Cheap, best-effort: failures leave
    /// the previous values untouched rather than flipping the UI
    /// to an error — time tracking is auxiliary, not load-bearing.
    @MainActor
    func hydrateTaskTime(taskId: String) async {
        if let ms = try? await cuSvc.taskTrackedMs(id: taskId) {
            taskTrackedMs[taskId] = ms
        }
        await refreshRunningTimer()
    }

    @MainActor
    func refreshRunningTimer() async {
        guard let wsId = await resolveWorkspaceId() else { return }
        do {
            let cur = try await cuSvc.currentTimer(workspaceId: wsId)
            runningTimer = cur.map { RunningTimer(taskId: $0.taskId,
                                                  startedAt: $0.startedAt) }
        } catch {
            // Transient failure — keep the previous state rather
            // than flapping the timer UI to "not running".
        }
    }

    /// Start the timer on `taskId`, or stop it if it's already
    /// the running task. ClickUp implicitly stops any other
    /// running timer when a new one starts, so the optimistic
    /// state just mirrors that single-timer invariant.
    @MainActor
    func toggleTimer(for taskId: String) async {
        guard let wsId = await resolveWorkspaceId() else {
            notifyTask(.error,
                       title: tasksById[taskId]?.title ?? "Tarefa",
                       subtitle: "Time tracking",
                       message: "Workspace não resolvido.",
                       taskId: taskId)
            return
        }
        let wasRunningHere = runningTimer?.taskId == taskId
        do {
            if wasRunningHere {
                runningTimer = nil
                try await cuSvc.stopTimer(workspaceId: wsId)
            } else {
                runningTimer = RunningTimer(taskId: taskId,
                                            startedAt: Date())
                try await cuSvc.startTimer(workspaceId: wsId,
                                           taskId: taskId)
            }
            // Re-sync from the server so the total + running
            // state reflect ClickUp's truth (e.g. it stopped a
            // different task's timer for us).
            await hydrateTaskTime(taskId: taskId)
        } catch {
            Log.error("toggleTimer: \(error)")
            await refreshRunningTimer()   // roll back to truth
            let api = error as? APIError
            notifyTask(.error,
                       title: tasksById[taskId]?.title ?? "Tarefa",
                       subtitle: api?.userFacingTitle ?? "Time tracking",
                       message: api?.userFacingMessage
                            ?? "Não consegui atualizar o timer.",
                       taskId: taskId)
        }
    }

    /// Optimistically set a drop_down custom field, then PUT it.
    /// Mirrors `toggleChecklistItem`: flip locally everywhere the
    /// task is mirrored, roll back + notify on failure.
    @MainActor
    func setTaskCustomField(taskId: String,
                            fieldId: String,
                            option: CUTask.CustomField.Option) async {
        func apply(_ optId: String?, _ display: String) {
            func patch(_ t: inout CUTask) {
                guard let fi = t.customFields
                        .firstIndex(where: { $0.id == fieldId }) else { return }
                t.customFields[fi].selectedOptionId = optId
                t.customFields[fi].displayValue     = display
            }
            if let i = tasks.firstIndex(where: { $0.id == taskId }) { patch(&tasks[i]) }
            if detailTask?.id == taskId { patch(&detailTask!) }
            for i in detailSubtaskStack.indices
                where detailSubtaskStack[i].id == taskId { patch(&detailSubtaskStack[i]) }
        }

        // Snapshot prior value for rollback.
        let prior = (detailTask?.id == taskId ? detailTask
                     : tasksById[taskId])?
            .customFields.first(where: { $0.id == fieldId })

        apply(option.id, option.name)

        do {
            try await cuSvc.setCustomField(taskId: taskId,
                                           fieldId: fieldId,
                                           optionOrderIndex: option.orderIndex)
            bumpTaskSnapshot(for: taskId)
        } catch {
            Log.error("setTaskCustomField: \(error)")
            apply(prior?.selectedOptionId, prior?.displayValue ?? "")
            let api = error as? APIError
            notifyTask(.error,
                       title: tasksById[taskId]?.title ?? "Tarefa",
                       subtitle: api?.userFacingTitle ?? "Campo personalizado",
                       message: api?.userFacingMessage
                            ?? "Não consegui atualizar o campo.",
                       taskId: taskId)
        }
    }

    /// Posts a review summary back to ClickUp (embedded review workflow).
    /// Replies to the attachment's comment when known (threaded), else a
    /// top-level task comment. @mentions the given members (the uploader) so
    /// ClickUp notifies them.
    /// Bumped after a review is posted so the open comments section auto-reloads
    /// (the review is posted outside the section's own composer, so it wouldn't
    /// refresh on its own). `reviewPostTaskId` scopes it to the right task.
    @Published var reviewPostTick = 0
    var reviewPostTaskId: String?
    /// When a review is posted as a REPLY, this is the parent comment id so the
    /// comments section can auto-expand that thread (otherwise the analysis sits
    /// collapsed behind "Responder · N"). nil when posted as a top-level comment.
    var reviewPostParentId: String?
    /// The freshly posted review comment, for an OPTIMISTIC insert into the
    /// section (ClickUp's read endpoints lag a beat behind the write).
    var reviewPostedReply: CUComment?

    /// Legacy hidden marker prefixing the review-JSON URL (older comments).
    /// Still parsed for back-compat; new comments use the visible link below.
    static let reviewMarker = "⟦apollo-review⟧"

    /// Hosted web viewer base URL (NO trailing slash). Set this ONCE, in code,
    /// after deploying `apollo-review/` as a static site (Vercel/Netlify/GitHub
    /// Pages). When empty, the comment links straight to the raw JSON — Apollo
    /// still reopens it natively, but ClickUp-web users only get a download.
    static let reviewViewerBase = "https://marconiteles.github.io/apollo-review"

    /// Legacy plain-text label (older comments: "▶ Ver review: <url>"). Still
    /// parsed for back-compat; new comments use a compact markdown link.
    static let reviewLinkLabel = "▶ Ver review: "

    /// Visible label for the review link in the ClickUp comment (uppercase).
    static let reviewLinkText = "VER REVIEW"

    /// Build the viewer link carrying the WHOLE review INLINE (`?z=<payload>`),
    /// so the page needs no network fetch — the ClickUp attachment CDN doesn't
    /// send CORS headers, so a `?d=<jsonURL>` fetch fails in the browser. The
    /// payload rides as gzip+base64url (already URL-safe). nil when the viewer
    /// base isn't configured or there's no review data.
    static func reviewLink(reviewJSON: Data) -> String? {
        guard !reviewViewerBase.isEmpty, !reviewJSON.isEmpty else { return nil }
        return "\(reviewViewerBase)/?z=\(ReviewHandoff.encode(reviewJSON))"
    }

    /// Visible label for the "open this file in the web review tool" link that
    /// rides on a reviewable file's comment (shown only in ClickUp).
    static let reviewOpenLinkText = "REVISAR"

    /// Build a link that opens the hosted EDITOR on a RAW file (the "REVISAR"
    /// entry point). Carries the ClickUp context (task/comment/uploader) so the
    /// web editor's "Concluir" can post the review back through Apollo via the
    /// daypanel://review-done callback — exactly like the native flow. nil when
    /// unconfigured.
    static func reviewOpenLink(mediaUrl: String, ext: String, title: String,
                               taskId: String, commentId: String, uploaderId: Int?) -> String? {
        guard !reviewViewerBase.isEmpty, !mediaUrl.isEmpty else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~") // RFC 3986 unreserved
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        var link = "\(reviewViewerBase)/?m=\(enc(mediaUrl))&x=\(enc(ext))&t=\(enc(title))"
        link += "&task=\(enc(taskId))&cmt=\(enc(commentId))"
        if let uploaderId { link += "&up=\(uploaderId)" }
        return link
    }

    /// After reviewable files are attached to a comment, edit that comment to
    /// append "REVISAR" web-review links (one per reviewable file). Shown only in
    /// ClickUp — Apollo strips them since it has the native REVIEW button.
    func postReviewComment(taskId: String, commentId: String?, attachmentId: String,
                           text: String, mentionMemberIds: [Int],
                           reviewJSON: Data = Data()) async {
        let members = mentionMemberIds.compactMap { id in
            availableMembers.first { $0.id == id }
        }
        // `@username` text is visual; the reliable notification is `assignee`.
        let prefix = members.map { "@\($0.username)" }.joined(separator: " ")
        let assignee = mentionMemberIds.first

        // 1. Build the comment as a RICH `comment` segment array: the analysis
        //    text + a labeled "VER REVIEW" hyperlink segment that hides the long
        //    inline-payload URL (?z=…). The whole review rides in the link, so
        //    there's no upload and no CORS-blocked fetch in the web viewer.
        let bodyText = prefix.isEmpty ? text : "\(prefix)\n\(text)"
        guard !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let link = Self.reviewLink(reviewJSON: reviewJSON)
        var segments: [[String: Any]] = [["text": bodyText]]
        if let link {
            // The "▶ " marker is a separate text segment so the linked label is
            // exactly `reviewLinkText` (extractReview matches `[VER REVIEW](…)`).
            // Non-breaking space — ClickUp trims a normal trailing space.
            segments = [
                ["text": bodyText + "\n\n▶\u{00A0}"],
                ["text": Self.reviewLinkText, "attributes": ["link": link]],
            ]
        }

        // 2. Thread under the video's comment when there is one.
        var target = commentId
        if target?.isEmpty ?? true {
            if let comments = try? await cuSvc.getTaskComments(taskId: taskId) {
                target = comments.first { c in
                    c.attachments.contains { $0.id == attachmentId }
                }?.id
            }
        }

        let postedAsReply = !(target?.isEmpty ?? true)
        var postedId: String?
        do {
            if let target, !target.isEmpty {
                postedId = try await cuSvc.addCommentReply(commentId: target, segments: segments, assignee: assignee)
            } else {
                postedId = try await cuSvc.addTaskComment(taskId: taskId, segments: segments, assignee: assignee)
            }
        } catch {
            Log.error("postReviewComment: \(error)")
        }

        // Build an OPTIMISTIC comment locally from the POST-response id + the
        // connected user, so the section shows it INSTANTLY (ClickUp's read
        // endpoints lag a beat). The real id means the later refresh dedups it.
        var posted: CUComment?
        if let postedId {
            let me = clickUpAuthService.userId
            let meMember = availableMembers.first { $0.id == me }
            let displayText = link.map { "\(bodyText)\n\n▶\u{00A0}[\(Self.reviewLinkText)](\($0))" } ?? bodyText
            posted = CUComment(
                id: postedId, text: displayText, date: Date(),
                userId: me, userName: meMember?.username, userEmail: meMember?.email,
                userColor: meMember?.color, initials: meMember?.initials,
                profilePic: meMember?.profilePicture,
                resolved: false, reactions: [], replyCount: 0, attachments: []
            )
        }
        // Auto-reload the open comments section — no manual refresh. Hand over the
        // parent id (to auto-expand the thread) AND the freshly posted comment so
        // the section can insert it OPTIMISTICALLY — ClickUp's read endpoints lag
        // a second or two behind a write, so an immediate refresh alone often
        // misses the new reply.
        await MainActor.run {
            reviewPostTaskId = taskId
            reviewPostParentId = postedAsReply ? target : nil
            reviewPostedReply = posted
            reviewPostTick &+= 1
        }
    }

    func postComment(on task: CUTask,
                     text: String,
                     mentionedMemberIds: [Int] = []) async -> CUComment? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Resolve the mentioned IDs to the full `CUMember`
        // objects ClickUpService needs (it has to emit
        // `@username` text alongside the user_mention id).
        // Filter out IDs that no longer exist in the
        // workspace roster (e.g. member removed since the
        // user typed the mention).
        let resolved = mentionedMemberIds.compactMap { id in
            availableMembers.first { $0.id == id }
        }
        do {
            let result = try await cuSvc.addTaskComment(
                taskId:           task.id,
                text:             trimmed,
                mentionedMembers: resolved
            )
            notifyTask(.success,
                       title:    task.title,
                       subtitle: "Comentário enviado",
                       message:  task.notificationDetails,
                       taskId:   task.id)
            return result
        } catch {
            Log.error("postComment: \(error)")
            notifyTask(.error,
                       title:    task.title,
                       subtitle: "Falha ao enviar comentário",
                       message:  task.notificationDetails,
                       taskId:   task.id)
            return nil
        }
    }

    /// Post a comment that carries a "REVISAR" web-review link for each reviewable
    /// file (built at CREATE time so ClickUp renders the clean label reliably —
    /// editing after the fact via PUT silently fails). Returns an optimistic
    /// CUComment (id from the POST). The REVISAR segment is ClickUp-only — Apollo
    /// strips it (it has the native REVIEW button).
    func postFileComment(on task: CUTask, text: String, mentionMemberIds: [Int],
                         reviewableFiles: [(url: String, ext: String, title: String)]) async -> CUComment? {
        let members = mentionMemberIds.compactMap { id in availableMembers.first { $0.id == id } }
        let uploader = clickUpAuthService.userId
        let links: [(label: String, url: String, title: String)] = reviewableFiles.compactMap { f in
            guard let link = Self.reviewOpenLink(mediaUrl: f.url, ext: f.ext, title: f.title,
                                                 taskId: task.id, commentId: "", uploaderId: uploader)
            else { return nil }
            return (label: Self.reviewOpenLinkText, url: link, title: f.title)
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? " " : text
        Log.info("postFileComment: \(reviewableFiles.count) reviewable, \(links.count) link(s)")
        do {
            guard let id = try await cuSvc.addTaskComment(
                taskId: task.id, text: body, mentionedMembers: members,
                links: links, assignee: mentionMemberIds.first) else { return nil }
            let m = availableMembers.first { $0.id == uploader }
            return CUComment(id: id, text: body, date: Date(), userId: uploader,
                             userName: m?.username, userEmail: m?.email, userColor: m?.color,
                             initials: m?.initials, profilePic: m?.profilePicture,
                             resolved: false, reactions: [], replyCount: 0, attachments: [])
        } catch {
            Log.error("postFileComment: \(error)")
            return nil
        }
    }

    func deleteComment(_ comment: CUComment) async {
        do {
            try await cuSvc.deleteTaskComment(commentId: comment.id)
            notify(.info, title: "Comentário excluído")
        } catch {
            Log.error("deleteComment: \(error)")
            notify(.error, title: "Falha ao excluir comentário")
        }
    }

    /// Uploads `fileURL` straight into the task's attachments — no
    /// comment-with-link side effect. Earlier versions also POSTed a
    /// comment whose body was the resulting URL, but ClickUp already
    /// generates an "X uploaded N file(s)" activity entry for each
    /// real attachment, so the extra comment surfaced as duplicate
    /// noise on the recipient's side (a bare `clickup-attachments.com`
    /// URL above the actual file card). Now the file just attaches
    /// — same UX as drag-and-drop in ClickUp's own web UI.
    /// Returns true on success. `onProgress` receives upload fraction
    /// 0.0…1.0 from a background queue.
    /// Returns the uploaded file's ClickUp URL + attachment id on success (nil on
    /// failure) so the caller can build a "REVISAR" link AND embed the file as a
    /// comment segment.
    @discardableResult
    func uploadCommentAttachment(for task: CUTask,
                                 fileURL: URL,
                                 commentId: String? = nil,
                                 onProgress: (@Sendable (Double) -> Void)? = nil) async -> (url: URL, id: String?)? {
        do {
            let url = try await cuSvc.uploadAttachment(taskId:    task.id,
                                                       fileURL:   fileURL,
                                                       commentId: commentId,
                                                       onProgress: onProgress)
            notifyTask(.success,
                       title:    task.title,
                       subtitle: "Anexo enviado",
                       message:  fileURL.lastPathComponent,
                       taskId:   task.id)
            guard let url else { return nil }
            return (url: url, id: cuSvc.lastUploadedAttachmentId)
        } catch {
            Log.error("uploadCommentAttachment: \(error)")
            notifyTask(.error,
                       title:    task.title,
                       subtitle: "Falha no anexo",
                       message:  fileURL.lastPathComponent,
                       taskId:   task.id)
            return nil
        }
    }

    func toggleCommentReaction(_ comment: CUComment, emoji: String,
                               currentlyReacted: Bool) async {
        do {
            if currentlyReacted {
                try await cuSvc.removeCommentReaction(commentId: comment.id, emoji: emoji)
            } else {
                try await cuSvc.addCommentReaction(commentId: comment.id, emoji: emoji)
            }
            // Reactions are silent — too noisy to surface as toasts.
        } catch {
            Log.error("toggleReaction: \(error)")
            notify(.error, title: "Falha ao reagir", message: emoji)
        }
    }

    func loadReplies(to commentId: String) async -> [CUComment] {
        do { return try await cuSvc.getCommentReplies(commentId: commentId) }
        catch {
            Log.error("loadReplies: \(error)")
            return []
        }
    }

    func postReply(to commentId: String, text: String) async -> CUComment? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let result = try await cuSvc.addCommentReply(commentId: commentId, text: trimmed)
            notify(.success, title: "Resposta enviada")
            return result
        } catch {
            Log.error("postReply: \(error)")
            notify(.error, title: "Falha ao enviar resposta")
            return nil
        }
    }

    /// Removes an event via the Google Calendar API and from
    /// local state. If the detail overlay is showing this
    /// event, it's dismissed too. EventKit fallback removed —
    /// Google is the single calendar source.
    func deleteEvent(_ event: CalendarEvent) async {
        let googleConnected = await MainActor.run { googleAuth.isConnected }
        guard googleConnected else {
            notify(.warning,
                   title: "Conecte o Google",
                   message: "Conecte sua conta Google em Configurações pra excluir.")
            return
        }
        do {
            // `sendUpdates=all` (set inside
            // `googleCalendar.deleteEvent`) notifies any
            // attendees that the meeting was cancelled.
            try await googleCalendar.deleteEvent(eventId: event.id)
            await MainActor.run {
                events.removeAll { $0.id == event.id }
                if detailEvent?.id == event.id {
                    detailEvent = nil
                }
                previousEventSnapshots?.removeValue(forKey: event.id)
            }
            notify(.success, title: "Evento excluído", message: event.title)
        } catch {
            Log.error("deleteEvent: \(error)")
            notify(.error,
                   title: "Não foi possível excluir o evento",
                   message: error.localizedDescription)
        }
    }

    /// Patches an existing event via Google API and updates
    /// local state. Used by the in-app edit sheet (the
    /// "pencil" action on the event detail popup). All
    /// fields are optional — passing nil leaves them
    /// untouched on the server.
    func updateEvent(
        _ event: CalendarEvent,
        title:       String? = nil,
        startDate:   Date?   = nil,
        endDate:     Date?   = nil,
        location:    String? = nil,
        notes:       String? = nil,
        guestEmails: [String]? = nil,
        colorId:     String?  = nil
    ) async {
        let googleConnected = await MainActor.run { googleAuth.isConnected }
        guard googleConnected else {
            notify(.warning,
                   title: "Edição requer Google",
                   message: "Conecte sua conta Google em Configurações.")
            return
        }
        do {
            try await googleCalendar.updateEvent(
                eventId:    event.id,
                calendarId: event.calendarId.isEmpty
                    ? "primary" : event.calendarId,
                title:      title,
                startDate:  startDate,
                endDate:    endDate,
                location:   location,
                notes:      notes,
                attendees:  guestEmails,
                colorId:    colorId
            )
            // Optimistic local update so the dashboard
            // reflects the change immediately, while a
            // background sync reconciles to the canonical
            // server state.
            await MainActor.run {
                if let idx = events.firstIndex(where: { $0.id == event.id }) {
                    var updated = events[idx]
                    if let title    { updated.title     = title }
                    if let startDate { updated.startDate = startDate }
                    if let endDate   { updated.endDate   = endDate }
                    if let location  { updated.location  = location }
                    if let notes     { updated.notes     = notes }
                    if let colorId,
                       let hex = CalendarEvent.googleColorMap[colorId] {
                        updated.colorHex = hex
                    }
                    events[idx] = updated
                    events.sort { $0.startDate < $1.startDate }
                }
                if detailEvent?.id == event.id {
                    detailEvent = events.first(where: { $0.id == event.id })
                }
            }
            notify(.success, title: "Evento atualizado", message: title ?? event.title)
            Task.detached { [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                await self?.sync()
            }
        } catch {
            Log.error("updateEvent: \(error)")
            notify(.error,
                   title: "Não foi possível salvar",
                   message: error.localizedDescription)
        }
    }

    /// Optimistic local RSVP update + push to Google Calendar
    /// via the REST API. Google is the only RSVP backend now —
    /// EventKit/Calendar.app AppleScript bridge was removed.
    func updateRSVP(for event: CalendarEvent,
                    attendeeEmail: String?,
                    to status: CalendarEvent.Attendee.Status) {
        guard let idx = events.firstIndex(where: { $0.id == event.id }) else { return }
        // If we know the attendee email, update that one. Otherwise update
        // the first non-organizer (best-effort guess for the local user).
        if let email = attendeeEmail {
            for i in events[idx].attendees.indices where events[idx].attendees[i].email == email {
                events[idx].attendees[i] = bumpStatus(events[idx].attendees[i], to: status)
            }
        } else if let firstNonOrganizer = events[idx].attendees.firstIndex(where: { !$0.isOrganizer }) {
            events[idx].attendees[firstNonOrganizer] =
                bumpStatus(events[idx].attendees[firstNonOrganizer], to: status)
        }
        if detailEvent?.id == event.id { detailEvent = events[idx] }

        // Pin the optimistic update so the next sync doesn't
        // clobber it before Google has reflected the change.
        // `applyPendingRSVPs` re-applies this on top of every
        // fetched snapshot until either upstream matches or
        // the TTL expires.
        pendingRSVPs[event.id] = PendingRSVP(status: status, setAt: Date())

        // Push to Google. Fire-and-forget — the optimistic
        // overlay above keeps the UI consistent if the
        // request races the next sync.
        Task { [weak self] in
            await self?.respondToEvent(event, status: status)
        }

        let label: String
        switch status {
        case .accepted:  label = "Sim"
        case .declined:  label = "Não"
        case .tentative: label = "Talvez"
        default:         label = "—"
        }
        notifyEvent(.info,
                    title:    event.title,
                    subtitle: "Resposta enviada: \(label)",
                    message:  event.organizerSuffix,
                    eventId:  event.id)
    }

    private func bumpStatus(_ a: CalendarEvent.Attendee,
                            to status: CalendarEvent.Attendee.Status) -> CalendarEvent.Attendee {
        CalendarEvent.Attendee(
            name:        a.name,
            email:       a.email,
            status:      status,
            isOrganizer: a.isOrganizer
        )
    }

    /// Re-applies any unexpired optimistic RSVPs on top of a freshly
    /// fetched event list. If the fetched event already reflects the
    /// pending status (EventKit caught up with the upstream server),
    /// the entry is dropped so we stop overriding from then on.
    private func applyPendingRSVPs(to fetched: [CalendarEvent]) -> [CalendarEvent] {
        guard !pendingRSVPs.isEmpty else { return fetched }

        let now = Date()
        // Drop entries past their TTL — eventually we trust upstream.
        pendingRSVPs = pendingRSVPs.filter {
            now.timeIntervalSince($0.value.setAt) < pendingRSVPTTL
        }
        if pendingRSVPs.isEmpty { return fetched }

        var settledIds: [String] = []
        let merged: [CalendarEvent] = fetched.map { ev in
            guard let pending = pendingRSVPs[ev.id] else { return ev }
            // Find the current user's attendee — best signal we have is
            // the first non-organizer, same heuristic used in updateRSVP.
            guard let meIdx = ev.attendees.firstIndex(where: { !$0.isOrganizer }) else {
                return ev
            }
            // Upstream caught up — clear the pin and stop overriding.
            if ev.attendees[meIdx].status == pending.status {
                settledIds.append(ev.id)
                return ev
            }
            var copy = ev
            copy.attendees[meIdx] = bumpStatus(copy.attendees[meIdx], to: pending.status)
            return copy
        }
        for id in settledIds { pendingRSVPs.removeValue(forKey: id) }
        return merged
    }

    @discardableResult
    func createEvent(
        title:        String,
        startDate:    Date,
        endDate:      Date,
        calendarId:   String?       = nil,
        location:     String?       = nil,
        notes:        String?       = nil,
        meetingURL:   URL?          = nil,
        guestEmails:  [String]      = [],
        availabilityBusy: Bool      = true,
        alarmOffset:  TimeInterval? = nil,
        colorId:      String?       = nil
    ) async -> CalendarEvent? {
        // Calendar source = Google only. EventKit fallback
        // was removed because (a) it lagged Google's web view
        // by 30-60s on writes and (b) it can't transmit
        // attendees on macOS, breaking invitations. Single
        // path → predictable behaviour.
        let googleConnected = await MainActor.run { googleAuth.isConnected }
        guard googleConnected else {
            notify(.warning,
                   title: "Conecte o Google",
                   message: "Conecte sua conta Google em Configurações pra criar eventos.")
            return nil
        }
        do {
            let created = try await googleCalendar.createEvent(
                title:     title,
                startDate: startDate,
                endDate:   endDate,
                location:  location,
                notes:     notes,
                attendees: guestEmails,
                colorId:   colorId
            )
            // Optimistic local insert so the UI sees the
            // event immediately. The next `sync()` tick
            // (kicked off below) replaces it with the
            // canonical server version.
            let placeholder = CalendarEvent(
                id:           created.id,
                title:        title,
                startDate:    startDate,
                endDate:      endDate,
                // Peacock default — matches Google's web UI
                // default colour for primary-calendar events.
                colorHex:     colorId.flatMap { CalendarEvent.googleColorMap[$0] }
                              ?? "#039BE5",
                calendarId:   "google-primary",
                isAllDay:     false,
                location:     location,
                notes:        notes,
                meetingURL:   created.meetingURL.flatMap(URL.init(string:)),
                alarmOffsets: [],
                calendarName: "Google Calendar"
            )
            await MainActor.run {
                events.append(placeholder)
                events.sort { $0.startDate < $1.startDate }
                if previousEventSnapshots != nil {
                    previousEventSnapshots?[placeholder.id] = EventSnapshot(placeholder)
                }
            }
            notifyEvent(.success,
                        title:    title,
                        subtitle: "Evento criado · \(guestEmails.count) convidado\(guestEmails.count == 1 ? "" : "s") notificado\(guestEmails.count == 1 ? "" : "s")",
                        message:  startDate.formatted(.dateTime.day().month(.abbreviated).hour().minute()),
                        eventId:  placeholder.id)
            // 800ms is enough for Google's eventual consistency
            // on `events.list` after a successful
            // `events.insert` — the next sync pulls the
            // canonical record.
            Task.detached { [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                await self?.sync()
            }
            return placeholder
        } catch {
            Log.error("createEvent: \(error)")
            notify(.error,
                   title: title,
                   subtitle: "Falha ao criar evento",
                   message: error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    func createTask(
        title:        String,
        description:  String? = nil,
        status:       String? = nil,
        priority:     Int     = 0,
        startDate:    Date?   = nil,
        dueDate:      Date?   = nil,
        assigneeIds:  [Int]   = [],
        tagNames:     [String] = []
    ) async -> CUTask? {
        guard clickUpAuthService.isConnected,
              KeychainHelper.load(for: KeychainHelper.Keys.clickupListId) != nil else {
            notify(.warning,
                   title: "ClickUp não configurado",
                   message: "Conecte e selecione uma lista nas Configurações.")
            return nil
        }
        do {
            let task = try await cuSvc.createTask(
                title:       title,
                description: description,
                status:      status,
                priority:    priority,
                startDate:   startDate,
                dueDate:     dueDate,
                assigneeIds: assigneeIds,
                tagNames:    tagNames
            )
            await MainActor.run {
                tasks.insert(task, at: 0)
                if previousTaskSnapshots != nil {
                    previousTaskSnapshots?[task.id] = TaskSnapshot(task)
                }
            }
            notifyTask(.success,
                       title:    task.title,
                       subtitle: "Tarefa criada",
                       message:  task.notificationDetails,
                       taskId:   task.id)
            return task
        } catch {
            Log.error("createTask: \(error)")
            notify(.error,
                   title:    title,
                   subtitle: "Falha ao criar tarefa")
            return nil
        }
    }

    /// Creates a subtask under `parent`. Mirrors `createTask`
    /// but routes through the ClickUp `parent`-aware endpoint
    /// and appends the resulting task to `tasks` so the parent
    /// detail popup picks it up via `subtasksByParentId`.
    func createSubtask(
        parent:      CUTask,
        title:       String,
        description: String? = nil,
        status:      String? = nil,
        priority:    Int     = 0,
        startDate:   Date?   = nil,
        dueDate:     Date?   = nil,
        assigneeIds: [Int]   = [],
        tagNames:    [String] = []
    ) async {
        guard clickUpAuthService.isConnected,
              KeychainHelper.load(for: KeychainHelper.Keys.clickupListId) != nil else {
            notify(.warning,
                   title: "ClickUp não configurado",
                   message: "Conecte e selecione uma lista nas Configurações.")
            return
        }
        do {
            let sub = try await cuSvc.createSubtask(
                parentId:    parent.id,
                title:       title,
                description: description,
                status:      status,
                priority:    priority,
                startDate:   startDate,
                dueDate:     dueDate,
                assigneeIds: assigneeIds,
                tagNames:    tagNames
            )
            await MainActor.run {
                // Append rather than insert(at: 0) so subtasks
                // stay in chronological create order under the
                // parent — `rebuildTaskIndex` sorts the children
                // list by `dateCreated` for stable rendering.
                tasks.append(sub)
                if previousTaskSnapshots != nil {
                    previousTaskSnapshots?[sub.id] = TaskSnapshot(sub)
                }
            }
            notifyTask(.success,
                       title:    sub.title,
                       subtitle: "Subtarefa criada em \(parent.title)",
                       message:  sub.notificationDetails,
                       taskId:   sub.id)
        } catch {
            Log.error("createSubtask: \(error)")
            notify(.error,
                   title:    title,
                   subtitle: "Falha ao criar subtarefa")
        }
    }

    // MARK: - Event ↔ Task conversion

    /// Turns a calendar event into a ClickUp task. The task's
    /// due date is the event's start; notes/location/guests are
    /// folded into the description. `status` and `assigneeIds`
    /// override the list defaults when provided. When
    /// `deleteOriginal` (the default — "transform", not "copy")
    /// the source event is removed afterwards; pass `false` to
    /// keep BOTH the event and the new task.
    @discardableResult
    func convertEventToTask(_ event: CalendarEvent,
                            deleteOriginal: Bool = true,
                            status: String? = nil,
                            assigneeIds: [Int] = [])
        async -> CUTask? {
        var lines: [String] = []
        if let n = event.notes?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !n.isEmpty { lines.append(n) }
        if let loc = event.location?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !loc.isEmpty { lines.append("Local: \(loc)") }
        if let url = event.meetingURL {
            lines.append("Link: \(url.absoluteString)")
        }
        let guests = event.attendees
            .map { $0.name.isEmpty ? ($0.email ?? "") : $0.name }
            .filter { !$0.isEmpty }
        if !guests.isEmpty {
            lines.append("Participantes: \(guests.joined(separator: ", "))")
        }
        lines.append("— Convertido de um evento do calendário.")
        let task = await createTask(
            title:       event.title,
            description: lines.joined(separator: "\n"),
            status:      status,
            priority:    0,
            startDate:   event.isAllDay ? nil : event.startDate,
            dueDate:     event.startDate,
            assigneeIds: assigneeIds
        )
        if task != nil, deleteOriginal {
            await deleteEvent(event)
        }
        return task
    }

    /// Turns a ClickUp task into a calendar event. `start`
    /// overrides the slot (else: task start → due → next hour);
    /// `durationMinutes` overrides the length (else: the task's
    /// start→due span, capped at 8 h, else 60 min). When
    /// `deleteOriginal` the source task is removed afterwards.
    @discardableResult
    func convertTaskToEvent(_ task: CUTask,
                            start: Date? = nil,
                            durationMinutes: Int? = nil,
                            deleteOriginal: Bool = true)
        async -> CalendarEvent? {
        let cal = Calendar.current
        let now = Date()
        let startDate: Date = {
            if let s = start { return s }
            if let s = task.startDate, s > now.addingTimeInterval(-86_400) {
                return s
            }
            if let d = task.dueDate { return d }
            var c = cal.dateComponents([.year, .month, .day, .hour],
                                       from: now)
            c.minute = 0
            let base = cal.date(from: c) ?? now
            return cal.date(byAdding: .hour, value: 1, to: base) ?? now
        }()
        let minutes: Int = {
            if let m = durationMinutes, m > 0 { return m }
            if let s = task.startDate, let d = task.dueDate, d > s {
                return min(Int(d.timeIntervalSince(s) / 60), 8 * 60)
            }
            return 60
        }()
        let endDate = startDate
            .addingTimeInterval(TimeInterval(minutes * 60))
        var note = task.description?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !note.isEmpty { note += "\n\n" }
        note += "— Convertido da tarefa do ClickUp · \(task.priorityLabel)."
        let event = await createEvent(
            title:     task.title,
            startDate: startDate,
            endDate:   endDate,
            notes:     note
        )
        if event != nil, deleteOriginal {
            await deleteTask(task)
        }
        return event
    }

    // MARK: - Filtered accessors (call on main thread)

    var eventsForToday: [CalendarEvent] {
        let cal = Calendar.current
        return events
            .filter { cal.isDate($0.startDate, inSameDayAs: selectedDate) }
            .sorted { $0.startDate < $1.startDate }
    }

    var pendingTasks:   [CUTask] { pendingTasksCached }
    var completedTasks: [CUTask] { completedTasksCached }

    /// Default ordering for task pills across the dashboard.
    /// Four-key ascending sort, in this order of precedence:
    ///   1. **ClickUp status group** (PRIMARY) — "Active"
    ///      statuses (`type == "custom"`) sit on top, then
    ///      "Not started" (`type == "open"` — BACKLOG,
    ///      RECORRENTES, CANCELADO etc.), then "Done" /
    ///      "Closed". Without this, ClickUp's per-list
    ///      workflow ordering pushed BACKLOG above TO DO
    ///      because BACKLOG comes earlier in the workflow
    ///      array — but BACKLOG isn't actively-worked.
    ///   2. **Workflow position within group** — status
    ///      earlier in the list's natural workflow sorts up
    ///      first, so TO DO sits above DOING above REVIEW
    ///      above LIBERADO inside the Active group.
    ///   3. **Deadline proximity** — within a status, tasks
    ///      already overdue or closest to their due date
    ///      float up. Tasks with no due date sink to the
    ///      bottom of their status group.
    ///   4. **ClickUp priority** — Urgent (1) on top, then
    ///      High (2), Normal (3), Low (4), None (0 treated
    ///      as last) breaks any remaining ties.
    /// Used by `pendingTasksCached` and the status-filtered
    /// branch in `TaskListView` so the order is consistent
    /// regardless of which filter is active.
    func sortByDeadlineThenPriority(_ tasks: [CUTask]) -> [CUTask] {
        // Pre-compute the status name → (typeRank, workflowIdx)
        // lookup once so every comparison is O(1).
        var statusInfo: [String: (typeRank: Int, idx: Int)] = [:]
        statusInfo.reserveCapacity(availableStatuses.count)
        for (idx, s) in availableStatuses.enumerated() {
            statusInfo[s.status.lowercased()] = (Self.typeRank(for: s.type), idx)
        }
        return tasks.sorted { lhs, rhs in
            let lKey = Self.sortKey(for: lhs, statusInfo: statusInfo)
            let rKey = Self.sortKey(for: rhs, statusInfo: statusInfo)
            if lKey.0 != rKey.0 { return lKey.0 < rKey.0 }
            if lKey.1 != rKey.1 { return lKey.1 < rKey.1 }
            if lKey.2 != rKey.2 { return lKey.2 < rKey.2 }
            if lKey.3 != rKey.3 { return lKey.3 < rKey.3 }
            return lKey.4 < rKey.4
        }
    }

    /// ClickUp's status type categories mapped to a sort rank.
    /// Lower rank = higher in the list. "custom" is the
    /// "Active" group (in-progress work) and outranks "open"
    /// (Not started group: BACKLOG, RECORRENTES, CANCELADO,
    /// etc.) which the user wants pushed to the bottom.
    /// "done"/"closed" come last (mostly excluded by
    /// `isCompleted` anyway, but kept here for safety).
    private static func typeRank(for type: String) -> Int {
        switch type.lowercased() {
        case "custom": return 0  // Active
        case "open":   return 1  // Not started
        case "done":   return 2
        case "closed": return 3
        default:       return 4  // unknown → very bottom
        }
    }

    /// (typeRank, statusIdx, hasNoDate, secondsUntilDue,
    /// priority) — designed so ascending sort yields "active
    /// status, earliest workflow, most urgent deadline,
    /// highest priority first". `statusIdx` is the position
    /// in the workflow (0 = first), with `Int.max` for any
    /// status not present in `availableStatuses`.
    /// `hasNoDate` is 0 for dated tasks, 1 for undated so
    /// undated sinks to bottom of its status group.
    /// `priority` uses `Int.max` for "None".
    private static func sortKey(
        for task: CUTask,
        statusInfo: [String: (typeRank: Int, idx: Int)]
    ) -> (Int, Int, Int, TimeInterval, Int) {
        let now = Date()
        let priority = (task.priority >= 1 && task.priority <= 4)
            ? task.priority : Int.max
        let info = statusInfo[task.status.lowercased()]
        let typeRank  = info?.typeRank ?? 4
        let statusIdx = info?.idx      ?? Int.max
        if let due = task.dueDate {
            return (typeRank, statusIdx, 0, due.timeIntervalSince(now), priority)
        }
        return (typeRank, statusIdx, 1, .infinity, priority)
    }
}
