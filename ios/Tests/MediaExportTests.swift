import AVFoundation
import XCTest
@testable import ARTOFFICE

final class MediaExportTests: XCTestCase {
    func testChunkedExportMuxAndReuse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("project"), media = directory.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let red = media.appendingPathComponent("red.mp4"), blue = media.appendingPathComponent("blue.mp4")
        try await fixture(url: red, frames: 90, red: true)
        try await fixture(url: blue, frames: 90, red: false)
        var project = Project(); project.name = "日本語のライブ"
        let a = try await MediaFiles.probe(red, relativePath: "Media/red.mp4", bookmark: nil)
        let b = try await MediaFiles.probe(blue, relativePath: "Media/blue.mp4", bookmark: nil)
        project.clips = [Clip(source: a, bandName: "日本語バンド"), Clip(source: b, bandName: "次のバンド")]
        let jobs = root.appendingPathComponent("jobs")
        let files = try await ExportEngine.run(project: project, directory: directory, jobsRoot: jobs, destination: nil,
                                               control: ExportControl(), chunkSeconds: 2) { _, _ in }
        let output = try XCTUnwrap(files.first { $0.pathExtension == "mp4" })
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 5.5, accuracy: 0.06)
        let video = try XCTUnwrap(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await video.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1920, height: 1080))
        let text = try String(contentsOf: XCTUnwrap(files.first { $0.pathExtension == "txt" }), encoding: .utf8)
        XCTAssertEqual(text, "0:00:00 日本語バンド\n0:00:02 次のバンド\n")
        let reader = try AVAssetReader(asset: asset)
        let audio = AVAssetReaderTrackOutput(track: try XCTUnwrap(try await asset.loadTracks(withMediaType: .audio).first), outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(audio); XCTAssertTrue(reader.startReading())
        var lastEnd = 0.0, samples = 0
        while let sample = audio.copyNextSampleBuffer() {
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            XCTAssertLessThanOrEqual(abs(start - lastEnd), 0.05)
            lastEnd = start + CMSampleBufferGetDuration(sample).seconds; samples += CMSampleBufferGetNumSamples(sample)
        }
        XCTAssertEqual(reader.status, .completed); XCTAssertGreaterThan(samples, 200_000); XCTAssertEqual(lastEnd, 5.5, accuracy: 0.06)
        let job = jobs.appendingPathComponent(project.id.uuidString).appendingPathComponent(try ExportEngine.key(project))
        let chunk = job.appendingPathComponent("chunk-0.mp4")
        let before = try chunk.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        _ = try await ExportEngine.run(project: project, directory: directory, jobsRoot: jobs, destination: nil,
                                      control: ExportControl(), chunkSeconds: 2) { _, _ in }
        XCTAssertEqual(try chunk.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, before)
        // Corrupting a completed chunk must cause only that chunk to be regenerated.
        try Data("broken".utf8).write(to: chunk)
        _ = try await ExportEngine.run(project: project, directory: directory, jobsRoot: jobs, destination: nil,
                                      control: ExportControl(), chunkSeconds: 2) { _, _ in }
        XCTAssertGreaterThan(try Data(contentsOf: chunk).count, 100)
    }
    func testCancellationBeforeStartRetainsEditing() async throws {
        let control = ExportControl(); control.cancel()
        XCTAssertThrowsError(try control.check())
        var p = Project(); p.name = "保存対象"
        let key = try ExportEngine.key(p)
        p.modifiedAt = Date().addingTimeInterval(100); p.name = "別のファイル名"
        XCTAssertEqual(try ExportEngine.key(p), key)
        p.resolution = .quadHD
        XCTAssertNotEqual(try ExportEngine.key(p), key)
    }
    func fixture(url: URL, frames: Int, red: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90
        ])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pixel: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, try XCTUnwrap(adaptor.pixelBufferPool), &pixel)
            let buffer = try XCTUnwrap(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            let pointer = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<90 { for x in 0..<160 { let p = pointer + y * stride + x * 4; p[0] = red ? 0 : 255; p[1] = 0; p[2] = red ? 255 : 0; p[3] = 255 } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: 30))
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        XCTAssertEqual(writer.status, .completed)
    }
}
