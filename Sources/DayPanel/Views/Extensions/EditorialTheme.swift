import SwiftUI
import AppKit

/// App-wide appearance choice, persisted in `AppState`. Drives
/// `NSApp.appearance`; the Editorial tokens are dynamic colours
/// that resolve light/dark off whatever this pins.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case light, dark, system

    var id: String { rawValue }

    /// `nil` = follow the system. Otherwise an explicit pin.
    var nsAppearance: NSAppearance? {
        switch self {
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }

    var label: String {
        switch self {
        case .light:  return "Claro"
        case .dark:   return "Escuro"
        case .system: return "Sistema"
        }
    }

    var symbol: String {
        switch self {
        case .light:  return "sun.max"
        case .dark:   return "moon.stars"
        case .system: return "circle.lefthalf.filled"
        }
    }
}

// Apollo — STUDIO GLASS (a filosofia de design do Galileo, portada).
// Substitui o "Editorial Calm". Tese: neutros verdadeiros; UM accent
// herdado do macOS p/ ação/marca; profundidade por MATERIAL e sombra (tiers
// em Materials.swift), não por bordas; SF Pro em tudo (serif morreu —
// o nome `serif` fica por compat de API, resolve pra SF Pro); status
// segue como dot + word, nunca pill preenchida.
//
// O enum continua `Editorial` por compat com as 43 views (1.520 refs).

// MARK: - Tokens

enum Editorial {

    /// New popup geometry. Callers pass their previous (pre-redesign) radius
    /// so the increase stays mathematically consistent across small menus,
    /// standard dialogs and full-window sheets. The scale was bumped a further
    /// +50% over the original +35% pass (1.35 → 2.025) for the rounder,
    /// softer popup language.
    static let popupRadiusScale: CGFloat = 2.025
    static func popupRadius(_ previous: CGFloat) -> CGFloat {
        previous * popupRadiusScale
    }

    /// Inbox rows intentionally read as capsules rather than editorial list
    /// rows. The 10pt baseline comes from the compact reference capsule.
    static let notificationCapsuleRadius: CGFloat = 13.5

    /// Neutral tint for transient/internal notification glass. The material
    /// must reinforce the active appearance rather than invert it: a dark veil
    /// in Dark Mode and a light veil in Light Mode. Semantic colour remains in
    /// the status dot, never in the whole capsule surface.
    static func notificationGlassTint(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .black : .white
    }

    static let notificationGlassTintOpacity = 0.50

    /// Canonical vertical elevation for native AppKit capsules. Core
    /// Animation layers hosted by Apollo's flipped list views use positive Y
    /// to project the shadow visually downward, matching SwiftUI's
    /// `.shadow(y:)` convention used everywhere else in the app.
    static let nativeCapsuleShadowRestY: CGFloat = 0.75
    static let nativeCapsuleShadowHoverY: CGFloat = 2
    static let nativeListShadowHoverY: CGFloat = 1

    // ── Surface (light / dark). Light mantém o creme original
    //    Light e dark são AMBOS neutros frios (o creme editorial
    //    morreu junto com o serif): light é uma escala cinza-clara
    //    neutra, dark é a escala do Studio Dark ancorada em #141415.
    static let paper    = Color(nsColor: .editorial(light: "#F5F5F6", dark: "#141415"))  // janela / raiz
    static let page     = Color(nsColor: .editorial(light: "#FFFFFF", dark: "#1B1B1C"))  // painéis
    static let card     = Color(nsColor: .editorial(light: "#FAFAFB", dark: "#1C1C1D"))  // barras/chips
    static let ink      = Color(nsColor: .editorial(light: "#141416", dark: "#E8E8EA"))  // body type (frio)

    /// Surface for the redesigned popup windows (detail / create /
    /// settings / filters / notifications / command palette).
    static let popup    = Color(nsColor: .editorial(light: "#FCFCFD", dark: "#1B1B1C"))

    /// Sub-áreas / sidebar (Studio Glass panelDeep).
    static let panelDeep = Color(nsColor: .editorial(light: "#EFEFF1", dark: "#171718"))
    /// Campos de busca / inputs.
    static let field     = Color(nsColor: .editorial(light: "#EDEDEF", dark: "#121213"))

    // Ink steps — no dark são CINZAS SÓLIDOS (Studio Glass), não
    // alphas de warm-white; no light seguem como alpha do ink
    // (agora neutro, sem o warm-black #14130F antigo).
    static let inkSoft  = Color(nsColor: .editorial(light: "#141416", dark: "#A0A0A6", lightAlpha: 0.70, darkAlpha: 1.0))
    static let inkMute  = Color(nsColor: .editorial(light: "#141416", dark: "#7A7A80", lightAlpha: 0.42, darkAlpha: 1.0))
    static let inkFaint = Color(nsColor: .editorial(light: "#141416", dark: "#56565B", lightAlpha: 0.22, darkAlpha: 1.0))
    static let rule     = Color(nsColor: .editorial(light: "#141416", dark: "#FFFFFF", lightAlpha: 0.10, darkAlpha: 0.07))
    static let ruleSoft = Color(nsColor: .editorial(light: "#141416", dark: "#FFFFFF", lightAlpha: 0.06, darkAlpha: 0.045))

    // ── Single accent — follows the user's macOS Accent color.
    // `controlAccentColor` is dynamic: changing the system preference
    // updates Apollo without maintaining an app-specific purple fork.
    static let accent     = Color(nsColor: .controlAccentColor)
    static let accentSoft = Color(nsColor: .controlAccentColor).opacity(0.12)
    /// Selected/hover glyph; hue remains identical to the system accent.
    static let accent2    = Color(nsColor: .controlAccentColor)
    /// Pressed/border variant.
    static let accentDim  = Color(nsColor: .controlAccentColor).opacity(0.72)
    /// Semantic deadline failure; unlike accent this never follows the
    /// user's customization because overdue always means alert red.
    static let overdue    = Color(nsColor: .systemRed)
    /// Texto/tokens sobre fills de accent.
    static let tokenOnAccent = Color(nsColor: .editorial(light: "#FFFFFF", dark: "#F0EAFF"))

    // Twins NSColor p/ superfícies AppKit (RichTextEditor etc.).
    static let inkNS:   NSColor = .editorial(light: "#141416", dark: "#E8E8EA")
    static let tokenNS: NSColor = .controlAccentColor

    /// Status colors — used ONLY as dots + caption text, never
    /// as a filled pill (that's the whole point of the redesign).
    /// Keyed by ClickUp's canonical status family. Light tones are
    /// the muted editorial palette; `Color(statusHex:)` lifts each
    /// hue to a brighter, more vibrant version in dark mode — the
    /// same transform applied to every other status colour in the
    /// app, so labels, dots, pills and washes stay consistent.
    static func statusColor(_ family: String) -> Color {
        switch family {
        case "todo":        return Color(statusHex: "#54577E")  // slate-indigo
        case "doing":       return Color(statusHex: "#B0612E")  // terracotta
        case "review":      return Color(statusHex: "#7A6597")  // dusty plum
        case "liberado":    return Color(statusHex: "#9A7B1F")  // ochre
        case "complete":    return Color(statusHex: "#3F6B4A")  // forest sage
        case "backlog":     return Color(statusHex: "#5E5786")  // violet-slate
        case "cancelado":   return Color(statusHex: "#B0402C")  // brick (accent kin)
        case "recorrentes": return Color(statusHex: "#7E6597")  // lavender
        default:            return Color(statusHex: "#54577E")
        }
    }

    // ── Type. Studio Glass: SF Pro em TUDO; SF Mono só pra dados
    // tabulares/atalhos. "serif" agora resolve pra SF Pro — a voz
    // editorial saiu da FONTE e foi pro comportamento (materiais,
    // glow). O nome fica pra não tocar 149 call sites.
    //
    // `typeScale` mantém o 0.85 do Apollo (o app inteiro foi
    // calibrado nele; o 0.90 do Galileo mudaria todo layout).
    // TODO: avaliar 0.90 depois que a migração estabilizar.
    static let typeScale: CGFloat = 0.85

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * typeScale, weight: weight)
    }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * typeScale, weight: weight)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * typeScale, weight: weight, design: .monospaced)
    }
}

// MARK: - Primitives

/// Tracking small-caps section folio: "TAREFAS / 26 ABERTAS".
struct Folio: View {
    let text: String
    var accent: Bool = false
    init(_ text: String, accent: Bool = false) {
        self.text = text; self.accent = accent
    }
    var body: some View {
        Text(text.uppercased())
            .font(Editorial.sans(10.5, .semibold))
            .tracking(1.4)
            .foregroundStyle(accent ? Editorial.accent : Editorial.inkMute)
    }
}

/// Italic editorial caption: "— Pedro Nasser, há 2 dias".
struct Caption: View {
    let text: String
    var size: CGFloat = 13
    init(_ text: String, size: CGFloat = 13) {
        self.text = text; self.size = size
    }
    var body: some View {
        Text(text)
            .font(Editorial.serif(size).italic())
            .foregroundStyle(Editorial.inkSoft)
    }
}

/// Status as dot + Capitalized word (NOT a filled pill).
struct StatusMark: View {
    /// ClickUp status family key (todo/doing/review/…).
    let family: String
    /// Human label ("Doing"). The prototype capitalizes the
    /// family; callers pass the already-localized label.
    let label: String
    var dim: Bool = false
    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Editorial.statusColor(family))
                .frame(width: 7, height: 7)
            Text(label)
                .font(Editorial.sans(11.5, .medium))
                .foregroundStyle(Editorial.inkSoft)
                .tracking(0.2)
        }
        .opacity(dim ? 0.55 : 1)
    }
}

/// Section folio header line: name + count + trailing actions,
/// underlined by a hairline rule. Trailing content via the
/// `trailing` builder.
struct FolioBar<Trailing: View>: View {
    let label: String
    var count: Int? = nil
    var accent: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    init(_ label: String,
         count: Int? = nil,
         accent: Bool = false,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.label = label; self.count = count
        self.accent = accent; self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Folio(label, accent: accent)
            if let count {
                Text("\(count)")
                    .font(Editorial.sans(11))
                    .foregroundStyle(Editorial.inkMute)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Editorial.rule).frame(height: 1)
        }
    }
}

/// Magazine "drop cap" opener for the description/body. SwiftUI
/// can't float text around an oversized glyph the way CSS
/// `float` does, so this is the faithful-enough approximation:
/// an outsized serif initial sitting on the first line, the
/// remaining text flowing beside/below it.
struct DropCap: View {
    let text: String
    var capSize: CGFloat = 56
    init(_ text: String, capSize: CGFloat = 56) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.capSize = capSize
    }
    var body: some View {
        let first = String(text.prefix(1))
        let rest  = String(text.dropFirst())
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(first)
                .font(Editorial.serif(capSize, .medium))
                .foregroundStyle(Editorial.ink)
                .tracking(-2)
            Text(rest)
                .font(Editorial.serif(17))
                .foregroundStyle(Editorial.ink)
                .lineSpacing(5)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Big tabular hero date — weekday small-caps + outsized serif
/// numeral + italic serif month.
struct HeroDate: View {
    let weekday: String
    let day: Int
    let month: String
    var accent: Bool = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(weekday.uppercased())
                .font(Editorial.sans(11, .semibold))
                .tracking(1)
                .foregroundStyle(accent ? Editorial.accent : Editorial.inkMute)
            Text("\(day)")
                .font(Editorial.serif(40))
                .foregroundStyle(Editorial.ink)
                .tracking(-1.6)
                .monospacedDigit()
            Text(month.lowercased())
                .font(Editorial.serif(14).italic())
                .foregroundStyle(Editorial.inkSoft)
        }
    }
}

/// The AI mark — a small cinnabar serif glyph (the prototype's ✦).
struct AIMark: View {
    var size: CGFloat = 14
    var body: some View {
        Text("✦")
            .font(Editorial.serif(size, .medium).italic())
            .foregroundStyle(Editorial.accent)
    }
}

// MARK: - Hover primitives (Studio Glass)

/// A INTERAÇÃO do "Exportar" como modificador reutilizável: bounce de
/// mola no hover. Pra botões construídos fora dos ButtonStyles
/// compartilhados (chips locais, menus).
struct HoverBounce: ViewModifier {
    var scale: CGFloat
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hover ? scale : 1.0)
            .scrollAwareOnHover { hover = $0 }
            .animation(.spring(response: 0.32, dampingFraction: 0.55), value: hover)
    }
}

/// Vidro SÓ no hover/seleção (botões de ícone): em repouso o glyph
/// fica limpo; hover acende o chip de vidro + bounce; ativo = vidro
/// fixo.
struct HoverGlass: ViewModifier {
    var active: Bool
    var scale: CGFloat
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .background {
                if hover || active {
                    Color.clear.glassControl(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .transition(.opacity)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.clear, lineWidth: 1))
            .scaleEffect(hover ? scale : 1.0)
            .scrollAwareOnHover { hover = $0 }
            .animation(.spring(response: 0.32, dampingFraction: 0.55), value: hover)
    }
}

extension View {
    func hoverBounce(_ scale: CGFloat = 1.02) -> some View { modifier(HoverBounce(scale: scale)) }
    func hoverGlass(active: Bool = false, scale: CGFloat = 1.04) -> some View {
        modifier(HoverGlass(active: active, scale: scale))
    }
}

// MARK: - Buttons

/// Studio Glass: chip de VIDRO + a INTERAÇÃO do Exportar — bounce de
/// mola no hover (response 0.32 / damping 0.55), dip no press.
/// Linguagem única em todo botão-chip do app.
struct PaperButtonStyle: ButtonStyle {
    var active: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration, active: active)
    }
    private struct Chip: View {
        let configuration: Configuration
        let active: Bool
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(Editorial.sans(12, .medium))
                .foregroundStyle(active ? Editorial.accent2 : Editorial.ink)
                .padding(.horizontal, 11).padding(.vertical, 4.5)
                .glassControl(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.clear, lineWidth: 1))
                // HITBOX = o chip INTEIRO (padding + vidro), não só os
                // glifos do label.
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.96 : (hover ? 1.02 : 1.0))
                .opacity(configuration.isPressed ? 0.85 : 1)
                .scrollAwareOnHover { hover = $0 }
                .animation(.spring(response: 0.32, dampingFraction: 0.55), value: hover)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }
}

/// CTA em Liquid Glass com tint accent + bounce do Exportar (só quando
/// habilitado). O botão de ação primária do Studio Glass.
struct AccentButtonStyle: ButtonStyle {
    var enabled: Bool = true
    var cornerRadius: CGFloat = 5
    func makeBody(configuration: Configuration) -> some View {
        CTA(configuration: configuration, enabled: enabled, cornerRadius: cornerRadius)
    }
    private struct CTA: View {
        let configuration: Configuration
        let enabled: Bool
        let cornerRadius: CGFloat
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(Editorial.sans(12, .semibold))
                .foregroundStyle(enabled ? Color.white : Editorial.inkMute)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .glassControl(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                              tint: enabled ? Editorial.accent : nil)
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.96 : (hover && enabled ? 1.02 : 1.0))
                .opacity(configuration.isPressed ? 0.85 : 1)
                .scrollAwareOnHover { hover = $0 }
                .animation(.spring(response: 0.32, dampingFraction: 0.55), value: hover)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }
}

/// Text-only, link-like button — underlined, rule-colored
/// underline (cinnabar when `accent`).
struct TextLinkButtonStyle: ButtonStyle {
    var accent: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Editorial.sans(12, .medium))
            .foregroundStyle(accent ? Editorial.accent : Editorial.ink)
            .underline(true, color: accent ? Editorial.accentSoft : Editorial.rule)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - Toolbar primitives (prototype PToolbar)

/// `TBBtn` from the prototype: a transparent, type-led toolbar
/// button — SF Pro 13.5 medium ink (cinnabar when `accent`),
/// `4px 0` padding, and a 1px ink underline that fades in on
/// hover (`marginBottom: -1` → the rule sits flush at the band's
/// baseline). No fill, no capsule.
struct TBButtonStyle: ButtonStyle {
    var accent: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        TBLabel(configuration: configuration, accent: accent)
    }
    private struct TBLabel: View {
        let configuration: Configuration
        let accent: Bool
        var body: some View {
            configuration.label
                .font(Editorial.sans(13.5, .medium))
                .foregroundStyle(accent ? Editorial.accent : Editorial.ink)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.vertical, 4)
                .padding(.horizontal, 7)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
                // Studio Glass: chip de vidro no hover no lugar do
                // underline de tipo-jornal.
                .hoverGlass()
                .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
                .animation(.spring(response: 0.22, dampingFraction: 0.7),
                           value: configuration.isPressed)
        }
    }
}

/// Botão de ícone quadrado — Studio Glass: glyph limpo em repouso,
/// chip de vidro acende no hover (hoverGlass), dip no press.
struct TBIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TBIcon(configuration: configuration)
    }
    private struct TBIcon: View {
        let configuration: Configuration
        var body: some View {
            configuration.label
                .foregroundStyle(Editorial.ink)
                .padding(6)
                .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
                .animation(.spring(response: 0.22, dampingFraction: 0.7),
                           value: configuration.isPressed)
                .hoverGlass()
        }
    }
}

/// `kbdTB` from the prototype: the ⌘K hint chip — SF Pro 10.5
/// medium, `1px 5px` padding, 3pt radius, `E.rule` fill,
/// inkSoft text, 4pt leading gap from the preceding label.
struct KbdTB: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Editorial.sans(10.5, .medium))
            .foregroundStyle(Editorial.inkSoft)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(Editorial.rule))
            .padding(.leading, 4)
    }
}

extension View {
    /// Masks a HORIZONTAL rule so its left/right ends dissolve softly
    /// (clear → opaque → clear) instead of terminating in a hard tip.
    /// Same edge fade used by the task/event row dividers and hover glow.
    func edgeFadedHorizontal() -> some View {
        mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black, location: 0.06),
                    .init(color: .black, location: 0.94),
                    .init(color: .clear, location: 1.0),
                ],
                startPoint: .leading, endPoint: .trailing)
        )
    }

    /// Masks a VERTICAL rule so its top/bottom ends dissolve softly.
    func edgeFadedVertical() -> some View {
        mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black, location: 0.06),
                    .init(color: .black, location: 0.94),
                    .init(color: .clear, location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom)
        )
    }
}

/// The prototype's TBIconBtn count badge — cinnabar fill, white
/// (page) numerals, SF Pro 9.5 bold, pinned to the glyph's
/// top-trailing corner.
struct TBBadge: View {
    let count: Int
    var body: some View {
        Text("\(min(count, 99))")
            .font(Editorial.sans(9.5, .bold))
            .foregroundStyle(Editorial.page)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 14)
            .background(Capsule().fill(Editorial.accent))
            .offset(x: 7, y: -6)
    }
}
