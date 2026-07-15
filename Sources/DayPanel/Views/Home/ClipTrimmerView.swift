import AVFoundation
import AppKit
import SwiftUI

/// QuickTime-style clip trimmer used by the media flow. A live preview sits on
/// top of a filmstrip timeline with two drag handles; applying the trim exports
/// the selected range to a temp `.mov` that the caller then classifies as a
/// HOOK or BODY. Vertical (Reels) and horizontal clips both fit via aspect-fit.
struct ClipTrimmerView: View {
    @StateObject private var model: ClipTrimModel
    var onCancel: () -> Void
    var onApply: (URL) -> Void

    init(url: URL, onCancel: @escaping () -> Void, onApply: @escaping (URL) -> Void) {
        _model = StateObject(wrappedValue: ClipTrimModel(url: url))
        self.onCancel = onCancel
        self.onApply = onApply
    }

    enum Handle { case left, right }

    var body: some View {
        VStack(spacing: 14) {
            preview
            timeline
            controls
            if let err = model.errorText {
                Text(err)
                    .font(Editorial.sans(11, .medium))
                    .foregroundStyle(Editorial.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.load() }
        .onDisappear { model.teardown() }
        .overlay { if model.exporting { exportOverlay } }
    }

    // MARK: Preview

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black)
            PlayerLayerView(player: model.player)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if !model.isPlaying {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.4), radius: 6)
            }
            if !model.isReady {
                ProgressView().controlSize(.small).tint(.white)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .contentShape(Rectangle())
        .onTapGesture { model.togglePlay() }
    }

    // MARK: Timeline

    private var timeline: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                filmstrip(width: w)

                // Dim the trimmed-away head and tail.
                Path { p in
                    p.addRect(CGRect(x: 0, y: 0, width: model.startFraction * w, height: 56))
                    p.addRect(CGRect(x: model.endFraction * w, y: 0,
                                     width: (1 - model.endFraction) * w, height: 56))
                }
                .fill(Color.black.opacity(0.55))
                .allowsHitTesting(false)

                // Kept-range frame.
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Editorial.accent, lineWidth: 2.5)
                    .frame(width: max(0, (model.endFraction - model.startFraction) * w), height: 56)
                    .offset(x: model.startFraction * w)
                    .allowsHitTesting(false)

                // Playhead.
                Capsule().fill(Color.white)
                    .frame(width: 2.5, height: 64)
                    .offset(x: min(max(model.playhead * w - 1.25, 0), w - 2.5), y: -4)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .allowsHitTesting(false)

                handle(.left).offset(x: min(max(model.startFraction * w - 11, -2), w - 20))
                handle(.right).offset(x: min(max(model.endFraction * w - 11, -2), w - 20))
            }
            .frame(width: w, height: 56)
            .coordinateSpace(name: Self.trackSpace)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.trackSpace))
                    .onChanged { v in model.drag(toX: v.location.x, width: w) }
                    .onEnded { _ in model.endDrag() }
            )
        }
        .frame(height: 56)
    }

    private static let trackSpace = "clipTrimTrack"

    private func filmstrip(width w: CGFloat) -> some View {
        HStack(spacing: 0) {
            if model.thumbnails.isEmpty {
                Rectangle().fill(Editorial.card)
            } else {
                ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, img in
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: w / CGFloat(model.thumbnails.count), height: 56)
                        .clipped()
                }
            }
        }
        .frame(width: w, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Editorial.rule))
    }

    private func handle(_ side: Handle) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Editorial.accent)
            .frame(width: 22, height: 64)
            .overlay(
                Image(systemName: side == .left ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            )
            .offset(y: -4)
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .allowsHitTesting(false)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Editorial.ink)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Editorial.card))
                    .overlay(Circle().strokeBorder(Editorial.rule))
            }
            .buttonStyle(.plain)
            .focusable(false)

            VStack(alignment: .leading, spacing: 1) {
                Text("\(timeLabel(model.startTime)) – \(timeLabel(model.endTime))")
                    .font(Editorial.sans(12, .semibold)).foregroundStyle(Editorial.ink)
                    .monospacedDigit()
                Text("Trecho de \(timeLabel(model.trimmedDuration))")
                    .font(Editorial.sans(10.5)).foregroundStyle(Editorial.inkMute)
            }

            Spacer(minLength: 8)

            Button { model.teardown(); onCancel() } label: {
                Text("Cancelar")
                    .font(Editorial.sans(11.5, .medium))
                    .foregroundStyle(Editorial.ink)
                    .padding(.horizontal, 15).frame(height: 34)
                    .background(Capsule().fill(Editorial.card))
                    .overlay(Capsule().strokeBorder(Editorial.rule))
            }
            .buttonStyle(.plain)
            .focusable(false)

            Button {
                Task {
                    if let out = await model.export() { onApply(out) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "scissors")
                    Text("APLICAR CORTE")
                }
                .font(Editorial.sans(11.5, .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18).frame(height: 34)
                .background(Capsule().fill(Editorial.accent))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disabled(!model.isReady || model.trimmedDuration < 0.15)
            .opacity((!model.isReady || model.trimmedDuration < 0.15) ? 0.5 : 1)
        }
    }

    private var exportOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 10) {
                ProgressView(value: model.exportProgress).frame(width: 180).tint(.white)
                Text("Cortando… \(Int(model.exportProgress * 100))%")
                    .font(Editorial.sans(11.5, .medium)).foregroundStyle(.white)
            }
            .padding(22)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.65)))
        }
    }

    private func timeLabel(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00.0" }
        let whole = Int(s)
        let m = whole / 60, sec = whole % 60
        let tenths = Int((s - Double(whole)) * 10)
        return String(format: "%d:%02d.%d", m, sec, tenths)
    }
}

// MARK: - Player layer

private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        return view
    }
    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        nsView.playerLayer.player = player
    }
}

private final class PlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        playerLayer.videoGravity = .resizeAspect
        playerLayer.frame = bounds
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

// MARK: - Model

final class ClipTrimModel: ObservableObject {
    let url: URL
    let player = AVPlayer()

    @Published var duration: Double = 0
    @Published var startFraction: Double = 0
    @Published var endFraction: Double = 1
    @Published var playhead: Double = 0
    @Published var isPlaying = false
    @Published var isReady = false
    @Published var thumbnails: [NSImage] = []
    @Published var exporting = false
    @Published var exportProgress: Double = 0
    @Published var errorText: String?

    private var observer: Any?
    private var activeHandle: ClipTrimmerView.Handle?

    var startTime: Double { startFraction * duration }
    var endTime: Double { endFraction * duration }
    var trimmedDuration: Double { max(0, endTime - startTime) }
    /// Keep the kept-range from collapsing below ~0.3s.
    private var minFraction: Double { duration > 0 ? min(0.3 / duration, 0.5) : 0.05 }

    init(url: URL) { self.url = url }

    @MainActor
    func load() async {
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration))?.seconds ?? 0
        duration = seconds.isFinite ? seconds : 0
        startFraction = 0; endFraction = 1; playhead = 0
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        addObserver()
        isReady = duration > 0
        await generateThumbnails(asset: asset)
    }

    private func addObserver() {
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.033, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let s = time.seconds
            guard self.duration > 0, s.isFinite else { return }
            self.playhead = min(max(s / self.duration, 0), 1)
            if self.isPlaying, s >= self.endTime - 0.03 {
                self.player.seek(to: CMTime(seconds: self.startTime, preferredTimescale: 600),
                                 toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    @MainActor
    private func generateThumbnails(asset: AVURLAsset) async {
        guard duration > 0 else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.4, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.4, preferredTimescale: 600)
        let count = 10
        var frames: [NSImage] = []
        for i in 0..<count {
            let t = duration * (Double(i) + 0.5) / Double(count)
            if let cg = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                frames.append(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
            }
        }
        thumbnails = frames
    }

    func togglePlay() {
        guard isReady else { return }
        if isPlaying {
            player.pause(); isPlaying = false
        } else {
            if playhead < startFraction || playhead >= endFraction - 0.001 {
                player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
            }
            player.play(); isPlaying = true
        }
    }

    func drag(toX x: Double, width w: Double) {
        guard w > 0, duration > 0 else { return }
        let f = min(max(x / w, 0), 1)
        if activeHandle == nil {
            activeHandle = abs(f - startFraction) <= abs(f - endFraction) ? .left : .right
        }
        if isPlaying { player.pause(); isPlaying = false }
        if activeHandle == .left {
            startFraction = min(max(0, f), endFraction - minFraction)
            seekPreview(startFraction)
        } else {
            endFraction = max(min(1, f), startFraction + minFraction)
            seekPreview(endFraction)
        }
    }

    func endDrag() {
        activeHandle = nil
        seekPreview(startFraction)
    }

    private func seekPreview(_ fraction: Double) {
        guard duration > 0 else { return }
        player.seek(to: CMTime(seconds: fraction * duration, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        playhead = fraction
    }

    @MainActor
    func export() async -> URL? {
        guard duration > 0, trimmedDuration > 0.05 else { return nil }
        player.pause(); isPlaying = false
        exporting = true; exportProgress = 0; errorText = nil
        defer { exporting = false }

        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            errorText = "Não foi possível preparar o corte."
            return nil
        }
        let stem = url.deletingPathExtension().lastPathComponent
        let safeStem = stem.isEmpty ? "clipe" : stem
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeStem)-corte-\(UUID().uuidString.prefix(6)).mov")
        session.outputURL = out
        session.outputFileType = .mov
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: startTime, preferredTimescale: 600),
            end: CMTime(seconds: endTime, preferredTimescale: 600)
        )

        let progress = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.exportProgress = Double(session.progress)
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        progress.cancel()

        if session.status == .completed {
            exportProgress = 1
            return out
        }
        errorText = session.error?.localizedDescription ?? "Falha ao cortar o clipe."
        return nil
    }

    func teardown() {
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        player.pause()
    }
}
