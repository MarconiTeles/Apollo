import SwiftUI

// Editorial event-detail popup — SwiftUI port of the prototype
// `PEventDetail`: paper card, Folio kicker, serif-26 title +
// italic date Caption, a full-width ink "Entrar com o Google
// Meet" button, and `PMarg`-style marginalia rows. All real
// behaviour (RSVP round-trip, edit sheet, delete, copy link,
// links) is preserved verbatim.

struct EventDetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.windowSize) private var windowSize
    let event: CalendarEvent
    var onClose: () -> Void = {}

    @State private var showDeleteConfirm = false
    /// Drives the in-app edit sheet (re-using `CreateEventSheet`
    /// in editing mode).
    @State private var showEditSheet     = false

    /// Frozen scroll-body height — captured the first time this
    /// view appears for a given event so host-window resizes
    /// don't reflow the interior.
    @State private var lockedScrollMaxH: CGFloat? = nil

    /// Drives the in-content settle: header + body sections rise
    /// and fade into place on appear (the overlay owns the
    /// scale-in; this is the second, calmer beat layered on top).
    @State private var entered = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One spring, tuned to the rest of the redesign.
    private var settle: Animation {
        reduceMotion ? .easeOut(duration: 0.18)
                     : .spring(response: 0.40, dampingFraction: 0.86)
    }

    /// Staggered rise for a body block at `slot` (0,1,2…).
    private func reveal<V: View>(_ slot: Int, _ v: V) -> some View {
        v
            .opacity(entered ? 1 : 0)
            .offset(y: (entered || reduceMotion) ? 0 : 10)
            .animation(reduceMotion ? .easeOut(duration: 0.16)
                                    : .spring(response: 0.42,
                                              dampingFraction: 0.88)
                                        .delay(Double(slot) * 0.045),
                       value: entered)
    }

    private var color: Color { Color(googleSnapHex: event.colorHex) }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Editorial.popupRadius(4.5), style: .continuous)
    }

    private var headerShape: UnevenRoundedRectangle {
        let radius = Editorial.popupRadius(4.5)
        return UnevenRoundedRectangle(topLeadingRadius: radius,
                                      bottomLeadingRadius: 0,
                                      bottomTrailingRadius: 0,
                                      topTrailingRadius: radius,
                                      style: .continuous)
    }

    private let headerHeight: CGFloat = 126

    private func computeScrollMaxH(for window: CGSize) -> CGFloat {
        let h = window.height
        guard h > 0 else { return 540 }
        let chrome: CGFloat = 110
        let preferred = max(300, h * 0.945 - chrome)
        let safeMax   = max(0,   h - 128 - chrome)
        return min(preferred, safeMax)
    }

    private var scrollMaxHeight: CGFloat {
        lockedScrollMaxH ?? computeScrollMaxH(for: windowSize)
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            ScrollablePopupContent(maxHeight: scrollMaxHeight,
                                   clipDisabled: true) {
                VStack(alignment: .leading, spacing: 0) {
                    // Resting content begins below the header; when scrolled,
                    // this spacer leaves and real content travels under glass.
                    Color.clear.frame(height: headerHeight)
                    if let url = event.meetingURL {
                        reveal(0,
                               meetingButton(url: url)
                                .padding(.bottom, 4))
                    }

                    reveal(1, VStack(alignment: .leading, spacing: 0) {
                        if let loc = event.location, !loc.isEmpty {
                            eventMarg("Local") {
                                Text(loc)
                                    .font(Editorial.serif(14))
                                    .foregroundStyle(Editorial.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if !guestAttendees.isEmpty { attendeesRow }
                        if let alarm = event.alarmOffsets.first {
                            eventMarg("Lembrete") {
                                Text(alarmText(alarm))
                                    .font(Editorial.serif(14))
                                    .foregroundStyle(Editorial.ink)
                            }
                        }
                        if let calName = event.calendarName {
                            eventMarg("Calendário") {
                                HStack(spacing: 7) {
                                    Circle().fill(color.editorialMuted)
                                        .frame(width: 7, height: 7)
                                    Text(calName)
                                        .font(Editorial.serif(14))
                                        .foregroundStyle(Editorial.ink)
                                }
                            }
                        }
                        if event.attendees.contains(where: { $0.isCurrentUser }) {
                            rsvpRow
                        }
                    }
                    .padding(.top, 18))

                    if let notes = event.notes.flatMap(stripGoogleMeetBlock(_:)),
                       !notes.isEmpty {
                        reveal(2,
                               notesSection(notes)
                                .padding(.top, 20))
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }

            header
                .frame(minHeight: headerHeight, alignment: .top)
                .opacity(entered ? 1 : 0)
                .offset(y: (entered || reduceMotion) ? 0 : 6)
                .animation(settle, value: entered)
                .liquidGlass(in: headerShape,
                             tint: Editorial.ink,
                             tintOpacity: 0.01,
                             interactive: false)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Editorial.rule).frame(height: 1)
                }
                .zIndex(20)
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .solidPopupSurface(in: shape)
        .onAppear {
            if lockedScrollMaxH == nil {
                lockedScrollMaxH = computeScrollMaxH(for: windowSize)
            }
            // Second beat: let the overlay's scale-in seat, then
            // settle the content.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                entered = true
            }
        }
        .onChange(of: event.id) { _, _ in
            lockedScrollMaxH = computeScrollMaxH(for: windowSize)
            // Re-play the settle when navigating to another event.
            entered = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                entered = true
            }
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

    // MARK: - Header (prototype: Folio · serif title · Caption)

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Circle().fill(color.editorialMuted)
                        .frame(width: 6, height: 6)
                    Folio("Evento · \(statusKicker)")
                }
                Text(event.title)
                    .font(Editorial.serif(26))
                    .foregroundStyle(Editorial.ink)
                    .tracking(-0.5)
                    .fixedSize(horizontal: false, vertical: true)
                Caption(formattedDateTime, size: 13)
            }

            Spacer(minLength: 12)

            HStack(spacing: 4) {
                actionIcon("pencil",          size: 14, help: "Editar evento") { showEditSheet = true }
                actionIcon("arrow.2.squarepath", size: 13, help: "Transformar em tarefa") {
                    // Hand off cleanly: stash the target event,
                    // dismiss the detail overlay so the convert
                    // sheet rises on its own.
                    appState.pendingConversion = event
                    appState.detailEvent       = nil
                }
                actionIcon("trash",           size: 14, help: "Excluir evento") { showDeleteConfirm = true }
                actionIcon("xmark",           size: 15, help: "Fechar")          { onClose() }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    /// Real status kicker — the user's own RSVP when they're a
    /// guest, "confirmado" when they own/attend it.
    private var statusKicker: String {
        if let me = event.attendees.first(where: { $0.isCurrentUser }) {
            switch me.status {
            case .accepted:  return "confirmado"
            case .declined:  return "recusado"
            case .tentative: return "talvez"
            default:         return "pendente"
            }
        }
        return "confirmado"
    }

    private func actionIcon(_ symbol: String, size: CGFloat, help: String,
                            action: @escaping () -> Void) -> some View {
        EventActionIcon(symbol: symbol, size: size,
                        accent: symbol == "trash",
                        action: action)
            .help(help)
    }

    // MARK: - Marginalia row (prototype `PMarg`)

    private func eventMarg<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label.uppercased())
                .font(Editorial.sans(10.5, .semibold))
                .tracking(1.1)
                .foregroundStyle(Editorial.inkMute)
                .frame(width: 100, alignment: .leading)
                .padding(.top, 2)
            content()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Editorial.ruleSoft).frame(height: 1)
        }
    }

    // MARK: - Meeting button (prototype: full-width ink CTA)

    private func meetingButton(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MeetingCTA(label: meetingProvider(url),
                       reduceMotion: reduceMotion) {
                NSWorkspace.shared.open(url)
            }

            HStack(spacing: 8) {
                Text(url.host ?? url.absoluteString)
                    .font(Editorial.sans(11))
                    .foregroundStyle(Editorial.inkMute)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                        Text("Copiar link")
                            .font(Editorial.sans(11, .medium))
                    }
                    .foregroundStyle(Editorial.accent)
                }
                .buttonStyle(.plain).focusEffectDisabled()
                .help("Copiar link")
            }
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

    // MARK: - Attendees

    /// Other attendees, excluding the user themselves (the user's
    /// own row lives in the RSVP block).
    private var guestAttendees: [CalendarEvent.Attendee] {
        event.attendees.filter { !$0.isCurrentUser }
    }

    private var attendeesRow: some View {
        eventMarg("Convidados") {
            VStack(alignment: .leading, spacing: 8) {
                let count = guestAttendees.count
                Text("\(count) pessoa\(count == 1 ? "" : "s")")
                    .font(Editorial.serif(14))
                    .foregroundStyle(Editorial.ink)
                let counts = attendeeCounts
                if !counts.isEmpty {
                    Caption(counts, size: 12)
                }
                ForEach(guestAttendees, id: \.email) { a in
                    attendeeRow(a)
                }
            }
        }
    }

    private var attendeeCounts: String {
        let g = Dictionary(grouping: guestAttendees, by: \.status)
        var parts: [String] = []
        if let n = g[.accepted]?.count,  n > 0 { parts.append("\(n) sim") }
        if let n = g[.declined]?.count,  n > 0 { parts.append("\(n) não") }
        if let n = g[.tentative]?.count, n > 0 { parts.append("\(n) talvez") }
        if let n = g[.pending]?.count,   n > 0 { parts.append("\(n) pendente") }
        return parts.joined(separator: " · ")
    }

    private func attendeeRow(_ a: CalendarEvent.Attendee) -> some View {
        HStack(spacing: 8) {
            Text(initials(for: a.name))
                .font(Editorial.sans(8, .bold))
                .foregroundStyle(Editorial.page)
                .frame(width: 22, height: 22)
                .background(Circle().fill(avatarColor(for: a.name).editorialMuted))
                .overlay(statusBadge(a.status).offset(x: 8, y: 7))

            VStack(alignment: .leading, spacing: 1) {
                Text(a.name)
                    .font(Editorial.sans(12, .medium))
                    .foregroundStyle(Editorial.ink)
                if a.isOrganizer {
                    Text("Organizador")
                        .font(Editorial.sans(10.5))
                        .foregroundStyle(Editorial.inkMute)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: CalendarEvent.Attendee.Status) -> some View {
        // Crisp ring: a popup-coloured disc punches a clean hole
        // out of the avatar, the tone glyph sits centred on top.
        let spec: (String, Color)? = {
            switch status {
            case .accepted:  return ("checkmark.circle.fill", Color(hex: "#3F6B4A"))
            case .declined:  return ("xmark.circle.fill",      Editorial.accent)
            case .tentative: return ("questionmark.circle.fill", Color(hex: "#9A7B1F"))
            default:         return nil
            }
        }()
        if let (glyph, tone) = spec {
            ZStack {
                Circle().fill(Editorial.popup).frame(width: 12, height: 12)
                Image(systemName: glyph)
                    .font(.system(size: 10))
                    .foregroundStyle(tone)
            }
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

    // MARK: - RSVP

    @ViewBuilder
    private var rsvpRow: some View {
        if let myAttendee = event.attendees.first(where: { $0.isCurrentUser }) {
            let myStatus  = myAttendee.status
            let hasAnswer = myStatus == .accepted || myStatus == .declined || myStatus == .tentative
            eventMarg("Você vai?") {
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
        }
    }

    private func rsvpButton(_ label: String,
                            status: CalendarEvent.Attendee.Status,
                            isCurrent: Bool, email: String?) -> some View {
        Button {
            appState.updateRSVP(for: event, attendeeEmail: email, to: status)
        } label: {
            Text(label)
                .font(Editorial.sans(12, .medium))
                .foregroundStyle(isCurrent ? Editorial.page : Editorial.ink)
                .padding(.horizontal, 13)
                .padding(.vertical, 5)
                // Liquid Glass pill — ink-tinted when selected, neutral
                // page glass at rest.
                .liquidGlassCapsule(tint: isCurrent ? Editorial.ink : Editorial.page,
                                    tintOpacity: isCurrent ? 0.85 : 0.55)
                .overlay(
                    Capsule().strokeBorder(
                        isCurrent ? Color.clear : Editorial.rule,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .glassHover()
        .animation(settle, value: isCurrent)
    }

    // MARK: - Notes

    private func notesSection(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Folio("Anotações")
            Text(notes.linkified)
                .font(Editorial.serif(13.5))
                .foregroundStyle(Editorial.ink)
                .tint(Editorial.accent)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Formatting

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
        return "\(day) \(s) → \(event.endDate.formatted(.dateTime.day().month(.wide))) \(e)"
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

    /// Removes the auto-generated Google-Meet block that Calendar
    /// appends to notes — it sits between two `-:::~:::-`-style
    /// separator lines and duplicates the meeting link we already
    /// render at the top.
    private func stripGoogleMeetBlock(_ notes: String) -> String {
        let lines        = notes.components(separatedBy: "\n")
        let boundary     = try? NSRegularExpression(pattern: #"^\s*-[:~\-]{2,}-\s*$"#)
        var result:      [String] = []
        var insideBlock  = false

        for line in lines {
            let range      = NSRange(line.startIndex..., in: line)
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
}

// MARK: - Header action icon (hover wash)

/// Bare editorial glyph button that grows a soft rounded wash on
/// hover and darkens its ink — `trash` reads cinnabar on hover so
/// the destructive action telegraphs itself.
private struct EventActionIcon: View {
    let symbol: String
    let size: CGFloat
    var accent: Bool = false
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(
                    hover ? (accent ? Editorial.accent : Editorial.ink)
                          : Editorial.inkSoft
                )
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hover
                              ? (accent ? Editorial.accent.opacity(0.10)
                                        : Editorial.ink.opacity(0.06))
                              : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .scrollAwareOnHover { hover = $0 }
        .animation(.easeOut(duration: 0.13), value: hover)
    }
}

// MARK: - Meeting CTA (ink button, hover lift + press)

/// Full-width ink call-to-action. Lifts subtly on hover (a
/// faint shadow + 1pt rise) and presses in on tap. Reduce Motion
/// keeps it perfectly still — only the colour cue remains.
private struct MeetingCTA: View {
    let label: String
    let reduceMotion: Bool
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "video.fill")
                    .font(.system(size: 13))
                Text(label)
                    .font(Editorial.sans(13, .semibold))
            }
            .foregroundStyle(Editorial.page)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Editorial.ink.opacity(hover ? 0.92 : 1))
            )
        }
        .buttonStyle(MeetingCTAStyle(reduceMotion: reduceMotion))
        .focusEffectDisabled()
        .offset(y: (hover && !reduceMotion) ? -1 : 0)
        .shadow(color: .black.opacity(hover && !reduceMotion ? 0.18 : 0),
                radius: 10, x: 0, y: 4)
        .scrollAwareOnHover { hover = $0 }
        .animation(.easeOut(duration: 0.16), value: hover)
    }

    private struct MeetingCTAStyle: ButtonStyle {
        let reduceMotion: Bool
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(
                    (configuration.isPressed && !reduceMotion) ? 0.98 : 1,
                    anchor: .center
                )
                .opacity(configuration.isPressed ? 0.92 : 1)
                .animation(.easeOut(duration: 0.12),
                           value: configuration.isPressed)
        }
    }
}

// MARK: - Convert event → task sheet

/// Small editorial sheet shown when the user clicks
/// "Transformar em tarefa" on an event. Collects the three
/// decisions that matter for the new ClickUp task —
/// **status**, **responsável** and whether to **keep the
/// original event** — then dispatches to
/// `AppState.convertEventToTask`. Default keeps the event
/// (the user opts in to deletion via the toggle).
struct ConvertEventToTaskSheet: View {
    let event: CalendarEvent
    @EnvironmentObject var appState: AppState
    let onClose: () -> Void
    /// Called only when the conversion succeeded — the caller
    /// closes the EventDetail overlay after the task lands.
    let onDone:  () -> Void

    /// Default: keep the event (ON). The user explicitly opts
    /// OUT (toggle OFF) if they want the event removed from the
    /// calendar. Phrased positively so the active state and the
    /// label ("Manter evento") agree at a glance.
    @State private var keepOriginal: Bool = true
    @State private var selectedStatus: String? = nil
    @State private var assigneeQuery:  String = ""
    /// Multi-select — any number of ClickUp members can be
    /// assigned to the new task at once.
    @State private var selectedAssignees: [CUMember] = []
    @FocusState private var assigneeFocused: Bool
    @State private var isCreating: Bool = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Editorial.popupRadius(4.5), style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassFormHeader(title: "Transformar em tarefa",
                            onClose: onClose)

            VStack(alignment: .leading, spacing: 0) {
                statusDetailRow
                assigneeDetailRow
                if showAssigneeSuggestions {
                    assigneeSuggestionsList
                        .transition(.asymmetric(
                            insertion: .opacity
                                .combined(with: .scale(scale: 0.96,
                                                       anchor: .top))
                                .combined(with: .offset(y: -6)),
                            removal:   .opacity
                                .combined(with: .scale(scale: 0.96,
                                                       anchor: .top))
                                .combined(with: .offset(y: -6))
                        ))
                }
                deleteDetailRow
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .animation(.spring(response: 0.32, dampingFraction: 0.82),
                       value: showAssigneeSuggestions)
            .animation(.spring(response: 0.32, dampingFraction: 0.82),
                       value: filteredMembers.map(\.id))

            GlassFormFooter(
                onCancel:       onClose,
                onCreate:       submit,
                createLabel:    isCreating ? "Criando…" : "Criar tarefa",
                createDisabled: isCreating
            )
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            Color.clear
                .contentShape(shape)
                .onTapGesture { assigneeFocused = false }
        }
        .popupGlass(in: shape)
    }

    // MARK: - Submit

    private func submit() {
        isCreating = true
        Task {
            let task = await appState.convertEventToTask(
                event,
                deleteOriginal: !keepOriginal,
                status:         selectedStatus,
                assigneeIds:    selectedAssignees.map(\.id)
            )
            isCreating = false
            if task != nil { onDone() } else { onClose() }
        }
    }

    // MARK: - Detail rows (canonical editorial `PMarg` pattern)

    @ViewBuilder
    private func detailRow<Content: View>(
        label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label.uppercased())
                .font(Editorial.sans(10.5, .semibold))
                .tracking(1.1)
                .foregroundStyle(Editorial.inkMute)
                .frame(width: 100, alignment: .leading)
                .padding(.top, 2)
            content()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Editorial.ruleSoft).frame(height: 1)
        }
    }

    // MARK: - Status

    private var statusDetailRow: some View {
        detailRow(label: "Status") { statusMenu }
    }

    private var statusMenu: some View {
        Menu {
            Button("Padrão da lista") { selectedStatus = nil }
            ForEach(appState.availableStatuses, id: \.id) { s in
                Button(s.status.capitalized) { selectedStatus = s.status }
            }
        } label: {
            HStack(spacing: 6) {
                if let hex = currentStatusHex {
                    Circle().fill(Color(hex: hex))
                        .frame(width: 8, height: 8)
                }
                Text(selectedStatus?.capitalized ?? "Padrão da lista")
                    .font(Editorial.sans(13, .medium))
                    .foregroundStyle(Editorial.ink)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Editorial.inkFaint)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var currentStatusHex: String? {
        guard let s = selectedStatus else { return nil }
        return appState.availableStatuses
            .first { $0.status.lowercased() == s.lowercased() }?
            .displayHex
    }

    // MARK: - Assignee (interactive search)

    private var assigneeDetailRow: some View {
        detailRow(label: "Responsável") {
            HStack(spacing: 6) {
                ForEach(selectedAssignees) { m in
                    assigneeChip(m)
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Editorial.inkFaint)
                    TextField(selectedAssignees.isEmpty
                              ? "Buscar pessoa…"
                              : "Adicionar outro…",
                              text: $assigneeQuery)
                        .textFieldStyle(.plain)
                        .font(Editorial.sans(13))
                        .foregroundStyle(Editorial.ink)
                        .focused($assigneeFocused)
                        .frame(minWidth: 100)
                }
            }
            .animation(.spring(response: 0.30, dampingFraction: 0.82),
                       value: selectedAssignees.map(\.id))
        }
    }

    @ViewBuilder
    private func assigneeChip(_ m: CUMember) -> some View {
        HStack(spacing: 6) {
            memberAvatar(m).frame(width: 16, height: 16)
            Text(m.username)
                .font(Editorial.sans(12, .medium))
                .foregroundStyle(Editorial.ink)
                .lineLimit(1)
            Button {
                selectedAssignees.removeAll { $0.id == m.id }
                assigneeFocused = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Editorial.inkFaint)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Editorial.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Editorial.rule, lineWidth: 0.5)
        )
    }

    private var showAssigneeSuggestions: Bool {
        let q = assigneeQuery.trimmingCharacters(in: .whitespaces)
        return assigneeFocused
            && !q.isEmpty
            && !filteredMembers.isEmpty
    }

    /// Capped at 3 results so the dropdown never overwhelms the
    /// dialog. Members already picked are filtered out so the
    /// list always offers something new.
    private var filteredMembers: [CUMember] {
        let q = assigneeQuery
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        let picked = Set(selectedAssignees.map(\.id))
        let pool   = appState.availableMembers.filter { !picked.contains($0.id) }
        let matched: [CUMember]
        if q.isEmpty {
            matched = pool
        } else {
            matched = pool.filter {
                $0.username.lowercased().contains(q)
                    || ($0.email ?? "").lowercased().contains(q)
            }
        }
        return Array(matched.prefix(3))
    }

    // Mirrors the editorial guest-picker list in CreateEventSheet:
    // page surface, hairline border, muted avatar disc, ink names,
    // ruleSoft separators — no shadow.
    private var assigneeSuggestionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(filteredMembers) { m in
                Button {
                    selectedAssignees.append(m)
                    assigneeQuery   = ""
                    // Keep focus so the user can chain another pick.
                    assigneeFocused = true
                } label: {
                    HStack(spacing: 8) {
                        memberAvatar(m).frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.username)
                                .font(Editorial.sans(12, .medium))
                                .foregroundStyle(Editorial.ink)
                                .lineLimit(1)
                            if let mail = m.email, !mail.isEmpty {
                                Text(mail)
                                    .font(Editorial.sans(11))
                                    .foregroundStyle(Editorial.inkSoft)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                if m.id != filteredMembers.last?.id {
                    Rectangle().fill(Editorial.ruleSoft).frame(height: 1)
                }
            }
        }
        // Indent aligns with the content column of `detailRow`
        // (label 100 + spacing 12 = 112pt).
        .padding(.leading, 112)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Editorial.page)
                .padding(.leading, 112),
            alignment: .leading
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Editorial.rule, lineWidth: 0.5)
                .padding(.leading, 112),
            alignment: .leading
        )
        .padding(.top, 4)
    }

    @ViewBuilder
    private func memberAvatar(_ m: CUMember) -> some View {
        ZStack {
            Circle().fill(memberColor(m))
            Text(memberInitials(m))
                .font(Editorial.sans(8, .bold))
                .foregroundStyle(Editorial.page)
        }
    }

    private func memberColor(_ m: CUMember) -> Color {
        if let hex = m.color, !hex.isEmpty {
            return Color(hex: hex).editorialMuted
        }
        return Editorial.inkSoft.editorialMuted
    }

    private func memberInitials(_ m: CUMember) -> String {
        if let initials = m.initials,
           !initials.isEmpty { return initials.uppercased() }
        let source = m.username.isEmpty ? (m.email ?? "?") : m.username
        let parts = source
            .split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" })
            .prefix(2)
        return parts.compactMap { $0.first }
            .map(String.init)
            .joined()
            .uppercased()
    }

    // MARK: - Keep-event toggle (editorial switch)

    private var deleteDetailRow: some View {
        detailRow(label: "Manter evento") {
            Button { keepOriginal.toggle() } label: {
                HStack(spacing: 10) {
                    editorialSwitch
                    Text(keepOriginal ? "Sim, manter no calendário"
                                      : "Remover do calendário")
                        .font(Editorial.sans(12.5, .medium))
                        .foregroundStyle(Editorial.ink)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
    }

    /// Small editorial switch — capsule track + circular knob,
    /// ink-on / paper-off, springs cleanly between states.
    private var editorialSwitch: some View {
        let trackW: CGFloat = 32
        let trackH: CGFloat = 18
        let knob:   CGFloat = 14
        return ZStack(alignment: keepOriginal ? .trailing : .leading) {
            Capsule()
                .fill(keepOriginal ? Editorial.ink : Editorial.page)
            Capsule()
                .strokeBorder(keepOriginal ? Editorial.ink
                                           : Editorial.rule,
                              lineWidth: 1)
            Circle()
                .fill(keepOriginal ? Editorial.page : Editorial.ink)
                .frame(width: knob, height: knob)
                .padding(2)
        }
        .frame(width: trackW, height: trackH)
        .animation(.spring(response: 0.26, dampingFraction: 0.78),
                   value: keepOriginal)
    }
}
