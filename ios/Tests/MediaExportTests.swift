import AVFoundation
import CoreGraphics
import XCTest
@testable import ARTOFFICE

final class MediaExportTests: XCTestCase {
    func testChunkReuseRejectsRedirectedAndInvalidCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDirectory = root.appendingPathComponent("project"), outside = root.appendingPathComponent("outside")
        let current = projectDirectory.appendingPathComponent(String(repeating: "a", count: 64))
        let previous = projectDirectory.appendingPathComponent(String(repeating: "b", count: 64))
        for directory in [current, previous, outside] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let range = ExportChunk(index: 0, start: 0, end: Clock.ticks(1)), key = String(repeating: "c", count: 64)
        let source = ExportEngine.chunkURL(range, job: previous), sentinel = outside.appendingPathComponent("sentinel.mp4")
        try Data("unrelated".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: sentinel)
        var journal = ExportJournal()
        journal.completed["0"] = ChunkReceipt(byteCount: 9, modifiedAt: nil, range: range, contentKey: key)
        try JSONEncoder().encode(journal).write(to: previous.appendingPathComponent("journal.json"))
        XCTAssertTrue(ChunkReuse.candidates(projectDirectory: projectDirectory, excluding: current).isEmpty)
        try FileManager.default.removeItem(at: source)
        try Data("not a movie".utf8).write(to: source)
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        journal.completed["0"] = ChunkReceipt(byteCount: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate, range: range, contentKey: key)
        try JSONEncoder().encode(journal).write(to: previous.appendingPathComponent("journal.json"))
        let candidates = ChunkReuse.candidates(projectDirectory: projectDirectory, excluding: current)[key] ?? []
        XCTAssertEqual(candidates.count, 1)
        let output = ExportEngine.chunkURL(range, job: current)
        let linked = try await ChunkReuse.link(candidates, to: output, chunk: range, project: Project(), control: ExportControl())
        XCTAssertNil(linked); XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("unrelated".utf8))
        journal.rendererVersion -= 1
        try JSONEncoder().encode(journal).write(to: previous.appendingPathComponent("journal.json"))
        XCTAssertTrue(ChunkReuse.candidates(projectDirectory: projectDirectory, excluding: current).isEmpty)
    }
    func testCompletedCleanupPreservesSourcesChunksAndExternalFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = root.appendingPathComponent("jobs"), project = Project()
        let job = jobs.appendingPathComponent(project.id.uuidString).appendingPathComponent(try ExportEngine.key(project))
        let completed = job.appendingPathComponent("Completed"), sourceDirectory = root.appendingPathComponent("Projects/Media")
        let external = root.appendingPathComponent("external")
        for directory in [completed, sourceDirectory, external] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let internalFile = completed.appendingPathComponent("inside.mp4"), externalFile = external.appendingPathComponent("outside.mp4")
        let source = sourceDirectory.appendingPathComponent("source.mp4"), metadata = sourceDirectory.deletingLastPathComponent().appendingPathComponent("project.json")
        let chunk = job.appendingPathComponent("chunk-0.mp4"), journal = job.appendingPathComponent("journal.json")
        let retained = [externalFile, source, metadata, chunk, journal]
        for url in retained + [internalFile] { try Data(url.lastPathComponent.utf8).write(to: url) }
        try ExportHistory.record(files: [internalFile], job: job, destination: nil)
        try ExportHistory.record(files: [externalFile], job: job, destination: external)
        try ExportHistory.removeInternalCompleted(jobsRoot: jobs, projectID: project.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: completed.path))
        for url in retained { XCTAssertEqual(try Data(contentsOf: url), Data(url.lastPathComponent.utf8)) }
        let remaining = try XCTUnwrap(ExportHistory.latest(jobsRoot: jobs, projectID: project.id))
        XCTAssertTrue(remaining.files.contains { $0.resolvingSymlinksInPath().standardizedFileURL.path == externalFile.resolvingSymlinksInPath().standardizedFileURL.path })
        XCTAssertFalse(remaining.files.contains(internalFile))

        // A redirected Completed directory must never turn into an external removal target.
        let redirectedID = UUID(), redirected = jobs.appendingPathComponent(redirectedID.uuidString).appendingPathComponent(String(repeating: "a", count: 64))
        try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: redirected.appendingPathComponent("Completed"), withDestinationURL: external)
        XCTAssertThrowsError(try ExportHistory.removeInternalCompleted(jobsRoot: jobs, projectID: redirectedID))
        XCTAssertEqual(try Data(contentsOf: externalFile), Data(externalFile.lastPathComponent.utf8))
    }
    func testInterruptedAttemptDoesNotHideCommittedOutputs() throws {
        struct State: Encodable { var status: String; var startedAt: Date }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(), job = root.appendingPathComponent(project.id.uuidString).appendingPathComponent(try ExportEngine.key(project))
        let completedDirectory = job.appendingPathComponent("Completed"), report = job.appendingPathComponent("performance.json")
        try FileManager.default.createDirectory(at: completedDirectory, withIntermediateDirectories: true)
        var state = State(status: "running", startedAt: Date())
        try JSONEncoder().encode(state).write(to: report)
        var attempt = ExportHistory.attempt(jobsRoot: root, project: project, completed: nil)
        XCTAssertTrue(attempt.unfinished); XCTAssertEqual(attempt.report, report)
        let file = completedDirectory.appendingPathComponent("video.mp4")
        try Data("receipt fixture".utf8).write(to: file)
        try ExportHistory.record(files: [file], job: job, destination: nil)
        let completed = try XCTUnwrap(ExportHistory.latest(jobsRoot: root, projectID: project.id))
        attempt = ExportHistory.attempt(jobsRoot: root, project: project, completed: completed)
        XCTAssertFalse(attempt.unfinished, "Committed files survive a missing final diagnostic update")
        XCTAssertTrue(completed.files.contains(file))
        state.startedAt = completed.createdAt.addingTimeInterval(1)
        for status in ["running", "cancelled", "failed"] {
            state.status = status; try JSONEncoder().encode(state).write(to: report)
            XCTAssertTrue(ExportHistory.attempt(jobsRoot: root, project: project, completed: completed).unfinished)
        }
        state.status = "completed"; try JSONEncoder().encode(state).write(to: report)
        XCTAssertFalse(ExportHistory.attempt(jobsRoot: root, project: project, completed: completed).unfinished)
    }
    func testOutputFormatsPreserveFrameCountAndRate() async throws {
        executionTimeAllowance = 600
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let source = media.appendingPathComponent("formats.mp4")
        try await fixture(url: source, frames: 36, red: true)
        let metadata = try await MediaFiles.probe(source, relativePath: "Media/formats.mp4", bookmark: nil)
        for resolution in Resolution.allCases { for rate in FrameRate.allCases {
            var project = Project(); project.name = "Format \(resolution.rawValue) \(rate.rawValue)"
            project.resolution = resolution; project.frameRate = rate
            project.clips = [Clip(source: metadata, bandName: "形式の試験")]
            log("format test \(resolution.rawValue) \(rate.rawValue)")
            let files = try await ExportEngine.run(project: project, directory: root, jobsRoot: root.appendingPathComponent("jobs"),
                destination: nil, control: ExportControl()) { _, _ in }
            let asset = AVURLAsset(url: try XCTUnwrap(files.first(where: { $0.pathExtension == "mp4" })))
            let tracks = try await asset.loadTracks(withMediaType: .video), track = try XCTUnwrap(tracks.first)
            let size = try await track.load(.naturalSize), fps = try await track.load(.nominalFrameRate)
            XCTAssertEqual(size, CGSize(width: resolution.width, height: resolution.height))
            XCTAssertEqual(Double(fps), rate.value, accuracy: 0.02)
            let descriptions = try await track.load(.formatDescriptions)
            let description = try XCTUnwrap(descriptions.first)
            XCTAssertEqual(CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String, AVVideoColorPrimaries_ITU_R_709_2)
            XCTAssertEqual(CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String, AVVideoTransferFunction_ITU_R_709_2)
            let expectedEnd = try XCTUnwrap(Timeline(project).chunks(rate: rate).last).end
            // Count displayed images，not compressed packets that can include preroll/markers.
            let reader = try AVAssetReader(asset: asset), output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ])
            output.alwaysCopiesSampleData = false
            reader.add(output); XCTAssertTrue(reader.startReading())
            var frames = 0, incorrectTimes = 0
            var firstTimes: [Int64] = [], firstDurations: [Int64] = []
            while let sample = output.copyNextSampleBuffer() {
                guard CMSampleBufferGetImageBuffer(sample) != nil else { continue }
                let stamp = CMSampleBufferGetPresentationTimeStamp(sample).ticks
                if stamp != Int64(frames) * rate.frameTicks { incorrectTimes += 1 }
                if firstTimes.count < 4 { firstTimes.append(stamp); firstDurations.append(CMSampleBufferGetDuration(sample).ticks) }
                frames += 1
            }
            log("format result \(resolution.rawValue) \(rate.rawValue) frames=\(frames) expected=\(expectedEnd / rate.frameTicks) firstPTS=\(firstTimes) durations=\(firstDurations)")
            XCTAssertEqual(incorrectTimes, 0, "Decoded frame timestamps differ: \(firstTimes)")
            XCTAssertEqual(reader.status, .completed)
            XCTAssertEqual(Int64(frames), expectedEnd / rate.frameTicks)
            let duration = try await asset.load(.duration)
            XCTAssertEqual(duration.seconds, Clock.seconds(expectedEnd), accuracy: Clock.seconds(rate.frameTicks))
            // Keep the matrix's disk usage bounded，just as the production export keeps frame queues bounded.
            try FileManager.default.removeItem(at: root.appendingPathComponent("jobs").appendingPathComponent(project.id.uuidString))
        } }
    }
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
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 32, height: 18)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let first = try centerColor(generator, frame: 6), fade = try centerColor(generator, frame: 82), last = try centerColor(generator, frame: 156)
        log("sRGB samples first=\(first) fade=\(fade) last=\(last)")
        XCTAssertGreaterThan(first[0], 200); XCTAssertLessThan(first[2], 40)
        XCTAssertGreaterThan(fade[0], 60); XCTAssertGreaterThan(fade[2], 60); XCTAssertLessThan(fade[1], 40)
        XCTAssertGreaterThan(last[2], 200); XCTAssertLessThan(last[0], 40)
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
        // A title correction changes only the chunks that display that title.
        // The unaffected final chunk is linked across job identities，not copied.
        project.clips[0].bandName = "訂正した日本語バンド"
        let editedFiles = try await ExportEngine.run(project: project, directory: directory, jobsRoot: jobs, destination: nil,
            control: ExportControl(), chunkSeconds: 2) { _, _ in }
        let editedJob = jobs.appendingPathComponent(project.id.uuidString).appendingPathComponent(try ExportEngine.key(project))
        let report = try JSONDecoder().decode(ExportReport.self, from: Data(contentsOf: editedJob.appendingPathComponent("performance.json")))
        XCTAssertEqual(report.reusedChunkIndices, [2])
        XCTAssertEqual(report.chunks.map(\.index), [0, 1])
        let originalTail = job.appendingPathComponent("chunk-2.mp4"), editedTail = editedJob.appendingPathComponent("chunk-2.mp4")
        let originalInode = try FileManager.default.attributesOfItem(atPath: originalTail.path)[.systemFileNumber] as? NSNumber
        let editedInode = try FileManager.default.attributesOfItem(atPath: editedTail.path)[.systemFileNumber] as? NSNumber
        XCTAssertNotNil(originalInode); XCTAssertEqual(originalInode, editedInode)
        let editedChapters = try String(contentsOf: XCTUnwrap(editedFiles.first { $0.pathExtension == "txt" }), encoding: .utf8)
        XCTAssertTrue(editedChapters.contains("訂正した日本語バンド"))
        // Removing an old job's link must not remove the new job's reusable media.
        try FileManager.default.removeItem(at: originalTail)
        try await ExportEngine.validateChunk(editedTail, chunk: ExportChunk(index: 2, start: Clock.ticks(4), end: Clock.ticks(5.5)), project: project)
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
    func testRotationMatchesAVFoundationReference() async throws {
        executionTimeAllowance = 600
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let source = media.appendingPathComponent("rotation.mp4")
        try await fixture(url: source, frames: 36, red: true,
            transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 90, ty: 0), quadrants: true)
        var project = Project()
        let metadata = try await MediaFiles.probe(source, relativePath: "Media/rotation.mp4", bookmark: nil)
        project.clips = [Clip(source: metadata, bandName: "回転の試験")]
        let files = try await ExportEngine.run(project: project, directory: root, jobsRoot: root.appendingPathComponent("jobs"),
            destination: nil, control: ExportControl()) { _, _ in }
        let referenceGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        referenceGenerator.appliesPreferredTrackTransform = true
        let outputGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: try XCTUnwrap(files.first(where: { $0.pathExtension == "mp4" }))))
        outputGenerator.maximumSize = CGSize(width: 192, height: 108)
        let time = CMTime(value: 6, timescale: 30)
        let reference = try referenceGenerator.copyCGImage(at: time, actualTime: nil)
        let output = try outputGenerator.copyCGImage(at: time, actualTime: nil)
        XCTAssertLessThan(reference.width, reference.height)
        let scale = min(CGFloat(output.width) / CGFloat(reference.width), CGFloat(output.height) / CGFloat(reference.height))
        let left = (CGFloat(output.width) - CGFloat(reference.width) * scale) / 2
        let top = (CGFloat(output.height) - CGFloat(reference.height) * scale) / 2
        let points: [(CGFloat, CGFloat)] = [(0.25, 0.25), (0.75, 0.25), (0.25, 0.65), (0.75, 0.65)]
        for (x, y) in points {
            let expected = try pixelColor(reference, x: CGFloat(reference.width) * x, y: CGFloat(reference.height) * y)
            let actual = try pixelColor(output, x: left + CGFloat(reference.width) * scale * x,
                                        y: top + CGFloat(reference.height) * scale * y)
            for channel in 0..<3 { XCTAssertLessThan(abs(Int(actual[channel]) - Int(expected[channel])), 35, "Rotated content differs at \(x)，\(y)") }
        }
        for x in [CGFloat(3), CGFloat(output.width - 4)] {
            let black = try pixelColor(output, x: x, y: CGFloat(output.height) / 2)
            XCTAssertTrue(black.prefix(3).allSatisfy { $0 < 20 }, "Portrait footage must preserve its aspect ratio")
        }
    }
    func testShortRelinkIsRejectedBeforeCopyingMedia() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("short.mp4"), directory = root.appendingPathComponent("project")
        try await fixture(url: source, frames: 30, red: true)
        do {
            _ = try await MediaFiles.importVideo(source, copy: true, directory: directory, minimumDuration: Clock.ticks(5))
            XCTFail("A short replacement must be rejected before copying")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("元のカット範囲より短い"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Media").path))
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: source.path))
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
    func fixture(url: URL, frames: Int, red: Bool, transform: CGAffineTransform = .identity, quadrants: Bool = false) async throws {
        log("video fixture beginning")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90
        ])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var still: CVPixelBuffer?
        for frame in 0..<frames {
            let deadline = Date().addingTimeInterval(120)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else { throw writer.error ?? AppError.message("試験素材のエンコード待機がタイムアウトしました。") }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            if still == nil {
                var pixel: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, try XCTUnwrap(adaptor.pixelBufferPool), &pixel)
                let buffer = try XCTUnwrap(pixel)
                CVPixelBufferLockBaseAddress(buffer, [])
                let pointer = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<90 { for x in 0..<160 {
                    let p = pointer + y * stride + x * 4
                    if quadrants {
                        p[0] = y >= 45 && x < 80 ? 255 : 0
                        p[1] = x >= 80 ? 255 : 0
                        p[2] = (y < 45 && x < 80) || (y >= 45 && x >= 80) ? 255 : 0
                    } else { p[0] = red ? 0 : 255; p[1] = 0; p[2] = red ? 255 : 0 }
                    p[3] = 255
                } }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                // Every fixture frame has identical pixels. Keep this buffer immutable
                // rather than allocating and painting it again for every timestamp.
                still = buffer; log("video fixture pixels prepared")
            }
            XCTAssertTrue(adaptor.append(try XCTUnwrap(still), withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
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
    private func centerColor(_ generator: AVAssetImageGenerator, frame: Int64) throws -> [UInt8] {
        let image = try generator.copyCGImage(at: CMTime(value: frame, timescale: 30), actualTime: nil)
        return try pixelColor(image, x: CGFloat(image.width / 2), y: CGFloat(image.height / 2))
    }
    private func pixelColor(_ image: CGImage, x: CGFloat, y: CGFloat) throws -> [UInt8] {
        let pixel = try XCTUnwrap(image.cropping(to: CGRect(x: x.rounded(.down), y: y.rounded(.down), width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1)); return true
        }
        XCTAssertTrue(drawn)
        return rgba
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
