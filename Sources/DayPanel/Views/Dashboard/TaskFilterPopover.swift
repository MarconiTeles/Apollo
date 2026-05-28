import SwiftUI

/// Multi-dimensional filter UI for the task list. Opens from the
/// "Filtros" button in the toolbar. Each dimension is a collapsible
/// section with chip-style multi-select. Status keeps its existing
/// horizontal-bar UI in the dashboard — this popover handles the
/// other four dimensions.
struct TaskFilterPopover: View {
    /// Where the filter UI is being rendered. Drives whether the
    /// popover chrome (header, footer, background, shadow) is
    /// painted — the embedded variant is for surfaces like the
    /// sidebar's FILTROS section that already provide their own
    /// container.
    enum Mode { case popover, embedded }
    var mode: Mode = .popover

    @EnvironmentObject var appState: AppState
    @Environment(\.windowSize) private var windowSize
    /// X position of the notch tip in the popover's local coordinate
    /// space. Caller (ContentView) passes the button's center X minus
    /// the popover's resting min X. If the caller doesn't supply this
    /// (e.g. previews), the notch falls back to the popover's center.
    var notchX: CGFloat = 160
    var onClose: () -> Void = {}

    /// Live search query for the Responsável picker. Replaces the
    /// old "render every member as a chip" layout — workspaces
    /// with 20+ members were producing a wall of chips. Empty
    /// query shows only currently-selected members.
    @State private var assigneeQuery: String = ""
    /// Same idea for Criado por.
    @State private var creatorQuery:  String = ""
    /// And for Etiquetas — but with a companion dropdown menu
    /// next to the search box so the user can also browse the
    /// full tag list without typing.
    @State private var tagQuery:      String = ""

    /// Whole-popover cap: never exceed 70% of the app window height
    /// AND never overlap the macOS toolbar after centering.
    /// `ScrollablePopupContent` gets (cap − header chrome) so the
    /// header + scroll area together stay under that cap.
    private var scrollMaxHeight: CGFloat {
        let h = windowSize.height
        guard h > 0 else { return 420 }
        // Header (~64pt) + divider + outer padding ≈ 80pt chrome.
        let chrome: CGFloat = 80
        let preferred = max(200, h * 0.70 - chrome)
        let safeMax   = max(0,   h - 128 - chrome)
        return min(preferred, safeMax)
    }

    private static let popoverWidth: CGFloat = 340
    private static let cornerRadius: CGFloat = 6

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    }

    /// Priorities present in the user's tasks — only show pickers for
    /// values that exist so the UI doesn't list ranks no one uses.
    private var availablePriorities: [Int] {
        let ranks = Set(appState.tasks.map(\.priority))
        // Sort: Urgent → High → Normal → Low → None
        return [1, 2, 3, 4, 0].filter { ranks.contains($0) }
    }

    /// Tags present anywhere in the workspace (from `availableTags`,
    /// loaded by sync). Falls back to tags found directly on tasks if
    /// the workspace fetch isn't yet populated.
    private var availableTagNames: [String] {
        if !appState.availableTags.isEmpty {
            return appState.availableTags.map(\.name).sorted()
        }
        let set = Set(appState.tasks.flatMap { $0.tags.map(\.name) })
        return set.sorted()
    }

    /// Distinct creators across loaded tasks — ClickUp doesn't expose a
    /// dedicated "all creators" endpoint, so we derive this from the
    /// tasks themselves. Only members who actually authored visible
    /// tasks show up.
    private var availableCreators: [CUTask.Assignee] {
        var seen: Set<Int> = []
        var list: [CUTask.Assignee] = []
        for t in appState.tasks {
            guard let c = t.creator, !seen.contains(c.id) else { continue }
            seen.insert(c.id)
            list.append(c)
        }
        return list.sorted { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }
    }

    private var hasClosedDates: Bool {
        appState.tasks.contains { $0.dateClosed != nil }
    }

    var body: some View {
        switch mode {
        case .popover:  popoverBody
        case .embedded: embeddedBody
        }
    }

    /// The original popover layout — header + scrollable
    /// sections + footer + popover chrome (background / border /
    /// shadow). Used by the toolbar "Filtros" button.
    private var popoverBody: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Editorial.rule).frame(height: 1)

            ScrollablePopupContent(maxHeight: scrollMaxHeight) {
                sectionsStack
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
            }

            Rectangle().fill(Editorial.rule).frame(height: 1)
            footer
        }
        .frame(width: Self.popoverWidth)
        .fixedSize(horizontal: false, vertical: true)
        // Editorial card (prototype `PFilters` / `PPopup`):
        // near-neutral popup surface, hairline border, soft
        // ambient shadow — no glass, no notch.
        .background(Editorial.popup, in: shape)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Editorial.rule, lineWidth: 1).allowsHitTesting(false) }
        .shadow(color: .black.opacity(0.22), radius: 50, x: 0, y: 40)
        .shadow(color: .black.opacity(0.08), radius: 24, x: 0, y: 8)
    }

    /// Chrome-less variant for embedding inside another
    /// container (e.g. the sidebar's FILTROS section). Skips
    /// the header/footer/popover background — the host owns
    /// the container, and any clear action is wired by the
    /// embedding view if it wants one.
    private var embeddedBody: some View {
        sectionsStack
    }

    /// Shared filter sections — the same content rendered in
    /// both popover and embedded modes so toggling a chip in
    /// one surface mutates the SAME `appState.taskFilters`
    /// (single source of truth).
    ///
    /// All 7 sections render UNCONDITIONALLY now — the previous
    /// "hide if empty" gates were dropping Prioridade / Etiquetas
    /// / Criado por / Data de encerramento from the sidebar when
    /// the active list happened to have no priorities/tags/etc.
    /// loaded. Each section's body already handles its own empty
    /// state (e.g. "Digite para buscar entre N pessoas") so the
    /// UI stays predictable.
    private var sectionsStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            dueSection
            prioritySection
            assigneeSection
            tagsSection
            creatorSection
            createdSection
            closedSection
        }
    }

    // MARK: - Footer (prototype: Limpar · Aplicar)

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.spring(duration: 0.2)) {
                    appState.taskFilters = TaskFilters()
                }
            } label: {
                Text("Limpar")
                    .font(Editorial.sans(12, .medium))
                    .foregroundStyle(appState.taskFilters.isEmpty
                                     ? Editorial.inkMute : Editorial.accent)
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .disabled(appState.taskFilters.isEmpty)

            Spacer(minLength: 0)

            Button(action: onClose) {
                Text("Aplicar")
                    .font(Editorial.sans(12.5, .medium))
                    .foregroundStyle(Editorial.page)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Editorial.ink))
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Folio("Filtros")
                let n = appState.taskFilters.activeDimensionCount
                Caption(n == 0
                        ? "refine a lista de tarefas"
                        : "\(n) dimensão" + (n == 1 ? "" : "s") + " ativa" + (n == 1 ? "" : "s"),
                        size: 12.5)
            }

            Spacer(minLength: 0)

            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Editorial.inkSoft)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Section: Vencimento

    private var dueSection: some View {
        sectionContainer(title: "Vencimento", systemImage: "calendar.badge.clock") {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(DueWindow.allCases) { w in
                    chipToggle(
                        label:    w.label,
                        isActive: appState.taskFilters.dueWindow == w
                    ) {
                        appState.taskFilters.dueWindow =
                            (appState.taskFilters.dueWindow == w) ? nil : w
                    }
                }
            }
        }
    }

    // MARK: - Section: Prioridade

    private var prioritySection: some View {
        sectionContainer(title: "Prioridade", systemImage: "flag") {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(availablePriorities, id: \.self) { p in
                    chipToggle(
                        label:     label(forPriority: p),
                        tint:      priorityColor(p),
                        showCheck: true,
                        isActive:  appState.taskFilters.priorities.contains(p)
                    ) {
                        toggle(&appState.taskFilters.priorities, p)
                    }
                }
            }
        }
    }

    // MARK: - Section: Responsável

    private var assigneeSection: some View {
        sectionContainer(title: "Responsável", systemImage: "person.2") {
            VStack(alignment: .leading, spacing: 6) {
                memberSearchField(
                    placeholder: "Buscar pessoa…",
                    query: $assigneeQuery
                )
                let q = assigneeQuery.trimmingCharacters(in: .whitespaces)
                let selected = appState.availableMembers
                    .filter { appState.taskFilters.assigneeIds.contains($0.id) }
                let pool = q.isEmpty
                    ? selected
                    : appState.availableMembers
                        .filter { $0.username.localizedCaseInsensitiveContains(q) }
                if !pool.isEmpty {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(pool) { m in
                            chipToggle(
                                label:    m.username,
                                avatar:   m,
                                isActive: appState.taskFilters.assigneeIds.contains(m.id)
                            ) {
                                toggle(&appState.taskFilters.assigneeIds, m.id)
                            }
                        }
                    }
                } else if !q.isEmpty {
                    Text("Nenhum responsável corresponde.")
                        .font(Editorial.serif(11.5).italic())
                        .foregroundStyle(Editorial.inkSoft)
                        .padding(.vertical, 2)
                } else {
                    Text("Digite para buscar entre \(appState.availableMembers.count) pessoas.")
                        .font(Editorial.serif(11.5).italic())
                        .foregroundStyle(Editorial.inkSoft)
                        .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Section: Etiquetas

    private var tagsSection: some View {
        sectionContainer(title: "Etiquetas", systemImage: "tag") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    memberSearchField(
                        placeholder: "Buscar etiqueta…",
                        query: $tagQuery
                    )
                    tagDropdownMenu
                }
                let q = tagQuery.trimmingCharacters(in: .whitespaces)
                let selected = availableTagNames
                    .filter { appState.taskFilters.tagNames.contains($0) }
                let pool = q.isEmpty
                    ? selected
                    : availableTagNames
                        .filter { $0.localizedCaseInsensitiveContains(q) }
                if !pool.isEmpty {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(pool, id: \.self) { name in
                            chipToggle(
                                label:     name,
                                tint:      tagTint(name),
                                showCheck: true,
                                isActive:  appState.taskFilters.tagNames.contains(name)
                            ) {
                                toggle(&appState.taskFilters.tagNames, name)
                            }
                        }
                    }
                } else if !q.isEmpty {
                    Text("Nenhuma etiqueta corresponde.")
                        .font(Editorial.serif(11.5).italic())
                        .foregroundStyle(Editorial.inkSoft)
                        .padding(.vertical, 2)
                } else {
                    Text("Digite ou abra a lista pra escolher entre \(availableTagNames.count) etiquetas.")
                        .font(Editorial.serif(11.5).italic())
                        .foregroundStyle(Editorial.inkSoft)
                        .padding(.vertical, 2)
                }
            }
        }
    }

    /// Full-list dropdown that complements the tag search box
    /// — same toggle semantics as the chips, but reachable
    /// without typing. Selected names get a checkmark so the
    /// menu is a single source of truth for what's active.
    private var tagDropdownMenu: some View {
        Menu {
            if availableTagNames.isEmpty {
                Text("Sem etiquetas no workspace")
            } else {
                ForEach(availableTagNames, id: \.self) { name in
                    let isOn = appState.taskFilters.tagNames.contains(name)
                    Button {
                        toggle(&appState.taskFilters.tagNames, name)
                    } label: {
                        if isOn {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Editorial.inkSoft)
                .frame(width: 26, height: 26)
                .background(Editorial.card,
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Editorial.rule, lineWidth: 1)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Ver todas as etiquetas")
    }

    // MARK: - Section: Criado por

    private var creatorSection: some View {
        sectionContainer(title: "Criado por", systemImage: "person.crop.circle.badge.questionmark") {
            VStack(alignment: .leading, spacing: 6) {
                memberSearchField(
                    placeholder: "Buscar criador…",
                    query: $creatorQuery
                )
                let q = creatorQuery.trimmingCharacters(in: .whitespaces)
                let selected = availableCreators
                    .filter { appState.taskFilters.creatorIds.contains($0.id) }
                let pool = q.isEmpty
                    ? selected
                    : availableCreators
                        .filter { $0.username.localizedCaseInsensitiveContains(q) }
                if !pool.isEmpty {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(pool, id: \.id) { c in
                            let member = CUMember(
                                id:             c.id,
                                username:       c.username,
                                email:          nil,
                                color:          c.color,
                                profilePicture: c.profilePicture,
                                initials:       c.initials
                            )
                            chipToggle(
                                label:    c.username,
                                avatar:   member,
                                isActive: appState.taskFilters.creatorIds.contains(c.id)
                            ) {
                                toggle(&appState.taskFilters.creatorIds, c.id)
                            }
                        }
                    }
                } else if !q.isEmpty {
                    Text("Nenhum criador corresponde.")
                        .font(Editorial.serif(11.5).italic())
                        .foregroundStyle(Editorial.inkSoft)
                        .padding(.vertical, 2)
                } else {
                    Text("Digite para buscar entre \(availableCreators.count) pessoas.")
                        .font(Editorial.serif(11.5).italic())
                        .foregroundStyle(Editorial.inkSoft)
                        .padding(.vertical, 2)
                }
            }
        }
    }

    /// Compact glass search field reused by Responsável + Criado
    /// por. Same visual treatment as the toolbar search but
    /// sized for the popover (28pt tall vs 26).
    @ViewBuilder
    private func memberSearchField(placeholder: String,
                                   query: Binding<String>) -> some View {
        let hasQuery = !query.wrappedValue
            .trimmingCharacters(in: .whitespaces).isEmpty
        // Prototype `inputBare`: borderless serif field on a single
        // bottom hairline (cinnabar while it has a query).
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(hasQuery ? Editorial.accent : Editorial.inkMute)
            TextField(placeholder, text: query)
                .textFieldStyle(.plain)
                .font(Editorial.serif(14))
                .foregroundStyle(Editorial.ink)
                .focusEffectDisabled()
            if hasQuery {
                Button { query.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Editorial.inkMute)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(hasQuery ? Editorial.accent : Editorial.rule)
                .frame(height: 1)
        }
    }

    // MARK: - Section: Data criada

    private var createdSection: some View {
        sectionContainer(title: "Data criada", systemImage: "calendar.badge.plus") {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(DateRange.allCases) { r in
                    chipToggle(
                        label:    r.label,
                        isActive: appState.taskFilters.createdRange == r
                    ) {
                        appState.taskFilters.createdRange =
                            (appState.taskFilters.createdRange == r) ? nil : r
                    }
                }
            }
        }
    }

    // MARK: - Section: Data de encerramento

    private var closedSection: some View {
        sectionContainer(title: "Data de encerramento", systemImage: "calendar.badge.checkmark") {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(DateRange.allCases) { r in
                    chipToggle(
                        label:    r.label,
                        isActive: appState.taskFilters.closedRange == r
                    ) {
                        appState.taskFilters.closedRange =
                            (appState.taskFilters.closedRange == r) ? nil : r
                    }
                }
            }
        }
    }

    // MARK: - Section container

    /// Per-section expand state. Key = section title (the Folio
    /// label). Default: empty set → every section starts
    /// COLLAPSED (per user request: keep the FILTROS strip tidy
    /// by default, expand on demand). Same `@State` for both
    /// `.popover` and `.embedded` modes.
    @State private var expandedSections: Set<String> = []

    private func sectionContainer<Content: View>(
        title: String,
        systemImage _: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let expanded = expandedSections.contains(title)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.spring(duration: 0.26, bounce: 0.18)) {
                    if expanded {
                        expandedSections.remove(title)
                    } else {
                        expandedSections.insert(title)
                    }
                }
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    // Mirror the SidebarNavRow row labels
                    // (Hoje, Tarefas, Quadro, …) — sans 13.5
                    // medium ink, NOT the caps Folio used for
                    // section TITLES. Filter categories live
                    // at the same hierarchy as those rows.
                    Text(title)
                        .font(Editorial.sans(13.5, .medium))
                        .foregroundStyle(Editorial.ink)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Editorial.inkFaint)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if expanded {
                content()
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
            }
        }
    }

    // MARK: - Chip

    @ViewBuilder
    private func chipToggle(label: String,
                            icon: String? = nil,
                            tint: Color = .accentColor,
                            avatar: CUMember? = nil,
                            showCheck: Bool = false,
                            isActive: Bool,
                            action: @escaping () -> Void) -> some View {
        // Prototype `pillBtn`: rounded capsule, paper at rest,
        // muted-tint wash + tint border + tint label when active.
        // Single-select date pills are label-only (no icon, no
        // check) — the colour wash alone signals state. Multi-select
        // chips (`showCheck`) get a leading ✓ when active.
        let c = tint.editorialMuted
        Button(action: { withAnimation(.spring(duration: 0.18)) { action() } }) {
            HStack(spacing: 5) {
                if let avatar {
                    chipAvatar(avatar)
                } else if showCheck && isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 10))
                }
                Text(label)
                    .font(Editorial.sans(12, .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? c : Editorial.ink)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                isActive ? AnyShapeStyle(c.opacity(0.10)) : AnyShapeStyle(Editorial.page),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    isActive ? c : Editorial.rule,
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func chipAvatar(_ m: CUMember) -> some View {
        let bg = (m.color.flatMap { Color(hex: $0) } ?? Editorial.inkSoft).editorialMuted
        return ZStack {
            Circle().fill(bg)
            if let pic = m.profilePicture, let url = URL(string: pic) {
                CachedAvatar(url: url).clipShape(Circle())
            } else {
                Text(m.initials ?? String(m.username.prefix(2)).uppercased())
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Editorial.page)
            }
        }
        .frame(width: 16, height: 16)
    }

    // MARK: - Helpers

    private func toggle<T: Hashable>(_ set: inout Set<T>, _ value: T) {
        withAnimation(.spring(duration: 0.18)) {
            if set.contains(value) {
                set.remove(value)
            } else {
                set.insert(value)
            }
        }
    }

    private func label(forPriority p: Int) -> String {
        switch p {
        case 1: return "Urgente"
        case 2: return "Alta"
        case 3: return "Normal"
        case 4: return "Baixa"
        default: return "Sem prioridade"
        }
    }

    private func priorityColor(_ p: Int) -> Color {
        // Editorial-muted priority palette — same densified hexes
        // used by the task list / create form.
        switch p {
        case 1: return Color(hex: "#A8392A")
        case 2: return Color(hex: "#9A7B1F")
        case 3: return Color(hex: "#56708A")
        case 4: return Color(hex: "#A8A39A")
        default: return Editorial.inkMute
        }
    }

    private func tagTint(_ name: String) -> Color {
        if let tag = appState.availableTags.first(where: { $0.name == name }) {
            return Color(hex: tag.background)
        }
        return .accentColor
    }
}

// MARK: - Flow layout (chips wrap to new lines as needed)

/// Wraps subviews to multiple lines when they overflow the container's
/// width. Used for the multi-select chip groups in the filter popover.
struct FlowLayout: Layout {
    var spacing:     CGFloat = 6   // horizontal gap between chips
    var lineSpacing: CGFloat = 6   // vertical gap between rows

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.reduce(0) { acc, row in acc + row.height } +
                     CGFloat(max(rows.count - 1, 0)) * lineSpacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = subviews[item.index].sizeThatFits(.unspecified)
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            let needed = (rows[rows.count - 1].items.isEmpty ? 0 : spacing) + s.width
            if rows[rows.count - 1].width + needed > maxWidth, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            if !row.items.isEmpty { row.width += spacing }
            row.items.append((index: i, size: s))
            row.width += s.width
            row.height = max(row.height, s.height)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

// MARK: - Triangle (popover notch)
//
// Plain upward-pointing isosceles triangle. Drawn as a separate overlay
// above the popover's rounded body — keeping the body shape a vanilla
// `RoundedRectangle` is important because NSScrollView's macOS layout
// helper crashes if the hosting view's clipShape is a custom non-trivial
// path (`NSViewGetTransformToDescendant` assertion failure).
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))   // top tip
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)) // bottom-right
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)) // bottom-left
        p.closeSubpath()
        return p
    }
}
