import SwiftUI

/// Multi-dimensional filter UI for the task list. Opens from the
/// "Filtros" button in the toolbar. Each dimension is a collapsible
/// section with chip-style multi-select. Status keeps its existing
/// horizontal-bar UI in the dashboard — this popover handles the
/// other four dimensions.
struct TaskFilterPopover: View {
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

    private static let popoverWidth: CGFloat = 320
    private static let cornerRadius: CGFloat = 18
    private static let notchWidth:   CGFloat = 18
    private static let notchHeight:  CGFloat = 8

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
        VStack(spacing: 0) {
            header

            // Body wrapped in a solid surface that hides the
            // popup-level material — header alone reads as
            // translucent glass.
            ScrollablePopupContent(maxHeight: scrollMaxHeight) {
                VStack(alignment: .leading, spacing: 16) {
                    dueSection
                    if !availablePriorities.isEmpty {
                        prioritySection
                    }
                    if !appState.availableMembers.isEmpty {
                        assigneeSection
                    }
                    if !availableTagNames.isEmpty {
                        tagsSection
                    }
                    if !availableCreators.isEmpty {
                        creatorSection
                    }
                    createdSection
                    if hasClosedDates {
                        closedSection
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: Self.popoverWidth)
        .fixedSize(horizontal: false, vertical: true)
        .popupGlass(shape)
        .overlay(alignment: .topLeading) { notchView }
    }

    /// Small upward triangle floating above the popover, drop-shadow
    /// matched to the popover's so the seam reads as one unit.
    private var notchView: some View {
        Triangle()
            .fill(.ultraThinMaterial)
            .overlay(
                Triangle().stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.55), .white.opacity(0.10)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.6
                )
            )
            .frame(width: Self.notchWidth, height: Self.notchHeight)
            // -y so the triangle pokes above the popover's top edge by
            // its full height; +1 of overlap so the seam between the
            // triangle's base and the popover's rounded top is hidden.
            .offset(x: notchX - Self.notchWidth / 2, y: -Self.notchHeight + 1)
            .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: -1)
            .allowsHitTesting(false)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15))
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(Color.accentColor)
                    .font(.callout.weight(.semibold))
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("Filtros")
                    .font(.headline.weight(.semibold))
                let n = appState.taskFilters.activeDimensionCount
                Text(n == 0 ? "Refine a lista de tarefas" : "\(n) dimensão" + (n == 1 ? "" : "s") + " ativa" + (n == 1 ? "" : "s"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !appState.taskFilters.isEmpty {
                Button {
                    withAnimation(.spring(duration: 0.2)) {
                        appState.taskFilters = TaskFilters()
                    }
                } label: {
                    Text("Limpar")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain).focusEffectDisabled()
            }

            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain).focusEffectDisabled()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Section: Vencimento

    private var dueSection: some View {
        sectionContainer(title: "Vencimento", systemImage: "calendar.badge.clock") {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(DueWindow.allCases) { w in
                    chipToggle(
                        label:    w.label,
                        icon:     w.systemImage,
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
                        label:    label(forPriority: p),
                        tint:     priorityColor(p),
                        isActive: appState.taskFilters.priorities.contains(p)
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
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 2)
                } else {
                    Text("Digite para buscar entre \(appState.availableMembers.count) pessoas.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
                                label:    name,
                                tint:     tagTint(name),
                                isActive: appState.taskFilters.tagNames.contains(name)
                            ) {
                                toggle(&appState.taskFilters.tagNames, name)
                            }
                        }
                    }
                } else if !q.isEmpty {
                    Text("Nenhuma etiqueta corresponde.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 2)
                } else {
                    Text("Digite ou abra a lista pra escolher entre \(availableTagNames.count) etiquetas.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Color.gray.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.gray.opacity(0.18), lineWidth: 0.6)
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
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 2)
                } else {
                    Text("Digite para buscar entre \(availableCreators.count) pessoas.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(hasQuery ? Color.accentColor : .secondary)
            TextField(placeholder, text: query)
                .textFieldStyle(.plain)
                .font(.caption)
                .foregroundStyle(.primary)
                .focusEffectDisabled()
            if hasQuery {
                Button { query.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, hasQuery ? 4 : 8)
        .frame(height: 26)
        .background(Color.gray.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    hasQuery ? Color.accentColor.opacity(0.30)
                             : Color.gray.opacity(0.18),
                    lineWidth: 0.6
                )
        )
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

    private func sectionContainer<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    // MARK: - Chip

    @ViewBuilder
    private func chipToggle(label: String,
                            icon: String? = nil,
                            tint: Color = .accentColor,
                            avatar: CUMember? = nil,
                            isActive: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.spring(duration: 0.18)) { action() } }) {
            HStack(spacing: 5) {
                if let avatar {
                    chipAvatar(avatar)
                } else if let icon {
                    Image(systemName: icon).font(.caption2)
                }
                Text(label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? tint : Color.primary.opacity(0.8))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                isActive ? AnyShapeStyle(tint.opacity(0.14)) : AnyShapeStyle(Color.gray.opacity(0.08)),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    isActive ? tint.opacity(0.55) : Color.gray.opacity(0.18),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func chipAvatar(_ m: CUMember) -> some View {
        let bg = m.color.flatMap { Color(hex: $0) } ?? .blue
        return ZStack {
            Circle().fill(bg)
            if let pic = m.profilePicture, let url = URL(string: pic) {
                CachedAvatar(url: url).clipShape(Circle())
            } else {
                Text(m.initials ?? String(m.username.prefix(2)).uppercased())
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
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
        switch p {
        case 1: return Color(hex: "#F50000")
        case 2: return Color(hex: "#FFCC00")
        case 3: return Color(hex: "#6FDDFF")
        case 4: return Color(hex: "#87909E")
        default: return .gray
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
