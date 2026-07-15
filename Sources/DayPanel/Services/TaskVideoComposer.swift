import AVFoundation
import CoreGraphics
import Foundation

actor TaskVideoComposer {
    enum ComposerError: LocalizedError {
        case missingVideoTrack(String)
        case invalidDuration(String)
        case cannotCreateTrack
        case cannotCreateExporter
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingVideoTrack(let name): return "\(name) não contém uma faixa de vídeo."
            case .invalidDuration(let name): return "A duração de \(name) é inválida."
            case .cannotCreateTrack: return "Não foi possível montar a composição."
            case .cannotCreateExporter: return "Este Mac não conseguiu iniciar o exportador HEVC."
            case .exportFailed(let message): return "Falha ao renderizar: \(message)"
            }
        }
    }

    struct Geometry: Equatable, Sendable {
        let renderSize: CGSize
        let hookTransform: CGAffineTransform
        let bodyTransform: CGAffineTransform
    }

    static func geometry(hookNaturalSize: CGSize, hookPreferredTransform: CGAffineTransform,
                         bodyNaturalSize: CGSize, bodyPreferredTransform: CGAffineTransform) -> Geometry {
        let bodyNormalized = normalizedTransform(naturalSize: bodyNaturalSize,
                                                 preferred: bodyPreferredTransform)
        let bodyBounds = CGRect(origin: .zero, size: bodyNaturalSize).applying(bodyNormalized)
        let render = CGSize(width: even(bodyBounds.width), height: even(bodyBounds.height))

        let bodyScale = min(render.width / max(1, bodyBounds.width),
                            render.height / max(1, bodyBounds.height))
        let bodyScaled = bodyBounds.size.applying(CGAffineTransform(scaleX: bodyScale, y: bodyScale))
        let bodyCenter = CGAffineTransform(translationX: (render.width - abs(bodyScaled.width)) / 2,
                                           y: (render.height - abs(bodyScaled.height)) / 2)
        let finalBody = bodyNormalized
            .concatenating(CGAffineTransform(scaleX: bodyScale, y: bodyScale))
            .concatenating(bodyCenter)

        let hookNormalized = normalizedTransform(naturalSize: hookNaturalSize,
                                                 preferred: hookPreferredTransform)
        let hookBounds = CGRect(origin: .zero, size: hookNaturalSize).applying(hookNormalized)
        let fill = max(render.width / max(1, hookBounds.width),
                       render.height / max(1, hookBounds.height))
        let filled = CGSize(width: hookBounds.width * fill, height: hookBounds.height * fill)
        let center = CGAffineTransform(translationX: (render.width - filled.width) / 2,
                                       y: (render.height - filled.height) / 2)
        let finalHook = hookNormalized
            .concatenating(CGAffineTransform(scaleX: fill, y: fill))
            .concatenating(center)
        return Geometry(renderSize: render, hookTransform: finalHook, bodyTransform: finalBody)
    }

    func compose(hookURL: URL, bodyURL: URL, outputURL: URL,
                 onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        let hook = AVURLAsset(url: hookURL)
        let body = AVURLAsset(url: bodyURL)
        guard let hookTrack = try await hook.loadTracks(withMediaType: .video).first else {
            throw ComposerError.missingVideoTrack(hookURL.lastPathComponent)
        }
        guard let bodyTrack = try await body.loadTracks(withMediaType: .video).first else {
            throw ComposerError.missingVideoTrack(bodyURL.lastPathComponent)
        }
        let hookDuration = try await hook.load(.duration)
        let bodyDuration = try await body.load(.duration)
        guard hookDuration.isNumeric && hookDuration.seconds > 0 else {
            throw ComposerError.invalidDuration(hookURL.lastPathComponent)
        }
        guard bodyDuration.isNumeric && bodyDuration.seconds > 0 else {
            throw ComposerError.invalidDuration(bodyURL.lastPathComponent)
        }

        async let hookNatural = hookTrack.load(.naturalSize)
        async let hookPreferred = hookTrack.load(.preferredTransform)
        async let bodyNatural = bodyTrack.load(.naturalSize)
        async let bodyPreferred = bodyTrack.load(.preferredTransform)
        async let bodyRate = bodyTrack.load(.nominalFrameRate)
        let geometry = Self.geometry(hookNaturalSize: try await hookNatural,
                                     hookPreferredTransform: try await hookPreferred,
                                     bodyNaturalSize: try await bodyNatural,
                                     bodyPreferredTransform: try await bodyPreferred)

        let composition = AVMutableComposition()
        guard let hookCompositionTrack = composition.addMutableTrack(withMediaType: .video,
                                                                      preferredTrackID: kCMPersistentTrackID_Invalid),
              let bodyCompositionTrack = composition.addMutableTrack(withMediaType: .video,
                                                                      preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ComposerError.cannotCreateTrack }
        try hookCompositionTrack.insertTimeRange(CMTimeRange(start: .zero, duration: hookDuration),
                                                 of: hookTrack, at: .zero)
        try bodyCompositionTrack.insertTimeRange(CMTimeRange(start: .zero, duration: bodyDuration),
                                                 of: bodyTrack, at: hookDuration)

        if let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid) {
            if let hookAudio = try await hook.loadTracks(withMediaType: .audio).first {
                try? audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: hookDuration),
                                                of: hookAudio, at: .zero)
            }
            if let bodyAudio = try await body.loadTracks(withMediaType: .audio).first {
                try? audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: bodyDuration),
                                                of: bodyAudio, at: hookDuration)
            }
        }

        let hookLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: hookCompositionTrack)
        hookLayer.setTransform(geometry.hookTransform, at: .zero)
        let hookInstruction = AVMutableVideoCompositionInstruction()
        hookInstruction.timeRange = CMTimeRange(start: .zero, duration: hookDuration)
        hookInstruction.layerInstructions = [hookLayer]

        let bodyLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: bodyCompositionTrack)
        bodyLayer.setTransform(geometry.bodyTransform, at: hookDuration)
        let bodyInstruction = AVMutableVideoCompositionInstruction()
        bodyInstruction.timeRange = CMTimeRange(start: hookDuration, duration: bodyDuration)
        bodyInstruction.layerInstructions = [bodyLayer]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = geometry.renderSize
        let loadedBodyRate = try await bodyRate
        let fps = max(1, min(120, Double(loadedBodyRate == 0 ? 30 : loadedBodyRate)))
        videoComposition.frameDuration = CMTime(seconds: 1 / fps, preferredTimescale: 60_000)
        videoComposition.instructions = [hookInstruction, bodyInstruction]

        try? FileManager.default.removeItem(at: outputURL)
        guard let exporter = AVAssetExportSession(asset: composition,
                                                   presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw ComposerError.cannotCreateExporter
        }
        exporter.videoComposition = videoComposition
        exporter.outputURL = outputURL
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = true

        let progressTask = Task {
            while !Task.isCancelled && (exporter.status == .waiting || exporter.status == .exporting) {
                onProgress?(Double(exporter.progress))
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
        await withCheckedContinuation { continuation in
            exporter.exportAsynchronously { continuation.resume() }
        }
        progressTask.cancel()
        switch exporter.status {
        case .completed:
            onProgress?(1)
        case .cancelled:
            throw CancellationError()
        default:
            throw ComposerError.exportFailed(exporter.error?.localizedDescription ?? "erro desconhecido")
        }
    }

    private static func normalizedTransform(naturalSize: CGSize,
                                            preferred: CGAffineTransform) -> CGAffineTransform {
        let source = CGRect(origin: .zero, size: naturalSize)
        let transformed = source.applying(preferred)
        return preferred.concatenating(
            CGAffineTransform(translationX: -transformed.minX, y: -transformed.minY)
        )
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        let rounded = max(2, Int(value.rounded()))
        return CGFloat(rounded.isMultiple(of: 2) ? rounded : rounded + 1)
    }
}

private extension CGSize {
    func applying(_ transform: CGAffineTransform) -> CGSize {
        CGRect(origin: .zero, size: self).applying(transform).size
    }
}
