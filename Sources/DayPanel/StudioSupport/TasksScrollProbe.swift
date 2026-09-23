import AppKit
import QuartzCore
import CoreGraphics
import OSLog

/// Opt-in DEV measurements. No kernel tracing, screenshots or per-frame logs.
/// At most 15,000 samples in memory and one small JSON result per launch.
@MainActor
final class TasksScrollProbe: NSObject {
    #if APOLLO_DEV
    private static var current: TasksScrollProbe?
    private static let log = Logger(subsystem: "com.painellunar.app.dev", category: "TasksScroll")
    private weak var scroll: NSScrollView?
    private var link: CADisplayLink?
    private var eventMonitor: Any?
    private var wheelEvents = 0
    private var momentumEvents = 0
    private var preciseEvents = 0
    private var syntheticEvents = 0
    private var momentumActive = false
    private var momentumGaps: [Double] = []
    private var momentumMovingFrames = 0
    private var momentumDistance: CGFloat = 0
    private var viewport: [String: Any] = [:]
    private var display: [String: Any] = [:]
    private var measuredDisplayID: CGDirectDisplayID?
    private var displayChanged = false
    private var keyWindowFrames = 0
    private let output: URL
    private var start: CFTimeInterval = 0
    private var previousTime: CFTimeInterval = 0
    private var previousY: CGFloat = 0
    private var lastMovement: CFTimeInterval = 0
    private var gaps: [Double] = []
    private var scheduledGaps: [Double] = []
    private var previousTimestamp: CFTimeInterval = 0
    private var bindDurations: [Double] = []
    private var layoutDurations: [Double] = []
    private var distance: CGFloat = 0
    private var maxViews = 0
    private var minY: CGFloat = .greatestFiniteMagnitude
    private var maxY: CGFloat = 0
    private var frames = 0
    private var movingFrames = 0
    private let capacity = 15_000

    private init(scroll: NSScrollView, output: URL) {
        self.scroll = scroll
        self.output = output
    }
    #endif

    static func install(on scroll: NSScrollView) {
        #if APOLLO_DEV
        guard current == nil,
              ProcessInfo.processInfo.arguments.contains("--tasks-metrics")
        else { return }
        // Resolve inside this app's sandbox. Writing to the checkout from a
        // signed sandboxed DEV app fails without a user-selected security scope.
        guard let caches = FileManager.default.urls(for: .cachesDirectory,
                                                    in: .userDomainMask).first else { return }
        let directory = caches.appendingPathComponent("TasksScrollProbe", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Self.log.error("Tasks probe output unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }
        let probe = TasksScrollProbe(scroll: scroll,
                                     output: directory.appendingPathComponent("latest.json"))
        current = probe
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { probe.begin() }
        #endif
    }

    static func restart() {
        #if APOLLO_DEV
        guard let previous = current, previous.link == nil,
              let scroll = previous.scroll else { return }
        let probe = TasksScrollProbe(scroll: scroll, output: previous.output)
        current = probe
        DispatchQueue.main.async { probe.begin() }
        #endif
    }

    static func recordScrollEvent(_ event: NSEvent, window: NSWindow?, synthetic: Bool = false) {
        #if APOLLO_DEV
        guard let probe = current, probe.link != nil,
              let scroll = probe.scroll, window === scroll.window else { return }
        probe.wheelEvents += 1
        if !event.momentumPhase.isEmpty { probe.momentumEvents += 1 }
        if event.hasPreciseScrollingDeltas { probe.preciseEvents += 1 }
        if synthetic { probe.syntheticEvents += 1 }
        probe.momentumActive = !event.momentumPhase.isEmpty
            && !event.momentumPhase.contains(.ended) && !event.momentumPhase.contains(.cancelled)
        #endif
    }

    @inline(__always) static func beginWork() -> CFTimeInterval {
        #if APOLLO_DEV
        return current?.link != nil ? CACurrentMediaTime() : 0
        #else
        return 0
        #endif
    }

    @inline(__always) static func endWork(_ time: CFTimeInterval, layout: Bool) {
        #if APOLLO_DEV
        guard time > 0, let current else { return }
        let ms = (CACurrentMediaTime() - time) * 1000
        if layout {
            if current.layoutDurations.count < current.capacity { current.layoutDurations.append(ms) }
        } else if current.bindDurations.count < current.capacity {
            current.bindDurations.append(ms)
        }
        #endif
    }

    #if APOLLO_DEV
    private func begin() {
        guard let scroll, scroll.window != nil else {
            Self.log.error("Tasks probe has no window; measurement not started")
            return
        }
        guard let screen = scroll.window?.screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              CGDisplayIsBuiltin(number.uint32Value) != 0,
              screen.maximumFramesPerSecond >= 120 else {
            Self.log.error("Tasks probe refused: requires the internal 120 Hz display")
            return
        }
        measuredDisplayID = number.uint32Value
        display = ["name": screen.localizedName, "builtin": true,
                   "max_hz": screen.maximumFramesPerSecond, "scale": screen.backingScaleFactor]
        do {
            try Data("{\"state\":\"recording\"}\n".utf8).write(to: output, options: .atomic)
        } catch {
            Self.log.error("Tasks probe not started; output unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }
        viewport = ["scroll_layer": scroll.layer != nil,
                    "clip_layer": scroll.contentView.layer != nil,
                    "document_layer": scroll.documentView?.layer != nil,
                    "scroll_responsive": type(of: scroll).isCompatibleWithResponsiveScrolling,
                    "clip_responsive": type(of: scroll.contentView).isCompatibleWithResponsiveScrolling]
        if let document = scroll.documentView {
            viewport["document_responsive"] = type(of: document).isCompatibleWithResponsiveScrolling
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            Self.recordScrollEvent(event, window: event.window,
                                   synthetic: event.cgEvent?.getIntegerValueField(.eventSourceUserData) == BoardScrollDriver.eventTag)
            return event
        }
        start = CACurrentMediaTime()
        previousY = scroll.contentView.bounds.minY
        link = scroll.displayLink(target: self, selector: #selector(frame(_:)))
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link?.add(to: .main, forMode: .common)
        Self.log.notice("Tasks probe started on internal 120 Hz display; 45 second limit")
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in self?.finish() }
    }

    @objc private func frame(_ link: CADisplayLink) {
        guard let scroll else { finish(); return }
        let screenNumber = scroll.window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard screenNumber?.uint32Value == measuredDisplayID else {
            displayChanged = true
            finish()
            return
        }
        if scroll.window?.isKeyWindow == true { keyWindowFrames += 1 }
        let now = CACurrentMediaTime()
        let y = scroll.contentView.bounds.minY
        let delta = abs(y - previousY)
        if delta > 0.01 {
            lastMovement = now
            movingFrames += 1
            if momentumActive { momentumMovingFrames += 1; momentumDistance += delta }
        }
        distance += delta
        minY = min(minY, y)
        maxY = max(maxY, y)
        // Retain the tail of scrolling so a missed callback isn't excluded
        // merely because a short gesture stopped before the next callback.
        if now - lastMovement < 0.15, previousTime > 0, gaps.count < capacity {
            gaps.append((now - previousTime) * 1000)
            scheduledGaps.append((link.timestamp - previousTimestamp) * 1000)
            if momentumActive, momentumGaps.count < capacity { momentumGaps.append((now - previousTime) * 1000) }
        }
        previousY = y
        previousTime = now
        previousTimestamp = link.timestamp
        frames += 1
        maxViews = max(maxViews, scroll.documentView?.subviews.count ?? 0)
    }

    private func summary(_ samples: [Double]) -> [String: Any] {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return ["count": 0] }
        func percentile(_ p: Double) -> Double { sorted[Int(Double(sorted.count - 1) * p)] }
        return ["count": sorted.count, "p50_ms": percentile(0.5),
                "p95_ms": percentile(0.95), "p99_ms": percentile(0.99),
                "max_ms": sorted.last!, "over_16_7ms": sorted.filter { $0 > 16.7 }.count,
                "over_33_4ms": sorted.filter { $0 > 33.4 }.count]
    }

    private func finish() {
        guard link != nil else { return }
        link?.invalidate()
        link = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        let result: [String: Any] = [
            "state": displayChanged ? "invalid_display_changed" : "complete", "seconds": CACurrentMediaTime() - start,
            "frames": frames, "moving_frames": movingFrames,
            "travelled_points": distance, "min_y": minY, "max_y": maxY,
            "max_document_subviews": maxViews,
            "wheel_events": wheelEvents, "momentum_events": momentumEvents,
            "momentum_moving_frames": momentumMovingFrames, "momentum_points": momentumDistance,
            "precise_events": preciseEvents, "synthetic_events": syntheticEvents, "viewport": viewport,
            "display": display, "key_window_frames": keyWindowFrames,
            "callback_intervals_while_scrolling": summary(gaps),
            "scheduled_intervals_while_scrolling": summary(scheduledGaps),
            "row_bind_cpu": summary(bindDurations), "row_layout_cpu": summary(layoutDurations),
            "momentum_callback_intervals": summary(momentumGaps),
            "qualification": "Display-link callback cadence and row CPU, not presented-frame FPS. Scroll movement is verified from clip bounds."
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output, options: .atomic)
            // Small aggregate records avoid unified logging's message truncation.
            // No task content, identity or paths. A single report per launch.
            var totals = result
            for key in ["callback_intervals_while_scrolling", "scheduled_intervals_while_scrolling",
                        "row_bind_cpu", "row_layout_cpu", "momentum_callback_intervals"] {
                let part = try JSONSerialization.data(withJSONObject: [key: totals.removeValue(forKey: key)!],
                                                     options: [.sortedKeys])
                Self.log.notice("Tasks probe stats: \(String(decoding: part, as: UTF8.self), privacy: .public)")
            }
            let totalsData = try JSONSerialization.data(withJSONObject: totals, options: [.sortedKeys])
            Self.log.notice("Tasks probe totals: \(String(decoding: totalsData, as: UTF8.self), privacy: .public)")
        } catch { Self.log.error("Tasks probe could not save summary: \(error.localizedDescription)") }
    }
    #endif
}
