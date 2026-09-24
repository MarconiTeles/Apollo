import SwiftUI

// Compact settings, using Apollo's current materials and native controls.
// Connection and preference actions keep their existing service entry points.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.windowSize) private var windowSize
    var onClose: () -> Void = {}

    @State private var showListPicker = false
    @State private var section: SettingsSection = .integracoes

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Editorial.popupRadius(9), style: .continuous)
    }

    private var popupSize: CGSize {
        let available = windowSize.width > 0 && windowSize.height > 0
            ? windowSize : CGSize(width: 1200, height: 820)
        return CGSize(width: min(860, max(0, available.width - 48)),
                      height: min(620, max(0, available.height - 48)))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            content
                // Overlay the opaque content edge. A translucent divider as a
                // separate HStack child leaves an unpainted half-point gap.
                .overlay(alignment: .leading) {
                    Rectangle().fill(Editorial.rule).frame(width: 1)
                        .allowsHitTesting(false)
                }
        }
        .frame(width: popupSize.width, height: popupSize.height)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Editorial.rule, lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.18), radius: 28, y: 12)
        .sheet(isPresented: $showListPicker) {
            CUListPickerSheet().environmentObject(appState)
        }
    }

    private var appVersionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Versão \(version) (\(build))"
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Configurações")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Editorial.ink)
                .padding(.horizontal, 18)
                .frame(height: 58)

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(SettingsSection.allCases) { item in
                        SetNavItem(item: item, active: item == section) { section = item }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }

            HStack(spacing: 8) {
                SettingsAvatar(letter: accountInitial, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(accountName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Editorial.ink)
                    Text(accountSubtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Editorial.inkSoft)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .frame(width: 190)
        .officialHeaderMaterial(in: Rectangle())
        .apolloStudioNode("settings.sidebar",
                          title: "Navegação de configurações",
                          kind: .sidebar,
                          parent: "settings.panel",
                          properties: [
                            .init(kind: .width, title: "Largura", value: 190),
                            .init(kind: .material, title: "Material", token: "OfficialHeaderMaterial"),
                          ])
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(section.label)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Editorial.ink)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Fechar configurações")
                .help("Fechar configurações")
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 22)
            .frame(height: 58)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Editorial.rule).frame(height: 0.5)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch section {
                    case .geral: geralSection
                    case .conta: contaSection
                    case .integracoes: integracoesSection
                    case .ia: AISection().environmentObject(appState)
                    case .atalhos: atalhosSection
                    case .sobre: sobreSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
            }
            // Each section starts at its own top, including after a long list
            // of ClickUp status mappings or provider configuration.
            .id(section)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Editorial.page)
        .apolloStudioNode("settings.content",
                          title: "Conteúdo de configurações",
                          kind: .section,
                          parent: "settings.panel")
    }

    private var accountName: String { appState.clickUpAuthService.userName ?? "Você" }
    private var accountInitial: String { String(accountName.prefix(1)).uppercased() }
    private var accountSubtitle: String {
        appState.googleAuth.connectedEmail
            ?? appState.clickUpAuthService.workspaceName
            ?? "Apollo · macOS"
    }

    private var geralSection: some View {
        SettingsCard(title: "Preferências", icon: "slider.horizontal.3") {
            SetRow(label: "Aparência") {
                Picker("Aparência", selection: Binding(
                    get: { appState.appearanceMode },
                    set: { appState.setAppearanceMode($0) }
                )) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            SetRow(label: "Modo menu bar") {
                Toggle("Modo menu bar", isOn: Binding(
                    get: { appState.menuBarMode },
                    set: { appState.setMenuBarMode($0) }
                ))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            SetRow(label: "Notificações do macOS",
                   sub: "Exibe as notificações do Apollo no Centro de Notificações.") {
                Toggle("Notificações do macOS", isOn: Binding(
                    get: { appState.nativeNotificationsEnabled },
                    set: { appState.setNativeNotificationsEnabled($0) }
                ))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            SetRow(label: "Tutorial", divider: false) {
                Button("Reabrir") {
                    appState.requestOpenOnboarding()
                    onClose()
                }
                .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.regular)
            }
        }
    }

    private var contaSection: some View {
        SettingsCard(title: "Conta conectada", icon: "person.crop.circle") {
            HStack(spacing: 12) {
                SettingsAvatar(letter: accountInitial, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(accountName).font(.system(size: 15, weight: .medium))
                    Text(accountSubtitle).font(.system(size: 12)).foregroundStyle(Editorial.inkSoft)
                }
                .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            SetRow(label: "Sair do Apollo",
                   sub: "Desconecta as contas ClickUp e Google.", divider: false) {
                Button("Sair", role: .destructive) {
                    appState.clickUpAuthService.disconnect()
                    appState.googleAuth.disconnect()
                }
                .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.regular)
            }
        }
    }

    @ViewBuilder private var integracoesSection: some View {
        GoogleCalendarSection().environmentObject(appState)
        ClickUpSection(showListPicker: $showListPicker).environmentObject(appState)
        SettingsCard(title: "Sincronização", icon: "arrow.triangle.2.circlepath") {
            SetRow(label: "Frequência", divider: false) {
                SettingsMenu("Frequência de sincronização", selection: Binding(
                    get: { appState.autoSyncInterval },
                    set: { appState.setAutoSyncInterval($0) }
                ), options: [(0, "Manual"), (5, "A cada 5 min"),
                             (15, "A cada 15 min"), (30, "A cada 30 min"),
                             (60, "A cada 1 hora")])
            }
        }
    }

    private var atalhosSection: some View {
        SettingsCard(title: "Teclado", icon: "command") {
            SetRow(label: "Paleta de comandos") { shortcut("⌘ K") }
            SetRow(label: "Sincronizar agora") { shortcut("⌘ R") }
            SetRow(label: "Desfazer") { shortcut("⌘ Z") }
            SetRow(label: "Fechar janela de configurações", divider: false) { shortcut("Esc") }
        }
    }

    private func shortcut(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Editorial.inkSoft)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Editorial.field, in: RoundedRectangle(cornerRadius: 6))
    }

    private var sobreSection: some View {
        SettingsCard(title: "Apollo", icon: "info.circle") {
            Text(appVersionString)
                .font(.system(size: 12)).foregroundStyle(Editorial.inkSoft)
            Button("Verificar atualizações…") {
                NSApp.sendAction(Selector(("checkForUpdates:")), to: nil, from: nil)
            }
            .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.regular)
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case geral, integracoes, ia, conta, atalhos, sobre
    var id: String { rawValue }

    var label: String {
        switch self {
        case .geral: "Geral"
        case .integracoes: "Integrações"
        case .ia: "Apollo IA"
        case .conta: "Conta"
        case .atalhos: "Atalhos"
        case .sobre: "Sobre"
        }
    }

    var icon: String {
        switch self {
        case .geral: "gearshape"
        case .integracoes: "puzzlepiece.extension"
        case .ia: "sparkles"
        case .conta: "person.crop.circle"
        case .atalhos: "command"
        case .sobre: "info.circle"
        }
    }
}

private struct SetNavItem: View {
    let item: SettingsSection
    let active: Bool
    let onTap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: SidebarRowMetrics.iconSpacing) {
                Image(systemName: item.icon)
                    .font(.system(size: SidebarRowMetrics.iconSize))
                    .foregroundStyle(active ? Editorial.accent : Editorial.inkSoft)
                    .frame(width: SidebarRowMetrics.iconFrame)
                Text(item.label)
                    .font(.system(size: 12.5, weight: active ? .medium : .regular))
                    .foregroundStyle(Editorial.ink)
                Spacer(minLength: 0)
            }
            .frame(minHeight: SidebarRowMetrics.contentHeight)
            .padding(.horizontal, 9)
            .padding(.vertical, SidebarRowMetrics.verticalPadding)
            .background(active ? Editorial.accentSoft : (hover ? Editorial.ruleSoft : .clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
        .scrollAwareOnHover { hover = $0 }
        .apolloStudioNode(StudioNodeID(rawValue: "settings.nav.\(item.rawValue)"),
                          title: item.label, kind: .button, parent: "settings.sidebar")
    }
}

// These cards are local to Settings; shared forms keep their existing layout.
private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Editorial.inkSoft)
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Editorial.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .apolloStudioNode(StudioNodeID(rawValue: "settings.section.\(title.lowercased())"),
                          title: title, kind: .section, parent: "settings.content")
    }
}

private struct SetRow<Control: View>: View {
    let label: String
    var sub: String? = nil
    var divider: Bool = true
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(.system(size: 12))
                        .foregroundStyle(Editorial.ink)
                    if let sub {
                        Text(sub).font(.system(size: 11))
                            .foregroundStyle(Editorial.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                control()
            }
            .padding(.vertical, 2)
            if divider { Rectangle().fill(Editorial.ruleSoft).frame(height: 0.5) }
        }
        .apolloStudioNode(StudioNodeID(rawValue: "settings.row.\(label.lowercased())"),
                          title: label, kind: .row, parent: "settings.content")
    }
}

private struct SettingsAvatar: View {
    let letter: String
    var size: CGFloat
    var body: some View {
        Text(letter)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(Editorial.accent)
            .frame(width: size, height: size)
            .background(Editorial.accentSoft, in: Circle())
    }
}

// MARK: - ClickUp Section

private struct ClickUpSection: View {
    @EnvironmentObject var appState: AppState
    @Binding var showListPicker: Bool

    var body: some View {
        SettingsCard(title: "ClickUp", icon: "checkmark.circle") {
            if appState.clickUpAuthService.isConnected {
                connectedView
            } else {
                disconnectedView
            }
        }
        .onChange(of: appState.clickUpAuthService.isConnected) { _, connected in
            if connected, KeychainHelper.load(for: KeychainHelper.Keys.clickupListId) == nil {
                showListPicker = true
            }
        }
    }

    private var disconnectedView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if appState.clickUpAuthService.isWaitingForToken {
                waitingForTokenView
            } else {
                Text("Conecte sua conta ClickUp para ver e criar tarefas.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let err = appState.clickUpAuthService.connectionError {
                    SettingsWarningRow(message: err)
                }

                accentButton("Conectar com ClickUp", icon: "checkmark.circle") {
                    appState.clickUpAuthService.startConnection()
                }
            }
        }
    }

    private var waitingForTokenView: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsFormRow {
                Image(systemName: "key.viewfinder")
                    .font(.callout)
                    .foregroundStyle(Editorial.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cole seu token do ClickUp")
                        .font(.system(size: 13, weight: .medium))
                    Text("No browser, clique em **Copiar** ao lado do seu token e cole abaixo.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancelar") { appState.clickUpAuthService.cancelConnection() }
                    .buttonStyle(.glass).buttonBorderShape(.capsule)
            }

            // Explicit paste field replaces the previous
            // clipboard-polling flow — Apollo only ever sees the
            // token the user deliberately pastes here, never
            // anything else copied during a 2-minute window.
            HStack(spacing: 8) {
                SecureField("pk_…", text: $pastedClickUpToken)
                    .textFieldStyle(.plain)
                    .modifier(SettingsFieldSurface())
                    .onSubmit { confirmPastedClickUpToken() }
                Button("Conectar") { confirmPastedClickUpToken() }
                    .buttonStyle(.glassProminent).buttonBorderShape(.capsule)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(pastedClickUpToken
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty)
            }

            if let err = appState.clickUpAuthService.connectionError {
                SettingsWarningRow(message: err)
            }
        }
    }

    /// Local buffer for the pasted token while the user is
    /// confirming. Kept here (not in the service) so SwiftUI
    /// owns the binding and the field clears as soon as the
    /// submission succeeds.
    @State private var pastedClickUpToken: String = ""

    private func confirmPastedClickUpToken() {
        let raw = pastedClickUpToken
        if appState.clickUpAuthService.submitToken(raw) {
            pastedClickUpToken = ""
        }
    }

    private var connectedView: some View {
        VStack(spacing: 8) {
            SettingsFormRow {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(appState.clickUpAuthService.userName ?? "Conectado")
                        .font(.system(size: 13)).lineLimit(1)
                    if let ws = appState.clickUpAuthService.workspaceName {
                        Text(ws).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Button("Sair", role: .destructive) { appState.clickUpAuthService.disconnect() }
                    .buttonStyle(.glass).buttonBorderShape(.capsule)
            }
            Divider().overlay(Editorial.ruleSoft)
            SettingsFormRow {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lista de tarefas").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(listSummary).font(.system(size: 12, weight: .medium))
                }
                Spacer()
                Button("Selecionar", systemImage: "list.bullet.rectangle") { showListPicker = true }
                    .buttonStyle(.glass).buttonBorderShape(.capsule)
            }
            Divider().overlay(Editorial.ruleSoft)
            doneActionRow
        }
    }

    /// One row per current-status, letting the user pick where DONE should
    /// move the task FROM that status. Example: "DOING → REVIEW",
    /// "REVIEW → COMPLETE". Empty when ClickUp statuses haven't loaded yet.
    private var doneActionRow: some View {
        DisclosureGroup("Ação do botão Done por status") {
            VStack(spacing: 4) {
                if appState.availableStatuses.isEmpty {
                    SettingsFormRow {
                        Text("Nenhum status disponível")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                } else {
                    ForEach(appState.availableStatuses) { s in
                        doneActionMappingRow(for: s)
                    }
                }
            }
            .padding(.top, 6)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    /// One mapping row split into 3 fixed-width blocks so the arrow stays
    /// in the same column regardless of the names involved:
    ///   [ CURRENT ▮▮▮▮▮ ]   →    [ ▮▮▮▮▮ TARGET ]
    private func doneActionMappingRow(for current: CUStatus) -> some View {
        let mapped   = appState.doneActionByStatus[current.status]
        let target   = mapped.flatMap { name in
            appState.availableStatuses.first(where: { $0.status == name })
        }
        let curColor = Color(statusHex: current.displayHex)

        return SettingsFormRow {
            // ── Block 1: current status (read-only)
            HStack(spacing: 4) {
                Circle().fill(curColor).frame(width: 6, height: 6)
                Text(current.status)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Editorial.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 130, alignment: .leading)

            // ── Block 2: arrow (centred in its own column)
            Image(systemName: "arrow.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .center)

            // ── Block 3: target status menu
            Menu {
                Button {
                    appState.setDoneAction(forStatus: current.status, to: nil)
                } label: {
                    if mapped == nil {
                        Label("Não definido", systemImage: "checkmark")
                    } else {
                        Text("Não definido")
                    }
                }
                Divider()
                ForEach(appState.availableStatuses.filter { $0.status != current.status }) { s in
                    Button {
                        appState.setDoneAction(forStatus: current.status, to: s.status)
                    } label: {
                        if s.status == mapped {
                            Label(s.status.uppercased(), systemImage: "checkmark")
                        } else {
                            Text(s.status.uppercased())
                        }
                    }
                }
            } label: {
                if let t = target {
                    let tColor = Color(statusHex: t.displayHex)
                    HStack(spacing: 4) {
                        Circle().fill(tColor).frame(width: 6, height: 6)
                        Text(t.status)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Editorial.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    HStack(spacing: 4) {
                        Text("Selecionar")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Editorial.accent)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Editorial.inkSoft)
                    }
                }
            }
            .menuIndicator(.hidden)
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .frame(width: 170, alignment: .leading)

            Spacer(minLength: 0)
        }
    }

    private var listSummary: String {
        if let name = KeychainHelper.load(for: KeychainHelper.Keys.clickupListName),
           !name.isEmpty {
            return name
        }
        if KeychainHelper.load(for: KeychainHelper.Keys.clickupListId) != nil {
            return "Lista selecionada"
        }
        return "Nenhuma lista — toque em Selecionar"
    }
}

// MARK: - Apollo IA Section

/// Settings card for the in-app AI agent. Lets the user pick the
/// backend (Gemini cloud / Ollama local) and tweak per-backend
/// configuration. The choice persists in UserDefaults via
/// `LLMBackend.userDefaultsKey`.
private struct AISection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        SettingsCard(title: "Apollo IA", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 12) {
                backendPicker
                Divider().opacity(0.4)
                switch appState.aiAgent.backend {
                case .embedded:           EmbeddedSettingsCard()
                case .groq:               GroqSettingsCard()
                case .gemini:             GeminiSettingsCard()
                case .ollama:             OllamaSettingsCard()
                case .appleIntelligence:  AppleIntelligenceSettingsCard()
                case .openai:             OpenAISettingsCard()
                }
            }
        }
    }

    private var backendPicker: some View {
        SetRow(label: "Provedor", divider: false) {
            SettingsMenu("Provedor", selection: Binding(
                get: { appState.aiAgent.backend },
                set: { appState.aiAgent.setBackend($0) }
            ), options: LLMBackend.userSelectable.map { ($0, $0.label) })
        }
    }
}

// MARK: - Embedded model status card

/// "Configuration" view for the bundled MLX model. There's
/// nothing to configure — the model ships in the .app — so the
/// card is purely informational, confirming everything works
/// out of the box.
private struct EmbeddedSettingsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apollo IA está pronto.")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Roda 100% local, sem chave, sem rede.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Text("O modelo de IA vem embutido no Apollo. Privacidade total: tarefas e eventos nunca saem do seu Mac. Funciona offline.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Groq config card

/// Groq settings: API key field. The free tier doesn't require a
/// credit card and gives ~14k requests/day at 30 RPM with
/// sub-second token latency.
private struct GroqSettingsCard: View {
    @State private var keyDraft: String = ""
    @State private var savedFlash: Bool = false
    @State private var selectedModelId: String = GroqProvider.defaultModelId

    private var savedKey: String? {
        KeychainHelper.load(for: KeychainHelper.Keys.groqApiKey)
    }

    private var isConfigured: Bool { (savedKey?.count ?? 0) >= 20 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cole sua chave do **Groq Console**. O free tier dá ~14k requisições/dia com latência de ~300 ms, sem cartão. Gere a chave em [console.groq.com/keys](https://console.groq.com/keys).")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .tint(.blue)

            glassLabeledSecureField("Chave da API Groq", text: $keyDraft)

            // Model picker. Critical because the user-friendly
            // default (`llama-3.3-70b-versatile`) has a tight
            // free-tier TPR ceiling (~12K) that Apollo's
            // workspace-rich system prompt routinely blows
            // through, returning 413. Letting the user pick a
            // higher-TPR model (8B Instant ~30K) recovers
            // them — and we also auto-fallback to it on 413.
            VStack(alignment: .leading, spacing: 6) {
                Text("Modelo")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("Modelo", selection: Binding(
                    get: { selectedModelId },
                    set: {
                        selectedModelId = $0
                        UserDefaults.standard.set($0, forKey: GroqProvider.modelDefaultsKey)
                    }
                )) {
                    ForEach(GroqProvider.availableModels) { opt in
                        Text(opt.label + " · " + opt.trpHint).tag(opt.id)
                            .help(opt.qualityHint)
                    }
                }
                .pickerStyle(.radioGroup).labelsHidden()
                Text("⚡ Recuperação automática: se o modelo escolhido recusar a request com 413 (input grande), o Apollo refaz a chamada com `Llama 3.1 8B Instant` (TPR maior).")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }

            HStack(spacing: 8) {
                Button {
                    let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        KeychainHelper.delete(for: KeychainHelper.Keys.groqApiKey)
                    } else {
                        KeychainHelper.save(trimmed, for: KeychainHelper.Keys.groqApiKey)
                    }
                    savedFlash = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        savedFlash = false
                    }
                } label: {
                    Label(savedFlash ? "Salvo" : "Salvar",
                          systemImage: savedFlash ? "checkmark.circle.fill" : "tray.and.arrow.down")
                        .font(.system(size: 12, weight: .semibold))

                }
                .buttonStyle(.glassProminent).buttonBorderShape(.capsule)

                if isConfigured {
                    Label("Conectado", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(.green)
                } else {
                    Label("Não configurado", systemImage: "key.slash")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
        }
        .onAppear {
            keyDraft = savedKey ?? ""
            let stored = UserDefaults.standard.string(forKey: GroqProvider.modelDefaultsKey) ?? ""
            selectedModelId = stored.isEmpty ? GroqProvider.defaultModelId : stored
        }
    }
}

// MARK: - Gemini config card

private struct GeminiSettingsCard: View {
    @State private var keyDraft: String = ""
    @State private var savedFlash: Bool = false

    private var savedKey: String? {
        KeychainHelper.load(for: KeychainHelper.Keys.geminiApiKey)
    }

    private var isConfigured: Bool { (savedKey?.count ?? 0) >= 20 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cole sua chave do Google AI Studio (Gemini). O **free tier** dá ~1.500 requisições/dia sem cartão de crédito — gere a sua em [aistudio.google.com](https://aistudio.google.com).")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .tint(.blue)

            glassLabeledSecureField("Chave da API Gemini", text: $keyDraft)

            HStack(spacing: 8) {
                Button {
                    let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        KeychainHelper.delete(for: KeychainHelper.Keys.geminiApiKey)
                    } else {
                        KeychainHelper.save(trimmed, for: KeychainHelper.Keys.geminiApiKey)
                    }
                    savedFlash = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        savedFlash = false
                    }
                } label: {
                    Label(savedFlash ? "Salvo" : "Salvar",
                          systemImage: savedFlash ? "checkmark.circle.fill" : "tray.and.arrow.down")
                        .font(.system(size: 12, weight: .semibold))

                }
                .buttonStyle(.glassProminent).buttonBorderShape(.capsule)

                if isConfigured {
                    Label("Conectado", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(.green)
                } else {
                    Label("Não configurado", systemImage: "key.slash")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
        }
        .onAppear { keyDraft = savedKey ?? "" }
    }
}

// MARK: - OpenAI config card

/// API-key input + model picker for the OpenAI backend.
/// Mirrors the Gemini card structure but with a model radio
/// (GPT-4o-mini default, GPT-4o, GPT-5) since OpenAI's pricing
/// varies meaningfully between tiers and the user should be
/// able to control cost.
private struct OpenAISettingsCard: View {
    @EnvironmentObject var appState: AppState

    @State private var keyDraft: String = ""
    @State private var savedFlash: Bool = false
    @State private var selectedModelId: String =
        UserDefaults.standard.string(forKey: OpenAIProvider.modelDefaultsKey)
            ?? OpenAIProvider.defaultModelId

    private var savedKey: String? {
        KeychainHelper.load(for: KeychainHelper.Keys.openaiApiKey)
    }
    private var isConfigured: Bool { (savedKey?.count ?? 0) >= 20 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cole sua chave da OpenAI. Pago por uso — cobrança no cartão da conta OpenAI. Crie uma chave em [platform.openai.com/api-keys](https://platform.openai.com/api-keys).")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .tint(.blue)

            glassLabeledSecureField("Chave da API OpenAI (sk-…)", text: $keyDraft)

            HStack(spacing: 8) {
                Button {
                    let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        KeychainHelper.delete(for: KeychainHelper.Keys.openaiApiKey)
                    } else {
                        KeychainHelper.save(trimmed, for: KeychainHelper.Keys.openaiApiKey)
                    }
                    savedFlash = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        savedFlash = false
                    }
                } label: {
                    Label(savedFlash ? "Salvo" : "Salvar",
                          systemImage: savedFlash ? "checkmark.circle.fill" : "tray.and.arrow.down")
                        .font(.system(size: 12, weight: .semibold))

                }
                .buttonStyle(.glassProminent).buttonBorderShape(.capsule)

                if isConfigured {
                    Label("Conectado", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(.green)
                } else {
                    Label("Não configurado", systemImage: "key.slash")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }

            Divider().opacity(0.4)

            Text("Modelo")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Picker("Modelo", selection: Binding(
                get: { selectedModelId },
                set: {
                    selectedModelId = $0
                    UserDefaults.standard.set($0, forKey: OpenAIProvider.modelDefaultsKey)
                    appState.aiAgent.setBackend(.openai)
                }
            )) {
                ForEach(OpenAIProvider.availableModels) { opt in
                    Text(opt.label + " · " + opt.priceHint).tag(opt.id)
                        .help(opt.qualityHint)
                }
            }
            .pickerStyle(.radioGroup).labelsHidden()
        }
        .onAppear { keyDraft = savedKey ?? "" }
    }
}

// MARK: - Ollama config card

/// Read-only status card for the local Ollama runtime. Apollo
/// drives the actual lifecycle (start daemon, pick model, pull
/// Settings card for the Apple Intelligence backend. Pure
/// info: no API key, no model picker, no toggles — Apollo just
/// asks Apple's `FoundationModels` framework to handle the
/// inference on-device. The card surfaces availability state
/// (macOS 26+ Apple Silicon Mac with Apple Intelligence
/// enabled) and explains why the user might want this backend.
private struct AppleIntelligenceSettingsCard: View {
    @EnvironmentObject var appState: AppState

    private var isAvailable: Bool {
        appState.aiAgent.provider.isConfigured
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Usa o modelo Apple Intelligence direto no seu Mac. Sem API key, sem limite por minuto, sem custo. As perguntas e respostas nunca saem do dispositivo.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isAvailable ? .green : .orange)
                Text(isAvailable
                     ? "Apple Intelligence ativo neste Mac."
                     : "Indisponível neste Mac. Requer macOS 26 ou posterior em Apple Silicon, com Apple Intelligence habilitado em Ajustes do Sistema.")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label("Sem rate limit por minuto", systemImage: "infinity")
                Label("Privacidade total — nada sai do seu Mac", systemImage: "lock.shield.fill")
                Label("Sem custo, sem chave de API", systemImage: "dollarsign.circle.fill")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }
}

/// model) via `OllamaServiceManager` — this view just observes
/// `aiAgent.ollama` and surfaces the user-actionable cases
/// (Ollama not installed, daemon won't start).
private struct OllamaSettingsCard: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Roda 100% local na sua máquina — zero rede, zero custo, total privacidade. O Apollo gerencia o serviço Ollama automaticamente: inicia o daemon, escolhe um modelo e baixa um se necessário.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            statusRow
            modelRow

            // If Ollama isn't installed, give the user a single
            // button to open the official downloads page. Once
            // they install the .pkg the next bootstrap call
            // detects it and proceeds.
            if appState.aiAgent.ollama.daemonStatus == .notInstalled {
                Button {
                    appState.aiAgent.ollama.openInstallPage()
                } label: {
                    Label("Instalar Ollama", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 12, weight: .semibold))

                }
                .buttonStyle(.glassProminent).buttonBorderShape(.capsule)
            }

            // "Try again" button — useful after the user finishes
            // an external action (installed Ollama, killed a stuck
            // daemon, etc.) and wants Apollo to re-check.
            Button {
                Task { await appState.aiAgent.ollama.bootstrap() }
            } label: {
                Label("Verificar de novo", systemImage: "arrow.clockwise")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.glass).buttonBorderShape(.capsule)
        }
        .task { await appState.aiAgent.ollama.bootstrap() }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(daemonColor)
                .frame(width: 8, height: 8)
            Text(daemonText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        switch appState.aiAgent.ollama.modelStatus {
        case .ready(let name):
            Label("Modelo: \(name)", systemImage: "cube.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
        case .pulling(let name, let fraction, let stage):
            VStack(alignment: .leading, spacing: 4) {
                Label("Baixando \(name)…", systemImage: "arrow.down.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(.orange)
                Text(stage)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        case .noneInstalled:
            Label("Sem modelos instalados", systemImage: "cube.box")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        case .unknown:
            EmptyView()
        }
    }

    private var daemonColor: Color {
        switch appState.aiAgent.ollama.daemonStatus {
        case .running:      return .green
        case .starting:     return .orange
        case .stopped:      return .red
        case .notInstalled: return .red
        case .unknown:      return .gray
        }
    }

    private var daemonText: String {
        switch appState.aiAgent.ollama.daemonStatus {
        case .running:      return "Ollama rodando"
        case .starting:     return "Iniciando Ollama…"
        case .stopped:      return "Ollama instalado, mas não consegue subir"
        case .notInstalled: return "Ollama não está instalado"
        case .unknown:      return "Verificando…"
        }
    }
}

// MARK: - App Section

// MARK: - Google Calendar (REST API for attendees)
//
// EventKit on macOS can read events from Google calendars (synced
// via Internet Accounts) but can NOT add attendees programmatically
// — that's Apple platform-level read-only. To actually invite
// people to events Apollo creates (the AI agent's CREATE_EVENT
// marker, the "+ Evento" form), we hit Google's REST API directly.
// One-time OAuth via the user's own Google Cloud Project.
private struct GoogleCalendarSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        SettingsCard(title: "Google Calendar", icon: "envelope.badge") {
            VStack(alignment: .leading, spacing: 10) {
                if appState.googleAuth.isConnected {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Conectado")
                                .font(.system(size: 13, weight: .semibold))
                            if let email = appState.googleAuth.connectedEmail {
                                Text(email)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Desconectar", role: .destructive) {
                            appState.googleAuth.disconnect()
                        }
                        .buttonStyle(.glass).buttonBorderShape(.capsule)
                    }
                    Text("Eventos criados no Apollo com convidados são enviados via Google API com notificação por email.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !appState.googleAuth.hasClientId {
                    // Apollo was built without an embedded
                    // OAuth Client ID — the developer needs to
                    // fill in `GoogleAuthService.embeddedClientId`
                    // before the connect button can do anything.
                    Text("A conexão com o Google não está disponível nesta versão do Apollo.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Conecte sua conta Google para sincronizar eventos e enviar convites aos participantes.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button(appState.googleAuth.inProgress ? "Conectando…" : "Conectar Google",
                           systemImage: "link") {
                        Task { await appState.googleAuth.connect() }
                    }
                    .buttonStyle(.glassProminent).buttonBorderShape(.capsule)
                    .disabled(appState.googleAuth.inProgress)

                    if let err = appState.googleAuth.lastError {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

// MARK: - Shared field helpers (file-private)

private struct SettingsFieldSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 13))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Editorial.field, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SettingsWarningRow: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.system(size: 12))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

@ViewBuilder
private func glassLabeledSecureField(_ label: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(label).font(.system(size: 12)).foregroundStyle(Editorial.inkSoft)
        SecureField(label, text: text)
            .textFieldStyle(.plain)
            .modifier(SettingsFieldSurface())
    }
}

private func accentButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
    Button(label, systemImage: icon, action: action)
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
}

/// Flat content row inside a single grouped surface, without legacy boxes.
private struct SettingsFormRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 12) { content() }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    }
}

/// Native glass menu with the selected value and checkmarks, shared by the
/// provider and synchronization controls. Does not own preference state.
private struct SettingsMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]

    init(_ title: String, selection: Binding<Value>, options: [(Value, String)]) {
        self.title = title
        self._selection = selection
        self.options = options
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { value, label in
                Button { selection = value } label: {
                    if value == selection { Label(label, systemImage: "checkmark") }
                    else { Text(label) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(options.first { $0.0 == selection }?.1 ?? "Selecionar")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
        }
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(options.first { $0.0 == selection }?.1 ?? "Selecionar")
    }
}
