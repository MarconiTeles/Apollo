import Foundation

/// One entry in a task's activity log. Produced by parsing
/// `/api/v2/task/{id}/history` (still functional despite
/// being marked deprecated in ClickUp's docs — the web client
/// itself uses the same endpoint to power its Activity panel).
///
/// The wire format is loose: each `history_item` carries a
/// `field` string plus event-specific payload under `data`,
/// `before`, and `after`. The shape varies enough that the
/// parser maps known field combos to typed `Kind` cases and
/// falls back to `.unknown` for anything we don't recognise.
/// `.unknown` still renders as a generic "<actor> alterou
/// <field>" row, so a workspace using a custom field type or
/// a brand-new ClickUp event still surfaces in the timeline
/// instead of vanishing.
///
/// Equatable / Hashable so SwiftUI `ForEach` and `.equatable()`
/// can short-circuit on stable event lists. The synthetic
/// implementations are fine — every associated value is itself
/// already Equatable / Hashable.
struct TaskActivityEvent: Identifiable, Equatable, Hashable {
    /// Stable id from ClickUp's `history_item.id`. When that's
    /// missing (rare — usually only for synthesised events like
    /// the task-created marker derived from `date_created`) the
    /// caller composes one from `kind` + `date`.
    let id: String
    let date: Date
    /// Who performed the action. Optional because some
    /// system-generated events (automations, integrations)
    /// don't carry a user object.
    let actor: CUTask.Assignee?
    let kind: Kind

    /// Discriminated payload. Each case carries exactly the
    /// fields the corresponding card needs at render time —
    /// the view layer never has to re-parse the raw history
    /// payload.
    enum Kind: Equatable, Hashable {
        /// Task was opened. Synthesised from the task's own
        /// `date_created` field, not from a history_item, so
        /// every task always has at least this one event.
        case taskCreated

        /// Status pill changed. `from` may be nil for the
        /// task's first status assignment.
        case statusChanged(from: StatusRef?, to: StatusRef?)

        case assigneeAdded(CUTask.Assignee)
        case assigneeRemoved(CUTask.Assignee)

        /// File uploaded via paperclip / drag-drop / API.
        /// Carries the full attachment so the view can show a
        /// thumbnail card identical to the one used elsewhere.
        case attachmentAdded(CUTask.Attachment)
        case attachmentRemoved(CUTask.Attachment)

        case nameChanged(from: String?, to: String?)
        case priorityChanged(from: PriorityRef?, to: PriorityRef?)
        case dueDateChanged(from: Date?, to: Date?)
        case startDateChanged(from: Date?, to: Date?)

        /// Description edits — we don't carry the diff (too big
        /// and ClickUp rarely returns the old/new bodies in
        /// `history_items`); just the fact that it changed.
        case descriptionChanged

        case tagAdded(name: String, foregroundHex: String?, backgroundHex: String?)
        case tagRemoved(name: String, foregroundHex: String?, backgroundHex: String?)

        /// New subtask created under this task. `name` may be
        /// missing if ClickUp returned only the id.
        case subtaskAdded(name: String?, id: String?)

        /// Task moved to a different parent (or detached from
        /// one). String values are best-effort labels — ClickUp
        /// may return either ids or names depending on the
        /// workspace state.
        case parentChanged(from: String?, to: String?)
        case listChanged(from: String?, to: String?)

        /// Task was archived / unarchived. ClickUp doesn't
        /// always emit a dedicated event for these — when it
        /// doesn't they fall through to `.unknown`.
        case archived
        case unarchived

        /// Catch-all so unmapped events still render a row.
        /// `summary` is a short human-readable string built
        /// from `field` + `before`/`after` snippets so the user
        /// gets at least *some* context about what happened.
        case unknown(field: String, summary: String)
    }

    /// Lightweight reference to a status pill. We don't reuse
    /// `CUStatus` because history items only carry name + hex
    /// — there's no `orderindex` / `type` data on the wire and
    /// re-fabricating those fields would be misleading.
    struct StatusRef: Equatable, Hashable {
        let name: String
        let hex: String?
    }

    /// Lightweight reference to a priority. Same reasoning as
    /// `StatusRef` — history items don't carry the full ClickUp
    /// priority object.
    struct PriorityRef: Equatable, Hashable {
        let name: String
        let hex: String?
    }
}

// MARK: - Display helpers

extension TaskActivityEvent {
    /// SF Symbol that visually labels the row. Mirrors the
    /// icon set ClickUp's own Activity panel uses (e.g.
    /// paperclip for uploads, person.badge.plus for
    /// assignment, flag.fill for status).
    var iconName: String {
        switch kind {
        case .taskCreated:                    return "plus.circle.fill"
        case .statusChanged:                  return "flag.fill"
        case .assigneeAdded:                  return "person.fill.badge.plus"
        case .assigneeRemoved:                return "person.fill.badge.minus"
        case .attachmentAdded:                return "paperclip"
        case .attachmentRemoved:              return "paperclip.badge.ellipsis"
        case .nameChanged:                    return "pencil"
        case .priorityChanged:                return "exclamationmark.triangle.fill"
        case .dueDateChanged, .startDateChanged: return "calendar"
        case .descriptionChanged:             return "text.alignleft"
        case .tagAdded:                       return "tag.fill"
        case .tagRemoved:                     return "tag.slash"
        case .subtaskAdded:                   return "rectangle.stack.badge.plus"
        case .parentChanged:                  return "arrow.triangle.branch"
        case .listChanged:                    return "list.bullet.rectangle"
        case .archived:                       return "archivebox.fill"
        case .unarchived:                     return "tray.and.arrow.up.fill"
        case .unknown:                        return "circle.dashed"
        }
    }
}
