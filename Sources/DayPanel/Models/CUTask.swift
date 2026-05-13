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

    /// ClickUp's canonical priority palette (matches the flags shown in
    /// ClickUp's own UI: Urgent red, High amber, Normal blue, Low grey).
    var priorityHex: String {
        switch priority {
        case 1: return "#F50000"   // Urgent
        case 2: return "#FFCC00"   // High
        case 3: return "#6FDDFF"   // Normal
        case 4: return "#87909E"   // Low
        default: return "#BFBFBF"  // None
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
