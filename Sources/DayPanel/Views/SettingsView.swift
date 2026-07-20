import SwiftUI

// MARK: - Settings (editorial, full-bleed two-pane)
//
// SwiftUI port of the prototype `PSettings` (prototype-settings.jsx):
// a proper settings *surface* — 260pt folio sidebar + content pane,
// eight numbered sections. Real Apollo controls are wired live; the
// prototype rows Apollo can't do yet are still rendered (for visual
// completeness) but tagged with an "em breve" badge and disabled.
// All pre-existing functional subviews (ClickUp/Google/AI/App auth +
// Keychain) are re-hosted verbatim so nothing stops working.

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.windowSize) private var windowSize
    var onClose: () -> Void = {}

    @State private var showListPicker = false
    @State private var section: SettingsSection = .integracoes

    private var shape: RoundedRectangle {
        // Mesmo arredondamento da janela de Anexar (TaskMediaFlowSheet).
        RoundedRectangle(cornerRadius: Editorial.popupRadius(9), style: .continuous)
    }

    /// Full-bleed: fills the window minus the prototype's
    /// `left/right 60 · top/bottom 24` margins, clamped so it stays
    /// readable on small windows.
    private var popupSize: CGSize {
        let w = windowSize.width  > 0 ? windowSize.width  : 1200
        let h = windowSize.height > 0 ? windowSize.height : 820
        return CGSize(width:  max(760, w - 120),
                      height: max(520, h - 56))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Editorial.rule).frame(width: 1)
            content
        }
        .frame(width: popupSize.width, height: popupSize.height)
        // Do not place an opaque sheet behind both panes: it made the left
        // Liquid Glass sample a white backstop and therefore look solid. The
        // working pane paints its own Editorial.page background; the sidebar
        // is intentionally left to refract the live app canvas behind it.
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Editorial.rule, lineWidth: 0.7)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.20), radius: 36, y: 18)
        .shadow(color: .black.opacity(0.07), radius: 12, y: 4)
        .sheet(isPresented: $showListPicker) {
            CUListPickerSheet().environmentObject(appState)
        }
    }

    // MARK: Sidebar

    private var appVersionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Apollo · v\(v) (\(b))"
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Folio("Configurações")
                Caption(appVersionString, size: 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22).padding(.bottom, 16)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Editorial.rule).frame(height: 1)
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(SettingsSection.allCases) { s in
                        SetNavItem(item: s, active: s == section) { section = s }
                    }
                }
                .padding(.vertical, 12)
            }

            Rectangle().fill(Editorial.rule).frame(height: 1)
            HStack(spacing: 10) {
                SettingsAvatar(letter: accountInitial, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(accountName)
                        .font(Editorial.serif(13.5))
                        .foregroundStyle(Editorial.ink)
                        .lineLimit(1)
                    Caption(accountSubtitle, size: 11)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(width: 260)
        // Material OFICIAL do header (mesma receita de Tarefas).
        .officialHeaderMaterial(in: Rectangle())
        .apolloStudioNode("settings.sidebar",
                          title: "Navegação de configurações",
                          kind: .sidebar,
                          parent: "settings.panel",
                          properties: [
                            .init(kind: .width, title: "Largura", value: 260),
                            .init(kind: .material,
                                  title: "Material", token: "OfficialHeaderMaterial"),
                          ])
    }

    // MARK: Content

    private var content: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(section.folio + ".")
                    .font(Editorial.serif(15).italic())
                    .foregroundStyle(Editorial.inkMute)
                Text(section.label)
                    .font(Editorial.serif(28))
                    .foregroundStyle(Editorial.ink)
                    .tracking(-0.7)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Editorial.inkSoft)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 40)
            .padding(.top, 20).padding(.bottom, 16)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Editorial.rule).frame(height: 1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch section {
                    case .conta:        contaSection
                    case .integracoes:  integracoesSection
                    case .ia:           iaSection
                    case .aparencia:    aparenciaSection
                    case .notificacoes: notificacoesSection
                    case .atalhos:      atalhosSection
                    case .avancado:     avancadoSection
                    case .sobre:        sobreSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.top, 32).padding(.bottom, 40)
            }
            .background(Color.clear)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Editorial.page)
        .apolloStudioNode("settings.content",
                          title: "Conteúdo de configurações",
                          kind: .section,
                          parent: "settings.panel")
    }

    // MARK: Account identity (real)

    private var accountName: String {
        appState.clickUpAuthService.userName ?? "Você"
    }
    private var accountInitial: String {
        String(accountName.first.map(String.init) ?? "A").uppercased()
    }
    private var accountSubtitle: String {
        appState.googleAuth.connectedEmail
            ?? appState.clickUpAuthService.workspaceName
            ?? "Apollo · macOS"
    }

    // MARK: - Sections

    @ViewBuilder private var contaSection: some View {
        SetSection(title: "Perfil") {
            HStack(spacing: 18) {
                SettingsAvatar(letter: accountInitial, size: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(accountName)
                        .font(Editorial.serif(22)).foregroundStyle(Editorial.ink)
                        .tracking(-0.3)
                    Caption(accountSubtitle + " · macOS · pt-BR", size: 13)
                }
                Spacer(minLength: 0)
                SetButton("Trocar foto", emBreve: true) {}
            }
            .padding(.vertical, 8)
            SetRow(label: "Nome de exibição",
                   sub: "aparece em comentários e atribuições",
                   emBreve: true) { SetInput(text: .constant(accountName)) }
            SetRow(label: "Fuso horário",
                   sub: "usado para calcular horários e lembretes",
                   emBreve: true) {
                SetSelect(selection: .constant("brt"),
                          options: [("brt", "Brasília — GMT−03:00")])
            }
            SetRow(label: "Idioma",
                   sub: "da interface · não afeta o conteúdo das tarefas",
                   emBreve: true, divider: false) {
                SetSelect(selection: .constant("pt"),
                          options: [("pt", "Português (Brasil)")])
            }
        }
        SetSection(title: "Sessão") {
            SetRow(label: "Sair do Apollo",
                   sub: "desconecta ClickUp e Google — você precisará reconectar",
                   divider: false) {
                SetButton("Sair", kind: .danger) {
                    appState.clickUpAuthService.disconnect()
                    appState.googleAuth.disconnect()
                }
            }
        }
    }

    @ViewBuilder private var integracoesSection: some View {
        SetSection(title: "Serviços conectados") {
            GoogleCalendarSection().environmentObject(appState)
                .padding(.vertical, 4)
            ClickUpSection(showListPicker: $showListPicker)
                .environmentObject(appState)
                .padding(.vertical, 4)
        }
        SetSection(title: "Disponíveis",
                   sub: "conecte mais serviços para enriquecer o painel") {
            SetRow(label: "Gmail",
                   sub: "criar tarefa a partir do email",
                   emBreve: true) { SetButton("Conectar", kind: .primary) {} }
            SetRow(label: "Slack",
                   sub: "compartilhar tarefas no canal #planejamento",
                   emBreve: true, divider: false) {
                SetButton("Conectar", kind: .primary) {}
            }
        }
        SetSection(title: "Sincronização") {
            SetRow(label: "Frequência",
                   sub: "com que frequência Apollo busca mudanças nos serviços conectados") {
                SetSelect(
                    selection: Binding(
                        get: { appState.autoSyncInterval },
                        set: { appState.setAutoSyncInterval($0) }
                    ),
                    options: [(0, "Manual"), (5, "A cada 5 min"),
                              (15, "A cada 15 min"), (30, "A cada 30 min"),
                              (60, "A cada 1 hora")]
                )
            }
            SetRow(label: "Sincronizar ao despertar",
                   sub: "quando o Mac volta do sleep",
                   emBreve: true) { SetToggle(isOn: .constant(true)) }
            SetRow(label: "Modo offline",
                   sub: "continuar editando sem internet — sincroniza quando voltar",
                   emBreve: true, divider: false) { SetToggle(isOn: .constant(true)) }
        }
    }

    @ViewBuilder private var iaSection: some View {
        SetSection(title: "Provedor & modelo") {
            AISection().environmentObject(appState)
                .padding(.vertical, 4)
        }
        SetSection(title: "Comportamento") {
            SetRow(label: "Pode executar ações",
                   sub: "criar tarefa, mudar status, reagendar — sem confirmar a cada ação",
                   emBreve: true) { SetToggle(isOn: .constant(true)) }
            SetRow(label: "Sugestões proativas",
                   sub: "Apollo abre um banner sutil quando notar algo (atraso, conflito, padrão)",
                   emBreve: true) { SetToggle(isOn: .constant(true)) }
            SetRow(label: "Voz das respostas",
                   sub: "como Apollo conversa — afeta tom, não conteúdo",
                   emBreve: true, divider: false) {
                SetSelect(selection: .constant("ed"),
                          options: [("ed", "Editorial — calmo, italic")])
            }
        }
        SetSection(title: "Histórico") {
            SetRow(label: "Manter histórico de conversas",
                   sub: "local, no seu Mac · pode ser exportado em Markdown",
                   emBreve: true) { SetToggle(isOn: .constant(true)) }
            SetRow(label: "Apagar todo o histórico",
                   sub: "ação irreversível · não afeta tarefas nem eventos",
                   emBreve: true, divider: false) {
                SetButton("Apagar histórico", kind: .danger) {}
            }
        }
    }

    @ViewBuilder private var aparenciaSection: some View {
        SetSection(title: "Tema", sub: "Apollo é editorial-only por ora") {
            SetRow(label: "Esquema de cor",
                   sub: "claro · escuro · seguir o sistema",
                   emBreve: true) {
                SetSelect(selection: .constant("light"),
                          options: [("light", "Claro (Editorial Calm)")])
            }
        }
        SetSection(title: "Tipografia") {
            SetRow(label: "Fonte do conteúdo",
                   sub: "serif usada em títulos, descrição e comentários",
                   emBreve: true) {
                SetSelect(selection: .constant("ny"),
                          options: [("ny", "New York (padrão)")])
            }
            SetRow(label: "Tamanho base",
                   sub: "afeta toda a interface proporcionalmente",
                   emBreve: true) {
                SetSelect(selection: .constant("100"),
                          options: [("100", "Normal · 100 %")])
            }
            SetRow(label: "Números tabulares",
                   sub: "todos os dígitos ocupam a mesma largura — facilita comparar datas",
                   emBreve: true, divider: false) { SetToggle(isOn: .constant(true)) }
        }
        SetSection(title: "Janela") {
            SetRow(label: "Janela sempre por cima",
                   sub: "útil ao alternar entre Apollo e outros apps",
                   emBreve: true) { SetToggle(isOn: .constant(false)) }
            SetRow(label: "Densidade",
                   sub: "afeta o espaçamento vertical entre itens da lista",
                   emBreve: true, divider: false) {
                SetSelect(selection: .constant("conf"),
                          options: [("conf", "Confortável")])
            }
        }
    }

    @ViewBuilder private var notificacoesSection: some View {
        SetSection(title: "Canais",
                   sub: "o sino sempre registra; o resto depende do contexto") {
            SetRow(label: "Notificações do macOS",
                   sub: "espelha as notificações do app no Centro de Notificações") {
                SetToggle(isOn: Binding(
                    get: { appState.nativeNotificationsEnabled },
                    set: { appState.setNativeNotificationsEnabled($0) }
                ))
            }
            SetRow(label: "Toast in-app",
                   sub: "aparece no canto, 4 s, sem chrome — só com Apollo em foco",
                   emBreve: true) { SetToggle(isOn: .constant(true)) }
            SetRow(label: "Som",
                   sub: "audível em qualquer canal",
                   emBreve: true, divider: false) { SetToggle(isOn: .constant(false)) }
        }
        SetSection(title: "Eventos & tarefas") {
            SetRow(label: "Reunião daqui a X minutos",
                   sub: "lembrete antes do início",
                   emBreve: true) {
                SetSelect(selection: .constant("10"),
                          options: [("10", "10 min antes")])
            }
            SetRow(label: "Tarefa atribuída a mim",
                   sub: "alguém te coloca como responsável",
                   emBreve: true) { SetToggle(isOn: .constant(true)) }
            SetRow(label: "Tarefa vence hoje",
                   sub: "resumo matinal das 9:00",
                   emBreve: true, divider: false) { SetToggle(isOn: .constant(true)) }
        }
    }

    @ViewBuilder private var atalhosSection: some View {
        Caption("Atalhos do Apollo. O remapeamento por tecla chega em breve.",
                size: 13)
            .padding(.bottom, 22)
        ForEach(Self.shortcutGroups, id: \.title) { group in
            SetSection(title: group.title) {
                ForEach(Array(group.items.enumerated()), id: \.offset) { idx, item in
                    SetRow(label: item.0,
                           divider: idx < group.items.count - 1) {
                        KbdCombo(combo: item.1)
                    }
                }
            }
        }
    }

    @ViewBuilder private var avancadoSection: some View {
        SetSection(title: "App") {
            AppSection().environmentObject(appState)
                .padding(.vertical, 4)
            SetRow(label: "Reabrir tutorial",
                   sub: "passa pelo wizard inicial de novo",
                   divider: false) {
                SetButton("Abrir") {
                    appState.requestOpenOnboarding()
                    onClose()
                }
            }
        }
        SetSection(title: "Performance & privacidade") {
            SetRow(label: "Animações",
                   sub: "transições de spring, fade in/out de popups",
                   emBreve: true) { SetToggle(isOn: .constant(true)) }
            SetRow(label: "Enviar telemetria anônima",
                   sub: "apenas métricas de crash e performance — sem conteúdo de tarefas",
                   emBreve: true, divider: false) { SetToggle(isOn: .constant(false)) }
        }
        SetSection(title: "Dados") {
            SetRow(label: "Exportar tudo",
                   sub: "Markdown + JSON · tarefas, eventos e histórico",
                   emBreve: true) { SetButton("Exportar", kind: .primary) {} }
            SetRow(label: "Limpar tudo",
                   sub: "apaga cache e histórico · não afeta dados no ClickUp ou Calendar",
                   emBreve: true, divider: false) {
                SetButton("Limpar dados", kind: .danger) {}
            }
        }
        SetSection(title: "Para desenvolvedores") {
            SetRow(label: "Modo debug",
                   sub: "abre o painel de logs",
                   emBreve: true, divider: false) { SetToggle(isOn: .constant(false)) }
        }
    }

    @ViewBuilder private var sobreSection: some View {
        HStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Editorial.popup)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Editorial.rule, lineWidth: 1))
                Text("a")
                    .font(.system(size: 64, weight: .regular))
                    .italic()
                    .foregroundStyle(Editorial.accent)
            }
            .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 8) {
                (Text("Apollo ")
                    .font(Editorial.serif(32)).foregroundStyle(Editorial.ink)
                 + Text("— uma agenda que lê")
                    .font(Editorial.serif(32).italic())
                    .foregroundStyle(Editorial.inkSoft))
                    .tracking(-0.8)
                Caption("versão \(appVersionString)", size: 13)
            }
            Spacer(minLength: 0)
            SetButton("Procurar atualizações", kind: .primary) {
                NSApp.sendAction(Selector(("checkForUpdates:")), to: nil, from: nil)
            }
        }
        .padding(.bottom, 24)
        .overlay(alignment: .bottom) { Rectangle().fill(Editorial.rule).frame(height: 1) }
        .padding(.bottom, 24)

        SetSection(title: "Créditos & licenças") {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Folio("Tecnologia")
                    Text("SwiftUI · AppKit · Sparkle · Keychain Services")
                        .font(Editorial.serif(14)).foregroundStyle(Editorial.ink)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Folio("APIs")
                    Text("ClickUp v2 · Google Calendar v3 · Gemini · OpenAI · Groq")
                        .font(Editorial.serif(14)).foregroundStyle(Editorial.ink)
                }
            }
            .padding(.vertical, 4)
        }
        SetSection(title: "Notas") {
            SetRow(label: "Ver changelog completo",
                   sub: "histórico de versões e melhorias",
                   emBreve: true, divider: false) {
                SetButton("Abrir") {}
            }
        }
    }

    // Real, currently-supported shortcuts (display-only — exactly
    // as the prototype presents them; remapping is "em breve").
    private static let shortcutGroups: [(title: String, items: [(String, String)])] = [
        ("Geral", [
            ("Buscar / paleta de comandos", "⌘K"),
            ("Sincronizar agora", "⌘R"),
            ("Fechar overlay", "Esc"),
            ("Confirmar / criar", "⌘↩"),
        ]),
        ("Tarefa & evento", [
            ("Concluir / ação primária", "⌘↩"),
            ("Cancelar formulário", "Esc"),
        ]),
    ]
}

// MARK: - Settings section model

enum SettingsSection: String, CaseIterable, Identifiable {
    case conta, integracoes, ia, aparencia, notificacoes, atalhos, avancado, sobre
    var id: String { rawValue }

    var label: String {
        switch self {
        case .conta:        return "Conta"
        case .integracoes:  return "Integrações"
        case .ia:           return "Apollo IA"
        case .aparencia:    return "Aparência"
        case .notificacoes: return "Notificações"
        case .atalhos:      return "Atalhos"
        case .avancado:     return "Avançado"
        case .sobre:        return "Sobre"
        }
    }
    var folio: String {
        switch self {
        case .conta:        return "I"
        case .integracoes:  return "II"
        case .ia:           return "III"
        case .aparencia:    return "IV"
        case .notificacoes: return "V"
        case .atalhos:      return "VI"
        case .avancado:     return "VII"
        case .sobre:        return "VIII"
        }
    }
    var icon: String {
        switch self {
        case .conta:        return "person.crop.circle"
        case .integracoes:  return "list.bullet"
        case .ia:           return "sparkles"
        case .aparencia:    return "sun.max"
        case .notificacoes: return "bell"
        case .atalhos:      return "command"
        case .avancado:     return "gearshape"
        case .sobre:        return "info.circle"
        }
    }
}

// MARK: - Settings building blocks (prototype Set* components)

private struct SetNavItem: View {
    let item: SettingsSection
    let active: Bool
    let onTap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Text(item.folio + ".")
                    .font(Editorial.serif(11.5).italic())
                    .foregroundStyle(active ? Editorial.accent : Editorial.inkMute)
                    .frame(width: 22, alignment: .trailing)
                Text(item.label)
                    .font(Editorial.serif(15, active ? .medium : .regular))
                    .foregroundStyle(Editorial.ink)
                    .tracking(-0.15)
                Spacer(minLength: 0)
                if active {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Editorial.accent)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? Editorial.page
                               : (hover ? Editorial.ink.opacity(0.04) : Color.clear))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(active ? Editorial.accent : Color.clear)
                    .frame(width: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .scrollAwareOnHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .apolloStudioNode(
            StudioNodeID(rawValue: "settings.nav.\(item.rawValue)"),
            title: item.label,
            kind: .button,
            parent: "settings.sidebar",
            properties: [
                .init(kind: .verticalPadding,
                      title: "Padding vertical", value: 10),
                .init(kind: .animationDuration,
                      title: "Hover", value: 0.12),
            ]
        )
    }
}

private struct SetSection<Content: View>: View {
    let title: String
    var sub: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Folio(title)
                if let sub { Caption("— " + sub, size: 12.5) }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 10)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Editorial.rule).frame(height: 1)
            }
            VStack(spacing: 0) { content() }
                .padding(.top, 4)
        }
        .padding(.bottom, 36)
        .apolloStudioNode(
            StudioNodeID(rawValue: "settings.section.\(title.lowercased())"),
            title: title,
            kind: .section,
            parent: "settings.content",
            properties: [
                .init(kind: .verticalPadding,
                      title: "Distância entre seções", value: 36),
            ]
        )
    }
}

private struct SetRow<Control: View>: View {
    let label: String
    var sub: String? = nil
    var emBreve: Bool = false
    var divider: Bool = true
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(label)
                            .font(Editorial.serif(15))
                            .foregroundStyle(Editorial.ink)
                            .tracking(-0.15)
                        if emBreve { EmBreveBadge() }
                    }
                    if let sub {
                        Caption(sub, size: 12.5)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 520, alignment: .leading)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) { control() }
                    .disabled(emBreve)
                    .opacity(emBreve ? 0.5 : 1)
            }
            .padding(.vertical, 16)
            if divider {
                Rectangle().fill(Editorial.ruleSoft).frame(height: 1)
            }
        }
        .apolloStudioNode(
            StudioNodeID(rawValue: "settings.row.\(label.lowercased())"),
            title: label,
            kind: .row,
            parent: "settings.content",
            properties: [
                .init(kind: .verticalPadding,
                      title: "Padding vertical", value: 16),
                .init(kind: .spacing, title: "Espaçamento", value: 24),
            ]
        )
    }
}

private struct EmBreveBadge: View {
    var body: some View {
        Text("EM BREVE")
            .font(Editorial.sans(9, .semibold))
            .tracking(0.8)
            .foregroundStyle(Editorial.inkMute)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Editorial.ruleSoft))
    }
}

private struct SetToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Editorial.ink : Editorial.rule)
                    .frame(width: 36, height: 20)
                Circle()
                    .fill(Editorial.page)
                    .frame(width: 16, height: 16)
                    .padding(2)
                    .shadow(color: .black.opacity(0.20), radius: 1, y: 1)
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .animation(.easeInOut(duration: 0.15), value: isOn)
    }
}

private struct SetSelect<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, label: String)]

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { o in
                Button(o.label) { selection = o.value }
            }
        } label: {
            HStack(spacing: 6) {
                Text(options.first { $0.value == selection }?.label ?? "—")
                    .font(Editorial.sans(12.5))
                    .foregroundStyle(Editorial.ink)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Editorial.inkMute)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Editorial.page))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Editorial.rule, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct SetButton: View {
    enum Kind { case normal, primary, danger }
    let title: String
    var kind: Kind = .normal
    var emBreve: Bool = false
    let action: () -> Void

    init(_ title: String, kind: Kind = .normal,
         emBreve: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.kind = kind
        self.emBreve = emBreve; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Editorial.sans(12.5, .medium))
                .foregroundStyle(fg)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(bg))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(emBreve)
        .opacity(emBreve ? 0.5 : 1)
    }

    private var fg: Color {
        switch kind {
        case .primary: return Editorial.page
        case .danger:  return Editorial.accent
        case .normal:  return Editorial.ink
        }
    }
    private var bg: Color {
        kind == .primary ? Editorial.ink : Editorial.page
    }
    private var border: Color {
        switch kind {
        case .primary: return Editorial.ink
        case .danger:  return Editorial.accent
        case .normal:  return Editorial.rule
        }
    }
}

private struct SetInput: View {
    @Binding var text: String
    var mono: Bool = false
    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(mono ? Editorial.mono(12.5) : Editorial.serif(14))
            .foregroundStyle(Editorial.ink)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(width: 220)
            .background(RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Editorial.page))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Editorial.rule, lineWidth: 1))
    }
}

private struct KbdCombo: View {
    let combo: String
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(combo.enumerated()), id: \.offset) { _, c in
                Text(String(c))
                    .font(Editorial.sans(11.5, .medium))
                    .foregroundStyle(Editorial.ink)
                    .frame(minWidth: 16)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Editorial.card))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(Editorial.rule, lineWidth: 1))
    }
}

private struct SettingsAvatar: View {
    let letter: String
    var size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(Editorial.accent.opacity(0.14))
            Text(letter)
                .font(Editorial.serif(size * 0.42, .medium))
                .foregroundStyle(Editorial.accent)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Editorial.rule, lineWidth: 1))
    }
}

// MARK: - ClickUp Section

private struct ClickUpSection: View {
    @EnvironmentObject var appState: AppState
    @Binding var showListPicker: Bool

    var body: some View {
        GlassSectionCard(title: "ClickUp", icon: "checkmark.circle") {
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
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let err = appState.clickUpAuthService.connectionError {
                    GlassWarningRow(err, tint: .red)
                }

                accentButton("Conectar com ClickUp", icon: "checkmark.circle") {
                    appState.clickUpAuthService.startConnection()
                }
            }
        }
    }

    private var waitingForTokenView: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassFormRow {
                Image(systemName: "key.viewfinder")
                    .font(.callout)
                    .foregroundStyle(Editorial.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cole seu token do ClickUp")
                        .font(.subheadline.weight(.medium))
                    Text("No browser, clique em **Copiar** ao lado do seu token e cole abaixo.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancelar") { appState.clickUpAuthService.cancelConnection() }
                    .buttonStyle(.plain).focusEffectDisabled()
                    .font(.caption.weight(.medium)).foregroundStyle(.red)
            }

            // Explicit paste field replaces the previous
            // clipboard-polling flow — Apollo only ever sees the
            // token the user deliberately pastes here, never
            // anything else copied during a 2-minute window.
            HStack(spacing: 8) {
                SecureField("pk_…", text: $pastedClickUpToken)
                    .textFieldStyle(.roundedBorder)
                    .focusEffectDisabled()
                    .onSubmit { confirmPastedClickUpToken() }
                Button("Conectar") { confirmPastedClickUpToken() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(pastedClickUpToken
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty)
            }

            if let err = appState.clickUpAuthService.connectionError {
                GlassWarningRow(err, tint: .red)
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
            GlassFormRow {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(appState.clickUpAuthService.userName ?? "Conectado")
                        .font(.subheadline).lineLimit(1)
                    if let ws = appState.clickUpAuthService.workspaceName {
                        Text(ws).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Button("Sair") { appState.clickUpAuthService.disconnect() }
                    .buttonStyle(.plain).focusEffectDisabled()
                    .font(.caption.weight(.medium)).foregroundStyle(.red)
            }
            GlassFormRow {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lista de tarefas").font(.caption).foregroundStyle(.secondary)
                    Text(listSummary).font(.caption.weight(.medium))
                }
                Spacer()
                Button("Selecionar") { showListPicker = true }
                    .buttonStyle(.plain).focusEffectDisabled()
                    .font(.caption.weight(.medium)).foregroundStyle(.blue)
            }
            doneActionRow
        }
    }

    /// One row per current-status, letting the user pick where DONE should
    /// move the task FROM that status. Example: "DOING → REVIEW",
    /// "REVIEW → COMPLETE". Empty when ClickUp statuses haven't loaded yet.
    private var doneActionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ação do botão Done por status")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 4) {
                if appState.availableStatuses.isEmpty {
                    GlassFormRow {
                        Text("Nenhum status disponível")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                } else {
                    ForEach(appState.availableStatuses) { s in
                        doneActionMappingRow(for: s)
                    }
                }
            }
        }
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

        return GlassFormRow {
            // ── Block 1: current status (read-only)
            HStack(spacing: 4) {
                Circle().fill(curColor).frame(width: 6, height: 6)
                Text(current.status.uppercased())
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(curColor)
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
                        Text(t.status.uppercased())
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(tColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    HStack(spacing: 4) {
                        Text("Selecionar")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.blue)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.blue.opacity(0.7))
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .focusEffectDisabled()
            .frame(width: 130, alignment: .leading)

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
        GlassSectionCard(title: "Apollo IA", icon: "sparkles") {
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

    /// Two-button segmented selector — visually clearer than a
    /// SwiftUI Picker for two options.
    private var backendPicker: some View {
        HStack(spacing: 8) {
            // Use the curated `userSelectable` list — `.embedded`
            // is hidden because the bundled local 7B model is
            // disabled (too heavy on the host system).
            ForEach(LLMBackend.userSelectable) { backend in
                let active = appState.aiAgent.backend == backend
                Button {
                    appState.aiAgent.setBackend(backend)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: backend.systemImage)
                            .font(.caption)
                        Text(backend.label)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(active ? AnyShapeStyle(Editorial.accent)
                                            : AnyShapeStyle(Color.primary))
                    .background(
                        active ? Editorial.accent.opacity(0.14) : Color.clear,
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            active ? Editorial.accent.opacity(0.40)
                                   : Color.primary.opacity(0.10),
                            lineWidth: 0.6
                        )
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
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
                        .font(.subheadline.weight(.semibold))
                    Text("Roda 100% local, sem chave, sem rede.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Text("O modelo de IA vem embutido no Apollo. Privacidade total: tarefas e eventos nunca saem do seu Mac. Funciona offline.")
                .font(.caption)
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
                .font(.caption)
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
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(GroqProvider.availableModels) { opt in
                    let active = selectedModelId == opt.id
                    Button {
                        selectedModelId = opt.id
                        UserDefaults.standard.set(opt.id,
                                                   forKey: GroqProvider.modelDefaultsKey)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: active
                                ? "largecircle.fill.circle"
                                : "circle")
                                .foregroundStyle(active
                                    ? Editorial.accent
                                    : Color.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(opt.label)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(opt.trpHint)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                                Text(opt.qualityHint)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            active
                                ? Editorial.accent.opacity(0.10)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
                Text("⚡ Recuperação automática: se o modelo escolhido recusar a request com 413 (input grande), o Apollo refaz a chamada com `Llama 3.1 8B Instant` (TPR maior).")
                    .font(.caption2)
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
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(savedFlash ? Color.green : Editorial.accent, in: Capsule())
                }
                .buttonStyle(.plain).focusEffectDisabled()

                if isConfigured {
                    Label("Conectado", systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                } else {
                    Label("Não configurado", systemImage: "key.slash")
                        .font(.caption2).foregroundStyle(.tertiary)
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
                .font(.caption)
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
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(savedFlash ? Color.green : Editorial.accent, in: Capsule())
                }
                .buttonStyle(.plain).focusEffectDisabled()

                if isConfigured {
                    Label("Conectado", systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                } else {
                    Label("Não configurado", systemImage: "key.slash")
                        .font(.caption2).foregroundStyle(.tertiary)
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
                .font(.caption)
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
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(savedFlash ? Color.green : Editorial.accent, in: Capsule())
                }
                .buttonStyle(.plain).focusEffectDisabled()

                if isConfigured {
                    Label("Conectado", systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                } else {
                    Label("Não configurado", systemImage: "key.slash")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }

            Divider().opacity(0.4)

            Text("Modelo")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                ForEach(OpenAIProvider.availableModels) { opt in
                    Button {
                        selectedModelId = opt.id
                        UserDefaults.standard.set(opt.id,
                                                  forKey: OpenAIProvider.modelDefaultsKey)
                        appState.aiAgent.setBackend(.openai)
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: selectedModelId == opt.id
                                  ? "largecircle.fill.circle"
                                  : "circle")
                                .foregroundStyle(selectedModelId == opt.id
                                                 ? Editorial.accent : .secondary)
                                .font(.callout)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(opt.label)
                                        .font(.caption.weight(.semibold))
                                    Text(opt.priceHint)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                Text(opt.qualityHint)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selectedModelId == opt.id
                                      ? Editorial.accent.opacity(0.10)
                                      : Color.primary.opacity(0.04))
                        )
                    }
                    .buttonStyle(.plain).focusEffectDisabled()
                }
            }
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
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isAvailable ? .green : .orange)
                Text(isAvailable
                     ? "Apple Intelligence ativo neste Mac."
                     : "Indisponível neste Mac. Requer macOS 26 ou posterior em Apple Silicon, com Apple Intelligence habilitado em Ajustes do Sistema.")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label("Sem rate limit por minuto", systemImage: "infinity")
                Label("Privacidade total — nada sai do seu Mac", systemImage: "lock.shield.fill")
                Label("Sem custo, sem chave de API", systemImage: "dollarsign.circle.fill")
            }
            .font(.caption2)
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
                .font(.caption)
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
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Editorial.accent, in: Capsule())
                }
                .buttonStyle(.plain).focusEffectDisabled()
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
            .buttonStyle(.plain).focusEffectDisabled()
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
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        switch appState.aiAgent.ollama.modelStatus {
        case .ready(let name):
            Label("Modelo: \(name)", systemImage: "cube.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .pulling(let name, let fraction, let stage):
            VStack(alignment: .leading, spacing: 4) {
                Label("Baixando \(name)…", systemImage: "arrow.down.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(.orange)
                Text(stage)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        case .noneInstalled:
            Label("Sem modelos instalados", systemImage: "cube.box")
                .font(.caption2)
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
        GlassSectionCard(title: "Google Calendar (convites)", icon: "envelope.badge") {
            VStack(alignment: .leading, spacing: 10) {
                if appState.googleAuth.isConnected {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Conectado")
                                .font(.subheadline.weight(.semibold))
                            if let email = appState.googleAuth.connectedEmail {
                                Text(email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            appState.googleAuth.disconnect()
                        } label: {
                            Text("Desconectar")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                    Text("Eventos criados no Apollo com convidados são enviados via Google API com notificação por email.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !appState.googleAuth.hasClientId {
                    // Apollo was built without an embedded
                    // OAuth Client ID — the developer needs to
                    // fill in `GoogleAuthService.embeddedClientId`
                    // before the connect button can do anything.
                    Text("Conexão com o Google ainda não foi configurada nesta build do Apollo. Atualize a constante `GoogleAuthService.embeddedClientId` no código fonte com o OAuth Client ID do projeto Google Cloud.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Conecte sua conta Google para que eventos criados no Apollo com convidados enviem invites de verdade. Sem isso, EventKit do macOS não consegue adicionar attendees.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        Task { await appState.googleAuth.connect() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                                .font(.caption)
                            Text(appState.googleAuth.inProgress ? "Conectando…" : "Conectar Google")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(Editorial.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .disabled(appState.googleAuth.inProgress)

                    if let err = appState.googleAuth.lastError {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

private struct AppSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        GlassSectionCard(title: "App", icon: "gearshape") {
            VStack(spacing: 6) {
                GlassFormRow {
                    Text("Aparência").font(.subheadline)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { appState.appearanceMode },
                        set: { appState.setAppearanceMode($0) }
                    )) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                GlassFormRow {
                    Toggle("Modo menu bar", isOn: Binding(
                        get: { appState.menuBarMode },
                        set: { appState.setMenuBarMode($0) }
                    ))
                    .font(.subheadline)
                }
                GlassFormRow {
                    Text("Auto-sincronizar").font(.subheadline)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { appState.autoSyncInterval },
                        set: { appState.setAutoSyncInterval($0) }
                    )) {
                        Text("Desativado").tag(0)
                        Text("5 min").tag(5)
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                        Text("1 hora").tag(60)
                    }
                    .pickerStyle(.menu).frame(width: 120)
                }
                GlassFormRow {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Notificações do macOS").font(.subheadline)
                        Text("Espelha as notificações do app no Centro de Notificações do sistema.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { appState.nativeNotificationsEnabled },
                        set: { appState.setNativeNotificationsEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }
            }
        }
    }
}

// MARK: - Shared field helpers (file-private)

@ViewBuilder
private func glassLabeledField(_ label: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(label).font(.caption).foregroundStyle(.secondary)
        GlassTextField("", text: text)
    }
}

@ViewBuilder
private func glassLabeledSecureField(_ label: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(label).font(.caption).foregroundStyle(.secondary)
        SecureField("", text: text)
            .textFieldStyle(.plain).font(.body)
            .padding(.horizontal, 12).padding(.vertical, 9)
            // Same per-popup backdrop-filter savings as
            // `GlassTextField`; see GlassFormComponents.
            .background(Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
            )
    }
}

@ViewBuilder
private func accentButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Label(label, systemImage: icon)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(Editorial.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .buttonStyle(.plain)
    .focusEffectDisabled()
}

// `CalendarPickerSheet` was removed alongside the EventKit
// integration. With Google as the single calendar source we
// always show the user's primary Google Calendar — no
// per-calendar selection UI is needed for now.

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
    /// stars + the "Fixadas" section re-render on toggle.
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
        RoundedRectangle(cornerRadius: Editorial.popupRadius(4.5), style: .continuous)
    }

    var body: some View {
        Group {
            if compact { compactBody } else { wideBody }
        }
        .popupGlass(in: shape)
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
        .frame(width: 700, height: 460)
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
        .frame(width: 380, height: 460)
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
                        crumb(selectedSpace?.name ?? "Space",
                              icon: "folder", active: true)
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
            workspacesColumn.frame(width: 200)
            divider
            spacesColumn.frame(width: 220)
            divider
            listsColumn.frame(minWidth: 240)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var errorRow: some View {
        if let error {
            Rectangle().fill(Editorial.rule).frame(height: 1)
            GlassWarningRow(error, tint: Editorial.accent)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
        }
    }

    private var workspacesColumn: some View {
        pickerColumn(title: "Workspace",
                     icon:  "building.2.fill",
                     count: workspaces.count,
                     loading: loadingWorkspaces) {
            if workspaces.isEmpty && !loadingWorkspaces {
                emptyHint(icon: "building.2", text: "Sem workspaces")
            } else {
                ForEach(workspaces) { ws in
                    row(name: ws.name,
                        icon: "building.2.fill",
                        selected: selectedWorkspace?.id == ws.id,
                        action: { selectWorkspace(ws) })
                }
            }
        }
    }

    private var spacesColumn: some View {
        pickerColumn(title: "Space",
                     icon:  "folder.fill",
                     count: spaces.count,
                     loading: loadingSpaces || restoringSelection,
                     scrollTarget: selectedSpace?.id) {
            if restoringSelection && selectedWorkspace == nil {
                emptyHint(icon: "arrow.triangle.2.circlepath",
                          text: "Procurando lista atual…")
            } else if selectedWorkspace == nil {
                emptyHint(icon: "arrow.left", text: "Escolha um workspace")
            } else if spaces.isEmpty && !loadingSpaces {
                emptyHint(icon: "folder", text: "Sem spaces")
            } else {
                ForEach(spaces) { sp in
                    row(name: sp.name,
                        icon: "folder.fill",
                        selected: selectedSpace?.id == sp.id,
                        action: { selectSpace(sp) })
                        .id(sp.id)
                }
            }
        }
    }

    // MARK: - Header & footer

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Folio("Selecionar lista")
                Caption("onde suas tarefas serão lidas no Apollo", size: 13)
            }

            Spacer(minLength: 0)

            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .regular))
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

    private var footer: some View {
        HStack(spacing: 10) {
            // Breadcrumb of the current selection
            HStack(spacing: 7) {
                breadcrumbChip(text: selectedWorkspace?.name ?? "—",
                               icon: "building.2")
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Editorial.inkFaint)
                breadcrumbChip(text: selectedSpace?.name ?? "—",
                               icon: "folder")
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Editorial.inkFaint)
                breadcrumbChip(text: currentListName ?? "—",
                               icon: "list.bullet")
            }
            .lineLimit(1)
            .truncationMode(.tail)

            Spacer()

            Button { close() } label: {
                Text("Fechar")
                    .font(Editorial.sans(12.5, .medium))
                    .foregroundStyle(Editorial.ink)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .liquidGlass(in: RoundedRectangle(cornerRadius: 4,
                                                      style: .continuous),
                                 tint: Editorial.page, tintOpacity: 0.6)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Editorial.rule, lineWidth: 1))
            }
            .buttonStyle(.plain).focusEffectDisabled()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var currentListName: String? {
        lists.first(where: { $0.id == selectedListId })?.name
            ?? KeychainHelper.load(for: KeychainHelper.Keys.clickupListName)
    }

    private func breadcrumbChip(text: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(Editorial.sans(11.5, .medium))
        }
        .foregroundStyle(Editorial.inkSoft)
    }

    // MARK: - Lists column (with search)

    private var listsColumn: some View {
        VStack(spacing: 0) {
            columnHeader(title: "Lista",
                         icon: "list.bullet",
                         count: filteredLists.count)

            if selectedSpace != nil && !lists.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Editorial.inkMute)
                    TextField("Buscar lista", text: $listFilter)
                        .textFieldStyle(.plain)
                        .font(Editorial.serif(13))
                        .foregroundStyle(Editorial.ink)
                }
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Editorial.rule).frame(height: 1)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }

            ZStack {
                if loadingLists || (restoringSelection && selectedSpace == nil) {
                    ProgressView().controlSize(.small)
                } else if selectedSpace == nil {
                    emptyHint(icon: "arrow.left", text: "Escolha um space")
                } else if filteredLists.isEmpty {
                    emptyHint(icon: "list.bullet",
                              text: lists.isEmpty
                              ? "Sem listas neste space"
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
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            columnHeader(title: title, icon: icon, count: count)

            ZStack {
                if loading {
                    ProgressView().controlSize(.small)
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

    private func columnHeader(title: String, icon _: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(Editorial.sans(10, .semibold))
                .foregroundStyle(Editorial.inkMute)
                .tracking(1.2)
            if count > 0 {
                Text("\(count)")
                    .font(Editorial.sans(9, .bold))
                    .foregroundStyle(Editorial.inkSoft)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Editorial.rule))
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Editorial.card)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Editorial.rule).frame(height: 1)
        }
    }

    /// List row with a trailing pin/unpin star. The star is a
    /// separate hit target from the main row body so clicking
    /// it toggles the pin WITHOUT also selecting the list.
    private func listRow(_ list: CUList) -> some View {
        ListPickerRow(
            name: list.name,
            icon: "list.bullet",
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
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Editorial.inkMute)
            Text(text)
                .font(Editorial.serif(13).italic())
                .foregroundStyle(Editorial.inkMute)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
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
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Editorial.accent)
                    Folio("Fixadas")
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(pinned.sorted { $0.name < $1.name }) { entry in
                            let sel = selectedListId == entry.id
                            Button {
                                pickById(id: entry.id, name: entry.name)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "list.bullet")
                                        .font(.system(size: 9))
                                    Text(entry.name)
                                        .font(Editorial.sans(11.5, .medium))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(sel ? Editorial.accent : Editorial.ink)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                // Liquid Glass pill — accent-tinted when
                                // selected, neutral page glass at rest.
                                .liquidGlassCapsule(
                                    tint: sel ? Editorial.accent : Editorial.page,
                                    tintOpacity: sel ? 0.16 : 0.55)
                                .overlay(
                                    Capsule().strokeBorder(
                                        sel ? Editorial.accent : Editorial.rule,
                                        lineWidth: 1)
                                )
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .glassHover()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }
                Rectangle().fill(Editorial.rule).frame(height: 1)
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
            await MainActor.run { self.error = error.localizedDescription; loadingWorkspaces = false }
        }
    }

    private func loadSpaces(for ws: CUWorkspace) async {
        loadingSpaces = true; error = nil
        do {
            let sp = try await svc.getSpaces(workspaceId: ws.id)
            await MainActor.run { spaces = sp; loadingSpaces = false }
        } catch {
            await MainActor.run { self.error = error.localizedDescription; loadingSpaces = false }
        }
    }

    private func loadLists(for space: CUSpace) async {
        loadingLists = true; error = nil
        do {
            let ls = try await svc.getLists(spaceId: space.id)
            await MainActor.run { lists = ls; loadingLists = false }
        } catch {
            await MainActor.run { self.error = error.localizedDescription; loadingLists = false }
        }
    }
}

// MARK: - Editorial list-picker row (prototype `PListPicker`)

/// One row in any of the three columns. Editorial: no fill —
/// the active row reads through a cinnabar glyph + cinnabar
/// check + serif title (prototype `PListPicker`); a hover wash
/// gives pointer feedback; rows self-divide with a `ruleSoft`
/// hairline. `listRow` also passes a pin star (cinnabar when
/// pinned) on a separate hit target.
private struct ListPickerRow: View {
    let name: String
    let icon: String
    let selected: Bool
    var pinned: Bool? = nil
    var onPinToggle: (() -> Void)? = nil
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? Editorial.accent : Editorial.inkSoft)
                        .frame(width: 16)
                    Text(name)
                        .font(Editorial.serif(15))
                        .foregroundStyle(Editorial.ink)
                        .tracking(-0.15)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Editorial.accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if let pinned, let onPinToggle {
                Button(action: onPinToggle) {
                    Image(systemName: pinned ? "star.fill" : "star")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(pinned ? Editorial.accent : Editorial.inkMute)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(pinned ? "Desafixar lista" : "Fixar lista pra acesso rápido")
                .opacity(pinned || hover ? 1 : 0.35)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hover ? Editorial.ink.opacity(0.04) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Editorial.ruleSoft).frame(height: 1)
        }
        .scrollAwareOnHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}
