import SwiftUI

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

    // ── Surface
    static let paper    = Color(hex: "#FAF7F0")   // warm cream — outer canvas
    static let page     = Color(hex: "#FFFFFF")   // pure white — surfaces
    static let card     = Color(hex: "#FCFAF5")   // off-white — secondary surfaces
    static let ink      = Color(hex: "#14130F")   // warm black

    /// Surface for the redesigned popup windows (detail / create /
    /// settings / filters / notifications / command palette).
    /// A near-neutral soft off-white — the warm yellow cast of
    /// `paper` pulled out so floating windows read calmer and
    /// don't fight the content inside them.
    static let popup    = Color(hex: "#FCFCFC")

    static let inkSoft  = Color(hex: "#14130F").opacity(0.62)
    static let inkMute  = Color(hex: "#14130F").opacity(0.42)
    static let inkFaint = Color(hex: "#14130F").opacity(0.22)
    static let rule     = Color(hex: "#14130F").opacity(0.10)
    static let ruleSoft = Color(hex: "#14130F").opacity(0.06)

    // ── Single accent — cinnabar (newsroom red)
    static let accent     = Color(hex: "#C7321B")
    static let accentSoft = Color(hex: "#C7321B").opacity(0.10)

    /// Status colors — used ONLY as dots + caption text, never
    /// as a filled pill (that's the whole point of the redesign).
    /// Keyed by ClickUp's canonical status family.
    /// Muted, denser editorial palette — desaturated warm tones
    /// that sit coherently with the cream paper, warm ink and the
    /// single cinnabar accent (no vivid web hues).
    static func statusColor(_ family: String) -> Color {
        switch family {
        case "todo":        return Color(hex: "#54577E")  // muted slate-indigo
        case "doing":       return Color(hex: "#B0612E")  // muted terracotta
        case "review":      return Color(hex: "#7A6597")  // muted dusty plum
        case "liberado":    return Color(hex: "#9A7B1F")  // deep muted ochre
        case "complete":    return Color(hex: "#3F6B4A")  // muted forest sage
        case "backlog":     return Color(hex: "#5E5786")  // muted violet-slate
        case "cancelado":   return Color(hex: "#B0402C")  // muted brick (accent kin)
        case "recorrentes": return Color(hex: "#7E6597")  // muted lavender
        default:            return Color(hex: "#54577E")
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
