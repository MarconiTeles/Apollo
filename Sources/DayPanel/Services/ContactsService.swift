import Foundation
import Contacts

/// Suggestion source for the "Convidados" field. Builds its cache by
/// combining (in priority order):
///
///   1. **People who appear as attendees in events from the calendars
///      the user has selected for display.** This is the same source
///      Google Calendar prioritises ("frequently invited") — pulled
///      via EventKit, which mirrors the user's Google Calendar.
///
///   2. macOS Contacts (`CNContactStore`) — as a complement, in case
///      the user invites someone they've never had on a meeting yet.
///      Includes Google Contacts when synced via System Settings →
///      Internet Accounts.
///
/// EventKit attendees take precedence in the de-duplication so the
/// suggestions feel like they're coming from "the same Google
/// Calendar account" the user picked in Settings.
final class ContactsService {
    static let shared = ContactsService()

    private let store = CNContactStore()
    private var cachedSuggestions: [GuestSuggestion]?
    private var cacheLoadTask: Task<[GuestSuggestion], Never>?

    /// Most recently received list of EventKit attendees. Set by the
    /// caller (typically `CreateEventSheet`) right before or during
    /// the popup's open so the cache reflects the active calendar
    /// selection.
    private var eventAttendees: [GuestSuggestion] = []

    /// Search results merged: first the items that match by name,
    /// then ones matching by email substring. De-duplicates by email
    /// address (case-insensitive), capped to 8 results.
    func search(query rawQuery: String) async -> [GuestSuggestion] {
        let q = rawQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }

        let all = await loadAllContacts()
        guard !all.isEmpty else { return [] }

        // Score: name match > email "starts with" > email contains.
        var byName:    [GuestSuggestion] = []
        var byEmailSW: [GuestSuggestion] = []
        var byEmailC:  [GuestSuggestion] = []

        for s in all {
            let nameLower  = s.name?.lowercased() ?? ""
            let emailLower = s.email.lowercased()
            if nameLower.contains(q) {
                byName.append(s)
            } else if emailLower.hasPrefix(q) {
                byEmailSW.append(s)
            } else if emailLower.contains(q) {
                byEmailC.append(s)
            }
        }

        var seen: Set<String> = []
        var out:  [GuestSuggestion] = []
        for s in byName + byEmailSW + byEmailC {
            let key = s.email.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(s)
            if out.count >= 8 { break }
        }
        return out
    }

    /// Pre-warm the cache so the first keystroke isn't waiting on
    /// the contacts enumeration.
    func warmUp() {
        Task { _ = await loadAllContacts() }
    }

    /// Inject attendees harvested from EventKit (the events backing
    /// the calendars the user has selected in Settings). Call this on
    /// the popup's open — the cache is rebuilt so EventKit suggestions
    /// rank above the macOS-Contacts fallback. Pass an empty array to
    /// fall back to Contacts only.
    func setEventAttendees(_ attendees: [GuestSuggestion]) {
        eventAttendees = attendees
        // Invalidate the merged cache so the next search() rebuilds
        // it with the new event-attendee list at the top.
        cachedSuggestions = nil
        cacheLoadTask     = nil
    }

    // MARK: - Internal cache

    private func loadAllContacts() async -> [GuestSuggestion] {
        if let cached = cachedSuggestions { return cached }
        if let inflight = cacheLoadTask { return await inflight.value }
        let attendees = eventAttendees
        let task = Task<[GuestSuggestion], Never> { [store] in
            await Self.requestAccessIfNeeded(store: store)
            let contacts = Self.fetchAll(store: store)
            // Merge — EventKit attendees first (priority), then macOS
            // Contacts as fallback. De-dupe by email (lowercased).
            var seen: Set<String> = []
            var merged: [GuestSuggestion] = []
            for s in attendees + contacts {
                let key = s.email.lowercased()
                if seen.contains(key) { continue }
                seen.insert(key)
                merged.append(s)
            }
            return merged
        }
        cacheLoadTask = task
        let result = await task.value
        cachedSuggestions = result
        cacheLoadTask = nil
        return result
    }

    private static func requestAccessIfNeeded(store: CNContactStore) async {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .notDetermined else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            store.requestAccess(for: .contacts) { _, _ in cont.resume() }
        }
    }

    private static func fetchAll(store: CNContactStore) -> [GuestSuggestion] {
        // Bail if access denied — `enumerateContacts` would throw.
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized else { return [] }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactOrganizationNameKey,
            CNContactEmailAddressesKey,
        ] as [CNKeyDescriptor]

        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault

        var results: [GuestSuggestion] = []
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let parts = [contact.givenName, contact.familyName]
                    .filter { !$0.isEmpty }
                let name: String? = {
                    let joined = parts.joined(separator: " ")
                    if !joined.isEmpty { return joined }
                    if !contact.organizationName.isEmpty { return contact.organizationName }
                    return nil
                }()
                for email in contact.emailAddresses {
                    let address = (email.value as String).trimmingCharacters(in: .whitespaces)
                    guard !address.isEmpty, address.contains("@") else { continue }
                    results.append(GuestSuggestion(name: name, email: address))
                }
            }
        } catch {
            // Likely access denied or no contacts — return what we have.
        }
        return results
    }
}

/// Plain value used by both the Contacts cache and the create-event
/// UI's autocomplete popover.
struct GuestSuggestion: Identifiable, Hashable {
    let name:  String?
    let email: String
    var id: String { email.lowercased() }
}
