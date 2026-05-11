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

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v: NSVisualEffectView = stripTint ? TintlessVisualEffectView() : NSVisualEffectView()
        v.material         = material
        v.blendingMode     = blendingMode
        v.state            = state
        v.isEmphasized     = false
        v.autoresizingMask = [.width, .height]
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material     = material
        v.blendingMode = blendingMode
        v.state        = state
        if let tintless = v as? TintlessVisualEffectView {
            tintless.clearTintLayers()
        }
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
final class TintlessVisualEffectView: NSVisualEffectView {
    override func layout() {
        super.layout()
        clearTintLayers()
    }

    func clearTintLayers() {
        guard let root = layer else { return }
        clearTintLayers(in: root)
    }

    private func clearTintLayers(in node: CALayer) {
        for sub in node.sublayers ?? [] {
            let className = NSStringFromClass(type(of: sub))
            if className.contains("Backdrop") {
                // The backdrop layer's tint is usually
                // baked into its own `filters` chain
                // (Gaussian blur + colour-matrix /
                // saturation filters that produce the
                // material's tint). Strip everything from
                // the chain except the blur — that keeps
                // the visible Gaussian softening but
                // removes any colour shift.
                if let filters = sub.filters as? [CIFilter] {
                    let blurOnly = filters.filter { $0.name == "CIGaussianBlur" }
                    if !blurOnly.isEmpty {
                        sub.filters = blurOnly
                    }
                }
            } else {
                // Tint/vibrancy overlay layer — wipe its
                // colour and any composite/background
                // filters that contribute to the tint.
                sub.backgroundColor   = NSColor.clear.cgColor
                sub.compositingFilter = nil
                sub.backgroundFilters = []
            }
            clearTintLayers(in: sub)
        }
    }
}
