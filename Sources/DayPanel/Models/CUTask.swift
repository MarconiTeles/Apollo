import Foundation

/// A row in the flattened task-list view, including indent
/// depth so the cell can render hierarchically. Used by the
/// inline-expand feature: when a task with children is
/// expanded, its subtasks appear directly below it as rows
/// with `depth + 1`. `hasChildren` and `isExpanded` drive
/// the chevron at the top-right of the cell.
struct TaskListRow: Identifiable, Equatable {
    let task: CUTask
    let depth: Int
    let hasChildren: Bool
    let isExpanded: Bool
    /// True for the last row of an expanded subtree (a subtask
    /// whose next sibling in the flat list is a top-level mother
    /// task, or the end of the list). Drives the single hairline
    /// that closes the subtree off from the next mother task.
    var isLastInSubtree: Bool = false

    /// Composite id so the same task at different depths
    /// (shouldn't happen in normal use, but safe) renders as
    /// distinct cells.
    var id: String { "\(task.id)::\(depth)" }
}

struct CUTask: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var status: String
    var statusColor: String
    var priority: Int
    var priorityColor: String
    var startDate: Date?
    var dueDate: Date?
    var listId: String
    var listName: String
    var isCompleted: Bool
    var description: String?
    /// Comment count supplied by ClickUp's task payload. `nil` means an older
    /// cache/endpoint did not provide it; callers must then use the safe
    /// fallback instead of assuming the task has no comments.
    var commentCount: Int? = nil
    var assignees: [Assignee] = []
    var tags: [Tag]           = []
    var url: String?
    // Extended fields used by the filter system. Default values keep
    // older cached payloads decodable.
    var archived:    Bool      = false
    var creator:     Assignee? = nil
    var dateCreated: Date?     = nil
    var dateClosed:  Date?     = nil
    /// Numeric id of the last user to edit the task. Populated when
    /// the API returns it (some endpoints / payloads include it as
    /// `last_editor` or inside the latest history entry). Used by
    /// `diffAndNotifyRemoteChanges` to suppress notifications for
    /// edits the connected user made on clickup.com / mobile.
    var lastEditorId: Int?     = nil

    /// ClickUp's `parent` field — when this task is a subtask, it
    /// points at the parent task's id. `nil` for top-level tasks.
    /// Drives the subtask UI (collapsible group inside the parent's
    /// detail popup) AND the main list filter (top-level only).
    var parentId: String?      = nil
    /// `top_level_parent` from ClickUp — present on subtasks of
    /// subtasks, points at the *root* parent. Captured so the UI
    /// can group everything under the same root regardless of
    /// nesting depth. `nil` on root tasks.
    var topLevelParentId: String? = nil

    /// True iff this task is a subtask (has a parent). Convenience
    /// over `parentId != nil`.
    var isSubtask: Bool { parentId != nil }

    /// File attachments attached to the task. Populated from
    /// ClickUp's `attachments` array on the task payload AND
    /// merged with any markdown-style file links the parser
    /// finds inside the description text — both surfaces show
    /// up as a single deduplicated list of pills below the
    /// description editor.
    var attachments: [Attachment] = []

    /// ClickUp checklists on the task. ClickUp returns these in
    /// the single-task GET payload as a top-level `checklists`
    /// array, each with its own `items`. Only the full task
    /// fetch (`getTask`) includes them — the list endpoint
    /// omits checklists, so this stays empty until the detail
    /// popup hydrates the task. Default keeps older cached
    /// payloads decodable.
    var checklists: [Checklist] = []

    /// Lists the task belongs to ("Tasks in Multiple Lists"). The
    /// task's HOME list is `listId` / `listName`; this array carries
    /// every additional list the task was added to via ClickUp's
    /// `POST /list/{lid}/task/{tid}` endpoint. Populated from the
    /// `locations` field in the API payload when present — older
    /// cached payloads decode with an empty array, matching the
    /// "no extra lists" case. Always sorted alphabetically by name
    /// for predictable display.
    var locations: [TaskLocation] = []

    /// Convenience union of the home list + every entry in
    /// `locations`, deduped by id. Drives the LISTAS chips in the
    /// task detail view.
    var allListMemberships: [TaskLocation] {
        var seen: Set<String> = []
        var out: [TaskLocation] = []
        let home = TaskLocation(id: listId, name: listName)
        if !home.id.isEmpty {
            seen.insert(home.id)
            out.append(home)
        }
        for loc in locations where !seen.contains(loc.id) {
            seen.insert(loc.id)
            out.append(loc)
        }
        return out
    }

    struct TaskLocation: Codable, Hashable, Identifiable {
        let id: String
        let name: String
    }

    /// ClickUp custom fields on the task. Like checklists, only
    /// the single-task GET payload carries usable `value`s — the
    /// list endpoint returns the field definitions but typically
    /// without per-task values, so this stays empty until the
    /// detail popup hydrates the task. Default keeps older cached
    /// payloads decodable.
    ///
    /// `displayValue` is pre-formatted by the parser per field
    /// type (drop_down → option label, labels → joined labels,
    /// date → localized date, etc.) so the view layer stays dumb.
    /// `options` + `selectedOptionId` are only populated for
    /// `drop_down` fields so the detail view can offer an inline
    /// menu to change them; every other type is read-only.
    var customFields: [CustomField] = []

    struct CustomField: Codable, Hashable, Identifiable {
        let id: String
        var name: String
        /// Raw ClickUp type string (`drop_down`, `labels`,
        /// `text`, `number`, `url`, `date`, `users`, `checkbox`,
        /// …). Drives the icon and whether the row is editable.
        var type: String
        /// Human-readable, already-formatted value. Empty string
        /// means "no value set".
        var displayValue: String
        /// Drop-down options (empty for non-dropdown fields).
        var options: [Option] = []
        /// Currently-selected option id for a drop_down, when set.
        var selectedOptionId: String? = nil

        var hasValue: Bool { !displayValue.isEmpty }
        /// Only single-select drop-downs are inline-editable for
        /// now — the highest-value actionable type for the
        /// content-production workflow ("Próxima Etapa",
        /// "Empresa", "Produtos"). Everything else is read-only.
        var isEditable: Bool { type == "drop_down" && !options.isEmpty }

        struct Option: Codable, Hashable, Identifiable {
            let id: String
            var name: String
            /// ClickUp `orderindex` — what the "set custom field"
            /// endpoint expects as the value for a drop_down.
            var orderIndex: Int
            var color: String?
        }

        /// SF Symbol per field family — keeps the rows visually
        /// scannable without a legend.
        var icon: String {
            switch type {
            case "drop_down", "labels":   return "chevron.down.square"
            case "users":                 return "person.crop.circle"
            case "url":                   return "link"
            case "email":                 return "envelope"
            case "phone":                 return "phone"
            case "date":                  return "calendar"
            case "number", "currency",
                 "money":                 return "number"
            case "checkbox":              return "checkmark.square"
            case "emoji", "rating":       return "star"
            default:                       return "tag"
            }
        }
    }

    /// Blocking relationships from ClickUp's `dependencies`
    /// array, already interpreted relative to THIS task
    /// (waiting-on vs. blocking). Read-only — Apollo surfaces
    /// them as visual blocks; editing the dependency graph is
    /// out of scope. List-endpoint-omitted; hydrated via getTask.
    var dependencies: [Dependency] = []
    /// Task ids from ClickUp's `linked_tasks` (non-blocking
    /// "related" links). Titles/status are resolved lazily by
    /// AppState from the loaded set or a bounded getTask.
    var linkedTaskIds: [String] = []

    struct Dependency: Codable, Hashable, Identifiable {
        enum Kind: String, Codable {
            /// This task can't proceed until `otherTaskId` is done.
            case waitingOn
            /// `otherTaskId` can't proceed until this one is done.
            case blocking
        }
        let otherTaskId: String
        let kind: Kind
        var id: String { "\(kind.rawValue):\(otherTaskId)" }
    }

    /// One ClickUp checklist (a named group of checkable items).
    struct Checklist: Codable, Hashable, Identifiable {
        let id: String
        var name: String
        /// `orderindex` from ClickUp — used to keep multiple
        /// checklists in the order the user arranged them.
        var orderIndex: Int
        var items: [Item]

        /// Convenience for the progress label
        /// ("3/8 concluídos").
        var resolvedCount: Int { items.filter(\.resolved).count }

        struct Item: Codable, Hashable, Identifiable {
            let id: String
            var name: String
            var resolved: Bool
            var orderIndex: Int
            /// Assignee user id, when ClickUp returns one. We
            /// only render the presence of an assignee as a
            /// small dot — full avatar resolution would need a
            /// roster lookup the checklist payload doesn't
            /// carry.
            var assigneeId: Int?
        }
    }

    struct Attachment: Codable, Hashable, Identifiable {
        /// Unique identifier — uses ClickUp's `id` when
        /// available, falls back to the URL string for
        /// description-derived attachments without a real id.
        let id: String
        let title: String
        let url: String
        /// File extension (lowercased, no dot) — derived from
        /// the title or url. Drives the icon + accent colour.
        let ext: String
        /// Optional human-readable file size string. Empty
        /// when missing (description-derived links typically
        /// have no size info).
        let sizeString: String?

        /// Count of proofing / video-annotation comments tied
        /// to this attachment. ClickUp returns this in the task
        /// payload as `total_comments`. The proofing comments
        /// themselves aren't exposed by the public API (they
        /// require a JWT session cookie reachable only from the
        /// web client), but surfacing the count + a direct
        /// "open in ClickUp" path tells the user the
        /// annotations exist instead of silently hiding them.
        /// Optional so cached snapshots written before this
        /// field existed still decode.
        let totalComments: Int?
        /// Subset of `totalComments` already marked resolved.
        /// Used to render the badge in a calmer state when
        /// every annotation has been addressed.
        let resolvedComments: Int?

        /// ClickUp user id of whoever uploaded this attachment.
        /// Used by the diff-based notifier to fire a toast only
        /// when proofing comments accrue on files the CURRENT
        /// user uploaded — strangers leaving annotations on
        /// teammates' uploads shouldn't ping the wrong inbox.
        /// Optional because some attachment shapes (description-
        /// derived links) don't carry an uploader.
        let uploaderId: Int?

        /// SF Symbol that best represents this file type.
        var icon: String {
            switch ext {
            case "pdf":
                return "doc.fill"
            case "doc", "docx", "txt", "rtf", "md":
                return "doc.text.fill"
            case "xls", "xlsx", "csv", "numbers":
                return "tablecells.fill"
            case "ppt", "pptx", "key":
                return "rectangle.stack.fill"
            case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg":
                return "photo.fill"
            case "mp4", "mov", "avi", "mkv", "webm":
                return "video.fill"
            case "mp3", "wav", "m4a", "flac", "aac":
                return "waveform"
            case "zip", "rar", "7z", "tar", "gz":
                return "archivebox.fill"
            case "fig", "sketch":
                return "pencil.and.ruler.fill"
            default:
                return "paperclip"
            }
        }

        /// Accent colour per file family. Tints the chip's
        /// icon background and (subtly) its border.
        var accentHex: String {
            switch ext {
            case "pdf":
                return "#FF5757"
            case "doc", "docx", "txt", "rtf", "md":
                return "#4F8EF7"
            case "xls", "xlsx", "csv", "numbers":
                return "#34C759"
            case "ppt", "pptx", "key":
                return "#FF9F0A"
            case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg":
                return "#A875FF"
            case "mp4", "mov", "avi", "mkv", "webm":
                return "#5AC8FA"
            case "mp3", "wav", "m4a", "flac", "aac":
                return "#FF5E8A"
            case "zip", "rar", "7z", "tar", "gz":
                return "#87909E"
            case "fig", "sketch":
                return "#FF6F61"
            default:
                return "#87909E"
            }
        }
    }

    struct Assignee: Codable, Hashable {
        let id:             Int
        let username:       String
        let initials:       String?
        let color:          String?
        let profilePicture: String?
    }

    struct Tag: Codable, Hashable {
        let name:       String
        let foreground: String
        let background: String
    }

    /// Canonical ClickUp pill colour for this task's status, matching CUStatus.displayHex.
    var statusDisplayHex: String {
        CUStatus(status: status, color: statusColor, type: isCompleted ? "closed" : "open").displayHex
    }

    /// Muted, denser editorial priority palette — desaturated
    /// warm tones coherent with the "Editorial Calm" system
    /// (not ClickUp's vivid red/amber/cyan web flags).
    var priorityHex: String {
        switch priority {
        case 1: return "#A8392A"   // Urgente — muted brick
        case 2: return "#9A7B1F"   // Alta — muted ochre
        case 3: return "#56708A"   // Normal — muted slate-blue
        case 4: return "#7C7E84"   // Baixa — warm muted grey
        default: return "#A8A39A"  // Nenhuma — pale warm grey
        }
    }

    var priorityLabel: String {
        switch priority {
        case 1: return "Urgente"
        case 2: return "Alta"
        case 3: return "Normal"
        case 4: return "Baixa"
        default: return "—"
        }
    }

    /// "<priority> · <category>" tag line surfaced as the body of
    /// every macOS notification about this task. Hides priority
    /// when ClickUp returned no value (priority 0 / out-of-range)
    /// so the user doesn't see a stray "—".
    var notificationDetails: String {
        var parts: [String] = []
        if (1...4).contains(priority) { parts.append(priorityLabel) }
        parts.append(status.uppercased())
        return parts.joined(separator: " · ")
    }

    static func mock() -> [CUTask] {
        let now = Date()
        return [
            CUTask(id: "t1", title: "Implementar autenticação OAuth",    status: "in progress", statusColor: "#4194F6", priority: 1, priorityColor: "#FF1744", startDate: nil, dueDate: now,                            listId: "l1", listName: "Sprint 1",  isCompleted: false),
            CUTask(id: "t2", title: "Revisar design do dashboard",       status: "open",        statusColor: "#87909E", priority: 2, priorityColor: "#FF6D00", startDate: nil, dueDate: now.addingTimeInterval(86400),  listId: "l1", listName: "Sprint 1",  isCompleted: false),
            CUTask(id: "t3", title: "Escrever testes unitários",         status: "open",        statusColor: "#87909E", priority: 3, priorityColor: "#2979FF", startDate: nil, dueDate: now.addingTimeInterval(172800), listId: "l1", listName: "Sprint 1",  isCompleted: false),
            CUTask(id: "t4", title: "Deploy para staging",               status: "open",        statusColor: "#87909E", priority: 2, priorityColor: "#FF6D00", startDate: nil, dueDate: now.addingTimeInterval(259200), listId: "l2", listName: "DevOps",    isCompleted: false),
            CUTask(id: "t5", title: "Atualizar documentação da API",     status: "open",        statusColor: "#87909E", priority: 4, priorityColor: "#9E9E9E", startDate: nil, dueDate: now.addingTimeInterval(345600), listId: "l1", listName: "Sprint 1",  isCompleted: false),
            CUTask(id: "t6", title: "Setup ambiente de homologação",     status: "complete",    statusColor: "#6BC950", priority: 3, priorityColor: "#2979FF", startDate: nil, dueDate: nil,                            listId: "l2", listName: "DevOps",    isCompleted: true),
        ]
    }
}
