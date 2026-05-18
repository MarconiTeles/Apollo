import Foundation

/// Extracts `[[ACTION_NAME key="value" key2="value2"]]` markers
/// from an AI response and returns both:
///   1. The text with markers stripped (what the user actually
///      sees in the chat bubble)
///   2. The parsed `AgentAction` list (what the executor runs)
///
/// Format chosen for local 7B compliance:
///   • `[[` and `]]` are easy for the model to reliably emit
///     (both are 2-character tokens that encode predictably).
///   • `key="value"` is a familiar attribute syntax — Qwen has
///     seen XML/HTML and JSON-ish syntax in training, so it
///     follows the pattern naturally.
///   • Whitespace between attributes is tolerated — so
///     `[[CREATE_TASK title="X" priority="urgent"]]`,
///     `[[CREATE_TASK   title="X"    priority="urgent"  ]]`,
///     and even line-broken variants all parse the same.
///
/// Anything inside `[[ … ]]` that doesn't match a known action
/// name is left in the visible text untouched (so the user can
/// see and report odd model output).
enum AgentActionParser {

    /// Parse `text` once, returning the stripped text and the
    /// list of actions to execute in document order.
    static func extract(from text: String) -> (cleanedText: String, actions: [AgentAction]) {
        // Bracket pair non-greedy match. NSRegularExpression
        // doesn't support `(?s)` reliably across platforms but
        // `.` matches anything except newline by default — for
        // multi-line markers we use `[\\s\\S]` instead.
        // `\s*` (not `\s+`) between name and attribute body so
        // attribute-less markers like `[[GET_LISTS]]` also
        // match. The attribute-body capture itself can be empty.
        let pattern = #"\[\[\s*([A-Z_]+)\s*([\s\S]*?)\s*\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (text, [])
        }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)
        guard !matches.isEmpty else { return (text, []) }

        var actions: [AgentAction] = []
        var cleaned = ""
        var cursor = text.startIndex

        for match in matches {
            guard let fullRange = Range(match.range, in: text),
                  let nameRange = Range(match.range(at: 1), in: text),
                  let attrRange = Range(match.range(at: 2), in: text)
            else { continue }

            // Append the text before this match to the cleaned
            // output.
            cleaned.append(contentsOf: text[cursor..<fullRange.lowerBound])

            let name  = String(text[nameRange])
            let attrs = parseAttributes(String(text[attrRange]))

            if let action = buildAction(name: name, attrs: attrs) {
                actions.append(action)
                // Don't append the marker itself — the executor
                // will inject a real result pill in its place
                // when it runs.
            } else {
                // Unknown action name — leave it visible so the
                // user / dev can see what the model emitted.
                cleaned.append(contentsOf: text[fullRange])
            }
            cursor = fullRange.upperBound
        }
        // Tail.
        cleaned.append(contentsOf: text[cursor..<text.endIndex])
        return (cleaned, actions)
    }

    // MARK: - Attribute parser

    /// Parses `key="value"` pairs into a dictionary. Tolerates
    /// extra whitespace, supports values with spaces and
    /// punctuation as long as they're inside double quotes.
    /// Example: `title="Buy bread" due="2026-05-02"` →
    /// `["title": "Buy bread", "due": "2026-05-02"]`.
    private static func parseAttributes(_ s: String) -> [String: String] {
        var attrs: [String: String] = [:]
        let pattern = #"([a-zA-Z_]+)\s*=\s*"([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return attrs
        }
        let nsRange = NSRange(s.startIndex..., in: s)
        for match in regex.matches(in: s, range: nsRange) {
            guard let kRange = Range(match.range(at: 1), in: s),
                  let vRange = Range(match.range(at: 2), in: s)
            else { continue }
            attrs[String(s[kRange]).lowercased()] = String(s[vRange])
        }
        return attrs
    }

    // MARK: - Action factory

    /// Maps an `(action name, attribute dict)` pair onto a
    /// concrete `AgentAction`. Returns nil for unknown names
    /// or missing required fields — the parser leaves those
    /// markers in the visible text so they're reportable.
    private static func buildAction(name: String,
                                    attrs: [String: String]) -> AgentAction? {
        switch name {
        case "CREATE_TASK":
            guard let title = attrs["title"], !title.isEmpty else {
                return nil
            }
            // Hoisted into locals: a single big `.createTask(...)`
            // literal with these `??` chains blows the Swift
            // type-checker's budget ("unable to type-check in
            // reasonable time").
            let ctAssignees:   String? = attrs["assignees"] ?? attrs["assignee"]
            let ctDescription: String? = attrs["description"] ?? attrs["desc"] ?? attrs["notes"]
            let ctStart:       String? = attrs["start"] ?? attrs["start_date"]
            let ctTags:        String? = attrs["tags"] ?? attrs["tag"]
            let ctParent:      String? = attrs["parent"] ?? attrs["parent_task"] ?? attrs["parent_id"]
            let ctLinks:       String? = attrs["links"] ?? attrs["link"] ?? attrs["url"]
            let ctAttachments: String? = attrs["attachments"] ?? attrs["attachment"] ?? attrs["files"] ?? attrs["file"]
            return .createTask(
                title:       title,
                priority:    attrs["priority"],
                due:         attrs["due"],
                status:      attrs["status"],
                assignees:   ctAssignees,
                description: ctDescription,
                start:       ctStart,
                tags:        ctTags,
                parent:      ctParent,
                links:       ctLinks,
                attachments: ctAttachments
            )

        case "COMPLETE_TASK":
            if let id = attrs["task_id"], !id.isEmpty {
                return .completeTask(taskRef: id)
            }
            if let title = attrs["title"], !title.isEmpty {
                return .completeTask(taskRef: title)
            }
            return nil

        case "UPDATE_TASK_STATUS":
            guard let ref = attrs["task_id"] ?? attrs["title"], !ref.isEmpty,
                  let status = attrs["status"], !status.isEmpty
            else { return nil }
            return .updateTaskStatus(taskRef: ref, newStatus: status)

        case "UPDATE_TASK_PRIORITY":
            guard let ref = attrs["task_id"] ?? attrs["title"], !ref.isEmpty,
                  let prio = attrs["priority"], !prio.isEmpty
            else { return nil }
            return .updateTaskPriority(taskRef: ref, newPriority: prio)

        case "CREATE_EVENT":
            guard let title = attrs["title"], !title.isEmpty,
                  let start = attrs["start"], !start.isEmpty
            else { return nil }
            // Hoisted (see CREATE_TASK note) — keeps the Swift
            // type-checker inside its time budget.
            let ceDuration: String? = attrs["duration"] ?? attrs["minutes"]
            let ceGuests:   String? = attrs["guests"] ?? attrs["guest"]
            let ceNotes:    String? = attrs["notes"] ?? attrs["description"] ?? attrs["desc"]
            let ceMeet:     String? = attrs["meeting_url"] ?? attrs["meetingURL"] ?? attrs["meet"] ?? attrs["video"]
            let ceColor:    String? = attrs["color"] ?? attrs["colorId"] ?? attrs["color_id"]
            let ceAvail:    String? = attrs["availability"] ?? attrs["busy"] ?? attrs["free"]
            let ceAlarm:    String? = attrs["alarm"] ?? attrs["reminder"] ?? attrs["alarm_minutes"]
            return .createEvent(
                title:           title,
                start:           start,
                end:             attrs["end"],
                durationMinutes: ceDuration,
                location:        attrs["location"],
                guests:          ceGuests,
                notes:           ceNotes,
                meetingURL:      ceMeet,
                color:           ceColor,
                availability:    ceAvail,
                alarm:           ceAlarm
            )

        case "DELETE_EVENT":
            guard let ref = attrs["event_id"] ?? attrs["title"],
                  !ref.isEmpty
            else { return nil }
            return .deleteEvent(eventRef: ref)

        case "SCHEDULE_TASK_WORK":
            guard let ref = attrs["task_id"] ?? attrs["title"],
                  !ref.isEmpty,
                  let start = attrs["start"], !start.isEmpty,
                  let dur = attrs["duration"] ?? attrs["minutes"],
                  !dur.isEmpty
            else { return nil }
            return .scheduleTaskWork(
                taskRef: ref,
                start: start,
                durationMinutes: dur
            )

        case "CONVERT_EVENT_TO_TASK", "EVENT_TO_TASK":
            guard let ref = attrs["event_id"] ?? attrs["title"]
                            ?? attrs["event"],
                  !ref.isEmpty
            else { return nil }
            return .convertEventToTask(eventRef: ref)

        case "CONVERT_TASK_TO_EVENT", "TASK_TO_EVENT":
            guard let ref = attrs["task_id"] ?? attrs["title"]
                            ?? attrs["task"],
                  !ref.isEmpty
            else { return nil }
            return .convertTaskToEvent(
                taskRef: ref,
                start: attrs["start"] ?? attrs["start_date"],
                durationMinutes: attrs["duration"] ?? attrs["minutes"])

        // ── Read / fetch markers ───────────────────────────
        // Format mirrors the mutation markers — same parser
        // path, just yields read actions whose results feed
        // back into a second model invocation instead of
        // mutating state.

        case "GET_COMMENTS", "FETCH_COMMENTS":
            guard let ref = attrs["task_id"] ?? attrs["title"] ?? attrs["task"],
                  !ref.isEmpty
            else { return nil }
            return .fetchComments(taskRef: ref)

        case "GET_TASK", "FETCH_TASK", "GET_TASK_DETAILS":
            guard let ref = attrs["task_id"] ?? attrs["title"] ?? attrs["task"],
                  !ref.isEmpty
            else { return nil }
            return .fetchTaskDetails(taskRef: ref)

        case "GET_LISTS", "FETCH_LISTS", "GET_WORKSPACE_LISTS":
            return .fetchWorkspaceLists

        case "GET_TASK_HISTORY", "FETCH_TASK_HISTORY", "GET_HISTORY":
            guard let ref = attrs["task_id"] ?? attrs["title"] ?? attrs["task"],
                  !ref.isEmpty
            else { return nil }
            return .fetchTaskHistory(taskRef: ref)

        case "GET_TIME_ENTRIES", "FETCH_TIME_ENTRIES":
            guard let ref = attrs["task_id"] ?? attrs["title"] ?? attrs["task"],
                  !ref.isEmpty
            else { return nil }
            return .fetchTimeEntries(taskRef: ref)

        // ── Extended task mutations ────────────────────────

        case "UPDATE_TASK_DUE", "SET_DUE":
            guard let ref = attrs["task_id"] ?? attrs["title"], !ref.isEmpty
            else { return nil }
            return .updateTaskDue(taskRef: ref, due: attrs["due"] ?? attrs["date"])

        case "UPDATE_TASK_START", "SET_START":
            guard let ref = attrs["task_id"] ?? attrs["title"], !ref.isEmpty
            else { return nil }
            return .updateTaskStart(taskRef: ref, start: attrs["start"] ?? attrs["date"])

        case "UPDATE_TASK_TITLE", "RENAME_TASK":
            guard let ref = attrs["task_id"] ?? attrs["title"], !ref.isEmpty,
                  let newTitle = attrs["new_title"] ?? attrs["to"], !newTitle.isEmpty
            else { return nil }
            return .updateTaskTitle(taskRef: ref, newTitle: newTitle)

        case "UPDATE_TASK_DESCRIPTION", "SET_DESCRIPTION":
            guard let ref = attrs["task_id"] ?? attrs["title"], !ref.isEmpty
            else { return nil }
            let utdDesc:  String? = attrs["description"] ?? attrs["text"]
            let utdLinks: String? = attrs["links"] ?? attrs["link"] ?? attrs["url"]
            let utdFiles: String? = attrs["attachments"] ?? attrs["attachment"] ?? attrs["files"] ?? attrs["file"]
            // Need at least one of: new body, links, files.
            guard utdDesc != nil || utdLinks != nil || utdFiles != nil
            else { return nil }
            return .updateTaskDescription(taskRef: ref,
                                          description: utdDesc,
                                          links: utdLinks,
                                          attachments: utdFiles)

        case "UPDATE_TASK_ASSIGNEES", "REASSIGN_TASK":
            guard let ref = attrs["task_id"] ?? attrs["title"], !ref.isEmpty
            else { return nil }
            let add    = attrs["add"]    ?? attrs["assignees"]
            let remove = attrs["remove"] ?? attrs["rem"]
            guard add != nil || remove != nil else { return nil }
            return .updateTaskAssignees(taskRef: ref, add: add, remove: remove)

        case "ADD_TASK_TAG", "ADD_TAG":
            guard let ref = attrs["task_id"] ?? attrs["title"], !ref.isEmpty,
                  let tag = attrs["tag"], !tag.isEmpty
            else { return nil }
            return .addTaskTag(taskRef: ref, tag: tag)

        case "REMOVE_TASK_TAG", "REMOVE_TAG":
            guard let ref = attrs["task_id"] ?? attrs["title"], !ref.isEmpty,
                  let tag = attrs["tag"], !tag.isEmpty
            else { return nil }
            return .removeTaskTag(taskRef: ref, tag: tag)

        case "ADD_TASK_COMMENT", "COMMENT", "POST_COMMENT":
            guard let ref = attrs["task_id"] ?? attrs["title"], !ref.isEmpty
            else { return nil }
            let cmText:  String? = attrs["text"] ?? attrs["comment"]
            let cmFiles: String? = attrs["attachments"] ?? attrs["attachment"] ?? attrs["files"] ?? attrs["file"]
            // A comment needs text OR at least one file.
            let hasText = cmText.map { !$0.isEmpty } ?? false
            guard hasText || (cmFiles?.isEmpty == false) else { return nil }
            return .addTaskComment(taskRef: ref,
                                   text: hasText ? cmText : nil,
                                   attachments: cmFiles)

        case "ADD_TASK_ATTACHMENT", "ATTACH_FILE", "ADD_ATTACHMENT",
             "ATTACH":
            guard let ref = attrs["task_id"] ?? attrs["title"], !ref.isEmpty,
                  let files = attrs["attachments"] ?? attrs["attachment"]
                              ?? attrs["files"] ?? attrs["file"]
                              ?? attrs["url"],
                  !files.isEmpty
            else { return nil }
            return .addTaskAttachment(taskRef: ref, files: files)

        case "CREATE_SUBTASK":
            guard let parent = attrs["parent"] ?? attrs["parent_title"] ?? attrs["task_id"],
                  !parent.isEmpty,
                  let title = attrs["title"], !title.isEmpty
            else { return nil }
            return .createSubtask(
                parentRef: parent,
                title: title,
                priority: attrs["priority"],
                due: attrs["due"],
                assignees: attrs["assignees"] ?? attrs["assignee"]
            )

        case "DELETE_TASK":
            guard let ref = attrs["task_id"] ?? attrs["title"], !ref.isEmpty
            else { return nil }
            return .deleteTask(taskRef: ref)

        case "ARCHIVE_TASK":
            guard let ref = attrs["task_id"] ?? attrs["title"], !ref.isEmpty
            else { return nil }
            return .archiveTask(taskRef: ref)

        case "DUPLICATE_TASK", "CLONE_TASK":
            guard let ref = attrs["task_id"] ?? attrs["title"], !ref.isEmpty
            else { return nil }
            return .duplicateTask(taskRef: ref, newTitle: attrs["new_title"])

        case "MOVE_TASK_TO_LIST", "MOVE_TASK":
            guard let ref = attrs["task_id"] ?? attrs["title"], !ref.isEmpty,
                  let list = attrs["list"] ?? attrs["to"], !list.isEmpty
            else { return nil }
            return .moveTaskToList(taskRef: ref, listName: list)

        // ── Extended calendar mutations ────────────────────

        case "UPDATE_EVENT", "MOVE_EVENT", "EDIT_EVENT":
            guard let ref = attrs["event_id"] ?? attrs["title"], !ref.isEmpty
            else { return nil }
            return .updateEvent(
                eventRef: ref,
                newStart: attrs["start"] ?? attrs["new_start"],
                newEnd:   attrs["end"]   ?? attrs["new_end"],
                newDurationMinutes: attrs["duration"] ?? attrs["minutes"],
                newTitle: attrs["new_title"],
                newLocation: attrs["location"],
                // Comma-separated list of emails (or names that
                // resolve to emails) to APPEND to the event's
                // attendees. Accepts a few common synonyms so the
                // model can pick whichever reads natural.
                addGuests: attrs["add_guests"]
                    ?? attrs["guests"]
                    ?? attrs["attendees"]
                    ?? attrs["invite"]
            )

        case "ACCEPT_EVENT", "RSVP_ACCEPT":
            guard let ref = attrs["event_id"] ?? attrs["title"], !ref.isEmpty
            else { return nil }
            return .respondToEvent(eventRef: ref, status: "accepted")

        case "DECLINE_EVENT", "RSVP_DECLINE":
            guard let ref = attrs["event_id"] ?? attrs["title"], !ref.isEmpty
            else { return nil }
            return .respondToEvent(eventRef: ref, status: "declined")

        case "TENTATIVE_EVENT", "RSVP_TENTATIVE":
            guard let ref = attrs["event_id"] ?? attrs["title"], !ref.isEmpty
            else { return nil }
            return .respondToEvent(eventRef: ref, status: "tentative")

        // ── Batch / bulk ───────────────────────────────────

        case "BATCH_CREATE_TASKS":
            guard let titles = attrs["titles"], !titles.isEmpty
            else { return nil }
            return .batchCreateTasks(titlesJSON: titles)

        case "BULK_UPDATE_STATUS":
            guard let filter = attrs["filter"] ?? attrs["where"], !filter.isEmpty,
                  let newStatus = attrs["status"], !newStatus.isEmpty
            else { return nil }
            return .bulkUpdateStatus(filter: filter, newStatus: newStatus)

        case "BULK_REASSIGN":
            guard let filter = attrs["filter"] ?? attrs["where"], !filter.isEmpty,
                  let to = attrs["to"], !to.isEmpty
            else { return nil }
            return .bulkReassign(filter: filter,
                                 fromName: attrs["from"],
                                 toName: to)

        // ── UI control ─────────────────────────────────────

        case "OPEN_TASK":
            guard let ref = attrs["task_id"] ?? attrs["title"], !ref.isEmpty
            else { return nil }
            return .openTask(taskRef: ref)

        case "OPEN_EVENT":
            guard let ref = attrs["event_id"] ?? attrs["title"], !ref.isEmpty
            else { return nil }
            return .openEvent(eventRef: ref)

        case "JUMP_TO_DATE", "GOTO_DATE":
            guard let date = attrs["date"], !date.isEmpty
            else { return nil }
            return .jumpToDate(date: date)

        case "SWITCH_LIST", "CHANGE_LIST":
            guard let list = attrs["list"] ?? attrs["name"], !list.isEmpty
            else { return nil }
            return .switchList(listName: list)

        case "TRIGGER_SYNC", "SYNC":
            return .triggerSync

        case "SET_SEARCH", "SEARCH":
            return .setSearch(query: attrs["query"] ?? attrs["q"] ?? "")

        case "SET_FILTER", "FILTER":
            return .setFilter(
                priority:  attrs["priority"],
                assignees: attrs["assignees"] ?? attrs["assignee"],
                tags:      attrs["tags"] ?? attrs["tag"],
                status:    attrs["status"]
            )

        case "CLEAR_FILTERS", "RESET_FILTERS":
            return .clearFilters

        case "SCHEDULE_REMINDER", "REMIND", "REMIND_ME":
            guard let title = attrs["title"] ?? attrs["text"], !title.isEmpty
            else { return nil }
            // Either an absolute fire date OR a relative offset
            // anchored on a task/event. The model may emit
            // either; the executor handles both.
            let fireDate    = attrs["at"] ?? attrs["fire"] ?? attrs["date"] ?? attrs["when"]
            let offset      = attrs["offset"] ?? attrs["before"] ?? attrs["after"]
            let anchorRef   = attrs["task"] ?? attrs["event"] ?? attrs["target"]
            let isBefore    = attrs["after"] == nil
            guard fireDate != nil || (offset != nil && anchorRef != nil)
            else { return nil }
            return .scheduleReminder(
                title:          title,
                body:           attrs["body"] ?? attrs["message"],
                fireDate:       fireDate,
                relativeOffset: offset,
                relativeTo:     anchorRef,
                relativeBefore: isBefore
            )

        case "GET_REMINDERS", "LIST_REMINDERS", "FETCH_REMINDERS":
            return .fetchPendingReminders

        case "CANCEL_REMINDER":
            guard let id = attrs["id"] ?? attrs["reminder_id"], !id.isEmpty
            else { return nil }
            return .cancelReminder(reminderId: id)

        default:
            return nil
        }
    }
}
