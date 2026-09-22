import XCTest
import AVFoundation
import CoreVideo
@testable import ApolloRuntime

/// Hook e body sem faixa de áudio.
///
/// O compositor criava a faixa de áudio da composição sempre, e com os
/// dois clipes mudos ela ficava vazia — o exportador HEVC recusava a
/// composição inteira com -11838 "Operation Stopped", e a pessoa via
/// "Falha ao renderizar" sem entender por quê.
final class TaskVideoComposerSilentClipTests: XCTestCase {

    func testSilentHookAndBodyCompose() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-silent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let hook = dir.appendingPathComponent("H1.mp4")
        let body = dir.appendingPathComponent("B1.mp4")
        let out = dir.appendingPathComponent("out.mov")
        try await writeSilentClip(to: hook, seconds: 1)
        try await writeSilentClip(to: body, seconds: 2)

        try await TaskVideoComposer().compose(hookURL: hook, bodyURL: body, outputURL: out)

        let result = AVURLAsset(url: out)
        let duration = try await result.load(.duration).seconds
        let audio = try await result.loadTracks(withMediaType: .audio)
        let video = try await result.loadTracks(withMediaType: .video)
        XCTAssertEqual(duration, 3, accuracy: 0.1)
        XCTAssertTrue(audio.isEmpty)
        XCTAssertEqual(video.count, 1)
    }

    /// Clipe H.264 de 480×854 só com vídeo, quadros cinza.
    private func writeSilentClip(to url: URL, seconds: Int) async throws {
        let width = 480, height = 854, fps: Int32 = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<(seconds * Int(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), 0x80,
                   CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame),
                                                                timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
