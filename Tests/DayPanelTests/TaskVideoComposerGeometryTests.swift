import AVFoundation
import CoreGraphics
import XCTest
@testable import ApolloRuntime

final class TaskVideoComposerGeometryTests: XCTestCase {
    func testRealCompositionExportsHEVCWithCombinedDurationAndBodyCanvas() async throws {
        let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else {
            throw XCTSkip("ffmpeg não está instalado neste ambiente")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apollo-composer-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hook = directory.appendingPathComponent("hook.mov")
        let body = directory.appendingPathComponent("body.mov")
        let output = directory.appendingPathComponent("result.mov")
        try run(ffmpeg, ["-y", "-f", "lavfi", "-i", "color=c=red:s=320x180:d=0.4:r=30",
                         "-f", "lavfi", "-i", "sine=frequency=440:duration=0.4",
                         "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", hook.path])
        try run(ffmpeg, ["-y", "-f", "lavfi", "-i", "color=c=blue:s=180x320:d=0.6:r=30",
                         "-f", "lavfi", "-i", "sine=frequency=660:duration=0.6",
                         "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", body.path])

        try await TaskVideoComposer().compose(hookURL: hook, bodyURL: body,
                                              outputURL: output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1.0, accuracy: 0.08)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(videoTracks.first)
        let naturalSize = try await track.load(.naturalSize)
        XCTAssertEqual(naturalSize, CGSize(width: 180, height: 320))
        let descriptions = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        let codec = CMFormatDescriptionGetMediaSubType(description)
        XCTAssertTrue(codec == kCMVideoCodecType_HEVC || codec == kCMVideoCodecType_HEVCWithAlpha)
        let frameRate = try await track.load(.nominalFrameRate)
        XCTAssertEqual(frameRate, 30, accuracy: 1)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty)
        let audioDuration = try await audioTracks[0].load(.timeRange).duration.seconds
        XCTAssertEqual(audioDuration, 1.0, accuracy: 0.08)
    }

    func testBodyDefinesPortraitCanvasAndHookAspectFillsIt() {
        let geometry = TaskVideoComposer.geometry(
            hookNaturalSize: CGSize(width: 1920, height: 1080),
            hookPreferredTransform: .identity,
            bodyNaturalSize: CGSize(width: 1080, height: 1920),
            bodyPreferredTransform: .identity
        )
        XCTAssertEqual(geometry.renderSize, CGSize(width: 1080, height: 1920))
        let hookBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            .applying(geometry.hookTransform)
        XCTAssertGreaterThanOrEqual(hookBounds.width, geometry.renderSize.width - 0.5)
        XCTAssertGreaterThanOrEqual(hookBounds.height, geometry.renderSize.height - 0.5)
        XCTAssertEqual(hookBounds.midX, geometry.renderSize.width / 2, accuracy: 0.5)
        XCTAssertEqual(hookBounds.midY, geometry.renderSize.height / 2, accuracy: 0.5)
    }

    func testPreferredRotationProducesEvenPortraitCanvas() {
        let rotate90 = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let geometry = TaskVideoComposer.geometry(
            hookNaturalSize: CGSize(width: 1920, height: 1080),
            hookPreferredTransform: .identity,
            bodyNaturalSize: CGSize(width: 1920, height: 1080),
            bodyPreferredTransform: rotate90
        )
        XCTAssertEqual(Int(geometry.renderSize.width) % 2, 0)
        XCTAssertEqual(Int(geometry.renderSize.height) % 2, 0)
        XCTAssertEqual(geometry.renderSize, CGSize(width: 1080, height: 1920))
    }

    func testLandscapeBodyStillDefinesCanvasAndCentersRotatedPortraitHook() {
        let rotate90 = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let geometry = TaskVideoComposer.geometry(
            hookNaturalSize: CGSize(width: 1920, height: 1080),
            hookPreferredTransform: rotate90,
            bodyNaturalSize: CGSize(width: 1920, height: 1080),
            bodyPreferredTransform: .identity
        )
        XCTAssertEqual(geometry.renderSize, CGSize(width: 1920, height: 1080))
        let hookBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            .applying(geometry.hookTransform)
        XCTAssertGreaterThanOrEqual(hookBounds.width, geometry.renderSize.width - 0.5)
        XCTAssertGreaterThanOrEqual(hookBounds.height, geometry.renderSize.height - 0.5)
        XCTAssertEqual(hookBounds.midX, geometry.renderSize.width / 2, accuracy: 0.5)
        XCTAssertEqual(hookBounds.midY, geometry.renderSize.height / 2, accuracy: 0.5)
    }

    private func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
