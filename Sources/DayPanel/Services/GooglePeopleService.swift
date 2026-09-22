import Foundation

/// Searches Google for attendee suggestions the way Google Calendar's own
/// "add guests" field does — across three People API sources:
///   • `people:searchContacts`        the user's saved Google contacts
///   • `otherContacts:search`         people emailed but never saved
///   • `people:searchDirectoryPeople` the Workspace directory (org members)
///
/// Requires the contacts/directory OAuth scopes (see GoogleAuthService.scope).
/// If they're missing (old token) or the Cloud project doesn't allow them, the
/// calls 403 and we return [] — the EventKit + macOS-Contacts fallback in
/// ContactsService still works, so the field degrades gracefully.
final class GooglePeopleService {
    private let auth: GoogleAuthService
    init(auth: GoogleAuthService) { self.auth = auth }

    /// `searchContacts`/`otherContacts:search` need a one-time warm-up call
    /// (empty query) to prime Google's server-side cache before real queries
    /// return anything.
    private var warmedUp = false

    func search(query: String) async -> [GuestSuggestion] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let token = try? await auth.validAccessToken() else { return [] }

        if !warmedUp {
            _ = await get(searchURL("people:searchContacts", query: ""), token: token)
            _ = await get(searchURL("otherContacts:search", query: ""), token: token)
            warmedUp = true
        }

        let contacts  = await get(searchURL("people:searchContacts", query: q), token: token)
        let others    = await get(searchURL("otherContacts:search", query: q), token: token)
        let directory = await get(directoryURL(query: q), token: token)

        var seen = Set<String>()
        var out: [GuestSuggestion] = []
        for s in contacts + others + directory {
            let key = s.email.lowercased()
            if seen.insert(key).inserted { out.append(s) }
        }
        return out
    }

    // MARK: - URLs

    private func searchURL(_ path: String, query: String) -> URL {
        var c = URLComponents(string: "https://people.googleapis.com/v1/\(path)")!
        c.queryItems = [
            .init(name: "query", value: query),
            .init(name: "readMask", value: "names,emailAddresses"),
            .init(name: "pageSize", value: "20"),
        ]
        return c.url!
    }

    private func directoryURL(query: String) -> URL {
        var c = URLComponents(string: "https://people.googleapis.com/v1/people:searchDirectoryPeople")!
        c.queryItems = [
            .init(name: "query", value: query),
            .init(name: "readMask", value: "names,emailAddresses"),
            .init(name: "sources", value: "DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE"),
            .init(name: "sources", value: "DIRECTORY_SOURCE_TYPE_DOMAIN_CONTACT"),
            .init(name: "pageSize", value: "20"),
        ]
        return c.url!
    }

    // MARK: - Networking + parsing

    private func get(_ url: URL, token: String) async -> [GuestSuggestion] {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return Self.parse(data)
    }

    /// searchContacts / otherContacts → `{ results: [{ person: {...} }] }`
    /// searchDirectoryPeople        → `{ people: [{...}] }`
    private static func parse(_ data: Data) -> [GuestSuggestion] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let persons: [[String: Any]]
        if let results = obj["results"] as? [[String: Any]] {
            persons = results.compactMap { $0["person"] as? [String: Any] }
        } else if let people = obj["people"] as? [[String: Any]] {
            persons = people
        } else {
            persons = []
        }

        var out: [GuestSuggestion] = []
        for p in persons {
            let name = (p["names"] as? [[String: Any]])?.first?["displayName"] as? String
            for e in (p["emailAddresses"] as? [[String: Any]]) ?? [] {
                if let addr = (e["value"] as? String)?.trimmingCharacters(in: .whitespaces),
                   addr.contains("@") {
                    out.append(GuestSuggestion(name: name, email: addr))
                }
            }
        }
        return out
    }
}
