import AppKit
import Foundation

/// Renders inline attachment cards inside task descriptions to
/// match ClickUp's web client.
///
/// ClickUp embeds an uploaded file in a description as
/// `[Filename.ext](https://t…p.clickup-attachments.com/.../Filename.ext)`.
/// The Apollo parse layer flattens that markdown shape to
/// `Filename.ext (URL)` so plain-text consumers (search,
/// previews, Spotlight) stay readable. For the task-detail
/// editor, though, we want the visual ClickUp delivers: a
/// teal-green pill card with the filename centered and the
/// surrounding `(URL)` clutter hidden.
///
/// This renderer scans the flattened description for the
/// `Filename.ext (clickup-attachments URL)` pattern, replaces
/// each hit with an `NSTextAttachment` whose image is the
/// pre-drawn pill, and stamps a `.link` attribute over the
/// attachment glyph so a click opens the file in the user's
/// browser. The text BEFORE the pattern is kept (line breaks,
/// preceding list markers, headers all stay intact); only the
/// "filename + (URL)" substring becomes a single graphical glyph.
///
/// Idempotent on text with no matches — returns a plain
/// `NSAttributedString` with the default font when nothing
/// matches the regex.
extension NSAttributedString.Key {
    /// Custom attribute carrying the original ClickUp attachment
    /// URL (as `NSString`) on the range occupied by an attachment-
    /// card glyph. `LinkifiedTextView.mouseDown` looks this up to
    /// open the URL — we avoid the standard `.link` attribute on
    /// these single-character attachment ranges because
    /// `-[NSTextView clickedOnLink:atIndex:]` crashes with a
    /// pointer-auth trap inside `swift_unknownObjectRetain` on
    /// TextKit 1 in macOS Sequoia. The custom-attribute +
    /// manual-mouseDown route bypasses the buggy path entirely.
    static let descriptionAttachmentURL =
        NSAttributedString.Key("DPDescriptionAttachmentURL")
}

enum DescriptionAttachmentRenderer {

    // MARK: - Public entry point

    /// Build an attributed representation of a description, with
    /// ClickUp attachment URLs replaced by pill cards.
    /// `containerWidth` lets the card cap its own width so a long
    /// filename truncates middle-style instead of overflowing the
    /// description column.
    static func render(_ text: String,
                       font: NSFont,
                       textColor: NSColor = .labelColor,
                       containerWidth: CGFloat = 280) -> NSAttributedString {
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font:            font,
            .foregroundColor: textColor,
        ]
        guard let regex = attachmentRegex else {
            return NSAttributedString(string: text, attributes: baseAttributes)
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else {
            // No attachment cards to splice in. Still need to
            // linkify any plain URLs in the body so the user can
            // click them in display mode (same behavior the
            // editor's `applyLinks` gives in edit mode).
            return linkifiedAttributed(text, attributes: baseAttributes)
        }

        let result = NSMutableAttributedString()
        var cursor = 0
        for match in matches {
            // Append plain text between the previous match and this one.
            if match.range.location > cursor {
                let pre = nsText.substring(
                    with: NSRange(location: cursor,
                                  length: match.range.location - cursor)
                )
                // Linkify URLs inside the plain text segment.
                // Without this, non-attachment URLs (Google Docs
                // links, arbitrary clipboard pastes, etc.) showed
                // as black plain text in display mode while edit
                // mode rendered them as clickable blue — surprising
                // mode mismatch the user reported. Matches the
                // editor's NSDataDetector behavior.
                result.append(linkifiedAttributed(pre, attributes: baseAttributes))
            }

            // Group 1: filename label; Group 2: URL.
            let labelRange = match.range(at: 1)
            let urlRange   = match.range(at: 2)
            let label      = nsText.substring(with: labelRange)
                                .trimmingCharacters(in: .whitespaces)
            let urlString  = nsText.substring(with: urlRange)

            if let url = URL(string: urlString),
               let card = makeAttachmentCard(filename: label,
                                             font: font,
                                             maxWidth: containerWidth) {
                let attachment = NSTextAttachment()
                attachment.image = card
                attachment.bounds = NSRect(origin: .zero, size: card.size)
                let attachmentString = NSMutableAttributedString(attachment: attachment)
                let attRange = NSRange(location: 0, length: attachmentString.length)
                // We DON'T set the `.link` attribute on the
                // attachment glyph. Even when the value is cast
                // explicitly to NSURL/NSString, AppKit's
                // `-[NSTextView mouseDown:]` path crashes inside
                // `swift_unknownObjectRetain` (pointer-auth
                // trap) when it reads the `.link` value off an
                // attachment-only range to feed our delegate —
                // appears to be a TextKit-1 bug specific to
                // single-character attachment ranges combined
                // with link attributes. Workaround: route the
                // click through a custom attribute that we
                // look up in `LinkifiedTextView.mouseDown` by
                // inspecting the character at the click point.
                // No `.link` on the storage means no
                // `clickedOnLink:` delegate call → no crash.
                attachmentString.addAttribute(.descriptionAttachmentURL,
                                              value: urlString as NSString,
                                              range: attRange)
                attachmentString.addAttribute(.cursor,
                                              value: NSCursor.pointingHand,
                                              range: attRange)
                attachmentString.addAttribute(.toolTip,
                                              value: label as NSString,
                                              range: attRange)
                result.append(attachmentString)
            } else {
                // URL didn't parse or the card image render failed;
                // keep the literal "Filename (URL)" text as a
                // graceful fallback.
                let literal = nsText.substring(with: match.range)
                result.append(NSAttributedString(string: literal,
                                                 attributes: baseAttributes))
            }

            cursor = match.range.location + match.range.length
        }

        // Tail after the last match — same linkification as the
        // segments between attachment matches.
        if cursor < nsText.length {
            let tail = nsText.substring(
                with: NSRange(location: cursor, length: nsText.length - cursor)
            )
            result.append(linkifiedAttributed(tail, attributes: baseAttributes))
        }

        return result
    }

    // MARK: - Plain-text linkification

    /// `NSDataDetector` for URLs (same detector
    /// `RichTextEditor.applyLinks` uses in edit mode). Compiled
    /// once and reused — `NSDataDetector` initialization isn't
    /// free.
    private static let urlDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    /// Build an attributed string from the given plain `text`
    /// with `.link` attributes applied over any URLs the data
    /// detector finds. The link value is stored as `NSString`
    /// (the URL's `absoluteString`) — NOT `URL` / `NSURL` —
    /// because the same TextKit-1 retain bug that crashed
    /// attachment-glyph clicks bites here too on attribute
    /// ranges in attributed strings pushed to text storage via
    /// `setAttributedString`. Strings are safe; the
    /// `clickedOnLink:atIndex:` delegate already accepts
    /// `String` / `NSString` (see `RichTextEditor.Coordinator
    /// .textView(_:clickedOnLink:at:)`).
    private static func linkifiedAttributed(
        _ text: String,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: attributes
        )
        guard let detector = urlDetector, !text.isEmpty else { return attributed }
        let range = NSRange(location: 0, length: (text as NSString).length)
        let cursor = NSCursor.pointingHand
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url else { continue }
            attributed.addAttribute(.link,
                                    value: url.absoluteString as NSString,
                                    range: match.range)
            attributed.addAttribute(.cursor, value: cursor, range: match.range)
        }
        return attributed
    }

    // MARK: - Regex

    /// `Filename.ext (URL)` where URL points at ClickUp's CDN.
    ///
    ///   - Group 1: filename label. Greedy on a `[^\n(]+` set so it
    ///     captures everything from the line start up to ` (URL)`
    ///     (filenames legitimately contain spaces, hyphens, dots
    ///     and other punctuation; we stop at `(`, `\n`, or the
    ///     mandatory separator space).
    ///   - Group 2: full URL, anchored by the
    ///     `clickup-attachments.com` host. We accept the legacy
    ///     `attachments.clickup.com` host too just in case.
    ///
    /// `\(` and `\)` are literal parens around the URL — the
    /// surrounding markdown-link parens in ClickUp's flattened
    /// output (`Filename (URL)`).
    private static let attachmentRegex: NSRegularExpression? = {
        let pattern =
            #"""
            ([^\n(]+?)\s+\((https?://[^()\s]*(?:clickup-attachments\.com|attachments\.clickup\.com)[^()\s]+)\)
            """#
        return try? NSRegularExpression(pattern: pattern,
                                        options: [.allowCommentsAndWhitespace])
    }()

    // MARK: - Card drawing

    /// Pre-draw the pill card as an `NSImage` so it can live inside
    /// an `NSTextAttachment`. We render a rounded rect with the
    /// ClickUp-style teal fill, a darker stroke for definition,
    /// and the filename centered with middle truncation.
    ///
    /// Caching: keyed by `(filename, fontSize, maxWidth, isDark)`
    /// so the same card doesn't get re-rasterized on every text
    /// change. Cache size is bounded so a workspace with hundreds
    /// of unique attachment names doesn't bloat memory.
    private static func makeAttachmentCard(filename: String,
                                           font: NSFont,
                                           maxWidth: CGFloat) -> NSImage? {
        let isDark = NSApp.effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua]) == .darkAqua
        let key = CacheKey(filename: filename,
                           fontSize: font.pointSize,
                           maxWidth: maxWidth,
                           isDark: isDark)
        if let cached = cache[key] { return cached }

        // Filename gets middle-truncated to ~36 chars before being
        // measured. Long names that survive that cap still fit
        // because the text is drawn into a rect clipped at
        // `maxWidth` minus padding.
        // Studio Glass: accent roxo, chip nos neutros novos. Cores
        // são cozidas no bitmap (NSImage), então resolvem aqui pelo
        // flag `isDark` cacheado em vez de NSColor dinâmico.
        let editorialAccent = NSColor.controlAccentColor
        let editorialCard   = NSColor(hexString: isDark ? "#1C1C1D" : "#FCFAF5")
        let editorialRule   = isDark
            ? NSColor(hexString: "#FFFFFF").withAlphaComponent(0.07)
            : NSColor(hexString: "#14130F").withAlphaComponent(0.10)
        // SF Pro itálico (serif morreu no Studio Glass).
        let cardFont: NSFont = {
            let size = font.pointSize - 1
            let base = NSFont.systemFont(ofSize: size)
            let d = base.fontDescriptor.withSymbolicTraits(.italic)
            return NSFont(descriptor: d, size: size) ?? base
        }()
        let truncated = truncateMiddle(filename, maxChars: 36)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font:            cardFont,
            .foregroundColor: editorialAccent,
        ]
        let textString = NSAttributedString(string: truncated, attributes: textAttrs)
        let textSize = textString.size()

        let hPad: CGFloat = 10
        let vPad: CGFloat = 4
        let height = ceil(textSize.height + vPad * 2)
        let naturalWidth = ceil(textSize.width + hPad * 2)
        let width = min(naturalWidth, maxWidth)

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 4, yRadius: 4)
        // Editorial chip: off-white paper fill + a single
        // hairline rule — no saturated emerald block.
        editorialCard.setFill()
        path.fill()
        editorialRule.setStroke()
        path.lineWidth = 1
        path.stroke()

        let textRect = NSRect(
            x: hPad,
            y: vPad,
            width: width - hPad * 2,
            height: textSize.height
        )
        // Single-line, middle-truncated drawing. The truncation
        // happens via the line break mode set inside the
        // paragraph style.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        paragraph.alignment     = .center
        let drawingAttrs: [NSAttributedString.Key: Any] = [
            .font:            cardFont,
            .foregroundColor: editorialAccent,
            .paragraphStyle:  paragraph,
        ]
        (truncated as NSString).draw(in: textRect, withAttributes: drawingAttrs)

        cache[key] = image
        if cache.count > 256 { cache.removeAll() } // bounded
        return image
    }

    private static func truncateMiddle(_ s: String, maxChars: Int) -> String {
        guard s.count > maxChars else { return s }
        let halfBudget = (maxChars - 1) / 2
        let prefix = String(s.prefix(halfBudget))
        let suffix = String(s.suffix(halfBudget))
        return prefix + "…" + suffix
    }

    // MARK: - Cache

    private struct CacheKey: Hashable {
        let filename: String
        let fontSize: CGFloat
        let maxWidth: CGFloat
        let isDark:   Bool
    }
    private static var cache: [CacheKey: NSImage] = [:]
}
