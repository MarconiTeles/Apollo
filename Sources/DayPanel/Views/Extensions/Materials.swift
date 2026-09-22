import AppKit
import SwiftUI

// STUDIO GLASS — SISTEMA DE MATERIAIS EM TIERS (o contrato de desempenho).
// Portado do Galileo/EditKit. O vidro é um sistema, não uma chamada de API:
//   A liquidGlass — Apple Silicon + macOS 26 (refração real via glassEffect)
//   B vibrancy    — Apple Silicon em macOS 14-25 (material compatível)
//   C solid       — Intel, Reduce Transparency (HIG manda respeitar)
// REGRAS DURAS: vidro só na camada SUPERIOR (chips, popups, cards flutuantes;
// janela e painéis = sólidos) · ≤8 regiões por janela · zero vidro aninhado ·
// animações contínuas gateadas (AgentGlow respeita).

enum Materials {
    enum Tier { case liquidGlass, vibrancy, solid }

    /// Resolvido 1× no launch (mudanças exigiriam observer — v1 honesto:
    /// relança). Low Power NÃO mata o vidro: material ESTÁTICO não drena
    /// bateria — o contrato corta animação contínua, não o material. Low
    /// Power therefore keeps native Liquid Glass; animation-heavy effects
    /// are already gated independently by `AgentGlow` and ScrollGate.
    static let tier: Tier = {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency { return .solid }   // acessibilidade: obrigatório
        var sys = utsname(); uname(&sys)
        let machine = withUnsafeBytes(of: &sys.machine) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        guard machine.hasPrefix("arm64") else { return .solid }   // Intel: iGPU + compositor → sólido
        if #available(macOS 26.0, *) { return .liquidGlass }
        return .vibrancy
    }()
}

extension View {
    /// A LÂMINA: raiz da janela. Studio Glass decidiu que vidro NÃO vai em
    /// painel grande de fundo — janela e painéis são sólidos; vidro só na
    /// camada superior (chips, popovers, cards flutuantes).
    @ViewBuilder func windowGlass() -> some View {
        self.background(Editorial.paper)
    }

    /// PAINEL (sidebar, colunas, sub-áreas): sólido SEMPRE.
    @ViewBuilder func panelGlass() -> some View {
        self.background(Editorial.page)
    }

    /// CARD FLUTUANTE modal (popups de detalhe/criação/settings): vidro
    /// espesso + sombra de elevação. Substitui o trio fill + stroke + shadow.
    @ViewBuilder func floatingPanel(cornerRadius: CGFloat = 16) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        switch Materials.tier {
        case .solid:
            self.background(shape.fill(Editorial.popup))
                .overlay(shape.strokeBorder(Editorial.rule, lineWidth: 1))
                .shadow(color: .black.opacity(0.30), radius: 26, y: 12)
        case .liquidGlass:
            self.glassControl(shape)
                .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
        case .vibrancy:
            self.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))  // fio de luz
                .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
        }
    }
}

/// GLOW DO AGENTE (estilo Apple Intelligence): borda de luz multicolor
/// girando — identidade visual de "IA trabalhando". GATEADO pelo contrato:
/// Reduce Motion, Tier C ou Low Power → borda accent estática (zero
/// animação contínua).
struct AgentGlow: View {
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(cornerRadius: CGFloat = 18) { self.cornerRadius = cornerRadius }
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceMotion || Materials.tier == .solid || ProcessInfo.processInfo.isLowPowerModeEnabled {
            shape.strokeBorder(Editorial.accent.opacity(0.35), lineWidth: 1)
        } else {
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let a = Angle.degrees(t.truncatingRemainder(dividingBy: 12) / 12 * 360)
                shape.strokeBorder(
                    AngularGradient(colors: [Color(hex: "#5AC8FA"), Color(hex: "#7C5CFF"),
                                             Color(hex: "#FF6AC1"), Color(hex: "#FF9F0A"),
                                             Color(hex: "#5AC8FA")],
                                    center: .center, angle: a),
                    lineWidth: 1.5)
                .shadow(color: .black.opacity(0.18), radius: 10)
            }
        }
    }
}
