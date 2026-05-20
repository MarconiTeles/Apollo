import Foundation

/// One concrete action the AI agent can request the app to
/// execute against the live workspace. The agent emits these
/// from chat replies via `[[ACTION_NAME …]]` markers; the
/// executor parses, validates, and routes them to `AppState`.
///
/// Parameters are kept loose (mostly strings) on purpose:
/// local 7B models don't reliably emit structured types like
/// dates or enum cases. The executor coerces strings into
/// `Date`, status enums, priority ints, etc., and rejects
/// (rather than crashes) on bad input.
enum AgentAction {

    // ── ClickUp ────────────────────────────────────────────

    /// Create a new task in the user's currently-selected list.
    /// `assignees` is a free-form comma-separated list of
    /// names / usernames / emails — the executor resolves each
    /// against `appState.availableMembers` (ClickUp roster) and
    /// drops anything it can't match. When the list is empty,
    /// the executor defaults to assigning the connected user.
    case createTask(
        title: String,
        priority: String?,
        due: String?,
        status: String?,
        assignees: String?,
        description: String?,
        start: String?,
        tags: String?,
        parent: String?,
        links: String?,
        attachments: String?
    )

    /// Mark a task complete. `taskRef` is matched against
    /// `appState.tasks` first by `id`, then by exact title,
    /// then by case-insensitive contains.
    case completeTask(taskRef: String)

    /// Move a task to an arbitrary status by name.
    case updateTaskStatus(taskRef: String, newStatus: String)

    /// Change the priority of a task.
    case updateTaskPriority(taskRef: String, newPriority: String)

    // ── Calendar ───────────────────────────────────────────

    /// Create a calendar event. `start` is a datetime string
    /// (ISO `YYYY-MM-DDTHH:MM`, ` `-separated, or relative
    /// like `tomorrow 14:00`). `end` and `durationMinutes` are
    /// alternative ways to express the duration — exactly one
    /// of them should be present, with `end` taking precedence
    /// if both are. `guests` is a comma-separated list of
    /// names or e-mails resolved against the calendar's
    /// recent-attendees roster.
    case createEvent(
        title: String,
        start: String,
        end: String?,
        durationMinutes: String?,
        location: String?,
        guests: String?,
        notes: String?,
        meetingURL: String?,
        color: String?,
        availability: String?,
        alarm: String?
    )

    /// Delete an event. `eventRef` matches against title
    /// (exact, then contains) inside the loaded events
    /// window.
    case deleteEvent(eventRef: String)

    // ── Cross-reference ────────────────────────────────────

    /// Block calendar time to work on a specific task. Creates
    /// an event whose title is the task's title (so the
    /// timeline pill matches the task pill), at the given
    /// start time for the given duration. The task's due date
    /// stays untouched — the user can still extend or move it
    /// — but the calendar now blocks the requested work
    /// window. This is the primary "cross between Calendar and
    /// ClickUp" action.
    case scheduleTaskWork(
        taskRef: String,
        start: String,
        durationMinutes: String
    )

    /// Transform an event into a ClickUp task. The new task is
    /// created with the event's data folded in (notes, location,
    /// guests → description; start → due). Any of the create-
    /// task fields below override the derived defaults so the
    /// AI can enrich the conversion (assignees, status, links,
    /// attachments, etc.). `deleteSource` defaults to "true";
    /// pass "false"/"no"/"não" to keep BOTH the event and the
    /// new task.
    case convertEventToTask(eventRef: String,
                            deleteSource: String?,
                            titleOverride: String?,
                            status: String?,
                            priority: String?,
                            assignees: String?,
                            description: String?,
                            start: String?,
                            due: String?,
                            tags: String?,
                            links: String?,
                            attachments: String?)

    /// Transform a ClickUp task into a calendar event. Mirrors
    /// `convertEventToTask` — any create-event field can be
    /// supplied (guests, location, meetingURL, etc.); the rest
    /// fall back to the task's own start/due window.
    case convertTaskToEvent(taskRef: String,
                            deleteSource: String?,
                            titleOverride: String?,
                            start: String?,
                            end: String?,
                            durationMinutes: String?,
                            location: String?,
                            guests: String?,
                            notes: String?,
                            meetingURL: String?,
                            color: String?,
                            availability: String?,
                            alarm: String?)

    // ── Extended task mutations ────────────────────────────

    case updateTaskDue(taskRef: String, due: String?)        // nil/"" clears
    case updateTaskStart(taskRef: String, start: String?)
    case updateTaskTitle(taskRef: String, newTitle: String)
    /// `description` nil → keep the task's current body (only
    /// append links / upload files). `links` are appended as
    /// clickable URLs; `attachments` local paths are uploaded as
    /// real task attachments, http(s) entries become links.
    case updateTaskDescription(taskRef: String, description: String?,
                               links: String?, attachments: String?)
    /// `add` and `remove` are comma-separated names/emails/ids.
    /// Either can be empty; both empty is a no-op.
    case updateTaskAssignees(taskRef: String, add: String?, remove: String?)
    case addTaskTag(taskRef: String, tag: String)
    case removeTaskTag(taskRef: String, tag: String)
    /// Post a comment. `text` may be nil when only files are
    /// sent. `attachments` local paths are uploaded onto the
    /// comment; http(s) entries are appended to the comment text
    /// as links.
    case addTaskComment(taskRef: String, text: String?,
                        attachments: String?)
    /// Attach files to an existing task (no comment). Local
    /// paths upload as real attachments; http(s) URLs are
    /// recorded as a link comment.
    case addTaskAttachment(taskRef: String, files: String)
    case createSubtask(parentRef: String, title: String,
                       priority: String?, due: String?, assignees: String?)
    case deleteTask(taskRef: String)
    case archiveTask(taskRef: String)
    case duplicateTask(taskRef: String, newTitle: String?)
    case moveTaskToList(taskRef: String, listName: String)

    // ── Extended calendar mutations ────────────────────────

    /// Update an existing event. Any of start/end/duration/title/
    /// location/guests can be supplied; the executor only writes
    /// the ones that are non-nil. `addGuests` appends emails to
    /// the existing attendees list (so you can grow an event's
    /// invite roster without dropping the people already on it).
    case updateEvent(
        eventRef: String,
        newStart: String?,
        newEnd: String?,
        newDurationMinutes: String?,
        newTitle: String?,
        newLocation: String?,
        addGuests: String?
    )
    case respondToEvent(eventRef: String, status: String)  // accept|decline|tentative

    // ── Batch / bulk ───────────────────────────────────────

    /// Multiple `[[CREATE_TASK …]]` markers can already do this
    /// implicitly, but a single `BATCH_CREATE_TASKS` lets the
    /// model emit a JSON array of titles in one shot — handy
    /// when the user dictates "cria 5 tarefas: A, B, C, D, E".
    case batchCreateTasks(titlesJSON: String)
    case bulkUpdateStatus(filter: String, newStatus: String)
    case bulkReassign(filter: String, fromName: String?, toName: String)

    // ── App / UI control ───────────────────────────────────

    case openTask(taskRef: String)
    case openEvent(eventRef: String)
    case jumpToDate(date: String)
    case switchList(listName: String)
    case triggerSync
    case setSearch(query: String)
    case setFilter(priority: String?, assignees: String?,
                   tags: String?, status: String?)
    case clearFilters

    // ── Notifications / reminders ──────────────────────────

    /// Schedules a future notification banner. `fireDate` is
    /// a flexible datetime string (ISO, "amanhã 09:00", "2026-
    /// 05-12 14:30") OR a relative-to-target offset
    /// ("3 dias antes da X", encoded as `relativeOffset` +
    /// `relativeTo`). Either `fireDate` OR (`relativeOffset`+
    /// `relativeTo`) must be present.
    case scheduleReminder(
        title: String,
        body: String?,
        fireDate: String?,
        relativeOffset: String?,   // "3 dias", "2h", "30min"
        relativeTo: String?,       // task or event title
        relativeBefore: Bool       // true = before, false = after
    )

    /// Lists pending reminders the user previously scheduled.
    case fetchPendingReminders

    /// Cancels a pending reminder by id (uuid).
    case cancelReminder(reminderId: String)

    // ── Read / fetch (no mutation) ─────────────────────────
    //
    // The actions below FETCH data on-demand to fill gaps in
    // what the system prompt could pre-load. The agent emits
    // them when the user asks about things that aren't in the
    // prompt (comments, full descriptions, attachments,
    // workspace lists, etc). The executor runs them, formats
    // the result as a hidden context note, and re-invokes the
    // model with that note appended — so the user sees ONE
    // final answer with the live data, not a "let me look up"
    // turnaround.

    /// Fetches all comments + threaded replies for a task.
    /// Resolves `taskRef` like the other action shapes (id →
    /// title → contains). Returns formatted text the model
    /// can quote directly.
    case fetchComments(taskRef: String)

    /// Fetches the FULL canonical task payload from ClickUp
    /// — full description (untruncated), every attachment,
    /// every assignee, custom fields, time tracking, etc.
    /// Use when the snippet in the prompt isn't enough.
    case fetchTaskDetails(taskRef: String)

    /// Lists the OTHER ClickUp lists the user has access to.
    /// Lets the AI answer "que listas existem?" / "tenho
    /// outras listas no clickup?" — the prompt itself only
    /// carries data from the active list.
    case fetchWorkspaceLists

    /// Activity log for one task — every status change /
    /// rename / reassignment / comment, ordered newest first.
    case fetchTaskHistory(taskRef: String)

    /// Time-tracking entries logged for one task. Empty when
    /// the user doesn't track time on the task.
    case fetchTimeEntries(taskRef: String)
}

/// Outcome returned by the executor for each action it tried.
/// The chat layer uses these to render confirmation pills, or
/// error messages when something went wrong.
enum AgentActionResult {
    case createdTask(CUTask)
    case updatedTask(CUTask)
    case createdEvent(CalendarEvent)
    case deletedEvent(title: String)
    case failed(reason: String)

    // Read-action results — carry rich text the model can
    // reason about in the second-pass invocation. Not surfaced
    // as visible pills; instead they're fed back into the
    // conversation as hidden context.
    case fetchedContext(label: String, body: String)
}

extension AgentAction {
    /// True for actions that READ data (don't mutate state).
    /// The agent pipeline treats reads specially: their results
    /// feed back into a second model invocation so the user
    /// sees a single coherent answer, not a "looking up…" round
    /// trip.
    var isRead: Bool {
        switch self {
        case .fetchComments, .fetchTaskDetails, .fetchWorkspaceLists,
             .fetchTaskHistory, .fetchTimeEntries,
             .fetchPendingReminders:
            return true
        default:
            return false
        }
    }
}
