import AVFoundation
import XCTest
@testable import ARTOFFICE

final class MediaExportTests: XCTestCase {
    func testChunkedExportMuxAndReuse() async throws {
        log("tone export beginning")
        executionTimeAllowance = 600
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("project"), media = directory.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let red = media.appendingPathComponent("red.mov"), blue = media.appendingPathComponent("blue.mov")
        try await toneFixture(url: red, red: true, frequency: 440)
        try await toneFixture(url: blue, red: false, frequency: 880)
        log("tone fixtures completed")
        var project = Project(); project.name = "日本語のライブ"
        let a = try await MediaFiles.probe(red, relativePath: "Media/red.mov", bookmark: nil)
        let b = try await MediaFiles.probe(blue, relativePath: "Media/blue.mov", bookmark: nil)
        project.clips = [Clip(source: a, bandName: "日本語バンド"), Clip(source: b, bandName: "次のバンド")]
        let jobs = root.appendingPathComponent("jobs")
        let files = try await ExportEngine.run(project: project, directory: directory, jobsRoot: jobs, destination: nil,
                                               control: ExportControl(), chunkSeconds: 2) { _, _ in }
        let output = try XCTUnwrap(files.first { $0.pathExtension == "mp4" })
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 5.5, accuracy: 0.06)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videoTracks.first)
        let size = try await video.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1920, height: 1080))
        let text = try String(contentsOf: XCTUnwrap(files.first { $0.pathExtension == "txt" }), encoding: .utf8)
        XCTAssertEqual(text, "0:00:00 日本語バンド\n0:00:02 次のバンド\n")
        let restored = try XCTUnwrap(ExportHistory.latest(jobsRoot: jobs, projectID: project.id))
        XCTAssertTrue(restored.files.contains(output))
        let reader = try AVAssetReader(asset: asset)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audio = AVAssetReaderTrackOutput(track: try XCTUnwrap(audioTracks.first), outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false
        ])
        reader.add(audio); XCTAssertTrue(reader.startReading())
        var lastEnd = 0.0, samples = 0
        var energy = Array(repeating: 0.0, count: 600), counts = Array(repeating: 0, count: 600)
        while let sample = audio.copyNextSampleBuffer() {
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            XCTAssertLessThanOrEqual(abs(start - lastEnd), 0.05)
            lastEnd = start + CMSampleBufferGetDuration(sample).seconds; samples += CMSampleBufferGetNumSamples(sample)
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            var pcm = Array(repeating: Float.zero, count: CMSampleBufferGetNumSamples(sample) * 2)
            let copied = pcm.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            XCTAssertEqual(copied, noErr)
            for frame in 0..<(pcm.count / 2) {
                let bin = Int((start + Double(frame) / 48_000) * 100)
                if energy.indices.contains(bin) { energy[bin] += Double(pcm[frame * 2] * pcm[frame * 2]); counts[bin] += 1 }
            }
        }
        XCTAssertEqual(reader.status, .completed); XCTAssertGreaterThan(samples, 200_000); XCTAssertEqual(lastEnd, 5.5, accuracy: 0.06)
        // Continuous tones expose missing audio and AAC priming gaps at chunk boundaries.
        for bin in [100, 198, 199, 200, 201, 274, 275, 398, 399, 400, 401, 540] {
            XCTAssertGreaterThan(counts[bin], 400, "Missing PCM at \(Double(bin) / 100)s")
            XCTAssertGreaterThan(sqrt(energy[bin] / Double(max(1, counts[bin]))), 0.04, "Unexpected silence at \(Double(bin) / 100)s")
        }
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
    func testCancellationWhileEncodingRetainsSavedProject() async throws {
        executionTimeAllowance = 600
        log("active cancellation beginning")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(root: root)
        var project = Project()
        let directory = await repository.directory(project.id), media = directory.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let url = media.appendingPathComponent("cancel.mp4")
        try await fixture(url: url, frames: 90, red: true)
        log("cancellation fixture completed")
        let source = try await MediaFiles.probe(url, relativePath: "Media/cancel.mp4", bookmark: nil)
        project.clips = [Clip(source: source, bandName: "中断の試験")]
        try await repository.save(project)
        log("cancellation project saved; building composition")
        let composition = try await CompositionBuilder.build(project: project, directory: directory)
        log("cancellation composition completed")
        let audioEncoding = try AudioEncoding.supported()
        log("cancellation audio settings selected")
        let control = ExportControl(), chunk = try XCTUnwrap(Timeline(project).chunks(rate: project.frameRate).first)
        do {
            try await ExportEngine.writeChunk(composition: composition, chunk: chunk, project: project,
                audioEncoding: audioEncoding, url: directory.appendingPathComponent("cancel.partial.mp4"), control: control) { _ in
                    control.cancel()
                }
            XCTFail("An active export must report cancellation")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation，received \(error)") }
        let saved = try await repository.load(project.id)
        XCTAssertEqual(saved.project, project)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: url.path))
    }
    func fixture(url: URL, frames: Int, red: Bool) async throws {
        log("video fixture beginning")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90
        ])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            let deadline = Date().addingTimeInterval(30)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else { throw writer.error ?? AppError.message("試験素材のエンコード待機がタイムアウトしました。") }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
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
        log("video fixture waiting for writer finish")
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        log("video fixture finished status=\(writer.status.rawValue)")
        XCTAssertEqual(writer.status, .completed)
    }
    private func log(_ message: String) {
        FileHandle.standardError.write(Data("ARTOFFICE test \(Date().timeIntervalSince1970) \(message)\n".utf8))
    }
    private func toneFixture(url: URL, red: Bool, frequency: Double) async throws {
        let videoURL = url.appendingPathExtension("video.mp4"), audioURL = url.appendingPathExtension("caf")
        defer { try? FileManager.default.removeItem(at: videoURL); try? FileManager.default.removeItem(at: audioURL) }
        try await fixture(url: videoURL, frames: 90, red: red)
        try writeTone(url: audioURL, frequency: frequency)
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL), audioAsset = AVURLAsset(url: audioURL)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video), audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        let videoTrack = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let audioTrack = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        let range = CMTimeRange(start: .zero, duration: CMTime(value: 3, timescale: 1))
        try videoTrack.insertTimeRange(range, of: XCTUnwrap(videoTracks.first), at: .zero)
        try audioTrack.insertTimeRange(range, of: XCTUnwrap(audioTracks.first), at: .zero)
        let session = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        session.outputURL = url; session.outputFileType = .mov
        await withCheckedContinuation { continuation in session.exportAsynchronously { continuation.resume() } }
        XCTAssertEqual(session.status, .completed, session.error?.localizedDescription ?? "")
    }
    private func writeTone(url: URL, frequency: Double) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144_000)); buffer.frameLength = 144_000
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<144_000 {
            let value = Float(0.25 * sin(2 * Double.pi * frequency * Double(frame) / 48_000))
            channels[0][frame] = value; channels[1][frame] = value
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
