import SwiftUI

// Apollo · Shared Liquid Glass + hover primitives.
//
// One place for the button/pill surface treatments the UI asks for
// repeatedly: a subtle hover lift, a Liquid Glass background, and a
// Liquid Glass "selected" pill. On macOS 26+ these use the real
// Liquid Glass material (interactive glass also carries Apple's own
// built-in hover/press response); older systems fall back to a
// translucent tinted fill so the app still builds + looks coherent on
// macOS 14–15.

// MARK: - Hover lift

private struct GlassHoverModifier: ViewModifier {
    var scale: CGFloat
    var brightness: Double
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? scale : 1)
            .brightness(hovering ? brightness : 0)
            .animation(.easeOut(duration: 0.14), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Subtle hover lift for interactive pills/buttons — scales up a
    /// touch and brightens on cursor-over. Cheap, self-contained
    /// `@State`, safe to sprinkle on any control.
    func glassHover(scale: CGFloat = 1.04, brightness: Double = 0.06) -> some View {
        modifier(GlassHoverModifier(scale: scale, brightness: brightness))
    }
}

// MARK: - Liquid Glass background

private struct LiquidGlassFillModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color
    var tintOpacity: Double
    var interactive: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let glass: Glass = interactive
                ? .regular.tint(tint.opacity(tintOpacity)).interactive()
                : .regular.tint(tint.opacity(tintOpacity))
            content
                .background(shape.fill(tint.opacity(tintOpacity * 0.5)))
                .glassEffect(glass, in: shape)
        } else {
            content
                .background(shape.fill(tint.opacity(max(tintOpacity, 0.14))))
        }
    }
}

extension View {
    /// Liquid Glass background tinted with `tint`. macOS 26+ paints a
    /// real Liquid Glass material (interactive → Apple's built-in
    /// hover/press feedback); older systems get a translucent tinted
    /// fill in the same shape.
    func liquidGlass<S: InsettableShape>(
        in shape: S,
        tint: Color = .white,
        tintOpacity: Double = 0.18,
        interactive: Bool = true
    ) -> some View {
        modifier(LiquidGlassFillModifier(shape: shape,
                                         tint: tint,
                                         tintOpacity: tintOpacity,
                                         interactive: interactive))
    }

    /// Convenience for the most common case — a Capsule-shaped Liquid
    /// Glass pill.
    func liquidGlassCapsule(tint: Color = .white,
                            tintOpacity: Double = 0.18,
                            interactive: Bool = true) -> some View {
        liquidGlass(in: Capsule(style: .continuous),
                    tint: tint,
                    tintOpacity: tintOpacity,
                    interactive: interactive)
    }

    /// Applies a Liquid Glass "selected" pill ONLY when `active` —
    /// otherwise the view is returned untouched. For toggle/segmented
    /// surfaces (sidebar selection, filter pills) where only the chosen
    /// option carries the glass tint.
    @ViewBuilder
    func liquidGlassSelected<S: InsettableShape>(
        _ active: Bool,
        in shape: S,
        tint: Color,
        tintOpacity: Double = 0.22
    ) -> some View {
        if active {
            liquidGlass(in: shape, tint: tint,
                        tintOpacity: tintOpacity, interactive: false)
        } else {
            self
        }
    }
}
