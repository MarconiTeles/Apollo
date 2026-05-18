import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CreateTaskSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.windowSize) private var windowSize
    var onClose: () -> Void = {}

    /// 70% of host-window height minus chrome (header + footer),
    /// also clamped so the centered popup never overlaps the macOS
    /// toolbar at the top of the window.
    private var scrollMaxHeight: CGFloat {
        let h = windowSize.height
        guard h > 0 else { return 420 }
        let chrome: CGFloat = 140
        let preferred = max(220, h * 0.70 - chrome)
        let safeMax   = max(0,   h - 128 - chrome)
        return min(preferred, safeMax)
    }

    @State private var title       = ""
    @State private var description = ""
    @State private var statusName: String?
    @State private var priority    = 0
    @State private var hasStart    = false
    @State private var startDate   = Date()
    @State private var hasDue      = false
    @State private var dueDate     = Date().addingTimeInterval(86400)
    @State private var assigneeIds: Set<Int>    = []
    @State private var tagNames:    Set<String> = []

    /// Interactive assignee search — mirrors the event guest
    /// search: a live-filtered, multi-select editorial list
    /// instead of a flat `Menu`.
    @State private var assigneeSearch       = ""
    @State private var showAssigneeSearch   = false
    @FocusState private var assigneeSearchFocused: Bool
    @State private var creating    = false

    /// Files queued for upload. Selected via `NSOpenPanel`
    /// (multi-select, any file type — ClickUp's attachment
    /// endpoint is content-agnostic). Uploaded sequentially
    /// AFTER the task is created (`submit()` needs the
    /// task id the server hands back from
    /// `POST /list/{id}/task`).
    @State private var pickedAttachments: [URL] = []
    /// 0.0 → uploads.count once `submit()` reaches the
    /// attachment phase. Drives the "Anexando 2/5…" hint
    /// shown alongside the create-task spinner so the user
    /// knows the form is still working after the task
    /// itself is up.
    @State private var attachmentsUploaded: Int = 0

    // Editorial-muted priority palette — same densified hexes as
    // `CUTask.priorityHex` so the create form and the task list
    // read priority with one coherent set of colors.
    private let priorities: [(Int, String, Color)] = [
        (0, "Nenhuma", Editorial.inkMute),
        (1, "Urgente", Color(hex: "#A8392A")),
        (2, "Alta",    Color(hex: "#9A7B1F")),
        (3, "Normal",  Color(hex: "#56708A")),
        (4, "Baixa",   Color(hex: "#A8A39A")),
    ]

    private var cuConfigured: Bool {
        appState.clickUpAuthService.isConnected &&
        KeychainHelper.load(for: KeychainHelper.Keys.clickupListId) != nil
    }

    private var shape: RoundedRectangle {
        // Editorial popup: near-square corners — same radius as the
        // sibling `TaskDetailSheet` so creating and editing feel like
        // one surface (prototype `PPopup`).
        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
    }

    @FocusState private var titleFocused:       Bool
    // RichTextEditor drives this via the responder chain (it takes
    // a Binding<Bool>, not a FocusState).
    @State private var descriptionFocused = false

    /// Trailing "@token" in the description, or nil. Drives the
    /// inline member picker — same behavior as the comment composer.
    @State private var mentionQuery: String?

    @State private var showStartPicker  = false
    @State private var showDuePicker    = false
    @State private var showStatusPicker = false

    var body: some View {
        VStack(spacing: 0) {
            // Editorial masthead: serif title + hairline rule.
            GlassFormHeader(title: "Nova Tarefa", onClose: onClose)

            // Body + footer flow on the shared paper surface — the
            // header's hairline is the only divider (prototype
            // `PNewTask`).
            VStack(spacing: 0) {
                ScrollablePopupContent(maxHeight: scrollMaxHeight) {
                    VStack(alignment: .leading, spacing: 12) {
                        // Hero: borderless serif title + collapsible
                        // description on the bare paper.
                        titleHero
                        descriptionField

                        // Marginalia rows — each carries its own
                        // `ruleSoft` underline (prototype `PMarg`),
                        // so they self-divide with no extra separator.
                        VStack(alignment: .leading, spacing: 0) {
                            statusDetailRow
                            assigneesDetailRow
                            // Inline, live-filtered member picker —
                            // placed in-flow (not a popover) so the
                            // search field keeps keyboard focus.
                            if showAssigneeSearch {
                                assigneeResultsList
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .offset(y: -6)),
                                        removal:   .opacity.combined(with: .offset(y: -6))
                                    ))
                            }
                            datesDetailRow
                            priorityDetailRow
                            tagsDetailRow
                            attachmentsDetailRow
                        }
                        .padding(.top, 6)
                        .animation(.easeInOut(duration: 0.18), value: showAssigneeSearch)

                        if !cuConfigured {
                            GlassWarningRow("Configure o ClickUp nas configurações primeiro.")
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                }

                GlassFormFooter(
                    onCancel: onClose,
                    onCreate: submit,
                    createLabel: createButtonLabel,
                    createDisabled: title.isEmpty || creating || !cuConfigured
                )
            }
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        // Editorial page chrome — near-neutral popup surface,
        // hairline border, one soft ambient shadow (matches
        // `TaskDetailSheet`).
        .background(Editorial.popup, in: shape)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Editorial.rule, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.22), radius: 50, x: 0, y: 40)
        .shadow(color: .black.opacity(0.08), radius: 24, x: 0, y: 8)
        // Drop target — accepts any file dragged from Finder /
        // Mail / Safari / iMessage. URLs are queued exactly the
        // same way the "Adicionar" button feeds `pickedAttachments`,
        // so the user can mix the two flows freely. `isTargeted`
        // drives a subtle accent ring so it's obvious the form
        // accepted the drag before the drop.
        .onDrop(
            of: [.fileURL],
            isTargeted: $isDropTargeted
        ) { providers in
            handleDroppedProviders(providers)
        }
        .overlay(
            shape.strokeBorder(
                Editorial.accent.opacity(isDropTargeted ? 0.7 : 0),
                lineWidth: isDropTargeted ? 2 : 0
            )
            .animation(.easeOut(duration: 0.15), value: isDropTargeted)
            .allowsHitTesting(false)
        )
        .onAppear {
            if statusName == nil {
                statusName = appState.availableStatuses.first?.status
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                titleFocused = true
            }
        }
    }

    // MARK: - Drop handling

    /// True while a Finder drag is hovering anywhere over the
    /// sheet. Drives the accent ring overlay so the user knows
    /// the drop will be accepted.
    @State private var isDropTargeted: Bool = false

    /// Drains every `NSItemProvider` reported by the drop, loading
    /// the file URL representation off the main thread (some
    /// providers — Mail attachments, screenshots from Continuity —
    /// do the materialisation lazily and can block briefly).
    /// Hops back to main to mutate `pickedAttachments` so SwiftUI
    /// re-evaluates the chip list.
    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    if !pickedAttachments.contains(url) {
                        pickedAttachments.append(url)
                    }
                }
            }
        }
        return true
    }

    // MARK: - Detail-row helper (matches TaskDetailView)

    /// Prototype `PMarg`: a `100px 1fr` row — uppercase sans
    /// micro-caps label, ink value, hairline (`ruleSoft`) underline.
    /// The `icon:` argument is kept for call-site compatibility but
    /// unused (the editorial marginalia row carries no glyph).
    private func detailRow<Content: View>(
        icon _: String, label: String, @ViewBuilder content: () -> Content
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

    /// Synthesises a `CUTask` from the current form state so we can
    /// reuse `UnifiedDatePickerPopover` (which is task-shaped) without
    /// duplicating the popover's UI for create-mode.
    private var draftTask: CUTask {
        CUTask(
            id:            "__draft",
            title:         title,
            status:        statusName ?? "open",
            statusColor:   "#87909E",
            priority:      priority,
            priorityColor: "#BFBFBF",
            startDate:     hasStart ? startDate : nil,
            dueDate:       hasDue   ? dueDate   : nil,
            listId:        "",
            listName:      "",
            isCompleted:   false,
            description:   description.isEmpty ? nil : description,
            assignees:     [],
            tags:          [],
            url:           nil
        )
    }

    // MARK: - Detail rows

    private var statusDetailRow: some View {
        detailRow(icon: "circle.dashed", label: "Status") {
            statusPicker
        }
    }

    private var assigneesDetailRow: some View {
        detailRow(icon: "person.fill", label: "Responsáveis") {
            HStack(spacing: 6) {
                if !assigneeIds.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(selectedMembers, id: \.id) { m in
                            assigneeChip(m)
                        }
                    }
                }

                if showAssigneeSearch {
                    TextField("Buscar pessoa…", text: $assigneeSearch)
                        .textFieldStyle(.plain)
                        .font(Editorial.sans(12.5))
                        .foregroundStyle(Editorial.ink)
                        .focused($assigneeSearchFocused)
                        .focusEffectDisabled()
                        .onSubmit { closeAssigneeSearch() }
                    Button { closeAssigneeSearch() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Editorial.inkMute)
                    }
                    .buttonStyle(.plain).focusEffectDisabled()
                } else {
                    Button {
                        showAssigneeSearch = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            assigneeSearchFocused = true
                        }
                    } label: {
                        Text(assigneeIds.isEmpty ? "Adicionar" : "Editar")
                            .font(Editorial.sans(12, .medium))
                            .foregroundStyle(Editorial.accent)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
        }
    }

    private func closeAssigneeSearch() {
        showAssigneeSearch    = false
        assigneeSearch        = ""
        assigneeSearchFocused = false
    }

    /// Removable chip for a chosen responsible. The trailing ✕
    /// deselects the member — recovery path for an accidental pick.
    private func assigneeChip(_ m: CUMember) -> some View {
        HStack(spacing: 5) {
            avatarCircle(m)
            Text(m.username.split(separator: " ").first.map(String.init) ?? m.username)
                .font(Editorial.sans(11.5, .medium))
                .foregroundStyle(Editorial.ink)
                .lineLimit(1)
            Button { assigneeIds.remove(m.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Editorial.inkMute)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Remover \(m.username)")
        }
        .padding(.leading, 3)
        .padding(.trailing, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Editorial.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Editorial.rule, lineWidth: 1)
        )
    }

    private var filteredAssigneeMembers: [CUMember] {
        let q = assigneeSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return appState.availableMembers }
        return appState.availableMembers.filter {
            $0.username.lowercased().contains(q)
            || ($0.initials?.lowercased().contains(q) ?? false)
        }
    }

    // Canonical editorial picker (matches the comment @-mention
    // picker / event guest list): page surface, hairline border,
    // `editorialMuted` avatar discs, ink names, `ruleSoft`
    // separators. Multi-select — a check trails the chosen rows.
    private var assigneeResultsList: some View {
        let members = filteredAssigneeMembers
        return VStack(alignment: .leading, spacing: 0) {
            if members.isEmpty {
                Text("Nenhum membro encontrado")
                    .font(Editorial.sans(12))
                    .foregroundStyle(Editorial.inkMute)
                    .padding(.horizontal, 10).padding(.vertical, 8)
            } else {
                ForEach(members) { m in
                    Button {
                        if assigneeIds.contains(m.id) { assigneeIds.remove(m.id) }
                        else                          { assigneeIds.insert(m.id) }
                    } label: {
                        HStack(spacing: 8) {
                            avatarCircle(m)
                            Text(m.username)
                                .font(Editorial.sans(12, .medium))
                                .foregroundStyle(Editorial.ink)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if assigneeIds.contains(m.id) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Editorial.accent)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    if m.id != members.last?.id {
                        Rectangle().fill(Editorial.ruleSoft).frame(height: 1)
                    }
                }
            }
        }
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
                .strokeBorder(Editorial.rule, lineWidth: 1)
                .padding(.leading, 112),
            alignment: .leading
        )
    }

    private var datesDetailRow: some View {
        detailRow(icon: "calendar", label: "Datas") {
            HStack(spacing: 6) {
                dateButton(
                    label: hasStart
                        ? startDate.formatted(.dateTime.day().month(.abbreviated))
                        : "Início",
                    color: hasStart ? Editorial.ink : Editorial.inkSoft,
                    show:  $showStartPicker
                ) {
                    UnifiedDatePickerPopover(task: draftTask, initialMode: .start) { mode, date in
                        commitDate(mode: mode, date: date)
                    }
                }
                if hasStart || hasDue {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10))
                        .foregroundStyle(Editorial.inkMute)
                }
                dateButton(
                    label: hasDue
                        ? dueDate.formatted(.dateTime.day().month(.abbreviated))
                        : "Vencimento",
                    color: hasDue ? Editorial.ink : Editorial.inkSoft,
                    show:  $showDuePicker
                ) {
                    UnifiedDatePickerPopover(task: draftTask, initialMode: .due) { mode, date in
                        commitDate(mode: mode, date: date)
                    }
                }
            }
        }
    }

    private func commitDate(mode: UnifiedDatePickerPopover.Mode, date: Date?) {
        switch mode {
        case .start:
            if let d = date {
                startDate = d
                hasStart  = true
            } else {
                hasStart = false
            }
        case .due:
            if let d = date {
                dueDate = d
                hasDue  = true
            } else {
                hasDue = false
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
                .font(Editorial.sans(12, .medium))
                .foregroundStyle(color)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Editorial.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Editorial.rule, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .popover(isPresented: show, arrowEdge: .bottom) { content() }
    }

    private var priorityDetailRow: some View {
        let current = priorities.first(where: { $0.0 == priority }) ?? priorities[0]
        return detailRow(icon: "flag.fill", label: "Prioridade") {
            Menu {
                ForEach(priorities, id: \.0) { p in
                    Button {
                        priority = p.0
                    } label: {
                        if p.0 == priority {
                            Label(p.1, systemImage: "checkmark")
                        } else {
                            Text(p.1)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(current.2)
                    Text(current.1)
                        .font(Editorial.serif(14))
                        .foregroundStyle(priority == 0 ? Editorial.inkMute : Editorial.ink)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Editorial.inkMute)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .focusEffectDisabled()
        }
    }

    private var tagsDetailRow: some View {
        detailRow(icon: "tag.fill", label: "Etiquetas") {
            HStack(spacing: 4) {
                if !selectedTags.isEmpty {
                    ForEach(selectedTags.prefix(3), id: \.name) { t in
                        tagPill(t)
                    }
                    if selectedTags.count > 3 {
                        Text("+\(selectedTags.count - 3)")
                            .font(Editorial.sans(11, .semibold))
                            .foregroundStyle(Editorial.inkSoft)
                    }
                }
                Menu {
                    if appState.availableTags.isEmpty {
                        Text("Nenhuma etiqueta na space")
                    } else {
                        ForEach(appState.availableTags, id: \.name) { t in
                            Button {
                                if tagNames.contains(t.name) { tagNames.remove(t.name) }
                                else                         { tagNames.insert(t.name) }
                            } label: {
                                if tagNames.contains(t.name) {
                                    Label(t.name, systemImage: "checkmark")
                                } else {
                                    Text(t.name)
                                }
                            }
                        }
                    }
                } label: {
                    Text(tagNames.isEmpty ? "Adicionar" : "Editar")
                        .font(Editorial.sans(12, .medium))
                        .foregroundStyle(Editorial.accent)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .focusEffectDisabled()
            }
        }
    }

    // MARK: - Attachments

    private var attachmentsDetailRow: some View {
        detailRow(icon: "paperclip", label: "Anexos") {
            VStack(alignment: .leading, spacing: 6) {
                // Chip per queued file. Compact row of icon
                // + truncated filename + size + dismiss
                // button. ClickUp's upload endpoint is
                // file-type agnostic, so we show the icon
                // mapping our existing `Attachment.icon`
                // table uses for the same extensions.
                if !pickedAttachments.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(pickedAttachments, id: \.self) { url in
                            attachmentChip(url)
                        }
                    }
                }

                HStack(spacing: 6) {
                    Button {
                        pickAttachments()
                    } label: {
                        Text(pickedAttachments.isEmpty
                              ? "Adicionar"
                              : "Adicionar mais")
                            .font(Editorial.sans(12, .medium))
                            .foregroundStyle(Editorial.accent)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()

                    if !pickedAttachments.isEmpty {
                        Text("·")
                            .font(Editorial.sans(11))
                            .foregroundStyle(Editorial.inkMute)
                        Text("\(pickedAttachments.count) " +
                             (pickedAttachments.count == 1
                                ? "arquivo" : "arquivos"))
                            .font(Editorial.sans(11))
                            .foregroundStyle(Editorial.inkSoft)
                    }
                }
            }
        }
    }

    private func attachmentChip(_ url: URL) -> some View {
        let size = fileSizeString(url)
        let ext  = url.pathExtension.lowercased()
        return HStack(spacing: 8) {
            Image(systemName: iconName(forExtension: ext))
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Editorial.accent)
                .frame(width: 16)

            Text(url.lastPathComponent)
                .font(.system(size: 13, design: .serif).italic())
                .foregroundStyle(Editorial.accent)
                .lineLimit(1)
                .truncationMode(.middle)

            if let size {
                Text(size)
                    .font(Editorial.sans(10.5))
                    .foregroundStyle(Editorial.inkMute)
            }

            Spacer(minLength: 4)

            Button {
                pickedAttachments.removeAll { $0 == url }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Editorial.inkMute)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Remover anexo")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Editorial.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Editorial.rule,
                              lineWidth: 1)
        )
    }

    /// Open an `NSOpenPanel` (multi-select, all file
    /// types). ClickUp accepts arbitrary content via its
    /// multipart attachment endpoint, so we don't apply
    /// any type filter here.
    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles          = true
        panel.canChooseDirectories    = false
        panel.allowsMultipleSelection = true
        panel.title                   = "Selecionar anexos"
        panel.message                 = "Escolha arquivos para anexar à nova tarefa"
        panel.prompt                  = "Adicionar"

        if panel.runModal() == .OK {
            // Append without duplicates (same path picked
            // twice in two passes shouldn't queue twice).
            for url in panel.urls
            where !pickedAttachments.contains(url) {
                pickedAttachments.append(url)
            }
        }
    }

    private func fileSizeString(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default
                .attributesOfItem(atPath: url.path),
              let bytes = attrs[.size] as? Int64
        else { return nil }
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useKB, .useMB, .useGB]
        fmt.countStyle   = .file
        return fmt.string(fromByteCount: bytes)
    }

    /// SF Symbol roughly matching `CUTask.Attachment.icon`
    /// in `Models/CUTask.swift`. Kept inline here (rather
    /// than importing the model's helper) because the
    /// model side takes an `Attachment` and we only have a
    /// local `URL` until the upload completes.
    private func iconName(forExtension ext: String) -> String {
        switch ext {
        case "pdf":                                       return "doc.fill"
        case "doc","docx","txt","rtf","md","pages":       return "doc.text.fill"
        case "xls","xlsx","csv","numbers":                return "tablecells.fill"
        case "ppt","pptx","key":                          return "rectangle.stack.fill"
        case "png","jpg","jpeg","gif","heic","webp","svg","tiff","bmp":
            return "photo.fill"
        case "mp4","mov","m4v","avi","mkv","webm":        return "video.fill"
        case "mp3","wav","aac","m4a","flac","ogg":        return "waveform"
        case "zip","rar","7z","tar","gz","bz2":           return "archivebox.fill"
        case "swift","js","ts","py","rb","go","java","kt","cpp","c","h","html","css","json","xml","yml","yaml","sh":
            return "chevron.left.forwardslash.chevron.right"
        default:                                          return "doc"
        }
    }

    // MARK: - Hero title

    private var titleHero: some View {
        // Prototype `PNewTask`: borderless serif-24 input with a
        // single bottom hairline (cinnabar when focused). No card,
        // no fill — the title sits directly on the paper.
        TextField("", text: $title, prompt: Text("Título da tarefa")
            .font(Editorial.serif(24))
            .foregroundColor(Editorial.inkMute))
            .textFieldStyle(.plain)
            .font(Editorial.serif(24))
            .foregroundStyle(Editorial.ink)
            .tracking(-0.4)
            .focused($titleFocused)
            .focusEffectDisabled()
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(titleFocused ? Editorial.accent : Editorial.rule)
                    .frame(height: 1)
            }
            .animation(.easeInOut(duration: 0.15), value: titleFocused)
    }

    // MARK: - Description

    private var descriptionField: some View {
        // Compact when empty/unfocused, grows as the user writes.
        let minH: CGFloat = (description.isEmpty && !descriptionFocused) ? 36 : 60
        let maxH: CGFloat = descriptionFocused ? 160 : 96

        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if description.isEmpty && !descriptionFocused {
                    // Aligned to RichTextEditor's NSTextView insets
                    // (left 5, top 8).
                    Text("Descrição (opcional)")
                        .font(Editorial.sans(13))
                        .foregroundStyle(Editorial.inkMute)
                        .padding(.leading, 12)
                        .padding(.top, 11)
                        .allowsHitTesting(false)
                }
                // RichTextEditor auto-detects URLs and renders them
                // as clickable links — covers "colocar links na
                // descrição" with the app's canonical editor.
                RichTextEditor(
                    text:              $description,
                    minHeight:         minH,
                    maxHeight:         maxH,
                    scrollsInternally: true,
                    fontSize:          13,
                    isFocused:         $descriptionFocused,
                    mentionStrings:    appState.availableMembers.map { "@" + $0.username },
                    onFileDrop: { urls in
                        // A file dropped on the description is queued
                        // as an attachment (editorial ANEXOS chip) —
                        // not pasted as a raw path. Multi-file safe.
                        for u in urls where !pickedAttachments.contains(u) {
                            pickedAttachments.append(u)
                        }
                    }
                )
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .frame(minHeight: minH, maxHeight: maxH)
                .onChange(of: description) { _, new in
                    updateMentionState(text: new)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Editorial.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(descriptionFocused ? Editorial.accent : Editorial.rule,
                                  lineWidth: 1)
            )

            // Inline editorial member picker for the trailing
            // "@token" — same component family as the comment
            // composer and the assignee search.
            if let q = mentionQuery, !filteredMentionMembers(matching: q).isEmpty {
                descriptionMentionPicker(query: q)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }

            Text("Arraste arquivos para anexar · @ marca pessoas · links viram clicáveis")
                .font(Editorial.sans(10.5))
                .foregroundStyle(Editorial.inkMute)
        }
        .animation(.easeInOut(duration: 0.18), value: descriptionFocused)
        .animation(.easeInOut(duration: 0.18), value: description.isEmpty)
        .animation(.easeInOut(duration: 0.15), value: mentionQuery)
    }

    // MARK: - Description @-mentions

    private func updateMentionState(text: String) {
        guard let atIdx = text.lastIndex(of: "@") else {
            mentionQuery = nil; return
        }
        let after = text.index(after: atIdx)
        let trailing = String(text[after...])
        if trailing.contains(where: { $0.isWhitespace || $0.isNewline }) {
            mentionQuery = nil
        } else {
            mentionQuery = trailing.lowercased()
        }
    }

    private func filteredMentionMembers(matching q: String) -> [CUMember] {
        guard !appState.availableMembers.isEmpty else { return [] }
        if q.isEmpty { return Array(appState.availableMembers.prefix(6)) }
        return appState.availableMembers
            .filter { $0.username.lowercased().contains(q) }
            .prefix(6)
            .map { $0 }
    }

    private func insertDescriptionMention(_ m: CUMember) {
        guard let atIdx = description.lastIndex(of: "@") else { return }
        let prefix = description[..<atIdx]
        description = prefix + "@" + m.username + " "
        mentionQuery = nil
    }

    private func descriptionMentionPicker(query: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            let members = filteredMentionMembers(matching: query)
            ForEach(members) { m in
                Button {
                    insertDescriptionMention(m)
                } label: {
                    HStack(spacing: 8) {
                        avatarCircle(m)
                        Text("@" + m.username)
                            .font(Editorial.sans(12, .medium))
                            .foregroundStyle(Editorial.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).focusEffectDisabled()
                if m.id != members.last?.id {
                    Rectangle().fill(Editorial.ruleSoft).frame(height: 1)
                }
            }
        }
        .background(
            Editorial.page,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Editorial.rule, lineWidth: 1)
        )
    }

    // MARK: - Status picker

    private var statusPicker: some View {
        Group {
            if appState.availableStatuses.isEmpty {
                Text("—").font(Editorial.sans(12)).foregroundStyle(Editorial.inkMute)
            } else {
                Button { showStatusPicker.toggle() } label: { statusPillLabel }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .popover(isPresented: $showStatusPicker, arrowEdge: .bottom) {
                        StatusPickerPopover(
                            statuses:          appState.availableStatuses,
                            currentStatusName: statusName
                        ) { status in
                            statusName = status.status
                            showStatusPicker = false
                        }
                    }
            }
        }
    }

    // Editorial `StatusMark`-style value: a muted status dot +
    // ink label + chevron — no loud capsule (prototype `PMarg`
    // renders status the same way the task list does).
    private var statusPillLabel: some View {
        let s = appState.availableStatuses.first(where: { $0.status == statusName })
        let color = Color(hex: s?.color ?? "#87909E").editorialMuted
        return HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(s?.status ?? "Selecionar")
                .font(Editorial.sans(11.5, .medium))
                .foregroundStyle(Editorial.inkSoft)
                .tracking(0.2)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Editorial.inkMute)
        }
    }

    // MARK: - Helpers

    private var selectedMembers: [CUMember] {
        appState.availableMembers.filter { assigneeIds.contains($0.id) }
    }

    private var selectedTags: [CUTask.Tag] {
        appState.availableTags.filter { tagNames.contains($0.name) }
    }

    private func avatarCircle(_ m: CUMember) -> some View {
        let bg = (m.color.flatMap { Color(hex: $0) } ?? Editorial.inkSoft).editorialMuted
        return ZStack {
            Circle().fill(bg)
            if let pic = m.profilePicture, let url = URL(string: pic) {
                AsyncImage(url: url) { phase in
                    if case .success(let img) = phase { img.resizable().scaledToFill() }
                }
                .clipShape(Circle())
            } else {
                Text(m.initials ?? String(m.username.prefix(2)).uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 18, height: 18)
    }

    private func tagPill(_ tag: CUTask.Tag) -> some View {
        let c = Color(hex: tag.background).editorialMuted
        return HStack(spacing: 4) {
            Text(tag.name)
                .font(Editorial.sans(10.5, .medium))
            Button { tagNames.remove(tag.name) } label: {
                Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
            }
            .buttonStyle(.plain).focusEffectDisabled()
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .foregroundStyle(c)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(c.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(c.opacity(0.22), lineWidth: 1)
        )
    }

    /// Footer button copy. Reflects the current phase of
    /// the `submit()` async chain so the user knows
    /// whether we're still posting the task itself or
    /// already streaming attachments to ClickUp — the
    /// latter can be slow on large files and a static
    /// "Criando…" was reading as a hang.
    private var createButtonLabel: String {
        guard creating else { return "Criar Tarefa" }
        let total = pickedAttachments.count
        if total > 0 && attachmentsUploaded < total {
            return "Anexando \(attachmentsUploaded + 1)/\(total)…"
        }
        return "Criando…"
    }

    private func submit() {
        guard !title.isEmpty else { return }
        creating = true
        attachmentsUploaded = 0
        let queued = pickedAttachments
        Task {
            // 1. Create the task. We need the returned
            //    `CUTask` so we have the id to anchor any
            //    follow-up attachment uploads onto. If
            //    creation fails we DON'T attempt uploads —
            //    `createTask` already surfaced an error
            //    notification.
            let task = await appState.createTask(
                title:       title,
                description: description.isEmpty ? nil : description,
                status:      statusName,
                priority:    priority,
                startDate:   hasStart ? startDate : nil,
                dueDate:     hasDue ? dueDate : nil,
                assigneeIds: Array(assigneeIds),
                tagNames:    Array(tagNames)
            )

            // 2. Sequential upload of queued attachments.
            //    Sequential (not parallel) so the user's
            //    ClickUp rate limits aren't blown out on a
            //    large picker selection — and so each file's
            //    own per-task notification lands in order.
            //    `uploadCommentAttachment` is the existing
            //    public hop on AppState; under the hood it
            //    hits the same `POST /task/{id}/attachment`
            //    multipart endpoint as drag-drop in the
            //    detail popup.
            if let task, !queued.isEmpty {
                for url in queued {
                    _ = await appState.uploadCommentAttachment(
                        for: task,
                        fileURL: url
                    )
                    await MainActor.run {
                        attachmentsUploaded += 1
                    }
                }
            }

            await MainActor.run {
                creating = false
                onClose()
            }
        }
    }
}
