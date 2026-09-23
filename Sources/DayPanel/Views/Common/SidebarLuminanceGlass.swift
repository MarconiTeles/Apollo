import AppKit
import CoreImage
import SwiftUI

/// Adjusts the rendered native glass RGB while leaving alpha and its backdrop
/// blur untouched. Foreground sidebar content lives outside this view.
@available(macOS 27.0, *)
struct SidebarLuminanceGlass: NSViewRepresentable {
    let cornerRadius: CGFloat
    let gain: CGFloat

    func makeNSView(context: Context) -> MaterialHost {
        MaterialHost(cornerRadius: cornerRadius, gain: gain)
    }

    func updateNSView(_ view: MaterialHost, context: Context) {
        view.update(cornerRadius: cornerRadius, gain: gain)
    }

    final class MaterialHost: NSView {
        private let glass = NSGlassEffectView()
        private var currentGain: CGFloat?

        init(cornerRadius: CGFloat, gain: CGFloat) {
            super.init(frame: .zero)
            wantsLayer = true
            glass.style = .regular
            glass.autoresizingMask = [.width, .height]
            glass.frame = bounds
            addSubview(glass)
            update(cornerRadius: cornerRadius, gain: gain)
        }

        required init?(coder: NSCoder) { nil }

        // This is a decorative background, never an input surface.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(cornerRadius: CGFloat, gain: CGFloat) {
            if glass.cornerRadius != cornerRadius { glass.cornerRadius = cornerRadius }
            guard currentGain != gain,
                  let matrix = CIFilter(name: "CIColorMatrix") else { return }
            matrix.setValue(CIVector(x: gain, y: 0, z: 0, w: 0), forKey: "inputRVector")
            matrix.setValue(CIVector(x: 0, y: gain, z: 0, w: 0), forKey: "inputGVector")
            matrix.setValue(CIVector(x: 0, y: 0, z: gain, w: 0), forKey: "inputBVector")
            matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            layer?.filters = [matrix]
            currentGain = gain
        }
    }
}
