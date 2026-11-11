import AVFoundation
import UIKit
import XCTest
@testable import ARTOFFICE

final class MediaFormatTests: XCTestCase {
    private func fixture(_ extensionName: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: extensionName, subdirectory: "fixtures"))
    }
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testMixedMoviesRemainPlayableAfterSavingAndReopeningSources() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for extensionName in ["mp4", "mov", "mkv", "webm", "mts", "m2ts", "avi", "wmv"] {
            let source = try fixture(extensionName)
            let original = try Data(contentsOf: source)
            // A format that needs conversion is stored locally even in reference mode.
            let clip = try await MediaFiles.importVideo(source, copy: extensionName != "mkv", directory: root)
            XCTAssertEqual(clip.source.fileName, source.lastPathComponent)
            XCTAssertTrue(clip.source.hasAudio, extensionName)
            XCTAssertEqual(Clock.seconds(clip.source.duration), 1.5, accuracy: 0.18, extensionName)
            let restored = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))
            let lease = try SourceLease(source: restored.source, projectDirectory: root)
            let asset = AVURLAsset(url: lease.url)
            let playable = try await asset.load(.isPlayable)
            XCTAssertTrue(playable, extensionName)
            // Decode both tracks, rather than accepting a container whose metadata alone loads.
            let reader = try AVAssetReader(asset: asset)
            let videos = try await asset.loadTracks(withMediaType: .video)
            let audios = try await asset.loadTracks(withMediaType: .audio)
            let video = try XCTUnwrap(videos.first)
            let audio = try XCTUnwrap(audios.first)
            let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            let audioOutput = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(videoOutput); reader.add(audioOutput)
            XCTAssertTrue(reader.startReading(), extensionName)
            XCTAssertNotNil(videoOutput.copyNextSampleBuffer(), extensionName)
            XCTAssertNotNil(audioOutput.copyNextSampleBuffer(), extensionName)
            reader.cancelReading()
            XCTAssertEqual(try Data(contentsOf: source), original, extensionName)
        }
    }

    func testAdditionalImagesExportPNGAndUseFirstGIFFrame() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for extensionName in ["jpg", "png", "webp", "tif", "tiff", "bmp", "avif", "gif"] {
            var crop = try MediaFiles.importPhoto(try fixture(extensionName), directory: root)
            crop.outputFormat = .png
            let output = root.appendingPathComponent("thumbnail-\(extensionName).png")
            try MediaFiles.exportPhoto(crop, directory: root, output: output)
            let bytes = try Data(contentsOf: output)
            XCTAssertEqual(Array(bytes.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10], extensionName)
            let image = try XCTUnwrap(UIImage(data: bytes)?.cgImage)
            XCTAssertEqual(image.width, 1920, extensionName); XCTAssertEqual(image.height, 1080, extensionName)
            var pixel = [UInt8](repeating: 0, count: 4)
            try pixel.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            XCTAssertGreaterThan(pixel[0], 180, extensionName)
            XCTAssertLessThan(pixel[2], 40, extensionName)
        }
    }

    func testConvertedRelinkChecksDurationBeforeWritingProjectMedia() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await MediaFiles.importVideo(try fixture("webm"), copy: true, directory: root,
                minimumDuration: Clock.ticks(3))
            XCTFail("Short replacement must be rejected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("短い")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Media").path))
    }

    func testConvertedVideoDetectsDuplicateBeforeCreatingAnotherCopy() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture("mkv")
        let first = try await MediaFiles.importVideo(source, copy: false, directory: root)
        let identity = try XCTUnwrap(first.source.importIdentity)
        let media = root.appendingPathComponent("Media")
        let before = try FileManager.default.contentsOfDirectory(atPath: media.path)
        do {
            _ = try await MediaFiles.importVideo(source, copy: false, directory: root, existingIDs: [identity])
            XCTFail("Duplicate must be rejected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("既に")) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: media.path), before)
    }
}
