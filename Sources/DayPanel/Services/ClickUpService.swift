import Foundation
import UniformTypeIdentifiers

private extension Data {
    /// Convenience for building multipart/form-data bodies.
    mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
}

final class ClickUpService {
    private let auth: ClickUpAuthService
    init(auth: ClickUpAuthService) { self.auth = auth }

    private var token:  String? { auth.accessToken }   // reads dp_clickup_token
    private var listId: String? { KeychainHelper.load(for: KeychainHelper.Keys.clickupListId) }


    // MARK: - Tasks

    func listTasks() async throws -> [CUTask] {
        guard let token, let listId else { throw CUError.notConfigured }

        var comps = URLComponents(string: "https://api.clickup.com/api/v2/list/\(listId)/task")!
        comps.queryItems = [
            URLQueryItem(name: "include_closed", value: "true"),
            // `subtasks=true` makes ClickUp include child tasks in
            // the response (each with its `parent` field set to
            // the parent task's id). The app filters them out of
            // the top-level list view and only surfaces them
            // under the parent's detail popup.
            URLQueryItem(name: "subtasks",       value: "true"),
        ]

        var req = URLRequest(url: comps.url!)
        req.setValue(token, forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: req)
        return parseTasks(data)
    }

    func createTask(
        title:        String,
        description:  String? = nil,
        status:       String? = nil,
        priority:     Int     = 0,
        startDate:    Date?   = nil,
        dueDate:      Date?   = nil,
        assigneeIds:  [Int]   = [],
        tagNames:     [String] = []
    ) async throws -> CUTask {
        guard let token, let listId else { throw CUError.notConfigured }

        var body: [String: Any] = ["name": title]
        if let description, !description.isEmpty { body["description"] = description }
        if let status                              { body["status"]      = status }
        if priority > 0                            { body["priority"]    = priority }
        if let startDate {
            body["start_date"]      = Int(startDate.timeIntervalSince1970 * 1000)
            body["start_date_time"] = true
        }
        if let dueDate {
            body["due_date"]      = Int(dueDate.timeIntervalSince1970 * 1000)
            body["due_date_time"] = true
        }
        if !assigneeIds.isEmpty { body["assignees"] = assigneeIds }
        if !tagNames.isEmpty    { body["tags"]      = tagNames }

        var req = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/list/\(listId)/task")!)
        req.httpMethod = "POST"
        req.setValue(token,             forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let task = parseTasks(data, single: true).first else { throw CUError.parse }
        return task
    }

    /// Creates a subtask under `parentId`. ClickUp's same
    /// `POST /list/{list_id}/task` endpoint accepts a `parent`
    /// field — the new task is created in the same list as the
    /// parent and inherits no defaults beyond what's passed.
    /// The returned `CUTask` already has its `parentId` set so
    /// callers can drop it straight into `appState.tasks`.
    func createSubtask(
        parentId:    String,
        title:       String,
        description: String? = nil,
        status:      String? = nil,
        priority:    Int     = 0,
        startDate:   Date?   = nil,
        dueDate:     Date?   = nil,
        assigneeIds: [Int]   = [],
        tagNames:    [String] = []
    ) async throws -> CUTask {
        guard let token, let listId else { throw CUError.notConfigured }

        var body: [String: Any] = [
            "name":   title,
            "parent": parentId
        ]
        if let description, !description.isEmpty { body["description"] = description }
        if let status                              { body["status"]      = status }
        if priority > 0                            { body["priority"]    = priority }
        if let startDate {
            body["start_date"]      = Int(startDate.timeIntervalSince1970 * 1000)
            body["start_date_time"] = true
        }
        if let dueDate {
            body["due_date"]      = Int(dueDate.timeIntervalSince1970 * 1000)
            body["due_date_time"] = true
        }
        if !assigneeIds.isEmpty { body["assignees"] = assigneeIds }
        if !tagNames.isEmpty    { body["tags"]      = tagNames }

        var req = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/list/\(listId)/task")!)
        req.httpMethod = "POST"
        req.setValue(token,             forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard var task = parseTasks(data, single: true).first else { throw CUError.parse }
        // Belt-and-suspenders: ClickUp sometimes echoes back
        // the parent only on subsequent fetches, so fill it in
        // ourselves from the request payload.
        if task.parentId == nil { task.parentId = parentId }
        return task
    }

    /// Fetches one task with its full payload — including the
    /// `attachments` array, which ClickUp's *list* endpoint
    /// (`/list/{id}/task`) does NOT return. Used to hydrate
    /// `CUTask.attachments` lazily when the user opens the
    /// detail popup, so we don't pay the cost of N
    /// per-task fetches up-front but still show every file
    /// the user uploaded via the "+ Anexar" button.
    func getTask(id: String) async throws -> CUTask {
        guard let token else { throw CUError.notConfigured }
        // `include_subtasks=true` mirrors the list endpoint — the
        // single-task GET respects the same flag and is the
        // ClickUp-documented way to ensure full child data.
        // Doesn't affect `attachments`, which is always returned.
        var comps = URLComponents(string: "https://api.clickup.com/api/v2/task/\(id)")!
        comps.queryItems = [
            URLQueryItem(name: "include_subtasks", value: "true"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue(token, forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let task = parseTasks(data, single: true).first else {
            throw CUError.parse
        }
        return task
    }

    func completeTask(id: String) async throws {
        guard let token else { throw APIError.notConfigured }

        var req = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/task/\(id)")!)
        req.httpMethod = "PUT"
        req.setValue(token,            forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["status": "complete"])

        _ = try await sendClassified(req)
    }

    func updateTaskStatus(id: String, to status: String) async throws {
        try await updateTask(id: id, fields: ["status": status])
    }

    /// Permanently deletes a task. ClickUp returns 204 on
    /// success — this is a destructive operation, the task
    /// can't be recovered after this.
    func deleteTask(id: String) async throws {
        guard let token else { throw CUError.notConfigured }
        var req = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/task/\(id)")!)
        req.httpMethod = "DELETE"
        req.setValue(token, forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw CUError.parse
        }
    }

    /// Archives a task — keeps it on the workspace but hidden
    /// from the default list view. Reversible via the ClickUp
    /// web UI ("show archived"). On the API, this is just a
    /// flag flip on the task's `archived` field.
    func archiveTask(id: String) async throws {
        try await updateTask(id: id, fields: ["archived": true])
    }

    /// Moves a task to a different list within the same
    /// workspace. ClickUp's `Move task` endpoint preserves
    /// the task id (the url stays the same) and migrates
    /// status / priority / assignees as long as the target
    /// list has matching values; otherwise they reset to
    /// the new list's defaults.
    func moveTask(id: String, toListId: String) async throws {
        guard let token else { throw CUError.notConfigured }
        var req = URLRequest(url: URL(
            string: "https://api.clickup.com/api/v2/list/\(toListId)/task/\(id)"
        )!)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw CUError.parse
        }
    }

    /// Activity log for a task — every status change, rename,
    /// reassignment, comment, attachment add/remove, etc. The
    /// agent uses this to answer "o que mudou nessa tarefa?".
    /// Returns chronological list (oldest first) of human-
    /// readable strings; the wire format is awkward and varies
    /// by event type.
    func getTaskHistory(id: String) async throws -> [(date: Date, who: String, what: String)] {
        guard let token else { throw CUError.notConfigured }
        var req = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/task/\(id)?include_subtasks=false&custom_task_ids=false")!)
        req.setValue(token, forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        var entries: [(Date, String, String)] = []

        // ClickUp returns task creation + close dates on the
        // task object itself, plus per-event history under
        // `history_items` on /task/{id}/history (deprecated
        // but still works for many workspaces).
        if let dateCreated = (json["date_created"] as? String).flatMap(Double.init) {
            let creator = (json["creator"] as? [String: Any])?["username"] as? String ?? "—"
            entries.append((Date(timeIntervalSince1970: dateCreated/1000),
                            creator, "criou a tarefa"))
        }

        // Try the dedicated activity endpoint.
        var actReq = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/task/\(id)/history")!)
        actReq.setValue(token, forHTTPHeaderField: "Authorization")
        if let (actData, _) = try? await URLSession.shared.data(for: actReq),
           let actJson = try? JSONSerialization.jsonObject(with: actData) as? [String: Any],
           let items = actJson["history_items"] as? [[String: Any]] {
            // One-shot ground-truth dump so the activity-timeline
            // parser (see `parseActivityEvents`) can be written
            // against the real wire format. ClickUp's docs only
            // cover a subset of the `history_items` fields and
            // event types; this dump is read by the dev to map
            // every observed `field` / `data` combination to a
            // typed `TaskActivityEvent` case. Only writes if the
            // file isn't already present, so it doesn't churn on
            // every fetch.
            let dumpPath = "/tmp/apollo_clickup_history_dump.json"
            if !FileManager.default.fileExists(atPath: dumpPath) && !items.isEmpty {
                try? actData.write(to: URL(fileURLWithPath: dumpPath))
            }
            for item in items {
                guard let dateStr = item["date"] as? String,
                      let ms = Double(dateStr)
                else { continue }
                let who = (item["user"] as? [String: Any])?["username"]
                    as? String ?? "—"
                let field = item["field"] as? String ?? "campo"
                let action = item["type"] as? String
                    ?? (item["data"] as? [String: Any])?["status_type"] as? String
                    ?? "alterou"
                let what = "\(action) \(field)"
                entries.append((Date(timeIntervalSince1970: ms/1000), who, what))
            }
        }

        return entries.sorted { $0.0 < $1.0 }
    }

    /// Rich, typed activity timeline for a task — the data
    /// source behind the unified Comments+Activity panel in
    /// the popup (`TaskActivitySection`). Same endpoint as
    /// `getTaskHistory`, but each event becomes a strongly-typed
    /// `TaskActivityEvent` with the right associated payload
    /// (status pill colours, attachment metadata, assignee
    /// objects, etc.) — the view layer never reparses the raw
    /// `history_items` payload.
    ///
    /// Always returns the synthesised `taskCreated` event up
    /// front (built from `date_created` on the task object)
    /// so even tasks with empty history have a non-empty
    /// timeline. Sort: oldest → newest, matching ClickUp's
    /// own panel.
    func getTaskActivity(id: String) async throws -> [TaskActivityEvent] {
        guard let token else { throw CUError.notConfigured }

        // 1) Fetch the task itself for `date_created` + `creator`
        //    so we always have a "task created" anchor.
        var taskReq = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/task/\(id)?include_subtasks=false&custom_task_ids=false")!)
        taskReq.setValue(token, forHTTPHeaderField: "Authorization")
        let (taskData, _) = try await URLSession.shared.data(for: taskReq)
        let taskJson = (try? JSONSerialization.jsonObject(with: taskData)) as? [String: Any]

        var events: [TaskActivityEvent] = []

        if let taskJson,
           let dateStr = taskJson["date_created"] as? String,
           let ms = Double(dateStr) {
            let creator = Self.parseAssignee(taskJson["creator"] as? [String: Any])
            events.append(TaskActivityEvent(
                id: "task-created-\(id)",
                date: Date(timeIntervalSince1970: ms / 1000),
                actor: creator,
                kind: .taskCreated
            ))
        }

        // 2) Synthesise attachment-add events from the task's
        //    own `attachments` array. Each entry carries a
        //    per-file `date` (epoch ms) and `user` (uploader),
        //    so we get accurate "who uploaded what when" rows
        //    in the timeline even though the dedicated history
        //    endpoint is unavailable on most workspaces (see
        //    note below). Without this fallback, uploads were
        //    invisible in the Apollo timeline despite being
        //    front-and-centre in ClickUp's own Activity panel.
        if let attsRaw = taskJson?["attachments"] as? [[String: Any]] {
            for attRaw in attsRaw {
                guard let att = Self.parseAttachment(attRaw) else { continue }
                let date  = Self.parseEpochMs(attRaw["date"]) ?? Date()
                let actor = Self.parseAssignee(attRaw["user"] as? [String: Any])
                events.append(TaskActivityEvent(
                    id: "attachment-\(att.id)",
                    date: date,
                    actor: actor,
                    kind: .attachmentAdded(att)
                ))
            }
        }

        // 3) Best-effort: try the deprecated activity endpoint.
        //    On older workspaces this still returns `history_items`
        //    with status changes, assignee adds, priority moves,
        //    rename events, etc. — everything the rich timeline
        //    can render. On newer workspaces it returns HTTP 404
        //    ("page not found") and the section degrades to the
        //    creation + uploads + comments we already have.
        //    Status / priority / assignee history is simply NOT
        //    accessible via ClickUp's public REST API on those
        //    workspaces — the official web client populates its
        //    Activity panel via an internal `app.clickup.com
        //    /api/v1/...` endpoint that requires session-cookie
        //    auth (not a Personal API token), so a third-party
        //    client like ours can't reach it.
        var actReq = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/task/\(id)/history")!)
        actReq.setValue(token, forHTTPHeaderField: "Authorization")
        if let (actData, _) = try? await URLSession.shared.data(for: actReq),
           let actJson = try? JSONSerialization.jsonObject(with: actData) as? [String: Any],
           let items = actJson["history_items"] as? [[String: Any]] {
            events.append(contentsOf: items.compactMap(Self.parseActivityItem))
        }

        return events.sorted { $0.date < $1.date }
    }

    // MARK: - Activity parsing helpers
    //
    // These are private static so they can be unit-reasoned
    // without an instance, and so the parsing surface stays
    // visibly co-located with the endpoint that needs it.

    /// Parse one `history_items` entry into a typed event.
    /// Returns nil only when the entry is missing both `date`
    /// and `id` (i.e. it's not a meaningful event we can
    /// render). For UNKNOWN field types we still return a
    /// `.unknown` event so the user sees that *something*
    /// happened — silent drops would make the timeline lie.
    private static func parseActivityItem(_ item: [String: Any]) -> TaskActivityEvent? {
        // Date — ClickUp returns ms since epoch as a string.
        // Some payloads use a number; handle both.
        let date: Date = {
            if let s = item["date"] as? String, let ms = Double(s) {
                return Date(timeIntervalSince1970: ms / 1000)
            }
            if let n = item["date"] as? Double {
                return Date(timeIntervalSince1970: n / 1000)
            }
            return Date()
        }()

        let id = item["id"] as? String
            ?? "hist-\(date.timeIntervalSince1970)-\(item["field"] as? String ?? "?")"

        let actor = parseAssignee(item["user"] as? [String: Any])
        let field = (item["field"] as? String ?? "").lowercased()
        let data  = item["data"] as? [String: Any]
        let before = item["before"]
        let after  = item["after"]

        // Skip comment-post history items entirely. The
        // dedicated `/comment` endpoint already returns these
        // with full structure (text, attachments, reactions,
        // replies); surfacing them again as activity rows
        // would double-render the same content. The check is
        // generous on the field name since ClickUp has used
        // both `comment` and `comment_post` over time.
        if field.hasPrefix("comment") { return nil }

        let kind = parseActivityKind(field: field, data: data,
                                     before: before, after: after)
        return TaskActivityEvent(id: id, date: date, actor: actor, kind: kind)
    }

    /// The dispatch table that maps ClickUp's `field` strings
    /// to typed `Kind` cases. Each branch is defensive — it
    /// pulls every payload variant we've observed (object form,
    /// string form, plus `data` subkeys) and falls through to
    /// `.unknown` when nothing matches. New ClickUp event types
    /// surface as `.unknown(field, summary)` rows rather than
    /// disappearing.
    private static func parseActivityKind(field: String,
                                          data: [String: Any]?,
                                          before: Any?,
                                          after:  Any?) -> TaskActivityEvent.Kind {
        switch field {
        case "status":
            return .statusChanged(
                from: parseStatusRef(before),
                to:   parseStatusRef(after)
            )

        case "assignee_add", "assignee_rem", "assignee":
            // ClickUp emits the changed user under different
            // keys depending on workspace age. Try `data
            // .assignee`, then `after` (for adds) / `before`
            // (for removes).
            let userPayload = (data?["assignee"] as? [String: Any])
                ?? (after  as? [String: Any])
                ?? (before as? [String: Any])
            let user = parseAssignee(userPayload) ?? CUTask.Assignee(
                id: 0, username: "alguém", initials: nil,
                color: nil, profilePicture: nil)
            // Use field suffix to disambiguate; for the
            // legacy `assignee` field, presence of `after`
            // (added) vs `before` only (removed) decides.
            let isRemove: Bool = {
                if field == "assignee_rem" { return true }
                if field == "assignee_add" { return false }
                return after == nil && before != nil
            }()
            return isRemove ? .assigneeRemoved(user) : .assigneeAdded(user)

        case "attachment", "attachment_add":
            if let att = parseAttachment(data?["attachment"] as? [String: Any]
                                         ?? (after as? [String: Any])) {
                return .attachmentAdded(att)
            }
            return .unknown(field: field, summary: "anexou um arquivo")

        case "attachment_rem", "attachment_remove":
            if let att = parseAttachment(data?["attachment"] as? [String: Any]
                                         ?? (before as? [String: Any])) {
                return .attachmentRemoved(att)
            }
            return .unknown(field: field, summary: "removeu um anexo")

        case "name":
            return .nameChanged(from: before as? String, to: after as? String)

        case "priority":
            return .priorityChanged(
                from: parsePriorityRef(before),
                to:   parsePriorityRef(after)
            )

        case "due_date":
            return .dueDateChanged(from: parseEpochMs(before),
                                   to:   parseEpochMs(after))

        case "start_date":
            return .startDateChanged(from: parseEpochMs(before),
                                     to:   parseEpochMs(after))

        case "content", "description":
            return .descriptionChanged

        case "tag", "tag_added":
            let payload = (data?["tag"] as? [String: Any])
                ?? (after as? [String: Any])
            if let p = payload, let name = p["name"] as? String {
                return .tagAdded(name: name,
                                 foregroundHex: p["fg_color"] as? String,
                                 backgroundHex: p["bg_color"] as? String)
            }
            return .unknown(field: field, summary: "adicionou tag")

        case "tag_removed":
            let payload = (data?["tag"] as? [String: Any])
                ?? (before as? [String: Any])
            if let p = payload, let name = p["name"] as? String {
                return .tagRemoved(name: name,
                                   foregroundHex: p["fg_color"] as? String,
                                   backgroundHex: p["bg_color"] as? String)
            }
            return .unknown(field: field, summary: "removeu tag")

        case "subtask_create", "subtask", "child":
            let info = (data as? [String: Any]) ?? (after as? [String: Any]) ?? [:]
            return .subtaskAdded(
                name: info["name"] as? String,
                id:   info["id"]   as? String
            )

        case "parent", "parent_id":
            return .parentChanged(from: before as? String, to: after as? String)

        case "list", "list_id":
            return .listChanged(from: before as? String, to: after as? String)

        case "archived":
            return ((after as? Bool) ?? false) ? .archived : .unarchived

        default:
            // Best-effort summary for unknown fields. Use
            // before/after snippets when they're scalar; skip
            // complex objects so the row stays short.
            var bits: [String] = ["alterou \(field.replacingOccurrences(of: "_", with: " "))"]
            if let b = stringify(before) { bits.append("de \"\(b)\"") }
            if let a = stringify(after)  { bits.append("para \"\(a)\"") }
            return .unknown(field: field, summary: bits.joined(separator: " "))
        }
    }

    /// Convert ClickUp's `user` payload into our `Assignee`
    /// struct. Tolerates the various shapes the API uses
    /// across endpoints: `creator`, `user`, history-item
    /// `user`. Returns nil on malformed input rather than
    /// fabricating a placeholder — callers decide whether
    /// "unknown actor" should fall back to a synthetic value.
    private static func parseAssignee(_ obj: [String: Any]?) -> CUTask.Assignee? {
        guard let obj,
              let id = obj["id"] as? Int,
              let username = obj["username"] as? String
        else { return nil }
        return CUTask.Assignee(
            id:             id,
            username:       username,
            initials:       obj["initials"]       as? String,
            color:          obj["color"]          as? String,
            profilePicture: obj["profilePicture"] as? String
        )
    }

    /// Parse one attachment payload from a history item.
    /// ClickUp returns either the full attachment object or
    /// (rarely) just a URL string. Mirror's the structure
    /// `getTask` builds via `attachmentsForTask`.
    private static func parseAttachment(_ obj: [String: Any]?) -> CUTask.Attachment? {
        guard let obj else { return nil }
        let url   = obj["url"] as? String ?? ""
        let title = obj["title"] as? String
            ?? (URL(string: url)?.lastPathComponent ?? "arquivo")
        let id    = obj["id"] as? String ?? url
        let ext: String = {
            if let e = obj["extension"] as? String { return e.lowercased() }
            return (URL(string: url)?.pathExtension ?? "").lowercased()
        }()
        let size: String? = {
            if let s = obj["size"] as? Int    { return ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file) }
            if let s = obj["size"] as? Double { return ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file) }
            return nil
        }()
        return CUTask.Attachment(id: id, title: title, url: url,
                                 ext: ext, sizeString: size)
    }

    /// Status payloads come in two shapes: `{status, color,
    /// type, orderindex}` (object) or just a status name
    /// string. Either is normalised to a `StatusRef` carrying
    /// what the row actually renders (label + colour).
    private static func parseStatusRef(_ raw: Any?) -> TaskActivityEvent.StatusRef? {
        if let obj = raw as? [String: Any], let name = obj["status"] as? String {
            return .init(name: name, hex: obj["color"] as? String)
        }
        if let s = raw as? String, !s.isEmpty {
            return .init(name: s, hex: nil)
        }
        return nil
    }

    /// Priority payloads are either `{priority, color}` or a
    /// numeric/string id. We only render the label + colour, so
    /// numeric-only payloads fall back to the canonical priority
    /// names.
    private static func parsePriorityRef(_ raw: Any?) -> TaskActivityEvent.PriorityRef? {
        if let obj = raw as? [String: Any], let name = obj["priority"] as? String {
            return .init(name: name, hex: obj["color"] as? String)
        }
        if let s = raw as? String, !s.isEmpty {
            return .init(name: s, hex: nil)
        }
        if let n = raw as? Int {
            // ClickUp's canonical mapping (1=urgent…4=low).
            let names = [1: "urgente", 2: "alta", 3: "normal", 4: "baixa"]
            return .init(name: names[n] ?? "prioridade \(n)", hex: nil)
        }
        return nil
    }

    /// Robust epoch-ms parser. ClickUp returns timestamps as
    /// strings most places and as numbers in a few corners of
    /// the API; date fields specifically are sometimes empty
    /// strings (meaning "unset"), which we map to nil.
    private static func parseEpochMs(_ raw: Any?) -> Date? {
        if let s = raw as? String {
            guard !s.isEmpty, let ms = Double(s) else { return nil }
            return Date(timeIntervalSince1970: ms / 1000)
        }
        if let n = raw as? Double, n > 0 {
            return Date(timeIntervalSince1970: n / 1000)
        }
        return nil
    }

    /// Compact, render-safe stringify used by the `.unknown`
    /// summary builder. Skips dictionaries/arrays so an
    /// unmapped field never spills its raw object into the UI.
    private static func stringify(_ raw: Any?) -> String? {
        switch raw {
        case let s as String where !s.isEmpty: return s
        case let n as Int:    return String(n)
        case let n as Double: return String(n)
        case let b as Bool:   return b ? "sim" : "não"
        default: return nil
        }
    }

    /// Time-tracking entries for one task. ClickUp v2 endpoint.
    /// Each entry is `{start, end, duration_ms, user, description}`
    /// — formatted by the executor for the agent's reply.
    func getTaskTimeEntries(id: String) async throws -> [(start: Date, end: Date?, durationMs: Int, who: String, note: String)] {
        guard let token else { throw CUError.notConfigured }
        var req = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/task/\(id)/time")!)
        req.setValue(token, forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { item in
            guard let startStr = item["start"] as? String,
                  let startMs = Double(startStr)
            else { return nil }
            let endMs = (item["end"] as? String).flatMap(Double.init)
            let durStr = item["duration"] as? String ?? "0"
            let durMs = Int(durStr) ?? 0
            let who = (item["user"] as? [String: Any])?["username"]
                as? String ?? "—"
            let note = item["description"] as? String ?? ""
            return (
                Date(timeIntervalSince1970: startMs/1000),
                endMs.map { Date(timeIntervalSince1970: $0/1000) },
                durMs,
                who,
                note
            )
        }
    }

    // Generic field updater. ClickUp's PUT /task/{id} accepts:
    //   name, description, priority, status,
    //   start_date, due_date (+ start_date_time / due_date_time),
    //   assignees: { add: [Int], rem: [Int] }
    func updateTask(id: String, fields: [String: Any]) async throws {
        guard let token else { throw APIError.notConfigured }
        var req = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/task/\(id)")!)
        req.httpMethod = "PUT"
        req.setValue(token,             forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: fields)
        // Routes through `sendClassified` so the offline queue + UI
        // recovery layer see a typed `APIError` for status changes,
        // title/description/priority/date edits, and any other
        // patch the dashboard sends through here. The other API
        // methods below still throw `CUError` until they're
        // migrated; the queue only drains operations that flow
        // through this path.
        _ = try await sendClassified(req)
    }

    // Tags use a separate endpoint per add/remove
    func addTaskTag(id: String, tag: String) async throws {
        guard let token else { throw CUError.notConfigured }
        let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
        var req = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/task/\(id)/tag/\(encoded)")!)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "Authorization")
        _ = try await URLSession.shared.data(for: req)
    }

    func removeTaskTag(id: String, tag: String) async throws {
        guard let token else { throw CUError.notConfigured }
        let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
        var req = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/task/\(id)/tag/\(encoded)")!)
        req.httpMethod = "DELETE"
        req.setValue(token, forHTTPHeaderField: "Authorization")
        _ = try await URLSession.shared.data(for: req)
    }

    // MARK: - Comments

    func getTaskComments(taskId: String) async throws -> [CUComment] {
        guard let token else { throw CUError.notConfigured }
        var req = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/task/\(taskId)/comment")!)
        req.setValue(token, forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        return parseComments(data)
    }

    func addTaskComment(taskId: String, text: String,
                        mentionedMembers: [CUMember] = [],
                        assignee: Int? = nil,
                        notifyAll: Bool = false) async throws -> CUComment? {
        guard let token else { throw CUError.notConfigured }

        // ClickUp's v2 comment endpoint accepts a structured
        // `comment` array of segments — the SAME shape the GET
        // endpoint hands back (see `parseComments`, ~line 1025).
        // Each segment can be plain text or a typed token such
        // as a user mention. To register a real mention — one
        // that ClickUp lights up as a clickable chip AND fires
        // the recipient's notification — we MUST emit the
        // segment with `type: "tag"` and a `user.id` reference.
        //
        // History of attempts:
        //
        //  1. Earliest version sent `attributes.advanced
        //     .user-mention` payloads. Wrong shape — ClickUp
        //     silently dropped both the structure AND
        //     `comment_text` (we'd replaced the latter), so
        //     comments came out blank and notified nobody.
        //
        //  2. Reverted to plain `comment_text` + `assignee`
        //     (single user) / `notify_all` (multi). The text
        //     rendered, but ClickUp does NOT re-resolve
        //     "@Username" out of raw `comment_text` — it just
        //     auto-colours the visible "@FirstName" run with
        //     no notification fired. Worse, multi-mention fell
        //     back to `notify_all` which spammed every watcher.
        //
        //  3. (Current) Send BOTH the structured `comment`
        //     array AND `comment_text`. The array carries the
        //     mention metadata that actually triggers the
        //     notification + clickable chip; `comment_text`
        //     stays as the plain-string echo for legacy
        //     consumers (and matches what ClickUp's own GET
        //     responses provide alongside the structured
        //     form).
        //
        // The caller's explicit `assignee` / `notifyAll`
        // overrides — used by the AI agent — still pass
        // through, since they know the intent without the
        // mention inference. For human-typed comments these
        // stay unset; the structured array does the work.

        let segments = Self.buildCommentSegments(text: text, members: mentionedMembers)

        var body: [String: Any] = [
            "comment_text": text,
            "comment":      segments,
            "notify_all":   notifyAll,
        ]
        if let assignee {
            body["assignee"] = assignee
        }

        var req = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/task/\(taskId)/comment")!)
        req.httpMethod = "POST"
        req.setValue(token,             forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        // The POST response carries id/date but not the full user object,
        // so re-fetch the list to get the canonical record back.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cid = json["id"] as? String {
            let comments = try await getTaskComments(taskId: taskId)
            return comments.first { $0.id == cid }
        }
        return nil
    }

    /// Splits `text` into ClickUp's structured comment-segment
    /// array. Each `@username` substring whose username matches
    /// a resolved member becomes a `type: "tag"` segment with
    /// `user.id` set — the form that triggers ClickUp's
    /// mention pipeline (notification + clickable chip). Plain
    /// runs between mentions stay as untyped `text` segments.
    ///
    /// Overlap rule: when one member's `@<username>` substring
    /// is a prefix of another's (e.g. `@Joao` vs `@Joao Silva`
    /// when both exist in the workspace), the LONGER match
    /// wins. Sort puts longer-at-same-start first; the
    /// claim-range walk discards any later overlap.
    ///
    /// Empty input or zero mentions → a single `text` segment
    /// containing the whole string (still a valid `comment`
    /// array per ClickUp's schema, just with no tag tokens).
    private static func buildCommentSegments(text: String,
                                             members: [CUMember]) -> [[String: Any]] {
        struct Match {
            let range: Range<String.Index>
            let memberId: Int
        }

        var matches: [Match] = []
        for m in members {
            guard !m.username.isEmpty else { continue }
            let needle = "@" + m.username
            var search = text.startIndex..<text.endIndex
            while let r = text.range(of: needle, options: .literal, range: search) {
                matches.append(Match(range: r, memberId: m.id))
                search = r.upperBound..<text.endIndex
            }
        }

        // Earlier start wins; on tie, longer wins.
        matches.sort {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            return $0.range.upperBound > $1.range.upperBound
        }

        // Walk left to right, claiming non-overlapping matches.
        var keep: [Match] = []
        var lastEnd = text.startIndex
        for m in matches where m.range.lowerBound >= lastEnd {
            keep.append(m)
            lastEnd = m.range.upperBound
        }

        var segments: [[String: Any]] = []
        var cursor = text.startIndex
        for m in keep {
            if cursor < m.range.lowerBound {
                segments.append(["text": String(text[cursor..<m.range.lowerBound])])
            }
            segments.append([
                "text": String(text[m.range]),
                "type": "tag",
                "user": ["id": m.memberId],
            ])
            cursor = m.range.upperBound
        }
        if cursor < text.endIndex {
            segments.append(["text": String(text[cursor..<text.endIndex])])
        }
        // Guarantee at least one segment so we never POST an
        // empty `comment` array (ClickUp rejects those).
        if segments.isEmpty {
            segments.append(["text": text])
        }
        return segments
    }

    func deleteTaskComment(commentId: String) async throws {
        guard let token else { throw CUError.notConfigured }
        var req = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/comment/\(commentId)")!)
        req.httpMethod = "DELETE"
        req.setValue(token, forHTTPHeaderField: "Authorization")
        _ = try await URLSession.shared.data(for: req)
    }

    // MARK: - Reactions

    func addCommentReaction(commentId: String, emoji: String) async throws {
        guard let token else { throw CUError.notConfigured }
        var req = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/comment/\(commentId)/reaction")!)
        req.httpMethod = "POST"
        req.setValue(token,             forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["reaction": emoji])
        _ = try await URLSession.shared.data(for: req)
    }

    func removeCommentReaction(commentId: String, emoji: String) async throws {
        guard let token else { throw CUError.notConfigured }
        let encoded = emoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? emoji
        var req = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/comment/\(commentId)/reaction/\(encoded)")!)
        req.httpMethod = "DELETE"
        req.setValue(token, forHTTPHeaderField: "Authorization")
        _ = try await URLSession.shared.data(for: req)
    }

    // MARK: - Threaded replies

    func getCommentReplies(commentId: String) async throws -> [CUComment] {
        guard let token else { throw CUError.notConfigured }
        var req = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/comment/\(commentId)/reply")!)
        req.setValue(token, forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        return parseComments(data)
    }

    @discardableResult
    func addCommentReply(commentId: String, text: String) async throws -> CUComment? {
        guard let token else { throw CUError.notConfigured }
        var req = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/comment/\(commentId)/reply")!)
        req.httpMethod = "POST"
        req.setValue(token,             forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "comment_text": text,
            "notify_all":   false,
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cid = json["id"] as? String {
            let replies = try await getCommentReplies(commentId: commentId)
            return replies.first { $0.id == cid }
        }
        return nil
    }

    // MARK: - Attachments
    //
    // ClickUp accepts any file type via multipart upload to
    // `/task/{id}/attachment`. The response gives back a public URL —
    // we return it but DON'T post it as a comment, since ClickUp
    // already generates an activity-thread entry per real attachment.
    // Posting the URL on top would surface as a duplicate "bare link"
    // comment for the recipient. (See `AppState.uploadCommentAttachment`
    // for the history.)

    @discardableResult
    func uploadAttachment(taskId: String, fileURL: URL,
                          commentId: String? = nil,
                          onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> URL? {
        guard let token else { throw CUError.notConfigured }
        guard fileURL.startAccessingSecurityScopedResource() ||
              FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw CUError.notConfigured
        }
        defer { fileURL.stopAccessingSecurityScopedResource() }

        let fileData = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent
        let mime     = mimeType(for: fileURL)

        let boundary = "PainelLunar-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/task/\(taskId)/attachment")!)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)",
                     forHTTPHeaderField: "Content-Type")

        var body = Data()

        // Optional `comment_id` multipart field — when present,
        // ClickUp's attachment endpoint anchors the upload to the
        // specified comment instead of creating a standalone
        // "uploaded N files" activity entry. The web client uses
        // this for the chat-style flow where one bubble carries
        // both text and files. If the field is absent (or the
        // server ignores it on an older account), the file still
        // attaches to the task — same as the legacy task-level
        // upload — which is a graceful fallback rather than a
        // hard error.
        if let commentId {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"comment_id\"\r\n\r\n")
            body.append("\(commentId)\r\n")
        }

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"attachment\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mime)\r\n\r\n")
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n")
        req.httpBody = body

        let delegate = onProgress.map { UploadProgressDelegate(onProgress: $0) }
        let (data, _) = try await URLSession.shared.upload(for: req,
                                                           from: body,
                                                           delegate: delegate)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let s = json["url"]         as? String, let u = URL(string: s) { return u }
        if let s = json["url_w_query"] as? String, let u = URL(string: s) { return u }
        return nil
    }

    private func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    // MARK: - Members (workspace assignees)

    func getMembers() async throws -> [CUMember] {
        guard let token else { throw CUError.notConfigured }

        var req = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/team")!)
        req.setValue(token, forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let teams = json["teams"] as? [[String: Any]],
              let team  = teams.first,
              let members = team["members"] as? [[String: Any]] else { throw CUError.parse }

        return members.compactMap { m in
            guard let user = m["user"] as? [String: Any],
                  let id   = user["id"] as? Int,
                  let name = user["username"] as? String else { return nil }
            return CUMember(
                id:             id,
                username:       name,
                email:          user["email"]          as? String,
                color:          user["color"]          as? String,
                profilePicture: user["profilePicture"] as? String,
                initials:       user["initials"]       as? String
            )
        }
    }

    // MARK: - Space tags (for tag picker)

    func getSpaceTags() async throws -> [CUTask.Tag] {
        guard let token, let listId else { throw CUError.notConfigured }

        // 1) Resolve list → space ID
        var listReq = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/list/\(listId)")!)
        listReq.setValue(token, forHTTPHeaderField: "Authorization")
        let (listData, _) = try await URLSession.shared.data(for: listReq)
        guard let listJson = try? JSONSerialization.jsonObject(with: listData) as? [String: Any],
              let space    = listJson["space"] as? [String: Any],
              let spaceId  = space["id"] as? String else { throw CUError.parse }

        // 2) Fetch tags for that space
        var tagsReq = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/space/\(spaceId)/tag")!)
        tagsReq.setValue(token, forHTTPHeaderField: "Authorization")
        let (tagsData, _) = try await URLSession.shared.data(for: tagsReq)
        guard let json = try? JSONSerialization.jsonObject(with: tagsData) as? [String: Any],
              let raw  = json["tags"] as? [[String: Any]] else { return [] }

        return raw.compactMap { t in
            guard let n = t["name"] as? String else { return nil }
            return CUTask.Tag(
                name:       n,
                foreground: t["tag_fg"] as? String ?? "#FFFFFF",
                background: t["tag_bg"] as? String ?? "#87909E"
            )
        }
    }

    // MARK: - List statuses (for status dropdown)

    func getListStatuses() async throws -> [CUStatus] {
        guard let token, let listId else { throw CUError.notConfigured }

        var req = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/list/\(listId)")!)
        req.setValue(token, forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statuses = json["statuses"] as? [[String: Any]] else { throw CUError.parse }

        return statuses.compactMap { s in
            guard let name = s["status"] as? String else { return nil }
            return CUStatus(
                status: name,
                color:  s["color"] as? String ?? "#87909E",
                type:   s["type"]  as? String ?? "custom"
            )
        }
    }

    // MARK: - Workspace hierarchy (for list picker)

    func getWorkspaces() async throws -> [CUWorkspace] {
        guard let token else { throw CUError.notConfigured }
        var req = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/team")!)
        req.setValue(token, forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let teams = json["teams"] as? [[String: Any]] else { throw CUError.parse }
        return teams.compactMap { t in
            guard let id = t["id"] as? String, let name = t["name"] as? String else { return nil }
            return CUWorkspace(id: id, name: name)
        }
    }

    func getSpaces(workspaceId: String) async throws -> [CUSpace] {
        guard let token else { throw CUError.notConfigured }
        var req = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/team/\(workspaceId)/space?archived=false")!)
        req.setValue(token, forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spaces = json["spaces"] as? [[String: Any]] else { throw CUError.parse }
        return spaces.compactMap { s in
            guard let id = s["id"] as? String, let name = s["name"] as? String else { return nil }
            return CUSpace(id: id, name: name)
        }
    }

    func getLists(spaceId: String) async throws -> [CUList] {
        guard let token else { throw CUError.notConfigured }
        async let folderlessReq = fetchFolderlessLists(spaceId: spaceId, token: token)
        async let foldersReq    = fetchFolderLists(spaceId: spaceId, token: token)
        let (direct, inFolders) = try await (folderlessReq, foldersReq)
        return (direct + inFolders).sorted { $0.name < $1.name }
    }

    private func fetchFolderlessLists(spaceId: String, token: String) async throws -> [CUList] {
        var req = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/space/\(spaceId)/list?archived=false")!)
        req.setValue(token, forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lists = json["lists"] as? [[String: Any]] else { return [] }
        return lists.compactMap { l in
            guard let id = l["id"] as? String, let name = l["name"] as? String else { return nil }
            return CUList(id: id, name: name)
        }
    }

    private func fetchFolderLists(spaceId: String, token: String) async throws -> [CUList] {
        var req = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/space/\(spaceId)/folder?archived=false")!)
        req.setValue(token, forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folders = json["folders"] as? [[String: Any]] else { return [] }

        var result: [CUList] = []
        for folder in folders {
            guard let lists = folder["lists"] as? [[String: Any]] else { continue }
            let folderName = folder["name"] as? String ?? ""
            result += lists.compactMap { l in
                guard let id = l["id"] as? String, let name = l["name"] as? String else { return nil }
                return CUList(id: id, name: "\(folderName) / \(name)")
            }
        }
        return result
    }

    // MARK: - Parse

    private func parseTasks(_ data: Data, single: Bool = false) -> [CUTask] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let items = single ? [json] : (json["tasks"] as? [[String: Any]] ?? [])

        return items.compactMap { item in
            guard let id   = item["id"]   as? String,
                  let name = item["name"] as? String else { return nil }

            let statusDict   = item["status"]   as? [String: Any]
            let priorityDict = item["priority"] as? [String: Any]
            let listDict     = item["list"]     as? [String: Any]

            let status      = statusDict?["status"] as? String ?? "open"
            let statusColor = statusDict?["color"]  as? String ?? "#87909E"
            let statusType  = statusDict?["type"]   as? String ?? "open"

            let priorityStr   = priorityDict?["id"]    as? String ?? "0"
            let priority      = Int(priorityStr) ?? 0
            let priorityColor = priorityDict?["color"] as? String ?? "#E0E0E0"

            let listId   = listDict?["id"]   as? String ?? ""
            let listName = listDict?["name"] as? String ?? "Unknown"

            var dueDate: Date?
            if let ms = item["due_date"] as? String, let val = Double(ms) {
                dueDate = Date(timeIntervalSince1970: val / 1000)
            }

            var startDate: Date?
            if let ms = item["start_date"] as? String, let val = Double(ms) {
                startDate = Date(timeIntervalSince1970: val / 1000)
            }

            let description = item["description"]  as? String ?? item["text_content"] as? String

            let assignees: [CUTask.Assignee] = (item["assignees"] as? [[String: Any]] ?? [])
                .compactMap { a in
                    guard let id = a["id"] as? Int,
                          let username = a["username"] as? String else { return nil }
                    return CUTask.Assignee(
                        id:             id,
                        username:       username,
                        initials:       a["initials"]       as? String,
                        color:          a["color"]          as? String,
                        profilePicture: a["profilePicture"] as? String
                    )
                }

            let tags: [CUTask.Tag] = (item["tags"] as? [[String: Any]] ?? [])
                .compactMap { t in
                    guard let n = t["name"] as? String else { return nil }
                    return CUTask.Tag(
                        name:       n,
                        foreground: t["tag_fg"] as? String ?? "#FFFFFF",
                        background: t["tag_bg"] as? String ?? "#87909E"
                    )
                }

            let url = item["url"] as? String

            // Extended filter fields. ClickUp returns archived as a Bool,
            // creator as the same shape as assignees, and date_* as
            // millisecond-stringified Doubles like the existing dates.
            let archived = item["archived"] as? Bool ?? false

            var creator: CUTask.Assignee? = nil
            if let c = item["creator"] as? [String: Any],
               let cid = c["id"] as? Int,
               let cuser = c["username"] as? String {
                creator = CUTask.Assignee(
                    id:             cid,
                    username:       cuser,
                    initials:       c["initials"]       as? String,
                    color:          c["color"]          as? String,
                    profilePicture: c["profilePicture"] as? String
                )
            }

            var dateCreated: Date?
            if let ms = item["date_created"] as? String, let val = Double(ms) {
                dateCreated = Date(timeIntervalSince1970: val / 1000)
            }

            var dateClosed: Date?
            if let ms = item["date_closed"] as? String, let val = Double(ms) {
                dateClosed = Date(timeIntervalSince1970: val / 1000)
            }

            // ClickUp's GET task endpoint sometimes includes a
            // `last_editor` user object (especially via webhooks /
            // single-task fetches). When present, capture the id so
            // we can filter the user's own remote edits out of the
            // diff-detection notifications. Falls back through a few
            // possible field names ClickUp has used over time.
            let lastEditorId: Int? = {
                if let e = item["last_editor"]    as? [String: Any], let id = e["id"] as? Int { return id }
                if let e = item["latest_editor"]  as? [String: Any], let id = e["id"] as? Int { return id }
                if let e = item["editor"]         as? [String: Any], let id = e["id"] as? Int { return id }
                return nil
            }()

            // Subtask wiring. ClickUp returns `parent` as either a
            // bare id string OR null. `top_level_parent` (when
            // present) points at the root of a deeper subtask
            // chain — captured so the UI can group everything
            // under one collapsible regardless of nesting depth.
            let parentId         = item["parent"]            as? String
            let topLevelParentId = item["top_level_parent"]  as? String

            // Attachments — directly from ClickUp's `attachments`
            // array, merged with anything we can pull out of the
            // description text (markdown-style file links). Both
            // sources flow through `attachmentsForTask` so the
            // result is deduped by URL.
            let attachments = Self.attachmentsForTask(
                apiArray: item["attachments"] as? [[String: Any]] ?? [],
                description: description
            )

            return CUTask(
                id:                id,
                title:             name,
                status:            status,
                statusColor:       statusColor,
                priority:          priority,
                priorityColor:     priorityColor,
                startDate:         startDate,
                dueDate:           dueDate,
                listId:            listId,
                listName:          listName,
                isCompleted:       statusType == "closed",
                description:       (description?.isEmpty == false) ? description : nil,
                assignees:         assignees,
                tags:              tags,
                url:               url,
                archived:          archived,
                creator:           creator,
                dateCreated:       dateCreated,
                dateClosed:        dateClosed,
                lastEditorId:      lastEditorId,
                parentId:          parentId,
                topLevelParentId:  topLevelParentId,
                attachments:       attachments
            )
        }
    }

    // MARK: - Attachment extraction

    /// Builds the deduplicated attachment list for one task.
    /// Combines:
    ///   • ClickUp's structured `attachments` array (rich
    ///     metadata: id, title, url, size, mime type)
    ///   • Markdown-style file links found inside the
    ///     description text — `[label](url)` where the URL
    ///     looks like a file (extension or ClickUp file host).
    ///     Important because ClickUp web sometimes embeds
    ///     attachments inline in the description body, so
    ///     they don't always show up in the API's separate
    ///     `attachments` array.
    /// Dedupe key = URL.
    private static func attachmentsForTask(
        apiArray: [[String: Any]],
        description: String?
    ) -> [CUTask.Attachment] {
        var byURL: [String: CUTask.Attachment] = [:]

        // 1) API-provided structured attachments.
        for raw in apiArray {
            guard let url = (raw["url"] as? String) ?? (raw["url_w_query"] as? String),
                  !url.isEmpty
            else { continue }
            let id    = (raw["id"] as? String) ?? url
            let title = (raw["title"] as? String)
                ?? (raw["name"]  as? String)
                ?? deriveFilename(from: url)
            let ext = (raw["extension"] as? String).map { $0.lowercased() }
                ?? extensionFromName(title)
                ?? extensionFromName(url)
                ?? ""
            let sizeBytes = raw["size"] as? Int
            let sizeStr   = sizeBytes.flatMap(humanSize(_:))

            byURL[url] = CUTask.Attachment(
                id:         id,
                title:      title,
                url:        url,
                ext:        ext,
                sizeString: sizeStr
            )
        }

        // 2) Markdown links scraped from the description.
        if let body = description, !body.isEmpty {
            for match in markdownLinkMatches(in: body) {
                let label = match.label
                let url   = match.url
                guard byURL[url] == nil else { continue }

                let ext = extensionFromName(label) ?? extensionFromName(url) ?? ""
                // Heuristic: only treat as an attachment if the
                // URL or label has a recognisable file extension,
                // OR the link points at ClickUp's file/attachment
                // host. Plain web links stay as plain text inside
                // the description editor's auto-link detection.
                let looksLikeFile =
                    !ext.isEmpty
                    || url.contains("clickup.com/file/")
                    || url.contains("attachments.clickup.com")
                    || url.contains("/attachment/")
                guard looksLikeFile else { continue }

                byURL[url] = CUTask.Attachment(
                    id:         url,
                    title:      label.isEmpty ? deriveFilename(from: url) : label,
                    url:        url,
                    ext:        ext,
                    sizeString: nil
                )
            }
        }

        // Stable order: same as discovery (API first, then
        // description-discovered ones).
        return Array(byURL.values).sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    /// Extracts the lowercased file extension from a name or
    /// URL path. Ignores query strings.
    private static func extensionFromName(_ s: String) -> String? {
        // Strip query / fragment.
        let core = s
            .split(separator: "?").first
            .map(String.init) ?? s
        guard let dot = core.lastIndex(of: ".") else { return nil }
        let after = core[core.index(after: dot)...]
        // File extensions are short ASCII alphanum strings.
        guard !after.isEmpty, after.count <= 5,
              after.allSatisfy({ $0.isLetter || $0.isNumber })
        else { return nil }
        return after.lowercased()
    }

    /// Falls back to the last URL path component when no
    /// proper title was returned.
    private static func deriveFilename(from url: String) -> String {
        guard let comps = URLComponents(string: url),
              let last = comps.path.split(separator: "/").last
        else { return url }
        return String(last).removingPercentEncoding ?? String(last)
    }

    /// Naive but reliable Markdown-link scanner. Returns every
    /// `[label](url)` pair found, in order of appearance.
    /// We avoid an `NSRegularExpression` here because the
    /// label can contain almost anything (including escaped
    /// brackets) and a small hand-rolled scanner is easier to
    /// reason about than a dialed-in regex.
    struct MarkdownLink { let label: String; let url: String }
    private static func markdownLinkMatches(in body: String)
        -> [MarkdownLink]
    {
        var results: [MarkdownLink] = []
        let chars = Array(body)
        var i = 0
        while i < chars.count {
            // Look for `[`.
            guard chars[i] == "[" else { i += 1; continue }
            // Scan label — closing `]` at the same depth (ignore
            // any `[` we haven't matched).
            var j = i + 1
            var labelEnd = -1
            while j < chars.count {
                if chars[j] == "]" { labelEnd = j; break }
                // Skip ahead through escaped char.
                if chars[j] == "\\", j + 1 < chars.count { j += 2; continue }
                j += 1
            }
            if labelEnd < 0 { break }
            // Expect `(` immediately after `]`.
            let parenStart = labelEnd + 1
            guard parenStart < chars.count, chars[parenStart] == "(" else {
                i = labelEnd + 1
                continue
            }
            // Scan URL up to closing `)`. Disallow whitespace
            // inside the URL — Markdown spec uses `<...>` for
            // URLs with spaces, which we don't bother handling.
            var k = parenStart + 1
            while k < chars.count, chars[k] != ")", chars[k] != "\n" { k += 1 }
            guard k < chars.count, chars[k] == ")" else {
                i = labelEnd + 1
                continue
            }
            let label = String(chars[(i + 1)..<labelEnd])
            let url   = String(chars[(parenStart + 1)..<k])
                .trimmingCharacters(in: .whitespaces)
            if !url.isEmpty {
                results.append(MarkdownLink(label: label, url: url))
            }
            i = k + 1
        }
        return results
    }

    /// Bytes → human-readable size string ("3.2 MB", "812 KB").
    private static func humanSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func parseComments(_ data: Data) -> [CUComment] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["comments"] as? [[String: Any]] else { return [] }

        // DIAGNOSTIC: dump the raw JSON of any comment fetch that
        // mentions a video file to /tmp so we can inspect the
        // actual segment shape ClickUp returns for multi-
        // attachment comments. `print()` doesn't surface when
        // the app is launched via `open`, but a tmp-file write
        // is trivially inspectable.
        do {
            let raw = String(data: data, encoding: .utf8) ?? ""
            if raw.contains(".mov") || raw.contains(".mp4") {
                let path = "/tmp/apollo_clickup_comments_dump.json"
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }

        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }

            // ClickUp comments come back either as plain `comment_text` OR
            // as a structured `comment` array of segments. Concatenate the
            // segment texts when present.
            var text = item["comment_text"] as? String ?? ""
            if text.isEmpty, let segs = item["comment"] as? [[String: Any]] {
                text = segs.compactMap { $0["text"] as? String }.joined()
            }

            // Date — ClickUp returns ms-since-epoch as a string
            var date = Date()
            if let ms = item["date"] as? String, let val = Double(ms) {
                date = Date(timeIntervalSince1970: val / 1000)
            } else if let ms = item["date"] as? Double {
                date = Date(timeIntervalSince1970: ms / 1000)
            }

            let user = item["user"] as? [String: Any]

            // Group reactions by emoji → list of user IDs.
            var grouped: [String: [Int]] = [:]
            if let raw = item["reactions"] as? [[String: Any]] {
                for r in raw {
                    let emoji = (r["reaction"] as? String) ?? "👍"
                    if let u = r["user"] as? [String: Any], let uid = u["id"] as? Int {
                        grouped[emoji, default: []].append(uid)
                    } else if let uid = r["user_id"] as? Int {
                        grouped[emoji, default: []].append(uid)
                    } else {
                        grouped[emoji, default: []].append(0)
                    }
                }
            }
            let reactions = grouped.map { CUComment.Reaction(emoji: $0.key, userIds: $0.value) }

            let replyCount = (item["reply_count"] as? Int)
                          ?? Int(item["reply_count"] as? String ?? "0")
                          ?? 0

            // Comment attachments. ClickUp's API returns them in
            // several shapes depending on how the file was added
            // and which client uploaded it:
            //   1. Top-level `attachments: [...]` array on the
            //      comment object (paperclip in the web composer).
            //   2. A `comment` segment with a nested `attachment`
            //      object (older web client shape).
            //   3. A `comment` segment that IS the attachment —
            //      `type: "attachment"` and `url` / `attachment_id`
            //      sit directly on the segment (newer web client +
            //      mobile uploads — this is what produces multi-
            //      file comments where each file is its own
            //      segment).
            //   4. A segment with an `image` field (image-only
            //      uploads sometimes use this dedicated key).
            // Everything flows through `attachmentsForTask` which
            // dedupes by URL, so collecting from all four shapes
            // is safe.
            var rawAttachments: [[String: Any]] = []
            if let arr = item["attachments"] as? [[String: Any]] {
                rawAttachments.append(contentsOf: arr)
            }
            if let segs = item["comment"] as? [[String: Any]] {
                for seg in segs {
                    // Shape 2 — nested object.
                    if let att = seg["attachment"] as? [String: Any] {
                        rawAttachments.append(att)
                        continue
                    }
                    // Shape 3 — segment IS the attachment.
                    let segType = seg["type"] as? String
                    let hasURL  = (seg["url"] as? String)?.isEmpty == false
                    let hasAttId = seg["attachment_id"] != nil
                    if segType == "attachment" || hasAttId || hasURL {
                        // Synthesize an attachment dict that matches
                        // the structured shape expected by
                        // `attachmentsForTask`. Falls back gracefully
                        // when individual fields are missing.
                        var synth: [String: Any] = [:]
                        if let id = seg["attachment_id"] as? String { synth["id"] = id }
                        else if let id = seg["id"] as? String { synth["id"] = id }
                        if let url = seg["url"] as? String { synth["url"] = url }
                        if let q = seg["url_w_query"] as? String { synth["url_w_query"] = q }
                        if let t = seg["title"] as? String { synth["title"] = t }
                        else if let t = seg["text"] as? String, !t.isEmpty { synth["title"] = t }
                        else if let t = seg["name"]  as? String { synth["title"] = t }
                        if let e = seg["extension"] as? String { synth["extension"] = e }
                        if let s = seg["size"] as? Int { synth["size"] = s }
                        if synth["url"] != nil || synth["url_w_query"] != nil {
                            rawAttachments.append(synth)
                            continue
                        }
                    }
                    // Shape 4 — image-only segment.
                    if let img = seg["image"] as? String, !img.isEmpty {
                        var synth: [String: Any] = ["url": img]
                        if let t = seg["text"] as? String, !t.isEmpty { synth["title"] = t }
                        rawAttachments.append(synth)
                    }
                }
            }
            let attachments = Self.attachmentsForTask(
                apiArray: rawAttachments,
                description: nil
            )

            return CUComment(
                id:           id,
                text:         text,
                date:         date,
                userId:       user?["id"]             as? Int,
                userName:     user?["username"]       as? String,
                userEmail:    user?["email"]          as? String,
                userColor:    user?["color"]          as? String,
                initials:     user?["initials"]       as? String,
                profilePic:   user?["profilePicture"] as? String,
                resolved:     item["resolved"] as? Bool ?? false,
                reactions:    reactions,
                replyCount:   replyCount,
                attachments:  attachments
            )
        }
    }

    enum CUError: Error { case notConfigured, parse }

    /// Send a request and classify the response into the semantic
    /// `APIError` taxonomy. Use for mutations that benefit from the
    /// offline queue / recovery banner — the queue inspects the
    /// thrown error and decides whether to retry or surface to the
    /// user. Existing methods that just `_ = try await URLSession`
    /// can be migrated incrementally; throwing `CUError` from them
    /// remains the legacy path until they're refactored.
    func sendClassified(_ req: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let err = APIError.classify(response: response,
                                           data: data,
                                           thrown: nil) {
                throw err
            }
            return data
        } catch let apiErr as APIError {
            throw apiErr
        } catch {
            // Anything URLSession threw — likely a URLError. Hand
            // off to the classifier which puts URLErrors into
            // `.offline(...)`.
            if let cls = APIError.classify(response: nil,
                                           data: nil,
                                           thrown: error) {
                throw cls
            }
            throw error
        }
    }
}

/// Streams URLSession upload progress (0.0 → 1.0) back to the caller.
/// Used by `uploadAttachment` to drive a SwiftUI progress bar.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let p = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        onProgress(p)
    }
}
