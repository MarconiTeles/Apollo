import SwiftUI

/// Vídeo solto sobre uma tarefa que já tem vídeo: adicionar como novo
/// ou substituir um existente?
///
/// A pergunta mora na lista, por cima da página, e não dentro da folha
/// de anexo. Uma sheet vive numa `NSWindow` própria, e no macOS 26+ o
/// sistema pinta um material nessa janela que o SwiftUI não alcança —
/// o cartão aparecia no meio de um painel cinza de 680×540. Aqui atrás
/// dele fica o próprio app, e a folha só abre depois da escolha, já na
/// etapa certa.
///
/// Fundo opaco do tema para que o conteúdo da lista não atravesse
/// a pergunta e suas opções; mantém o raio de popup existente.
///
/// O título faz a pergunta; embaixo, as duas escolhas
/// lado a lado, cada uma só com o ícone à esquerda do nome — a pessoa
/// acabou de soltar o arquivo, não precisa de explicação para decidir.
/// Sem seta de navegação (seta é
/// gramática de lista empilhada), e os dois blocos nascem iguais:
/// um bloco já aceso lia como opção marcada à espera de um "Continuar"
/// que não existe, e o outro, mais escuro, parecia desabilitado. O hover
/// acende o que o clique vai fazer; o Return escolhe Adicionar, o
/// caminho que não mexe no que está publicado, sinalizado só por uma
/// borda leve.
struct TaskMediaDropDecisionOverlay: View {
    let isLoading: Bool
    let canReplace: Bool
    let onAdd: () -> Void
    let onReplace: () -> Void
    let onCancel: () -> Void

    /// Qual bloco está sob o cursor — só ele acende.
    @State private var hoveredChoice: TaskMediaDropChoice?

    var body: some View {
        ZStack {
            // Transparente mas clicável: clicar fora cancela, como em
            // qualquer diálogo do sistema.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)
            Group {
                if isLoading {
                    loadingCard.frame(width: 340)
                } else {
                    decisionCard.frame(width: 340)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
        .animation(.easeOut(duration: 0.16), value: isLoading)
        .onExitCommand(perform: onCancel)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Editorial.popupRadius(9), style: .continuous)
    }

    private var cardBackground: some View {
        shape.fill(Editorial.popup)
            .overlay {
                shape.strokeBorder(Editorial.rule, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }

    private var loadingCard: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Lendo o histórico desta tarefa…")
                .font(Editorial.sans(11.5))
                .foregroundStyle(Editorial.inkSoft)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .background(cardBackground)
    }

    private var decisionCard: some View {
        VStack(spacing: 0) {
            Text("O que deseja fazer?")
                .font(Editorial.sans(15, .semibold))
                .foregroundStyle(Editorial.ink)
                .padding(.bottom, 14)

            HStack(spacing: 10) {
                TaskMediaDropChoiceCard(
                    icon: "plus.circle.fill",
                    title: "Adicionar",
                    isDefault: true,
                    lit: hoveredChoice == .add,
                    onHover: { hoveredChoice = $0 ? .add : nil },
                    action: onAdd)
                .keyboardShortcut(.defaultAction)
                TaskMediaDropChoiceCard(
                    icon: "arrow.triangle.2.circlepath.circle.fill",
                    title: "Substituir",
                    isDefault: false,
                    lit: hoveredChoice == .replace,
                    onHover: { hoveredChoice = $0 && canReplace ? .replace : nil },
                    action: onReplace)
                .disabled(!canReplace)
            }

            Button("Cancelar", action: onCancel)
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .font(Editorial.sans(12, .medium))
                .foregroundStyle(Editorial.inkSoft)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .padding(.top, 6)
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
        .padding(.bottom, 8)
        .background(cardBackground)
    }
}

/// Uma das duas escolhas: ícone à esquerda e o nome. Fundo igual para
/// os dois — um pouco MAIS claro que o painel, para ler como botão e
/// não como área afundada.
private struct TaskMediaDropChoiceCard: View {
    let icon: String
    let title: String
    /// Responde ao Return: ganha só uma borda leve, nunca o aceso.
    let isDefault: Bool
    let lit: Bool
    let onHover: (Bool) -> Void
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    private var borderColor: Color {
        if lit { return Editorial.accent.opacity(0.8) }
        if isDefault { return Editorial.accent.opacity(0.32) }
        return Color.white.opacity(0.09)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Editorial.popupRadius(6),
                                     style: .continuous)
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Editorial.accent)
                Text(title)
                    .font(Editorial.sans(13, .semibold))
                    .foregroundStyle(Editorial.ink)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(shape.fill(lit ? Editorial.accent.opacity(0.14)
                                       : Color.white.opacity(0.045)))
            .overlay {
                shape.strokeBorder(borderColor, lineWidth: lit ? 1 : 0.8)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .opacity(isEnabled ? 1 : 0.42)
        .onHover(perform: onHover)
        .animation(.easeOut(duration: 0.14), value: lit)
    }
}
