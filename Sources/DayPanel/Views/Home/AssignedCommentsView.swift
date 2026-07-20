import AppKit
import SwiftUI

/// Global task-comment action list inspired by ClickUp's Assigned Comments
/// surface, rebuilt with Apollo's compact Liquid Glass capsule language.
struct AssignedCommentsView: View {
    @EnvironmentObject private var appState: AppState

    private enum Tab: String, CaseIterable {
        case assigned = "Atribuídos a mim"
        case delegated = "Delegados por mim"
    }

    private enum Kind: String, CaseIterable {
        case all = "Tudo"
        case assigned = "Atribuídos"
        case mentions = "Menções"
    }

    private enum Period: String, CaseIterable {
        case thirty = "Últimos 30 dias"
        case sixty = "Últimos 60 dias"
        case ninety = "Últimos 90 dias"
        case oneEighty = "Últimos 180 dias"
        case all = "Todo o período"

        var days: Int? {
            switch self {
            case .thirty: 30
            case .sixty: 60
            case .ninety: 90
            case .oneEighty: 180
            case .all: nil
            }
        }
    }

    @State private var tab: Tab = .assigned
    @State private var kind: Kind = .all
    @State private var period: Period = .ninety
    @State private var includeResolved = false
    @State private var query = ""
    @State private var savedIds = AssignedCommentPreferences.savedIds
    @State private var readIds = AssignedCommentPreferences.readIds
    @State private var reminders = AssignedCommentPreferences.reminders
    /// Altura medida do header sobreposto — recuo do topo do conteúdo (os
    /// cards descansam abaixo, mas rolam por trás até o topo da janela).
    @State private var headerBarHeight: CGFloat = 96

    private var me: Int? { appState.clickUpAuthService.userId }
    private var myUsername: String {
        guard let me else { return appState.clickUpAuthService.userName ?? "" }
        return appState.availableMembers.first { $0.id == me }?.username
            ?? appState.clickUpAuthService.userName ?? ""
    }

    private var filtered: [AssignedCommentRecord] {
        guard let me else { return [] }
        let threshold = period.days.flatMap {
            Calendar.current.date(byAdding: .day, value: -$0, to: Date())
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Os FILTROS do painel lateral valem aqui: um comentário só aparece
        // se a TAREFA dele passa nos taskFilters ativos (prioridade,
        // responsável, etiquetas, datas…).
        let sidebarFilters = appState.taskFilters
        let passingTaskIds: Set<String>? = sidebarFilters.isEmpty ? nil : {
            let tasks = Array(Set(appState.assignedCommentRecords.map(\.task.id)))
                .compactMap { id in appState.assignedCommentRecords.first { $0.task.id == id }?.task }
            return Set(sidebarFilters.applying(to: tasks).map(\.id))
        }()
        return appState.assignedCommentRecords.filter { record in
            if let passingTaskIds, !passingTaskIds.contains(record.task.id) { return false }
            let belongs: Bool
            switch tab {
            case .assigned:
                belongs = record.isAssigned(to: me)
                    || record.mentions(username: myUsername)
            case .delegated:
                belongs = record.wasDelegated(by: me)
            }
            guard belongs else { return false }
            if !includeResolved && record.comment.resolved { return false }
            if let threshold, record.comment.date < threshold { return false }
            switch kind {
            case .all: break
            case .assigned:
                if record.comment.assignee == nil { return false }
            case .mentions:
                if !record.mentions(username: myUsername) { return false }
            }
            guard !needle.isEmpty else { return true }
            return record.task.title.localizedCaseInsensitiveContains(needle)
                || record.comment.text.localizedCaseInsensitiveContains(needle)
                || (record.comment.userName?.localizedCaseInsensitiveContains(needle) == true)
        }
        .sorted { $0.comment.date > $1.comment.date }
    }

    var body: some View {
        // ZStack (não safeAreaInset!): o scroll ocupa a janela INTEIRA
        // (viewport até y=0) e o header é sobreposto. O descanso do conteúdo
        // abaixo do header vem de contentMargins DENTRO do scroll — um card
        // rolando pra cima viaja até o topo REAL da janela sem sair do
        // viewport. Com safeAreaInset o viewport encolhia e o LazyVStack
        // DESCARTAVA o card ao cruzar o limite ("comentários somem" em vez de
        // passar por trás do header) — mesmo bug/fix do Quadro.
        ZStack(alignment: .top) {
            content

            // UMA linha só: título + abas + filtro compacto + busca +
            // progresso + atualizar. Os FILTROS do painel lateral também
            // valem aqui (aplicados à tarefa de cada comentário).
            header
                .padding(.top, 52)   // toolbar band — same element
                // The comments route is inset around the 220pt floating
                // sidebar, but the native titlebar material is window chrome
                // and therefore continues underneath that pane to x = 0.
                .finderHeaderMaterial(leadingExtension: 220)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Editorial.rule.opacity(0.6)).frame(height: 1)
                        .padding(.leading, -220)
                }
                .background(
                    GeometryReader { g in
                        Color.clear
                            .onAppear { headerBarHeight = g.size.height }
                            .onChange(of: g.size.height) { _, h in
                                headerBarHeight = h
                            }
                    }
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Editorial.paper)
        .task {
            if appState.assignedCommentRecords.isEmpty {
                await appState.refreshAssignedComments()
            }
        }
        .apolloStudioNode("comments.page",
                          title: "Página de comentários",
                          kind: .page,
                          parent: "app.root",
                          properties: [
                            .init(kind: .verticalPadding,
                                  title: "Respiro do conteúdo", value: 30),
                            .init(kind: .material,
                                  title: "Material do header", token: "Materials.finderHeader"),
                          ])
    }

    /// Single-row identity band: title, scope tabs, live scan progress and
    /// refresh all share one line so the header stays two rows tall (this row
    /// + the filter toolbar) instead of the previous four.
    private var header: some View {
        HStack(spacing: 12) {
            // Título "Comentários atribuídos" removido — as abas já dizem
            // onde estamos; o espaço vai pro conteúdo.
            HStack(spacing: 6) {
                ForEach(Tab.allCases, id: \.self) { option in
                    Button { tab = option } label: {
                        Text(option.rawValue)
                            .font(Editorial.sans(12, tab == option ? .semibold : .medium))
                            .foregroundStyle(tab == option ? Editorial.ink : Editorial.inkMute)
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                    }
                    .buttonStyle(.plain)
                    .liquidGlassSelected(tab == option,
                                         in: Capsule(style: .continuous),
                                         tint: Editorial.accent,
                                         tintOpacity: 0.07)
                }
            }
            .padding(.leading, 6)

            Spacer(minLength: 12)

            // Filtro compacto (tipo + resolvidos + período) — sem linha própria.
            Menu {
                Picker("Tipo", selection: $kind) {
                    ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("Incluir resolvidos", isOn: $includeResolved)
                Picker("Período", selection: $period) {
                    ForEach(Period.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(filtersTouched ? Editorial.accent : Editorial.inkSoft)
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .liquidGlassCapsule(tint: Editorial.accent,
                                tintOpacity: filtersTouched ? 0.10 : 0.05)
            .help("Filtro: tipo, resolvidos e período")

            // Busca subiu pra linha do título (a linha extra morreu).
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Editorial.inkMute)
                TextField("Pesquisar comentários", text: $query)
                    .textFieldStyle(.plain)
                    .font(Editorial.sans(12))
                    .frame(width: 190)
            }
            .padding(.horizontal, 13)
            .frame(height: 30)
            .liquidGlassCapsule(tint: Editorial.accent, tintOpacity: 0.035)

            if appState.assignedCommentsLoading
                || appState.assignedCommentsScannedTasks < appState.assignedCommentsTotalTasks {
                HStack(spacing: 8) {
                    if appState.assignedCommentsLoading {
                        ProgressView().controlSize(.small)
                    }
                    Text("\(appState.assignedCommentsScannedTasks)/\(appState.assignedCommentsTotalTasks)")
                        .font(Editorial.sans(10.5, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Editorial.inkMute)
                }
                .help("Tarefas verificadas em lotes de 30")
            }
            Button {
                Task { await appState.refreshAssignedComments() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .liquidGlassCapsule(tint: Editorial.accent, tintOpacity: 0.05)
            .help("Atualizar comentários")
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 11)
        .apolloStudioNode("comments.header",
                          title: "Header de comentários",
                          kind: .header,
                          parent: "comments.page",
                          properties: [
                            .init(kind: .horizontalPadding,
                                  title: "Padding horizontal", value: 28),
                            .init(kind: .spacing, title: "Espaçamento", value: 12),
                          ])
    }

    /// Algum filtro do menu compacto fora do padrão? (colore o ícone)
    private var filtersTouched: Bool {
        kind != .all || includeResolved || period != .ninety
    }

    /// One geometry for every toolbar action. Menu controls have a smaller
    /// native intrinsic height than plain Buttons on macOS; the explicit
    /// outer 32pt frame above plus this shared label prevents that platform
    /// difference from leaking into Apollo's visual rhythm.
    private func toolbarCapsuleLabel(_ title: String,
                                     icon: String,
                                     tone: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 15, height: 15)
                .foregroundStyle(tone)
            Text(title)
                .font(Editorial.sans(12, .medium))
                .lineLimit(1)
                .foregroundStyle(Editorial.ink)
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .contentShape(Capsule(style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        if me == nil {
            empty(icon: "person.crop.circle.badge.exclamationmark",
                  title: "Conecte o ClickUp",
                  caption: "Entre na sua conta para carregar comentários atribuídos.")
        } else if filtered.isEmpty && appState.assignedCommentsLoading {
            // Actively scanning with nothing yet — show a breathing skeleton,
            // never the "Tudo em ordem" empty state (which read as "you have
            // zero comments" while the index was still being built).
            skeletonList
        } else if filtered.isEmpty && appState.assignedCommentsHasMore {
            // Auto-scan window finished without a match, but tasks remain — be
            // honest that the search isn't exhausted instead of claiming order.
            VStack(spacing: 14) {
                empty(icon: "text.magnifyingglass",
                      title: "Nada neste intervalo ainda",
                      caption: "Ainda há tarefas para verificar. Continue a busca quando quiser.")
                loadMoreButton
                    .padding(.bottom, 80)
            }
        } else if filtered.isEmpty {
            empty(icon: "checkmark.bubble",
                  title: "Tudo em ordem",
                  caption: "Nenhum comentário corresponde aos filtros atuais.")
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(filtered) { record in
                        AssignedCommentCard(
                            record: record,
                            isRead: readIds.contains(record.id),
                            isSaved: savedIds.contains(record.id),
                            reminder: reminders[record.id].map(Date.init(timeIntervalSince1970:)),
                            onToggleRead: { toggle(record.id, in: &readIds, kind: .read) },
                            onToggleSaved: { toggle(record.id, in: &savedIds, kind: .saved) },
                            onRemind: { date in
                                reminders[record.id] = date.timeIntervalSince1970
                                AssignedCommentPreferences.reminders = reminders
                            }
                        )
                        .environmentObject(appState)
                    }
                    if appState.assignedCommentsHasMore
                        || appState.assignedCommentsLoading {
                        loadMoreButton
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 4)
                .padding(.bottom, 80)
            }
            .scrollIndicators(.never)
            // Margens de CONTEÚDO (não padding/safeArea!): o viewport alcança
            // y=0, o conteúdo descansa abaixo do header e, ao rolar, viaja por
            // dentro da margem até o topo REAL da janela — sempre dentro do
            // viewport, então o LazyVStack não descarta o card no caminho.
            .contentMargins(.top, headerBarHeight + 30, for: .scrollContent)
            // Sombras/hover podem desenhar além dos limites do scroll.
            .scrollClipDisabled()
        }
    }

    /// Breathing placeholder cards shown while the index is being built, so
    /// the surface reads as "loading" rather than "empty".
    private var skeletonList: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(0..<5, id: \.self) { _ in CommentSkeletonCard() }
            }
            .padding(.horizontal, 28)
            .padding(.top, 4)
        }
        .scrollIndicators(.never)
        .allowsHitTesting(false)
        .contentMargins(.top, headerBarHeight + 30, for: .scrollContent)
    }

    private var loadMoreButton: some View {
        Button {
            Task { await appState.loadNextAssignedCommentsPage() }
        } label: {
            HStack(spacing: 8) {
                if appState.assignedCommentsLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle")
                }
                Text(appState.assignedCommentsLoading
                     ? "Verificando próximo lote…"
                     : "Carregar mais 30")
                    .font(Editorial.sans(12, .semibold))
            }
            .padding(.horizontal, 15)
            .frame(height: 34)
        }
        .buttonStyle(.plain)
        .disabled(appState.assignedCommentsLoading)
        .liquidGlassCapsule(tint: Editorial.accent,
                            tintOpacity: 0.05,
                            interactive: !appState.assignedCommentsLoading)
    }

    private func empty(icon: String, title: String, caption: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Editorial.inkMute)
            Text(title).font(Editorial.sans(16, .semibold))
            Text(caption)
                .font(Editorial.sans(12))
                .foregroundStyle(Editorial.inkMute)
        }
        .foregroundStyle(Editorial.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private enum PreferenceKind { case read, saved }
    private func toggle(_ id: String,
                        in set: inout Set<String>,
                        kind: PreferenceKind) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        switch kind {
        case .read: AssignedCommentPreferences.readIds = set
        case .saved: AssignedCommentPreferences.savedIds = set
        }
    }
}

/// Identical material and outline for every Assigned Comments filter.
/// Semantic state lives in the icon tone, never in a heavier surface.
private struct AssignedCommentsToolbarCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content
            .liquidGlassCapsule(tint: Editorial.ink,
                                tintOpacity: 0.012,
                                interactive: false,
                                lightweight: true)
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Editorial.rule.opacity(0.75), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
    }
}

/// One loading placeholder that mirrors an `AssignedCommentCard`'s layout and
/// breathes so the wait reads as progress, not emptiness.
private struct CommentSkeletonCard: View {
    @State private var dim = false
    private var bar: Color { Editorial.ink.opacity(0.09) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(bar).frame(width: 8, height: 8)
                RoundedRectangle(cornerRadius: 4).fill(bar).frame(width: 150, height: 11)
                Spacer(minLength: 12)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(bar).frame(width: 88, height: 22)
            }
            HStack(alignment: .top, spacing: 12) {
                Circle().fill(bar).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 9) {
                    RoundedRectangle(cornerRadius: 4).fill(bar).frame(width: 120, height: 10)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(bar).frame(maxWidth: .infinity).frame(height: 34)
                }
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Editorial.card))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Editorial.rule.opacity(0.5), lineWidth: 0.7))
        .opacity(dim ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
    }
}

private struct AssignedCommentCard: View {
    @EnvironmentObject private var appState: AppState
    let record: AssignedCommentRecord
    let isRead: Bool
    let isSaved: Bool
    let reminder: Date?
    let onToggleRead: () -> Void
    let onToggleSaved: () -> Void
    let onRemind: (Date) -> Void

    @State private var showThread = false
    @State private var replies: [CUComment] = []
    @State private var draft = ""
    @State private var sending = false

    private var tint: Color { Color(statusHex: record.task.statusDisplayHex) }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
    }

    // Review context so the shared CommentBodyView can render REVIEW / "Ver
    // review" affordances exactly like the task Activity tab.
    private var reviewActorId: Int? { appState.clickUpAuthService.userId }
    private var reviewActorName: String {
        let id = appState.clickUpAuthService.userId
        return appState.availableMembers.first { $0.id == id }?.username ?? "Revisor"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            taskHeader
            commentBody
            if showThread { thread }
        }
        // Solid card — no Liquid Glass material. A flat `page` surface with a
        // hairline and a soft neutral shadow; status colour stays in the dot.
        .background(shape.fill(Editorial.page))
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Editorial.rule.opacity(0.7), lineWidth: 0.7)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.05), radius: 2.5, y: 1)
        .contextMenu { contextMenu }
        .accessibilityElement(children: .contain)
        .apolloStudioNode(
            StudioNodeID(rawValue: "comments.card.\(record.id)"),
            title: record.task.title,
            kind: .card,
            parent: "comments.page",
            properties: [
                .init(kind: .cornerRadius, title: "Raio", value: 11),
                .init(kind: .shadowRadius, title: "Sombra", value: 2.5),
                .init(kind: .shadowY, title: "Sombra Y", value: 1),
            ]
        )
    }

    private var taskHeader: some View {
        HStack(spacing: 10) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(record.task.title)
                .font(Editorial.sans(13.5, isRead ? .medium : .semibold))
                .foregroundStyle(Editorial.ink)
                .lineLimit(1)
            Spacer(minLength: 12)
            assignmentSummary
            if record.comment.assignee != nil {
                Button {
                    Task {
                        _ = await appState.setAssignedCommentResolved(
                            record, resolved: !record.comment.resolved)
                    }
                } label: {
                    Label(record.comment.resolved ? "Reabrir" : "Resolver",
                          systemImage: record.comment.resolved
                            ? "arrow.uturn.backward" : "checkmark")
                        .font(Editorial.sans(11.5, .semibold))
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                }
                .buttonStyle(.plain)
                .liquidGlassCapsule(tint: record.comment.resolved ? Editorial.accent : .green,
                                    tintOpacity: 0.08)
            }
        }
        .padding(.horizontal, 17)
        .padding(.top, 13)
        .padding(.bottom, 9)
        .contentShape(Rectangle())
        .onTapGesture { openTask() }
    }

    @ViewBuilder
    private var assignmentSummary: some View {
        if let assignee = record.comment.assignee {
            HStack(spacing: 6) {
                Text("Atribuído a")
                    .foregroundStyle(Editorial.inkMute)
                participantAvatar(assignee, size: 20)
                Text(assignee.id == appState.clickUpAuthService.userId
                     ? "Eu" : assignee.username)
                    .foregroundStyle(Editorial.ink)
                if let by = record.comment.assignedBy {
                    Text("por \(by.username)")
                        .foregroundStyle(Editorial.inkMute)
                }
            }
            .font(Editorial.sans(10.5, .medium))
        } else {
            Label("Menção", systemImage: "at")
                .font(Editorial.sans(10.5, .semibold))
                .foregroundStyle(tint)
        }
    }

    private var commentBody: some View {
        HStack(alignment: .top, spacing: 12) {
            UserAvatar(initials: record.comment.initials ?? initials(record.comment.userName),
                       colorHex: record.comment.userColor,
                       photoURL: record.comment.profilePic.flatMap(URL.init(string:)),
                       size: 34)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(record.comment.userName ?? "Pessoa")
                        .font(Editorial.sans(12.5, .semibold))
                    Text(record.comment.date.formatted(date: .abbreviated,
                                                       time: .shortened))
                        .font(Editorial.sans(10.5))
                        .foregroundStyle(Editorial.inkMute)
                    if isSaved {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Editorial.accent)
                    }
                    if let reminder {
                        Label(reminder.formatted(date: .abbreviated, time: .shortened),
                              systemImage: "alarm")
                            .font(Editorial.sans(9.5, .medium))
                            .foregroundStyle(Editorial.inkMute)
                    }
                }
                // Full renderer (same as the task Activity tab): URLs become
                // typed attachment cards, the REVISAR/Ver-review link becomes a
                // clickable button, @mentions highlight — never raw markdown.
                CommentBodyView(text: record.comment.text,
                                attachments: record.comment.attachments,
                                mentionUsernames: appState.availableMembers.map(\.username),
                                reviewTaskId: record.task.id,
                                reviewListId: record.task.listId,
                                reviewActorId: reviewActorId,
                                reviewActorName: reviewActorName,
                                reviewCommentId: record.comment.id)
                    .equatable()
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 7) {
                    ForEach(record.comment.reactions, id: \.emoji) { reaction in
                        Button {
                            Task { _ = await appState.toggleAssignedCommentReaction(record,
                                                                                    emoji: reaction.emoji) }
                        } label: {
                            Text("\(reaction.emoji) \(reaction.userIds.count)")
                                .font(Editorial.sans(10.5, .medium))
                                .padding(.horizontal, 8)
                                .frame(height: 23)
                        }
                        .buttonStyle(.plain)
                        .liquidGlassCapsule(tint: tint, tintOpacity: 0.05)
                    }
                    reactionMenu
                    Button {
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                            showThread.toggle()
                        }
                        if showThread && replies.isEmpty {
                            Task { replies = await appState.loadReplies(for: record.id) }
                        }
                    } label: {
                        Label(record.comment.replyCount > 0
                              ? "\(record.comment.replyCount) respostas" : "Responder",
                              systemImage: "arrowshape.turn.up.left")
                            .font(Editorial.sans(10.5, .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Editorial.accent)
                    Spacer()
                    Button(action: openTask) {
                        Label("Abrir tarefa", systemImage: "arrow.up.right")
                            .font(Editorial.sans(10.5, .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Editorial.accent)
                }
            }
        }
        .padding(.horizontal, 17)
        .padding(.bottom, 14)
    }

    private var reactionMenu: some View {
        Menu {
            ForEach(["👍", "❤️", "🔥", "👏", "🎯", "👀"], id: \.self) { emoji in
                Button(emoji) {
                    Task { _ = await appState.toggleAssignedCommentReaction(record, emoji: emoji) }
                }
            }
        } label: {
            Image(systemName: "face.smiling")
                .font(.system(size: 11))
                .frame(width: 24, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var thread: some View {
        VStack(alignment: .leading, spacing: 9) {
            Rectangle().fill(Editorial.rule.opacity(0.55)).frame(height: 1)
            ForEach(replies) { reply in
                HStack(alignment: .top, spacing: 9) {
                    UserAvatar(initials: reply.initials ?? initials(reply.userName),
                               colorHex: reply.userColor,
                               photoURL: reply.profilePic.flatMap(URL.init(string:)),
                               size: 25)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reply.userName ?? "Pessoa")
                            .font(Editorial.sans(10.5, .semibold))
                        CommentBodyView(text: reply.text,
                                        attachments: reply.attachments,
                                        mentionUsernames: appState.availableMembers.map(\.username),
                                        reviewTaskId: record.task.id,
                                        reviewListId: record.task.listId,
                                        reviewActorId: reviewActorId,
                                        reviewActorName: reviewActorName,
                                        reviewCommentId: reply.id)
                            .equatable()
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Responder no tópico…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Editorial.sans(11.5))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .liquidGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                                 tint: tint, tintOpacity: 0.03)
                Button {
                    sendReply()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 29, height: 29)
                }
                .buttonStyle(.plain)
                .liquidGlassCapsule(tint: Editorial.accent, tintOpacity: 0.10)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            }
        }
        .padding(.horizontal, 17)
        .padding(.bottom, 14)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Curtir", systemImage: "hand.thumbsup") {
            Task { _ = await appState.toggleAssignedCommentReaction(record, emoji: "👍") }
        }
        Menu("Adicionar reação", systemImage: "face.smiling") {
            ForEach(["❤️", "🔥", "👏", "🎯", "👀"], id: \.self) { emoji in
                Button(emoji) {
                    Task { _ = await appState.toggleAssignedCommentReaction(record, emoji: emoji) }
                }
            }
        }
        Divider()
        Button(isSaved ? "Remover de salvos" : "Salvar para depois",
               systemImage: isSaved ? "bookmark.slash" : "bookmark",
               action: onToggleSaved)
        Button("Encaminhar", systemImage: "square.and.arrow.up") { share() }
        Menu("Atribuir", systemImage: "person.badge.plus") {
            ForEach(appState.availableMembers, id: \.id) { member in
                Button(member.username) {
                    Task { _ = await appState.assignComment(record, to: member) }
                }
            }
        }
        Divider()
        Button(isRead ? "Marcar como não lido" : "Marcar como lido",
               systemImage: isRead ? "envelope.badge" : "envelope.open",
               action: onToggleRead)
        Button("Copiar link", systemImage: "link") { copyLink() }
        Divider()
        Menu("Lembrar mais tarde", systemImage: "alarm") {
            Button("Em 1 hora") { remind(hours: 1) }
            Button("Amanhã") { remind(hours: 24) }
            Button("Próxima semana") { remind(hours: 24 * 7) }
        }
    }

    private func participantAvatar(_ participant: CUComment.Participant,
                                   size: CGFloat) -> some View {
        UserAvatar(initials: participant.initials ?? initials(participant.username),
                   colorHex: participant.color,
                   photoURL: participant.profilePicture.flatMap(URL.init(string:)),
                   size: size)
    }

    private func initials(_ name: String?) -> String {
        let parts = (name ?? "?").split(separator: " ")
        return parts.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    private func openTask() {
        appState.openTaskDetail(record.task,
                                origin: MouseOriginCapture.currentClickRectInMainWindow(),
                                navigationTasks: appState.tasks,
                                style: .bottomSlide)
    }

    private func sendReply() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        Task {
            if let reply = await appState.reply(to: record.id, text: text) {
                await MainActor.run {
                    replies.append(reply)
                    draft = ""
                    sending = false
                }
            } else {
                await MainActor.run { sending = false }
            }
        }
    }

    private func commentURL() -> URL? {
        guard let base = record.task.url, !base.isEmpty else { return nil }
        let separator = base.contains("?") ? "&" : "?"
        return URL(string: "\(base)\(separator)comment=\(record.id)")
    }

    private func copyLink() {
        guard let url = commentURL() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func share() {
        var items: [Any] = ["\(record.task.title)\n\n\(record.comment.text)"]
        if let url = commentURL() { items.append(url) }
        guard let view = NSApp.keyWindow?.contentView else {
            copyLink(); return
        }
        let picker = NSSharingServicePicker(items: items)
        picker.show(relativeTo: CGRect(x: view.bounds.midX, y: view.bounds.midY,
                                      width: 1, height: 1),
                    of: view, preferredEdge: .minY)
    }

    private func remind(hours: Double) {
        onRemind(Date().addingTimeInterval(hours * 3600))
    }
}

private enum AssignedCommentPreferences {
    private static let savedKey = "apollo.assignedComments.saved"
    private static let readKey = "apollo.assignedComments.read"
    private static let reminderKey = "apollo.assignedComments.reminders"

    static var savedIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: savedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: savedKey) }
    }
    static var readIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: readKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: readKey) }
    }
    static var reminders: [String: TimeInterval] {
        get { UserDefaults.standard.dictionary(forKey: reminderKey) as? [String: TimeInterval] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: reminderKey) }
    }
}
