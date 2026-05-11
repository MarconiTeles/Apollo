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
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(
                    LinearGradient(
                        colors: [
                            Color.accentColor,
                            Color.accentColor.opacity(0.85),
                        ],
                        startPoint: .top,
                        endPoint:   .bottom
                    ),
                    in: Circle()
                )
                // Liquid-glass specular edge + ambient shadow,
                // matching every other circular toolbar
                // button in Apollo (settings, sync, bell).
                .liquidGlassEdge(Circle())
                // Stronger accent halo on top of the standard
                // glass treatment so the floating button
                // reads as a primary call-to-action.
                .shadow(color: Color.accentColor.opacity(0.55),
                        radius: 14, x: 0, y: 6)
                .shadow(color: Color.accentColor.opacity(0.30),
                        radius: 4,  x: 0, y: 2)
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
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(height: 22)
            TextField("Adicionar pessoa por email ou nome",
                      text: $query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .focusEffectDisabled()
                .font(.subheadline)
                // Explicit fixed height + middle-aligned
                // baseline so the typed text sits dead-
                // centre in the capsule.
                .frame(height: 22)
                .onSubmit { commitFreeformEmail() }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
            Button {
                expanded = false
                query = ""
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(.regularMaterial, in: Circle())
                    .liquidGlassEdge(Circle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Fechar")
        }
        // Asymmetric padding so the X button hugs the
        // capsule's right curve.
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        // Liquid-glass backdrop. SwiftUI Materials bake blur
        // and frost together — lowering their opacity dilutes
        // both, killing the actual blur. `NSVisualEffectView`
        // with `.withinWindow` blending produces a real
        // backdrop blur of the sibling events column behind
        // the bar; we then dial overall opacity to 0.4 (≈20%
        // more translucent than the previous .5) so the
        // bar reads as a soft pane of glass — events behind
        // it stay legible and softened, not erased by frost.
        // Text + icons sit in the foreground and remain crisp.
        .background {
            VisualEffectView(
                material:     .hudWindow,
                blendingMode: .withinWindow
            )
            .clipShape(Capsule(style: .continuous))
            .opacity(0.4)
        }
        .liquidGlassEdge(Capsule(style: .continuous))
        .shadow(color: Color.accentColor.opacity(0.35),
                radius: 14, x: 0, y: 6)
        .shadow(color: Color.accentColor.opacity(0.18),
                radius: 4,  x: 0, y: 2)
        // Suggestions panel is an OVERLAY — it does not
        // participate in the bar's layout. We then nudge
        // it upward via `alignmentGuide(.top) { d.height + 6 }`
        // which tells SwiftUI "my top alignment line is at
        // y=d.height+6", effectively shifting the overlay
        // up by its own full height + 6pt of breathing room.
        // Net: overlay sits entirely above the bar's top edge.
        .overlay(alignment: .top) {
            Group {
                if !suggestions.isEmpty {
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
                       value: suggestions.count)
            .animation(.spring(response: 0.34, dampingFraction: 0.82),
                       value: query.isEmpty)
        }
    }

    private var suggestionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions) { contact in
                Button { add(email: contact.email, name: contact.name) } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(Color(hex: SharedCalendar.paletteColor(for: contact.email)))
                                .frame(width: 22, height: 22)
                            Text(initials(for: contact.name))
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(contact.name)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(contact.email)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "plus.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                if contact.email != suggestions.last?.email {
                    Divider().opacity(0.30).padding(.leading, 38)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(.thickMaterial,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, x: 0, y: 4)
    }

    private var addManualHint: some View {
        Button { commitFreeformEmail() } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Adicionar “\(query.trimmingCharacters(in: .whitespaces))”")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thickMaterial,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        return HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.25))
                    .frame(width: 22, height: 22)
                Text(initials(for: name))
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if limited {
                    Text("disponibilidade")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            Button {
                appState.removeSharedCalendar(email: contact.email)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(.white.opacity(0.20), in: Circle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Remover \(name)")
        }
        .padding(.leading, 5)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        // Solid tinted fill — was 0.18 alpha which left the
        // text fighting whatever was rendered behind. Now the
        // chip itself is the colour and white text reads
        // cleanly at every scroll position.
        .background(chipColor, in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                .white.opacity(0.20), lineWidth: 0.6
            )
        )
        // Same accent-family halo as the floating button —
        // tinted by the contact's colour so each chip pops
        // off the timeline without looking flat.
        .shadow(color: chipColor.opacity(0.45), radius: 6, x: 0, y: 3)
        .shadow(color: .black.opacity(0.12),    radius: 1, x: 0, y: 1)
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
