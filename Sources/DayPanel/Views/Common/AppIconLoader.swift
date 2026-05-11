import AppKit
import SwiftUI

/// Resolves Apollo's app icon at the highest available
/// resolution, regardless of where SwiftUI displays it.
///
/// `NSWorkspace.shared.icon(forFile:)` returns whatever
/// representation the Finder icon cache happens to have
/// served up — often a small (32–64pt) pixmap that SwiftUI
/// then has to upscale, producing the blurry "low-res Apollo
/// logo" we saw on the welcome and onboarding screens.
///
/// The fix is to load the .icns file directly: NSImage parses
/// every embedded rep (16, 32, 64, 128, 256, 512, 1024) and
/// SwiftUI can then pick the closest one to the requested
/// display size + Retina scale factor at draw time. We also
/// stamp the resulting NSImage's `size` to a large (256pt)
/// canonical so SwiftUI's automatic rep selection treats it
/// as a high-DPI source.
enum AppIconLoader {

    /// Cached so repeated reads (welcome anim, onboarding,
    /// any future "show the app icon" UI) don't keep reading
    /// the .icns file off disk.
    private static let cached: NSImage = {
        // 1. Best path: load the bundle's icns by reference.
        if let url = Bundle.main.urlForImageResource("AppIcon"),
           let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 256, height: 256)
            return img
        }
        // 2. Bundled-asset fallback (NSImage(named:) checks
        //    asset catalogs and direct resources).
        if let img = NSImage(named: "AppIcon") {
            img.size = NSSize(width: 256, height: 256)
            return img
        }
        // 3. Last resort: ask the workspace. May be small.
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }()

    /// The app icon as a SwiftUI `Image`, ready for
    /// `.resizable()` + `.frame(...)`.
    static var image: Image {
        Image(nsImage: cached)
    }
}
