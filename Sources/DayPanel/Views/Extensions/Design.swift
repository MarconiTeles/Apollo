import SwiftUI
import AppKit

// Studio Glass — primitivos de design compartilhados sobre o Editorial
// (portado do Galileo/EditKit): sistema de motion, ritmo de espaçamento,
// vidro de controle (glassControl) e hover affordances.

// SISTEMA DE MOTION — 3 durações + 1 física, em vez de durações ad hoc.
// fast: hover/seleção · standard: trocas de estado · panel: overlays ·
// magnetic: acomodação com física (springs de lista/board).
enum Motion {
    static let fast = Animation.easeOut(duration: 0.12)
    static let standard = Animation.easeOut(duration: 0.18)
    static let panel = Animation.easeInOut(duration: 0.25)
    static let magnetic = Animation.spring(response: 0.32, dampingFraction: 0.82)
}

enum Space {
    static let xs: CGFloat = 3
    static let s: CGFloat = 6
    static let m: CGFloat = 10
    static let l: CGFloat = 13
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 22
}

// MARK: - Liquid Glass de controle (chips, CTAs, popovers, seleção)

extension View {
    /// Liquid Glass nativo (macOS 26) com fallback em material fino +
    /// hairline, e sólido no Tier C. Use APENAS em chips, toggles ligados,
    /// busca, popups e CTAs — NUNCA em painéis grandes/chrome.
    @ViewBuilder
    func glassControl<S: Shape>(_ shape: S = RoundedRectangle(cornerRadius: 7, style: .continuous),
                                tint: Color? = nil, edge: Bool = true) -> some View {
        if Materials.tier == .solid {
            // Tier C (Intel / Reduce Transparency): sólido e rápido.
            self.background(shape.fill(tint ?? Editorial.card))
                .overlay(shape.stroke(edge ? Editorial.rule : .clear, lineWidth: 1))
        } else if #available(macOS 26.0, *) {
            self.glassEffect(tint.map { .regular.tint($0) } ?? .regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.fill(tint?.opacity(0.18) ?? .clear))
                .overlay(shape.stroke(edge ? Color.white.opacity(0.14) : .clear, lineWidth: 0.5))
        }
    }

    /// Vidro de BARRA SUPERIOR (full-width): base translúcida + Liquid
    /// Glass — o conteúdo que rola por baixo aparece através.
    func floatingBarGlass() -> some View {
        background {
            ZStack {
                Rectangle().fill(Editorial.card.opacity(0.72))
                Color.clear.glassControl(Rectangle(), edge: false)
            }
        }
    }
}

// MARK: - Hover wash (rows de lista/menus)

struct HoverRow: ViewModifier {
    var radius: CGFloat
    var inset: CGFloat
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(hover ? Editorial.rule : .clear)
                    .padding(.horizontal, -inset)
            )
            .scrollAwareOnHover { hover = $0 }
            .animation(Motion.fast, value: hover)
    }
}

extension View {
    func hoverRow(radius: CGFloat = 6, inset: CGFloat = 6) -> some View {
        modifier(HoverRow(radius: radius, inset: inset))
    }
}
