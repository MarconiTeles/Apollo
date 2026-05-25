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

// Apollo "Editorial Calm" design language — the SwiftUI port of
// `editorial-tokens.jsx` from the navigable prototype
// (/Apollo UI Redesign). Voice: NYT meets Linear. Type IS the
// chrome; cinnabar (#C7321B) is the single accent; status is a
// dot + word, never a filled pill.
//
// This file is the FOUNDATION (redesign Stage 0). It defines
// tokens + the reusable primitives every redesigned screen
// composes from. It deliberately touches no existing view —
// later stages migrate screens onto it one at a time. Do not
// reintroduce the old Liquid Glass materials/capsules here.

// MARK: - Tokens

enum Editorial {

    // ── Surface (light / dark). Light is the original "Editorial
    //    Calm" cream-and-ink palette; dark is a neutral charcoal
    //    scale anchored on Claude's app canvas (#1F1F1E) so the two
    //    apps share the same dark tone. Surfaces step up in
    //    luminance for elevation; the warm-white ink + cinnabar
    //    accent keep the editorial character on top.
    static let paper    = Color(nsColor: .editorial(light: "#FAF7F0", dark: "#1F1F1E"))  // outer canvas (= Claude bg)
    static let page     = Color(nsColor: .editorial(light: "#FFFFFF", dark: "#2A2A29"))  // primary surface
    static let card     = Color(nsColor: .editorial(light: "#FCFAF5", dark: "#242423"))  // secondary surface
    static let ink      = Color(nsColor: .editorial(light: "#14130F", dark: "#F3EFE6"))  // body type

    /// Surface for the redesigned popup windows (detail / create /
    /// settings / filters / notifications / command palette).
    static let popup    = Color(nsColor: .editorial(light: "#FCFCFC", dark: "#262625"))

    // Translucent ink steps — alpha baked per mode so dark mode
    // reads off a warm-white ink instead of warm-black.
    static let inkSoft  = Color(nsColor: .editorial(light: "#14130F", dark: "#F3EFE6", lightAlpha: 0.62, darkAlpha: 0.64))
    static let inkMute  = Color(nsColor: .editorial(light: "#14130F", dark: "#F3EFE6", lightAlpha: 0.42, darkAlpha: 0.46))
    static let inkFaint = Color(nsColor: .editorial(light: "#14130F", dark: "#F3EFE6", lightAlpha: 0.22, darkAlpha: 0.28))
    static let rule     = Color(nsColor: .editorial(light: "#14130F", dark: "#F3EFE6", lightAlpha: 0.10, darkAlpha: 0.13))
    static let ruleSoft = Color(nsColor: .editorial(light: "#14130F", dark: "#F3EFE6", lightAlpha: 0.06, darkAlpha: 0.08))

    // ── Single accent — cinnabar (newsroom red), nudged brighter
    //    in dark so it keeps punching against the warm-black canvas.
    static let accent     = Color(nsColor: .editorial(light: "#C7321B", dark: "#E04A2E"))
    static let accentSoft = Color(nsColor: .editorial(light: "#C7321B", dark: "#E04A2E", lightAlpha: 0.10, darkAlpha: 0.18))

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

    // ── Type. macOS ships "New York" as the system serif via the
    // `.serif` design; SF Pro is the default sans; SF Mono via
    // `.monospaced`. Matching the prototype's serif/sans/mono mix.
    //
    // `typeScale` is a single global multiplier on every editorial
    // font size. Set to 0.85 → the whole app's type is 15% smaller
    // in one place (every screen funnels through serif/sans/mono,
    // and the AppKit twins `editorialSerif`/`editorialSerifItalic`
    // apply the same factor).
    static let typeScale: CGFloat = 0.85

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * typeScale, weight: weight, design: .serif)
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

// MARK: - Buttons

/// Paper button: white surface, hairline border, no fill;
/// inverts to solid ink when `active`.
struct PaperButtonStyle: ButtonStyle {
    var active: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Editorial.sans(12.5, .medium))
            .foregroundStyle(active ? Editorial.page : Editorial.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(active ? Editorial.ink : Editorial.page)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(active ? Editorial.ink : Editorial.rule,
                                  lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
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
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(Editorial.sans(13.5, .medium))
                .foregroundStyle(accent ? Editorial.accent : Editorial.ink)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.vertical, 4)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(hover ? Editorial.ink : Color.clear)
                        .frame(height: 1)
                        .offset(y: 1)
                }
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

/// `TBIconBtn` from the prototype: a square icon hit-target with
/// 6pt padding, a 6pt-radius background that washes to `E.rule`
/// on hover, and ink-colored glyph.
struct TBIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TBIcon(configuration: configuration)
    }
    private struct TBIcon: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .foregroundStyle(Editorial.ink)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hover ? Editorial.rule : Color.clear)
                )
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
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
