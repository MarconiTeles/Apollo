import SwiftUI

struct EventDetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.windowSize) private var windowSize
    let event: CalendarEvent
    var onClose: () -> Void = {}

    @State private var showDeleteConfirm = false
    /// Drives the in-app edit sheet (re-using `CreateEventSheet`
    /// in editing mode). Replaces the previous "open in
    /// Calendar.app" behaviour — Apollo now manages event
    /// edits end-to-end through Google's REST API.
    @State private var showEditSheet     = false

    /// Frozen scroll-body height — captured the first time
    /// this view appears for a given event. Once locked, the
    /// popup's interior never reflows in response to host
    /// window resizes. Reset when the event identity changes.
    @State private var lockedScrollMaxH: CGFloat? = nil

    private var color: Color { Color(googleSnapHex: event.colorHex) }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }

    /// Compute scroll-body height from the host window. Was
    /// 70% of the window; bumped to ~94.5% (+35%) per design
    /// tweak. Still clamped so the popup never overlaps the
    /// macOS toolbar.
    private func computeScrollMaxH(for window: CGSize) -> CGFloat {
        let h = window.height
        guard h > 0 else { return 540 }   // was 400; +35%
        let chrome: CGFloat = 110
        let preferred = max(300, h * 0.945 - chrome)
        let safeMax   = max(0,   h - 128 - chrome)
        return min(preferred, safeMax)
    }

    /// Frozen value used by the layout. Falls back to a live
    /// computation only on the very first render before
    /// `onAppear` has had a chance to lock it in.
    private var scrollMaxHeight: CGFloat {
        lockedScrollMaxH ?? computeScrollMaxH(for: windowSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — no own background; popup-level material
            // (applied by `popupGlass`) shows through here as
            // the translucent title bar. Matches the design
            // language used by `TaskDetailSheet` and the other
            // popups.
            header

            // Body on a solid surface that hides the popup-level
            // material in this region. Header alone reads as glass.
            ScrollablePopupContent(maxHeight: scrollMaxHeight) {
                VStack(alignment: .leading, spacing: 14) {
                    if let url = event.meetingURL { meetingRow(url: url) }
                    if let loc = event.location, !loc.isEmpty { locationRow(loc) }
                    // Attendees row: only when there's at
                    // least one OTHER guest beyond the user.
                    if !guestAttendees.isEmpty { attendeesSection }
                    if let alarm = event.alarmOffsets.first { alarmRow(alarm) }
                    if let calName = event.calendarName { calendarRow(calName) }
                    if let notes = event.notes.flatMap(stripGoogleMeetBlock(_:)),
                       !notes.isEmpty { notesSection(notes) }
                    // RSVP only when the user has their own
                    // attendee row (i.e. they're a guest, not
                    // the standalone organizer).
                    if event.attendees.contains(where: { $0.isCurrentUser }) {
                        rsvpSection
                    }
                }
                .padding(.horizontal, 18)
                // 20pt top gap between the material title bar
                // and the first body row, per design tweak.
                .padding(.top, 20)
                .padding(.bottom, 14)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        // Width bumped 360 → 486 (+35%) per design tweak.
        .frame(width: 486)
        .fixedSize(horizontal: false, vertical: true)
        .popupGlass(shape)
        // Lock the scroll height the first time we render so
        // resizing the host window AFTER opening doesn't reflow
        // the popup's interior (notes block, RSVP, etc. would
        // otherwise visibly shift while the user drags the
        // window edge).
        .onAppear {
            if lockedScrollMaxH == nil {
                lockedScrollMaxH = computeScrollMaxH(for: windowSize)
            }
        }
        .onChange(of: event.id) { _, _ in
            lockedScrollMaxH = computeScrollMaxH(for: windowSize)
        }
        .confirmationDialog(
            "Excluir evento?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Excluir", role: .destructive) {
                Task { await appState.deleteEvent(event) }
            }
            Button("Cancelar", role: .cancel) { }
        } message: {
            Text("Esta ação não pode ser desfeita.")
        }
        .sheet(isPresented: $showEditSheet) {
            CreateEventSheet(
                onClose: { showEditSheet = false },
                editing: event
            )
            .environmentObject(appState)
        }
    }

    // MARK: - Header

    private var header: some View {
        // Single row: title block on the leading edge, action
        // icons on the trailing edge, both vertically centred
        // against each other inside the material title bar.
        // Previously the action icons sat above the title in a
        // VStack, which made the title block bottom-anchored
        // against the body — visually the labels read as
        // floating below the material instead of centred in it.
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 14, height: 14)
                .frame(width: 22, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(formattedDateTime)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                actionIcon("pencil",   help: "Editar evento") { showEditSheet = true }
                actionIcon("trash",    help: "Excluir evento") { showDeleteConfirm = true }
                actionIcon("ellipsis", help: "Mais opções")    { /* future overflow */ }
                actionIcon("xmark",    help: "Fechar")          { onClose() }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func actionIcon(_ symbol: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(help)
    }

    // MARK: - RSVP

    /// "Você vai?" buttons — RSVPs round-trip through the
    /// Google Calendar REST API now (EventKit was removed).
    /// Initial state is read straight from the synced event,
    /// so a pre-existing "Sim/Não/Talvez" answer comes through
    /// as the filled pill on first render.
    @ViewBuilder
    private var rsvpSection: some View {
        // Identify "me" via Google's `self: true` flag (parsed
        // into `isCurrentUser`). The previous lookup used
        // `!isOrganizer` and picked the first non-organizer —
        // wrong when the user IS the organizer of an event
        // they created from Apollo, because it then surfaced
        // Jonathan's status as if it were the user's.
        if let myAttendee = event.attendees.first(where: { $0.isCurrentUser }) {
            let myStatus   = myAttendee.status
            let hasAnswer  = myStatus == .accepted || myStatus == .declined || myStatus == .tentative

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .leading)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Você vai?")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        rsvpButton("Sim",    status: .accepted,
                                   isCurrent: hasAnswer && myStatus == .accepted,
                                   email:     myAttendee.email)
                        rsvpButton("Não",    status: .declined,
                                   isCurrent: hasAnswer && myStatus == .declined,
                                   email:     myAttendee.email)
                        rsvpButton("Talvez", status: .tentative,
                                   isCurrent: hasAnswer && myStatus == .tentative,
                                   email:     myAttendee.email)
                    }
                }
                Spacer()
            }
        }
        // When the user is ONLY the organizer (Google omits
        // them from the attendees array in this case), no
        // RSVP is needed — they're not a guest, they own the
        // event. The section just stays hidden.
    }

    /// Default look = no fill, neutral grey outline. Selected look = solid
    /// macOS accent fill, white text, no outline.
    private func rsvpButton(_ label: String,
                            status: CalendarEvent.Attendee.Status,
                            isCurrent: Bool, email: String?) -> some View {
        Button {
            // No click haptic — the trackpad's own click pulse
            // is the natural feedback for the RSVP tap.
            appState.updateRSVP(for: event, attendeeEmail: email, to: status)
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isCurrent ? Color.white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(
                    isCurrent ? AnyShapeStyle(Color.accentColor)
                              : AnyShapeStyle(Color.clear),
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(
                        isCurrent ? Color.clear
                                  : Color.secondary.opacity(0.40),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private var formattedDateTime: String {
        let cal = Calendar.current
        if event.isAllDay {
            return event.startDate.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
        let day = event.startDate.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let s   = event.startDate.formatted(date: .omitted, time: .shortened)
        let e   = event.endDate.formatted(date: .omitted, time: .shortened)
        if cal.isDate(event.startDate, inSameDayAs: event.endDate) {
            return "\(day) · \(s) – \(e)"
        }
        return "\(day) \(s) → \(event.endDate.formatted(.dateTime.day().month(.wide)) ) \(e)"
    }

    // MARK: - Rows

    private func meetingRow(url: URL) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "video.fill")
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                Link(destination: url) {
                    HStack(spacing: 6) {
                        Image(systemName: "video.fill")
                            .font(.caption)
                        Text(meetingProvider(url))
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.blue, in: Capsule())
                    .liquidGlassEdge(Capsule())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()

                Text(url.host ?? url.absoluteString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .help("Copiar link")
            .padding(.top, 9)
        }
    }

    private func meetingProvider(_ url: URL) -> String {
        let s = url.absoluteString
        if s.contains("meet.google.com")     { return "Entrar com o Google Meet" }
        if s.contains("zoom.us")             { return "Entrar no Zoom" }
        if s.contains("teams.")              { return "Entrar no Microsoft Teams" }
        if s.contains("webex.com")           { return "Entrar no Webex" }
        return "Entrar na chamada"
    }

    private func locationRow(_ location: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
            Text(location)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    /// Other attendees, excluding the user themselves. Apollo
    /// surfaces "you" in the dedicated RSVP section above, so
    /// listing them again as a guest below would be redundant
    /// (and was misleading: when only Jonathan was invited,
    /// the previous code rendered him as "the user" via the
    /// `!isOrganizer` lookup — see `rsvpSection`).
    private var guestAttendees: [CalendarEvent.Attendee] {
        event.attendees.filter { !$0.isCurrentUser }
    }

    private var attendeesSection: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.2.fill")
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                let count = guestAttendees.count
                let counts = attendeeCounts
                Text("\(count) convidado\(count == 1 ? "" : "s")")
                    .font(.callout.weight(.medium))
                if !counts.isEmpty {
                    Text(counts)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(guestAttendees, id: \.email) { a in
                    attendeeRow(a)
                }
            }
            Spacer()
        }
    }

    private var attendeeCounts: String {
        let g = Dictionary(grouping: guestAttendees, by: \.status)
        var parts: [String] = []
        if let n = g[.accepted]?.count, n > 0 { parts.append("\(n): sim") }
        if let n = g[.declined]?.count, n > 0 { parts.append("\(n): não") }
        if let n = g[.tentative]?.count, n > 0 { parts.append("\(n): talvez") }
        if let n = g[.pending]?.count, n > 0 { parts.append("\(n): pendente") }
        return parts.joined(separator: " · ")
    }

    private func attendeeRow(_ a: CalendarEvent.Attendee) -> some View {
        HStack(spacing: 8) {
            Text(initials(for: a.name))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(avatarColor(for: a.name)))
                .overlay(
                    statusBadge(a.status)
                        .offset(x: 8, y: 7)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(a.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                if a.isOrganizer {
                    Text("Organizador")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: CalendarEvent.Attendee.Status) -> some View {
        switch status {
        case .accepted:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.green)
                .background(Circle().fill(.background).frame(width: 9, height: 9))
        case .declined:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.red)
                .background(Circle().fill(.background).frame(width: 9, height: 9))
        case .tentative:
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .background(Circle().fill(.background).frame(width: 9, height: 9))
        default:
            EmptyView()
        }
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ")
        let first = parts.first?.first.map(String.init) ?? ""
        let last  = parts.dropFirst().last?.first.map(String.init) ?? ""
        return (first + last).uppercased()
    }

    private func avatarColor(for name: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo]
        let index = abs(name.hashValue) % palette.count
        return palette[index]
    }

    private func alarmRow(_ offset: TimeInterval) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bell.fill")
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
            Text(alarmText(offset))
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    private func alarmText(_ offset: TimeInterval) -> String {
        let mins = Int(abs(offset) / 60)
        if mins == 0 { return "No início do evento" }
        if mins < 60 { return "\(mins) minutos antes" }
        let hours = mins / 60
        if hours < 24 { return "\(hours) hora\(hours == 1 ? "" : "s") antes" }
        let days = hours / 24
        return "\(days) dia\(days == 1 ? "" : "s") antes"
    }

    private func calendarRow(_ name: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "calendar")
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
            Text(name)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    /// Removes the auto-generated Google-Meet block that Calendar appends
    /// to notes — it sits between two `-:::~:::-`-style separator lines and
    /// duplicates the meeting link/phone we already render at the top.
    private func stripGoogleMeetBlock(_ notes: String) -> String {
        let lines        = notes.components(separatedBy: "\n")
        let boundary     = try? NSRegularExpression(pattern: #"^\s*-[:~\-]{2,}-\s*$"#)
        var result:      [String] = []
        var insideBlock  = false

        for line in lines {
            let range     = NSRange(line.startIndex..., in: line)
            let isBoundary = boundary?.firstMatch(in: line, options: [], range: range) != nil
            if isBoundary {
                insideBlock.toggle()
                continue
            }
            if !insideBlock { result.append(line) }
        }

        return result.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func notesSection(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().opacity(0.5)
            // `linkified` converts raw URLs in the notes into real
            // `link` attributes on an AttributedString. SwiftUI's
            // `Text` renders those clickable, opening them in the
            // user's default browser. Markdown-formatted links
            // ([label](url)) are still parsed too — the data
            // detector matches both shapes.
            Text(notes.linkified)
                .font(.caption)
                .foregroundStyle(.primary)
                .tint(.blue)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

