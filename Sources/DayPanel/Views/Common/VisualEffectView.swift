import SwiftUI
import AppKit

// SwiftUI's `.ultraThinMaterial` is the lightest of the bundled materials,
// but it still applies a fairly heavy Gaussian blur. NSVisualEffectView
// exposes finer-grained materials — `.underWindowBackground` and
// `.fullScreenUI` give a noticeably lighter blur, much closer to the look
// of macOS Control Center where the desktop colours bleed through with
// only mild softening.

struct VisualEffectView: NSViewRepresentable {
    var material:     NSVisualEffectView.Material     = .underWindowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state:        NSVisualEffectView.State        = .active
    /// When true, walks the NSVisualEffectView's sublayer
    /// tree on every update and clears the background color
    /// of any non-backdrop layers — i.e. the layers AppKit
    /// uses to overlay the material's coloured tint /
    /// vibrancy on top of the blur. Pure Gaussian blur
    /// remains; the dark/light tint goes away.
    var stripTint:    Bool                            = false
    /// Fator aplicado ao raio do blur do material (só com `stripTint`). 1.0 =
    /// raio nativo; 0.5 = metade do blur. Escalado sobre o valor-base capturado
    /// uma vez, então é idempotente entre layouts.
    var blurScale:    CGFloat                         = 1.0
    func makeNSView(context: Context) -> NSVisualEffectView {
        // SEMPRE hit-test-transparente: estes materiais são decorativos
        // (backgrounds de barras/painéis). Como NSViews reais dentro do
        // NSHostingView, eles ENGOLIAM scroll/cliques destinados a listas
        // AppKit irmãs (ex.: o feed do popup de notificações ficava com o
        // scroll travado). hitTest nil deixa tudo passar; os controles
        // SwiftUI por cima seguem funcionando normalmente.
        let v: NSVisualEffectView
        if stripTint {
            let t = TintlessVisualEffectView()
            t.blurScale = blurScale
            v = t
        } else {
            v = PassthroughVisualEffectView()
        }
        v.material         = material
        v.blendingMode     = blendingMode
        v.state            = state
        v.isEmphasized     = false
        // The blur/tint adjustment below operates on the material's layer
        // tree. Make that contract explicit; otherwise AppKit may keep the
        // effect view view-backed and `layer` remains nil during layout,
        // leaving the original opaque header tint untouched.
        v.wantsLayer       = true
        v.autoresizingMask = [.width, .height]
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material     = material
        v.blendingMode = blendingMode
        v.state        = state
        if let tintless = v as? TintlessVisualEffectView {
            tintless.blurScale = blurScale
            tintless.clearTintLayers()
        }
    }
}

/// A RECEITA OFICIAL do material de header do app (a mesma do header de
/// Tarefas): `.fullScreenUI` sem tint nativo + blur reduzido (raio 5) +
/// véu de `Editorial.paper` a 0.85. Reutilizável em qualquer barra/painel
/// (popups, rodapés, sidebars) via `officialHeaderMaterial(in:)`.
struct OfficialHeaderMaterial<S: Shape>: View {
    let shape: S

    var body: some View {
        VisualEffectView(material: .fullScreenUI,
                         blendingMode: .withinWindow,
                         state: .followsWindowActiveState,
                         stripTint: true,
                         blurScale: 5.0 / 30.0)
            .overlay(Editorial.paper.opacity(0.85))
            .clipShape(shape)
    }
}

extension View {
    /// Aplica a receita oficial do material de header como background,
    /// recortada na `shape` (barras de popup com cantos arredondados etc.).
    func officialHeaderMaterial<S: Shape>(in shape: S) -> some View {
        background(OfficialHeaderMaterial(shape: shape))
    }
}

private struct FinderHeaderMaterialModifier: ViewModifier {
    let leadingExtension: CGFloat
    let trailingExtension: CGFloat
    let topExtension: CGFloat
    let bottomExtension: CGFloat
    let bottomRule: Bool

    func body(content: Content) -> some View {
        content.background(alignment: .topLeading) {
            GeometryReader { proxy in
                // Header = blur nativo MAIS LEVE. `.fullScreenUI` tem o menor
                // véu-base dos materiais (junto do underWindowBackground);
                // `.withinWindow` desfoca o conteúdo da janela (os cards atrás)
                // e `stripTint: true` tira a camada de cor/vibrancy — sobra o
                // blur mais limpo que o nativo permite.
                VisualEffectView(material: .fullScreenUI,
                                 blendingMode: .withinWindow,
                                 state: .followsWindowActiveState,
                                 stripTint: true,
                                 blurScale: 5.0 / 30.0) // raio 5 (nativo = 30)
                    // Tint da cor do fundo (paper) por cima do blur — o véu
                    // que separa o header do conteúdo, na cor do canvas.
                    .overlay(Editorial.paper.opacity(0.85))
                    .frame(width: proxy.size.width + leadingExtension + trailingExtension,
                           height: proxy.size.height + topExtension + bottomExtension)
                    // Linha do FIM DO HEADER: desenhada no fim REAL do material
                    // (já com a extensão), então segue o verdadeiro fim sem
                    // depender do layout — usada no Quadro.
                    .overlay(alignment: .bottom) {
                        if bottomRule {
                            Rectangle().fill(Editorial.rule).frame(height: 1)
                        }
                    }
                    .offset(x: -leadingExtension, y: -topExtension)
            }
        }
    }
}

extension View {
    /// Finder-style toolbar surface for sticky top chrome. `.titlebar` is the
    /// semantic AppKit material used by native window chrome, so AppKit owns
    /// its blur, vibrancy and light/dark adaptation. `leadingExtension` lets a
    /// route whose content is inset around the floating sidebar still paint one
    /// uninterrupted material band all the way to the window's leading edge.
    /// `bottomExtension` estende SÓ o material para baixo (via background, fora
    /// do fluxo de layout), sem alterar a altura medida do conteúdo — usado no
    /// Quadro para o material alcançar abaixo da faixa de labels de status.
    /// `trailingExtension` estende à direita — junto com `leadingExtension`
    /// deixa uma banda ROLANTE (dentro de um scroll horizontal) larga o
    /// bastante para as bordas retangulares nunca aparecerem na viewport.
    /// `topExtension` estende para CIMA (até y=0 da janela, p.ex.) — usado no
    /// Quadro para a banda dos labels e o chrome do topo compartilharem UM
    /// material contínuo, sem emenda visível.
    func finderHeaderMaterial(leadingExtension: CGFloat = 0,
                              trailingExtension: CGFloat = 0,
                              topExtension: CGFloat = 0,
                              bottomExtension: CGFloat = 0,
                              bottomRule: Bool = false) -> some View {
        modifier(FinderHeaderMaterialModifier(
            leadingExtension: max(0, leadingExtension),
            trailingExtension: max(0, trailingExtension),
            topExtension: max(0, topExtension),
            bottomExtension: max(0, bottomExtension),
            bottomRule: bottomRule
        ))
    }
}

/// NSVisualEffectView subclass that, after every layout pass,
/// inspects its CALayer hierarchy and clears the background
/// colour on every layer EXCEPT the actual backdrop blur
/// layer. AppKit's NSVisualEffectView stacks the blur (a
/// `CABackdropLayer` instance) plus one or more colour-tint
/// layers on top of it; the indices vary across macOS
/// versions / materials, so identifying the backdrop by class
/// name is more reliable than picking by position.
/// Variante decorativa do NSVisualEffectView: nunca participa de hit-test.
final class PassthroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class TintlessVisualEffectView: NSVisualEffectView {
    /// Material decorativo — transparente a eventos (ver PassthroughVEV).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Fator do raio do blur (1.0 = nativo, 0.5 = metade).
    var blurScale: CGFloat = 1.0
    /// Raio nativo capturado na primeira passada, para escalar de forma
    /// idempotente (não encolher a cada layout).
    private var baseBlurRadius: CGFloat?

    override func layout() {
        super.layout()
        // Passe SÍNCRONO apenas — o passe extra async aqui, combinado com a
        // reatribuição incondicional de filtros, formava um loop de
        // invalidação (layout → dirty → layout) que travava o scroll.
        clearTintLayers()
    }

    // O AppKit REASSERTA a receita do material (filtros/scale do backdrop) em
    // momentos próprios — depois do layout, ao entrar na janela, ao trocar de
    // aparência. Uma view FIXA (fora de scroll) quase não re-layouta, então
    // limpar só em layout() deixava a receita nativa vencer. Reasserta em
    // todos os hooks + um segundo passe no próximo runloop.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reassertTintless()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        reassertTintless()
    }

    override func updateLayer() {
        super.updateLayer()
        clearTintLayers()
    }

    private func reassertTintless() {
        clearTintLayers()
        DispatchQueue.main.async { [weak self] in
            self?.clearTintLayers()
        }
    }

    func clearTintLayers() {
        guard let root = layer else { return }
        clearTintLayers(in: root)
        // Só despeja quando a árvore do material já foi montada pelo AppKit
        // (dump precoce mostrava apenas a backing layer vazia 0x0).
        if !Self.didDumpTree, !(root.sublayers ?? []).isEmpty,
           root.bounds.width > 0 {
            Self.didDumpTree = true
            dumpTree(root, depth: 0)
        }
    }

    /// Dump único da árvore de layers do material — cada linha mostra quem
    /// pode estar pintando o véu (bg alpha, opacity, contents, filtros).
    private static var didDumpTree = false
    private func dumpTree(_ node: CALayer, depth: Int) {
        let pad = String(repeating: "  ", count: depth)
        let cls = NSStringFromClass(type(of: node))
        let bgA = node.backgroundColor?.alpha ?? -1
        let hasContents = node.contents != nil
        let fnames = (node.filters ?? []).compactMap {
            ($0 as AnyObject).value(forKey: "name") as? String
        }.joined(separator: ",")
        NSLog("APOLLO-TREE %@%@ bgA=%.2f op=%.2f contents=%d filters=[%@] size=%.0fx%.0f",
              pad, cls, bgA, node.opacity, hasContents ? 1 : 0, fnames,
              node.bounds.width, node.bounds.height)
        for s in node.sublayers ?? [] { dumpTree(s, depth: depth + 1) }
    }

    /// Log de diagnóstico único (primeira árvore inspecionada).
    private static var didLogFilters = false

    private func clearTintLayers(in node: CALayer) {
        for sub in node.sublayers ?? [] {
            let className = NSStringFromClass(type(of: sub))
            if className.contains("Backdrop") {
                // The backdrop layer's tint/blur live in its `filters` chain.
                // ⚠️ No macOS moderno esses filtros são `CAFilter` (classe
                // PRIVADA do Core Animation), NÃO `CIFilter` — o antigo cast
                // `as? [CIFilter]` falhava silencioso e nem o strip nem o
                // blurScale rodavam. KVC (`value(forKey:)`) funciona pros dois.
                if let filters = sub.filters, !filters.isEmpty {
                    if !Self.didLogFilters {
                        Self.didLogFilters = true
                        for f in filters {
                            let obj = f as AnyObject
                            let cls = NSStringFromClass(type(of: obj))
                            let name = (obj.value(forKey: "name") as? String) ?? "?"
                            let radius = obj.value(forKey: "inputRadius") ?? "-"
                            NSLog("APOLLO-TintlessVEV filtro: class=%@ name=%@ inputRadius=%@",
                                  cls, name, String(describing: radius))
                        }
                    }
                    var kept: [Any] = []
                    var blurName: String?
                    var hasNonBlur = false
                    for f in filters {
                        let obj = f as AnyObject
                        let name = (obj.value(forKey: "name") as? String) ?? ""
                        guard name.lowercased().contains("blur") else {
                            hasNonBlur = true
                            continue
                        }
                        blurName = name
                        if baseBlurRadius == nil {
                            baseBlurRadius =
                                (obj.value(forKey: "inputRadius") as? NSNumber)
                                    .map { CGFloat(truncating: $0) }
                        }
                        kept.append(f)
                    }
                    // IDEMPOTENTE: só reatribui a cadeia se ela ainda tiver
                    // filtro de tint. Reatribuir `filters` toda passada sujava
                    // a layer tree → novo layout → nova passada → LOOP que
                    // saturava a main thread (scroll "travado" perto de
                    // qualquer material).
                    if hasNonBlur, !kept.isEmpty { sub.filters = kept }
                    // Core Animation COPIA os filtros ao atribuí-los à layer —
                    // mutar o objeto original é no-op. O caminho documentado
                    // pra alterar parâmetro de filtro JÁ ANEXADO é via keyPath
                    // NA LAYER: "filters.<nome>.inputRadius". Também guardado
                    // por comparação pra não sujar a tree à toa.
                    if blurScale != 1.0, let name = blurName, let base = baseBlurRadius {
                        let target = base * blurScale
                        let current = (sub.value(forKeyPath: "filters.\(name).inputRadius")
                                       as? NSNumber).map { CGFloat(truncating: $0) }
                        if current == nil || abs(current! - target) > 0.01 {
                            sub.setValue(target, forKeyPath: "filters.\(name).inputRadius")
                        }
                    }
                    // O CABackdropLayer também DOWNSAMPLEIA a captura (chave
                    // privada "scale" < 1) — isso borra o conteúdo capturado
                    // INDEPENDENTE do raio do gaussiano (por isso mexer no
                    // inputRadius parecia não ter efeito). Força captura 1:1.
                    let curScale = (sub.value(forKey: "scale") as? NSNumber)?
                        .doubleValue ?? -1
                    if curScale != 1.0 {
                        sub.setValue(1.0, forKey: "scale")
                        NSLog("APOLLO-TintlessVEV backdrop scale %@ -> 1.0",
                              String(describing: curScale))
                    }
                }
            } else {
                // Tint/vibrancy overlay layer — wipe its colour and any
                // composite/background filters that contribute to the tint.
                // Guardado por comparação (idempotente, não suja a tree).
                if let bg = sub.backgroundColor, bg.alpha > 0 {
                    sub.backgroundColor = NSColor.clear.cgColor
                }
                if sub.compositingFilter != nil { sub.compositingFilter = nil }
                if !(sub.backgroundFilters ?? []).isEmpty { sub.backgroundFilters = [] }
            }
            clearTintLayers(in: sub)
        }
    }
}
