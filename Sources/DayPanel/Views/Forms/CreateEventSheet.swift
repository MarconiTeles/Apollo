import SwiftUI
import AppKit
// EventKit import removed when Apollo migrated to
// Google-only calendar. The picker below is now a one-row
// stub that always points at the user's primary Google
// Calendar.

struct CreateEventSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.windowSize) private var windowSize
    var onClose: () -> Void = {}

    /// When non-nil the sheet opens in EDIT mode — fields are
    /// pre-populated from this event and the submit button
    /// patches the event via Google API instead of creating
    /// a new one. The existing onClose callback fires after a
    /// successful save.
    var editing: CalendarEvent? = nil

    private var isEditing: Bool { editing != nil }

    /// Reserves ~140pt for the header + footer so the whole popup never
    /// exceeds 70% of the host window's height — AND never overlaps
    /// the toolbar at the top of the window after centering.
    private var scrollMaxHeight: CGFloat {
        let h = windowSize.height
        guard h > 0 else { return 420 }
        let chrome: CGFloat = 140
        let preferred = max(220, h * 0.70 - chrome)
        let safeMax   = max(0,   h - 128 - chrome)
        return min(preferred, safeMax)
    }

    @State private var title       = ""
    @State private var startDate   = roundedHour(Date())
    @State private var endDate     = roundedHour(Date()).addingTimeInterval(3600)
    @State private var guests      = ""
    @State private var meetURL     = ""
    @State private var location    = ""
    @State private var notes       = ""
    @State private var calendarId: String?  = nil
    @State private var availabilityBusy     = true
    @State private var alarmMinutes: Int    = 10
    /// Google's `colorId` (1–11). `nil` keeps the default
    /// (calendar's own colour). The 11 named colours are
    /// the same set Google Calendar surfaces in its event
    /// creation UI — see `CalendarEvent.googleColorMap`.
    @State private var colorId: String?     = nil
    /// Drives the colour picker popover anchored to the
    /// "Cor" row. Custom popover instead of `Menu` so we
    /// can lay out the swatches in Google's 6×2 grid with
    /// real circles rather than the monochrome SF Symbols
    /// that NSMenu would render.
    @State private var showColorPicker      = false
    @State private var creating  = false
    @State private var error: String?

    @State private var showStartPicker = false
    @State private var showEndPicker   = false
    @FocusState private var titleFocused:       Bool
    @FocusState private var descriptionFocused: Bool
    @FocusState private var guestsFocused:      Bool

    /// Live results from `ContactsService` for the email fragment the
    /// user is currently typing (the substring after the last comma).
    @State private var guestSuggestions: [GuestSuggestion] = []
    @State private var showGuestSuggestions = false

    private let alarmOptions: [(Int, String)] = [
        (-1, "Sem notificação"),
        (0,  "No início"),
        (5,  "5 minutos antes"),
        (10, "10 minutos antes"),
        (15, "15 minutos antes"),
        (30, "30 minutos antes"),
        (60, "1 hora antes"),
        (24 * 60, "1 dia antes"),
    ]

    /// With Google as the single calendar backend, there's
    /// only ever one option here — the user's primary Google
    /// Calendar. The picker UI is kept (collapsed to one row)
    /// to preserve layout; could be hidden entirely later.
    private var availableCalendars: [GCalendar] {
        [GCalendar(id: "primary", name: "Google Calendar", colorHex: "#039BE5")]
    }

    private var selectedCalendar: GCalendar? {
        availableCalendars.first(where: { $0.id == calendarId }) ?? availableCalendars.first
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassFormHeader(title: isEditing ? "Editar Evento" : "Novo Evento",
                            onClose: onClose)

            // Body + footer on a single solid surface — header
            // alone gets the popup-level material translucency.
            VStack(spacing: 0) {
                ScrollablePopupContent(maxHeight: scrollMaxHeight) {
                    VStack(alignment: .leading, spacing: 12) {
                        titleHero
                        descriptionField

                        // Subtle separator before the metadata grid — same
                        // visual rhythm used in the inline EventDetailView
                        // and the redesigned Nova Tarefa popup.
                        Rectangle()
                            .fill(.separator.opacity(0.4))
                            .frame(height: 0.5)
                            .padding(.horizontal, -12)
                            .padding(.top, 2)

                        // Detail rows mirroring the task / event detail
                        // patterns: [icon] [110pt label] [content].
                        VStack(alignment: .leading, spacing: 10) {
                            datesDetailRow
                            guestsDetailRow
                            // Inline suggestion list — placed in the same
                            // VStack instead of a `.popover(...)` so the
                            // TextField above retains keyboard focus
                            // while the user types (popovers spawn a
                            // separate NSWindow that steals key status).
                            if showGuestSuggestions {
                                guestSuggestionsList
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .offset(y: -6)),
                                        removal:   .opacity.combined(with: .offset(y: -6))
                                    ))
                            }
                            conferenceDetailRow
                            locationDetailRow
                            calendarDetailRow
                            colorDetailRow
                            reminderDetailRow
                            availabilityDetailRow
                        }
                        .animation(.easeInOut(duration: 0.18), value: showGuestSuggestions)

                        if let error {
                            GlassWarningRow(error, tint: .red)
                        }
                        // Connection gate: Google is the only
                        // calendar backend now (EventKit removed).
                        if !appState.googleAuth.isConnected {
                            GlassWarningRow("Conecte sua conta Google em Configurações pra criar eventos.")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }

                GlassFormFooter(
                    onCancel: onClose,
                    onCreate: submit,
                    createLabel: creating
                        ? (isEditing ? "Salvando…" : "Criando…")
                        : (isEditing ? "Salvar alterações" : "Criar Evento"),
                    // Disabled until Google is connected — the
                    // only calendar backend now.
                    createDisabled: title.isEmpty
                        || creating
                        || !appState.googleAuth.isConnected
                )
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .popupGlass(shape)
        .onAppear {
            // EDIT mode: pre-populate every field from the
            // event being edited. Skipped when `editing` is
            // nil (the create flow keeps its blank defaults).
            if let event = editing {
                title       = event.title
                startDate   = event.startDate
                endDate     = event.endDate
                location    = event.location ?? ""
                notes       = event.notes ?? ""
                meetURL     = event.meetingURL?.absoluteString ?? ""
                guests      = event.attendees
                    .filter { !$0.isCurrentUser }
                    .compactMap { $0.email }
                    .joined(separator: ", ")
                calendarId  = event.calendarId
                if let firstAlarm = event.alarmOffsets.first {
                    // Convert negative seconds-before-start
                    // to positive minutes for the alarm picker.
                    alarmMinutes = Int(-firstAlarm / 60)
                }
                // Reverse-lookup the colorId from the event's
                // hex. Only matches when the user previously
                // picked one of Google's 11 standard event
                // colours; calendar-default events stay as
                // `colorId = nil` so the picker shows
                // "Padrão" rather than a wrong match.
                colorId = CalendarEvent.googleColorMap
                    .first(where: { $0.value.lowercased() == event.colorHex.lowercased() })?.key
            } else if calendarId == nil {
                let preferred = appState.selectedCalendarIds.first { $0 != "primary" }
                calendarId = preferred ?? availableCalendars.first?.id
            }
            // Build the suggestion list from the SAME source the
            // event timeline uses: attendees harvested from past
            // events on the user's selected Google Calendar(s). Then
            // warm the macOS-Contacts fallback in the background.
            ContactsService.shared.setEventAttendees(harvestEventAttendees())
            ContactsService.shared.warmUp()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                titleFocused = true
            }
        }
    }

    /// Pulls every unique attendee out of the events AppState already
    /// has loaded (which spans the user's `±30 day` sync window over
    /// the calendars they selected in Settings). One suggestion per
    /// unique email; name is taken from the most recent event the
    /// person appears in. Organisers count too — you might want to
    /// re-invite them.
    private func harvestEventAttendees() -> [GuestSuggestion] {
        var byEmail: [String: GuestSuggestion] = [:]
        // Iterate newest events first so when we keep "first wins",
        // the freshest name for each person sticks.
        let events = appState.events.sorted(by: { $0.startDate > $1.startDate })
        for event in events {
            for a in event.attendees {
                guard let raw = a.email,
                      raw.contains("@") else { continue }
                let key = raw.lowercased()
                if byEmail[key] != nil { continue }
                let name = a.name.isEmpty || a.name == raw ? nil : a.name
                byEmail[key] = GuestSuggestion(name: name, email: raw)
            }
        }
        return Array(byEmail.values)
    }

    // MARK: - Detail-row helper (matches TaskDetailView / CreateTaskSheet)

    private func detailRow<Content: View>(
        icon: String, label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label {
                Text(label).font(.caption).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: icon).font(.caption2).foregroundStyle(.tertiary).frame(width: 14)
            }
            .labelStyle(.titleAndIcon)
            .frame(width: 110, alignment: .leading)

            content()
            Spacer(minLength: 0)
        }
    }

    // MARK: - Detail rows

    private var datesDetailRow: some View {
        detailRow(icon: "clock", label: "Datas") {
            HStack(spacing: 6) {
                dateButton(label: startDate.formatted(.dateTime.day().month(.abbreviated).hour().minute()),
                           color: .primary,
                           show:  $showStartPicker) {
                    EventDatePickerPopover(startDate: $startDate, endDate: $endDate, initialMode: .start)
                }
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                dateButton(label: endDate.formatted(.dateTime.day().month(.abbreviated).hour().minute()),
                           color: .primary,
                           show:  $showEndPicker) {
                    EventDatePickerPopover(startDate: $startDate, endDate: $endDate, initialMode: .end)
                }
            }
        }
    }

    @ViewBuilder
    private func dateButton<Content: View>(
        label: String,
        color: Color,
        show:  Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        Button { show.wrappedValue.toggle() } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
                .lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.secondary.opacity(0.20), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .popover(isPresented: show, arrowEdge: .bottom) { content() }
    }

    private var guestsDetailRow: some View {
        detailRow(icon: "person.2.fill", label: "Convidados") {
            TextField("email1@…, email2@…", text: $guests)
                .textFieldStyle(.plain)
                .font(.caption)
                .foregroundStyle(.primary)
                .focused($guestsFocused)
                .focusEffectDisabled()
                .onChange(of: guests) { _, new in
                    refreshGuestSuggestions(for: new)
                }
                .onChange(of: guestsFocused) { _, focused in
                    // Hide the suggestions when the field loses
                    // focus so they don't linger when the user
                    // tabs/clicks to a different field.
                    if !focused { showGuestSuggestions = false }
                }
        }
    }

    /// Active fragment = whatever the user has typed after the last
    /// "," / ";" / whitespace. Used both to query Contacts and to know
    /// what slice of `guests` to replace when a suggestion is picked.
    private var activeGuestFragment: String {
        let trailing = guests
            .reversed()
            .prefix(while: { ![",", ";", " ", "\n"].contains($0) })
        return String(trailing.reversed())
    }

    private func refreshGuestSuggestions(for text: String) {
        let fragment = activeGuestFragment.trimmingCharacters(in: .whitespaces)
        guard fragment.count >= 2 else {
            guestSuggestions = []
            showGuestSuggestions = false
            return
        }
        Task { @MainActor in
            let hits = await ContactsService.shared.search(query: fragment)
            // Filter out emails already present in the field — no
            // point suggesting people already invited.
            let existing = Set(text
                .split(whereSeparator: { ",;\n ".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            let filtered = hits.filter { !existing.contains($0.email.lowercased()) }
            guestSuggestions     = filtered
            showGuestSuggestions = !filtered.isEmpty && guestsFocused
        }
    }

    private var guestSuggestionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(guestSuggestions) { s in
                Button {
                    pick(suggestion: s)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            if let name = s.name {
                                Text(name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            Text(s.email)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
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
                if s.id != guestSuggestions.last?.id {
                    Rectangle().fill(.separator.opacity(0.3)).frame(height: 0.5)
                }
            }
        }
        // Indented to align with the content column of `detailRow`
        // (icon ~14pt + spacing 10 + label 110 = ~134pt). The
        // suggestion box itself is a small floating card.
        .padding(.leading, 124)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .padding(.leading, 124),
            alignment: .leading
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                .padding(.leading, 124),
            alignment: .leading
        )
    }

    /// Replaces the active fragment with the chosen email and appends
    /// ", " so the user can type the next guest immediately.
    private func pick(suggestion: GuestSuggestion) {
        let frag = activeGuestFragment
        guard let range = guests.range(of: frag, options: .backwards) else {
            guests += suggestion.email + ", "
            showGuestSuggestions = false
            return
        }
        guests.replaceSubrange(range, with: suggestion.email + ", ")
        showGuestSuggestions = false
    }

    private var conferenceDetailRow: some View {
        detailRow(icon: "video.fill", label: "Conferência") {
            if meetURL.isEmpty {
                Menu {
                    Button { scheduleGoogleMeet() } label: {
                        Label("Agendar Google Meet (no horário escolhido)", systemImage: "video.fill")
                    }
                    Button { insertZoomLink() } label: {
                        Label("Reunião instantânea Zoom", systemImage: "video.circle.fill")
                    }
                    Divider()
                    Button { meetURL = " " } label: {
                        Label("Inserir link manualmente…", systemImage: "link")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Adicionar")
                            .font(.caption.weight(.medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.blue)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .focusEffectDisabled()
            } else {
                HStack(spacing: 6) {
                    TextField("Link da videoconferência", text: $meetURL)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(meetURL.contains("://") ? Color.blue : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button { meetURL = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain).focusEffectDisabled()
                    .help("Remover link")
                }
            }
        }
    }

    private var locationDetailRow: some View {
        detailRow(icon: "mappin.circle.fill", label: "Local") {
            TextField("Sala, endereço…", text: $location)
                .textFieldStyle(.plain)
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }

    private var calendarDetailRow: some View {
        detailRow(icon: "calendar", label: "Calendário") {
            Menu {
                ForEach(availableCalendars) { cal in
                    Button { calendarId = cal.id } label: {
                        HStack {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(Color(hex: cal.colorHex))
                            Text(cal.name)
                            if cal.id == calendarId { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    if let c = selectedCalendar {
                        Circle().fill(Color(hex: c.colorHex)).frame(width: 8, height: 8)
                        Text(c.name)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    } else {
                        Text("Selecionar")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .focusEffectDisabled()
        }
    }

    /// Google's 11 event colours laid out in the SAME grid
    /// order Google Calendar's web picker uses (top row →
    /// bottom row, left → right). Hex values match the
    /// Material Design rendering Google Calendar shipped in
    /// 2018+ and still uses today — same shade you see in
    /// the web UI's swatch grid.
    private static let googleEventColors: [(id: String, name: String, hex: String)] = [
        // Top row
        ("11", "Tomate",     "#D50000"),
        ("4",  "Flamingo",   "#E67C73"),
        ("6",  "Tangerina",  "#F4511E"),
        ("5",  "Banana",     "#F6BF26"),
        ("2",  "Sálvia",     "#33B679"),
        ("10", "Manjericão", "#0B8043"),
        // Bottom row
        ("7",  "Pavão",      "#039BE5"),
        ("9",  "Mirtilo",    "#3F51B5"),
        ("1",  "Lavanda",    "#7986CB"),
        ("3",  "Uva",        "#8E24AA"),
        ("8",  "Grafite",    "#616161"),
    ]

    private var colorDetailRow: some View {
        detailRow(icon: "paintpalette.fill", label: "Cor") {
            Button {
                showColorPicker.toggle()
            } label: {
                HStack(spacing: 5) {
                    if let id = colorId,
                       let entry = Self.googleEventColors.first(where: { $0.id == id }) {
                        Circle()
                            .fill(Color(hex: entry.hex))
                            .frame(width: 10, height: 10)
                            .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                        Text(entry.name)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    } else {
                        Text("Padrão")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .popover(isPresented: $showColorPicker, arrowEdge: .top) {
                colorPickerPopover
            }
        }
    }

    /// Popover content: 6×2 grid of colour swatches matching
    /// Google Calendar's web picker, plus a "Padrão" reset
    /// row. Tapping a swatch picks the colour and dismisses
    /// the popover.
    private var colorPickerPopover: some View {
        let cols = Array(repeating: GridItem(.fixed(28), spacing: 10), count: 6)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Cor do evento")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(Self.googleEventColors, id: \.id) { entry in
                    swatchButton(entry: entry)
                }
            }

            Divider().opacity(0.5)

            Button {
                colorId = nil
                showColorPicker = false
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: colorId == nil ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(colorId == nil
                                         ? AnyShapeStyle(Color.accentColor)
                                         : AnyShapeStyle(.tertiary))
                    Text("Padrão (cor do calendário)")
                        .font(.caption)
                        .foregroundStyle(.primary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(14)
        .frame(width: 260)
    }

    private func swatchButton(
        entry: (id: String, name: String, hex: String)
    ) -> some View {
        let isSelected = colorId == entry.id
        return Button {
            colorId = entry.id
            showColorPicker = false
        } label: {
            ZStack {
                Circle()
                    .fill(Color(hex: entry.hex))
                    .frame(width: 26, height: 26)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.20), radius: 0.5, x: 0, y: 0.5)
                }
            }
            .overlay(
                Circle()
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(entry.name)
    }

    private var reminderDetailRow: some View {
        detailRow(icon: "bell.fill", label: "Lembrete") {
            Menu {
                ForEach(alarmOptions, id: \.0) { opt in
                    Button { alarmMinutes = opt.0 } label: {
                        if opt.0 == alarmMinutes {
                            Label(opt.1, systemImage: "checkmark")
                        } else {
                            Text(opt.1)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: alarmMinutes < 0 ? "bell.slash" : "bell.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(currentAlarmLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .focusEffectDisabled()
        }
    }

    private var availabilityDetailRow: some View {
        detailRow(icon: "circle.lefthalf.filled", label: "Disponibilidade") {
            Menu {
                Button { availabilityBusy = true } label: {
                    Label("Ocupado", systemImage: availabilityBusy ? "checkmark" : "")
                }
                Button { availabilityBusy = false } label: {
                    Label("Livre", systemImage: !availabilityBusy ? "checkmark" : "")
                }
            } label: {
                HStack(spacing: 4) {
                    Text(availabilityBusy ? "Ocupado" : "Livre")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .focusEffectDisabled()
        }
    }

    // MARK: - Conference link generator
    //
    // We don't have Google/Zoom OAuth, so we can't mint a real joinable
    // room ID locally. Instead, "Agendar Google Meet" opens Google
    // Calendar's create-event page with the date/time/title/guests
    // already filled in AND `conf=true` so Meet attaches automatically.
    // The user clicks Save in Google → Google creates the event with a
    // real Meet link → on next sync the event appears in our app.

    private func scheduleGoogleMeet() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.timeZone   = .current

        var query: [URLQueryItem] = [
            URLQueryItem(name: "dates", value: "\(formatter.string(from: startDate))/\(formatter.string(from: endDate))"),
            URLQueryItem(name: "conf",  value: "true"),
        ]
        if !title.isEmpty    { query.append(URLQueryItem(name: "text",     value: title)) }
        if !location.isEmpty { query.append(URLQueryItem(name: "location", value: location)) }
        if !notes.isEmpty    { query.append(URLQueryItem(name: "details",  value: notes)) }

        let guestList = guests
            .split(whereSeparator: { ",;\n ".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.contains("@") }
        if !guestList.isEmpty {
            query.append(URLQueryItem(name: "add", value: guestList.joined(separator: ",")))
        }

        var components = URLComponents(string: "https://calendar.google.com/calendar/u/0/r/eventedit")!
        components.queryItems = query

        if let url = components.url {
            NSWorkspace.shared.open(url)
            // Mark the field so the user knows what to expect — the real
            // Meet link will arrive on the next Google Calendar sync.
            meetURL = "Aguardando Google Calendar…"
        }
    }

    /// Fallback for Zoom — Zoom doesn't expose a deep-link to schedule a
    /// meeting at a specific time. Best we can do is start an instant
    /// meeting; the URL still works as a join link for everyone.
    private func insertZoomLink() {
        meetURL = "https://zoom.us/start"
    }

    // MARK: - Title hero

    private var titleHero: some View {
        TextField("", text: $title, prompt: Text("Título do evento")
            .font(.title3.weight(.regular))
            .foregroundColor(.secondary))
            .textFieldStyle(.plain)
            .font(.title3.weight(.semibold))
            .focused($titleFocused)
            .focusEffectDisabled()
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(titleFocused ? Color.accentColor.opacity(0.45) : .white.opacity(0.15),
                                  lineWidth: titleFocused ? 1.0 : 0.5)
            )
            .animation(.easeInOut(duration: 0.15), value: titleFocused)
    }

    // MARK: - Description

    private var descriptionField: some View {
        // Compact when empty/unfocused, grows up to 90pt as the user
        // writes — same shape as CreateTaskSheet's description so the
        // two creation popups feel like siblings.
        let minH: CGFloat = (notes.isEmpty && !descriptionFocused) ? 36 : 60
        let maxH: CGFloat = descriptionFocused ? 140 : 90

        return ZStack(alignment: .topLeading) {
            if notes.isEmpty && !descriptionFocused {
                Text("Descrição (opcional)")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $notes)
                .focused($descriptionFocused)
                .focusEffectDisabled()
                .scrollContentBackground(.hidden)
                .background(TextEditorEnhancements())
                .font(.subheadline)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .frame(minHeight: minH, maxHeight: maxH)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(descriptionFocused ? Color.accentColor.opacity(0.45) : .white.opacity(0.15),
                              lineWidth: descriptionFocused ? 1.0 : 0.5)
        )
        .animation(.easeInOut(duration: 0.18), value: descriptionFocused)
        .animation(.easeInOut(duration: 0.18), value: notes.isEmpty)
    }

    private var currentAlarmLabel: String {
        if alarmMinutes < 0 { return "Sem notificação" }
        if alarmMinutes == 0 { return "No início" }
        if alarmMinutes < 60 { return "\(alarmMinutes) min" }
        if alarmMinutes < 24 * 60 { return "\(alarmMinutes / 60) h" }
        return "\(alarmMinutes / 24 / 60) d"
    }

    // MARK: - Submit

    private func submit() {
        guard !title.isEmpty else { error = "Título obrigatório"; return }
        error = nil
        creating = true

        let guestList = guests
            .split(whereSeparator: { ",;\n ".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.contains("@") }

        let meetURLValue: URL? = {
            let trimmed = meetURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return URL(string: trimmed)
        }()

        let alarm: TimeInterval? = alarmMinutes < 0 ? nil : Double(alarmMinutes) * 60

        Task {
            if let existing = editing {
                // EDIT path — patch the event via Google API
                // and refresh the event list so the dashboard
                // reflects the new title/time/location/etc.
                // immediately.
                await appState.updateEvent(
                    existing,
                    title:       title,
                    startDate:   startDate,
                    endDate:     endDate,
                    location:    location.isEmpty ? nil : location,
                    notes:       notes.isEmpty ? nil : notes,
                    guestEmails: guestList,
                    colorId:     colorId
                )
            } else {
                await appState.createEvent(
                    title:            title,
                    startDate:        startDate,
                    endDate:          endDate,
                    calendarId:       calendarId,
                    location:         location.isEmpty ? nil : location,
                    notes:            notes.isEmpty ? nil : notes,
                    meetingURL:       meetURLValue,
                    guestEmails:      guestList,
                    availabilityBusy: availabilityBusy,
                    alarmOffset:      alarm,
                    colorId:          colorId
                )
            }
            creating = false
            onClose()
        }
    }
}

private func roundedHour(_ date: Date) -> Date {
    let cal  = Calendar.current
    let comp = cal.dateComponents([.year, .month, .day, .hour], from: date)
    return cal.date(from: comp)?.addingTimeInterval(3600) ?? date
}
