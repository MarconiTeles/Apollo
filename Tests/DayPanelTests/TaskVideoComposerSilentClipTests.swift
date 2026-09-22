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


    func testAudioOnHookOnlyKeepsAudioAtBeginning() async throws {
        try await assertAudioCombination(hookHasAudio: true, bodyHasAudio: false)
    }

    func testAudioOnBodyOnlyKeepsItsTimelineOffset() async throws {
        try await assertAudioCombination(hookHasAudio: false, bodyHasAudio: true)
    }

    func testBothClipsWithAudioKeepTheWholeTimeline() async throws {
        try await assertAudioCombination(hookHasAudio: true, bodyHasAudio: true)
    }

    private func assertAudioCombination(hookHasAudio: Bool, bodyHasAudio: Bool) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("composer-audio-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hook = dir.appendingPathComponent("hook.mp4")
        let body = dir.appendingPathComponent("body.mp4")
        try await writeSilentClip(to: hook, seconds: 1)
        try await writeSilentClip(to: body, seconds: 2)
        let h = hookHasAudio ? try await addingTone(to: hook, seconds: 1) : hook
        let b = bodyHasAudio ? try await addingTone(to: body, seconds: 2) : body
        let output = dir.appendingPathComponent("result.mov")
        try await TaskVideoComposer().compose(hookURL: h, bodyURL: b, outputURL: output)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 3, accuracy: 0.1)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
        // Decode the exported samples, checking each source interval for tone
        // or silence instead of just checking that an audio track exists.
        let reader = try AVAssetReader(asset: asset)
        let audio = AVAssetReaderTrackOutput(track: try XCTUnwrap(audioTracks.first), outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(audio)
        XCTAssertTrue(reader.startReading())
        var hookEnergy: Float = 0, bodyEnergy: Float = 0
        while let sample = audio.copyNextSampleBuffer() {
            guard let data = CMSampleBufferGetDataBuffer(sample) else { continue }
            let count = CMBlockBufferGetDataLength(data) / MemoryLayout<Float>.size
            var values = [Float](repeating: 0, count: count)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: count * 4, destination: $0.baseAddress!)
            }
            XCTAssertEqual(status, kCMBlockBufferNoErr)
            let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
            let stream = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)).pointee
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            for (index, value) in values.enumerated() {
                let time = start + Double(index / Int(stream.mChannelsPerFrame)) / stream.mSampleRate
                if time < 0.9 { hookEnergy = max(hookEnergy, abs(value)) }
                if time > 1.1 { bodyEnergy = max(bodyEnergy, abs(value)) }
            }
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(hookEnergy > 0.05, hookHasAudio)
        XCTAssertEqual(bodyEnergy > 0.05, bodyHasAudio)
    }

    private func addingTone(to video: URL, seconds: Int) async throws -> URL {
        let audioURL = video.deletingPathExtension().appendingPathExtension("caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 48000)))
        buffer.frameLength = buffer.frameCapacity
        let channel = try XCTUnwrap(buffer.floatChannelData?.pointee)
        for frame in 0..<Int(buffer.frameLength) {
            channel[frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48000)) * 0.25
        }
        do { let file = try AVAudioFile(forWriting: audioURL, settings: format.settings); try file.write(from: buffer) }
        let composition = AVMutableComposition()
        let source = AVURLAsset(url: video)
        let sourceAudio = AVURLAsset(url: audioURL)
        let videoTracks = try await source.loadTracks(withMediaType: .video)
        let audioTracks = try await sourceAudio.loadTracks(withMediaType: .audio)
        let duration = CMTime(seconds: Double(seconds), preferredTimescale: 48000)
        let videoTrack = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let audioTrack = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: try XCTUnwrap(videoTracks.first), at: .zero)
        try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: try XCTUnwrap(audioTracks.first), at: .zero)
        let output = video.deletingPathExtension().appendingPathExtension("mov")
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        exporter.outputURL = output; exporter.outputFileType = .mov
        await exporter.export()
        XCTAssertEqual(exporter.status, .completed)
        return output
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
