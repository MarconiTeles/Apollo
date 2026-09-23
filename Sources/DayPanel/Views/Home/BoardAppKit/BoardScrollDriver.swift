#if APOLLO_DEV
import AppKit
import QuartzCore
import OSLog

/// DEV-only reproducible scroll workload: `--board-autoscroll=<seconds>`.
///
/// Feeds the key window a real phased scroll-wheel sequence (touch drag
/// `.began/.changed/.ended` followed by a decaying momentum tail at 120 Hz),
/// alternating direction, over the busiest visible board column. Works with
/// both renderers and never touches data. Events target only this DEV process.
/// Display-link callback statistics are a scheduling signal, not presented FPS.
@MainActor
final class BoardScrollDriver: NSObject {
    static var shared: BoardScrollDriver?
    static let eventTag: Int64 = 0x41504F4C4C4F
    private static let log = Logger(subsystem: "com.painellunar.app.dev", category: "TasksDriver")
    private var directTasksDelivery: Bool {
        ApolloDevLaunchOptions.initialRoute == .tasks
            && ProcessInfo.processInfo.arguments.contains("--tasks-direct-scroll")
    }

    static func startIfRequested(window: NSWindow?) {
        guard shared == nil,
              let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--board-autoscroll=") }),
              let seconds = Double(arg.split(separator: "=").last ?? "") else { return }
        let axis = ProcessInfo.processInfo.arguments.contains("--board-autoscroll-axis=horizontal")
            ? Axis.horizontal : Axis.vertical
        let driver = BoardScrollDriver(duration: seconds, axis: axis)
        shared = driver
        driver.mainWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { driver.start() }
    }

    enum Axis { case vertical, horizontal }

    private let duration: Double
    private let axis: Axis
    private var timer: Timer?
    private var startTime: CFTimeInterval = 0
    private var phaseStep = 0
    private var velocity: Double = 0
    private var direction: Double = -1
    private var stage = 0          // 0 drag, 1 momentum, 2 pause
    private var target: CGPoint = .zero
    private var link: CADisplayLink?
    private weak var scrollView: NSScrollView?
    private weak var mainWindow: NSWindow?
    private var travelled: CGFloat = 0
    private var lastOrigin: CGPoint?
    private var frameTimes: [CFTimeInterval] = []

    init(duration: Double, axis: Axis) {
        self.duration = duration
        self.axis = axis
    }

    private func start() {
        guard let window = mainWindow, window.isVisible,
              let content = window.contentView else {
            Self.log.error("Native workload refused: no visible main window")
            return
        }
        guard directTasksDelivery || CGPreflightPostEventAccess() else {
            NSLog("[Apollo DEV] native scroll benchmark blocked: PostEvent permission denied; no events sent")
            Self.log.error("Native workload refused: PostEvent permission denied")
            return
        }
        // The task-list benchmark was explicitly requested on the internal
        // 120 Hz panel. Position before sending any test event, then verify.
        if ApolloDevLaunchOptions.initialRoute == .tasks {
            guard let screen = NSScreen.screens.first(where: { screen in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                return CGDisplayIsBuiltin(id.uint32Value) != 0 && screen.maximumFramesPerSecond >= 120
            }) else { NSLog("[Apollo DEV] tasks benchmark refused: no internal 120 Hz panel"); return }
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.midY - window.frame.height / 2))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            let displayKey = NSDeviceDescriptionKey("NSScreenNumber")
            guard window.screen?.deviceDescription[displayKey] as? NSNumber
                    == screen.deviceDescription[displayKey] as? NSNumber else {
                Self.log.error("Native workload refused: window did not move to internal display")
                return
            }
            TasksScrollProbe.restart()
        }
        // Middle of the content area, 40% down: over the board columns.
        let local = NSPoint(x: content.bounds.width * 0.45, y: content.bounds.height * 0.45)
        let inWindow = content.convert(local, to: nil)
        let screen = window.convertPoint(toScreen: inWindow)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        target = CGPoint(x: screen.x, y: primaryHeight - screen.y)
        scrollView = content.hitTest(content.convert(inWindow, from: nil))?.enclosingScrollView
        if ApolloDevLaunchOptions.initialRoute == .tasks {
            func taskScroll(in view: NSView) -> NSScrollView? {
                if let viewport = view as? MyTasksViewport { return viewport.enclosingScrollView }
                return view.subviews.lazy.compactMap(taskScroll).first
            }
            scrollView = taskScroll(in: content)
            guard scrollView != nil else {
                Self.log.error("Tasks driver refused: native viewport missing")
                return
            }
        }
        startTime = CACurrentMediaTime()
        link = content.displayLink(target: self, selector: #selector(frame(_:)))
        link?.add(to: .main, forMode: .common)
        timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(window) }
        }
        RunLoop.main.add(timer!, forMode: .common)
        NSLog("[Apollo DEV] autoscroll start %.0fs axis=%@", duration, axis == .vertical ? "v" : "h")
        Self.log.notice("Native workload started; duration=\(self.duration); direct=\(self.directTasksDelivery)")
    }

    @objc private func frame(_ link: CADisplayLink) {
        if frameTimes.count < 15_000 { frameTimes.append(link.timestamp) }
        if let origin = scrollView?.contentView.bounds.origin {
            if let last = lastOrigin { travelled += abs(origin.y - last.y) + abs(origin.x - last.x) }
            lastOrigin = origin
        }
    }

    private func post(_ window: NSWindow, delta: Double, phase: Int64, momentum: Int64) {
        let dy = axis == .vertical ? Int32(delta.rounded()) : 0
        let dx = axis == .horizontal ? Int32(delta.rounded()) : 0
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                               wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        cg.location = target
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                                value: Int64(window.windowNumber))
        cg.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: axis == .vertical ? delta : 0)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: axis == .horizontal ? delta : 0)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        if directTasksDelivery,
           let event = NSEvent(cgEvent: cg), let scrollView {
            // Bounded in-process workload for the native viewport. This
            // deliberately bypasses OS event routing; the probe labels every
            // event synthetic so it cannot be mistaken for trackpad input.
            TasksScrollProbe.recordScrollEvent(event, window: window, synthetic: true)
            scrollView.scrollWheel(with: event)
            return
        }
        // A process-targeted event needs its target window as well. Keep the
        // route inside this DEV process and through AppKit's event monitors.
        cg.postToPid(ProcessInfo.processInfo.processIdentifier)
    }

    private func tick(_ window: NSWindow) {
        if ApolloDevLaunchOptions.initialRoute == .tasks {
            guard let screen = window.screen,
                  let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  CGDisplayIsBuiltin(id.uint32Value) != 0,
                  screen.maximumFramesPerSecond >= 120 else { finish(); return }
        }
        if CACurrentMediaTime() - startTime > duration { finish(); return }
        switch stage {
        case 0:
            // 18 × 8.3 ms finger drag at ~3600 pt/s, then release.
            let phase: Int64 = phaseStep == 0 ? 1 : (phaseStep < 18 ? 2 : 4)
            post(window, delta: phase == 4 ? 0 : direction * 30, phase: phase, momentum: 0)
            phaseStep += 1
            if phaseStep > 18 { stage = 1; phaseStep = 0; velocity = 30 }
        case 1:
            let momentum: Int64 = phaseStep == 0 ? 1 : 2
            velocity *= 0.975
            if velocity < 0.6 {
                post(window, delta: 0, phase: 0, momentum: 3)
                stage = 2; phaseStep = 0
            } else {
                post(window, delta: direction * velocity, phase: 0, momentum: momentum)
                phaseStep += 1
            }
        default:
            phaseStep += 1
            if phaseStep > 24 { stage = 0; phaseStep = 0; direction = -direction }
        }
    }

    private func finish() {
        timer?.invalidate(); timer = nil
        link?.invalidate(); link = nil
        let gaps = zip(frameTimes.dropFirst(), frameTimes).map { $0 - $1 }.sorted()
        guard !gaps.isEmpty else { return }
        func pct(_ p: Double) -> Double { gaps[min(gaps.count - 1, Int(Double(gaps.count) * p))] * 1000 }
        let period = pct(0.5) / 1000
        let late = gaps.filter { $0 > period * 1.5 }
        let hitchMs = late.reduce(0) { $0 + ($1 - period) } * 1000
        let span = (frameTimes.last ?? 0) - (frameTimes.first ?? 0)
        let line = String(format: "autoscroll frames=%d span=%.2fs p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms late=%d hitchRatio=%.1fms/s travelled=%.0fpt scrollView=%@ renderer=%@\n",
              frameTimes.count, span, pct(0.5), pct(0.95), pct(0.99), (gaps.last ?? 0) * 1000,
              late.count, span > 0 ? hitchMs / span : 0, travelled,
              scrollView.map { String(describing: type(of: $0)) } ?? "none",
              ApolloDevLaunchOptions.boardRenderer ?? "swiftui")
        NSLog("[Apollo DEV] %@", line)
        Self.log.notice("\(line, privacy: .public)")
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("board-autoscroll.log")
        if let data = line.data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
            else { try? data.write(to: url) }
        }
    }
}
#endif
