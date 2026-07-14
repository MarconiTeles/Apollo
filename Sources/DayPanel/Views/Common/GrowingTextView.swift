import SwiftUI
import AppKit

/// A multi-line, auto-growing text input backed by `NSTextView`.
///
/// Replaces `TextField(axis: .vertical)` in the comment composer: on this
/// macOS build, plain Return there committed the field and SELECTED the
/// whole line instead of inserting a newline. With a real `NSTextView`,
/// Return always inserts a newline; Cmd+Return calls `onSubmit`.
///
/// Grows from `minHeight` to `maxHeight` (then scrolls internally),
/// reporting its measured height back through `height` so the SwiftUI
/// container can resize with it.
struct GrowingTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var isFocused: Bool
    var onSubmit: () -> Void
    var minHeight: CGFloat = 20
    var maxHeight: CGFloat = 150

    /// AppKit twin of `Editorial.serif(13)` — Studio Glass: SF Pro
    /// (serif morreu) no mesmo −15% de type scale global.
    private var nsFont: NSFont {
        let s = 13 * Editorial.typeScale
        return NSFont.systemFont(ofSize: s)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = nsFont
        tv.textColor = NSColor(Editorial.ink)
        tv.insertionPointColor = NSColor(Editorial.accent)
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.string = text
        context.coordinator.textView = tv
        DispatchQueue.main.async { context.coordinator.recalcHeight() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.string = text
            context.coordinator.recalcHeight()
        }
        tv.font = nsFont
        tv.textColor = NSColor(Editorial.ink)
        // Programmatic focus (SwiftUI → AppKit). Reported focus changes
        // flow back via the begin/end-editing delegate callbacks.
        if isFocused, let win = tv.window, win.firstResponder !== tv {
            win.makeFirstResponder(tv)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextView
        weak var textView: NSTextView?

        init(_ parent: GrowingTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            recalcHeight()
        }

        func textDidBeginEditing(_ notification: Notification) {
            if !parent.isFocused {
                DispatchQueue.main.async { self.parent.isFocused = true }
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            if parent.isFocused {
                DispatchQueue.main.async { self.parent.isFocused = false }
            }
        }

        /// Return → newline (default). Cmd+Return → submit, swallow the
        /// newline. Everything else falls through to the text view.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if let event = NSApp.currentEvent,
                   event.modifierFlags.contains(.command) {
                    parent.onSubmit()
                    return true
                }
                // Insert the newline EXPLICITLY (don't rely on the
                // default), then mark handled — the default path was
                // being swallowed, leaving Return a no-op.
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            }
            return false
        }

        func recalcHeight() {
            guard let tv = textView,
                  let lm = tv.layoutManager,
                  let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height
            let h = min(max(used + tv.textContainerInset.height * 2, parent.minHeight),
                        parent.maxHeight)
            if abs(parent.height - h) > 0.5 {
                DispatchQueue.main.async { self.parent.height = h }
            }
        }
    }
}
