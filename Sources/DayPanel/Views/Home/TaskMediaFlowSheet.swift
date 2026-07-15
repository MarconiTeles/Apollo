import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum TaskMediaFlowMode {
    case add
    case replace
    case replacePending
    case send
    case status
}

struct TaskMediaFlowRequest: Identifiable {
    let id = UUID()
    let task: CUTask
    let mode: TaskMediaFlowMode
}

struct TaskMediaFlowSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: TaskMediaTransferStore
    let request: TaskMediaFlowRequest

    private enum Stage {
        case loading
        case classify
        case selectReplacement
        case confirmReplacement
        case mentions
        case status
    }

    @State private var stage: Stage = .loading
    @State private var selections: [TaskMediaSelection] = []
    @State private var replacementURLs: [UUID: URL] = [:]
    @State private var selectedMemberIds: Set<Int> = []
    @State private var memberQuery = ""
    @State private var outputNames: [UUID: String] = [:]
    @State private var localError: String?
    @State private var preparing = false

    // Popup chrome. The body is one opaque rounded surface; the header and
    // footer are Liquid Glass bars pinned on top (zIndex), and the stage's
    // scroll content is padded to start/end behind them so it refracts
    // through the glass as it scrolls — the same treatment as the task
    // detail masthead. Corners follow the shared (rounder) popup token.
    private let headerHeight: CGFloat = 66
    private let footerHeight: CGFloat = 68

    private var outerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Editorial.popupRadius(9), style: .continuous)
    }
    private var headerBarShape: UnevenRoundedRectangle {
        let r = Editorial.popupRadius(9)
        return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: 0,
                                      bottomTrailingRadius: 0, topTrailingRadius: r,
                                      style: .continuous)
    }
    private var footerBarShape: UnevenRoundedRectangle {
        let r = Editorial.popupRadius(9)
        return UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: r,
                                      bottomTrailingRadius: r, topTrailingRadius: 0,
                                      style: .continuous)
    }

    private var hasFooter: Bool {
        if case .loading = stage { return false }
        return true
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Scrollable stage content — fills the whole card and is padded so
            // it lives behind the two glass bars.
            stageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, headerHeight)
                .padding(.bottom, hasFooter ? footerHeight : 0)

            // Transient error banner rides just below the header.
            if localError != nil {
                errorBanner
                    .padding(.top, headerHeight + 8)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .zIndex(15)
            }

            // Top glass bar.
            header
                .frame(height: headerHeight)
                .frame(maxWidth: .infinity)
                .liquidGlass(in: headerBarShape, tint: Editorial.ink,
                             tintOpacity: 0.01, interactive: false)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Editorial.rule.opacity(0.6)).frame(height: 1)
                }
                .zIndex(20)

            // Bottom glass bar (stage-specific actions).
            if hasFooter {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    stageFooter
                        .frame(height: footerHeight)
                        .frame(maxWidth: .infinity)
                        .liquidGlass(in: footerBarShape, tint: Editorial.ink,
                                     tintOpacity: 0.01, interactive: false)
                        .overlay(alignment: .top) {
                            Rectangle().fill(Editorial.rule.opacity(0.6)).frame(height: 1)
                        }
                }
                .zIndex(20)
            }
        }
        .frame(width: 680, height: 540)
        .solidPopupSurface(in: outerShape)
        .task { await start() }
        .onAppear { appState.swiftUIPopupOpen = true }
        .onDisappear { appState.swiftUIPopupOpen = false }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "paperclip")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Editorial.accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Editorial.accentSoft))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Editorial.sans(16, .semibold))
                    .foregroundStyle(Editorial.ink)
                Text(request.task.title)
                    .font(Editorial.sans(11.5))
                    .foregroundStyle(Editorial.inkSoft)
                    .lineLimit(1)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Editorial.inkSoft)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverGlass()
            .focusable(false)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Fechar")
        }
        .padding(.horizontal, 22)
    }

    private var title: String {
        switch stage {
        case .selectReplacement, .confirmReplacement: return "Substituir arquivo"
        case .mentions: return "Enviar para revisão"
        case .status: return "Processamento em segundo plano"
        default: return "Anexar vídeos"
        }
    }

    // MARK: Stage content (scrollable, rides behind the bars)

    @ViewBuilder private var stageContent: some View {
        switch stage {
        case .loading: loadingBody
        case .classify: classificationBody
        case .selectReplacement: replacementPicker
        case .confirmReplacement: replacementConfirmation
        case .mentions: mentionsBody
        case .status: statusBody
        }
    }

    private var loadingBody: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Lendo o histórico desta tarefa…")
                .font(Editorial.sans(12))
                .foregroundStyle(Editorial.inkSoft)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var classificationBody: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach($selections) { $selection in
                    classificationRow(selection: $selection)
                }
            }
            .padding(24)
        }
    }

    private func classificationRow(selection: Binding<TaskMediaSelection>) -> some View {
        let classified = selection.wrappedValue.role != nil
        return HStack(spacing: 14) {
            Image(systemName: "film")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Editorial.accent)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Editorial.accentSoft))
            VStack(alignment: .leading, spacing: 3) {
                Text(selection.wrappedValue.fileURL.lastPathComponent)
                    .font(Editorial.sans(12.5, .medium))
                    .foregroundStyle(Editorial.ink)
                    .lineLimit(1)
                Text(classified ? "Pronto para compor" : "Confirme o tipo do arquivo")
                    .font(Editorial.sans(10.5))
                    .foregroundStyle(classified ? Editorial.accent : Editorial.inkMute)
            }
            Spacer(minLength: 12)
            Picker("Tipo", selection: selection.role) {
                Text("—").tag(TaskMediaRole?.none)
                ForEach(TaskMediaRole.allCases) { role in
                    Text(role.label).tag(TaskMediaRole?.some(role))
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 250)
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(
            RoundedRectangle(cornerRadius: Editorial.notificationCapsuleRadius, style: .continuous)
                .fill(classified ? Editorial.accentSoft.opacity(0.5) : Editorial.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Editorial.notificationCapsuleRadius, style: .continuous)
                .strokeBorder(classified ? Editorial.accent.opacity(0.45) : Editorial.rule,
                              lineWidth: 1)
        )
    }

    private var replacementPicker: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if !composedLineages.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Folio("VÍDEOS COMPOSTOS")
                        ForEach(composedLineages) { lineage in
                            replacementLineageCard(lineage)
                        }
                    }
                }

                if !directVideoAssets.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Folio("VÍDEOS COMPLETOS")
                        ForEach(directVideoAssets) { asset in
                            replacementAssetButton(
                                asset,
                                title: asset.displayName,
                                subtitle: "R\(asset.activeRevision?.number ?? 1) · substituição integral",
                                systemImage: "play.rectangle"
                            )
                        }
                    }
                }
            }
            .padding(24)
        }
        .overlay {
            if composedLineages.isEmpty && directVideoAssets.isEmpty {
                ContentUnavailableView("Nenhuma fonte para substituir",
                                       systemImage: "square.stack.3d.up.slash",
                                       description: Text("Use Adicionar arquivos para iniciar o catálogo desta tarefa."))
            }
        }
    }

    private func replacementLineageCard(_ lineage: TaskMediaOutputLineage) -> some View {
        let catalog = store.catalog(for: request.task.id)
        let output = catalog.latestOutput(for: lineage.id)
        let components = catalog.replacementComponents(for: lineage)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "film.stack")
                    .foregroundStyle(Editorial.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(output?.fileName ?? "Vídeo composto")
                        .font(Editorial.sans(12.5, .semibold))
                        .foregroundStyle(Editorial.ink)
                        .lineLimit(1)
                    Text("V\(output?.version ?? catalog.latestVersion(for: lineage.id)) · substitua cada parte separadamente")
                        .font(Editorial.sans(10.5))
                        .foregroundStyle(Editorial.inkMute)
                }
            }
            HStack(spacing: 8) {
                ForEach(components) { asset in
                    replacementAssetButton(
                        asset,
                        title: "SUBSTITUIR \(asset.role.label)",
                        subtitle: "\(asset.displayName) · R\(asset.activeRevision?.number ?? 1)",
                        systemImage: asset.role == .hook ? "bolt.fill" : "rectangle.stack.fill",
                        compact: true
                    )
                }
                if components.count == 2 {
                    replaceBothButton(components)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Editorial.popupRadius(7), style: .continuous)
            .fill(Editorial.card))
        .overlay(RoundedRectangle(cornerRadius: Editorial.popupRadius(7), style: .continuous)
            .strokeBorder(Editorial.rule))
    }

    private func replaceBothButton(_ components: [TaskMediaAsset]) -> some View {
        let selected = components.allSatisfy { replacementURLs[$0.id] != nil }
        return Button { chooseBothReplacements(components) } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Editorial.accent)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SUBSTITUIR AMBOS").lineLimit(1)
                    Text(selected ? "HOOK + BODY preparados" : "Escolher HOOK e BODY")
                        .font(Editorial.sans(9.5, selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Editorial.accent : Editorial.inkMute)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? Editorial.accent : Editorial.inkMute)
            }
            .font(Editorial.sans(10.5, .medium))
            .foregroundStyle(Editorial.ink)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(replacementFill(selected: selected))
            .overlay(replacementBorder(selected: selected))
            .contentShape(RoundedRectangle(cornerRadius: Editorial.popupRadius(5.5), style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel("Substituir HOOK e BODY")
    }

    private func replacementAssetButton(_ asset: TaskMediaAsset,
                                        title: String,
                                        subtitle: String,
                                        systemImage: String,
                                        compact: Bool = false) -> some View {
        let selected = replacementURLs[asset.id] != nil
        return Button { chooseReplacement(for: asset) } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Editorial.accent)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    Text(selected ? "R\((asset.activeRevision?.number ?? 1) + 1) preparado" : subtitle)
                        .font(Editorial.sans(9.5, selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Editorial.accent : Editorial.inkMute)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? Editorial.accent : Editorial.inkMute)
            }
            .font(Editorial.sans(compact ? 10.5 : 12.5, .medium))
            .foregroundStyle(Editorial.ink)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: compact ? 48 : 52, alignment: .leading)
            .background(replacementFill(selected: selected))
            .overlay(replacementBorder(selected: selected))
            .contentShape(RoundedRectangle(cornerRadius: Editorial.popupRadius(5.5), style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel("\(title), \(asset.displayName)")
    }

    private func replacementFill(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: Editorial.popupRadius(5.5), style: .continuous)
            .fill(selected ? Editorial.accentSoft.opacity(0.6) : Editorial.paper)
    }
    private func replacementBorder(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: Editorial.popupRadius(5.5), style: .continuous)
            .strokeBorder(selected ? Editorial.accent.opacity(0.5) : Editorial.rule)
    }

    private var replacementConfirmation: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(selectedReplacementAssets) { asset in
                    HStack(spacing: 12) {
                        revisionCard(label: "\(asset.role.label) ATUAL",
                                     name: asset.activeRevision?.originalFileName ?? "—",
                                     revision: asset.activeRevision?.number ?? 1)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(Editorial.accent)
                        revisionCard(label: "NOVA",
                                     name: replacementURLs[asset.id]?.lastPathComponent ?? "—",
                                     revision: (asset.activeRevision?.number ?? 1) + 1,
                                     accent: true)
                        Button {
                            replacementURLs[asset.id] = nil
                            if replacementURLs.isEmpty { stage = .selectReplacement }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Editorial.inkMute)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remover substituição")
                    }
                }

                Text(replacementImpactText)
                    .font(Editorial.sans(13, .medium))
                    .foregroundStyle(Editorial.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Editorial.accentSoft))
                    .padding(.top, 4)
            }
            .padding(24)
        }
    }

    private func revisionCard(label: String, name: String, revision: Int,
                              accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Folio(label)
            Text(name).font(Editorial.sans(12.5, .medium)).lineLimit(2)
            Text("R\(revision)")
                .font(Editorial.sans(11, .semibold))
                .foregroundStyle(Editorial.accent)
        }
        .foregroundStyle(Editorial.ink)
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Editorial.popupRadius(7), style: .continuous)
            .fill(accent ? Editorial.accentSoft.opacity(0.5) : Editorial.card))
        .overlay(RoundedRectangle(cornerRadius: Editorial.popupRadius(7), style: .continuous)
            .strokeBorder(accent ? Editorial.accent.opacity(0.4) : Editorial.rule))
    }

    private var mentionsBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Folio("NOMES DOS VÍDEOS")
                    ForEach(pendingOutputs) { output in
                        HStack(spacing: 10) {
                            Image(systemName: "film")
                                .foregroundStyle(Editorial.accent)
                            TextField("Nome do vídeo", text: outputNameBinding(for: output))
                                .textFieldStyle(.plain)
                                .font(Editorial.sans(12.5, .medium))
                            Text(".mov")
                                .font(Editorial.sans(11))
                                .foregroundStyle(Editorial.inkMute)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 42)
                        .background(Capsule().fill(Editorial.paper))
                        .overlay(Capsule().strokeBorder(Editorial.rule))
                    }
                }

                Folio("MARCAR PESSOAS (OPCIONAL)")
                TextField("Buscar por nome ou e-mail", text: $memberQuery)
                    .textFieldStyle(.plain)
                    .font(Editorial.sans(12.5))
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .background(Capsule().fill(Editorial.paper))
                    .overlay(Capsule().strokeBorder(Editorial.rule))
                LazyVStack(spacing: 6) {
                    ForEach(filteredMembers, id: \.id) { member in
                        let picked = selectedMemberIds.contains(member.id)
                        Button { toggle(member.id) } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Color(hex: member.color ?? "#5B5B62"))
                                    .frame(width: 24, height: 24)
                                    .overlay(Text(member.initials ?? String(member.username.prefix(2)).uppercased())
                                        .font(.system(size: 8, weight: .bold)).foregroundStyle(.white))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(member.username).font(Editorial.sans(12.5, .medium))
                                    if let email = member.email {
                                        Text(email).font(Editorial.sans(10.5)).foregroundStyle(Editorial.inkMute)
                                    }
                                }
                                Spacer()
                                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked ? Editorial.accent : Editorial.inkMute)
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 12)
                            .frame(height: 48)
                            .background(RoundedRectangle(cornerRadius: Editorial.popupRadius(5.5), style: .continuous)
                                .fill(picked ? Editorial.accentSoft.opacity(0.5) : Color.clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(24)
        }
    }

    private var statusBody: some View {
        let phase = store.phase(for: request.task.id)
        let isFailure = phase == .failed || phase == .partialFailure
        return VStack(spacing: 18) {
            Spacer()
            if isFailure {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.system(size: 31, weight: .medium))
                    .foregroundStyle(Editorial.accent)
                    .frame(width: 88, height: 88)
                    .background(Circle().fill(Editorial.accentSoft))
            } else {
                ZStack {
                    Circle().stroke(Editorial.rule, lineWidth: 7)
                    Circle().trim(from: 0, to: store.progress(for: request.task.id))
                        .stroke(Editorial.accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.12), value: store.progress(for: request.task.id))
                    Text("\(Int(store.progress(for: request.task.id) * 100))%")
                        .font(Editorial.sans(15, .semibold)).monospacedDigit()
                }
                .frame(width: 88, height: 88)
            }
            Text(isFailure ? "PUBLICAÇÃO INCOMPLETA" : store.capsuleLabel(for: request.task.id))
                .font(Editorial.sans(14, .semibold))
                .foregroundStyle(Editorial.ink)
            if let message = store.batches[request.task.id]?.errorMessage {
                Text(message)
                    .font(Editorial.sans(11.5))
                    .foregroundStyle(Editorial.accent)
                    .multilineTextAlignment(.center)
            } else {
                Text("Você pode fechar esta janela. O processamento continuará em segundo plano.")
                    .font(Editorial.sans(11.5))
                    .foregroundStyle(Editorial.inkSoft)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Stage footer (rides on the bottom glass bar)

    @ViewBuilder private var stageFooter: some View {
        switch stage {
        case .loading:
            EmptyView()
        case .classify:
            footerRow {
                secondaryButton("Escolher outros") { openAddPanel() }
                Spacer()
                primaryButton(preparing ? "PREPARANDO…" : "PREPARAR \(projectedCount) VÍDEOS",
                              disabled: preparing || !canPrepare) {
                    prepareAdd()
                }
            }
        case .selectReplacement:
            footerRow {
                secondaryButton("Cancelar") { dismiss() }
                Spacer()
                if !replacementURLs.isEmpty {
                    primaryButton("REVISAR LOTE (\(replacementURLs.count))", disabled: false) {
                        stage = .confirmReplacement
                    }
                }
            }
        case .confirmReplacement:
            footerRow {
                secondaryButton("Adicionar outra") { stage = .selectReplacement }
                Spacer()
                primaryButton(preparing ? "PREPARANDO…" : "SUBSTITUIR \(replacementURLs.count)",
                              disabled: preparing || replacementURLs.isEmpty) {
                    prepareReplacement()
                }
            }
        case .mentions:
            footerRow {
                secondaryButton("Cancelar") { dismiss() }
                Spacer()
                primaryButton("ENVIAR", disabled: !validOutputNames,
                              badge: pendingOutputs.count) {
                    send()
                }
            }
        case .status:
            statusFooter
        }
    }

    @ViewBuilder private var statusFooter: some View {
        let phase = store.phase(for: request.task.id)
        let isFailure = phase == .failed || phase == .partialFailure
        footerRow {
            if isFailure {
                secondaryButton("Descartar") {
                    store.discard(taskId: request.task.id); dismiss()
                }
            }
            Spacer()
            if isFailure, (store.batches[request.task.id]?.total ?? 0) > 0 {
                primaryButton("TENTAR NOVAMENTE", disabled: false,
                              badge: store.batches[request.task.id]?.pendingCount) {
                    initializeOutputNames()
                    stage = .mentions
                }
            } else if isFailure {
                primaryButton("FECHAR", disabled: false) { dismiss() }
            } else {
                primaryButton("CONTINUAR EM SEGUNDO PLANO", disabled: false) { dismiss() }
            }
        }
    }

    private func footerRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10, content: content)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var errorBanner: some View {
        if let localError {
            Text(localError)
                .font(Editorial.sans(11.5, .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Editorial.accent))
                .shadow(color: Editorial.accent.opacity(0.3), radius: 8, y: 3)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func primaryButton(_ label: String, disabled: Bool,
                               badge: Int? = nil,
                               action: @escaping () -> Void) -> some View {
        TaskMediaCapsuleButton(label: label, primary: true,
                               disabled: disabled, badge: badge,
                               action: action)
    }

    private func secondaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        TaskMediaCapsuleButton(label: label, primary: false,
                               disabled: false, badge: nil,
                               action: action)
    }

    private var canPrepare: Bool {
        !selections.isEmpty && selections.allSatisfy { $0.role != nil }
    }

    private var projectedCount: Int {
        let catalog = store.catalog(for: request.task.id)
        let existingHooks = catalog.assets.filter { $0.role == .hook }.count
        let existingBodies = catalog.assets.filter { $0.role == .body }.count
        let newHooks = selections.filter { $0.role == .hook }.count
        let newBodies = selections.filter { $0.role == .body }.count
        let direct = selections.filter { $0.role == .video }.count
        return newHooks * existingBodies + newBodies * existingHooks + newHooks * newBodies + direct
    }

    private var replacementImpactText: String {
        guard !replacementURLs.isEmpty else { return "" }
        let catalog = store.catalog(for: request.task.id)
        let hooks = catalog.assets.filter { $0.role == .hook }
        let bodies = catalog.assets.filter { $0.role == .body }
        var lineageIds = Set<String>()
        for asset in selectedReplacementAssets {
            switch asset.role {
            case .hook:
                for body in bodies {
                    lineageIds.insert(TaskMediaOutputLineage.combination(hook: asset.id, body: body.id).id)
                }
            case .body:
                for hook in hooks {
                    lineageIds.insert(TaskMediaOutputLineage.combination(hook: hook.id, body: asset.id).id)
                }
            case .video:
                lineageIds.insert(TaskMediaOutputLineage.direct(video: asset.id).id)
            }
        }
        let versions = lineageIds.map { catalog.latestVersion(for: $0) + 1 }
        let minVersion = versions.min() ?? 1
        let maxVersion = versions.max() ?? minVersion
        let versionText = minVersion == maxVersion ? "V\(minVersion)" : "V\(minVersion)–V\(maxVersion)"
        let count = lineageIds.count
        return "\(replacementURLs.count) fonte\(replacementURLs.count == 1 ? "" : "s") regenerará\(replacementURLs.count == 1 ? "" : "ão") \(count) vídeo\(count == 1 ? "" : "s") · \(versionText)"
    }

    private var composedLineages: [TaskMediaOutputLineage] {
        let catalog = store.catalog(for: request.task.id)
        return catalog.lineages.filter(\.isComposition).sorted { lhs, rhs in
            let left = catalog.latestOutput(for: lhs.id)?.fileName ?? lhs.id
            let right = catalog.latestOutput(for: rhs.id)?.fileName ?? rhs.id
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }
    }

    private var directVideoAssets: [TaskMediaAsset] {
        store.catalog(for: request.task.id).assets
            .filter { $0.role == .video }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    private var selectedReplacementAssets: [TaskMediaAsset] {
        store.catalog(for: request.task.id).assets
            .filter { replacementURLs[$0.id] != nil }
            .sorted { lhs, rhs in
                if lhs.role != rhs.role {
                    return TaskMediaRole.allCases.firstIndex(of: lhs.role)! < TaskMediaRole.allCases.firstIndex(of: rhs.role)!
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    private var filteredMembers: [CUMember] {
        let q = memberQuery.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let assigneeIds = Set(request.task.assignees.map(\.id))
        return appState.availableMembers.filter { member in
            q.isEmpty || member.username.localizedCaseInsensitiveContains(q)
                || (member.email?.localizedCaseInsensitiveContains(q) == true)
        }.sorted {
            let l = assigneeIds.contains($0.id), r = assigneeIds.contains($1.id)
            return l == r ? $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending : l
        }
    }

    @MainActor
    private func start() async {
        await store.loadCatalog(for: request.task, appState: appState)
        switch request.mode {
        case .add:
            openAddPanel()
        case .replace:
            stage = .selectReplacement
        case .replacePending:
            openPendingReplacementPanel()
        case .send:
            initializeOutputNames()
            stage = .mentions
        case .status:
            stage = .status
        }
    }

    private func openAddPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.message = "Escolha HOOKs, BODYs e vídeos completos"
        guard panel.runModal() == .OK else {
            if selections.isEmpty { dismiss() }
            return
        }
        selections = panel.urls.map { TaskMediaSelection(fileURL: $0) }
        stage = .classify
    }

    private func chooseReplacement(for asset: TaskMediaAsset) {
        guard let url = replacementURL(for: asset) else { return }
        replacementURLs[asset.id] = url
        stage = .confirmReplacement
    }

    /// Selects both source revisions as one atomic UI operation. Cancelling
    /// either Finder step leaves the current selection untouched, so the user
    /// never lands in an accidental half-replacement after choosing AMBOS.
    private func chooseBothReplacements(_ components: [TaskMediaAsset]) {
        guard let hook = components.first(where: { $0.role == .hook }),
              let body = components.first(where: { $0.role == .body }),
              let hookURL = replacementURL(for: hook,
                                           prompt: "1 de 2 — escolha o novo HOOK"),
              let bodyURL = replacementURL(for: body,
                                           prompt: "2 de 2 — escolha o novo BODY") else { return }
        replacementURLs[hook.id] = hookURL
        replacementURLs[body.id] = bodyURL
        stage = .confirmReplacement
    }

    private func replacementURL(for asset: TaskMediaAsset, prompt: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.message = prompt ?? "Escolha a nova revisão de \(asset.role.label): \(asset.displayName)"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func openPendingReplacementPanel() {
        let expected = store.replaceablePendingCountByTask[request.task.id] ?? 0
        guard expected > 0 else {
            localError = "Não há vídeos pendentes para substituir."
            stage = .status
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.message = "Escolha exatamente \(expected) vídeo\(expected == 1 ? "" : "s") para substituir os pendentes"
        guard panel.runModal() == .OK else {
            stage = .status
            return
        }
        preparing = true
        stage = .status
        Task {
            do {
                try await store.replacePendingOutputs(taskId: request.task.id, with: panel.urls)
                initializeOutputNames()
                preparing = false
                stage = .mentions
            } catch {
                preparing = false
                localError = error.localizedDescription
                stage = .status
            }
        }
    }

    private func prepareAdd() {
        preparing = true; localError = nil; stage = .status
        Task {
            await store.prepareAdd(task: request.task, selections: selections, appState: appState)
            preparing = false
            if store.phase(for: request.task.id) == .ready { dismiss() }
            else { localError = store.batches[request.task.id]?.errorMessage }
        }
    }

    private func prepareReplacement() {
        guard !replacementURLs.isEmpty else { return }
        preparing = true; localError = nil; stage = .status
        Task {
            await store.prepareReplacements(task: request.task,
                                            replacementURLs: replacementURLs,
                                            appState: appState)
            preparing = false
            if store.phase(for: request.task.id) == .ready { dismiss() }
            else { localError = store.batches[request.task.id]?.errorMessage }
        }
    }

    private func toggle(_ memberId: Int) {
        if selectedMemberIds.contains(memberId) { selectedMemberIds.remove(memberId) }
        else { selectedMemberIds.insert(memberId) }
    }

    private var pendingOutputs: [TaskMediaPlannedOutput] {
        store.pendingOutputs(for: request.task.id)
    }

    private func initializeOutputNames() {
        var values: [UUID: String] = [:]
        for output in pendingOutputs {
            values[output.id] = (output.displayFileName as NSString).deletingPathExtension
        }
        outputNames = values
    }

    private func outputNameBinding(for output: TaskMediaPlannedOutput) -> Binding<String> {
        Binding(
            get: { outputNames[output.id] ?? (output.displayFileName as NSString).deletingPathExtension },
            set: { outputNames[output.id] = $0 }
        )
    }

    private var validOutputNames: Bool {
        guard !pendingOutputs.isEmpty else { return false }
        let names = pendingOutputs.compactMap { output -> String? in
            let raw = outputNames[output.id] ?? ""
            let ext = (output.displayFileName as NSString).pathExtension
            return TaskMediaOutputName.comparisonKey(raw,
                                                     pathExtension: ext.isEmpty ? "mov" : ext)
        }
        return names.count == pendingOutputs.count && Set(names).count == names.count
    }

    private func send() {
        stage = .status
        Task {
            await store.send(task: request.task,
                             mentionMemberIds: Array(selectedMemberIds),
                             outputNames: outputNames,
                             appState: appState)
        }
    }
}

private struct TaskMediaCapsuleButton: View {
    let label: String
    let primary: Bool
    let disabled: Bool
    let badge: Int?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Editorial.sans(11.5, primary ? .semibold : .medium))
                .tracking(primary ? 0.4 : 0)
                .foregroundStyle(primary ? Color.white : Editorial.ink)
                .padding(.horizontal, primary ? 18 : 15)
                .frame(height: 34)
                .background {
                    Capsule()
                        .fill(primary ? Editorial.accent : Editorial.card)
                        .overlay {
                            Capsule().fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(hovered ? 0.20 : 0.05), .clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        }
                }
                .overlay {
                    Capsule().strokeBorder(
                        primary
                            ? Color.white.opacity(hovered ? 0.28 : 0.10)
                            : Editorial.rule.opacity(hovered ? 1 : 0.78),
                        lineWidth: 1
                    )
                }
                .shadow(color: (primary ? Editorial.accent : Color.black)
                    .opacity(hovered ? (primary ? 0.22 : 0.11) : 0),
                        radius: hovered ? 7 : 0, x: 0, y: hovered ? 3 : 0)
                .overlay(alignment: .topTrailing) {
                    if let badge, badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Editorial.accent)
                            .frame(minWidth: 17, minHeight: 17)
                            .background(Circle().fill(.white))
                            .overlay(Circle().strokeBorder(Editorial.accent.opacity(0.18)))
                            .offset(x: 6, y: -6)
                    }
                }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(disabled)
        .opacity(disabled ? 0.42 : 1)
        .onHover { hovered = !disabled && $0 }
        .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.82), value: hovered)
    }
}
