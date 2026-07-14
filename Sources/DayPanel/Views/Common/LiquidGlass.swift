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
            // During a live trackpad/mouse scroll the pointer crosses several
            // rows per frame. Suppress those enter/exit animations so Inbox
            // and notification feeds do not continuously rebuild shadows.
            .scrollAwareOnHover { hovering = $0 }
    }
}

extension View {
    /// Subtle hover lift for interactive pills/buttons — scales up a
    /// touch and brightens on cursor-over. Cheap, self-contained
    /// `@State`, safe to sprinkle on any control.
    ///
    /// LEGADO (pré-Studio Glass): código novo deve preferir
    /// `.hoverGlass()` / `.hoverBounce()` (EditorialTheme.swift) —
    /// chip de vidro + mola, gateados pelo ScrollGate.
    func glassHover(scale: CGFloat = 1.04, brightness: Double = 0.06) -> some View {
        modifier(GlassHoverModifier(scale: scale, brightness: brightness))
    }
}

// MARK: - Floating panel glass

/// Canonical material for Apollo's floating panes. Both the sidebar and
/// prominent dashboard panels use this recipe so they react identically to
/// Liquid Glass availability and Reduce Transparency.
private struct FloatingPanelGlassSurface: ViewModifier {
    let shape: RoundedRectangle

    @ViewBuilder
    private func material(content: Content) -> some View {
        if Materials.tier == .solid {
            content.background(shape.fill(Editorial.panelDeep))
        } else if #available(macOS 26.0, *), Materials.tier == .liquidGlass {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }

    func body(content: Content) -> some View {
        material(content: content)
            .clipShape(shape)
            .overlay {
                if Materials.tier == .solid {
                    shape.strokeBorder(Editorial.rule, lineWidth: 1)
                        .allowsHitTesting(false)
                } else {
                    shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }
}

extension View {
    /// Applies the exact floating-pane material used by Apollo's sidebar.
    func floatingPanelGlass(in shape: RoundedRectangle) -> some View {
        modifier(FloatingPanelGlassSurface(shape: shape))
    }
}

// MARK: - Popup glass

/// Canonical chrome for dialog-sized and window-sized popup surfaces.
/// Unlike the legacy Editorial popup it never paints an opaque card beneath
/// native glass, so refraction and materialization remain visible.
private struct PopupGlassSurface: ViewModifier {
    let shape: RoundedRectangle

    @ViewBuilder
    private func material(content: Content) -> some View {
        if Materials.tier == .solid {
            content.background(shape.fill(Editorial.popup))
        } else if #available(macOS 26.0, *), Materials.tier == .liquidGlass {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }

    func body(content: Content) -> some View {
        material(content: content)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    Materials.tier == .solid
                        ? Editorial.rule
                        : Color.white.opacity(0.14),
                    lineWidth: Materials.tier == .solid ? 1 : 0.6
                )
                .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.20), radius: 36, y: 18)
            .shadow(color: .black.opacity(0.07), radius: 12, y: 4)
    }
}

extension View {
    /// One-layer popup surface that uses real Liquid Glass on macOS 26 and
    /// tier-aware native fallbacks elsewhere.
    func popupGlass(in shape: RoundedRectangle) -> some View {
        modifier(PopupGlassSurface(shape: shape))
    }

    /// Opaque detail/body surface. Use with a separate glass header when
    /// scrolling content should travel behind that single material layer.
    func solidPopupSurface<S: InsettableShape>(in shape: S) -> some View {
        self
            .background(shape.fill(Editorial.page))
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Editorial.rule, lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.20), radius: 18, y: 9)
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }
}

// MARK: - Capsule hover motion

private struct CapsuleHoverLiftModifier: ViewModifier {
    // `tint` remains part of the shared API because callers use it for their
    // glass fill. The elevation itself is deliberately neutral: semantic
    // coloured shadows are exclusive to Board cards.
    let tint: Color
    var scaleX: CGFloat
    var scaleY: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: hovering ? scaleX : 1,
                         y: hovering ? scaleY : 1)
            .offset(y: hovering ? -1 : 0)
            .shadow(color: .black.opacity(hovering ? 0.14 : 0.035),
                    radius: hovering ? 4 : 1.5,
                    y: hovering ? 2 : 0.75)
            // A hovered capsule must paint above neighbouring rows. Without
            // this, the next row covers the lower half of the blur and makes
            // a perfectly valid shadow look sharply clipped.
            .zIndex(hovering ? 10 : 0)
            .animation(.spring(response: 0.30, dampingFraction: 0.73),
                       value: hovering)
            .scrollAwareOnHover { hovering = $0 }
    }
}

extension View {
    /// Reference hover used by list/inbox capsules: a restrained elastic
    /// expansion with no layout reflow and a compact neutral elevation.
    /// Coloured elevation is reserved for the Board surface.
    func capsuleHoverLift(tint: Color,
                          scaleX: CGFloat = 1.008,
                          scaleY: CGFloat = 1.025) -> some View {
        modifier(CapsuleHoverLiftModifier(tint: tint,
                                          scaleX: scaleX,
                                          scaleY: scaleY))
    }
}

// MARK: - Liquid Glass background

private struct LiquidGlassFillModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color
    var tintOpacity: Double
    var interactive: Bool
    var lightweight: Bool

    // Tier-aware (Studio Glass, Materials.tier):
    //   C solid    — fill sólido + hairline (Intel / Reduce
    //                Transparency; antes esses users recebiam tint
    //                translúcido ilegível)
    //   A liquid   — glassEffect real (Apple Silicon + macOS 26)
    //   B vibrancy — ultraThinMaterial + tint + fio de luz
    func body(content: Content) -> some View {
        if Materials.tier == .solid {
            content
                .background(shape.fill(tint.opacity(max(tintOpacity, 0.10))))
                .background(shape.fill(Editorial.card))
                .overlay(shape.strokeBorder(Editorial.rule, lineWidth: 1))
        } else if #available(macOS 26.0, *), Materials.tier == .liquidGlass {
            let base: Glass = lightweight ? .clear : .regular
            let glass: Glass = interactive
                ? base.tint(tint.opacity(tintOpacity)).interactive()
                : base.tint(tint.opacity(tintOpacity))
            // Do not pre-paint a translucent color underneath native glass.
            // That extra layer becomes the material's sampled backdrop and
            // visually flattens refraction into a frosted/opaque fill.
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.fill(tint.opacity(tintOpacity * 0.6)))
                .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
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
        interactive: Bool = true,
        lightweight: Bool = false
    ) -> some View {
        modifier(LiquidGlassFillModifier(shape: shape,
                                         tint: tint,
                                         tintOpacity: tintOpacity,
                                         interactive: interactive,
                                         lightweight: lightweight))
    }

    /// Convenience for the most common case — a Capsule-shaped Liquid
    /// Glass pill.
    func liquidGlassCapsule(tint: Color = .white,
                            tintOpacity: Double = 0.18,
                            interactive: Bool = true,
                            lightweight: Bool = false) -> some View {
        liquidGlass(in: Capsule(style: .continuous),
                    tint: tint,
                    tintOpacity: tintOpacity,
                    interactive: interactive,
                    lightweight: lightweight)
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
