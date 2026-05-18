import Foundation

struct CUWorkspace: Identifiable {
    let id: String
    let name: String
}

struct CUSpace: Identifiable {
    let id: String
    let name: String
}

struct CUFolder: Identifiable {
    let id: String
    let name: String
    let lists: [CUList]
}

struct CUList: Identifiable {
    let id: String
    let name: String
}

struct CUStatus: Identifiable, Hashable {
    let status: String   // "to do", "in progress", etc.
    let color:  String   // "#d3d3d3" — comes from the ClickUp API
    let type:   String   // "open" | "custom" | "closed" | "done"
    var id: String { status }
    var isClosed: Bool { type == "closed" || type == "done" }

    /// ClickUp's API often returns greyed-out colors for default statuses,
    /// even when the workspace UI shows them as vivid pills. This mapping
    /// returns the canonical ClickUp pill colour for well-known status names
    /// (PT-BR + EN), falling back to whatever the API supplied.
    var displayHex: String {
        let key = status.lowercased().trimmingCharacters(in: .whitespaces)
        // Muted, denser "Editorial Calm" palette — same families
        // as `Editorial.statusColor`, desaturated/deepened to sit
        // with the cream/ink system instead of ClickUp's vivid
        // web hues.
        let map: [(String, String)] = [
            ("to do",         "#54577E"),  // muted slate-indigo
            ("todo",          "#54577E"),
            ("a fazer",       "#54577E"),
            ("doing",         "#B0612E"),  // muted terracotta
            ("em andamento",  "#B0612E"),
            ("in progress",   "#B0612E"),
            ("em progresso",  "#B0612E"),
            ("review",        "#7A6597"),  // muted dusty plum
            ("revisão",       "#7A6597"),
            ("revisao",       "#7A6597"),
            ("in review",     "#7A6597"),
            ("liberado",      "#9A7B1F"),  // deep muted ochre
            ("released",      "#9A7B1F"),
            ("aprovado",      "#9A7B1F"),
            ("approved",      "#9A7B1F"),
            ("complete",      "#3F6B4A"),  // muted forest sage
            ("completed",     "#3F6B4A"),
            ("concluído",     "#3F6B4A"),
            ("concluido",     "#3F6B4A"),
            ("done",          "#3F6B4A"),
            ("finalizado",    "#3F6B4A"),
            ("cancelado",     "#B0402C"),  // muted brick (accent kin)
            ("cancelled",     "#B0402C"),
            ("canceled",      "#B0402C"),
            ("backlog",       "#5E5786"),  // muted violet-slate
            ("recorrentes",   "#7E6597"),  // muted lavender
            ("recurring",     "#7E6597"),
            ("open",          "#7C7E84"),  // warm muted grey (default)
        ]
        for (name, hex) in map where key == name || key.contains(name) {
            return hex
        }
        return color
    }
}

struct CUMember: Identifiable, Hashable {
    let id: Int
    let username:       String
    let email:          String?
    let color:          String?
    let profilePicture: String?
    let initials:       String?
}
