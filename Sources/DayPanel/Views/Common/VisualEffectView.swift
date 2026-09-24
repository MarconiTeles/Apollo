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
    /// Multiplies the opacity of the material's own fill layer (1 = native).
    /// Keeps the material; lower values make it more translucent.
    var tintOpacity:  CGFloat                         = 1.0
    /// Multiplies the opacity of the material's blend-mode layer (lighten in
    /// dark, darken in light; 1 = native).
    var blendOpacity: CGFloat                         = 1.0
    func makeNSView(context: Context) -> NSVisualEffectView {
        // SEMPRE hit-test-transparente: estes materiais são decorativos
        // (backgrounds de barras/painéis). Como NSViews reais dentro do
        // NSHostingView, eles ENGOLIAM scroll/cliques destinados a listas
        // AppKit irmãs (ex.: o feed do popup de notificações ficava com o
        // scroll travado). hitTest nil deixa tudo passar; os controles
        // SwiftUI por cima seguem funcionando normalmente.
        let v: NSVisualEffectView
        if stripTint || blurScale != 1.0 || tintOpacity != 1.0 || blendOpacity != 1.0 {
            let t = TintlessVisualEffectView()
            t.stripsTint = stripTint
            t.blurScale = blurScale
            t.tintOpacity = tintOpacity
            t.blendOpacity = blendOpacity
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
            tintless.stripsTint = stripTint
            tintless.blurScale = blurScale
            tintless.tintOpacity = tintOpacity
            tintless.blendOpacity = blendOpacity
            tintless.clearTintLayers()
        }
    }
}

/// Shaped headers share the page-header material in light mode.
/// Preserve their existing approved dark appearance.
struct OfficialHeaderMaterial<S: Shape>: View {
    @Environment(\.colorScheme) private var colorScheme
    let shape: S

    var body: some View {
        if colorScheme == .dark {
            VisualEffectView(material: .fullScreenUI,
                             blendingMode: .withinWindow,
                             state: .active,
                             stripTint: true,
                             blurScale: 5.0 / 30.0)
                .overlay(Editorial.paper.opacity(0.85))
                .clipShape(shape)
        } else {
            AppHeaderMaterial().clipShape(shape)
        }
    }
}

extension View {
    /// Aplica a receita oficial do material de header como background,
    /// recortada na `shape` (barras de popup com cantos arredondados etc.).
    func officialHeaderMaterial<S: Shape>(in shape: S) -> some View {
        background(OfficialHeaderMaterial(shape: shape))
    }
}

/// Shared page-header material. Light mode uses the system
/// sidebar's regular glass. Dark mode retains the approved sidebar recipe
/// with reduced blur and a 30% black veil.
struct AppHeaderMaterial: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .dark {
            // Keep the approved dark recipe even when the window loses focus.
            VisualEffectView(material: .sidebar,
                             blendingMode: .withinWindow,
                             state: .active,
                             blurScale: 0.16)
                .overlay(Color.black.opacity(0.3))
        } else {
            // Sidebar background recipe, with the requested lighter blur
            // and white veil applied only in light mode.
            PanelGlassMaterial()
                .overlay(Color.white.opacity(0.252))
        }
    }
}

/// The sidebar BACKGROUND recipe, not the regular control/selection glass.
/// On macOS 27 both are NSGlassEffectView, but the system sidebar uses
/// variant 17 and adaptive appearance 1; controls use variant 0 / appearance 2.
/// These AppKit-internal settings were read from NavigationSplitView's
/// _NSSplitViewItemViewWrapper background (see docs/qa-header-light).
private struct PanelGlassMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SidebarBackgroundView() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? SidebarBackgroundView)?.refreshMaterial()
    }

    private final class SidebarBackgroundView: NSView {
        private let background = HeaderSidebarEffectView()
        // Keep the native surface's refracting perimeter outside the header.
        // Clipping exposes its flat interior without changing the material.
        private let perimeterInset: CGFloat = 64

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = true
            clipsToBounds = true
            background.style = .regular
            background.cornerRadius = 0
            background.setValue(17, forKey: "_variant")
            background.setValue(1, forKey: "_adaptiveAppearance")
            // 0 follows focus; 1 fixes the subdued (unfocused) appearance.
            background.setValue(1, forKey: "_subduedState")
            addSubview(background)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            background.frame = bounds.insetBy(dx: -perimeterInset,
                                              dy: -perimeterInset)
        }

        func refreshMaterial() {
            background.refreshMaterial()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private final class HeaderSidebarEffectView: NSGlassEffectView {
        private var refreshScheduled = false
        private var layerObservations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]

        override func layout() {
            super.layout()
            refreshMaterial()
        }

        override func updateLayer() {
            super.updateLayer()
            applyMaterial()
        }

        override func viewWillDraw() {
            super.viewWillDraw()
            applyMaterial()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            refreshMaterial()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            refreshMaterial()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            refreshMaterial()
        }

        func refreshMaterial() {
            applyMaterial()
            // AppKit may rebuild its backdrop after attachment/layout.
            // Coalesce a second pass; never continuously invalidate layout.
            guard !refreshScheduled else { return }
            refreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshScheduled = false
                self.applyMaterial()
            }
        }

        private func applyMaterial() {
            // The recipe must survive native layer/appearance rebuilds too.
            for (key, target) in [("_variant", 17),
                                  ("_adaptiveAppearance", 1),
                                  ("_subduedState", 1)] {
                if (value(forKey: key) as? NSNumber)?.intValue != target {
                    setValue(target, forKey: key)
                }
            }
            if let layer {
                var liveLayers: Set<ObjectIdentifier> = []
                observeLayerTree(layer, liveLayers: &liveLayers)
                layerObservations = layerObservations.filter { liveLayers.contains($0.key) }
                reduceBlur(in: layer)
            }
        }

        private func observeLayerTree(_ node: CALayer,
                                      liveLayers: inout Set<ObjectIdentifier>) {
            let id = ObjectIdentifier(node)
            liveLayers.insert(id)
            if layerObservations[id] == nil {
                // Native backdrop reconstruction does not necessarily call
                // NSView.layout/updateLayer. Observe the actual layer tree.
                let children = node.observe(\.sublayers) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.refreshMaterial() }
                }
                let filters = node.observe(\.filters) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.refreshMaterial() }
                }
                layerObservations[id] = [children, filters]
            }
            for child in node.sublayers ?? [] {
                observeLayerTree(child, liveLayers: &liveLayers)
            }
        }

        private func reduceBlur(in layer: CALayer) {
            if NSStringFromClass(type(of: layer)).contains("Backdrop") {
                for filter in layer.filters ?? [] {
                    let filter = filter as AnyObject
                    guard (filter.value(forKey: "name") as? String) == "glassBackground"
                    else { continue }
                    // Absolute targets: never derive them from a transient
                    // native radius captured during creation or screen changes.
                    for (key, target): (String, CGFloat) in [
                        ("inputBlurRadius", 3.98034),
                        ("inputBlurFillBlurRadius", 1.592136)
                    ] {
                        let path = "filters.glassBackground.\(key)"
                        guard let number = layer.value(forKeyPath: path) as? NSNumber
                        else { continue }
                        let current = CGFloat(truncating: number)
                        if abs(current - target) > 0.01 {
                            layer.setValue(target, forKeyPath: path)
                        }
                    }
                    // Avoid the extra softening from the native half-size capture.
                    if (layer.value(forKey: "scale") as? NSNumber)?.doubleValue != 1 {
                        layer.setValue(1.0, forKey: "scale")
                    }
                }
            }
            for child in layer.sublayers ?? [] { reduceBlur(in: child) }
        }
    }
}

/// Header sources report only their own geometry. A window-wide preference
/// reader forces SwiftUI to evaluate preferences through scrolling lazy rows.
@MainActor
final class HeaderBoundsStore: ObservableObject {
    @Published private(set) var bottom: CGFloat = 52
    private var sources: [UUID: CGFloat] = [:]

    func update(_ id: UUID, bottom: CGFloat?) {
        guard sources[id] != bottom else { return }
        sources[id] = bottom
        let next = max(52, sources.values.max() ?? 52)
        if self.bottom != next { self.bottom = next }
    }
}

private struct HeaderBoundsStoreKey: EnvironmentKey {
    static let defaultValue: HeaderBoundsStore? = nil
}
extension EnvironmentValues {
    var headerBoundsStore: HeaderBoundsStore? {
        get { self[HeaderBoundsStoreKey.self] }
        set { self[HeaderBoundsStoreKey.self] = newValue }
    }
}

private struct FinderHeaderMaterialModifier: ViewModifier {
    @Environment(\.headerBoundsStore) private var headerBounds
    @State private var sourceID = UUID()
    @State private var measuredBottom: CGFloat?
    let leadingExtension: CGFloat
    let trailingExtension: CGFloat
    let topExtension: CGFloat
    let bottomExtension: CGFloat
    let bottomRule: Bool

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named("appWindow")).maxY + bottomExtension
            } action: { bottom in
                measuredBottom = bottom
                headerBounds?.update(sourceID, bottom: bottom)
            }
            .onAppear { headerBounds?.update(sourceID, bottom: measuredBottom) }
            .onDisappear { headerBounds?.update(sourceID, bottom: nil) }
            .background(alignment: .topLeading) {
            GeometryReader { proxy in
                AppHeaderMaterial()
                    // DEV-only attribution switch (`--board-diag=noheadermaterial`);
                    // never a delivery state. Always visible outside APOLLO_DEV.
                    .opacity(BoardDiag.has("noheadermaterial") ? 0 : 1)
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
    /// false = mantém a cor/vibrancy nativa do material e só escala o blur.
    var stripsTint = true
    /// Com `stripsTint == false`: fator sobre a opacidade das layers de tint
    /// nativas (1 = nativo). Mesmo material, mais translúcido.
    var tintOpacity: CGFloat = 1.0
    /// Idem para a layer com blend mode (lighten no escuro, darken no claro).
    var blendOpacity: CGFloat = 1.0
    /// Opacidade nativa de cada layer de tint, para escalar de forma idempotente.
    private var baseTintOpacity: [ObjectIdentifier: Float] = [:]
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
           root.bounds.width > 0, Self.containsBackdrop(root) {
            Self.didDumpTree = true
            dumpTree(root, depth: 0)
        }
    }

    private static func containsBackdrop(_ node: CALayer) -> Bool {
        if NSStringFromClass(type(of: node)).contains("Backdrop") { return true }
        return (node.sublayers ?? []).contains { containsBackdrop($0) }
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
        let comp = node.compositingFilter.map { String(describing: ($0 as AnyObject).value(forKey: "name") ?? $0) } ?? "-"
        let rgb = node.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
            .map { String(format: "%.3f,%.3f,%.3f", $0.redComponent, $0.greenComponent, $0.blueComponent) } ?? "-"
        NSLog("APOLLO-TREE %@%@ bgA=%.2f rgb=%@ comp=%@ op=%.2f contents=%d filters=[%@] size=%.0fx%.0f",
              pad, cls, bgA, rgb, comp, node.opacity, hasContents ? 1 : 0, fnames,
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
                    if stripsTint, hasNonBlur, !kept.isEmpty { sub.filters = kept }
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
            } else if !stripsTint {
                // Keep the native tint layer; only scale its opacity.
                if let bg = sub.backgroundColor, bg.alpha > 0 {
                    let id = ObjectIdentifier(sub)
                    if baseTintOpacity[id] == nil { baseTintOpacity[id] = sub.opacity }
                    let factor = sub.compositingFilter == nil ? tintOpacity : blendOpacity
                    let target = (baseTintOpacity[id] ?? 1) * Float(factor)
                    if abs(sub.opacity - target) > 0.001 { sub.opacity = target }
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
