import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.windowSize) private var windowSize
    var onClose: () -> Void = {}

    @State private var showListPicker     = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }

    /// Cap the scrollable section so the whole popup never exceeds
    /// ~87.5% of the window's height (was 70%; +25% per user
    /// request) AND never bleeds into the macOS toolbar at the top
    /// of the window after centering.
    private var scrollMaxHeight: CGFloat {
        let h = windowSize.height
        guard h > 0 else { return 600 }   // sane default before measure (was 480; +25%)
        let chrome: CGFloat = 70
        let preferred = max(250, h * 0.875 - chrome)
        let safeMax   = max(0,   h - 128 - chrome)
        return min(preferred, safeMax)
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassFormHeader(title: "Configurações", onClose: onClose)

            // Body on a solid surface — header alone reads as
            // translucent glass.
            ScrollablePopupContent(maxHeight: scrollMaxHeight) {
                VStack(spacing: 12) {
                    // Calendar source = Google only (the
                    // EventKit `CalendarSection` was removed
                    // when Apollo dropped EventKit). The
                    // Google card below is the single
                    // calendar-connection surface.
                    GoogleCalendarSection()
                        .environmentObject(appState)
                    ClickUpSection(showListPicker: $showListPicker)
                        .environmentObject(appState)
                    AISection()
                        .environmentObject(appState)
                    AppSection()
                        .environmentObject(appState)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        // Width bumped from 460 → 621 (+35%) per design tweak.
        .frame(width: 621)
        .fixedSize(horizontal: false, vertical: true)
        .popupGlass(shape)
        .sheet(isPresented: $showListPicker) {
            CUListPickerSheet().environmentObject(appState)
        }
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
                    .foregroundStyle(Color.accentColor)
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
        let curColor = Color(hex: current.displayHex)

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
                    let tColor = Color(hex: t.displayHex)
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
                    .foregroundStyle(active ? AnyShapeStyle(Color.accentColor)
                                            : AnyShapeStyle(Color.primary))
                    .background(
                        active ? Color.accentColor.opacity(0.14) : Color.clear,
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            active ? Color.accentColor.opacity(0.40)
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
                                    ? Color.accentColor
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
                                ? Color.accentColor.opacity(0.10)
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
                        .background(savedFlash ? Color.green : Color.accentColor, in: Capsule())
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
                        .background(savedFlash ? Color.green : Color.accentColor, in: Capsule())
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
                        .background(savedFlash ? Color.green : Color.accentColor, in: Capsule())
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
                                                 ? Color.accentColor : .secondary)
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
                                      ? Color.accentColor.opacity(0.10)
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
                        .background(Color.accentColor, in: Capsule())
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
                        .background(Color.accentColor, in: Capsule())
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
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    private var svc: ClickUpService { ClickUpService(auth: appState.clickUpAuthService) }

    private var filteredLists: [CUList] {
        let q = listFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return lists }
        return lists.filter { $0.name.lowercased().contains(q) }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            columnsRow
            errorRow
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 700, height: 460)
        .background(.regularMaterial, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.20), radius: 24, x: 0, y: 12)
        .task { await loadWorkspaces() }
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
            Divider().opacity(0.5)
            GlassWarningRow(error, tint: .red)
                .padding(.horizontal, 16)
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
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
                Image(systemName: "list.bullet.rectangle.portrait.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.title3)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("Selecionar Lista")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Escolha onde suas tarefas serão lidas no Apollo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain).focusEffectDisabled()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            // Breadcrumb of the current selection
            HStack(spacing: 6) {
                breadcrumbChip(text: selectedWorkspace?.name ?? "—",
                               icon: "building.2.fill")
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                breadcrumbChip(text: selectedSpace?.name ?? "—",
                               icon: "folder.fill")
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                breadcrumbChip(text: currentListName ?? "—",
                               icon: "list.bullet")
            }
            .lineLimit(1)
            .truncationMode(.tail)

            Spacer()

            Button { close() } label: {
                Text("Fechar")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain).focusEffectDisabled()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var currentListName: String? {
        lists.first(where: { $0.id == selectedListId })?.name
            ?? KeychainHelper.load(for: KeychainHelper.Keys.clickupListName)
    }

    private func breadcrumbChip(text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
    }

    // MARK: - Lists column (with search)

    private var listsColumn: some View {
        VStack(spacing: 0) {
            columnHeader(title: "Lista",
                         icon: "list.bullet",
                         count: filteredLists.count)

            if selectedSpace != nil && !lists.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption).foregroundStyle(.tertiary)
                    TextField("Buscar lista", text: $listFilter)
                        .textFieldStyle(.plain)
                        .font(.caption)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
                .padding(.horizontal, 10)
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
                                    row(name: list.name,
                                        icon: "list.bullet",
                                        selected: selectedListId == list.id,
                                        action: { pick(list) })
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
        Rectangle().fill(.separator.opacity(0.5)).frame(width: 0.5)
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

    private func columnHeader(title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(title.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.secondary.opacity(0.55), in: Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.04))
        .overlay(Rectangle().fill(.separator.opacity(0.4))
            .frame(height: 0.5), alignment: .bottom)
    }

    private func row(name: String, icon: String, selected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Text(name)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected
                        ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                        : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.30) : .clear,
                                  lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func emptyHint(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.tertiary)
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
        selectedListId = list.id
        KeychainHelper.save(list.id,   for: KeychainHelper.Keys.clickupListId)
        KeychainHelper.save(list.name, for: KeychainHelper.Keys.clickupListName)
        Task { await appState.sync() }
        close()
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
