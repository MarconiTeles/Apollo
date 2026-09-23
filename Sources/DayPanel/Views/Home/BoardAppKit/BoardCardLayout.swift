import AppKit
import CoreText
import SwiftUI

// Text and geometry model of the SwiftUI `BoardCard`, reproduced for the
// AppKit renderer. Values below are derived from the SwiftUI source and from
// measured SwiftUI output (see docs/board-appkit): a SwiftUI `Text` line is
// `round(ascent) + ceil(descent)` points tall with its baseline at
// `round(ascent)`, and intrinsic widths are rounded up to the pixel grid.

/// Card copy shared by both renderers. Mechanical extraction of the former
/// private helpers of `BoardCard`, so SwiftUI and AppKit cannot drift.
enum BoardCardFormatting {
    static func breadcrumb(workspace ws: String, listName lst: String) -> String {
        if !ws.isEmpty && !lst.isEmpty { return "\(ws.uppercased()) · \(lst.uppercased())" }
        if !lst.isEmpty                { return lst.uppercased() }
        return ws.uppercased()
    }

    static func firstName(_ task: CUTask) -> String {
        let raw = task.assignees.first?.username ?? ""
        let token = raw.split(whereSeparator: { " ._-".contains($0) }).first ?? ""
        return token.isEmpty ? "Sem responsável" : token.prefix(1).uppercased() + token.dropFirst()
    }

    static func assigneeColorHex(_ task: CUTask) -> String {
        let palette = ["#8B5CF6", "#2E6E6A", "#3F6B4A", "#4F8EF7",
                       "#9A7B1F", "#7A6597", "#B0612E", "#54577E"]
        let key = task.assignees.first?.username ?? task.id
        var h = 0
        for u in key.unicodeScalars { h = (h &* 31) &+ Int(u.value) }
        return palette[abs(h) % palette.count]
    }

    static func relativeDate(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d)     { return "Hoje" }
        if cal.isDateInYesterday(d) { return "Ontem" }
        if cal.isDateInTomorrow(d)  { return "Amanhã" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now),
                                              to:   cal.startOfDay(for: d)).day ?? 0
        if days > 1 && days < 7  { return "em \(days) dias" }
        if days < -1 && days > -7 { return "\(-days) dias atrás" }
        return SharedDateFormatters.dayOfMonthAbbrevPTBR.string(from: d)
    }

    enum DateTone: Equatable { case today, overdue, normal }

    static func dateTone(due: Date, isCompleted: Bool, now: Date = Date()) -> DateTone {
        let cal = Calendar.current
        if cal.isDateInToday(due) { return .today }
        if due < cal.startOfDay(for: now) && !isCompleted { return .overdue }
        return .normal
    }

    static func priorityLabel(_ priority: Int) -> String {
        switch priority {
        case 1: return "URGENTE"
        case 2: return "ALTA"
        case 3: return "NORMAL"
        case 4: return "BAIXA"
        default: return ""
        }
    }

    static func showsPriorityChip(_ priority: Int) -> Bool {
        priority > 0 && priority <= 2
    }
}

/// Fonts of the SwiftUI card (`Editorial.sans(size) = size × 0.85`).
enum BoardCardFonts {
    static let scale = Editorial.typeScale
    static let breadcrumb = NSFont.systemFont(ofSize: 9.5 * scale, weight: .semibold)
    static let chip       = NSFont.systemFont(ofSize: 9.5 * scale, weight: .bold)
    static let title      = NSFont.systemFont(ofSize: 13 * scale, weight: .semibold)
    static let name       = NSFont.systemFont(ofSize: 11.5 * scale, weight: .medium)
    static let date       = NSFont.systemFont(ofSize: 11 * scale, weight: .medium)
    static let emptyDot   = NSFont.systemFont(ofSize: 9 * scale, weight: .bold)
    static let initials   = NSFont.systemFont(ofSize: 18 * 0.42, weight: .bold)
    static let overflow   = NSFont.systemFont(ofSize: 18 * 0.38, weight: .semibold)
}

/// Single SwiftUI-equivalent text line (CoreText), colour-independent so the
/// same layout serves light and dark appearances.
struct BoardTextLine {
    let line: CTLine
    /// Intrinsic width rounded up to the pixel grid (SwiftUI frame width).
    let width: CGFloat
    let height: CGFloat
    let baseline: CGFloat

    static func metrics(_ font: NSFont) -> (height: CGFloat, baseline: CGFloat) {
        let ct = font as CTFont
        let ascent = CTFontGetAscent(ct).rounded()
        let descent = CTFontGetDescent(ct).rounded(.up)
        return (ascent + descent, ascent)
    }

    static func attributes(_ font: NSFont, kern: CGFloat) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        if kern != 0 { attrs[.kern] = kern }
        return attrs
    }

    /// One line, tail-truncated with "…" when wider than `maxWidth`.
    static func make(_ string: String, font: NSFont, kern: CGFloat = 0,
                     maxWidth: CGFloat = .greatestFiniteMagnitude,
                     pixel: CGFloat) -> BoardTextLine {
        let attrs = attributes(font, kern: kern)
        let full = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
        let (height, baseline) = metrics(font)
        let natural = CGFloat(CTLineGetTypographicBounds(full, nil, nil, nil))
        let naturalWidth = pixelCeil(natural, pixel)
        if naturalWidth <= maxWidth {
            return BoardTextLine(line: full, width: naturalWidth, height: height, baseline: baseline)
        }
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
        let truncated = CTLineCreateTruncatedLine(full, Double(max(0, maxWidth)), .end, token) ?? full
        let w = CGFloat(CTLineGetTypographicBounds(truncated, nil, nil, nil))
        return BoardTextLine(line: truncated, width: min(maxWidth, pixelCeil(w, pixel)),
                             height: height, baseline: baseline)
    }

    /// Word-wrapped paragraph limited to `maxLines`, last line tail-truncated.
    static func wrapped(_ string: String, font: NSFont, width: CGFloat,
                        maxLines: Int) -> [CTLine] {
        let attrs = attributes(font, kern: 0)
        let attributed = NSAttributedString(string: string, attributes: attrs)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = attributed.length
        var lines: [CTLine] = []
        var start = 0
        while start < length && lines.count < maxLines {
            if lines.count == maxLines - 1 {
                // Last permitted line: the remainder, tail-truncated.
                let rest = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: length - start))
                let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
                lines.append(CTLineCreateTruncatedLine(rest, Double(width), .end, token) ?? rest)
                break
            }
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            guard count > 0 else { break }
            lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
            start += count
        }
        return lines
    }

    static func pixelCeil(_ value: CGFloat, _ pixel: CGFloat) -> CGFloat {
        (value * pixel - 0.0001).rounded(.up) / pixel
    }
}

/// Pixel-snapped geometry of one card, in card coordinates (flipped, origin
/// top-left). Content-only: interaction state never changes it.
struct BoardCardLayout {
    static let width: CGFloat = 240
    static let padding: CGFloat = 12
    static let contentWidth: CGFloat = 216
    /// Board card corner radius: popupRadius(8) = 16.2pt, reduced by 3pt at
    /// the user's request (23/09/2026). Shared by both renderers.
    static let radius: CGFloat = Editorial.popupRadius(8) - 3
    static let titleLineHeight: CGFloat = BoardTextLine.metrics(BoardCardFonts.title).height
    static let titleBaseline: CGFloat = BoardTextLine.metrics(BoardCardFonts.title).baseline
    static let avatarSize: CGFloat = 18

    let height: CGFloat
    let topRowHeight: CGFloat
    let breadcrumb: BoardTextLine
    let chip: (text: BoardTextLine, width: CGFloat)?
    let titleLines: [CTLine]
    let titleY: CGFloat
    let footerY: CGFloat
    let avatarSlots: Int           // photos/initials drawn (≤ 3)
    let avatarOverflow: Int        // "+N" chip count, 0 when none
    let avatarStackWidth: CGFloat
    let name: BoardTextLine
    let date: BoardTextLine?

    /// Height only depends on the title and the priority chip, so columns can
    /// size thousands of cards without building their full layout.
    static func height(titleLineCount: Int, hasChip: Bool) -> CGFloat {
        let top = topRowHeight(hasChip: hasChip)
        let footer = avatarSize
        return padding + top + 10 + CGFloat(titleLineCount) * titleLineHeight + 10 + footer + padding
    }

    static func topRowHeight(hasChip: Bool) -> CGFloat {
        let bread = BoardTextLine.metrics(BoardCardFonts.breadcrumb).height
        guard hasChip else { return max(6, bread) }
        let chipH = BoardTextLine.metrics(BoardCardFonts.chip).height + 4
        return max(6, bread, chipH)
    }

    static func make(task: CUTask, workspaceName: String, pixel: CGFloat,
                     titleLines: [CTLine]? = nil) -> BoardCardLayout {
        let hasChip = BoardCardFormatting.showsPriorityChip(task.priority)
        let topH = topRowHeight(hasChip: hasChip)

        var chip: (BoardTextLine, CGFloat)?
        if hasChip {
            let label = BoardTextLine.make(BoardCardFormatting.priorityLabel(task.priority),
                                           font: BoardCardFonts.chip, kern: 0.6, pixel: pixel)
            chip = (label, 6 + 5 + 4 + label.width + 6)
        }
        let breadcrumbMax = contentWidth - 6 - 8 - 8 - 4 - (chip.map { 8 + $0.1 } ?? 0)
        let breadcrumb = BoardTextLine.make(
            BoardCardFormatting.breadcrumb(workspace: workspaceName, listName: task.listName),
            font: BoardCardFonts.breadcrumb, kern: 1.0, maxWidth: breadcrumbMax, pixel: pixel)

        let lines = titleLines ?? BoardTextLine.wrapped(task.title, font: BoardCardFonts.title,
                                                        width: contentWidth, maxLines: 3)
        let titleY = padding + topH + 10
        let footerY = titleY + CGFloat(lines.count) * titleLineHeight + 10

        let assignees = task.assignees
        let slots = assignees.isEmpty ? 1 : min(3, assignees.count)
        let overflow = assignees.count > 3 ? assignees.count - 3 : 0
        let items = slots + (overflow > 0 ? 1 : 0)
        let overlap = avatarSize * 0.34
        let stackWidth = pixelRound(CGFloat(items) * avatarSize - CGFloat(items - 1) * overlap, pixel)

        var date: BoardTextLine?
        var dateGroupWidth: CGFloat = 0
        if let due = task.dueDate {
            let line = BoardTextLine.make(BoardCardFormatting.relativeDate(due),
                                          font: BoardCardFonts.date, pixel: pixel)
            date = line
            dateGroupWidth = line.width + 3 + BoardCardArrow.frame.width
        }
        let nameMax = contentWidth - stackWidth - 8 - 8 - 4 - (date == nil ? 0 : 8 + dateGroupWidth)
        let name = BoardTextLine.make(BoardCardFormatting.firstName(task),
                                      font: BoardCardFonts.name, maxWidth: nameMax, pixel: pixel)

        return BoardCardLayout(
            height: height(titleLineCount: lines.count, hasChip: hasChip),
            topRowHeight: topH,
            breadcrumb: breadcrumb,
            chip: chip.map { (text: $0.0, width: $0.1) },
            titleLines: lines,
            titleY: titleY,
            footerY: footerY,
            avatarSlots: slots,
            avatarOverflow: overflow,
            avatarStackWidth: stackWidth,
            name: name,
            date: date)
    }

    static func pixelRound(_ value: CGFloat, _ pixel: CGFloat) -> CGFloat {
        (value * pixel).rounded() / pixel
    }
}

/// `Image(systemName: "arrow.turn.down.right").font(.system(size: 8, weight: .semibold))`.
enum BoardCardArrow {
    static let image: NSImage? = NSImage(systemSymbolName: "arrow.turn.down.right",
                                         accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
    /// SwiftUI frame measured for this symbol configuration.
    static let frame = CGSize(width: 9.5, height: 7.5)
}

/// Title typesetting cache. Heights of every card of a column depend on the
/// number of title lines; typesetting each distinct title once keeps column
/// layout proportional to changed titles, not to all cards.
final class BoardTitleCache {
    static let shared = BoardTitleCache()
    private final class Box { let lines: [CTLine]; init(_ l: [CTLine]) { lines = l } }
    private let cache = NSCache<NSString, Box>()

    init() { cache.countLimit = 20_000 }

    func lines(for title: String) -> [CTLine] {
        let key = title as NSString
        if let hit = cache.object(forKey: key) { return hit.lines }
        let lines = BoardTextLine.wrapped(title, font: BoardCardFonts.title,
                                          width: BoardCardLayout.contentWidth, maxLines: 3)
        cache.setObject(Box(lines), forKey: key)
        return lines
    }

    func height(for task: CUTask) -> CGFloat {
        BoardCardLayout.height(titleLineCount: lines(for: task.title).count,
                               hasChip: BoardCardFormatting.showsPriorityChip(task.priority))
    }
}
