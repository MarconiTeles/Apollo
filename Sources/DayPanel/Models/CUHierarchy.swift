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
        let map: [(String, String)] = [
            ("to do",         "#5E5ED6"),  // purple
            ("todo",          "#5E5ED6"),
            ("a fazer",       "#5E5ED6"),
            ("doing",         "#FE9100"),  // orange
            ("em andamento",  "#FE9100"),
            ("in progress",   "#FE9100"),
            ("em progresso",  "#FE9100"),
            ("review",        "#A875FF"),  // light purple
            ("revisão",       "#A875FF"),
            ("revisao",       "#A875FF"),
            ("in review",     "#A875FF"),
            // Goldenrod — the original ClickUp yellow (#F9D900) has too
            // little chroma against white to be readable as pill text or
            // filter labels. This darker variant keeps the "amarelo/gold"
            // identity but actually stands out on light backgrounds.
            ("liberado",      "#D4A017"),
            ("released",      "#D4A017"),
            ("aprovado",      "#D4A017"),
            ("approved",      "#D4A017"),
            ("complete",      "#6BC950"),  // green
            ("completed",     "#6BC950"),
            ("concluído",     "#6BC950"),
            ("concluido",     "#6BC950"),
            ("done",          "#6BC950"),
            ("finalizado",    "#6BC950"),
            ("cancelado",     "#E50000"),  // red
            ("cancelled",     "#E50000"),
            ("canceled",      "#E50000"),
            ("backlog",       "#7B68EE"),  // muted purple
            ("recorrentes",   "#9B59B6"),  // soft violet
            ("recurring",     "#9B59B6"),
            ("open",          "#87909E"),  // grey (default)
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
