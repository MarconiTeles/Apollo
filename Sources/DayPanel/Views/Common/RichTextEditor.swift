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

    /// When true, the editor renders ClickUp-style attachment
    /// cards (teal pills) in place of `Filename.ext (URL)`
    /// patterns whose URL is a ClickUp attachment. Cards only
    /// appear in display mode (when `isFocused` is false); the
    /// user always sees raw markdown text while editing. Off by
    /// default so chat composers and other plain-text uses of
    /// the editor stay unchanged.
    var renderAttachmentCards: Bool = false

    /// Exact substrings (e.g. `@Lucas Lima`) to render link-like —
    /// cinnabar + semibold — so an @-mention reads as a link.
    var mentionStrings: [String] = []

    /// Files dropped onto the editor. When set, a file drag is
    /// intercepted *before* NSTextView's default handler dumps the
    /// raw POSIX path into the prose — the host turns the URLs into
    /// proper editorial attachments instead. Receives every file in
    /// a multi-file drop.
    var onFileDrop: (([URL]) -> Void)? = nil

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
        // Note: there is NO `onBecomeFirstResponder` hook flipping
        // `isFocused` on click. Doing that caused the description
        // editor to swap from card-display mode to plain-text
        // edit mode the moment a user clicked an attachment card,
        // which made the card "vanish into a plain link" the
        // instant the click opened the file. The
        // display→edit transition now happens through
        // `textDidBeginEditing` only — i.e. the user has to
        // actually start typing for the swap to fire.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: .greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.textColor = NSColor(srgbRed: 0.078, green: 0.075, blue: 0.059, alpha: 1.0)
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
            // Editorial cinnabar (#C7321B) instead of system blue.
            .foregroundColor: NSColor(srgbRed: 0.780, green: 0.196,
                                      blue: 0.106, alpha: 1.0),
            .cursor:          NSCursor.pointingHand,
        ]

        // Intercept file drags so a dropped file becomes a proper
        // editorial attachment instead of a raw path pasted into
        // the prose. Only active when the host wired `onFileDrop`.
        textView.onFileDrop = onFileDrop
        textView.registerForDraggedTypes([.fileURL])

        scrollView.documentView = textView

        // Initial content. `renderDisplayedContent` handles both
        // the plain (focused / no-card) path and the
        // attributed-with-cards path.
        renderDisplayedContent(into: textView, focused: isFocused)
        scrollView.invalidateIntrinsicContentSize()

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        return scrollView
    }

    func updateNSView(_ scrollView: IntrinsicTextScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Decide whether the displayed content is currently in
        // edit mode (plain text, raw markdown visible) or display
        // mode (attachment cards rendered). The "is displaying
        // cards" state is tracked on the coordinator so we re-
        // render only when the bound text changes OR focus
        // transitions between the two modes.
        let wantsCards = renderAttachmentCards && !isFocused
        let needsRender = textView.string != text
            || context.coordinator.isShowingCards != wantsCards

        if needsRender {
            let oldRange = textView.selectedRange()
            renderDisplayedContent(into: textView, focused: isFocused)
            let newLength = (textView.string as NSString).length
            let restored = NSRange(
                location: min(oldRange.location, newLength),
                length: 0
            )
            textView.selectedRange = restored
            scrollView.invalidateIntrinsicContentSize()
            context.coordinator.isShowingCards = wantsCards
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

        // Keep the drop callback fresh — it captures SwiftUI state
        // that changes between renders.
        (textView as? LinkifiedTextView)?.onFileDrop = onFileDrop

        // Sync focus state from outer SwiftUI binding.
        // - isFocused = true and we're not yet first responder
        //   → promote the textView to first responder so the
        //     user can type immediately (covers the toggle
        //     button case + programmatic focus elsewhere).
        // - isFocused = false and we ARE first responder
        //   → resign so the user doesn't see a blinking caret
        //     hovering over the card-render mode. The
        //     `endEditing` text-system call also flushes
        //     pending input + invalidates the marked text.
        if isFocused, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        } else if !isFocused, textView.window?.firstResponder === textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(nil)
            }
        }
    }

    /// Push the current `text` into the NSTextView, choosing
    /// between the plain edit-mode rendering and the attributed
    /// display-mode rendering with attachment cards. Editable
    /// flag also flips so a click inside the card area doesn't
    /// land a caret inside the attachment glyph.
    private func renderDisplayedContent(into textView: NSTextView,
                                        focused: Bool) {
        let wantsCards = renderAttachmentCards && !focused
        if wantsCards {
            let attributed = DescriptionAttachmentRenderer.render(
                text,
                font: NSFont.systemFont(ofSize: fontSize),
                textColor: NSColor(srgbRed: 0.078, green: 0.075, blue: 0.059, alpha: 1.0)
            )
            textView.textStorage?.setAttributedString(attributed)
            // In display mode the user can't accidentally type
            // between cards or delete one — flips back to
            // editable the moment they click in.
            textView.isEditable = false
            textView.isSelectable = true
        } else {
            textView.string = text
            // Re-apply data-detector links so plain URLs in the
            // raw markdown still come back as clickable.
            Self.applyLinks(to: textView)
            Self.applyMentions(to: textView, mentions: mentionStrings)
            textView.isEditable = true
            textView.isSelectable = true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        weak var textView: NSTextView?
        weak var scrollView: IntrinsicTextScrollView?
        private var lastCommittedText: String
        /// True when the editor is currently displaying the
        /// attachment-card attributed string. `updateNSView` reads
        /// this to decide whether to re-render — without it, every
        /// focus transition would needlessly rebuild the
        /// NSAttributedString.
        var isShowingCards: Bool = false

        init(_ parent: RichTextEditor) {
            self.parent = parent
            self.lastCommittedText = parent.text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            RichTextEditor.applyLinks(to: textView)
            RichTextEditor.applyMentions(to: textView, mentions: parent.mentionStrings)
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
                // NSURL FIRST. Attachment-card links are stored
                // as `NSURL` (see `DescriptionAttachmentRenderer`)
                // — Swift bridging from a stored `URL` value type
                // crashes inside `swift_unknownObjectRetain`
                // because the bridged NSObject's lifetime isn't
                // anchored by the attribute store.
                if let n = link as? NSURL { return n as URL }
                if let u = link as? URL { return u }
                if let s = link as? String { return URL(string: s) }
                if let n = link as? NSString { return URL(string: n as String) }
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

    /// Render exact `@mention` substrings link-like: editorial
    /// cinnabar + semibold. Foreground/font are first reset to the
    /// editor defaults across the whole string so deleting or
    /// editing a mention reverts cleanly; real links keep their
    /// look via the text view's `linkTextAttributes` (which the
    /// `.link` attribute drives independently of `.foregroundColor`).
    static func applyMentions(to textView: NSTextView, mentions: [String]) {
        guard let storage = textView.textStorage else { return }
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard full.length > 0 else { return }

        let defaultColor = textView.textColor
            ?? NSColor(srgbRed: 0.078, green: 0.075, blue: 0.059, alpha: 1.0)
        let defaultFont = textView.font ?? NSFont.systemFont(ofSize: 13)
        let mentionColor = NSColor(srgbRed: 0.780, green: 0.196,
                                   blue: 0.106, alpha: 1.0)
        let mentionFont = NSFont.systemFont(ofSize: defaultFont.pointSize,
                                            weight: .semibold)

        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: defaultColor, range: full)
        storage.addAttribute(.font, value: defaultFont, range: full)
        for mention in mentions where !mention.isEmpty {
            var cursor = 0
            while cursor < ns.length {
                let scan = NSRange(location: cursor, length: ns.length - cursor)
                let r = ns.range(of: mention, options: [], range: scan)
                if r.location == NSNotFound { break }
                storage.addAttribute(.foregroundColor, value: mentionColor, range: r)
                storage.addAttribute(.font, value: mentionFont, range: r)
                cursor = r.location + max(1, r.length)
            }
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
///
/// Also exposes a `onBecomeFirstResponder` callback that fires
/// the instant focus moves into the editor — used by
/// `RichTextEditor` to swap from the attachment-card display
/// rendering to a plain raw-markdown rendering BEFORE the user
/// starts typing, so the first keystroke lands in the editable
/// string and not on a card glyph.
final class LinkifiedTextView: NSTextView {
    /// Optional callback fired on `becomeFirstResponder`. Left in
    /// place for future use (e.g. a keyboard-driven focus path)
    /// but currently NOT wired by `RichTextEditor` — having
    /// `becomeFirstResponder` flip the SwiftUI `isFocused`
    /// binding caused the description editor to swap from card
    /// display mode to plain-text edit mode the moment the user
    /// clicked an attachment card, which made the card "vanish
    /// into plain text" right after the click opened the file.
    /// The display→edit swap now flows through
    /// `textDidBeginEditing` only.
    var onBecomeFirstResponder: (() -> Void)?

    /// Set by `RichTextEditor` when the host wants dropped files
    /// turned into attachments rather than pasted as a path string.
    var onFileDrop: (([URL]) -> Void)?

    // MARK: - File-drag interception
    //
    // NSTextView's default file-drop inserts the absolute POSIX
    // path as literal text ("/Users/…/B _ Editorial Calm.html").
    // When the host provides `onFileDrop`, we claim file drags here
    // and hand the URLs off so they become proper editorial
    // attachment chips/cards — and the prose stays clean. Non-file
    // drags (text, RTF, the editor's own selection) fall through to
    // the default behavior untouched.

    private func droppedFileURLs(_ sender: NSDraggingInfo) -> [URL] {
        let pb = sender.draggingPasteboard
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objs = pb.readObjects(forClasses: [NSURL.self], options: opts)
        return (objs as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if onFileDrop != nil, !droppedFileURLs(sender).isEmpty { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if onFileDrop != nil, !droppedFileURLs(sender).isEmpty { return .copy }
        return super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if onFileDrop != nil, !droppedFileURLs(sender).isEmpty { return true }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let onFileDrop {
            let urls = droppedFileURLs(sender)
            if !urls.isEmpty {
                DispatchQueue.main.async { onFileDrop(urls) }
                return true   // claimed — NSTextView never sees it
            }
        }
        return super.performDragOperation(sender)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if onFileDrop != nil,
           let sender, !droppedFileURLs(sender).isEmpty {
            return   // nothing to finalize; we handled it ourselves
        }
        super.concludeDragOperation(sender)
    }

    override func mouseDown(with event: NSEvent) {
        // Description-attachment cards carry a custom URL via
        // `.descriptionAttachmentURL` instead of `.link` because
        // the standard `clickedOnLink:` path crashes on
        // attachment glyphs in TextKit 1 (see comments on
        // `DescriptionAttachmentRenderer.render`). Handle the
        // click here by mapping the cursor to a character index,
        // verifying the glyph at that index IS our attachment
        // (not just the nearest glyph to an off-target click),
        // reading our attribute, and opening the URL ourselves.
        if let storage = self.textStorage,
           let layoutManager = self.layoutManager,
           let container = self.textContainer,
           storage.length > 0 {
            let pointInView = convert(event.locationInWindow, from: nil)
            let pointInContainer = NSPoint(
                x: pointInView.x - textContainerInset.width,
                y: pointInView.y - textContainerInset.height
            )
            // `glyphIndex(for:in:fractionOfDistanceThroughGlyph:)`
            // tells us how far into the glyph the click landed.
            // `glyphIndex(for:in:)` (no fraction) silently snaps
            // to the nearest glyph, which would fire the URL
            // open on a click anywhere NEAR a card — not what
            // we want. Use the fraction-aware variant and bail
            // when it's at the leading edge of an off-target
            // glyph (fraction ≈ 0) or trailing edge (fraction
            // ≈ 1) so a click in whitespace just below the card
            // doesn't open the URL.
            var fraction: CGFloat = 0
            let glyphIndex = layoutManager.glyphIndex(
                for: pointInContainer,
                in: container,
                fractionOfDistanceThroughGlyph: &fraction
            )
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            // Verify the click really lands inside the glyph's
            // bounding rect — not just near it.
            let glyphRect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyphIndex, length: 1),
                in: container
            )
            let hitsGlyph = glyphRect.insetBy(dx: -1, dy: -1)
                .contains(pointInContainer)
            if hitsGlyph,
               charIndex < storage.length,
               let urlString = storage.attribute(
                    .descriptionAttachmentURL,
                    at: charIndex,
                    effectiveRange: nil) as? String,
               let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
                return
            }
        }
        super.mouseDown(with: event)
    }
}
