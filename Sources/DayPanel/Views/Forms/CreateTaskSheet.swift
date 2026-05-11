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

    private let priorities: [(Int, String, Color)] = [
        (0, "Nenhuma", Color(NSColor.tertiaryLabelColor)),
        (1, "Urgente", .red),
        (2, "Alta",    .orange),
        (3, "Normal",  .blue),
        (4, "Baixa",   Color(NSColor.tertiaryLabelColor)),
    ]

    private var cuConfigured: Bool {
        appState.clickUpAuthService.isConnected &&
        KeychainHelper.load(for: KeychainHelper.Keys.clickupListId) != nil
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }

    @FocusState private var titleFocused:       Bool
    @FocusState private var descriptionFocused: Bool

    @State private var showStartPicker  = false
    @State private var showDuePicker    = false
    @State private var showStatusPicker = false

    var body: some View {
        VStack(spacing: 0) {
            // Header — no own background; the popup-level
            // material (applied by `popupGlass`) shows through
            // here as the translucent title bar.
            GlassFormHeader(title: "Nova Tarefa", onClose: onClose)

            // Body + footer share a single solid surface that
            // hides the popup-level material in their region —
            // matches the design language now used by
            // `TaskDetailSheet`.
            VStack(spacing: 0) {
                ScrollablePopupContent(maxHeight: scrollMaxHeight) {
                    VStack(alignment: .leading, spacing: 12) {
                        // Hero: big title input + collapsible description
                        titleHero
                        descriptionField

                        // Subtle separator before the metadata grid — same
                        // visual rhythm as the inline TaskDetailView.
                        Rectangle()
                            .fill(.separator.opacity(0.4))
                            .frame(height: 0.5)
                            .padding(.horizontal, -12)
                            .padding(.top, 2)

                        // Detail rows mirroring the expanded task pill:
                        // [icon] [110pt label] [content]. Same icons, same
                        // order, same labels — so creating feels like
                        // editing.
                        VStack(alignment: .leading, spacing: 10) {
                            statusDetailRow
                            assigneesDetailRow
                            datesDetailRow
                            priorityDetailRow
                            tagsDetailRow
                            attachmentsDetailRow
                        }

                        if !cuConfigured {
                            GlassWarningRow("Configure o ClickUp nas configurações primeiro.")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }

                GlassFormFooter(
                    onCancel: onClose,
                    onCreate: submit,
                    createLabel: createButtonLabel,
                    createDisabled: title.isEmpty || creating || !cuConfigured
                )
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .popupGlass(shape)
        .onAppear {
            if statusName == nil {
                statusName = appState.availableStatuses.first?.status
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                titleFocused = true
            }
        }
    }

    // MARK: - Detail-row helper (matches TaskDetailView)

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
                    HStack(spacing: -4) {
                        ForEach(selectedMembers.prefix(3), id: \.id) { m in
                            avatarCircle(m)
                                .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                        }
                        if selectedMembers.count > 3 {
                            Text("+\(selectedMembers.count - 3)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 6)
                        }
                    }
                }
                Menu {
                    if appState.availableMembers.isEmpty {
                        Text("Nenhum membro disponível")
                    } else {
                        ForEach(appState.availableMembers) { m in
                            Button {
                                if assigneeIds.contains(m.id) { assigneeIds.remove(m.id) }
                                else                          { assigneeIds.insert(m.id) }
                            } label: {
                                if assigneeIds.contains(m.id) {
                                    Label(m.username, systemImage: "checkmark")
                                } else {
                                    Text(m.username)
                                }
                            }
                        }
                    }
                } label: {
                    Text(assigneeIds.isEmpty ? "Adicionar" : "Editar")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.blue)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .focusEffectDisabled()
            }
        }
    }

    private var datesDetailRow: some View {
        detailRow(icon: "calendar", label: "Datas") {
            HStack(spacing: 6) {
                dateButton(
                    label: hasStart
                        ? startDate.formatted(.dateTime.day().month(.abbreviated))
                        : "Início",
                    color: hasStart ? .primary : .secondary,
                    show:  $showStartPicker
                ) {
                    UnifiedDatePickerPopover(task: draftTask, initialMode: .start) { mode, date in
                        commitDate(mode: mode, date: date)
                    }
                }
                if hasStart || hasDue {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                dateButton(
                    label: hasDue
                        ? dueDate.formatted(.dateTime.day().month(.abbreviated))
                        : "Vencimento",
                    color: hasDue ? .primary : .secondary,
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
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.secondary.opacity(0.20), lineWidth: 0.5))
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
                HStack(spacing: 4) {
                    Image(systemName: "flag.fill")
                        .font(.caption2)
                        .foregroundStyle(current.2)
                    Text(current.1)
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

    private var tagsDetailRow: some View {
        detailRow(icon: "tag.fill", label: "Etiquetas") {
            HStack(spacing: 4) {
                if !selectedTags.isEmpty {
                    ForEach(selectedTags.prefix(3), id: \.name) { t in
                        tagPill(t)
                    }
                    if selectedTags.count > 3 {
                        Text("+\(selectedTags.count - 3)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
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
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.blue)
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
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()

                    if !pickedAttachments.isEmpty {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("\(pickedAttachments.count) " +
                             (pickedAttachments.count == 1
                                ? "arquivo" : "arquivos"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(iconTint(forExtension: ext))
                .frame(width: 16)

            Text(url.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let size {
                Text(size)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            Button {
                pickedAttachments.removeAll { $0 == url }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Remover anexo")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10),
                              lineWidth: 0.5)
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

    private func iconTint(forExtension ext: String) -> Color {
        switch ext {
        case "pdf":                                       return .red
        case "doc","docx","txt","rtf","md","pages":       return .blue
        case "xls","xlsx","csv","numbers":                return .green
        case "ppt","pptx","key":                          return .orange
        case "png","jpg","jpeg","gif","heic","webp","svg","tiff","bmp":
            return .pink
        case "mp4","mov","m4v","avi","mkv","webm":        return .purple
        case "mp3","wav","aac","m4a","flac","ogg":        return .indigo
        case "zip","rar","7z","tar","gz","bz2":           return .brown
        case "swift","js","ts","py","rb","go","java","kt","cpp","c","h","html","css","json","xml","yml","yaml","sh":
            return .teal
        default:                                          return .secondary
        }
    }

    // MARK: - Hero title

    private var titleHero: some View {
        TextField("", text: $title, prompt: Text("Título da tarefa")
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
        // writes. Saves vertical space for the rest of the form when
        // the description isn't being edited.
        let minH: CGFloat = (description.isEmpty && !descriptionFocused) ? 36 : 60
        let maxH: CGFloat = descriptionFocused ? 140 : 90

        return ZStack(alignment: .topLeading) {
            if description.isEmpty && !descriptionFocused {
                Text("Descrição (opcional)")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $description)
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
        .animation(.easeInOut(duration: 0.18), value: description.isEmpty)
    }

    // MARK: - Status picker

    private var statusPicker: some View {
        Group {
            if appState.availableStatuses.isEmpty {
                Text("—").font(.caption).foregroundStyle(.tertiary)
            } else {
                Button { showStatusPicker.toggle() } label: { statusPillLabel }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .popover(isPresented: $showStatusPicker, arrowEdge: .top) {
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

    private var statusPillLabel: some View {
        let s = appState.availableStatuses.first(where: { $0.status == statusName })
        let color = Color(hex: s?.color ?? "#87909E")
        return HStack(spacing: 4) {
            Text((s?.status ?? "Selecionar").uppercased())
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.15), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 0.5))
    }

    // MARK: - Helpers

    private var selectedMembers: [CUMember] {
        appState.availableMembers.filter { assigneeIds.contains($0.id) }
    }

    private var selectedTags: [CUTask.Tag] {
        appState.availableTags.filter { tagNames.contains($0.name) }
    }

    private func avatarCircle(_ m: CUMember) -> some View {
        let bg = m.color.flatMap { Color(hex: $0) } ?? .blue
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
        HStack(spacing: 3) {
            Text(tag.name).font(.caption2.weight(.medium))
            Button { tagNames.remove(tag.name) } label: {
                Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
            }
            .buttonStyle(.plain).focusEffectDisabled()
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .foregroundStyle(Color(hex: tag.foreground))
        .background(Color(hex: tag.background).opacity(0.85), in: Capsule())
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
