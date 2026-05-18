import SwiftUI
import AppKit

// Renders a ClickUp comment body and converts URLs into typed attachment
// cards (image / video / audio / generic file). Each card has a "open in
// browser" button that hands the URL to NSWorkspace — much safer than
// trying to drive AVKit/AsyncImage inline inside a deeply-nested
// LazyVStack, which previously crashed the app on attachment-heavy tasks.

struct CommentBodyView: View, Equatable {
    let text: String
    /// Structured attachments returned by ClickUp on the
    /// comment object itself (paperclip / drag-drop into the
    /// comment box). These don't appear in the comment text and
    /// would otherwise be invisible. Rendered as cards below
    /// the text body and de-duplicated against any URLs the
    /// user typed inline so the same file never doubles up.
    var attachments: [CUTask.Attachment] = []

    /// Workspace usernames the highlighter will treat as
    /// mention targets — used to greedy-match `@<full username>`
    /// even when the username spans multiple words (e.g.
    /// `@Henrique Freitas Wiermann`). Without this list the
    /// regex fallback only catches `@Henrique` since `\w` doesn't
    /// span spaces, leaving the surname rendered as plain text.
    /// Deliberately NOT part of `Equatable`: the list rarely
    /// changes within a session, and including it would defeat
    /// the parent's `.equatable()` cache without measurable UX
    /// gain — at worst, a brand-new member's mention won't
    /// re-highlight until the comment list refreshes.
    var mentionUsernames: [String] = []

    /// Equatable so a parent's `.equatable()` modifier can
    /// short-circuit re-renders when neither the text nor the
    /// attachment list changed. Comparing the raw fields is
    /// cheap and avoids the NSDataDetector reparse below.
    static func == (lhs: CommentBodyView, rhs: CommentBodyView) -> Bool {
        lhs.text == rhs.text && lhs.attachments == rhs.attachments
    }

    /// Cached, parsed body parts — the text broken into runs of
    /// plain text + URL-detected attachment cards. Computing
    /// this in a `let` (initialised once when the view value is
    /// constructed) is critical: previously this was a
    /// computed property `{ Self.parse(text: text) }` that
    /// re-ran an `NSDataDetector` against the full comment body
    /// on EVERY body re-evaluation. With dozens of comments per
    /// task and SwiftUI re-running views on unrelated state
    /// changes, that dominated the popup's frame budget and
    /// produced the visible "anexos piscando / desaparecendo"
    /// glitch as each comment briefly reflowed mid-scroll.
    private let cachedParts: [Part]
    /// Pre-computed dedup set so the structured-attachment
    /// filter doesn't have to walk `cachedParts` on every body
    /// render. Same rationale as `cachedParts`.
    private let inlineUrlSet: Set<String>

    init(text: String,
         attachments: [CUTask.Attachment] = [],
         mentionUsernames: [String] = []) {
        self.text = text
        self.attachments = attachments
        self.mentionUsernames = mentionUsernames
        let parsed = Self.parse(text: text)
        self.cachedParts = parsed
        self.inlineUrlSet = Set(parsed.compactMap { p -> String? in
            if case .url(let u, _) = p { return u.absoluteString }
            return nil
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Inline parts (text + URL-detected attachments
            // pasted into the comment body).
            ForEach(Array(cachedParts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let s):
                    Text(Self.highlightedMentions(in: s,
                                                  knownUsernames: mentionUsernames))
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .url(let url, let kind):
                    attachmentCard(url: url, kind: kind)
                }
            }

            // Structured attachments — those uploaded via the
            // paperclip / drag-drop and not present in the text.
            // Skip any whose URL we already rendered inline.
            ForEach(attachments.filter { !inlineUrlSet.contains($0.url) },
                    id: \.id) { att in
                structuredCard(att)
            }
        }
    }

    // MARK: - Structured attachment card

    /// Card variant used when ClickUp gave us full metadata
    /// (filename, size, extension) on a comment attachment —
    /// we don't have to derive anything from the URL path.
    private func structuredCard(_ att: CUTask.Attachment) -> some View {
        let url = URL(string: att.url) ?? URL(fileURLWithPath: "/")
        let kind = Self.kind(for: url)
        let info = meta(for: url, kind: kind)

        let accent = info.tint.editorialMuted
        let ext = att.ext.isEmpty
            ? (url.pathExtension.isEmpty ? "FILE" : url.pathExtension)
            : att.ext
        return Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Text(ext.uppercased())
                    .font(Editorial.sans(9, .semibold))
                    .tracking(0.4)
                    .foregroundStyle(accent)
                    .frame(width: 38, height: 20)
                    .background(RoundedRectangle(cornerRadius: 3)
                        .fill(accent.opacity(0.12)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(att.title)
                        .font(Editorial.serif(13))
                        .foregroundStyle(Editorial.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        Text(info.label)
                        if let size = att.sizeString {
                            Text("·")
                            Text(size).monospacedDigit()
                        }
                    }
                    .font(Editorial.sans(10.5))
                    .foregroundStyle(Editorial.inkMute)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Editorial.inkMute)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Editorial.card))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Editorial.rule, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("Abrir \(att.title)")
    }

    // MARK: - One unified card

    private func attachmentCard(url: URL, kind: AttachmentKind) -> some View {
        let info = meta(for: url, kind: kind)

        let accent = info.tint.editorialMuted
        let ext = url.pathExtension.isEmpty ? "FILE" : url.pathExtension
        return Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Text(ext.uppercased())
                    .font(Editorial.sans(9, .semibold))
                    .tracking(0.4)
                    .foregroundStyle(accent)
                    .frame(width: 38, height: 20)
                    .background(RoundedRectangle(cornerRadius: 3)
                        .fill(accent.opacity(0.12)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(Editorial.serif(13))
                        .foregroundStyle(Editorial.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(info.label)
                        .font(Editorial.sans(10.5))
                        .foregroundStyle(Editorial.inkMute)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Editorial.inkMute)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Editorial.card))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Editorial.rule, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("Abrir \(url.lastPathComponent)")
    }

    // MARK: - Mention highlighting

    /// Regex that matches `@username`-style mentions inside a
    /// comment body. The username can contain Unicode word
    /// characters, dots, hyphens and underscores — so
    /// `@ana.bastos`, `@henrique-w`, and `@joão_silva` all
    /// get caught. Matches are non-greedy on punctuation: a
    /// trailing comma or period stops the match cleanly.
    ///
    /// `static let` so the regex compiles ONCE per process,
    /// not once per comment render. Cheap but adds up across
    /// long task threads.
    private static let mentionRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"@[\p{L}0-9._-]+"#)
    }()

    /// Produces an `AttributedString` where every `@mention`
    /// is painted in the accent colour (semibold). Plain
    /// chunks between mentions stay at the default style so
    /// the surrounding `Text(...)` modifiers control them.
    /// Matching ClickUp's web client, which renders mentions
    /// as the workspace's accent green/blue.
    ///
    /// Two-stage matching at every `@`:
    ///
    /// 1. If the text starting at `@` matches `@<username>`
    ///    for any known workspace username, the LONGEST such
    ///    match wins. This is what lets surnames stay blue —
    ///    `\w`-based regexes can't span the spaces in
    ///    `@Henrique Freitas Wiermann`, so without the username
    ///    list only "@Henrique" would highlight.
    /// 2. Otherwise, fall back to the simple `@[\p{L}0-9._-]+`
    ///    regex pattern. Catches stale @-mentions whose member
    ///    has been removed, AI-generated text with @mentions
    ///    we don't have a workspace handle for, etc.
    ///
    /// Falls through to plain rendering for any `@` that
    /// matches neither path (e.g. an `@` in an email address —
    /// the regex's `+` requires at least one char after `@`,
    /// but we still skip the `@` cleanly).
    static func highlightedMentions(in s: String,
                                    knownUsernames: [String] = []) -> AttributedString {
        // Sort longest-first so e.g. `@Joao Silva` claims its
        // full range before `@Joao` could grab the prefix.
        let sortedUsernames = knownUsernames
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }

        var result    = AttributedString()
        var plainStart = s.startIndex
        var i          = s.startIndex

        // Style applied to whichever range a `@` consumes.
        func styled(_ range: Range<String.Index>) -> AttributedString {
            var a = AttributedString(String(s[range]))
            // New York italic in the app's cinnabar accent.
            a.foregroundColor = Editorial.accent
            a.font = .system(.body, design: .serif).italic()
            return a
        }

        while i < s.endIndex {
            guard s[i] == "@" else {
                i = s.index(after: i)
                continue
            }

            // Stage 1: longest known username starting at `i`.
            var matchEnd: String.Index? = nil
            for username in sortedUsernames {
                let needle = "@" + username
                if let end = s.index(i, offsetBy: needle.count, limitedBy: s.endIndex),
                   s[i..<end] == needle {
                    matchEnd = end
                    break
                }
            }

            // Stage 2: regex fallback at `i`.
            if matchEnd == nil {
                let suffixRange = NSRange(i..<s.endIndex, in: s)
                if let m = mentionRegex.firstMatch(in: s, range: suffixRange),
                   let r = Range(m.range, in: s),
                   r.lowerBound == i {
                    matchEnd = r.upperBound
                }
            }

            if let end = matchEnd {
                if plainStart < i {
                    result.append(AttributedString(String(s[plainStart..<i])))
                }
                result.append(styled(i..<end))
                i          = end
                plainStart = end
            } else {
                // Bare `@` (e.g. inside an email). Skip past it
                // and let the surrounding text stay plain.
                i = s.index(after: i)
            }
        }

        if plainStart < s.endIndex {
            result.append(AttributedString(String(s[plainStart..<s.endIndex])))
        }
        return result
    }

    // MARK: - Parsing

    enum Part {
        case text(String)
        case url(URL, AttachmentKind)
    }

    enum AttachmentKind { case image, video, audio, file }

    private static func parse(text: String) -> [Part] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [.text(text)] }

        let range = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, range: range)
        guard !matches.isEmpty else { return [.text(text)] }

        var result: [Part] = []
        var cursor = text.startIndex
        for m in matches {
            guard let r = Range(m.range, in: text), let url = m.url else { continue }
            if cursor < r.lowerBound {
                let chunk = String(text[cursor..<r.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !chunk.isEmpty { result.append(.text(chunk)) }
            }
            result.append(.url(url, kind(for: url)))
            cursor = r.upperBound
        }
        if cursor < text.endIndex {
            let trail = String(text[cursor...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trail.isEmpty { result.append(.text(trail)) }
        }
        return result.isEmpty ? [.text(text)] : result
    }

    private static func kind(for url: URL) -> AttachmentKind {
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff"].contains(ext) {
            return .image
        }
        if ["mp4", "mov", "m4v", "webm", "avi", "mkv"].contains(ext) { return .video }
        if ["mp3", "m4a", "wav", "aac", "flac", "ogg"].contains(ext) { return .audio }
        return .file
    }

    // MARK: - Card metadata

    private struct Meta { let icon: String; let tint: Color; let label: String }

    private func meta(for url: URL, kind: AttachmentKind) -> Meta {
        switch kind {
        case .image: return .init(icon: "photo.fill",       tint: .pink,         label: "Imagem")
        case .video: return .init(icon: "video.fill",       tint: Editorial.accent, label: "Vídeo")
        case .audio: return .init(icon: "waveform",         tint: .purple,       label: "Áudio")
        case .file:
            switch url.pathExtension.lowercased() {
            case "pdf":
                return .init(icon: "doc.richtext.fill",     tint: .red,    label: "PDF")
            case "doc", "docx":
                return .init(icon: "doc.text.fill",         tint: .blue,   label: "Documento Word")
            case "xls", "xlsx", "csv":
                return .init(icon: "tablecells.fill",       tint: .green,  label: "Planilha")
            case "ppt", "pptx", "keynote":
                return .init(icon: "rectangle.on.rectangle.fill",
                             tint: .orange, label: "Apresentação")
            case "zip", "rar", "tar", "gz", "7z":
                return .init(icon: "doc.zipper",            tint: .purple, label: "Arquivo compactado")
            case "swift":
                return .init(icon: "swift",                 tint: .orange, label: "Swift")
            case "js", "ts", "py", "rb", "java", "go", "rs", "c", "cpp", "h", "hpp":
                return .init(icon: "chevron.left.forwardslash.chevron.right",
                             tint: .indigo, label: "Código")
            case "txt", "md":
                return .init(icon: "doc.plaintext.fill",    tint: .gray,   label: "Texto")
            default:
                return .init(icon: "doc.fill",
                             tint: Color(NSColor.tertiaryLabelColor),
                             label: "Arquivo")
            }
        }
    }
}
