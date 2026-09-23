import SwiftUI
import AppKit

// MARK: - ClickUp List Picker

struct CUListPickerSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    /// Optional explicit close callback. Used when the picker is
    /// presented via `FloatingModal` (the toolbar pill route),
    /// where `@Environment(\.dismiss)` doesn't reach a sheet
    /// parent and would otherwise propagate up to close the
    /// whole window. Settings/Onboarding present via `.sheet()`
    /// and pass `nil`, falling back to the system dismiss.
    var onClose: (() -> Void)? = nil

    /// When true, render the toolbar DROPDOWN form: one narrow
    /// column at a time (Workspace → Space → Lista) with a
    /// tappable breadcrumb to step back, instead of the wide
    /// 3-column tree used by Settings / Onboarding.
    var compact: Bool = false

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    @State private var workspaces: [CUWorkspace] = []
    @State private var spaces:     [CUSpace]     = []
    @State private var lists:      [CUList]      = []
    @State private var selectedWorkspace: CUWorkspace?
    @State private var selectedSpace:     CUSpace?
    @State private var selectedListId = KeychainHelper.load(for: KeychainHelper.Keys.clickupListId) ?? ""
    @State private var loadingWorkspaces = false
    @State private var loadingSpaces     = false
    @State private var loadingLists      = false
    /// True while we're walking the workspace → space → list tree
    /// on first open to auto-select the previously-saved list.
    /// Drives the spinner shown in all three columns during the
    /// restore so the user knows the picker is working.
    @State private var restoringSelection = false
    @State private var error: String?
    @State private var listFilter: String = ""
    /// Pinned lists, mirrored from `PinnedLists` so the row
    /// pins + the "Fixadas" section re-render on toggle.
    @State private var pinned: [PinnedLists.Entry] = PinnedLists.load()

    private var svc: ClickUpService { ClickUpService(auth: appState.clickUpAuthService) }

    private func togglePin(_ list: CUList) {
        PinnedLists.toggle(id: list.id, name: list.name)
        pinned = PinnedLists.load()
    }

    private func isPinned(_ id: String) -> Bool {
        pinned.contains { $0.id == id }
    }

    private var filteredLists: [CUList] {
        let q = listFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return lists }
        return lists.filter { $0.name.lowercased().contains(q) }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Editorial.popupRadius(9), style: .continuous)
    }

    var body: some View {
        Group {
            if compact { compactBody } else { wideBody }
        }
        // This picker is an opaque panel, independent of page-header materials.
        // Clip only its background so nested AppKit scroll views stay intact.
        .background {
            shape.fill(Editorial.page)
                .shadow(color: .black.opacity(0.18), radius: 28, y: 12)
        }
        .overlay {
            shape.strokeBorder(Editorial.rule, lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .task { await loadWorkspaces() }
    }

    // MARK: - Wide (Settings / Onboarding) layout

    private var wideBody: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Editorial.rule).frame(height: 1)
            pinnedStrip
            columnsRow
            errorRow
            Rectangle().fill(Editorial.rule).frame(height: 1)
            footer
        }
        .frame(width: 760, height: 500)
    }

    // MARK: - Compact (toolbar dropdown) layout

    private var compactBody: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Editorial.rule).frame(height: 1)
            compactNavBar
            pinnedStrip
            compactColumn
            errorRow
        }
        .frame(width: 380, height: 480)
    }

    /// Step-back breadcrumb. Each crumb is tappable to climb back
    /// up the Workspace → Space → Lista path. Hidden at root.
    @ViewBuilder
    private var compactNavBar: some View {
        if selectedWorkspace != nil {
            HStack(spacing: 7) {
                Button {
                    selectedWorkspace = nil
                    selectedSpace     = nil
                    spaces = []; lists = []
                } label: {
                    crumb(selectedWorkspace?.name ?? "Workspace",
                          icon: "building.2", active: selectedSpace == nil)
                }
                .buttonStyle(.plain).focusEffectDisabled()

                if selectedSpace != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Editorial.inkFaint)
                    Button {
                        selectedSpace = nil
                        lists = []
                    } label: {
                        crumb(selectedSpace?.name ?? "Espaço",
                              icon: "square.grid.2x2", active: true)
                    }
                    .buttonStyle(.plain).focusEffectDisabled()
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Editorial.ruleSoft).frame(height: 1)
            }
        }
    }

    private func crumb(_ text: String, icon: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(Editorial.sans(11.5, .medium)).lineLimit(1)
        }
        .foregroundStyle(active ? Editorial.accent : Editorial.inkSoft)
    }

    /// One column at a time: deepest available level wins.
    @ViewBuilder
    private var compactColumn: some View {
        if selectedSpace != nil {
            listsColumn
        } else if selectedWorkspace != nil {
            spacesColumn
        } else {
            workspacesColumn
        }
    }

    private var columnsRow: some View {
        HStack(spacing: 0) {
            workspacesColumn.frame(width: 230)
            divider
            spacesColumn.frame(width: 230)
            divider
            listsColumn.frame(minWidth: 240)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var errorRow: some View {
        if let error {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Editorial.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Tentar novamente", systemImage: "arrow.clockwise") {
                    Task { await retryLoading() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .help("Tentar novamente")
                .disabled(isLoading)
            }
            .padding(12)
            .background(Editorial.paper, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var isLoading: Bool {
        loadingWorkspaces || loadingSpaces || loadingLists || restoringSelection
    }

    private func retryLoading() async {
        if let selectedSpace { await loadLists(for: selectedSpace) }
        else if let selectedWorkspace { await loadSpaces(for: selectedWorkspace) }
        else { await loadWorkspaces() }
    }

    private var workspacesColumn: some View {
        pickerColumn(title: "Workspaces", icon: "building.2",
                     count: workspaces.count, loading: loadingWorkspaces,
                     placeholder: workspaces.isEmpty
                        ? ("building.2", "Nenhum workspace disponível") : nil) {
            ForEach(workspaces) { ws in
                row(name: ws.name, icon: "building.2",
                    selected: selectedWorkspace?.id == ws.id,
                    action: { selectWorkspace(ws) })
            }
        }
    }

    private var spacesColumn: some View {
        pickerColumn(title: "Espaços", icon: "square.grid.2x2",
                     count: spaces.count, loading: loadingSpaces || restoringSelection,
                     scrollTarget: selectedSpace?.id,
                     placeholder: selectedWorkspace == nil
                        ? ("square.grid.2x2", "Escolha um workspace para ver seus espaços")
                        : (spaces.isEmpty ? ("square.grid.2x2", "Nenhum espaço disponível") : nil)) {
            ForEach(spaces) { sp in
                row(name: sp.name, icon: "square.grid.2x2",
                    selected: selectedSpace?.id == sp.id,
                    action: { selectSpace(sp) })
                    .id(sp.id)
            }
        }
    }

    // MARK: - Header & footer

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Selecionar lista")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Editorial.ink)
                Text("Escolha de onde o Apollo carrega suas tarefas.")
                    .font(.system(size: 12))
                    .foregroundStyle(Editorial.inkSoft)
            }
            Spacer(minLength: 0)
            Button("Fechar", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.regular)
                .keyboardShortcut(.cancelAction)
                .help("Fechar")
        }
        .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let name = currentListName, !name.isEmpty {
                Label {
                    Text("Lista atual: \(name)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "list.bullet.rectangle")
                }
                .font(.system(size: 12))
                .foregroundStyle(Editorial.inkSoft)
            } else {
                Text("Selecione uma lista para continuar")
                    .font(.system(size: 12))
                    .foregroundStyle(Editorial.inkSoft)
            }
            Spacer(minLength: 8)
            Button("Fechar", action: close)
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var currentListName: String? {
        lists.first(where: { $0.id == selectedListId })?.name
            ?? KeychainHelper.load(for: KeychainHelper.Keys.clickupListName)
    }

    // MARK: - Lists column (with search)

    private var listsColumn: some View {
        VStack(spacing: 0) {
            columnHeader(title: "Listas",
                         icon: "list.bullet.rectangle",
                         count: filteredLists.count)

            if selectedSpace != nil && !lists.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Editorial.inkMute)
                    TextField("Buscar lista", text: $listFilter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(Editorial.ink)
                }
                .padding(9)
                .background(Editorial.paper, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }

            ZStack {
                if loadingLists || (restoringSelection && selectedSpace == nil) {
                    ProgressView().controlSize(.small)
                } else if selectedSpace == nil {
                    emptyHint(icon: "list.bullet.rectangle", text: "Escolha um espaço para ver suas listas")
                } else if filteredLists.isEmpty {
                    emptyHint(icon: "list.bullet.rectangle",
                              text: lists.isEmpty
                              ? "Nenhuma lista neste espaço"
                              : "Nenhuma lista corresponde à busca")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(filteredLists) { list in
                                    listRow(list)
                                        .id(list.id)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                        }
                        // Auto-scroll the saved list into view when
                        // the column first paints (after the
                        // restore walks the tree). The 80ms delay
                        // gives the rows time to lay out so
                        // `scrollTo` actually has positions to
                        // jump to.
                        .task(id: selectedListId) {
                            guard !selectedListId.isEmpty,
                                  filteredLists.contains(where: { $0.id == selectedListId })
                            else { return }
                            try? await Task.sleep(nanoseconds: 80_000_000)
                            withAnimation(.easeInOut(duration: 0.20)) {
                                proxy.scrollTo(selectedListId, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Reusable bits

    private var divider: some View {
        Rectangle().fill(Editorial.rule).frame(width: 1)
    }

    @ViewBuilder
    private func pickerColumn<Content: View>(
        title: String, icon: String, count: Int, loading: Bool,
        scrollTarget: String? = nil,
        placeholder: (icon: String, text: String)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            columnHeader(title: title, icon: icon, count: count)

            ZStack {
                if loading {
                    ProgressView().controlSize(.small)
                } else if let placeholder {
                    emptyHint(icon: placeholder.icon, text: placeholder.text)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 4) {
                                content()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                        }
                        // Initial scroll once the ScrollView mounts
                        // (i.e. when ZStack flips off the spinner).
                        // The tiny delay gives the rows a frame to
                        // lay out — without it `scrollTo` fires
                        // before the layout pass and silently no-ops.
                        .task(id: scrollTarget) {
                            guard let id = scrollTarget else { return }
                            try? await Task.sleep(nanoseconds: 80_000_000)
                            withAnimation(.easeInOut(duration: 0.20)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func columnHeader(title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Editorial.inkSoft)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Editorial.ink)
            Spacer()
            if count > 0 {
                Text(count, format: .number)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Editorial.inkMute)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Editorial.paper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Editorial.ruleSoft).frame(height: 1)
        }
    }

    /// List row with a trailing pin control. The pin is a
    /// separate hit target from the main row body so clicking
    /// it toggles the pin WITHOUT also selecting the list.
    private func listRow(_ list: CUList) -> some View {
        ListPickerRow(
            name: list.name,
            icon: "list.bullet.rectangle",
            selected: selectedListId == list.id,
            pinned: isPinned(list.id),
            onPinToggle: { togglePin(list) },
            action: { pick(list) }
        )
    }

    private func row(name: String, icon: String, selected: Bool,
                     action: @escaping () -> Void) -> some View {
        ListPickerRow(name: name, icon: icon, selected: selected,
                      action: action)
    }

    private func emptyHint(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(Editorial.inkMute)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Editorial.inkMute)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 30)
    }

    // MARK: - Actions

    private func selectWorkspace(_ ws: CUWorkspace) {
        selectedWorkspace = ws
        selectedSpace     = nil
        spaces            = []
        lists             = []
        Task { await loadSpaces(for: ws) }
    }

    private func selectSpace(_ sp: CUSpace) {
        selectedSpace = sp
        lists         = []
        Task { await loadLists(for: sp) }
    }

    private func pick(_ list: CUList) {
        pickById(id: list.id, name: list.name)
    }

    /// Shared selection path — used by both the tree rows and
    /// the "Fixadas" quick-pick chips (which only have the
    /// cached id+name, not a full CUList / its parent space).
    private func pickById(id: String, name: String) {
        selectedListId = id
        appState.activateList(id: id, name: name)
        close()
    }

    /// Quick-pick strip of pinned lists. Renders above the
    /// workspace/space/list tree so the user's real working
    /// set is one click away without re-navigating. Hidden
    /// when nothing is pinned.
    @ViewBuilder
    private var pinnedStrip: some View {
        if !pinned.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Fixadas", systemImage: "pin.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Editorial.inkSoft)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pinned.sorted { $0.name < $1.name }) { entry in
                            Button {
                                pickById(id: entry.id, name: entry.name)
                            } label: {
                                Label(entry.name, systemImage: "list.bullet.rectangle")
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                            .tint(selectedListId == entry.id ? Editorial.accent : nil)
                            .help(entry.name)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }
                Divider()
            }
        }
    }

    /// When the picker reopens, walk the workspace → space → list
    /// tree until we find the previously-saved list and pre-select
    /// the workspace + space containing it. Without this the
    /// picker would open with the Spaces and Lista columns empty
    /// ("Escolha um workspace") even though the user has had a
    /// list active for weeks.
    ///
    /// ClickUp's API has no "get parents of list" endpoint, so we
    /// walk: for each workspace, fetch its spaces; for each space,
    /// fetch its lists in parallel; first match wins. Bounded in
    /// practice (typical Apollo user has 1 workspace, <10 spaces,
    /// <20 lists per space) — runs once per picker open.
    private func restoreSelectionFromSavedList() async {
        guard !selectedListId.isEmpty,
              selectedWorkspace == nil,
              !workspaces.isEmpty else { return }

        await MainActor.run { restoringSelection = true }
        defer { Task { @MainActor in restoringSelection = false } }

        for ws in workspaces {
            let spacesForWS: [CUSpace]
            do {
                spacesForWS = try await svc.getSpaces(workspaceId: ws.id)
            } catch { continue }

            // Fan out the per-space list fetches in parallel and
            // bail as soon as one of them contains the saved list.
            let match: (space: CUSpace, lists: [CUList])? = await withTaskGroup(
                of: (CUSpace, [CUList]?).self,
                returning: (CUSpace, [CUList])?.self
            ) { group in
                for sp in spacesForWS {
                    group.addTask {
                        let ls = try? await svc.getLists(spaceId: sp.id)
                        return (sp, ls)
                    }
                }
                for await (sp, ls) in group {
                    if let ls, ls.contains(where: { $0.id == selectedListId }) {
                        group.cancelAll()
                        return (sp, ls)
                    }
                }
                return nil
            }

            if let match {
                await MainActor.run {
                    self.selectedWorkspace = ws
                    self.spaces            = spacesForWS
                    self.selectedSpace     = match.space
                    self.lists             = match.lists
                }
                return
            }
        }

        // No match — the saved list may have been deleted in
        // ClickUp or the user lost access. Pre-select the only
        // workspace anyway so the picker isn't empty.
        if workspaces.count == 1, let only = workspaces.first {
            await MainActor.run { selectWorkspace(only) }
        }
    }

    // MARK: - Networking

    private func loadingErrorMessage(_ error: Error) -> String {
        if let clickUpError = error as? ClickUpService.CUError {
            switch clickUpError {
            case .notConfigured:
                return "Conecte sua conta ClickUp nos Ajustes para carregar suas listas."
            case .parse:
                return "Não foi possível ler as listas do ClickUp. Tente novamente."
            }
        }
        return "Não foi possível carregar as listas. Verifique sua conexão e tente novamente."
    }

    private func loadWorkspaces() async {
        loadingWorkspaces = true; error = nil
        do {
            let ws = try await svc.getWorkspaces()
            await MainActor.run { workspaces = ws; loadingWorkspaces = false }
            // Right after workspaces land, walk the tree to
            // surface the user's currently-selected list. Without
            // this the columns stay empty until the user clicks.
            await restoreSelectionFromSavedList()
        } catch {
            await MainActor.run { self.error = loadingErrorMessage(error); loadingWorkspaces = false }
        }
    }

    private func loadSpaces(for ws: CUWorkspace) async {
        loadingSpaces = true; error = nil
        do {
            let sp = try await svc.getSpaces(workspaceId: ws.id)
            await MainActor.run { spaces = sp; loadingSpaces = false }
        } catch {
            await MainActor.run { self.error = loadingErrorMessage(error); loadingSpaces = false }
        }
    }

    private func loadLists(for space: CUSpace) async {
        loadingLists = true; error = nil
        do {
            let ls = try await svc.getLists(spaceId: space.id)
            await MainActor.run { lists = ls; loadingLists = false }
        } catch {
            await MainActor.run { self.error = loadingErrorMessage(error); loadingLists = false }
        }
    }
}

// MARK: - List selection row

/// Selection and pinning remain separate keyboard-accessible actions.
private struct ListPickerRow: View {
    let name: String
    let icon: String
    let selected: Bool
    var pinned: Bool? = nil
    var onPinToggle: (() -> Void)? = nil
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: action) {
                HStack(spacing: 9) {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(Editorial.accent)
                        .frame(width: 18)
                    Text(name)
                        .font(.system(size: 13, weight: selected ? .medium : .regular))
                        .foregroundStyle(Editorial.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Editorial.accent)
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, pinned == nil ? 10 : 2)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(name)

            if let pinned, let onPinToggle {
                Button(action: onPinToggle) {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.system(size: 12))
                        .foregroundStyle(pinned ? Editorial.accent : Editorial.inkMute)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pinned ? "Desafixar \(name)" : "Fixar \(name)")
                .help(pinned ? "Desafixar lista" : "Fixar lista")
                .padding(.trailing, 4)
            }
        }
        .background(selected ? Editorial.accentSoft : (hover ? Editorial.ruleSoft : .clear),
                    in: RoundedRectangle(cornerRadius: 8))
        .scrollAwareOnHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}
