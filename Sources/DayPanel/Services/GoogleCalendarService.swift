import Foundation

/// Thin REST client for Google Calendar API v3. Currently exposes
/// just the `events.insert` endpoint with proper attendee
/// support — that's the one piece EventKit on macOS can't do
/// (attendees are read-only via Apple's API).
///
/// The flow:
///   1. Apollo's `GoogleAuthService` holds a valid OAuth token.
///   2. `AgentActionExecutor.runCreateEvent` (and the manual
///      "+ Evento" form) detects guests in the request.
///   3. If Google is connected AND guests are non-empty, route
///      the create through here. Otherwise fall back to EventKit.
///
/// Why we still touch EventKit afterwards: the new Google event
/// will sync down to Calendar.app via the user's existing
/// Internet Account — but that round-trip can take 30+ seconds.
/// Apollo's UI optimistically appends the event so the user
/// sees it immediately; the EventKit refresh on next sync
/// reconciles the canonical version.
final class GoogleCalendarService {

    private let auth: GoogleAuthService

    init(auth: GoogleAuthService) {
        self.auth = auth
    }

    /// Creates a new event on the user's PRIMARY Google Calendar
    /// with the given attendees. Returns the created event ID
    /// (Google's, not EventKit's) and the meeting link if Google
    /// auto-generated one. `sendUpdates: "all"` makes Google
    /// actually email the invites — without it the attendees
    /// appear on the event but never get notified.
    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        location: String?,
        notes: String?,
        attendees: [String],
        colorId: String? = nil
    ) async throws -> CreatedEvent {
        let token = try await auth.validAccessToken()

        // Calendar ID `primary` is a Google-side alias for the
        // signed-in user's main calendar — saves us a separate
        // CalendarList.list call to discover the real ID.
        var components = URLComponents(string:
            "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        components.queryItems = [
            // sendUpdates=all → Google emails the attendees.
            // Without this, attendees appear on the event but
            // are never notified.
            URLQueryItem(name: "sendUpdates", value: "all"),
        ]
        var req = URLRequest(url: components.url!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Body shape per Google's reference:
        // https://developers.google.com/calendar/api/v3/reference/events/insert
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime]
        var body: [String: Any] = [
            "summary": title,
            "start": [
                "dateTime": isoFmt.string(from: startDate),
                "timeZone": TimeZone.current.identifier,
            ],
            "end": [
                "dateTime": isoFmt.string(from: endDate),
                "timeZone": TimeZone.current.identifier,
            ],
            "attendees": attendees.map { ["email": $0] },
        ]
        if let location, !location.isEmpty { body["location"] = location }
        if let notes, !notes.isEmpty       { body["description"] = notes }
        if let colorId, !colorId.isEmpty   { body["colorId"] = colorId }

        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw GCalError.message("Google Calendar API \(((response as? HTTPURLResponse)?.statusCode).map(String.init) ?? "?"): \(raw.prefix(300))")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String
        else {
            throw GCalError.message("Resposta sem id do evento")
        }
        let htmlLink = json["htmlLink"] as? String
        let hangoutLink = json["hangoutLink"] as? String
        return CreatedEvent(id: id, htmlLink: htmlLink, meetingURL: hangoutLink)
    }

    struct CreatedEvent {
        let id: String
        let htmlLink: String?
        let meetingURL: String?
    }

    // MARK: - Update / Delete

    /// Patches an existing event. All params except `eventId`
    /// are optional — nil leaves the field untouched on the
    /// server. Uses HTTP PATCH so we don't have to send the
    /// full event payload.
    func updateEvent(
        eventId: String,
        calendarId: String = "primary",
        title: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        location: String? = nil,
        notes: String? = nil,
        attendees: [String]? = nil,
        colorId: String? = nil
    ) async throws {
        let token = try await auth.validAccessToken()

        // PATCH the event on ITS calendar, not a hardcoded
        // `primary`. Events the user owns on a secondary
        // calendar (calendarId = that calendar's address) were
        // being patched against `primary`, so writes like
        // `location` never stuck server-side — the optimistic
        // local change showed, then the next sync reverted it.
        let calRaw = calendarId.isEmpty ? "primary" : calendarId
        let calPath = calRaw.addingPercentEncoding(
            withAllowedCharacters: .urlHostAllowed) ?? calRaw
        var components = URLComponents(string:
            "https://www.googleapis.com/calendar/v3/calendars/\(calPath)/events/\(eventId)")!
        // sendUpdates=all → if attendees changed (added or
        // removed), Google emails the deltas. Even on a
        // no-attendee patch this is a safe default.
        components.queryItems = [URLQueryItem(name: "sendUpdates", value: "all")]
        var req = URLRequest(url: components.url!)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime]

        var body: [String: Any] = [:]
        if let title    { body["summary"]     = title }
        if let location { body["location"]    = location }
        if let notes    { body["description"] = notes }
        if let startDate {
            body["start"] = [
                "dateTime": isoFmt.string(from: startDate),
                "timeZone": TimeZone.current.identifier,
            ]
        }
        if let endDate {
            body["end"] = [
                "dateTime": isoFmt.string(from: endDate),
                "timeZone": TimeZone.current.identifier,
            ]
        }
        if let attendees {
            body["attendees"] = attendees.map { ["email": $0] }
        }
        if let colorId, !colorId.isEmpty {
            body["colorId"] = colorId
        }

        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw GCalError.message("Update event: \(raw.prefix(300))")
        }
    }

    /// Updates the current user's RSVP status on an existing
    /// event. Google's `events.patch` requires sending the
    /// FULL attendees array with the modified status — there
    /// is no per-attendee patch endpoint — so the caller has
    /// to provide the existing attendees list (typically read
    /// from the local `CalendarEvent.attendees`) and we splice
    /// in the new `responseStatus` for the row marked
    /// `isCurrentUser`.
    func respondToEvent(
        eventId: String,
        attendees: [CalendarEvent.Attendee],
        newStatus: CalendarEvent.Attendee.Status
    ) async throws {
        let token = try await auth.validAccessToken()

        let payloadAttendees: [[String: Any]] = attendees.compactMap { att in
            guard let email = att.email else { return nil }
            var dict: [String: Any] = ["email": email]
            // Set responseStatus only on the user's own row;
            // leave the others untouched. Google preserves
            // their existing status when we don't include
            // `responseStatus` for them.
            if att.isCurrentUser {
                dict["responseStatus"] = Self.googleString(for: newStatus)
            }
            return dict
        }
        // If the user isn't in the attendees list yet (rare:
        // they were added by URL but never had a row),
        // append a new entry so the PATCH actually creates
        // their attendee record.
        var finalAttendees = payloadAttendees
        if !attendees.contains(where: { $0.isCurrentUser }) {
            // Best-effort: try to use the connected Google
            // account email. We don't have it here directly,
            // so let Google figure it out — if the call
            // fails, the caller can fall back to EventKit.
        }

        var components = URLComponents(string:
            "https://www.googleapis.com/calendar/v3/calendars/primary/events/\(eventId)")!
        components.queryItems = [URLQueryItem(name: "sendUpdates", value: "all")]
        var req = URLRequest(url: components.url!)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["attendees": finalAttendees])

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw GCalError.message("RSVP: \(raw.prefix(300))")
        }
    }

    private static func googleString(for status: CalendarEvent.Attendee.Status) -> String {
        switch status {
        case .accepted:  return "accepted"
        case .declined:  return "declined"
        case .tentative: return "tentative"
        case .pending:   return "needsAction"
        case .unknown:   return "needsAction"
        }
    }

    /// Deletes the event from the user's primary calendar.
    /// `sendUpdates=all` notifies attendees (if any) that the
    /// meeting was cancelled — matches the user's mental
    /// model when they hit "Excluir": the meeting is gone,
    /// not just gone from THEIR view.
    func deleteEvent(eventId: String) async throws {
        let token = try await auth.validAccessToken()

        var components = URLComponents(string:
            "https://www.googleapis.com/calendar/v3/calendars/primary/events/\(eventId)")!
        components.queryItems = [URLQueryItem(name: "sendUpdates", value: "all")]
        var req = URLRequest(url: components.url!)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse,
              // 204 No Content is the success path here; some
              // edge cases return 410 Gone (already deleted),
              // which we treat as success too.
              (200..<300).contains(http.statusCode) || http.statusCode == 410
        else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw GCalError.message("Delete event: \(raw.prefix(300))")
        }
    }

    // MARK: - List events

    /// Fetches events on the user's primary calendar in the
    /// given time window. Returns model `CalendarEvent`s
    /// already mapped to Apollo's domain shape, so the
    /// caller can drop them straight into `appState.events`.
    /// Recurrence is expanded server-side via
    /// `singleEvents=true` so each occurrence comes back as
    /// a flat row.
    /// Generalised list-events that accepts an arbitrary
    /// `calendarId` — `"primary"` for the user's own
    /// calendar, an email address for any calendar they have
    /// at least free/busy access to. The hybrid shared-
    /// calendar feature tries this first; if it returns 403
    /// (no access at all), the caller falls back to
    /// `freebusyQuery` for blocked-only data.
    func listEventsOnCalendar(
        calendarId: String,
        from: Date,
        to: Date
    ) async throws -> [CalendarEvent] {
        let token = try await auth.validAccessToken()
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime]

        let escaped = calendarId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? calendarId
        var components = URLComponents(string:
            "https://www.googleapis.com/calendar/v3/calendars/\(escaped)/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin",      value: isoFmt.string(from: from)),
            URLQueryItem(name: "timeMax",      value: isoFmt.string(from: to)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy",      value: "startTime"),
            URLQueryItem(name: "maxResults",   value: "500"),
        ]
        var req = URLRequest(url: components.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw GCalError.message("List events on \(calendarId): \(raw.prefix(200))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { Self.parseEvent($0) }
    }

    /// Returns blocked-time intervals per email for the given
    /// window. Uses Google's `freebusy.query` endpoint —
    /// works for any contact whose free/busy is visible to
    /// the user (default for everyone in the same Workspace
    /// org). Strips event details by design; we only get
    /// busy/free, not titles.
    func freebusyQuery(
        emails: [String],
        from: Date,
        to: Date
    ) async throws -> [String: [(start: Date, end: Date)]] {
        guard !emails.isEmpty else { return [:] }
        let token = try await auth.validAccessToken()
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime]

        var req = URLRequest(url: URL(string:
            "https://www.googleapis.com/calendar/v3/freeBusy")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "timeMin": isoFmt.string(from: from),
            "timeMax": isoFmt.string(from: to),
            "items":   emails.map { ["id": $0] },
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw GCalError.message("FreeBusy: \(raw.prefix(200))")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let calendars = json?["calendars"] as? [String: [String: Any]] ?? [:]

        var out: [String: [(Date, Date)]] = [:]
        for (email, payload) in calendars {
            let busy = payload["busy"] as? [[String: Any]] ?? []
            let intervals: [(Date, Date)] = busy.compactMap { entry in
                guard let s = entry["start"] as? String,
                      let e = entry["end"]   as? String,
                      let sd = isoFmt.date(from: s),
                      let ed = isoFmt.date(from: e) else { return nil }
                return (sd, ed)
            }
            out[email] = intervals
        }
        return out
    }

    /// Convenience for the caller that already has Apollo's
    /// 60-day timeline window populated. Wraps both REST
    /// calls in one call site so AppState doesn't have to
    /// reach for the parser builder for synthetic free/busy
    /// `CalendarEvent`s.
    ///
    /// Strategy:
    ///   1. Try `events.list` for full details (works when
    ///      the contact shared at "see all event details").
    ///   2. On 403/404 fall back to `freebusy.query` and
    ///      synthesise opaque "Ocupado" `CalendarEvent`s.
    /// Returns `(events, hadFullAccess)` so the UI can
    /// render the contact's row with a hint when only
    /// free/busy was available.
    func listSharedCalendar(
        email: String,
        from: Date,
        to: Date,
        contactColorHex: String
    ) async throws -> (events: [CalendarEvent], hadFullAccess: Bool) {
        do {
            let evs = try await listEventsOnCalendar(
                calendarId: email, from: from, to: to
            )
            // Mark every event as foreign by replacing the
            // colour with the contact's assigned shade so
            // the timeline can tint them as overlay rows
            // distinguishable from the user's own events.
            let tinted = evs.map { ev -> CalendarEvent in
                var copy = ev
                copy.colorHex = contactColorHex
                copy.calendarName = email
                return copy
            }
            return (tinted, true)
        } catch {
            // Fall through to free/busy. Don't surface the
            // 403 to the caller — most contacts in a
            // Workspace org will fall here, it's expected.
            let busy = try await freebusyQuery(
                emails: [email], from: from, to: to
            )
            let intervals = busy[email] ?? []
            let synthetic: [CalendarEvent] = intervals.enumerated().map { (i, iv) in
                CalendarEvent(
                    id:           "fb-\(email)-\(i)-\(Int(iv.start.timeIntervalSince1970))",
                    title:        "Ocupado",
                    startDate:    iv.start,
                    endDate:      iv.end,
                    colorHex:     contactColorHex,
                    calendarId:   email,
                    isAllDay:     false,
                    location:     nil,
                    notes:        nil,
                    meetingURL:   nil,
                    attendees:    [],
                    organizerName:nil,
                    alarmOffsets: [],
                    calendarName: email
                )
            }
            return (synthetic, false)
        }
    }

    func listEvents(from: Date, to: Date) async throws -> [CalendarEvent] {
        let token = try await auth.validAccessToken()

        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime]

        var components = URLComponents(string:
            "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin",      value: isoFmt.string(from: from)),
            URLQueryItem(name: "timeMax",      value: isoFmt.string(from: to)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy",      value: "startTime"),
            URLQueryItem(name: "maxResults",   value: "2500"),
        ]
        var req = URLRequest(url: components.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw GCalError.message("List events: \(raw.prefix(300))")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]]
        else { return [] }

        return items.compactMap { Self.parseEvent($0) }
    }

    /// Maps a single Google Calendar event JSON object to
    /// Apollo's `CalendarEvent`. Returns nil when the event
    /// is missing essentials (no id, no times) — those rows
    /// are typically holds for cancelled events that the API
    /// hasn't fully purged yet.
    private static func parseEvent(_ obj: [String: Any]) -> CalendarEvent? {
        guard let id = obj["id"] as? String else { return nil }

        let title = (obj["summary"] as? String) ?? "(sem título)"
        let location = obj["location"] as? String
        let description = obj["description"] as? String
        let hangoutLink = obj["hangoutLink"] as? String
        let colorId = obj["colorId"] as? String
        // Fallback `#039BE5` (Peacock) when no `colorId` is set
        // — that's the colour Google Calendar's web UI renders
        // for events on a default-themed primary calendar.
        // Was `#4285F4` (Google brand blue), but that hex got
        // snapped to **Lavender** by `GoogleCalendarPalette`
        // because it's closer in hue distance — every default-
        // colour event was coming out purple. Peacock is in
        // the palette so it self-snaps and renders correctly.
        let calendarHex = (colorId.flatMap { CalendarEvent.googleColorMap[$0] }) ?? "#039BE5"

        let start = obj["start"] as? [String: Any] ?? [:]
        let end   = obj["end"]   as? [String: Any] ?? [:]
        let (startDate, endDate, isAllDay) = parseTimes(start: start, end: end)
        guard let startDate = startDate, let endDate = endDate else { return nil }

        // Attendees (optional).
        let rawAttendees = obj["attendees"] as? [[String: Any]] ?? []
        let attendees: [CalendarEvent.Attendee] = rawAttendees.compactMap { a in
            let email = a["email"] as? String
            let name  = (a["displayName"] as? String) ?? email ?? "?"
            let isOrg = (a["organizer"] as? Bool) ?? false
            let isSelf = (a["self"]      as? Bool) ?? false
            let respRaw = (a["responseStatus"] as? String) ?? "needsAction"
            let status: CalendarEvent.Attendee.Status = {
                switch respRaw {
                case "accepted":     return .accepted
                case "declined":     return .declined
                case "tentative":    return .tentative
                case "needsAction":  return .pending
                default:             return .unknown
                }
            }()
            return CalendarEvent.Attendee(
                name: name, email: email, status: status,
                isOrganizer: isOrg, isCurrentUser: isSelf
            )
        }

        // Organizer.
        let organizer = obj["organizer"] as? [String: Any]
        let organizerName = organizer?["displayName"] as? String
            ?? organizer?["email"] as? String

        // Reminders — use overrides if `useDefault` is off,
        // otherwise we don't have visibility into the
        // calendar-level default without an extra API call,
        // so leave empty.
        var alarmOffsets: [TimeInterval] = []
        if let reminders = obj["reminders"] as? [String: Any],
           (reminders["useDefault"] as? Bool) == false,
           let overrides = reminders["overrides"] as? [[String: Any]] {
            alarmOffsets = overrides.compactMap { ov in
                guard let minutes = ov["minutes"] as? Int else { return nil }
                return -TimeInterval(minutes * 60)
            }
        }

        return CalendarEvent(
            id:           id,
            title:        title,
            startDate:    startDate,
            endDate:      endDate,
            colorHex:     calendarHex,
            calendarId:   (obj["organizer"] as? [String: Any])?["email"] as? String ?? "primary",
            isAllDay:     isAllDay,
            location:     location,
            notes:        description,
            meetingURL:   hangoutLink.flatMap(URL.init(string:)),
            attendees:    attendees,
            organizerName:organizerName,
            alarmOffsets: alarmOffsets,
            calendarName: nil
        )
    }

    /// Google returns either `dateTime` (for timed events) or
    /// `date` (for all-day). Same struct, different keys.
    private static func parseTimes(
        start: [String: Any],
        end: [String: Any]
    ) -> (Date?, Date?, Bool) {
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime]

        if let s = start["dateTime"] as? String,
           let e = end["dateTime"] as? String,
           let sd = isoFmt.date(from: s),
           let ed = isoFmt.date(from: e) {
            return (sd, ed, false)
        }
        // All-day branch: `date` is YYYY-MM-DD in event's
        // calendar timezone. Convert at midnight local for
        // sorting/grouping consistency.
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        dayFmt.timeZone = TimeZone(identifier: "UTC")
        if let s = start["date"] as? String,
           let e = end["date"] as? String,
           let sd = dayFmt.date(from: s),
           let ed = dayFmt.date(from: e) {
            return (sd, ed, true)
        }
        return (nil, nil, false)
    }

    enum GCalError: Error, LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let m): return m
            }
        }
    }
}
