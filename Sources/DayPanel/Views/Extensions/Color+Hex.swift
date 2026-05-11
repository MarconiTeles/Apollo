import SwiftUI
import AppKit

extension Color {
    /// Cached factory for `Color(hex:)`. Building a SwiftUI `Color`
    /// from a hex string is cheap individually but the task list
    /// reads `Color(hex: task.statusDisplayHex)` multiple times per
    /// row per render — for the row's drop shadow, the status pill
    /// fill, the priority flag, and again inside the hover-DONE
    /// pill. With 30 rows visible during scroll that's ~120 hex
    /// scans per frame, all redundant. We cache by raw hex string
    /// in a thread-local Dictionary so the first read of any hex
    /// builds the Color once and every subsequent read is a hash
    /// lookup.
    ///
    /// Why thread-local: Swift Dictionary isn't thread-safe, but
    /// SwiftUI body evaluation runs on the main thread; gating the
    /// cache to that thread is sufficient and avoids the cost of
    /// a lock. Other threads (sync workers, etc.) just bypass the
    /// cache and call the underlying initialiser.
    init(hex: String) {
        if Thread.isMainThread, let cached = HexColorCache.cached(hex) {
            self = cached
            return
        }
        self = Self.parseHex(hex)
        if Thread.isMainThread {
            HexColorCache.store(hex, color: self)
        }
    }

    /// Bypass-the-cache initialiser — kept private to this file
    /// so all callers go through the cached path.
    fileprivate static func parseHex(_ hex: String) -> Color {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        return Color(
            red:   Double((rgb & 0xFF0000) >> 16) / 255,
            green: Double((rgb & 0x00FF00) >>  8) / 255,
            blue:  Double( rgb & 0x0000FF)         / 255
        )
    }
}

/// Main-thread-scoped cache of parsed hex → SwiftUI `Color`. See
/// `Color.init(hex:)` for the rationale.
private enum HexColorCache {
    private static var storage: [String: Color] = [:]

    static func cached(_ hex: String) -> Color? {
        storage[hex]
    }

    static func store(_ hex: String, color: Color) {
        storage[hex] = color
    }
}

extension Color {
    /// Returns a shadow-friendly variant of this hex base — brighter
    /// against dark backgrounds, denser against light ones — so the
    /// row's coloured halo always reads as energy radiating off the
    /// card instead of fading into (dark mode) or merging with
    /// (light mode) the surrounding window.
    ///
    /// HSB-space adjustment: dark mode bumps brightness ~+0.20 and
    /// keeps saturation high; light mode drops brightness ~-0.30
    /// and slightly deepens saturation. Result is then alpha-tuned
    /// for shadow use.
    ///
    /// Cached by `(hex, scheme)` because the Hue→HSB→back-to-Color
    /// dance allocates an NSColor and reads four CGFloats per call —
    /// cheap individually but multiplied by 30 visible rows ×
    /// every body re-eval, worth memoising.
    static func shadowTint(forBaseHex hex: String, scheme: ColorScheme) -> Color {
        let key = ShadowTintCache.Key(hex: hex, isDark: scheme == .dark)
        if Thread.isMainThread, let cached = ShadowTintCache.cached(key) {
            return cached
        }
        let result = computeShadowTint(hex: hex, scheme: scheme)
        if Thread.isMainThread { ShadowTintCache.store(key, color: result) }
        return result
    }

    /// Returns a fill-tint variant of this hex base, suitable for
    /// painting the row card's coloured wash. In dark mode the
    /// raw status hue at 8% opacity over a dark window reads as
    /// MURKY (desaturated dark tint), so we pre-lighten the
    /// colour before passing it through `.opacity(...)` — giving
    /// a clearer, more pastel wash. Light mode passes the colour
    /// through unchanged (the existing palette already works).
    /// Cached by `(hex, scheme)`.
    static func fillTint(forBaseHex hex: String, scheme: ColorScheme) -> Color {
        let key = FillTintCache.Key(hex: hex, isDark: scheme == .dark)
        if Thread.isMainThread, let cached = FillTintCache.cached(key) {
            return cached
        }
        let result = computeFillTint(hex: hex, scheme: scheme)
        if Thread.isMainThread { FillTintCache.store(key, color: result) }
        return result
    }

    private static func computeFillTint(hex: String, scheme: ColorScheme) -> Color {
        // Final saturation × 0.6 in both modes — knocks 40% off the
        // wash vividness so the row identity stays visible without
        // colours competing with the status pill / shadow halo.
        let base = NSColor(Color(hex: hex)).usingColorSpace(.sRGB) ?? .gray
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        switch scheme {
        case .dark:
            // Pre-boosted saturation (max(s, 0.85)) pumped to keep
            // dim hues from disappearing on dark bg, then knocked
            // back 40% per the latest call.
            let ns = min(1.0, max(s, 0.85)) * 0.6
            let nb: CGFloat = 1.0
            return Color(NSColor(hue: h, saturation: ns, brightness: nb, alpha: 1))
        default:
            // Light mode: original ×1.25 boost, then ×0.6 = ×0.75
            // net. Result reads clearly desaturated vs the raw
            // hex but still hue-identifiable.
            let ns = min(1.0, s * 1.25) * 0.6
            return Color(NSColor(hue: h, saturation: ns, brightness: b, alpha: 1))
        }
    }

    private static func computeShadowTint(hex: String, scheme: ColorScheme) -> Color {
        let base = NSColor(Color(hex: hex)).usingColorSpace(.sRGB) ?? .gray
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        switch scheme {
        case .dark:
            // Brighter + just-as-saturated → vivid pop on dark bg.
            let nb = min(1, b + 0.20)
            let ns = min(1, s + 0.05)
            return Color(NSColor(hue: h, saturation: ns, brightness: nb, alpha: 1))
        default:
            // Darker + slightly more saturated → denser ground on
            // light bg. Anchored to a 0.18 brightness floor so
            // already-dark hues (deep purple, navy) don't collapse
            // to near-black.
            let nb = max(0.18, b - 0.30)
            let ns = min(1, s + 0.10)
            return Color(NSColor(hue: h, saturation: ns, brightness: nb, alpha: 1))
        }
    }
}

private enum ShadowTintCache {
    struct Key: Hashable { let hex: String; let isDark: Bool }
    private static var storage: [Key: Color] = [:]
    static func cached(_ key: Key) -> Color? { storage[key] }
    static func store(_ key: Key, color: Color) { storage[key] = color }
}

private enum FillTintCache {
    struct Key: Hashable { let hex: String; let isDark: Bool }
    private static var storage: [Key: Color] = [:]
    static func cached(_ key: Key) -> Color? { storage[key] }
    static func store(_ key: Key, color: Color) { storage[key] = color }
}

extension Color {
    /// Pre-blended task-row card fill — collapses the previous
    /// `ZStack { 2× RoundedRectangle.fill }` into a single colour
    /// so each cell renders ONE fill layer instead of two. With
    /// 30 visible rows that's 30 fewer CALayers in the compositor
    /// per scroll frame, plus one fewer SwiftUI `.fill` evaluation
    /// per re-render.
    ///
    /// Composition rule:
    ///   • Dark mode: `windowBackgroundColor` + 4% white overlay
    ///   • Light mode: `controlBackgroundColor` + 13% statusTint
    ///
    /// System colours (`windowBackgroundColor`/`controlBackgroundColor`)
    /// are resolved under an explicit `NSAppearance` so the cache
    /// stays correct across light/dark switches without depending
    /// on the caller's current drawing appearance. Cached by
    /// `(hex, scheme)` because the per-row HSB math + sRGB
    /// component reads aren't free at 30 cells × every body
    /// re-eval.
    static func rowFill(forBaseHex hex: String, scheme: ColorScheme) -> Color {
        let key = RowFillCache.Key(hex: hex, isDark: scheme == .dark)
        if Thread.isMainThread, let cached = RowFillCache.cached(key) {
            return cached
        }
        let result = computeRowFill(hex: hex, scheme: scheme)
        if Thread.isMainThread { RowFillCache.store(key, color: result) }
        return result
    }

    private static func computeRowFill(hex: String, scheme: ColorScheme) -> Color {
        let baseColor: NSColor
        let overlayColor: NSColor
        let alpha: CGFloat
        // Final card alpha. Dark mode ships at 80% so the cell
        // material reads as a slightly translucent pane — the
        // window background bleeds through just enough to give
        // the list a layered feel without the cards losing
        // their visible boundary against the canvas. Light mode
        // stays fully opaque (1.0) to preserve the existing
        // high-contrast look on white surfaces.
        let outputAlpha: CGFloat
        switch scheme {
        case .dark:
            baseColor    = NSColor.windowBackgroundColor
            overlayColor = .white
            alpha        = 0.04
            outputAlpha  = 0.8
        default:
            baseColor    = NSColor.controlBackgroundColor
            // The light-mode wash uses the existing fillTint
            // (saturation-bumped status hue). fillTint is hex-only
            // math so it doesn't depend on the drawing appearance
            // being active.
            overlayColor = NSColor(Color.fillTint(forBaseHex: hex, scheme: .light))
            alpha        = 0.13
            outputAlpha  = 1.0
        }

        let appearance: NSAppearance? = scheme == .dark
            ? NSAppearance(named: .darkAqua)
            : NSAppearance(named: .aqua)

        var blended = NSColor.gray
        let resolve = {
            let base = baseColor.usingColorSpace(.sRGB) ?? .gray
            let over = overlayColor.usingColorSpace(.sRGB) ?? .gray
            blended = NSColor(
                red:   base.redComponent   * (1 - alpha) + over.redComponent   * alpha,
                green: base.greenComponent * (1 - alpha) + over.greenComponent * alpha,
                blue:  base.blueComponent  * (1 - alpha) + over.blueComponent  * alpha,
                alpha: outputAlpha
            )
        }
        if let appearance {
            appearance.performAsCurrentDrawingAppearance(resolve)
        } else {
            resolve()
        }
        return Color(blended)
    }
}

private enum RowFillCache {
    struct Key: Hashable { let hex: String; let isDark: Bool }
    private static var storage: [Key: Color] = [:]
    static func cached(_ key: Key) -> Color? { storage[key] }
    static func store(_ key: Key, color: Color) { storage[key] = color }
}

extension NSColor {
    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#4285F4" }
        let r = Int((rgb.redComponent   * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent  * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - Google Calendar palette snap
//
// macOS Calendar tends to surface Google-Calendar event colours in a
// lightened/desaturated form (and EventKit doesn't expose Google's
// `colorId`). To keep the timeline visually identical to Google, we
// snap any incoming hex to the nearest entry of Google's standard
// 11-colour event palette by Euclidean distance in RGB.

enum GoogleCalendarPalette {
    /// Tomato, Flamingo, Tangerine, Banana, Sage, Basil, Peacock,
    /// Graphite, Blueberry, Basil-dark, Tomato-dark.
    static let hexes: [String] = [
        "#D50000", "#E67C73", "#F4511E",
        "#F6BF26", "#33B679", "#0B8043",
        "#039BE5", "#616161", "#3F51B5",
        "#7986CB", "#8E24AA",
    ]

    /// Returns the palette hex visually closest to `hex`. Matches by HUE
    /// (and falls back to Graphite for near-grayscale inputs) rather than
    /// raw RGB distance, so a lightened/desaturated version of "Blueberry"
    /// snaps back to Blueberry instead of jumping to Lavender.
    static func snap(_ hex: String) -> String {
        guard let target = rgb(of: hex) else { return hexes[0] }
        if saturation(target) < 0.18 {
            return "#616161"   // Graphite for grayscale-ish inputs
        }
        let targetHue = hue(target)
        return hexes.min { a, b in
            hueDistance(hue(rgb(of: a)!), targetHue) <
            hueDistance(hue(rgb(of: b)!), targetHue)
        } ?? hexes[0]
    }

    private static func rgb(of hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        var v: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&v) else { return nil }
        return (Double((v & 0xFF0000) >> 16) / 255,
                Double((v & 0x00FF00) >>  8) / 255,
                Double( v & 0x0000FF)        / 255)
    }

    private static func hue(_ rgb: (r: Double, g: Double, b: Double)) -> Double {
        let maxC = max(rgb.r, rgb.g, rgb.b)
        let minC = min(rgb.r, rgb.g, rgb.b)
        let delta = maxC - minC
        guard delta > 0 else { return 0 }
        var h: Double
        if maxC == rgb.r {
            h = ((rgb.g - rgb.b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == rgb.g {
            h = (rgb.b - rgb.r) / delta + 2
        } else {
            h = (rgb.r - rgb.g) / delta + 4
        }
        h *= 60
        if h < 0 { h += 360 }
        return h
    }

    private static func saturation(_ rgb: (r: Double, g: Double, b: Double)) -> Double {
        let maxC = max(rgb.r, rgb.g, rgb.b)
        let minC = min(rgb.r, rgb.g, rgb.b)
        guard maxC > 0 else { return 0 }
        return (maxC - minC) / maxC
    }

    private static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let diff = abs(a - b)
        return min(diff, 360 - diff)
    }
}

extension Color {
    /// Builds a color from a hex string but first snaps it to the closest
    /// match in Google Calendar's original 11-colour palette.
    init(googleSnapHex hex: String) {
        self.init(hex: GoogleCalendarPalette.snap(hex))
    }
}
