import SwiftUI

// One row in the command palette. Both static commands
// ("Sincronizar agora", "Abrir configurações", …) and dynamic
// task results funnel through this struct so the UI doesn't
// need to know what KIND of thing it's rendering — `kind`
// only matters for sorting + the section badge in the row.
//
// `perform` captures the AppState reference (not a weak one
// — palette items are short-lived, regenerated every keystroke
// from `CommandPaletteEngine.match`, so a strong capture
// can't outlive the AppState in any realistic scenario). The
// closure is fired on `Enter` or click and then the panel
// dismisses itself.
struct CommandPaletteItem: Identifiable {
    enum Kind: Int, Comparable {
        /// Specific ClickUp task — opens the detail popup.
        case task    = 0
        /// Calendar event (own or shared overlay) — opens
        /// the event detail popup.
        case event   = 1
        /// App-wide command — sync, settings, toggle mode, …
        case command = 2

        static func < (lhs: Kind, rhs: Kind) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        /// Short label rendered as the row's section badge.
        var badge: String {
            switch self {
            case .task:    return "TAREFA"
            case .event:   return "EVENTO"
            case .command: return "COMANDO"
            }
        }
    }

    /// Stable id used for SwiftUI diffing. Tasks use
    /// `task.<clickupId>`; commands use a literal handle
    /// (`cmd.sync`, `cmd.openSettings`, …).
    let id: String
    let title: String
    let subtitle: String?
    /// SF Symbol name. Drawn in a fixed 22×22 leading slot so
    /// rows align even when icons differ in width.
    let icon: String
    /// Tint for the icon. For task rows this is the task's
    /// status colour, so the palette mirrors the same colour
    /// language as the main list. For commands it's a category
    /// colour (sync = blue, settings = grey, filter = orange).
    let tint: Color
    let kind: Kind
    let perform: () -> Void
}
