import AppKit
import ObjectiveC

/// Apollo never draws keyboard focus rings. SwiftUI views opt out with
/// `.focusEffectDisabled()` at each root; AppKit views (tables, collection
/// views, text fields, buttons) draw their own ring whenever `focusRingType`
/// isn't `.none`, so the NSView getter is exchanged once at launch to always
/// answer `.none`.
enum FocusRingSuppressor {
    private static var installed = false

    static func install() {
        guard !installed,
              let original = class_getInstanceMethod(NSView.self, #selector(getter: NSView.focusRingType)),
              let replacement = class_getInstanceMethod(NSView.self, #selector(getter: NSView.apolloNoFocusRingType))
        else { return }
        method_exchangeImplementations(original, replacement)
        installed = true
    }
}

extension NSView {
    @objc fileprivate var apolloNoFocusRingType: NSFocusRingType { .none }
}
