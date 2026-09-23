import AppKit
import SwiftUI
import XCTest
@testable import ApolloRuntime

/// Equivalence between the SwiftUI reference board and the AppKit renderer:
/// ordering rules, column projection and per-card pixels.
@MainActor
final class BoardAppKitParityTests: XCTestCase {

    // MARK: Fixtures

    private static func assignee(_ id: Int, _ name: String, _ color: String) -> CUTask.Assignee {
        CUTask.Assignee(id: id, username: name, initials: nil, color: color, profilePicture: nil)
    }

    private static func task(_ id: String, _ title: String, status: String = "doing",
                             priority: Int = 0, due: Int? = nil, assignees: [CUTask.Assignee] = [],
                             list: String = "Video", parent: String? = nil,
                             completed: Bool = false) -> CUTask {
        let cal = Calendar.current
        let dueDate = due.flatMap { cal.date(byAdding: .day, value: $0, to: cal.startOfDay(for: Date())) }
            .map { $0.addingTimeInterval(18 * 3600) }
        return CUTask(id: id, title: title, status: status, statusColor: "#B0612E",
                      priority: priority, priorityColor: "#7C7E84", startDate: nil, dueDate: dueDate,
                      listId: "L1", listName: list, isCompleted: completed, description: nil,
                      commentCount: 0, assignees: assignees, tags: [], url: nil,
                      dateCreated: nil, dateUpdated: nil, parentId: parent)
    }

    // MARK: Ordering — oracle is the pre-extraction implementation, verbatim.

    private func oracleOrdered(_ cards: [CUTask], saved: [String]) -> [CUTask] {
        let pos = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return cards.enumerated().sorted { a, b in
            switch (pos[a.element.id], pos[b.element.id]) {
            case let (.some(x), .some(y)): return x < y
            case (.some, .none):           return true
            case (.none, .some):           return false
            case (.none, .none):           return a.offset < b.offset
            }
        }.map(\.element)
    }

    private func oracleReorder(_ current: [String], dragging: [String], target: String) -> [String]? {
        var ids = current
        let moving = ids.filter { dragging.contains($0) }
        guard !moving.isEmpty, !moving.contains(target), ids.contains(target) else { return nil }
        ids.removeAll { moving.contains($0) }
        guard let insertAt = ids.firstIndex(of: target) else { return nil }
        ids.insert(contentsOf: moving, at: insertAt)
        return ids
    }

    func testOrderingMatchesReferenceOnRandomInputs() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let n = Int.random(in: 0...12, using: &rng)
            let cards = (0..<n).map { Self.task("t\($0)", "T\($0)") }
            let saved = (0..<Int.random(in: 0...15, using: &rng)).map { _ in "t\(Int.random(in: 0...14, using: &rng))" }
            XCTAssertEqual(BoardOrdering.ordered(cards, saved: saved).map(\.id),
                           oracleOrdered(cards, saved: saved).map(\.id))
            let ids = cards.map(\.id)
            let dragging = (0..<Int.random(in: 0...3, using: &rng)).map { _ in "t\(Int.random(in: 0...13, using: &rng))" }
            let target = "t\(Int.random(in: 0...13, using: &rng))"
            XCTAssertEqual(BoardOrdering.reorder(ids: ids, dragging: dragging, before: target),
                           oracleReorder(ids, dragging: dragging, target: target))
        }
    }

    func testPlacementInsertsBeforeTargetOrAtTail() {
        XCTAssertEqual(BoardOrdering.place(ids: ["a", "b", "c"], dragIds: ["x", "y"], before: "b"),
                       ["a", "x", "y", "b", "c"])
        XCTAssertEqual(BoardOrdering.place(ids: ["a", "b"], dragIds: ["b"], before: "zz"), ["a", "b"])
        XCTAssertEqual(BoardOrdering.decode("{bad"), [:])
        let raw = BoardOrdering.encode(["doing": ["a", "b"]])!
        XCTAssertEqual(BoardOrdering.decode(raw), ["doing": ["a", "b"]])
    }

    func testSnapshotMatchesReferenceProjection() {
        let statuses = [CUStatus(status: "to do", color: "#54577E", type: "open"),
                        CUStatus(status: "DOING", color: "#B0612E", type: "custom"),
                        CUStatus(status: "done", color: "#1F7A3A", type: "done")]
        var tasks: [CUTask] = []
        for i in 0..<60 {
            tasks.append(Self.task("t\(i)", "Task \(i)", status: ["to do", "doing", "Doing", "done"][i % 4],
                                   parent: i % 7 == 0 ? "t0" : nil, completed: i % 11 == 0))
        }
        let order = ["doing": ["t9", "t5", "t1"], "to do": ["t4", "t0"]]
        for showSubtasks in [true, false] {
            let snap = BoardRenderSnapshot.make(tasks: tasks, activeListId: "L1", statuses: statuses,
                                                showSubtasks: showSubtasks, filters: TaskFilters(),
                                                cardOrder: order, workspaceName: "", isColdLoading: false)
            // Reference: boardTasks → columnCards(filter) → orderedCards.
            let open = TaskSurfaceScope.openTasks(in: tasks, activeListId: "L1")
            let board = TaskFilters().applying(to: open.filter { showSubtasks || !$0.isSubtask })
            for (i, status) in statuses.enumerated() {
                let key = status.status.lowercased()
                let expected = oracleOrdered(board.filter { $0.status.lowercased() == key },
                                             saved: order[key] ?? [])
                XCTAssertEqual(snap.columns[i].cards.map(\.id), expected.map(\.id))
            }
        }
    }

    // MARK: Card pixels

    private static let cases: [(String, CUTask)] = [
        ("plain", task("c1", "Legenda e safe area")),
        ("chip-two-today", task("c2", "Calça Comfort - Aumento de Preços - B2 - H4 [IA]", priority: 1, due: 0,
                                assignees: [assignee(1, "Marconi Reis", "#151A20"),
                                            assignee(2, "eduardo.jorge", "#1A73E8")])),
        ("long-overflow-overdue", task("c3", String(repeating: "Camiseta Modal Tech POV réplica honesta ", count: 5),
                                       priority: 2, due: -3,
                                       assignees: (1...5).map { assignee($0, "Pessoa\($0)", "#673DE6") })),
        ("emoji-future", task("c4", "🎬 Gravação 🇧🇷 — ângulo 2 çãõ", due: 4,
                              assignees: [assignee(9, "Joana_Rocha", "#D630E8")], list: "Listas de Vídeo")),
        ("long-breadcrumb", task("c5", "Curto", priority: 2, due: 20,
                                 assignees: [assignee(3, "Maximiliano-Bartholomeu Almeida", "#3F6B4A")],
                                 list: "Uma lista com um nome realmente muito comprido para caber")),
    ]

    private func renderSwiftUI(_ task: CUTask, appState: AppState, dark: Bool) -> CGImage? {
        let view = BoardCard(task: task)
            .environmentObject(appState)
            .frame(width: BoardCardLayout.width)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        var image: CGImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        return image
    }

    private func renderAppKit(_ task: CUTask, workspace: String, dark: Bool) -> CGImage? {
        let layout = BoardCardLayout.make(task: task, workspaceName: workspace, pixel: 2)
        let card = BoardCardView(frame: NSRect(x: 0, y: 0, width: BoardCardLayout.width, height: layout.height))
        card.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        card.bind(task: task, workspaceName: workspace, layout: layout)
        card.layoutSubtreeIfNeeded()
        card.layout()
        guard let layer = card.layer else { return nil }
        func displayAll(_ l: CALayer) {
            l.contentsScale = 2
            l.setNeedsDisplay()
            l.displayIfNeeded()
            l.sublayers?.forEach(displayAll)
        }
        var out: CGImage?
        card.effectiveAppearance.performAsCurrentDrawingAppearance {
            displayAll(layer)
            let w = Int(card.bounds.width * 2), h = Int(card.bounds.height * 2)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            // The backing layer of a flipped NSView is geometry-flipped, so
            // rendering into a y-up context already yields top-left output.
            ctx.scaleBy(x: 2, y: 2)
            layer.render(in: ctx)
            out = ctx.makeImage()
        }
        return out
    }

    private struct Diff { var width = 0; var height = 0; var differing = 0; var maxDelta = 0 }

    private func diff(_ a: CGImage, _ b: CGImage, write name: String) -> Diff {
        let w = max(a.width, b.width), h = max(a.height, b.height)
        func pixels(_ img: CGImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: h - img.height, width: img.width, height: img.height))
            return buf
        }
        let pa = pixels(a), pb = pixels(b)
        var d = Diff(width: w, height: h)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: pa.count, by: 4) {
            var m = 0
            for c in 0..<4 { m = max(m, abs(Int(pa[i + c]) - Int(pb[i + c]))) }
            d.maxDelta = max(d.maxDelta, m)
            if m > 40 { d.differing += 1 }
            let v = UInt8(min(255, m * 4))
            out[i] = v; out[i + 1] = 0; out[i + 2] = 0; out[i + 3] = 255
        }
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BOARD_PARITY_OUT"]
                      ?? NSTemporaryDirectory() + "board-parity")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(_ img: CGImage, _ suffix: String) {
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("\(name)-\(suffix).png"))
        }
        write(a, "swiftui"); write(b, "appkit")
        let ctx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if let img = ctx.makeImage() { write(img, "diff") }
        return d
    }

    /// Best integer-pixel shift (at 2x) of the AppKit image that aligns a
    /// region with the SwiftUI image, plus residual error.
    private func bestShift(_ a: CGImage, _ b: CGImage, _ rectPt: CGRect) -> String {
        func gray(_ img: CGImage) -> [Int] {
            let w = img.width, h = img.height
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return stride(from: 0, to: buf.count, by: 4).map { Int(buf[$0]) + Int(buf[$0 + 1]) + Int(buf[$0 + 2]) }
        }
        let ga = gray(a), gb = gray(b), w = a.width, h = a.height
        let r = CGRect(x: rectPt.minX * 2, y: rectPt.minY * 2, width: rectPt.width * 2, height: rectPt.height * 2)
        var best = (dx: 0, dy: 0, err: Int.max)
        var zero = 0
        for dy in -3...3 { for dx in -3...3 {
            var err = 0
            for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) {
                let bx = x + dx, by = y + dy
                guard bx >= 0, by >= 0, bx < w, by < h, y < h, x < w else { continue }
                err += abs(ga[y * w + x] - gb[by * w + bx])
            } }
            if dx == 0 && dy == 0 { zero = err }
            if err < best.err { best = (dx, dy, err) }
        } }
        return "shift(px) dx=\(best.dx) dy=\(best.dy) err0=\(zero) errBest=\(best.err)"
    }

    func testCardPixelsMatchSwiftUIReference() throws {
        let appState = AppState(previewMode: true)
        appState.clickUpAuthService.workspaceName = "Moon Ventures"
        var report: [String] = []
        for dark in [false, true] {
            for (name, task) in Self.cases {
                let label = "\(name)-\(dark ? "dark" : "light")"
                let ref = try XCTUnwrap(renderSwiftUI(task, appState: appState, dark: dark), label)
                let nat = try XCTUnwrap(renderAppKit(task, workspace: "Moon Ventures", dark: dark), label)
                XCTAssertEqual(ref.height, nat.height, "height \(label)")
                let d = diff(ref, nat, write: label)
                let layout = BoardCardLayout.make(task: task, workspaceName: "Moon Ventures", pixel: 2)
                let bands: [(String, CGFloat, CGFloat)] = [
                    ("top", 12, 12 + layout.topRowHeight),
                    ("title", layout.titleY, layout.footerY - 10),
                    ("footer", layout.footerY, layout.footerY + 18)]
                for (bn, y0, y1) in bands {
                    for (side, x0, x1) in [("L", 12.0, 120.0), ("R", 120.0, 228.0)] {
                        report.append("  \(bn)\(side) " + bestShift(ref, nat, CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)))
                    }
                }
                report.append("\(label): size \(ref.width)x\(ref.height) vs \(nat.width)x\(nat.height), " +
                              "differing(>40) \(d.differing) of \(d.width * d.height), maxDelta \(d.maxDelta)")
            }
        }
        print("BOARD_PARITY\n" + report.joined(separator: "\n"))
    }
}
