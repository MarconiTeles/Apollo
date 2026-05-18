import Foundation

/// Persisted set of "pinned" ClickUp lists so the user can
/// jump between the lists they actually work in with one click
/// — instead of re-walking workspace → space → list every time
/// in the picker. This is the pragmatic slice of multi-list
/// support: Apollo still scopes the dashboard to ONE active
/// list at a time (the cross-list view is "Meu trabalho"), but
/// switching among your handful of real lists is now instant.
///
/// Storage: a JSON array under UserDefaults key
/// `dp_pinned_lists_v1`. Each entry is just `{id, name}` — the
/// name is cached so the "Fixadas" quick-pick can render
/// without a network round-trip, and so a pinned list whose
/// space the user hasn't navigated to yet still shows its
/// label. Order is insertion order (most-recently-pinned last);
/// the UI sorts by name for stability.
enum PinnedLists {

    struct Entry: Codable, Hashable, Identifiable {
        let id: String
        var name: String
    }

    private static let key = "dp_pinned_lists_v1"
    private static let cap = 20  // bounded; nobody pins 20 lists

    static func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return decoded
    }

    private static func save(_ entries: [Entry]) {
        if let data = try? JSONEncoder().encode(Array(entries.prefix(cap))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func isPinned(id: String) -> Bool {
        load().contains { $0.id == id }
    }

    /// Pin if absent, unpin if present. Updates the cached name
    /// on re-pin in case the list was renamed in ClickUp.
    static func toggle(id: String, name: String) {
        var entries = load()
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries.remove(at: idx)
        } else {
            entries.append(Entry(id: id, name: name))
        }
        save(entries)
    }

    /// Drop a pin by id (used when a list 404s — it was
    /// deleted/archived in ClickUp and shouldn't linger in the
    /// quick-pick).
    static func remove(id: String) {
        save(load().filter { $0.id != id })
    }
}
