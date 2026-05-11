import Foundation

private extension Date {
    var relativeShort: String {
        let secs = Int(Date().timeIntervalSince(self))
        if secs < 60  { return "agora" }
        if secs < 3600 { return "\(secs / 60) min" }
        return "\(secs / 3600) h"
    }
}

enum SyncStatus: Equatable {
    case idle
    case syncing
    case success(Date)
    case error(String)
    case offline

    var label: String {
        switch self {
        case .idle:              return "Pronto"
        case .syncing:           return "Sync…"
        case .success(let date): return date.relativeShort
        case .error:             return "Erro"
        case .offline:           return "Offline"
        }
    }

    var isAnimating: Bool {
        if case .syncing = self { return true }
        return false
    }
}
