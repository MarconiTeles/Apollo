import SwiftUI
import AppKit

/// Multi-line rich-text editor that wraps `NSTextView` directly. Use
/// this in place of SwiftUI's `TextEditor` whenever you need:
///
///   • Reliable text alignment (no off-by-N clipping at the top or
///     leading edge — `TextEditor` on macOS is a black box that
///     ignores `padding(.horizontal:)` for its inner content insets
///     and routinely clips the first letter / first line).
///   • Clickable URLs *baked into the textStorage* via `NSDataDetector`
///     and routed to the user's default browser. Survives binding
///     updates because we re-apply the `.link` attribute on every
///     text change instead of relying on SwiftUI's text checking.
///   • A `intrinsicContentSize`-driven height so the popup version
///     can grow with the content while the row-inline version
///     scrolls internally up to a cap.
///   • Custom placeholder rendered as a sibling overlay.
///
/// The view ships in two modes:
///
///   - `scrollsInternally: true`  — inline use inside a row. The
///     editor scrolls itself between `minHeight` and `maxHeight`.
///   - `scrollsInternally: false` — popup use. The editor reports
///     an `intrinsicContentSize` matching its content; an outer
///     SwiftUI `ScrollView` handles overflow, giving a single
///     unified scrollbar instead of nested ones.
struct RichTextEditor: NSViewRepresentable {
    @Binding var text: String

    /// Floor / ceiling for the editor's height. Used in both modes:
    /// scrollsInternally enforces them via `frame(minHeight:maxHeight:)`,
    /// non-scrolling clamps the intrinsic size against them.
    var minHeight: CGFloat = 50
    var maxHeight: CGFloat = 400
    var scrollsInternally: Bool = true
    var fontSize: CGFloat = 12

    /// Bound focus state — typing into the editor flips this to
    /// true via the responder chain; clicking outside (or losing
    /// first-responder otherwise) flips it back.
    @Binding var isFocused: Bool

    /// Fired when the editor loses focus AND the text differs from
    /// the last commit. Used by `TaskDetailView` to dispatch the
    /// `updateTaskDescription` API call only on commit, not every
    /// keystroke.
    var onCommit: () -> Void = {}

    // MARK: - NSViewRepresentable

    func makeNSView(context: Context) -> IntrinsicTextScrollView {
        let scrollView = IntrinsicTextScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = scrollsInternally
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        if !scrollsInternally {
            scrollView.verticalScrollElasticity = .none
        }
        scrollView.autohidesScrollers = true

        let contentSize = scrollView.contentSize
        let textContainer = NSTextContainer(
            containerSize: NSSize(
                width: contentSize.width,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let textView = LinkifiedTextView(frame: NSRect(origin: .zero, size: contentSize),
                                         textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: .greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.textColor = NSColor.labelColor
        textView.isRichText = true
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.allowsImageEditing = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticDataDetectionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 5, height: 8)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor:          NSCursor.pointingHand,
        ]

        scrollView.documentView = textView

        // Initial content + link styling.
        textView.string = text
        Self.applyLinks(to: textView)
        scrollView.invalidateIntrinsicContentSize()

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        return scrollView
    }

    func updateNSView(_ scrollView: IntrinsicTextScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Pull the text from the binding only if it diverged — typing
        // already pushes through `textDidChange`, so re-setting the
        // string here would clobber the cursor and selection on every
        // keystroke.
        if textView.string != text {
            let oldRange = textView.selectedRange()
            textView.string = text
            let newLength = (text as NSString).length
            let restored = NSRange(
                location: min(oldRange.location, newLength),
                length: 0
            )
            textView.selectedRange = restored
            Self.applyLinks(to: textView)
            scrollView.invalidateIntrinsicContentSize()
        }
        // Note: previously we re-ran `applyLinks` on every
        // updateNSView call even when `text` matched. This
        // re-walked the entire text storage with NSDataDetector
        // — cheap on short descriptions but expensive on long
        // ones, and it ran on every parent body re-render.
        // `textDidChange` already keeps the link attributes in
        // sync as the user types, so the only path that needs
        // a re-apply is the text-divergent branch above.

        if textView.font?.pointSize != fontSize {
            textView.font = NSFont.systemFont(ofSize: fontSize)
        }

        // Sync focus state from outer SwiftUI binding.
        if isFocused, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        weak var textView: NSTextView?
        weak var scrollView: IntrinsicTextScrollView?
        private var lastCommittedText: String

        init(_ parent: RichTextEditor) {
            self.parent = parent
            self.lastCommittedText = parent.text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            RichTextEditor.applyLinks(to: textView)
            scrollView?.invalidateIntrinsicContentSize()
        }

        func textDidBeginEditing(_ notification: Notification) {
            DispatchQueue.main.async { self.parent.isFocused = true }
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            DispatchQueue.main.async { self.parent.isFocused = false }
            if textView.string != lastCommittedText {
                lastCommittedText = textView.string
                parent.onCommit()
            }
        }

        // Single-click opens links in the user's default browser
        // (instead of the macOS default which requires Cmd+Click on
        // editable text views). This matches what users expect from
        // chat apps / Notes — easier than hunting for Cmd.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL? = {
                if let u = link as? URL { return u }
                if let s = link as? String { return URL(string: s) }
                return nil
            }()
            guard let url else { return false }
            NSWorkspace.shared.open(url)
            return true
        }
    }

    // MARK: - Link styling helper

    private static let linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    static func applyLinks(to textView: NSTextView) {
        guard let storage = textView.textStorage,
              let detector = linkDetector else { return }
        let text = storage.string
        let fullRange = NSRange(location: 0, length: storage.length)

        // Re-mark the link attribute. Color/cursor come from
        // `linkTextAttributes` on the textView, so we don't have
        // to attach them per-range here.
        storage.beginEditing()
        storage.removeAttribute(.link, range: fullRange)
        for match in detector.matches(in: text, range: fullRange) {
            guard let url = match.url else { continue }
            storage.addAttribute(.link, value: url, range: match.range)
        }
        storage.endEditing()
    }
}

// MARK: - Custom NSScrollView with intrinsic content size

/// `NSScrollView` that reports its intrinsic content size as the
/// height needed to display all of the embedded `NSTextView`'s
/// content (including text-container insets). Lets SwiftUI size
/// the editor to fit when not scrolling internally — without this
/// the scroll view defaults to "no intrinsic metric" and SwiftUI
/// has nothing to grow against.
final class IntrinsicTextScrollView: NSScrollView {
    override var intrinsicContentSize: NSSize {
        guard let textView = documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return super.intrinsicContentSize }

        // Force layout so `usedRect` reflects the current text.
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let inset = textView.textContainerInset
        return NSSize(
            width:  NSView.noIntrinsicMetric,
            height: usedRect.height + inset.height * 2
        )
    }
}

// MARK: - NSTextView subclass for cleaner link clicking

/// Plain NSTextView subclass that we can extend later if we need
/// keyboard-shortcut hooks (e.g. cmd+enter to send). Keeping it as
/// a named type also makes the runtime hierarchy easier to inspect.
final class LinkifiedTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
    }
}
