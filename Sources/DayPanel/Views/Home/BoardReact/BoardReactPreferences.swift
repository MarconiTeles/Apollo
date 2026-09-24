#if APOLLO_BOARD_REACT
import Combine
import Foundation

/// Board view configuration per list (group, sort, card size, covers,
/// closed tasks, collapsed groups, hidden fields) and the manual card order
/// per group. Local preferences — never presented as a synced ClickUp view.
///
/// Versioned keys: the legacy `dp_board_cardOrder_v1` (status name → ids,
/// global) is read as the fallback for status groups and never rewritten.
///
/// Observable: the native window toolbar (group, sort, view options, search)
/// and the page edit the same `current` configuration of the active list.
@MainActor
final class BoardReactPreferences: ObservableObject {
    static let shared = BoardReactPreferences()

    /// Configuration of the list on screen.
    @Published private(set) var current = Prefs()
    /// Board search (toolbar `.searchable`); not persisted, like ClickUp.
    @Published var query = ""
    /// Cards the page shows after search/subtask options (window subtitle).
    @Published var total: Int?
    /// Group headers the page laid out (native pills in the header band).
    @Published var headers: [BoardReactHeader] = []
    /// One-shot page commands from native controls ("collapseAll", …).
    let commands = PassthroughSubject<String, Never>()
    private(set) var listId = ""

    struct Prefs: Codable, Equatable {
        var groupBy = "status"
        var sort = "manual"
        var desc = false
        var size = "m"
        var covers = true
        var emptyFields = false
        var collapseEmpty = false
        var showClosed = false
        var subtasks = "cards"
        var collapsed: [String] = []
        var hidden: [String] = []

        init() {}

        // Unknown or missing keys fall back to the defaults instead of
        // discarding the whole configuration.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Prefs()
            groupBy = (try? c.decode(String.self, forKey: .groupBy)) ?? d.groupBy
            sort = (try? c.decode(String.self, forKey: .sort)) ?? d.sort
            desc = (try? c.decode(Bool.self, forKey: .desc)) ?? d.desc
            size = (try? c.decode(String.self, forKey: .size)) ?? d.size
            covers = (try? c.decode(Bool.self, forKey: .covers)) ?? d.covers
            emptyFields = (try? c.decode(Bool.self, forKey: .emptyFields)) ?? d.emptyFields
            collapseEmpty = (try? c.decode(Bool.self, forKey: .collapseEmpty)) ?? d.collapseEmpty
            showClosed = (try? c.decode(Bool.self, forKey: .showClosed)) ?? d.showClosed
            subtasks = (try? c.decode(String.self, forKey: .subtasks)) ?? d.subtasks
            collapsed = (try? c.decode([String].self, forKey: .collapsed)) ?? d.collapsed
            hidden = (try? c.decode([String].self, forKey: .hidden)) ?? d.hidden
        }
    }

    private let defaults: UserDefaults
    private let prefsKey = "dp_board_react_prefs_v1"
    private let ordersKey = "dp_board_react_order_v1"
    private let legacyOrderKey = "dp_board_cardOrder_v1"

    private var prefsByList: [String: Prefs]
    private var ordersByList: [String: [String: [String]]]

    /// Fixture storage exists only in DEBUG/DEV builds.
    private nonisolated static var defaultStore: UserDefaults {
        #if DEBUG || APOLLO_DEV
        if ApolloDevLaunchOptions.isFixtureMode { return ApolloPreviewFixtures.defaults }
        #endif
        return .standard
    }

    init(defaults: UserDefaults = BoardReactPreferences.defaultStore) {
        self.defaults = defaults
        prefsByList = Self.decode(defaults.string(forKey: prefsKey)) ?? [:]
        ordersByList = Self.decode(defaults.string(forKey: ordersKey)) ?? [:]
    }

    /// The board shows another list: load its configuration.
    func activate(listId: String) {
        guard listId != self.listId else { return }
        self.listId = listId
        current = prefs(for: listId)
        query = ""
        total = nil
    }

    func update(_ change: (inout Prefs) -> Void) {
        var next = current
        change(&next)
        guard next != current else { return }
        current = next
        setPrefs(next, for: listId)
    }

    func prefs(for listId: String) -> Prefs {
        prefsByList[listId] ?? Prefs()
    }

    func setPrefs(_ prefs: Prefs, for listId: String) {
        guard prefsByList[listId] != prefs else { return }
        prefsByList[listId] = prefs
        defaults.set(Self.encode(prefsByList), forKey: prefsKey)
    }

    /// Manual order per `groupBy:key`; status groups fall back to the legacy
    /// per-status order so the arrangement survives the new renderer.
    func orders(for listId: String, statusKeys: [String]) -> [String: [String]] {
        var out = ordersByList[listId] ?? [:]
        let legacy = BoardOrdering.decode(defaults.string(forKey: legacyOrderKey) ?? "{}")
        for key in statusKeys where out["status:\(key)"] == nil {
            if let ids = legacy[key], !ids.isEmpty { out["status:\(key)"] = ids }
        }
        return out
    }

    func setOrder(_ ids: [String], group: String, listId: String) {
        var lists = ordersByList[listId] ?? [:]
        guard lists[group] != ids else { return }
        lists[group] = ids
        ordersByList[listId] = lists
        defaults.set(Self.encode(ordersByList), forKey: ordersKey)
    }

    private static func decode<T: Decodable>(_ raw: String?) -> T? {
        guard let data = raw?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func encode<T: Encodable>(_ value: T) -> String? {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
/// One page column as the native header draws it: position in the
/// document (the header offsets it by the scroll), identity and count.
struct BoardReactHeader: Identifiable, Equatable {
    let gk: String
    let key: String
    let kind: String
    let title: String
    let count: Int
    let x: CGFloat
    let width: CGFloat
    let collapsed: Bool
    let canCreate: Bool
    let ids: [String]
    var id: String { gk }
}
#endif
