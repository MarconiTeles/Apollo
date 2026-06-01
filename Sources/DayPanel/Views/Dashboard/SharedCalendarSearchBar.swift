import SwiftUI

/// Floating search affordance overlaid on the timeline that
/// expands from a compact circular button into a full search
/// bar — same UX as Google Calendar's "Search for people"
/// pill in the left sidebar.
///
/// Compact state: a 36pt circle with a person+plus glyph,
/// pinned to the bottom-right of the timeline.
/// Expanded state: a 280pt-wide search field with live
/// suggestions from `ContactsService` (the same roster the
/// CreateEventSheet uses for guests). Picking a suggestion
/// adds the contact to `appState.sharedCalendars`, which
/// triggers a background sync that overlays their events on
/// the timeline.
///
/// Already-overlaid contacts surface as colored avatar
/// chips above the search bar so the user can remove them
/// with one click.
struct SharedCalendarSearchBar: View {
    @EnvironmentObject var appState: AppState
    @State private var expanded: Bool = false
    @State private var query: String = ""
    @FocusState private var fieldFocused: Bool
    // Field width is governed by the parent's
    // `containerRelativeFrame` clamp. Internal slots use
    // `.frame(maxWidth: .infinity)` so they inherit the
    // responsive width without any additional measurement
    // here. Cleaner than the previous environment-based
    // read because the parent already knows the column
    // width and applies the min/max clamp once.

    /// Suggestions filtered live from the user's Google
    /// Calendar contacts roster (`appState.calendarContacts`),
    /// which AppState builds from the attendees of every
    /// synced Google Calendar event. This intentionally does
    /// NOT touch macOS Contacts — the user wanted to search
    /// only people present in their Google account, not the
    /// EventKit address book.
    private var suggestions: [AppState.CalendarContact] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let already = Set(appState.sharedCalendars.map { $0.email.lowercased() })

        // Score each contact: name-prefix > name-substring >
        // email-prefix > email-substring. Lower score sorts
        // first.
        struct Scored {
            let contact: AppState.CalendarContact
            let score: Int
        }
        let scored = appState.calendarContacts
            .filter { !already.contains($0.email.lowercased()) }
            .compactMap { c -> Scored? in
                let name  = c.name.lowercased()
                let email = c.email.lowercased()
                if name.hasPrefix(q)             { return Scored(contact: c, score: 0) }
                if name.contains(q)              { return Scored(contact: c, score: 1) }
                if email.hasPrefix(q)            { return Scored(contact: c, score: 2) }
                if email.contains(q)             { return Scored(contact: c, score: 3) }
                return nil
            }
            .sorted { $0.score < $1.score }
            .prefix(8)
        return scored.map { $0.contact }
    }

    /// Live Google People results (contacts + other contacts + directory),
    /// fetched async on query change. Broadens the roster beyond people seen in
    /// past events — same source the event attendee field uses.
    @State private var peopleResults: [AppState.CalendarContact] = []

    /// Local roster first (people you've actually shared calendars with),
    /// then the broader People API hits. De-duped by email, capped.
    private var mergedSuggestions: [AppState.CalendarContact] {
        var seen = Set<String>()
        var out: [AppState.CalendarContact] = []
        for c in suggestions + peopleResults {
            if seen.insert(c.email.lowercased()).inserted { out.append(c) }
            if out.count >= 8 { break }
        }
        return out
    }

    var body: some View {
        // Two stacked rows, both right-aligned within the
        // overlay container. The OUTER VStack uses
        // `alignment: .trailing` so every child snaps to the
        // right edge by default — no per-child Spacers, no
        // HStack wrappers. This keeps the layout impossible
        // to break: regardless of whether chips exist or
        // not, the bottom row (button OR bar) is ALWAYS
        // rendered and the chips slot above it is rendered
        // only when there are contacts.
        VStack(alignment: .trailing, spacing: 8) {
            // Active overlay chips — visible regardless of
            // expansion state so the user always sees who's
            // currently surfaced on the timeline. The
            // FlowLayout sizes itself to its content width;
            // the outer `.frame(maxWidth: .infinity,
            // alignment: .trailing)` then snaps that
            // content block against the right edge of the
            // overlay container so chips line up directly
            // above the circular add button below.
            if !appState.sharedCalendars.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(appState.sharedCalendars) { contact in
                        contactChip(contact)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            // Bottom row — bar (when expanded, fills width)
            // OR button (when collapsed, hugged to the
            // trailing edge by the outer VStack's alignment).
            // Both branches are wrapped so the if/else
            // boundary participates in the same spring
            // animation triggered by `expanded`.
            if expanded {
                expandedField
                    .frame(maxWidth: .infinity)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.7, anchor: .trailing)
                            .combined(with: .opacity),
                        removal:   .scale(scale: 0.7, anchor: .trailing)
                            .combined(with: .opacity)
                    ))
            } else {
                collapsedButton
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .trailing)
                            .combined(with: .opacity),
                        removal:   .scale(scale: 0.6, anchor: .trailing)
                            .combined(with: .opacity)
                    ))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: expanded)
        .animation(.spring(response: 0.32, dampingFraction: 0.84),
                   value: appState.sharedCalendars.count)
    }

    // MARK: - Collapsed

    private var collapsedButton: some View {
        Button {
            expanded = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                fieldFocused = true
            }
        } label: {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Editorial.page)
                .frame(width: 38, height: 38)
                // Editorial primary action: solid ink disc, page
                // glyph, one soft ambient shadow — no gradient,
                // no glass, no accent halo.
                .background(Editorial.ink, in: Circle())
                .overlay(Circle().strokeBorder(Editorial.ink, lineWidth: 1))
                .shadow(color: .black.opacity(0.20), radius: 12, x: 0, y: 5)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("Adicionar calendário de outra pessoa")
    }

    // MARK: - Expanded

    private var expandedField: some View {
        // The search input row IS the layout root — its
        // height defines the bar's pixel footprint and never
        // changes. The suggestions panel is attached as an
        // `.overlay(alignment: .top)` with an alignmentGuide
        // that shifts the overlay UP by its own height, so
        // it floats ABOVE the bar without ever participating
        // in layout. Result: the bar's position is rock-
        // stable regardless of how many suggestions appear,
        // and only the suggestions themselves animate.
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(query.isEmpty ? Editorial.inkMute : Editorial.accent)
                .frame(height: 22)
            TextField("Adicionar pessoa por email ou nome",
                      text: $query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .focusEffectDisabled()
                .font(Editorial.sans(13))
                .foregroundStyle(Editorial.ink)
                .frame(height: 22)
                .onSubmit { commitFreeformEmail() }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Editorial.inkMute)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
            Button {
                expanded = false
                query = ""
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Editorial.inkSoft)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Fechar")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        // Editorial floating bar — near-neutral popup surface,
        // hairline border, one soft ambient shadow. No glass.
        .background(Editorial.popup, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Editorial.rule, lineWidth: 1)
        )
        // Calmer, untinted lift — matches the suggestions card so
        // the bar + dropdown read as one editorial surface.
        .shadow(color: .black.opacity(0.16), radius: 22, x: 0, y: 8)
        .shadow(color: .black.opacity(0.06), radius: 7,  x: 0, y: 2)
        // Suggestions panel is an OVERLAY — it does not
        // participate in the bar's layout. We then nudge
        // it upward via `alignmentGuide(.top) { d.height + 6 }`
        // which tells SwiftUI "my top alignment line is at
        // y=d.height+6", effectively shifting the overlay
        // up by its own full height + 6pt of breathing room.
        // Net: overlay sits entirely above the bar's top edge.
        .overlay(alignment: .top) {
            Group {
                if !mergedSuggestions.isEmpty {
                    suggestionsList
                        .transition(.asymmetric(
                            insertion: .opacity
                                .combined(with: .scale(scale: 0.96, anchor: .bottom)),
                            removal: .opacity
                                .combined(with: .scale(scale: 0.96, anchor: .bottom))
                        ))
                } else if !query.trimmingCharacters(in: .whitespaces).isEmpty
                          && query.contains("@") {
                    addManualHint
                        .transition(.asymmetric(
                            insertion: .opacity
                                .combined(with: .scale(scale: 0.96, anchor: .bottom)),
                            removal: .opacity
                                .combined(with: .scale(scale: 0.96, anchor: .bottom))
                        ))
                }
            }
            .alignmentGuide(.top) { d in d.height + 6 }
            .animation(.spring(response: 0.34, dampingFraction: 0.82),
                       value: mergedSuggestions.count)
            .animation(.spring(response: 0.34, dampingFraction: 0.82),
                       value: query.isEmpty)
        }
        // Broaden the roster via the Google People API (contacts + directory),
        // debounced, on every query change.
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { peopleResults = []; return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            let hits = await appState.googlePeople.search(query: q)
            let already = Set(appState.sharedCalendars.map { $0.email.lowercased() })
            peopleResults = hits.compactMap { s in
                let email = s.email.lowercased()
                guard !already.contains(email) else { return nil }
                return AppState.CalendarContact(name: s.name ?? s.email, email: s.email)
            }
        }
    }

    /// Pretty display name. Google often has no `displayName`, so
    /// the contact's `name` IS the email — rendering it as both
    /// the title and the subtitle was the biggest source of visual
    /// noise. This title-cases the email's local part
    /// ("ana.figueiredo" → "Ana Figueiredo") and the caller drops
    /// the email subtitle when it would just repeat the title.
    private func prettyName(_ rawName: String, email: String) -> String {
        let raw = rawName.trimmingCharacters(in: .whitespaces)
        let looksLikeEmail = raw.isEmpty || raw == email || raw.contains("@")
        let token: String = looksLikeEmail
            ? String((email.split(separator: "@").first ?? "").prefix(64))
            : raw
        return token
            .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
            .map { w in
                guard let f = w.first else { return String(w) }
                return String(f).uppercased() + w.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    private var suggestionsList: some View {
        let items = mergedSuggestions
        return VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, contact in
                ContactSuggestionRow(
                    name:  prettyName(contact.name, email: contact.email),
                    email: contact.email,
                    initials: initials(for: prettyName(contact.name, email: contact.email)),
                    color: Color(hex: SharedCalendar.paletteColor(for: contact.email)).editorialMuted,
                    showsDivider: idx < items.count - 1
                ) {
                    add(email: contact.email, name: contact.name)
                }
            }
        }
        .frame(maxWidth: .infinity)
        // Cap the panel so a long roster scrolls instead of
        // running off the top of the window.
        .frame(maxHeight: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(Editorial.popup,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Editorial.rule, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 28, x: 0, y: 10)
        .shadow(color: .black.opacity(0.07), radius: 8,  x: 0, y: 2)
    }

    private var addManualHint: some View {
        Button { commitFreeformEmail() } label: {
            HStack(spacing: 10) {
                Image(systemName: "envelope")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Editorial.accent)
                    .frame(width: 24)
                (Text("Convidar ")
                    .font(Editorial.serif(13).italic())
                    .foregroundStyle(Editorial.inkSoft)
                 + Text(query.trimmingCharacters(in: .whitespaces))
                    .font(Editorial.serif(14))
                    .foregroundStyle(Editorial.ink))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Editorial.accent)
                    .frame(width: 22)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Editorial.popup,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Editorial.rule, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 28, x: 0, y: 10)
            .shadow(color: .black.opacity(0.07), radius: 8, x: 0, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    // MARK: - Active chips

    /// Display name resolver. Google's `attendees[].displayName`
    /// is often missing — `parseEvent` falls back to the email
    /// in that case, so `contact.name` may literally BE the
    /// email (e.g. "ana.bastos@minimalclub.com.br"). The chip
    /// looked unreadable rendering the full address; this
    /// helper strips the domain and titlecases the local
    /// part so "ana.bastos" reads as "Ana Bastos".
    private func displayName(for contact: SharedCalendar) -> String {
        let raw = contact.name.trimmingCharacters(in: .whitespaces)
        // If the "name" field is actually an email, reduce to
        // its local part. Otherwise use as-is.
        let token: String
        if raw.contains("@"), let local = raw.split(separator: "@").first {
            token = String(local)
        } else {
            token = raw
        }
        // Title-case: "ana.bastos" → "Ana Bastos".
        return token
            .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
            .map { word in
                guard let first = word.first else { return String(word) }
                return String(first).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    private func contactChip(_ contact: SharedCalendar) -> some View {
        let limited = appState.sharedCalendarsLimitedAccess.contains(contact.email.lowercased())
        let chipColor = Color(hex: contact.colorHex)
        let name = displayName(for: contact)
        return HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(chipColor.editorialMuted)
                    .frame(width: 20, height: 20)
                Text(initials(for: name))
                    .font(Editorial.sans(8, .bold))
                    .foregroundStyle(Editorial.page)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(Editorial.serif(12))
                    .foregroundStyle(Editorial.ink)
                    .lineLimit(1)
                if limited {
                    Text("disponibilidade")
                        .font(Editorial.sans(8.5))
                        .foregroundStyle(Editorial.inkMute)
                }
            }
            Button {
                appState.removeSharedCalendar(email: contact.email)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Editorial.inkMute)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Remover \(name)")
        }
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .padding(.vertical, 4)
        // Editorial chip — card surface + hairline, the contact's
        // identity colour carried only by the muted avatar disc.
        // One whisper-soft shadow so it lifts off the timeline
        // without the old tinted halo.
        .background(Editorial.card, in: Capsule())
        .overlay(
            Capsule().strokeBorder(Editorial.rule, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 5, x: 0, y: 2)
    }

    // MARK: - Helpers

    private func add(email: String, name: String?) {
        appState.addSharedCalendar(email: email, name: name)
        query = ""
        // Stay expanded so the user can add another. Press
        // Esc/X to dismiss.
    }

    private func commitFreeformEmail() {
        let raw = query.trimmingCharacters(in: .whitespaces)
        guard raw.contains("@") else { return }
        add(email: raw, name: nil)
    }

    private func initials(for name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "." })
        if parts.count >= 2,
           let f = parts.first?.first,
           let l = parts.dropFirst().first?.first {
            return "\(f)\(l)".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}

// MARK: - Editorial contact-suggestion row

/// One row in the people-search dropdown. Editorial: muted avatar
/// disc, serif name, italic-caption email (only when it differs
/// from the name so an email-only contact isn't printed twice),
/// a quiet `+` that warms to cinnabar on hover, and a soft ink
/// hover wash. Rows self-divide with a `ruleSoft` hairline.
private struct ContactSuggestionRow: View {
    let name: String
    let email: String
    let initials: String
    let color: Color
    let showsDivider: Bool
    let onAdd: () -> Void

    @State private var hover = false

    private var showsEmail: Bool {
        email.caseInsensitiveCompare(name) != .orderedSame
    }

    var body: some View {
        Button(action: onAdd) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(color).frame(width: 24, height: 24)
                    Text(initials)
                        .font(Editorial.sans(8.5, .bold))
                        .foregroundStyle(Editorial.page)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(Editorial.serif(14))
                        .foregroundStyle(Editorial.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if showsEmail {
                        Text(email)
                            .font(Editorial.serif(11.5).italic())
                            .foregroundStyle(Editorial.inkSoft)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hover ? Editorial.accent : Editorial.inkMute)
                    .frame(width: 22, height: 22)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover ? Editorial.ink.opacity(0.04) : Color.clear)
            .overlay(alignment: .bottom) {
                if showsDivider {
                    Rectangle().fill(Editorial.ruleSoft)
                        .frame(height: 1)
                        .padding(.leading, 48)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}
