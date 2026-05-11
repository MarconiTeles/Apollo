import SwiftUI
import AppKit

/// Drop-in `.background(...)` for SwiftUI's `TextEditor` on macOS.
///
/// Applies two cross-cutting tweaks by introspecting the underlying
/// `NSTextView` (which AppKit hides inside the SwiftUI primitive):
///
///   1. **Inset reset** — zeros `textContainerInset.width` and the
///      text container's `lineFragmentPadding`. By default macOS
///      adds ~10pt of inset which pushes the first character of
///      every line to the right of where the rest of the popup's
///      content sits (popups use `padding(.horizontal, 12)`),
///      visually clipping the first letter of each line under the
///      padding column.
///
///   2. **Link detection** — turns on automatic link + data
///      detection so URLs in the existing text (and anything the
///      user types) become clickable. The link styling matches
///      the system: blue + underlined + a pointer cursor on hover.
///      The user opens links with **Cmd+Click** (the macOS default
///      for editable text views) or via right-click → Open URL.
///      `checkTextInDocument(nil)` runs each `updateNSView` so
///      newly-loaded content (e.g. a task description fetched
///      from ClickUp) gets re-scanned and the URLs that already
///      live inside it become clickable, not only freshly-typed
///      ones.
///
/// Usage:
///
///     TextEditor(text: $body)
///         .scrollContentBackground(.hidden)
///         .background(TextEditorEnhancements())
struct TextEditorEnhancements: NSViewRepresentable {
    /// Top/bottom inset applied to the underlying NSTextView's
    /// textContainer. Defaults to 8pt — a comfortable breathing
    /// room for multi-line description editors. Pass a smaller
    /// value (e.g. 2pt) for short single-line comment inputs
    /// where the default insets would push the typed text out
    /// of the visible 22pt slot, biasing it toward the top edge.
    var verticalInset: CGFloat = 8

    func makeNSView(context: Context) -> NSView {
        let probe = NSView()
        let inset = verticalInset
        DispatchQueue.main.async { Self.apply(from: probe, verticalInset: inset) }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-apply on every SwiftUI invalidation. The textStorage
        // can be replaced when the binding is set externally
        // (e.g. when a task description is loaded asynchronously),
        // which would otherwise wipe the link attributes added by
        // the previous `checkTextInDocument` pass.
        let inset = verticalInset
        DispatchQueue.main.async { Self.apply(from: nsView, verticalInset: inset) }
    }

    private static func apply(from probe: NSView, verticalInset: CGFloat) {
        // First try to find a textView as a sibling/descendant of
        // the probe's parent. If that fails, walk up to the window
        // and search the entire content view (helps when SwiftUI
        // attaches the `.background` probe in an unexpected place).
        var textView: NSTextView?
        if let host = probe.superview {
            textView = findTextView(in: host)
        }
        if textView == nil, let window = probe.window {
            textView = findTextView(in: window.contentView ?? NSView())
        }
        guard let textView else { return }

        // 0. Allow rich-attribute rendering. SwiftUI's TextEditor
        // on macOS leaves `isRichText` enabled, but be explicit —
        // without it `.link` (and its blue/underlined paint via
        // `linkTextAttributes`) is silently ignored.
        textView.isRichText = true
        textView.usesFontPanel = false
        textView.allowsImageEditing = false

        // 1. Inset trim. Restore a sensible left/top breathing
        // room so the first line and first column don't get
        // clipped against the surrounding `NSScrollView`'s edge.
        // The defaults (5/5) were a tiny bit too far right but
        // visually safe; we keep 5pt on the left and bump the top
        // to 8pt so even a line whose first character carries a
        // link underline (which inflates line metrics) stays
        // inside the visible area.
        textView.textContainerInset = NSSize(width: 5, height: verticalInset)
        textView.textContainer?.lineFragmentPadding = 0

        // Lock horizontal layout so a long unbreakable URL can't
        // make the textContainer expand past the textView width
        // and force a horizontal scroll position that hides the
        // start of every line. NSTextView wraps to the view's
        // width when these are set.
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        if let scroll = textView.enclosingScrollView {
            scroll.hasHorizontalScroller = false
            scroll.horizontalScrollElasticity = .none
        }

        // 2. Link styling (hover + click). The underline is dropped
        // here because NSLayoutManager bakes the underline into the
        // line's metric, which on the very first line of the
        // textStorage can push the line origin above the textView's
        // bounds and visually clip the top of the glyphs. Just the
        // colour change is enough to mark links; the cursor changes
        // to a pointing hand on hover.
        textView.linkTextAttributes = [
            .foregroundColor:  NSColor.linkColor,
            .cursor:           NSCursor.pointingHand,
        ]
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticDataDetectionEnabled = true

        // 3. Apply `.link` attributes directly to the textStorage
        // for every URL detected by NSDataDetector. SwiftUI calls
        // `updateNSView` (which routes here) on every binding
        // change, so links get re-marked after each keystroke and
        // after asynchronous content arrives from the API.
        applyLinks(to: textView)
    }

    private static let linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    private static func applyLinks(to textView: NSTextView) {
        guard let storage = textView.textStorage,
              let detector = linkDetector else { return }
        let text = storage.string
        guard !text.isEmpty else { return }

        let fullRange = NSRange(location: 0, length: storage.length)
        // Quick exit when every URL in the current text already
        // carries a `.link` attribute pointing at the same URL —
        // avoids dirtying the storage on every keystroke when no
        // new URL appeared.
        if linksAlreadyApplied(in: storage, detector: detector,
                               text: text, fullRange: fullRange) {
            return
        }

        storage.beginEditing()
        // Strip any stale link attributes (e.g. a URL the user just
        // edited and is no longer a valid match).
        storage.removeAttribute(.link, range: fullRange)
        // Re-attach `.link` for every URL the detector finds. The
        // visual styling (blue + underline + pointer cursor) comes
        // from `linkTextAttributes`, which NSTextView paints on
        // top of any range that carries a `.link` attribute.
        for match in detector.matches(in: text, range: fullRange) {
            guard let url = match.url else { continue }
            storage.addAttribute(.link, value: url, range: match.range)
        }
        storage.endEditing()
    }

    /// Compares the current set of detected URL ranges against the
    /// `.link` attributes already in the storage. Returns `true`
    /// when they match exactly, so callers can skip a redundant
    /// edit transaction.
    private static func linksAlreadyApplied(in storage: NSTextStorage,
                                            detector: NSDataDetector,
                                            text: String,
                                            fullRange: NSRange) -> Bool {
        let matches = detector.matches(in: text, range: fullRange)
        // Cheapest path: zero URLs and zero existing `.link`
        // attributes ⇒ already in sync.
        if matches.isEmpty {
            var hasLink = false
            storage.enumerateAttribute(.link, in: fullRange,
                                       options: []) { value, _, stop in
                if value != nil { hasLink = true; stop.pointee = true }
            }
            return !hasLink
        }
        // Build a normalised set of (range, urlString) for both
        // detected matches and currently-attributed ranges, then
        // compare.
        var detected: Set<String> = []
        for m in matches {
            guard let url = m.url else { continue }
            detected.insert("\(m.range.location):\(m.range.length):\(url.absoluteString)")
        }
        var current: Set<String> = []
        storage.enumerateAttribute(.link, in: fullRange,
                                   options: []) { value, range, _ in
            if let url = value as? URL {
                current.insert("\(range.location):\(range.length):\(url.absoluteString)")
            } else if let str = value as? String, let url = URL(string: str) {
                current.insert("\(range.location):\(range.length):\(url.absoluteString)")
            }
        }
        return detected == current
    }

    private static func findTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView { return tv }
        for child in view.subviews {
            if let tv = findTextView(in: child) { return tv }
        }
        return nil
    }
}

// MARK: - Read-only text → AttributedString with clickable URLs

extension String {
    /// SwiftUI `Text` doesn't auto-link plain URLs. Convert any raw
    /// http(s) URL inside the string into a real `link` attribute on
    /// an `AttributedString`, styled to match SwiftUI's tinted-link
    /// appearance — `Text(text.linkified)` then renders clickable
    /// blue+underlined URLs and opens them via the default browser.
    ///
    /// Falls back to a non-attributed copy if the data detector
    /// can't be constructed (it can throw on locale-specific edge
    /// cases). Idempotent — calling on already-linkified text
    /// returns the same logical content.
    var linkified: AttributedString {
        var attr = AttributedString(self)
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return attr }

        let nsRange = NSRange(self.startIndex..., in: self)
        for match in detector.matches(in: self, range: nsRange) {
            guard let url = match.url,
                  let range = Range<AttributedString.Index>(match.range, in: attr)
            else { continue }
            attr[range].link            = url
            attr[range].foregroundColor = .blue
            attr[range].underlineStyle  = .single
        }
        return attr
    }
}
