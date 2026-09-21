import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Pedido de envio em lote: o conjunto de tarefas escolhido na lista,
/// mais o universo visível para o botão "+ tarefa" poder oferecer quem
/// ficou de fora.
struct TaskBulkMediaRequest: Identifiable {
    let id = UUID()
    let tasks: [CUTask]
    let candidates: [CUTask]
    /// Arquivos que já vieram junto com a abertura — o caso de arrastar
    /// o vídeo do Finder para cima da lista. Quando existem, a folha
    /// pula a área de soltar e abre direto no "Anexo em lote".
    var initialURLs: [URL] = []
}

/// Envio de arquivo(s) para várias tarefas de uma vez.
///
/// O FUNDO da janela é Liquid Glass translúcido (`floatingPanelGlass`,
/// o mesmo material da sidebar), então a tela que mostra quais vídeos vão
/// para quais tarefas refrata o app atrás dela de verdade.
///
/// Esse é o ÚNICO material da tela. As barras de topo e rodapé continuam
/// existindo, mas como um véu sobre o vidro — não um segundo vidro. E as
/// linhas são planas. Empilhar material aqui custaria exatamente a
/// legibilidade que esta tela precisa entregar.
struct TaskBulkMediaFlowSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: TaskMediaTransferStore
    @StateObject private var coordinator: TaskBulkMediaCoordinator
    let request: TaskBulkMediaRequest

    init(store: TaskMediaTransferStore, request: TaskBulkMediaRequest) {
        self.store = store
        self.request = request
        _coordinator = StateObject(wrappedValue: TaskBulkMediaCoordinator(store: store))
    }

    private enum Stage {
        case loading
        /// Primeira tela: a área onde se solta (ou escolhe) o arquivo.
        /// Nada de abrir o seletor do sistema na cara da pessoa — ela
        /// chega aqui, vê onde pôr o arquivo, e decide como.
        case dropZone
        /// Tela principal: arquivos em cima, tarefas de destino embaixo.
        case compose
        case trim
        case mentions
        case status
    }

    @State private var stage: Stage = .loading
    @State private var selections: [TaskMediaSelection] = []
    @State private var targets: [CUTask] = []
    /// O que UMA tarefa mudou em relação ao padrão da linha de cima.
    /// Vazio = aquela tarefa recebe o vídeo exatamente como está no topo.
    struct TargetOverride: Equatable {
        var role: TaskMediaRole?
        /// Corte próprio desta tarefa. Arquivo diferente ⇒ hash diferente
        /// ⇒ render e upload próprios.
        var fileURL: URL?
        var trimmed = false

        var isEmpty: Bool { role == nil && fileURL == nil }
    }

    /// taskId → (selectionId → o que aquela tarefa mudou)
    @State private var overrides: [String: [UUID: TargetOverride]] = [:]

    // MARK: Destino por arquivo
    //
    // Quando o nome do arquivo identifica a tarefa (`H4_REPLICA_BALDA_
    // AIRTON_V02` → "Camiseta 1.0 - Réplica Airton 2"), cada vídeo vai
    // para a SUA tarefa em vez de para todas. Sem nome que identifique,
    // o comportamento original continua: um vídeo para todas.

    /// selectionId → taskId. Ausente enquanto o roteamento não está ativo.
    @State private var assignments: [UUID: String] = [:]
    /// Arquivos cujo nome bateu com mais de uma tarefa, ou com nenhuma,
    /// enquanto os outros bateram. Precisam de escolha manual.
    @State private var unresolvedSelectionIds: Set<UUID> = []
    /// Liga quando pelo menos um arquivo foi identificado pelo nome.
    /// Antes disso a tela é a de sempre: tudo vai para todas.
    @State private var routingActive = false
    /// Cartão sob o cursor durante um arrasto interno de vídeo.
    @State private var dropHoverTaskId: String?
    /// Vídeo sendo arrastado da lista para um cartão de tarefa.
    @State private var draggingSelectionId: UUID?
    @State private var trimSelectionId: UUID?
    /// Quando o corte é de uma tarefa só, guarda qual. `nil` = corte
    /// padrão, que vale para todas as que não divergiram.
    @State private var trimTaskId: String?
    @State private var selectedMemberIds: Set<Int> = []
    @State private var memberQuery = ""
    @State private var localError: String?
    @State private var isDropTargeted = false
    @State private var working = false

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
    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Editorial.popupRadius(7), style: .continuous)
    }

    private var hasFooter: Bool {
        switch stage {
        case .loading, .trim, .dropZone: return false
        default: return true
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            stageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, headerHeight)
                .padding(.bottom, hasFooter ? footerHeight : 0)

            if localError != nil {
                errorBanner
                    .padding(.top, headerHeight + 8)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .zIndex(15)
            }

            header
                .frame(height: headerHeight)
                .frame(maxWidth: .infinity)
                // As barras continuam, mas como um véu sobre o vidro do
                // fundo — não um segundo material. Vidro sobre vidro
                // embaralha a leitura, que é justamente o que esta tela
                // não pode fazer.
                .background(headerBarShape.fill(Editorial.page.opacity(0.55)))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Editorial.rule.opacity(0.6)).frame(height: 1)
                }
                .zIndex(20)

            if hasFooter {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    stageFooter
                        .frame(height: footerHeight)
                        .frame(maxWidth: .infinity)
                        .background(footerBarShape.fill(Editorial.page.opacity(0.55)))
                        .overlay(alignment: .top) {
                            Rectangle().fill(Editorial.rule.opacity(0.6)).frame(height: 1)
                        }
                }
                .zIndex(20)
            }
        }
        .frame(width: 680, height: 560)
        // O FUNDO é o vidro. `solidPopupSurface` preenchia com
        // `Editorial.page` (opaco) e qualquer vidro por dentro não tinha
        // o que refratar — virava cor chapada. `floatingPanelGlass` é o
        // mesmo material da sidebar: translúcido de verdade, refrata o
        // app atrás, e cai para vibrancy/sólido sozinho em máquina Intel
        // ou com Reduzir Transparência ligado.
        .floatingPanelGlass(in: outerShape)
        .task { await start() }
        .onAppear { appState.swiftUIPopupOpen = true }
        .onDisappear { appState.swiftUIPopupOpen = false }
    }

    // MARK: - Header

    private var title: String {
        switch stage {
        case .dropZone: return "Anexar em lote"
        case .trim: return "Cortar clipe"
        case .mentions: return "Enviar para revisão"
        case .status: return "Enviando"
        // O ato de anexar aconteceu no popup anterior. Daqui em diante a
        // tela é sobre configurar o que já está anexado.
        default: return "Anexo em lote"
        }
    }

    private var subtitle: String {
        let videos = selections.count
        let tasks = targets.count
        return "\(videos) \(videos == 1 ? "vídeo" : "vídeos") · "
             + "\(tasks) \(tasks == 1 ? "tarefa" : "tarefas")"
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "paperclip")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Editorial.accent)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Editorial.accentSoft))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Editorial.sans(16, .semibold))
                    .foregroundStyle(Editorial.ink)
                Text(subtitle)
                    .font(Editorial.sans(11.5))
                    .foregroundStyle(Editorial.inkSoft)
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Editorial.inkSoft)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(.horizontal, 20)
    }

    private var errorBanner: some View {
        Text(localError ?? "")
            .font(Editorial.sans(11.5, .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.red.opacity(0.88)))
    }

    // MARK: - Stages

    @ViewBuilder private var stageContent: some View {
        switch stage {
        case .loading: loadingBody
        case .dropZone: dropZoneBody
        case .compose: composeBody
        case .trim: trimBody
        case .mentions: mentionsBody
        case .status: statusBody
        }
    }

    private var loadingBody: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Lendo o catálogo de cada tarefa…")
                .font(Editorial.sans(11.5))
                .foregroundStyle(Editorial.inkSoft)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Área de soltar. A janela inteira já é vidro translúcido, então o
    /// alvo não ganha material próprio: ele é marcado por uma borda
    /// tracejada que acende em accent quando o arquivo passa por cima.
    /// Toda a região é clicável — arrastar e escolher levam ao mesmo
    /// lugar, que é o que a pessoa espera de uma caixa dessas.
    private var dropZoneBody: some View {
        VStack(spacing: 0) {
            Button { openFilePanel() } label: {
                VStack(spacing: 12) {
                    Image(systemName: isDropTargeted
                          ? "square.and.arrow.down.fill" : "square.and.arrow.down")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(isDropTargeted ? Editorial.accent : Editorial.inkSoft)
                    VStack(spacing: 3) {
                        Text("Solte o vídeo aqui")
                            .font(Editorial.sans(14, .semibold))
                            .foregroundStyle(Editorial.ink)
                        Text("ou clique para escolher no Finder")
                            .font(Editorial.sans(11.5))
                            .foregroundStyle(Editorial.inkSoft)
                    }
                    Text(targets.count == 1
                         ? "Vai para 1 tarefa selecionada"
                         : "Vai para as \(targets.count) tarefas selecionadas")
                        .font(Editorial.sans(10.5, .medium))
                        .foregroundStyle(Editorial.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Editorial.accentSoft))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .overlay {
            panelShape.strokeBorder(
                style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1,
                                   dash: isDropTargeted ? [] : [6, 5]))
            .foregroundStyle(isDropTargeted
                             ? Editorial.accent
                             : Editorial.rule.opacity(0.7))
            .allowsHitTesting(false)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
    }

    /// Tela principal: o vídeo em cima, as tarefas e suas regras embaixo.
    private var composeBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Só o que ainda não tem dona. Vídeo já endereçado vive
                // dentro do cartão da tarefa dele — repetir aqui em cima
                // dobrava a lista sem acrescentar informação.
                sectionLabel(routingActive
                             ? "VÍDEOS SEM TAREFA"
                             : "VÍDEOS · PADRÃO PARA TODAS")
                if routingActive && unassignedSelections.isEmpty {
                    Text("Todos os vídeos já têm tarefa.")
                        .font(Editorial.sans(11))
                        .foregroundStyle(Editorial.inkSoft)
                        .padding(.vertical, 4)
                }
                ForEach(unassignedSelections) { selection in
                    if let index = selections.firstIndex(where: { $0.id == selection.id }) {
                        videoRow(selection: $selections[index])
                    }
                }
                addVideoRow

                Divider()
                    .overlay(Editorial.rule.opacity(0.5))
                    .padding(.vertical, 12)

                sectionLabel("TAREFAS DE DESTINO")
                Text("Arraste um vídeo da lista acima para a tarefa que ele pertence.")
                    .font(Editorial.sans(10.5))
                    .foregroundStyle(Editorial.inkSoft.opacity(0.8))
                    .padding(.bottom, 10)
                // Cartões sempre abertos: esconder o conteúdo de cada
                // tarefa atrás de uma gaveta obrigava a abrir uma por uma
                // só para conferir o que ia para onde.
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(targets) { task in
                        targetCard(task, projection: projection(for: task))
                    }
                }
                addTaskRow
                    .padding(.top, 8)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Sem vidro próprio: o fundo da janela já É o vidro, e um
            // segundo material aqui só embaçaria o que precisa ser lido.
            // A borda existe para marcar a área de soltar o arquivo.
            .overlay {
                panelShape
                    .strokeBorder(isDropTargeted
                                  ? Editorial.accent.opacity(0.75)
                                  : Editorial.rule.opacity(0.45),
                                  lineWidth: isDropTargeted ? 1.5 : 0.6)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        // Arrastar arquivo direto para dentro da janela adiciona mais vídeos
        // ao mesmo envio, sem passar pelo seletor do sistema.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Editorial.sans(9.5, .semibold))
            .tracking(0.8)
            .foregroundStyle(Editorial.inkSoft.opacity(0.85))
            .padding(.bottom, 8)
    }

    // MARK: Linha de vídeo

    private func videoRow(selection: Binding<TaskMediaSelection>) -> some View {
        HStack(spacing: 10) {
            // Alça de arrasto. Sem ela nada na linha dizia que o vídeo
            // podia ser levado para o cartão de uma tarefa — a
            // capacidade existia e ficava invisível.
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10))
                    .foregroundStyle(Editorial.inkSoft.opacity(0.6))
                Image(systemName: "film")
                    .font(.system(size: 13))
                    .foregroundStyle(Editorial.accent)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Editorial.accentSoft))
            }
            .contentShape(Rectangle())
            .onDrag {
                draggingSelectionId = selection.wrappedValue.id
                // Tipo explícito: `NSItemProvider(object: NSString)` se
                // registra como `public.utf8-plain-text`, e um `onDrop`
                // que aceitava só `public.text` nunca casava.
                return NSItemProvider(item: selection.wrappedValue.id.uuidString as NSString,
                                      typeIdentifier: UTType.plainText.identifier)
            }
            .help("Arraste para a tarefa a que este vídeo pertence")

            VStack(alignment: .leading, spacing: 1) {
                Text(selection.wrappedValue.fileURL.lastPathComponent)
                    .font(Editorial.sans(12.5, .medium))
                    .foregroundStyle(Editorial.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                destinationLine(for: selection.wrappedValue)
            }

            Spacer(minLength: 8)

            trimButton(selection: selection)
            roleToggle(selection: selection)

            Button {
                remove(selectionId: selection.wrappedValue.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Editorial.inkSoft)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(.vertical, 7)
    }

    /// Recebe o que for solto num cartão de tarefa: um vídeo que já
    /// está na tela (arrastado da lista ou de outro cartão) ou um
    /// arquivo vindo direto do Finder, que entra já endereçado àquela
    /// tarefa — sem passar pela lista de cima.
    private func acceptDrop(_ providers: [NSItemProvider],
                            onto taskId: String) -> Bool {
        if draggingSelectionId != nil {
            return acceptInternalDrop(providers, onto: taskId)
        }
        return loadFileURLs(from: providers) { url in
            guard let added = accept(droppedURL: url) else { return }
            assign(added, to: taskId)
        }
    }

    /// Recebe um vídeo arrastado da lista para o cartão de uma tarefa.
    private func acceptInternalDrop(_ providers: [NSItemProvider],
                                    onto taskId: String) -> Bool {
        // O id viaja no payload, mas durante o arrasto ele já está em
        // `draggingSelectionId`. Usar o estado evita depender da carga
        // assíncrona do provider no caminho comum.
        if let id = draggingSelectionId {
            assign(id, to: taskId)
            draggingSelectionId = nil
            dropHoverTaskId = nil
            return true
        }
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let raw = value as? String, let id = UUID(uuidString: raw) else { return }
            Task { @MainActor in
                assign(id, to: taskId)
                dropHoverTaskId = nil
            }
        }
        return true
    }

    /// Segunda linha do arquivo: para onde ele vai. É aqui que o
    /// casamento por nome se explica e se corrige — o sistema propõe,
    /// a pessoa confirma ou troca.
    @ViewBuilder
    private func destinationLine(for selection: TaskMediaSelection) -> some View {
        let assignedTask = assignments[selection.id]
            .flatMap { id in targets.first { $0.id == id } }

        Menu {
            Button("Todas as tarefas") { assign(selection.id, to: nil) }
            Divider()
            ForEach(targets) { task in
                Button(task.title) { assign(selection.id, to: task.id) }
            }
        } label: {
            HStack(spacing: 4) {
                if let assignedTask {
                    Image(systemName: manualAssignments.contains(selection.id)
                          ? "hand.point.right.fill" : "wand.and.stars")
                        .font(.system(size: 8.5))
                    Text(assignedTask.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if unresolvedSelectionIds.contains(selection.id) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 8.5))
                    Text("Escolher tarefa")
                } else {
                    Text(selection.trimmed
                         ? "Cortado · vale para todas"
                         : "Vale para todas as tarefas")
                }
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .font(Editorial.sans(10.5))
            .foregroundStyle(unresolvedSelectionIds.contains(selection.id)
                             ? Color.orange
                             : (assignedTask != nil ? Editorial.accent : Editorial.inkSoft))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func trimButton(selection: Binding<TaskMediaSelection>) -> some View {
        let isTrimmed = selection.wrappedValue.trimmed
        return Button {
            trimSelectionId = selection.wrappedValue.id
            stage = .trim
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isTrimmed ? "checkmark" : "scissors")
                Text(isTrimmed ? "CORTADO" : "CORTAR")
            }
            .font(Editorial.sans(9.5, .semibold))
            .foregroundStyle(isTrimmed ? Color.white : Editorial.accent)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(isTrimmed
                                       ? Color.green.opacity(0.85)
                                       : Editorial.accentSoft))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    /// HOOK / BODY / VIDEO vale para TODAS as tarefas — um arquivo tem uma
    /// natureza só. O que muda entre tarefas é com o que ele se combina,
    /// e isso a projeção logo abaixo mostra tarefa a tarefa.
    private func roleToggle(selection: Binding<TaskMediaSelection>) -> some View {
        HStack(spacing: 0) {
            ForEach(TaskMediaRole.allCases, id: \.self) { role in
                let active = selection.wrappedValue.role == role
                Button {
                    selection.wrappedValue.role = role
                    Task { await reproject() }
                } label: {
                    Text(role.rawValue.uppercased())
                        .font(Editorial.sans(9, .semibold))
                        .foregroundStyle(active ? Color.white : Editorial.inkSoft)
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(active ? Editorial.accent : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .background(Capsule().fill(Editorial.inkFaint.opacity(0.14)))
        .clipShape(Capsule(style: .continuous))
    }

    private var addVideoRow: some View {
        Button { openFilePanel() } label: {
            HStack(spacing: 7) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 12, weight: .medium))
                Text("Adicionar vídeos")
                    .font(Editorial.sans(11, .semibold))
                Text("· ou arraste do Finder para cá")
                    .font(Editorial.sans(10.5))
                    .foregroundStyle(Editorial.inkSoft)
            }
            .foregroundStyle(Editorial.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(isDropTargeted
                                     ? Editorial.accent
                                     : Editorial.accent.opacity(0.35))
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .padding(.top, 6)
    }

    /// Vídeos que ainda não foram endereçados a nenhuma tarefa.
    private var unassignedSelections: [TaskMediaSelection] {
        selections.filter { assignments[$0.id] == nil }
    }

    // MARK: Linha de tarefa

    /// O que ESTA tarefa vai receber: o padrão do topo, com o papel e o
    /// corte que ela tiver mudado aplicados por cima.
    private func effectiveSelections(for taskId: String) -> [TaskMediaSelection] {
        selections.filter { base in
            // Roteamento desligado: comportamento original, tudo para
            // todas. Ligado: a tarefa recebe só o que foi endereçado a
            // ela — e nada do que ficou sem destino, porque empurrar um
            // arquivo não identificado para todas as tarefas, no meio de
            // um lote roteado, é o tipo de surpresa que só se descobre
            // depois de publicado.
            guard routingActive else { return true }
            return assignments[base.id] == taskId
        }.map { base in
            var copy = base
            guard let override = overrides[taskId]?[base.id] else { return copy }
            if let role = override.role { copy.role = role }
            if let url = override.fileURL {
                copy.fileURL = url
                copy.contentHash = nil
                copy.trimmed = override.trimmed
            }
            return copy
        }
    }

    /// Roda o casamento por nome para os arquivos ainda sem destino
    /// escolhido à mão. Não sobrescreve escolha manual.
    private func applyNameMatching() {
        guard targets.count >= 2 else {
            routingActive = false
            unresolvedSelectionIds = []
            return
        }
        var resolved = assignments
        var unresolved: Set<UUID> = []
        var matchedAny = false

        for selection in selections where manualAssignments.contains(selection.id) == false {
            let resolution = TaskMediaNameMatcher.resolve(
                fileName: selection.fileURL.lastPathComponent, tasks: targets)
            if let taskId = resolution.suggestedTaskId {
                resolved[selection.id] = taskId
                matchedAny = true
            } else {
                resolved.removeValue(forKey: selection.id)
                unresolved.insert(selection.id)
            }
        }

        assignments = resolved
        // Só vale como "sem destino" se o roteamento estiver de pé; com
        // nenhum arquivo identificado, a tela segue sendo a de sempre.
        routingActive = matchedAny || !manualAssignments.isEmpty
        unresolvedSelectionIds = routingActive ? unresolved : []
    }

    /// Arquivos sobre os quais a PESSOA já decidiu — tanto ao escolher
    /// uma tarefa quanto ao tirar de uma. O casamento automático não
    /// mexe em nenhum deles.
    @State private var manualAssignments: Set<UUID> = []

    private func assign(_ selectionId: UUID, to taskId: String?) {
        if let taskId {
            assignments[selectionId] = taskId
            unresolvedSelectionIds.remove(selectionId)
            routingActive = true
        } else {
            assignments.removeValue(forKey: selectionId)
            if routingActive { unresolvedSelectionIds.insert(selectionId) }
        }
        // O id ENTRA no conjunto de decididos nos dois casos, inclusive
        // ao tirar de uma tarefa. Antes ele saía, e o casador automático
        // reatribuía o arquivo à mesma tarefa na projeção seguinte — o
        // ✕ parecia não funcionar porque o vídeo voltava no mesmo
        // instante. Decisão da pessoa manda, inclusive a de remover.
        manualAssignments.insert(selectionId)
        Task { await reproject() }
    }

    /// Tira o vídeo desta tarefa: limpa o ajuste próprio que ele tinha
    /// nela e devolve o arquivo à lista de cima, numa operação só.
    private func detach(_ selectionId: UUID, from taskId: String) {
        var forTask = overrides[taskId] ?? [:]
        forTask.removeValue(forKey: selectionId)
        if forTask.isEmpty { overrides.removeValue(forKey: taskId) }
        else { overrides[taskId] = forTask }
        assign(selectionId, to: nil)
    }

    private func override(_ taskId: String, _ selectionId: UUID) -> TargetOverride {
        overrides[taskId]?[selectionId] ?? TargetOverride()
    }

    private func setOverride(_ value: TargetOverride,
                             taskId: String, selectionId: UUID) {
        var forTask = overrides[taskId] ?? [:]
        if value.isEmpty { forTask.removeValue(forKey: selectionId) }
        else { forTask[selectionId] = value }
        if forTask.isEmpty { overrides.removeValue(forKey: taskId) }
        else { overrides[taskId] = forTask }
        Task { await reproject() }
    }

    private func hasOverrides(_ taskId: String) -> Bool {
        !(overrides[taskId]?.isEmpty ?? true)
    }

    /// Os arquivos que vão para esta tarefa. Com o roteamento desligado
    /// são todos — é o comportamento original, um vídeo para todas.
    private func selectionsRouted(to taskId: String) -> [TaskMediaSelection] {
        guard routingActive else { return selections }
        return selections.filter { assignments[$0.id] == taskId }
    }

    /// A tarefa declara no título quantos hooks e bodies espera
    /// ("B1 - H5"). Compara com o que o lote está levando para ela e
    /// devolve o aviso, se houver excesso.
    private func quotaWarning(for task: CUTask) -> String? {
        let quota = TaskMediaQuota.parse(title: task.title)
        guard !quota.isEmpty else { return nil }
        let incoming = effectiveSelections(for: task.id)
        return quota.warning(
            hooks: incoming.filter { $0.role == .hook }.count,
            bodies: incoming.filter { $0.role == .body }.count)
    }

    /// Resumo do que a tarefa pede, para a pessoa ver sem abrir o ClickUp.
    private func quotaCaption(for task: CUTask) -> String? {
        let quota = TaskMediaQuota.parse(title: task.title)
        guard !quota.isEmpty else { return nil }
        var parts: [String] = []
        if let hooks = quota.hooks { parts.append("\(hooks) hooks") }
        if let bodies = quota.bodies { parts.append("\(bodies) body") }
        return "pede " + parts.joined(separator: " · ")
    }

    /// Projeção já calculada para esta tarefa, se houver. Enquanto não
    /// existe arquivo escolhido não há o que projetar — a tarefa aparece
    /// mesmo assim, só sem o "gera N vídeos".
    private func projection(for task: CUTask) -> TaskBulkMediaCoordinator.Target? {
        coordinator.targets.first { $0.id == task.id }
    }

    // MARK: Cartão da tarefa

    /// Em que situação a tarefa está — cada uma pede uma cara diferente.
    private enum TargetState {
        /// Nenhum arquivo endereçado. NÃO é erro: é trabalho pendente,
        /// e a pessoa resolve arrastando um vídeo da lista de cima.
        case awaitingVideo
        /// O planner recusou por um motivo concreto (duplicata, falta de
        /// contraparte). Diferente de "sem vídeo" e precisa dizer o quê.
        case blocked(String)
        case ready(Int)
    }

    private func state(of task: CUTask,
                       projection target: TaskBulkMediaCoordinator.Target?) -> TargetState {
        if selectionsRouted(to: task.id).isEmpty { return .awaitingVideo }
        if let reason = target?.blockedReason { return .blocked(reason) }
        return .ready(target?.projectedOutputs ?? 0)
    }

    private func targetCard(_ task: CUTask,
                            projection target: TaskBulkMediaCoordinator.Target?)
    -> some View {
        let routed = selectionsRouted(to: task.id)
        let state = state(of: task, projection: target)
        let isDropTarget = dropHoverTaskId == task.id

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(Editorial.sans(12.5, .semibold))
                        .foregroundStyle(Editorial.ink)
                        .lineLimit(1)
                    if case .blocked(let reason) = state {
                        Text(reason)
                            .font(Editorial.sans(10.5))
                            .foregroundStyle(Editorial.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let warning = quotaWarning(for: task) {
                        Text(warning)
                            .font(Editorial.sans(10.5, .medium))
                            .foregroundStyle(Color.orange)
                    } else if let caption = quotaCaption(for: task) {
                        Text(caption)
                            .font(Editorial.sans(10.5))
                            .foregroundStyle(Editorial.inkSoft.opacity(0.8))
                    }
                }
                Spacer(minLength: 8)
                stateBadge(state)
                Button { remove(taskId: task.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Editorial.inkSoft)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, routed.isEmpty ? 10 : 8)

            if routed.isEmpty {
                emptyTargetSlot(isDropTarget: isDropTarget)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(routed) { base in
                        routedFileRow(base, task: task)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelShape.fill(Editorial.card.opacity(isDropTarget ? 0.55 : 0.28)))
        .overlay {
            panelShape.strokeBorder(borderColor(for: state, hovering: isDropTarget),
                                    lineWidth: isDropTarget ? 1.6 : 0.8)
                .allowsHitTesting(false)
        }
        // Soltar aqui um vídeo arrastado da lista de cima endereça o
        // arquivo a esta tarefa — é o conserto de um nome que não casou.
        .onDrop(of: [.plainText, .utf8PlainText, .text, .fileURL], isTargeted: Binding(
            get: { dropHoverTaskId == task.id },
            set: { hovering in dropHoverTaskId = hovering ? task.id : nil }
        )) { providers in
            acceptDrop(providers, onto: task.id)
        }
        .animation(.easeOut(duration: 0.14), value: isDropTarget)
    }

    private func borderColor(for state: TargetState, hovering: Bool) -> Color {
        if hovering { return Editorial.accent }
        switch state {
        case .awaitingVideo: return Color.orange.opacity(0.75)
        case .blocked:       return Editorial.rule.opacity(0.8)
        case .ready:         return Editorial.rule.opacity(0.45)
        }
    }

    @ViewBuilder
    private func stateBadge(_ state: TargetState) -> some View {
        switch state {
        case .awaitingVideo:
            Text("SEM VÍDEO")
                .font(Editorial.sans(9, .semibold))
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.orange.opacity(0.16)))
        case .blocked:
            Text("não vai receber")
                .font(Editorial.sans(10.5, .medium))
                .foregroundStyle(Editorial.inkSoft)
        case .ready(let count):
            Text("gera \(count) " + (count == 1 ? "vídeo" : "vídeos"))
                .font(Editorial.sans(10.5, .medium))
                .foregroundStyle(Editorial.accent)
                .monospacedDigit()
        }
    }

    /// Vazio chamativo: é o estado que pede ação da pessoa.
    private func emptyTargetSlot(isDropTarget: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 11, weight: .medium))
            Text(isDropTarget ? "Soltar aqui" : "Arraste um vídeo da lista acima")
                .font(Editorial.sans(11, .medium))
        }
        .foregroundStyle(isDropTarget ? Editorial.accent : Color.orange.opacity(0.95))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(isDropTarget ? Editorial.accent : Color.orange.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 11)
    }

    /// Um arquivo dentro do cartão da tarefa, com papel e corte próprios.
    private func routedFileRow(_ base: TaskMediaSelection, task: CUTask) -> some View {
        let current = override(task.id, base.id)
        let effectiveRole = current.role ?? base.role
        return HStack(spacing: 8) {
            // Alça de arrasto: só esta parte inicia o movimento. Com a
            // linha inteira arrastável, o gesto competia com o clique no
            // ✕ ao lado.
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9))
                    .foregroundStyle(Editorial.inkSoft.opacity(0.55))
                Text(base.fileURL.deletingPathExtension().lastPathComponent)
                    .font(Editorial.sans(11))
                    .foregroundStyle(Editorial.inkSoft)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(Rectangle())
            .onDrag {
                draggingSelectionId = base.id
                return NSItemProvider(item: base.id.uuidString as NSString,
                                      typeIdentifier: UTType.plainText.identifier)
            }
            .help("Arraste para outra tarefa")

            Spacer(minLength: 6)

            Button {
                trimSelectionId = base.id
                trimTaskId = task.id
                stage = .trim
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: current.fileURL != nil ? "checkmark" : "scissors")
                    Text(current.fileURL != nil ? "CORTE PRÓPRIO" : "CORTAR AQUI")
                }
                .font(Editorial.sans(8.5, .semibold))
                .foregroundStyle(current.fileURL != nil ? Color.white : Editorial.accent)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(current.fileURL != nil
                                           ? Color.green.opacity(0.85)
                                           : Editorial.accentSoft))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            HStack(spacing: 0) {
                ForEach(TaskMediaRole.allCases, id: \.self) { role in
                    let active = effectiveRole == role
                    Button {
                        var next = current
                        next.role = (role == base.role) ? nil : role
                        setOverride(next, taskId: task.id, selectionId: base.id)
                    } label: {
                        Text(role.rawValue.uppercased())
                            .font(Editorial.sans(8, .semibold))
                            .foregroundStyle(active ? Color.white : Editorial.inkSoft)
                            .padding(.horizontal, 7)
                            .frame(height: 22)
                            .background(active ? Editorial.accent : Color.clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
            .background(Capsule().fill(Editorial.inkFaint.opacity(0.14)))
            .clipShape(Capsule(style: .continuous))

            // Tira o vídeo desta tarefa e devolve para a lista de cima,
            // de onde ele pode ser arrastado para outra.
            Button {
                detach(base.id, from: task.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Editorial.inkSoft)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Tirar desta tarefa")
        }
    }

    private var availableCandidates: [CUTask] {
        let present = Set(targets.map(\.id))
        return request.candidates.filter { !present.contains($0.id) }
    }

    @ViewBuilder private var addTaskRow: some View {
        if !availableCandidates.isEmpty {
            Menu {
                ForEach(availableCandidates.prefix(50)) { task in
                    Button(task.title) {
                        targets.append(task)
                        Task { await reproject() }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("Adicionar tarefa")
                }
                .font(Editorial.sans(11))
                .foregroundStyle(Editorial.inkSoft)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    // MARK: Corte

    @ViewBuilder private var trimBody: some View {
        if let id = trimSelectionId,
           let selection = selections.first(where: { $0.id == id }) {
            ClipTrimmerView(
                url: selection.fileURL,
                onCancel: {
                    trimSelectionId = nil
                    trimTaskId = nil
                    stage = .compose
                },
                onApply: { trimmedURL in
                    if let taskId = trimTaskId {
                        // Corte de UMA tarefa: vira override dela, o padrão
                        // do topo fica intacto para as outras.
                        var next = override(taskId, id)
                        next.fileURL = trimmedURL
                        next.trimmed = true
                        setOverride(next, taskId: taskId, selectionId: id)
                    } else if let index = selections.firstIndex(where: { $0.id == id }) {
                        selections[index].fileURL = trimmedURL
                        selections[index].contentHash = nil
                        selections[index].trimmed = true
                        Task { await reproject() }
                    }
                    trimSelectionId = nil
                    trimTaskId = nil
                    stage = .compose
                }
            )
        } else {
            Color.clear.onAppear { stage = .compose }
        }
    }

    // MARK: Menções

    private var mentionCandidates: [CUMember] {
        let assigneeIds = Set(targets.flatMap { $0.assignees.map(\.id) })
        let q = memberQuery.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                    locale: .current)
        return appState.availableMembers.filter { member in
            q.isEmpty || member.username.localizedCaseInsensitiveContains(q)
        }.sorted {
            let l = assigneeIds.contains($0.id), r = assigneeIds.contains($1.id)
            return l == r
                ? $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
                : l
        }
    }

    private var mentionsBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cada tarefa já menciona os próprios responsáveis. "
                 + "Quem você marcar aqui é mencionado em todas.")
                .font(Editorial.sans(11.5))
                .foregroundStyle(Editorial.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Buscar pessoa", text: $memberQuery)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(mentionCandidates.prefix(40)) { member in
                        Button {
                            if selectedMemberIds.contains(member.id) {
                                selectedMemberIds.remove(member.id)
                            } else {
                                selectedMemberIds.insert(member.id)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selectedMemberIds.contains(member.id)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedMemberIds.contains(member.id)
                                                     ? Editorial.accent : Editorial.inkSoft)
                                Text(member.username)
                                    .font(Editorial.sans(12))
                                    .foregroundStyle(Editorial.ink)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    // MARK: Status

    private var statusBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(coordinator.targets.filter(\.isSendable)) { target in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(target.task.title)
                                .font(Editorial.sans(12.5, .medium))
                                .foregroundStyle(Editorial.ink)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(statusLabel(for: target))
                                .font(Editorial.sans(10.5, .medium))
                                .foregroundStyle(target.phase == .sent
                                                 ? Color.green.opacity(0.9)
                                                 : Editorial.inkSoft)
                        }
                        // Barra desenhada à mão em vez de `ProgressView`.
                        // O `.tint(Editorial.accent)` não estava pegando no
                        // estilo linear do sistema e a barra saía vermelha,
                        // que no app significa erro — exatamente a leitura
                        // errada para um envio que deu certo. Uma cápsula
                        // própria não depende de como a plataforma decide
                        // tingir o widget.
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Editorial.inkFaint.opacity(0.18))
                                Capsule()
                                    .fill(target.phase == .sent
                                          ? Color.green.opacity(0.85)
                                          : Editorial.accent)
                                    .frame(width: geo.size.width
                                           * min(max(target.phase == .sent
                                                     ? 1 : target.progress, 0), 1))
                            }
                        }
                        .frame(height: 4)
                        if let failure = target.failureMessage {
                            Text(failure)
                                .font(Editorial.sans(10.5))
                                .foregroundStyle(Color.red.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 9)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private func statusLabel(for target: TaskBulkMediaCoordinator.Target) -> String {
        switch target.phase {
        case .sent: return "enviado"
        case .sending: return "\(Int((target.progress * 100).rounded()))%"
        case .preparing: return "preparando"
        case .partialFailure, .failed: return "falhou"
        default: return "na fila"
        }
    }

    // MARK: - Rodapé

    @ViewBuilder private var stageFooter: some View {
        switch stage {
        case .compose: composeFooter
        case .mentions: mentionsFooter
        case .status: statusFooter
        default: EmptyView()
        }
    }

    private var composeFooter: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(coordinator.totalOutputs) "
                     + (coordinator.totalOutputs == 1 ? "vídeo" : "vídeos")
                     + " em \(coordinator.sendableTargets.count) "
                     + (coordinator.sendableTargets.count == 1 ? "tarefa" : "tarefas"))
                    .font(Editorial.sans(12.5, .semibold))
                    .foregroundStyle(Editorial.ink)
                    .monospacedDigit()
                // O custo real é explícito: cada saída é um arquivo próprio,
                // porque o ClickUp trata anexo como propriedade da tarefa.
                // Variação por tarefa significa arquivo diferente, logo
                // render e upload próprios. O rodapé não esconde isso.
                Text("\(coordinator.totalOutputs) "
                     + (coordinator.totalOutputs == 1 ? "envio" : "envios")
                     + (overrides.isEmpty
                        ? ""
                        : " · \(overrides.count) com ajuste próprio")
                     + (coordinator.blockedTargets.isEmpty
                        ? ""
                        : " · \(coordinator.blockedTargets.count) de fora")
                     + (unresolvedSelectionIds.isEmpty
                        ? ""
                        : " · \(unresolvedSelectionIds.count) sem tarefa"))
                    .font(Editorial.sans(10.5))
                    .foregroundStyle(Editorial.inkSoft)
            }
            Spacer(minLength: 0)
            primaryButton("CONTINUAR",
                          enabled: !selections.isEmpty
                                && !coordinator.sendableTargets.isEmpty
                                && unresolvedSelectionIds.isEmpty
                                && !working) {
                stage = .mentions
            }
        }
        .padding(.horizontal, 20)
    }

    private var mentionsFooter: some View {
        HStack(spacing: 12) {
            secondaryButton("Voltar") { stage = .compose }
            Spacer(minLength: 0)
            primaryButton("ENVIAR \(coordinator.totalOutputs)", enabled: !working) {
                Task { await send() }
            }
        }
        .padding(.horizontal, 20)
    }

    private var statusFooter: some View {
        HStack(spacing: 12) {
            if coordinator.phase == .partialFailure {
                secondaryButton("Descartar") {
                    coordinator.discardAll()
                    dismiss()
                }
                Spacer(minLength: 0)
                primaryButton("TENTAR NOVAMENTE", enabled: !working) {
                    Task { await send() }
                }
            } else {
                Spacer(minLength: 0)
                primaryButton(coordinator.phase == .done ? "CONCLUIR" : "ENVIANDO…",
                              enabled: coordinator.phase == .done) {
                    dismiss()
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func primaryButton(_ title: String, enabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Editorial.sans(11, .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 34)
                .background(Capsule().fill(enabled
                                           ? Editorial.accent
                                           : Editorial.accent.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!enabled)
    }

    private func secondaryButton(_ title: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Editorial.sans(11, .medium))
                .foregroundStyle(Editorial.inkSoft)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    // MARK: - Ações

    @MainActor
    private func start() async {
        targets = request.tasks
        stage = .dropZone
        // A projeção já roda aqui, sem arquivo: carrega o catálogo de
        // cada tarefa enquanto a pessoa escolhe o vídeo, para a tela
        // seguinte abrir com as regras já calculadas em vez de piscar
        // "calculando…" depois.
        await coordinator.warmUp(tasks: targets, appState: appState)
        // Arrastou o arquivo direto do Finder para a lista: o vídeo já
        // veio junto, não faz sentido pedir de novo.
        if !request.initialURLs.isEmpty {
            for url in request.initialURLs { accept(droppedURL: url) }
        }
    }

    @MainActor
    private func reproject() async {
        // Sem arquivo não há o que projetar, mas as tarefas continuam
        // listadas — quem abriu a janela precisa ver para onde o arquivo
        // vai antes mesmo de escolher qual é.
        guard !selections.isEmpty else { return }
        applyNameMatching()
        working = true
        await coordinator.project(tasks: targets,
                                  selectionsFor: { effectiveSelections(for: $0.id) },
                                  appState: appState)
        working = false
    }

    @MainActor
    private func send() async {
        working = true
        stage = .status
        await coordinator.sendAll(extraMentionMemberIds: Array(selectedMemberIds),
                                  appState: appState)
        working = false
    }

    private func remove(selectionId: UUID) {
        selections.removeAll { $0.id == selectionId }
        Task { await reproject() }
    }

    private func remove(taskId: String) {
        targets.removeAll { $0.id == taskId }
        overrides.removeValue(forKey: taskId)
        Task { await reproject() }
    }

    @discardableResult
    private func append(urls: [URL]) -> [UUID] {
        let known = Set(selections.map(\.fileURL))
        var added: [UUID] = []
        for url in urls where !known.contains(url) {
            let selection = TaskMediaSelection(fileURL: url)
            selections.append(selection)
            added.append(selection.id)
        }
        // Primeiro arquivo aceito: a área de soltar deu lugar à tela que
        // mostra o vídeo em cima e as tarefas com suas regras embaixo.
        if stage == .dropZone, !selections.isEmpty { stage = .compose }
        Task { await reproject() }
        return added
    }

    /// Aceita o arquivo arrastado para dentro da janela.
    ///
    /// A versão anterior filtrava por `hasItemConformingToTypeIdentifier`
    /// e devolvia `false` quando o teste não passava — e ele não passa em
    /// vários arrastes reais do Finder, porque o provider anuncia outros
    /// identificadores. `false` faz o macOS tocar a animação de recusa
    /// (o arquivo "voltando" e sumindo), que foi exatamente o sintoma.
    /// Aqui seguimos o mesmo recibo do compositor de comentários, que
    /// funciona: aceita o drop e resolve o tipo depois de carregar.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        loadFileURLs(from: providers) { url in accept(droppedURL: url) }
    }

    /// Extrai URLs de arquivo de um arrasto do Finder.
    ///
    /// `loadObject(ofClass: URL.self)` parecia funcionar (o alvo até
    /// acendia) mas não entregava nada nesta folha. O caminho confiável
    /// é pedir o item cru por `public.file-url` e montar a URL a partir
    /// do que vier — o Finder manda `Data` com a representação da URL,
    /// e outros remetentes mandam `URL` ou `String`.
    private func loadFileURLs(from providers: [NSItemProvider],
                              handle: @escaping @MainActor (URL) -> Void) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        let usable = fileProviders.isEmpty ? providers : fileProviders
        guard !usable.isEmpty else { return false }

        for provider in usable {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier,
                              options: nil) { item, _ in
                var resolved: URL?
                switch item {
                case let data as Data:
                    resolved = URL(dataRepresentation: data, relativeTo: nil)
                case let url as URL:
                    resolved = url
                case let text as String:
                    resolved = URL(string: text)
                default:
                    resolved = nil
                }
                guard let url = resolved else { return }
                Task { @MainActor in handle(url) }
            }
        }
        return true
    }

    /// O fluxo é de vídeo. Um arquivo de outro tipo não pode sumir em
    /// silêncio — a pessoa precisa saber por que ele não entrou.
    @MainActor
    @discardableResult
    private func accept(droppedURL url: URL) -> UUID? {
        let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
        guard videoExtensions.contains(url.pathExtension.lowercased()) else {
            showError("\(url.lastPathComponent) não é um vídeo — este envio aceita só vídeo.")
            return nil
        }
        return append(urls: [url]).first
    }

    @MainActor
    private func showError(_ message: String) {
        localError = message
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            await MainActor.run { if localError == message { localError = nil } }
        }
    }

    private func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.prompt = "Adicionar"
        // Cancelar o seletor devolve para a área de soltar — fechar a
        // janela inteira roubaria a seleção de tarefas que a pessoa
        // acabou de montar.
        guard panel.runModal() == .OK else { return }
        append(urls: panel.urls)
    }
}
