import SwiftUI

// First-run onboarding popup. Walks the user through:
//   1. Calendar (EventKit) access
//   2. ClickUp account connection
//   3. Pick a ClickUp list (where tasks live)
//
// Each step auto-advances as soon as its completion condition becomes
// true (we observe AppState live), so the user typically just hits
// "Permitir" / "Conectar" / "Selecionar" three times and they're done.
//
// Triggered automatically on launch by ContentView when any source is
// missing AND the user hasn't yet finished or skipped onboarding.

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    var onClose: () -> Void = {}

    @State private var step:           Step = .welcome
    @State private var showListPicker  = false

    /// Local buffer for the pasted ClickUp token while the user
    /// is confirming. Replaces the legacy clipboard-polling
    /// flow — the service no longer reads the pasteboard
    /// implicitly, so the UI owns the typed value.
    @State private var pastedClickUpToken: String = ""

    enum Step: Int, CaseIterable {
        // Google + ClickUp are connected together on a single
        // `integrations` screen (the prototype's "explanation
        // on top, content below" full-width layout — no more
        // two-pane spread). `swipe` then teaches the trackpad
        // gesture and `palette` the ⌘K command palette — the
        // two discoverability wins power users keep returning to.
        case welcome, integrations, list, swipe, palette, done
    }

    /// Whether the user has a Gemini API key configured. The
    /// onboarding's AI step now configures the cloud Gemini
    /// provider (default backend) instead of downloading the
    /// retired local 7B GGUF — much lighter on the host system
    /// and much faster end-to-end.
    /// True when the user's currently-selected backend is
    /// fully configured and ready to chat. Each backend has
    /// its own readiness check — Gemini/Groq need an API key,
    /// embedded needs the model on disk, Apple Intelligence
    /// just needs the OS to support it.
    private var aiReady: Bool {
        switch appState.aiAgent.backend {
        case .gemini:
            let key = KeychainHelper.load(for: KeychainHelper.Keys.geminiApiKey) ?? ""
            return key.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20
        case .groq:
            let key = KeychainHelper.load(for: KeychainHelper.Keys.groqApiKey) ?? ""
            return key.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20
        case .embedded:
            return appState.aiAgent.embeddedRuntime.isModelDownloaded
        case .appleIntelligence:
            return AppleIntelligenceProvider().isConfigured
        case .ollama:
            return appState.aiAgent.ollama.daemonStatus == .running
        case .openai:
            let key = KeychainHelper.load(for: KeychainHelper.Keys.openaiApiKey) ?? ""
            return key.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20
        }
    }
    /// Live bindings for API-key drafts typed in the AI step.
    /// Lifted to top-level `@State` so values survive a step
    /// revisit (user types, advances, comes back).
    @State private var geminiKeyDraft: String = ""
    @State private var geminiSavedFlash: Bool = false
    @State private var groqKeyDraft: String = ""
    @State private var groqSavedFlash: Bool = false
    @State private var openaiKeyDraft: String = ""
    @State private var openaiSavedFlash: Bool = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
    }

    /// "Calendar step" passes when the user is connected to
    /// Google. EventKit access is no longer required — Apollo
    /// reads events from Google's API directly. Existing
    /// EventKit access is harmless, just unused.
    private var calendarReady: Bool { appState.googleAuth.isConnected }
    private var clickupReady:  Bool { appState.clickUpAuthService.isConnected }
    private var listReady:     Bool {
        KeychainHelper.load(for: KeychainHelper.Keys.clickupListId) != nil
    }

    /// Hand the typed token to the auth service. On success the
    /// service flips `isConnected` (the step then advances). On
    /// failure `connectionError` is set and the field stays
    /// populated so the user can fix and retry.
    private func confirmPastedClickUpToken() {
        let raw = pastedClickUpToken
        if appState.clickUpAuthService.submitToken(raw) {
            pastedClickUpToken = ""
        }
    }

    var body: some View {
        // Prototype `POnboarding` — a full-bleed editorial page:
        // a hairline progress bar across the top, then ONE
        // single-width column — kicker + display headline + body
        // explanation up top, the step's interactive content
        // below it, and the navigation spanning the full window
        // width along the bottom. No two-pane spread.
        VStack(spacing: 0) {
            progressBar
            page
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Editorial.paper)
        .overlay(alignment: .topTrailing) {
            Button { dismissPermanently() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Editorial.inkSoft)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .padding(.top, 16)
            .padding(.trailing, 20)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: step)
        // Auto-advance the moment a step's prerequisite is satisfied.
        // The merged integrations step only advances once BOTH
        // sources are connected.
        .onChange(of: calendarReady) { _, _ in advanceIfIntegrationsDone() }
        .onChange(of: clickupReady)  { _, _ in advanceIfIntegrationsDone() }
        .onChange(of: listReady) { _, ok in
            if ok, step == .list { advance() }
        }
        .sheet(isPresented: $showListPicker) {
            CUListPickerSheet().environmentObject(appState)
        }
    }

    // MARK: - Spread chrome

    private var progressBar: some View {
        let total = max(1, Step.allCases.count)
        let frac  = CGFloat(step.rawValue + 1) / CGFloat(total)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Editorial.rule)
                Rectangle().fill(Editorial.accent)
                    .frame(width: max(0, geo.size.width * frac))
            }
        }
        .frame(height: 3)
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: step)
    }

    // MARK: - Page (single full-width editorial column)

    /// One column, full window width: editorial kicker + display
    /// headline + body explanation up top, the step's interactive
    /// content directly below it, then the navigation row running
    /// the full width along the bottom.
    private var page: some View {
        let copy = stepCopy(step)
        return VStack(alignment: .leading, spacing: 0) {
            Folio(copy.kicker)

            Spacer(minLength: 30)

            VStack(alignment: .leading, spacing: 20) {
                copy.headline
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(copy.body)
                    .font(Editorial.serif(17))
                    .foregroundStyle(Editorial.inkSoft)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 680, alignment: .leading)

                stepWidget
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 14)
            }

            Spacer(minLength: 30)

            // Footer nav — a 60×1 ink rule, then the controls
            // stretched across the full content width.
            Rectangle().fill(Editorial.ink).frame(width: 60, height: 1)
                .padding(.bottom, 20)
            footerNav
        }
        .padding(.top, 60)
        .padding(.horizontal, 72)
        .padding(.bottom, 46)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The step's interactive content, shown below the editorial
    /// explanation. Welcome + Done are copy-only (no widget).
    @ViewBuilder
    private var stepWidget: some View {
        switch step {
        case .welcome, .done:
            EmptyView()
        case .integrations:
            integrationsStep
        case .list:
            listStep.frame(maxWidth: 380, alignment: .leading)
        case .swipe:
            swipeStep.frame(maxWidth: 640, alignment: .leading)
        case .palette:
            paletteStep.frame(maxWidth: 640, alignment: .leading)
        }
    }

    /// Bottom navigation, full content width: back / skip on the
    /// left, the "n de N" marker + primary CTA on the right.
    private var footerNav: some View {
        HStack(spacing: 18) {
            if step.rawValue > 0 {
                Button { goBack() } label: {
                    Text("← Voltar")
                        .font(Editorial.sans(13, .medium))
                        .foregroundStyle(Editorial.inkSoft)
                }
                .buttonStyle(.plain).focusEffectDisabled()
            }
            if step != .done {
                Button { dismissPermanently() } label: {
                    Text("Pular tutorial")
                        .font(Editorial.sans(13, .medium))
                        .foregroundStyle(Editorial.inkMute)
                }
                .buttonStyle(.plain).focusEffectDisabled()
            }
            Spacer(minLength: 0)
            Text("\(step.rawValue + 1) de \(Step.allCases.count)")
                .font(Editorial.serif(13).italic())
                .foregroundStyle(Editorial.inkMute)
            primaryCTA
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Per-step editorial copy

    private func stepCopy(_ s: Step)
        -> (kicker: String, headline: Text, body: String) {
        func h(_ a: String, _ italic: String, _ b: String) -> Text {
            Text(a).font(Editorial.serif(42)).foregroundStyle(Editorial.ink)
            + Text(italic).font(Editorial.serif(42).italic())
                .foregroundStyle(Editorial.inkSoft)
            + Text(b).font(Editorial.serif(42)).foregroundStyle(Editorial.ink)
        }
        switch s {
        case .welcome:
            return ("Apollo · edição inaugural",
                    h("Apollo,\n", "uma agenda ", "que lê."),
                    "Junto seu calendário e suas tarefas do ClickUp numa única superfície — e respondo sobre elas em português, sem você abrir três apps.")
        case .integrations:
            return ("I · Conectar",
                    h("Suas contas,\n", "num só ", "lugar."),
                    "Conecte o Google Calendar e o ClickUp aqui mesmo. O Google é OAuth nativo; o ClickUp é um token pessoal que fica só na sua máquina. Eventos com convidados saem com convite por email — direto pela API.")
        case .list:
            return ("II · Escolher",
                    h("Escolha a ", "lista", " principal."),
                    "Apollo precisa saber qual lista do ClickUp aparece no painel. Você troca a qualquer hora pela toolbar — e sim, suporta múltiplos workspaces.")
        case .swipe:
            return ("III · Gestos",
                    h("Aprenda ", "com a mão", "."),
                    "Deslize uma tarefa com dois dedos no trackpad: para a direita conclui, para a esquerda volta o status. Tente no cartão abaixo.")
        case .palette:
            return ("IV · Atalhos",
                    h("Tudo a um ", "⌘K", " de distância."),
                    "Busca universal de tarefa, evento ou comando. ⌘J pergunta direto pro Apollo. Funciona com ou sem acento.")
        case .done:
            return ("Pronto",
                    h("Bom ", "trabalho", "."),
                    "Setup completo. Você pode reabrir este tutorial em Configurações · Avançado sempre que quiser.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Folio("Apollo · edição inaugural")
                    betaPill(compact: true)
                }
                Text("Bem-vindo ao Apollo")
                    .font(Editorial.serif(24))
                    .foregroundStyle(Editorial.ink)
                    .tracking(-0.4)
            }
            Spacer(minLength: 0)
            Button { dismissPermanently() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Editorial.inkSoft)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Editorial.rule).frame(height: 1)
        }
    }

    /// Small "BETA" capsule used next to the wordmark in both the
    /// onboarding header and the welcome step. The compact variant
    /// sits next to the toolbar-style title; the regular variant
    /// stays inline with the larger "Apollo" text on the welcome
    /// step's hero block.
    private func betaPill(compact: Bool) -> some View {
        Text("BETA")
            .font(Editorial.sans(compact ? 9 : 10, .semibold))
            .tracking(1.4)
            .foregroundStyle(Editorial.page)
            .padding(.horizontal, compact ? 6 : 7)
            .padding(.vertical, compact ? 2 : 3)
            .background(Editorial.accent,
                        in: RoundedRectangle(cornerRadius: 2, style: .continuous))
    }

    // MARK: - Step indicator (•──•──•──✓)

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases.indices, id: \.self) { i in
                let s = Step.allCases[i]
                let active   = i <= step.rawValue
                let complete = isStepComplete(s)
                Circle()
                    .fill(complete ? Editorial.accent :
                          active   ? Editorial.accent.opacity(0.40)
                                   : Editorial.inkFaint)
                    .frame(width: 8, height: 8)
                    .overlay {
                        if complete {
                            Image(systemName: "checkmark")
                                .font(.system(size: 5.5, weight: .bold))
                                .foregroundStyle(Editorial.page)
                        }
                    }
                if i != Step.allCases.count - 1 {
                    Rectangle()
                        .fill((complete && isStepComplete(Step.allCases[i+1]))
                              ? Editorial.accent
                              : Editorial.rule)
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func isStepComplete(_ s: Step) -> Bool {
        switch s {
        case .welcome:      return step.rawValue > Step.welcome.rawValue
        case .integrations: return calendarReady && clickupReady
        case .list:         return listReady
        // Swipe + palette are purely informational —
        // counts as complete the moment the user has
        // advanced past each.
        case .swipe:    return step.rawValue > Step.swipe.rawValue
        case .palette:  return step.rawValue > Step.palette.rawValue
        case .done:     return calendarReady && clickupReady && listReady
        }
    }

    // MARK: - Step 0 — Welcome

    private var welcomeStep: some View {
        WelcomeStepView(betaPill: AnyView(betaPill(compact: false)))
    }

    /// Compact icon-tinted row used by the aiPreview step. The
    /// welcome step has its own animated copy inside
    /// `WelcomeStepView`; this one stays simple/static.
    private func bulletRow(icon: String, tint: Color,
                           title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.15))
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .font(.callout)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Step 1 — Integrations (Google + ClickUp, one screen)

    /// Both connections live side by side on a single screen so
    /// the user wires up Apollo's two data sources without a
    /// page turn between them.
    private var integrationsStep: some View {
        HStack(alignment: .top, spacing: 18) {
            integrationTile(label: "Google Calendar",
                            connected: calendarReady) {
                googleConnectControl
            }
            integrationTile(label: "ClickUp",
                            connected: clickupReady) {
                clickupConnectControl
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    /// One bordered editorial tile per integration: small-caps
    /// label + a connected check, then the connect control.
    private func integrationTile<C: View>(
        label: String,
        connected: Bool,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(label.uppercased())
                    .font(Editorial.sans(10.5, .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Editorial.inkMute)
                Spacer(minLength: 0)
                if connected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                }
            }
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Editorial.page,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Editorial.rule, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var googleConnectControl: some View {
        if !appState.googleAuth.hasClientId {
            Text("Build do Apollo sem credenciais Google embutidas. Atualize `GoogleAuthService.embeddedClientId` no código fonte.")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            actionButton(appState.googleAuth.inProgress
                         ? "Conectando…"
                         : "Conectar Google",
                         icon: "link",
                         tint: Editorial.accent) {
                Task {
                    await appState.googleAuth.connect()
                    if appState.googleAuth.isConnected {
                        await appState.sync()
                    }
                }
            }
            if let err = appState.googleAuth.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }
        }
        if calendarReady {
            let email = appState.googleAuth.connectedEmail
            successBadge("Conectado\(email.map { " · \($0)" } ?? "")")
        }
    }

    @ViewBuilder
    private var clickupConnectControl: some View {
        if appState.clickUpAuthService.isWaitingForToken {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cole o token do ClickUp:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Button {
                    appState.clickUpAuthService.cancelConnection()
                } label: {
                    Text("Cancelar").font(.caption.weight(.medium)).foregroundStyle(.red)
                }
                .buttonStyle(.plain).focusEffectDisabled()
            }
        } else {
            actionButton("Conectar com ClickUp",
                         icon: "link",
                         tint: Editorial.accent) {
                appState.clickUpAuthService.startConnection()
            }
            if let err = appState.clickUpAuthService.connectionError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.top, 6)
            }
        }
        if clickupReady {
            successBadge("Conectado como \(appState.clickUpAuthService.userName ?? "usuário ClickUp")")
        }
    }

    // MARK: - Step 3 — Pick a list

    private var listStep: some View {
        StepLayout(
            icon:  "list.bullet.rectangle",
            tint:  .purple,
            title: "Escolha a lista de tarefas",
            bodyText: "Selecione qual lista do seu workspace o Apollo vai exibir. Você pode trocar isso depois nas Configurações."
        ) {
            actionButton("Selecionar lista",
                         icon: "list.bullet",
                         tint: Editorial.accent) {
                showListPicker = true
            }
            if listReady {
                let name = KeychainHelper.load(for: KeychainHelper.Keys.clickupListName)
                successBadge("Lista escolhida: \(name ?? "selecionada")")
            }
        }
    }

    // MARK: - Step 4 — Swipe gesture demo

    /// Teaches the trackpad two-finger swipe gesture on task
    /// cards (left → mark done / right → push back). Replaced
    /// the Apollo-IA pitch which the user no longer wants in
    /// onboarding.
    @ViewBuilder
    private var swipeStep: some View {
        StepLayout(
            icon:  "hand.draw.fill",
            tint:  Editorial.accent,
            title: "Gestos de trackpad",
            bodyText: "Em qualquer tarefa da lista, deslize com **dois dedos no trackpad**: para **avançar** o status ou **voltar** ao anterior. Tente abaixo — a tarefa precisa cruzar o limite para o gesto valer."
        ) {
            SwipeDemoCard(onComplete: { [self] in
                // Only advance if we're still on this step —
                // the user might have manually navigated past
                // it before the deferred completion fires.
                guard self.step == .swipe else { return }
                self.advance()
            })
            .padding(.top, 6)
        }
    }

    // MARK: - Step 5 — Command palette announcement
    //
    // Pure "feature pitch" slide — no interactivity, no
    // gating. The user reads the copy, watches the loop
    // demonstrate ⌘K → typing → results, and clicks Next
    // when ready. We deliberately DON'T auto-advance on
    // a real ⌘K press (previous version did): some users
    // want to dwell on the slide before moving on, and a
    // gesture-triggered advance felt hijacky.

    private var paletteStep: some View {
        StepLayout(
            icon:  "command",
            tint:  Editorial.accent,
            title: "Busca rápida com ⌘K",
            bodyText: "A qualquer momento, em qualquer tela, **⌘K** abre a busca universal. Encontre tarefas, eventos ou comandos digitando o nome — funciona com ou sem acentos."
        ) {
            CommandPaletteDemoCard()
                .padding(.top, 6)
        }
    }

    // MARK: - (REMOVED) Step 4 — Apollo IA

    /// Lets the user choose which LLM backend powers Apollo IA.
    /// Each option has its own follow-up config (API key, model
    /// download, OS check) shown conditionally below the picker.
    @ViewBuilder
    private var aiStep: some View {
        StepLayout(
            icon:  "sparkles",
            tint:  Editorial.accent,
            title: "Apollo IA (opcional)",
            bodyText: "Escolha o motor que vai responder suas perguntas. Cada opção tem trade-offs diferentes — privacidade, velocidade, qualidade. Você pode trocar a qualquer momento nas Configurações."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                backendChooser
                Divider().opacity(0.4)
                conditionalBackendConfig
            }
        }
    }

    /// Vertical list of backend cards. Each card is tappable and
    /// shows: icon · name · short description. The active
    /// backend is highlighted with the accent border.
    @ViewBuilder
    private var backendChooser: some View {
        VStack(spacing: 6) {
            ForEach(LLMBackend.userSelectable) { backend in
                let active = appState.aiAgent.backend == backend
                Button {
                    appState.aiAgent.setBackend(backend)
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: backend.systemImage)
                            .font(.callout)
                            .foregroundStyle(active ? Color.white : Editorial.accent)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(active ? Editorial.accent : Editorial.accent.opacity(0.15))
                            )
                        VStack(alignment: .leading, spacing: 1) {
                            Text(backend.label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(backendShortDescription(backend))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        if active {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(Editorial.accent)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(active ? Editorial.accent.opacity(0.10) : Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                active ? Editorial.accent.opacity(0.55) : Color.primary.opacity(0.10),
                                lineWidth: active ? 1 : 0.5
                            )
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
    }

    /// Short tagline shown under each backend's name in the
    /// chooser. Conveys the trade-off in one line.
    private func backendShortDescription(_ b: LLMBackend) -> String {
        switch b {
        case .appleIntelligence: return "On-device, sem rate limit, privacidade total. Requer macOS 26+."
        case .embedded:          return "Modelo local de ~9 GB, sem chave nem internet. Pesa na máquina."
        case .gemini:            return "Cloud · grátis ~1.500 req/dia · qualidade alta. Requer chave."
        case .groq:              return "Cloud ultrarrápido · 1k req/min grátis. Requer chave."
        case .ollama:            return "Daemon local · você gerencia o modelo. Requer Ollama instalado."
        case .openai:            return "Cloud · GPT-4o/GPT-5 · pago por uso. Requer chave + cartão."
        }
    }

    /// Renders the per-backend follow-up configuration based
    /// on the user's current pick.
    @ViewBuilder
    private var conditionalBackendConfig: some View {
        switch appState.aiAgent.backend {
        case .gemini:            geminiKeyForm
        case .groq:              groqKeyForm
        case .embedded:          embeddedConfig
        case .appleIntelligence: appleIntelligenceConfig
        case .ollama:            ollamaConfig
        case .openai:            openaiKeyForm
        }
    }

    /// Minimal API-key form for OpenAI in the onboarding step
    /// (re-uses existing visual style — full settings card with
    /// model picker lives in `OpenAISettingsCard`).
    @ViewBuilder
    private var openaiKeyForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            actionButton("Abrir OpenAI Platform",
                         icon: "arrow.up.right.square",
                         tint: .blue) {
                if let url = URL(string: "https://platform.openai.com/api-keys") {
                    NSWorkspace.shared.open(url)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("Cole sua chave OpenAI (sk-…)", text: $openaiKeyDraft)
                    .textFieldStyle(.plain)
                    .font(.caption.monospaced())
                    .onSubmit { saveOpenAIKey() }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))

            HStack(spacing: 8) {
                Button { saveOpenAIKey() } label: {
                    Label(openaiSavedFlash ? "Salvo" : "Salvar chave",
                          systemImage: openaiSavedFlash
                            ? "checkmark.circle.fill" : "tray.and.arrow.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(openaiSavedFlash ? Color.green : Editorial.accent,
                                    in: Capsule())
                }
                .buttonStyle(.plain).focusEffectDisabled()
                .disabled(openaiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).count < 20)
                if aiReady {
                    Label("Conectado", systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                }
                Spacer(minLength: 0)
            }
            if aiReady { successBadge("Apollo IA pronta para usar") }
        }
        .onAppear {
            openaiKeyDraft = KeychainHelper.load(for: KeychainHelper.Keys.openaiApiKey) ?? ""
        }
    }

    private func saveOpenAIKey() {
        let trimmed = openaiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainHelper.delete(for: KeychainHelper.Keys.openaiApiKey)
        } else {
            KeychainHelper.save(trimmed, for: KeychainHelper.Keys.openaiApiKey)
        }
        openaiSavedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            openaiSavedFlash = false
        }
    }

    @ViewBuilder
    private var groqKeyForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            actionButton("Abrir Groq Console",
                         icon: "arrow.up.right.square",
                         tint: .blue) {
                if let url = URL(string: "https://console.groq.com/keys") {
                    NSWorkspace.shared.open(url)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("Cole sua chave Groq (gsk_…)", text: $groqKeyDraft)
                    .textFieldStyle(.plain)
                    .font(.caption.monospaced())
                    .onSubmit { saveGroqKey() }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))

            HStack(spacing: 8) {
                Button { saveGroqKey() } label: {
                    Label(groqSavedFlash ? "Salvo" : "Salvar chave",
                          systemImage: groqSavedFlash
                            ? "checkmark.circle.fill" : "tray.and.arrow.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(groqSavedFlash ? Color.green : Editorial.accent,
                                    in: Capsule())
                }
                .buttonStyle(.plain).focusEffectDisabled()
                .disabled(groqKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).count < 20)
                if aiReady {
                    Label("Conectado", systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                }
                Spacer(minLength: 0)
            }
            if aiReady { successBadge("Apollo IA pronta para usar") }
        }
        .onAppear {
            groqKeyDraft = KeychainHelper.load(for: KeychainHelper.Keys.groqApiKey) ?? ""
        }
    }

    private func saveGroqKey() {
        let trimmed = groqKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainHelper.delete(for: KeychainHelper.Keys.groqApiKey)
        } else {
            KeychainHelper.save(trimmed, for: KeychainHelper.Keys.groqApiKey)
        }
        groqSavedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            groqSavedFlash = false
        }
    }

    @ViewBuilder
    private var embeddedConfig: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appState.aiAgent.embeddedRuntime.isModelDownloaded {
                successBadge("Modelo local pronto (~4 GB em disco)")
            } else if case .downloading(let f, _, _) = appState.aiAgent.embeddedRuntime.status {
                Text("Baixando modelo… \(Int(f * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
                ProgressView(value: f)
                    .progressViewStyle(.linear)
            } else {
                Text("O modelo (~4 GB) será baixado automaticamente na primeira pergunta. Você pode iniciar o download agora ou esperar até abrir o chat.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actionButton("Baixar modelo agora",
                             icon: "arrow.down.circle.fill",
                             tint: .accentColor) {
                    Task { await appState.aiAgent.embeddedRuntime.downloadModel() }
                }
            }
        }
    }

    @ViewBuilder
    private var appleIntelligenceConfig: some View {
        let ready = AppleIntelligenceProvider().isConfigured
        VStack(alignment: .leading, spacing: 8) {
            if ready {
                successBadge("Apple Intelligence ativo neste Mac")
                Text("Sem chave, sem rate limit, sem custo. As perguntas e respostas nunca saem do dispositivo.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Indisponível neste Mac. Requer macOS 26 ou posterior em Apple Silicon, com Apple Intelligence habilitado em Ajustes do Sistema.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var ollamaConfig: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch appState.aiAgent.ollama.daemonStatus {
            case .running:
                successBadge("Ollama rodando em localhost:11434")
            case .starting:
                Label("Iniciando daemon Ollama…", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
            case .notInstalled:
                Text("Ollama não encontrado. Instale o app oficial em ollama.com e volte aqui.")
                    .font(.caption).foregroundStyle(.orange)
                actionButton("Abrir ollama.com",
                             icon: "arrow.up.right.square",
                             tint: .blue) {
                    if let url = URL(string: "https://ollama.com") {
                        NSWorkspace.shared.open(url)
                    }
                }
            case .stopped, .unknown:
                Text("Daemon Ollama não está rodando. Apollo tenta subir automaticamente — aguarde alguns segundos ou inicie manualmente com `ollama serve`.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var geminiKeyForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Open AI Studio in the user's default browser to
            // generate a key — one click instead of asking them
            // to copy a URL out of the body text.
            actionButton("Abrir Google AI Studio",
                         icon: "arrow.up.right.square",
                         tint: .blue) {
                if let url = URL(string: "https://aistudio.google.com/app/apikey") {
                    NSWorkspace.shared.open(url)
                }
            }

            // Compact API-key field. SecureField hides the
            // chars; we still need a thin border so it reads
            // clearly against the popup glass background.
            HStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("Cole sua chave Gemini (AIza…)", text: $geminiKeyDraft)
                    .textFieldStyle(.plain)
                    .font(.caption.monospaced())
                    .onSubmit { saveGeminiKey() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )

            HStack(spacing: 8) {
                Button {
                    saveGeminiKey()
                } label: {
                    Label(geminiSavedFlash ? "Salvo" : "Salvar chave",
                          systemImage: geminiSavedFlash
                            ? "checkmark.circle.fill"
                            : "tray.and.arrow.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(geminiSavedFlash ? Color.green : Editorial.accent,
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(geminiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).count < 20)

                if aiReady {
                    Label("Conectado", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                Spacer(minLength: 0)
            }

            if aiReady {
                successBadge("Apollo IA pronta para usar")
            }
        }
        .onAppear {
            // Pre-fill the draft from any previously-saved key
            // so re-visiting the step shows the current value.
            geminiKeyDraft = KeychainHelper.load(for: KeychainHelper.Keys.geminiApiKey) ?? ""
        }
    }

    private func saveGeminiKey() {
        let trimmed = geminiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainHelper.delete(for: KeychainHelper.Keys.geminiApiKey)
        } else {
            KeychainHelper.save(trimmed, for: KeychainHelper.Keys.geminiApiKey)
            // Make sure the runtime now points at Gemini —
            // the migration in `LLMBackend.current` already
            // moves users off the embedded backend, but this
            // covers the case where the user manually picked a
            // different backend before configuring the key.
            appState.aiAgent.setBackend(.gemini)
        }
        geminiSavedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            geminiSavedFlash = false
        }
    }

    // MARK: - Step 5 — Done

    private var doneStep: some View {
        StepLayout(
            icon:  "moon.stars.fill",
            tint:  Editorial.accent,
            title: "Tudo pronto!",
            bodyText: "Você pode criar eventos e tarefas pelos botões da barra superior, expandir uma tarefa para editar, e arrastar para mudar o tamanho do painel à direita.\n\nBoa produtividade ✨"
        ) {
            // Primary CTA ("Ver novidades") lives in the unified footer.
            EmptyView()
        }
    }

    // MARK: - Step 5 — AI preview ("coming soon")

    /// Final beat of the onboarding: a teaser for the AI integration
    /// that's on the roadmap. Uses the welcome-step layout (icon +
    /// title centred, then a list of bullet rows) instead of
    /// `StepLayout` so it can carry a more marketing-y, less
    /// instructional tone.
    private var aiPreviewStep: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            // Halo + sparkle glyph — visually distinct from the
            // other steps to signal "this is something special".
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Editorial.accent.opacity(0.30), .clear],
                            center: .center,
                            startRadius: 4,
                            endRadius: 60
                        )
                    )
                    .frame(width: 120, height: 120)
                Image(systemName: "sparkles")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Editorial.accent, Color(hex: "#FF8A4C")],
                            startPoint: .topLeading,
                            endPoint:   .bottomTrailing
                        )
                    )
                    .shadow(color: Editorial.accent.opacity(0.45),
                            radius: 14, x: 0, y: 6)
            }

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text("Em breve")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Editorial.accent, in: Capsule())
                    Text("IA no Apollo")
                        .font(.title2.weight(.semibold))
                }
                Text("Em breve, o Apollo terá uma integração com IA para impulsionar a sua produtividade.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }

            VStack(alignment: .leading, spacing: 10) {
                bulletRow(icon: "wand.and.stars",
                          tint: .purple,
                          title: "Sugestões inteligentes",
                          subtitle: "Priorização automática das tarefas com base no seu fluxo e nos seus prazos.")
                bulletRow(icon: "calendar.badge.clock",
                          tint: .indigo,
                          title: "Agenda autônoma",
                          subtitle: "Encontre horários livres, marque reuniões e resolva conflitos sem alternar de app.")
                bulletRow(icon: "text.bubble.fill",
                          tint: .teal,
                          title: "Resumos do seu dia",
                          subtitle: "Um briefing diário do que importa: o que mudou, o que vence e o que vem por aí.")
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer (skip / next)

    private var footer: some View {
        HStack(spacing: 12) {
            // ── Bottom-left cluster ─────────────────────────────────
            // Voltar (when not on the first step)
            if step.rawValue > 0 {
                Button { goBack() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                        Text("Voltar").font(Editorial.sans(12, .medium))
                    }
                    .foregroundStyle(Editorial.inkSoft)
                }
                .buttonStyle(.plain).focusEffectDisabled()
            }

            // Pular configuração — hidden on the closing screen
            // (Done): the user has finished setup, so there's
            // nothing left to skip.
            if step != .done {
                Button { dismissPermanently() } label: {
                    Text("Pular configuração")
                        .font(Editorial.sans(12, .medium))
                        .foregroundStyle(Editorial.inkMute)
                }
                .buttonStyle(.plain).focusEffectDisabled()
            }

            Spacer()

            // ── Bottom-right primary CTA ────────────────────────────
            // Always present, label changes per step. On welcome it's
            // "Começar"; on done it's "Começar a usar"; in between it's
            // "Próximo" (or "Pular esta etapa" when the current step is
            // skippable because its prerequisite isn't yet met).
            primaryCTA
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(Editorial.rule).frame(height: 1)
        }
    }

    /// Can the user skip the current step without satisfying its
    /// requirement? Calendar + ClickUp are technically optional (the app
    /// will just show empty state), so we let them be skipped.
    private var canSkipCurrentStep: Bool { !isStepComplete(step) }

    // MARK: - Navigation

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            dismissPermanently(); return
        }
        withAnimation(.spring(duration: 0.3, bounce: 0.15)) { step = next }
    }

    private func goBack() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation(.spring(duration: 0.3, bounce: 0.15)) { step = prev }
    }

    /// The merged integrations step only auto-advances once BOTH
    /// Google and ClickUp are connected — connecting just one
    /// leaves the user on the screen to finish the other.
    private func advanceIfIntegrationsDone() {
        if step == .integrations, calendarReady, clickupReady { advance() }
    }

    /// Bottom-right primary call-to-action. Same accent-filled capsule
    /// across every step; only the label and tap action change.
    private var primaryCTA: some View {
        let (label, icon, action): (String, String, () -> Void) = {
            switch step {
            case .welcome:
                return ("Começar", "arrow.right.circle.fill", { advance() })
            case .done:
                return ("Começar a usar", "arrow.right.circle.fill", { dismissPermanently() })
            default:
                let label = canSkipCurrentStep ? "Pular esta etapa" : "Próximo"
                return (label, "chevron.right", { advance() })
            }
        }()

        return Button(action: action) {
            HStack(spacing: 7) {
                Text(label)
                    .font(Editorial.sans(12.5, .medium))
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Editorial.page)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Editorial.ink))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func dismissPermanently() {
        // The check now runs on every app launch — we don't persist a
        // "never show again" flag any more. ContentView will keep this
        // popup closed for the rest of the session, but a fresh launch
        // re-evaluates the connections.
        onClose()
    }

    // MARK: - Tiny building blocks

    private func actionButton(_ label: String, icon: String, tint: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func successBadge(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.green.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(.green.opacity(0.30), lineWidth: 0.5))
        .padding(.top, 6)
    }
}

// MARK: - Shared single-step layout

private struct StepLayout<Content: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let bodyText: String
    /// In the editorial two-pane spread the LEFT page already
    /// carries the headline + body, so the RIGHT page renders
    /// only the interactive widget — `spread` drops the
    /// redundant icon tile / title / body. Default `true`:
    /// `StepLayout` is used only inside the onboarding spread.
    var spread: Bool = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        if spread {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(tint.opacity(0.15))
                        Image(systemName: icon)
                            .font(.title2)
                            .foregroundStyle(tint)
                    }
                    .frame(width: 42, height: 42)
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                }

                Text(LocalizedStringKey(bodyText))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Welcome step (cinematic 4s entrance)

/// First-impression hero for new users. Runs a ~4-second
/// cinematic on appear, inspired by the Apollo IA chat orb:
/// an aurora of slow-moving radial gradients fades in behind
/// everything, then the app icon rises with a halo bloom, the
/// "Apollo" wordmark + BETA pill drop in together, the tagline
/// and disclaimer cascade, and finally the three feature
/// bullets bounce in one by one. After the entrance settles,
/// continuous breathing loops keep the aurora and the icon
/// halo feeling alive.
private struct WelcomeStepView: View {
    let betaPill: AnyView

    /// Cascade marker — bumped from 0 (everything hidden) up
    /// through 7 (every element visible) on a staggered
    /// timetable. Per-element `.animation(_:value:)` modifiers
    /// pick up the changes and run their own springs/fades.
    @State private var phase: Int = 0

    /// Continuous loops, independent from the cascade — the
    /// aurora keeps drifting forever, even after the static
    /// content has finished its entrance.
    @State private var auroraSlow: Bool = false
    @State private var auroraFast: Bool = false
    @State private var iconBreath: Bool = false
    @State private var hueDrift:   Double = 0

    var body: some View {
        ZStack {
            // Living aurora background — three blurred radial
            // gradients in different hues, each pulsing /
            // drifting at a different rate so the composition
            // never repeats exactly.
            aurora
                .opacity(phase >= 1 ? 1 : 0)
                .animation(.easeOut(duration: 0.9).delay(0.05),
                           value: phase)

            // Foreground content.
            VStack(spacing: 18) {
                Spacer(minLength: 0)

                heroIcon
                    .opacity(phase >= 2 ? 1 : 0)
                    .scaleEffect(phase >= 2 ? 1 : 0.55)
                    .offset(y: phase >= 2 ? 0 : 18)
                    .animation(.spring(response: 0.75, dampingFraction: 0.68)
                                .delay(0.30),
                               value: phase)

                titleBlock
                    // Title + beta pill arrive together with a
                    // small lift; subtitle is part of the same
                    // VStack so it inherits the parent animation.
                    .opacity(phase >= 3 ? 1 : 0)
                    .offset(y: phase >= 3 ? 0 : 14)
                    .animation(.spring(response: 0.6, dampingFraction: 0.78)
                                .delay(0.85),
                               value: phase)

                bulletStack
                    .padding(.horizontal, 4)
                    .padding(.top, 6)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear { startEntrance() }
    }

    // MARK: - Aurora

    /// Three soft radial gradients stacked behind the content.
    /// Each one drifts at a slightly different cadence so the
    /// composition shimmers without ever repeating cleanly.
    /// A single whisper-soft cinnabar halo that breathes — the
    /// only chromatic element (replaces the tri-colour aurora).
    private var aurora: some View {
        RadialGradient(
            colors: [Editorial.accent.opacity(0.09), .clear],
            center: .center,
            startRadius: 10,
            endRadius: 420
        )
        .frame(width: 520, height: 520)
        .blur(radius: 32)
        .scaleEffect(iconBreath ? 1.06 : 0.94)
        .allowsHitTesting(false)
    }

    // MARK: - Hero icon

    /// App icon plus a coloured halo + breathing scale. The
    /// halo blooms in late and never fully settles — just keeps
    /// breathing slowly so the icon feels "alive" even after
    /// the cascade is done.
    private var heroIcon: some View {
        // Editorial mark — serif-italic cinnabar "a" on a paper
        // tile with a hairline rule (same glyph as the splash and
        // Settings · Sobre).
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Editorial.page)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Editorial.rule, lineWidth: 1)
                )
            Text("a")
                .font(.system(size: 60, weight: .regular, design: .serif))
                .italic()
                .foregroundStyle(Editorial.accent)
        }
        .frame(width: 96, height: 96)
        .shadow(color: .black.opacity(0.10), radius: 18, x: 0, y: 9)
        .scaleEffect(iconBreath ? 1.015 : 0.99)
    }

    // MARK: - Title block

    private var titleBlock: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Apollo")
                    .font(Editorial.serif(34))
                    .foregroundStyle(Editorial.ink)
                    .tracking(-0.8)
                betaPill
                    .opacity(phase >= 4 ? 1 : 0)
                    .animation(.easeOut(duration: 0.4).delay(1.10),
                               value: phase)
            }

            Text("uma agenda que lê")
                .font(Editorial.serif(15).italic())
                .foregroundStyle(Editorial.inkSoft)
                .multilineTextAlignment(.center)
                .opacity(phase >= 4 ? 1 : 0)
                .offset(y: phase >= 4 ? 0 : 8)
                .animation(.spring(response: 0.55, dampingFraction: 0.82)
                            .delay(1.25),
                           value: phase)

            Text("Você está usando uma versão Beta — algumas peças ainda estão sendo afinadas.")
                .font(Editorial.sans(11.5))
                .foregroundStyle(Editorial.inkMute)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .opacity(phase >= 4 ? 1 : 0)
                .offset(y: phase >= 4 ? 0 : 8)
                .animation(.spring(response: 0.55, dampingFraction: 0.82)
                            .delay(1.45),
                           value: phase)
        }
    }

    // MARK: - Bullet rows

    private var bulletStack: some View {
        VStack(alignment: .leading, spacing: 10) {
            bulletRow(icon: "calendar",
                      tint: .red,
                      title: "Eventos do Calendário do macOS",
                      subtitle: "Google, iCloud, Exchange — tudo o que sincroniza no Calendário aparece aqui.",
                      index: 0,
                      visiblePhase: 5)
            bulletRow(icon: "checkmark.circle",
                      tint: .indigo,
                      title: "Tarefas do ClickUp",
                      subtitle: "Edite status, prioridade, datas e responsáveis sem sair do app.",
                      index: 1,
                      visiblePhase: 6)
            bulletRow(icon: "bell.badge",
                      tint: .orange,
                      title: "Notificações inteligentes",
                      subtitle: "Saiba quando algo muda no time — toasts in-app + Centro de Notificações do macOS.",
                      index: 2,
                      visiblePhase: 7)
        }
    }

    private func bulletRow(icon: String,
                           tint: Color,
                           title: String,
                           subtitle: String,
                           index: Int,
                           visiblePhase: Int) -> some View {
        let visible = phase >= visiblePhase
        // Cascade kicks in after the title block — first bullet
        // around 1.85s, then +0.30s per row. Last row lands
        // around 2.45s, leaving the remaining 1.5s for breathing
        // loops to register before the user starts interacting.
        let delay = 1.85 + Double(index) * 0.30

        return HStack(alignment: .top, spacing: 12) {
            // Editorial marginalia: a muted tone dot instead of a
            // saturated colour tile.
            Circle()
                .fill(tint.editorialMuted)
                .frame(width: 7, height: 7)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Editorial.serif(14))
                    .foregroundStyle(Editorial.ink)
                Text(subtitle)
                    .font(Editorial.serif(12).italic())
                    .foregroundStyle(Editorial.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .opacity(visible ? 1 : 0)
        .offset(x: visible ? 0 : -14)
        .animation(.spring(response: 0.55, dampingFraction: 0.80)
                    .delay(delay),
                   value: phase)
    }

    // MARK: - Choreography

    private func startEntrance() {
        // Reset so the show always plays from the start when
        // the user re-enters the welcome step.
        phase = 0

        // Phase bumps spread across the full 4-second show.
        // Each bump is a state change that the per-element
        // `.animation(.delay(...))` modifiers above pick up,
        // so the *visual* timing comes from those delays — these
        // bumps just unlock visibility.
        let bumps: [Double] = [
            0.00,  // 1: aurora visible
            0.20,  // 2: icon visible
            0.75,  // 3: title block visible
            1.05,  // 4: subtitle / pill / disclaimer visible
            1.75,  // 5: bullet 1 visible
            2.05,  // 6: bullet 2 visible
            2.35   // 7: bullet 3 visible
        ]
        for (i, t) in bumps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                phase = i + 1
            }
        }

        // One calm breathing loop drives both the cinnabar halo
        // and the mark — no aurora, no hue drift.
        withAnimation(.easeInOut(duration: 3.4)
                        .repeatForever(autoreverses: true)) {
            iconBreath = true
        }
    }
}

// MARK: - Swipe demo card (onboarding step)

/// Animated illustration of the two-finger trackpad swipe on
/// task cards. A stylized task pill slides back and forth on
/// loop, with green ✓ on the left and orange ↩︎ on the right
/// to telegraph the two swipe directions and their actions.
// MARK: - SwipeChallenge (interactive)
//
// Interactive trackpad-swipe tutorial — the user has to
// actually perform the gesture on a faux task tile to
// progress past the step. Mirrors the production
// `TaskRowCellItem` swipe pipeline as closely as a tutorial
// reasonably can:
//
//   • Same scroll-wheel driver. `event.hasPreciseScrollingDeltas`
//     gates trackpad-only (mouse wheels skip), `event.phase`
//     drives the same began/changed/ended state machine the
//     real cell uses.
//   • Same axis-lock at the first 0.5pt of motion — vertical
//     gestures pass through to the parent, horizontal
//     gestures drive the offset.
//   • Action panels reveal with the same colour language the
//     real swipe uses (forward target = green, previous
//     status = orange) and slide in from their edge with the
//     same proportions.
//   • Threshold-armed haptics fire on the boundary crossing
//     (assertive double-thunk) and again on retreat (softer
//     toggle pulse) — one-to-one with the production code in
//     `TaskRowContentView.updateSwipeArmFeedback`.
//   • Below threshold: spring-back with `.interactiveSpring`
//     so the bounce feels like the real `CASpringAnimation`
//     in `cancelSwipe`.
//   • Above threshold: pill flies off-screen, success badge
//     scales in, and `onComplete` fires advancing the step.
//
// Threshold is **120pt** here (vs 220pt in production) so the
// tutorial feels approachable; the real list cards expect a
// confident drag, but in a teaching context we want any
// committed gesture to register.
private struct SwipeDemoCard: View {
    /// Fired the moment the user successfully commits a
    /// swipe (either direction past the threshold). The
    /// onboarding wrapper uses this to advance the step.
    let onComplete: () -> Void

    /// Live horizontal offset of the pill. Driven directly
    /// by the `ScrollWheelCatcher` coordinator at trackpad
    /// scroll speed (no implicit animation) during a drag,
    /// then animated explicitly on release (`.spring` for
    /// cancel, `.easeIn` for commit fly-off).
    @State private var offset: CGFloat = 0
    /// True once the user crosses the commit threshold and
    /// releases. Drives the pill's exit animation + the
    /// success-state crossfade.
    @State private var committed: Bool = false
    /// Which side the user just committed toward. Drives
    /// which colour the success badge picks up.
    @State private var commitSide: Side = .none
    /// Threshold-armed flag: true when the current drag has
    /// crossed the commit boundary. Used to bump the
    /// already-revealed action panel (scale + opacity) so
    /// the user sees that the gesture is "loaded".
    @State private var armedSide: Side = .none
    /// Subtle pulse on the two-finger hint that fades
    /// once the user has interacted at least once.
    @State private var hasInteracted: Bool = false
    /// Demo loop that nudges the pill left + right on
    /// appear so the user SEES what the gesture looks like
    /// before they try it themselves. Cancelled the moment
    /// the catcher reports the first real scroll event so
    /// the user's drag never fights an in-flight animation.
    @State private var previewTask: Task<Void, Never>?

    enum Side { case none, forward, back }

    /// Trackpad pixels the user must drag past the resting
    /// position before a release commits. Lower than the
    /// 220pt floor in production so the tutorial never
    /// frustrates a user who under-shoots — but high enough
    /// that an accidental brush of the trackpad doesn't
    /// trip it.
    private static let commitThreshold: CGFloat = 120

    var body: some View {
        VStack(spacing: 14) {
            instruction
            stage
            twoFingerHint
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06),
                              lineWidth: 0.5)
        )
        // Catcher covers the ENTIRE card, not just the
        // pill. The user can have the cursor anywhere on
        // the demo (instruction line, hint dots, empty
        // padding) and still drive the swipe — matches
        // production where the cursor doesn't need to be
        // on the row's title to swipe it. `allowsHitTesting`
        // only flips off after a commit so success state
        // can be admired without the catcher swallowing
        // future scrolls.
        //
        // `frame(maxWidth/maxHeight: .infinity)` forces the
        // NSViewRepresentable to take the full overlay area
        // — without it, an NSView with no intrinsic content
        // size can collapse to zero and the catcher ends up
        // a 0×0 sliver that catches nothing.
        .overlay(
            ScrollWheelCatcher(
                offset: $offset,
                armedSide: $armedSide,
                hasInteracted: $hasInteracted,
                threshold: Self.commitThreshold,
                onUserScrollStart: { cancelPreview() },
                onEnd: handleEnd
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(!committed)
        )
        .onAppear  { startPreview() }
        .onDisappear { cancelPreview() }
    }

    // MARK: - Pieces

    /// Instruction line above the stage. Swaps to the
    /// success copy once the user has committed.
    private var instruction: some View {
        let text: String = committed
            ? "Boa! Gesto reconhecido."
            : "Use dois dedos no trackpad sobre a tarefa abaixo"
        return Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(committed ? Color.green : .secondary)
            .id(text)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: 4)),
                removal:   .opacity.combined(with: .offset(y: -4))
            ))
            .frame(height: 14)
            .animation(.easeOut(duration: 0.25), value: committed)
    }

    /// Pill + action-panel reveal. The scroll-wheel catcher
    /// is attached one layer up (covers the whole demo
    /// card) so users don't have to aim the cursor at the
    /// pill itself. Clipped so the commit fly-off doesn't
    /// bleed past the demo container into the rest of the
    /// onboarding popup.
    private var stage: some View {
        ZStack {
            HStack(spacing: 0) {
                actionPanel(side: .forward,
                            text: "REVIEW",
                            icon: "checkmark",
                            tint: .green)
                Spacer(minLength: 0)
                actionPanel(side: .back,
                            text: "TO DO",
                            icon: "arrow.uturn.left",
                            tint: .orange)
            }
            taskPill
                .offset(x: offset)
                .opacity(committed ? 0 : 1)
            successBadge
                .opacity(committed ? 1 : 0)
                .scaleEffect(committed ? 1 : 0.92)
        }
        .frame(height: 64)
        .frame(maxWidth: .infinity)
        .clipShape(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    /// Two pulsing dots beneath the stage hinting the
    /// gesture: "drag with two fingers". Pulses gently
    /// until the user has interacted at least once, then
    /// stays calm.
    private var twoFingerHint: some View {
        HStack(spacing: 6) {
            fingerDot()
            fingerDot()
        }
        .frame(height: 14)
        .opacity(committed ? 0 : 1)
        .animation(.easeOut(duration: 0.25), value: committed)
    }

    private func fingerDot() -> some View {
        Circle()
            .fill(Editorial.accent.opacity(0.55))
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .strokeBorder(Editorial.accent.opacity(0.30),
                                  lineWidth: 1)
                    .modifier(PulseHint(active: !hasInteracted))
            )
    }

    /// Faux PARENT task pill — same anatomy as a top-level
    /// row in `TaskRowView`: checkbox · title · status pill
    /// · calendar-icon date · priority flag. Sized larger
    /// (taller, deeper shadow, 14pt corner radius) than
    /// the compact subtask variant so the user reads this
    /// as "a real task card", not a thin sub-item. Status
    /// is `DOING` so both directions of the swipe are valid
    /// (forward → REVIEW, back → TO DO).
    private var taskPill: some View {
        HStack(spacing: 10) {
            // Checkbox circle (matches the resting circle on
            // a non-completed parent row).
            Circle()
                .strokeBorder(Color.secondary.opacity(0.6),
                              lineWidth: 1.5)
                .frame(width: 16, height: 16)

            // Title — semibold like the real parent row
            // titles, sized down a touch to fit alongside
            // status + date + flag inside the popup width.
            Text("Reescrever copy do briefing")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            // Status pill — DOING, orange. Same heavy
            // tracking-0.4 caps the real `StatusPillView`
            // uses.
            Text("DOING")
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.4)
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.orange, in: Capsule())

            Spacer(minLength: 4)

            // Date — calendar icon + relative copy ("em N
            // dias"), same secondary grey + 11pt medium the
            // real row uses.
            HStack(spacing: 3) {
                Image(systemName: "calendar")
                    .font(.system(size: 9, weight: .semibold))
                Text("em 2 dias")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)

            // Priority flag — yellow, same SF Symbol the
            // real row uses for high-priority cards.
            Image(systemName: "flag.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.yellow)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.16),
                              lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18),
                radius: 6, x: 0, y: 3)
    }

    /// Success badge that crossfades in after a commit.
    /// Same colour pair the real `SwipeActionPanelView`
    /// uses for forward / back so the user closes the
    /// loop visually ("yes, that was the gesture").
    private var successBadge: some View {
        let tint: Color = commitSide == .back ? .orange : .green
        return HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(tint)
            Text("Gesto reconhecido!")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Coloured action-panel sliver behind the pill. Fades
    /// in proportional to drag distance, jumps to a
    /// stronger reveal when the user crosses the commit
    /// threshold (matching the production `armed` haptic
    /// feedback timing).
    private func actionPanel(side: Side,
                             text: String,
                             icon: String,
                             tint: Color) -> some View {
        // Reveal proportional to drag in the panel's
        // direction. Forward swipe (positive offset) reveals
        // the LEFT panel (forward target); back swipe
        // (negative offset) reveals the RIGHT panel.
        let progress: CGFloat = {
            switch side {
            case .forward:
                return max(0, min(1, offset / 100))
            case .back:
                return max(0, min(1, -offset / 100))
            default: return 0
            }
        }()
        let armed = armedSide == side
        let scale: CGFloat = armed ? 1.0 : 0.86 + 0.14 * progress
        return HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .heavy))
            Text(text)
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.4)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.95))
        )
        .opacity(progress)
        .scaleEffect(scale,
                     anchor: side == .forward ? .leading : .trailing)
        .animation(
            .spring(response: 0.30, dampingFraction: 0.85),
            value: armed
        )
    }

    // MARK: - Preview animation

    /// Demo loop that animates the pill back and forth a
    /// couple of times so the user sees what the gesture
    /// looks like before they try it. Cancelled the moment
    /// the catcher reports a real scroll event so the
    /// user's drag never fights an in-flight animation.
    /// `withAnimation(...)` drives `offset` here; the
    /// catcher overrides with `Transaction.animation = nil`
    /// during a real drag, which cleanly takes over even
    /// if the preview is mid-spring.
    private func startPreview() {
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            // Brief pause so the user reads the instruction
            // before the pill starts moving.
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, !hasInteracted else { return }

            // Two cycles: forward peek → return → back peek
            // → return. Stops there so the demo doesn't
            // become a permanent distraction; the
            // two-finger hint dots keep pulsing as a
            // gentle ongoing cue.
            for cycle in 0..<2 {
                guard !Task.isCancelled, !hasInteracted else { return }
                let direction: CGFloat = cycle.isMultiple(of: 2) ? 1 : -1
                withAnimation(.spring(response: 0.55,
                                       dampingFraction: 0.78)) {
                    offset = direction * 48
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled, !hasInteracted else { return }
                withAnimation(.spring(response: 0.55,
                                       dampingFraction: 0.78)) {
                    offset = 0
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
    }

    /// Stop the preview loop and snap the pill back to 0
    /// without animation so the user's drag picks up
    /// cleanly from rest. Called when the catcher reports
    /// the first real scroll event AND on view disappear.
    private func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
    }

    // MARK: - Commit / cancel

    /// Called by the `ScrollWheelCatcher` when the user
    /// releases. Mirrors `TaskRowContentView.handleSwipeEnd`:
    /// commit if past threshold, spring back otherwise.
    private func handleEnd(finalOffset: CGFloat) {
        let t = Self.commitThreshold
        if finalOffset > t {
            commit(.forward)
        } else if finalOffset < -t {
            commit(.back)
        } else {
            // Spring back. `.interactiveSpring` reads as the
            // physical-spring overshoot the production
            // `cancelSwipe` uses (`damping=14`).
            armedSide = .none
            withAnimation(
                .interactiveSpring(response: 0.40,
                                    dampingFraction: 0.55,
                                    blendDuration: 0)
            ) {
                offset = 0
            }
        }
    }

    /// Slide off-screen, fire the success haptic, then
    /// signal the wrapper to advance the step.
    private func commit(_ side: Side) {
        commitSide = side
        Haptics.taskAction(after: 0.05)
        withAnimation(.easeIn(duration: 0.20)) {
            offset = side == .forward ? 600 : -600
        }
        // Match the production 180ms slide-out before the
        // success state replaces the pill.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.spring(response: 0.45,
                                   dampingFraction: 0.78)) {
                committed = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
            onComplete()
        }
    }
}

// MARK: - PulseHint
//
// Soft scale + opacity pulse used on the two-finger hint
// dots. Applied via a custom modifier so the autoreverse
// loop can be cancelled by setting `active` to false when
// the user makes their first interaction — leaving the dots
// at rest afterwards.
private struct PulseHint: ViewModifier {
    let active: Bool
    @State private var phase = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(phase ? 1.6 : 1.0)
            .opacity(phase ? 0 : 0.55)
            .onAppear {
                guard active else { return }
                withAnimation(
                    .easeOut(duration: 0.9)
                        .repeatForever(autoreverses: false)
                ) { phase = true }
            }
            .onChange(of: active) { _, isActive in
                if !isActive {
                    withAnimation(.easeOut(duration: 0.20)) {
                        phase = false
                    }
                }
            }
    }
}

// MARK: - ScrollWheelCatcher
//
// Captures trackpad two-finger scroll events on top of the
// SwiftUI stage and feeds them into the parent's `offset` /
// `armedSide` bindings. Faithful to the production swipe
// state machine in `TaskRowContentView.scrollWheel`:
//
//   • Mouse wheels (no `hasPreciseScrollingDeltas`) pass
//     through — only trackpad gestures drive the demo.
//   • First 0.5pt of motion locks the axis. Vertical
//     gestures pass through unhandled (super.scrollWheel).
//   • Horizontal: accumulates `dx` and writes to `offset`
//     directly (no implicit animation — `Transaction.animation
//     = nil` so live drag tracks 1:1 with the trackpad).
//   • Threshold crossings fire the same haptics the real
//     cell uses: assertive `taskAction` on arm, softer
//     `toggle` on disarm.
//   • End: hands `accumulated` to the parent's `onEnd` for
//     the commit-vs-cancel decision.
private struct ScrollWheelCatcher: NSViewRepresentable {
    @Binding var offset: CGFloat
    @Binding var armedSide: SwipeDemoCard.Side
    @Binding var hasInteracted: Bool
    let threshold: CGFloat
    /// Fired ONCE on the first scroll event of a session
    /// so the demo can cancel its preview animation. The
    /// callback is rate-limited at the SwiftUI side via the
    /// `previewTask?.cancel()` idempotency.
    let onUserScrollStart: () -> Void
    let onEnd: (CGFloat) -> Void

    final class CatcherView: NSView {
        var onScroll: ((NSEvent) -> Void)?
        override func scrollWheel(with event: NSEvent) {
            // Only trackpad gestures drive the demo; mouse
            // wheels skip so a regular vertical scroll
            // inside the popup still works.
            if event.hasPreciseScrollingDeltas {
                onScroll?(event)
            } else {
                super.scrollWheel(with: event)
            }
        }
    }

    final class Coordinator {
        var parent: ScrollWheelCatcher
        var accumulated: CGFloat = 0
        var axis: Axis = .none
        enum Axis { case none, horizontal, vertical }

        init(_ parent: ScrollWheelCatcher) { self.parent = parent }

        func handle(_ event: NSEvent) {
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY

            switch event.phase {
            case .began:
                accumulated = 0
                axis = .none
                // Tell the SwiftUI side IMMEDIATELY so the
                // preview animation cancels before we
                // produce our first delta — that way the
                // user's drag picks up from `0` cleanly,
                // not from a half-finished spring.
                DispatchQueue.main.async {
                    self.parent.onUserScrollStart()
                }

            case .changed:
                if axis == .none {
                    let mag = max(abs(dx), abs(dy))
                    guard mag > 0.5 else { return }
                    axis = abs(dx) > abs(dy)
                        ? .horizontal : .vertical
                }
                guard axis == .horizontal else { return }
                accumulated += dx
                let final = accumulated
                let newArmed: SwipeDemoCard.Side = {
                    if final >  parent.threshold { return .forward }
                    if final < -parent.threshold { return .back    }
                    return .none
                }()
                let oldArmed = parent.armedSide
                let interactedAlready = parent.hasInteracted

                DispatchQueue.main.async {
                    var t = Transaction()
                    t.animation = nil
                    withTransaction(t) {
                        self.parent.offset = final
                    }
                    if oldArmed != newArmed {
                        self.parent.armedSide = newArmed
                        if newArmed != .none {
                            Haptics.taskAction()
                        } else {
                            Haptics.toggle()
                        }
                    }
                    if !interactedAlready {
                        self.parent.hasInteracted = true
                    }
                }

            case .ended, .cancelled:
                let final = accumulated
                let wasHorizontal = (axis == .horizontal)
                accumulated = 0
                axis = .none
                guard wasHorizontal else { return }
                DispatchQueue.main.async {
                    self.parent.armedSide = .none
                    self.parent.onEnd(final)
                }

            default: break
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onScroll = { [weak coordinator = context.coordinator]
            event in
            coordinator?.handle(event)
        }
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        // Re-bind so the coordinator's `parent` always sees
        // the freshest closures + bindings.
        context.coordinator.parent = self
    }
}

// MARK: - CommandPaletteDemoCard
//
// Animated demo of the ⌘K command palette: keys press,
// fake palette zooms in, search field types a query
// character-by-character, results filter live, then the
// loop fades out and starts over. Mirrors the visual look
// of the real palette (`CommandPaletteView`) closely so
// the user recognises the UI when they actually press ⌘K.
//
// Sequence (5.4s total per loop):
//   0.0 – 0.4s   keys at rest
//   0.4 – 0.8s   ⌘ + K press visual
//   0.8 – 1.2s   palette zoom-in (scale + opacity)
//   1.2 – 2.5s   typing "reels" (one char ~250ms)
//   2.5 – 4.5s   hold (results visible)
//   4.5 – 5.0s   palette fade-out
//   5.0 – 5.4s   pause
//   loop
private struct CommandPaletteDemoCard: View {
    enum Phase {
        case idle           // before anything happens
        case keysPressed    // ⌘+K visual
        case paletteIn      // palette zooming in
        case typing         // chars appearing
        case results        // hold final results
        case paletteOut     // fade out
    }

    @State private var phase: Phase = .idle
    /// How many characters of `targetQuery` are visible at
    /// any given moment. Drives the typed-text + result
    /// filtering. Always 0 in non-typing phases (or full
    /// length once typing finishes).
    @State private var typedCount: Int = 0
    @State private var loopTask: Task<Void, Never>?

    /// Target query the demo "types".
    private let targetQuery = "reels"

    /// Mock result rows the demo shows. Filtered by the
    /// current `typedCount` prefix against each row's
    /// title — same fold-and-substring contract the real
    /// engine uses.
    private let mockRows: [DemoRow] = [
        .init(icon: "circle",                  tint: .purple,
              title: "REELS: Mini teaser inverno",
              subtitle: "TO DO 👀 · Video"),
        .init(icon: "circle",                  tint: .purple,
              title: "REELS: bastidores campanha",
              subtitle: "TO DO 👀 · Video"),
        .init(icon: "checkmark.circle.fill",   tint: .green,
              title: "Reels Balda — Teste do tecido",
              subtitle: "COMPLETE · Video"),
        .init(icon: "arrow.triangle.2.circlepath",
              tint: .blue,
              title: "Sincronizar agora",
              subtitle: "ClickUp e calendários",
              kind: .command),
    ]

    private var currentQuery: String {
        String(targetQuery.prefix(typedCount))
    }

    /// Rows filtered by the visible query (case + accent
    /// insensitive substring on the title). Matches the
    /// engine semantics enough for the demo to read true.
    private var visibleRows: [DemoRow] {
        let q = currentQuery
            .folding(options: [.diacriticInsensitive,
                                .caseInsensitive],
                     locale: nil)
        guard !q.isEmpty else { return mockRows }
        return mockRows.filter {
            $0.title.folding(options: [.diacriticInsensitive,
                                        .caseInsensitive],
                             locale: nil)
                .contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            keysHeader
            paletteCard
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06),
                              lineWidth: 0.5)
        )
        .onAppear { startLoop() }
        .onDisappear {
            loopTask?.cancel()
            loopTask = nil
        }
    }

    // MARK: - Pieces

    /// ⌘ + K press visual — two key caps that scale down +
    /// glow when the demo "presses" them.
    private var keysHeader: some View {
        let pressed = phase == .keysPressed
        return HStack(spacing: 8) {
            keyCap(label: "⌘", pressed: pressed)
            Text("+")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.secondary)
            keyCap(label: "K", pressed: pressed)
        }
        .frame(height: 22)
    }

    private func keyCap(label: String, pressed: Bool) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .heavy,
                          design: .rounded))
            .foregroundStyle(pressed ? Color.white
                                     : Color.primary.opacity(0.8))
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(pressed
                          ? Editorial.accent
                          : Color.primary.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        pressed
                            ? Editorial.accent
                            : Color.primary.opacity(0.18),
                        lineWidth: 0.6
                    )
            )
            .scaleEffect(pressed ? 0.92 : 1.0)
            .shadow(color: pressed
                    ? Editorial.accent.opacity(0.55)
                    : Color.clear,
                    radius: 6, x: 0, y: 0)
            .animation(
                .spring(response: 0.30, dampingFraction: 0.65),
                value: pressed
            )
    }

    /// Faux palette card. Hidden until `paletteIn`,
    /// scale-up + fade-in entrance, fade-out exit. Search
    /// field shows the typed query with a blinking caret;
    /// rows below filter live.
    private var paletteCard: some View {
        let visible = phase == .paletteIn
            || phase == .typing
            || phase == .results
        let scale: CGFloat =
            phase == .paletteOut ? 0.94 :
            phase == .paletteIn  ? 0.94 :
            1.0
        return VStack(spacing: 0) {
            paletteSearchField
            Divider().opacity(0.5)
            paletteResultsList
        }
        .background(.regularMaterial)
        .clipShape(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10),
                              lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.20),
                radius: 8, x: 0, y: 3)
        .scaleEffect(scale, anchor: .top)
        .opacity(visible ? 1 : 0)
        .animation(
            .spring(response: 0.45, dampingFraction: 0.78),
            value: phase
        )
    }

    private var paletteSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                if currentQuery.isEmpty {
                    Text("Buscar tarefa ou comando…")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 2) {
                    Text(currentQuery)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                    if phase == .typing {
                        BlinkingCaret()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private var paletteResultsList: some View {
        VStack(spacing: 1) {
            ForEach(visibleRows) { row in
                resultRow(row,
                          isFirst: row.id == visibleRows.first?.id)
                    .transition(.asymmetric(
                        insertion: .opacity
                            .combined(with: .move(edge: .top)),
                        removal:   .opacity
                    ))
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(minHeight: 80, alignment: .top)
        .animation(.easeOut(duration: 0.20),
                   value: visibleRows.map(\.id))
    }

    private func resultRow(_ row: DemoRow,
                           isFirst: Bool) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(row.tint.opacity(0.18))
                Image(systemName: row.icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(row.tint)
            }
            .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 0) {
                Text(row.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(row.subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(row.kind == .command ? "COMANDO" : "TAREFA")
                .font(.system(size: 7, weight: .heavy))
                .tracking(0.4)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isFirst
                    ? Editorial.accent.opacity(0.18)
                    : Color.clear)
        )
    }

    // MARK: - Loop

    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task { @MainActor in
            while !Task.isCancelled {
                phase = .idle
                typedCount = 0
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { break }

                phase = .keysPressed
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { break }

                phase = .paletteIn
                try? await Task.sleep(nanoseconds: 380_000_000)
                guard !Task.isCancelled else { break }

                phase = .typing
                for i in 0...targetQuery.count {
                    typedCount = i
                    try? await Task.sleep(nanoseconds: 220_000_000)
                    if Task.isCancelled { break }
                }
                guard !Task.isCancelled else { break }

                phase = .results
                try? await Task.sleep(nanoseconds: 1_900_000_000)
                guard !Task.isCancelled else { break }

                phase = .paletteOut
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
        }
    }

    // MARK: - Mock data

    private struct DemoRow: Identifiable {
        enum Kind { case task, command }
        let id = UUID()
        let icon: String
        let tint: Color
        let title: String
        let subtitle: String
        var kind: Kind = .task
    }
}

/// Blinking caret used by the palette demo's search field
/// while it "types" the demo query.
private struct BlinkingCaret: View {
    @State private var visible = true
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.7))
            .frame(width: 1, height: 11)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.55)
                        .repeatForever(autoreverses: true)
                ) {
                    visible = false
                }
            }
    }
}
