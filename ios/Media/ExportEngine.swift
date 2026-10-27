import AVFoundation
import CryptoKit
import Darwin
import Metal
import UIKit

final class ExportControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var reader: AVAssetReader?
    private var session: AVAssetExportSession?
    private var wakeup: (@Sendable () -> Void)?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func attach(reader: AVAssetReader?, writer: AVAssetWriter?, session: AVAssetExportSession? = nil) {
        lock.lock(); self.reader = reader; self.session = session; let cancelled = stopped; lock.unlock()
        if cancelled { reader?.cancelReading(); session?.cancelExport() }
    }
    func cancel() {
        lock.lock(); stopped = true; let r = reader, s = session, callback = wakeup; lock.unlock()
        // The pump queues finish before cancelling the writer，avoiding concurrent
        // markAsFinished/cancelWriting calls inside AVAssetWriter.
        r?.cancelReading(); s?.cancelExport()
        callback?()
    }
    func setWakeup(_ callback: (@Sendable () -> Void)?) {
        lock.lock(); wakeup = callback; let cancelled = stopped; lock.unlock()
        if cancelled { callback?() }
    }
    func check() throws { if isCancelled { throw CancellationError() }; try Task.checkCancellation() }
}

private final class PumpFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    func record(_ error: Error) { lock.lock(); if stored == nil { stored = error }; lock.unlock() }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return stored }
}

struct ChunkReceipt: Codable {
    var byteCount: Int64
    var modifiedAt: Date?
    var range: ExportChunk
    var contentKey: String? = nil
}
struct ExportJournal: Codable {
    var rendererVersion = ExportEngine.rendererVersion
    var completed: [String: ChunkReceipt] = [:]
}
struct ChunkMeasurement: Codable {
    var index: Int
    var mediaSeconds: Double
    var elapsedSeconds: Double
    var residentBytes: UInt64
    var thermalState: Int
}
struct ExportReport: Codable {
    var startedAt = Date()
    var budget: DeviceBudget
    var systemVersion: String
    var metalDevice: String
    var resolution: String
    var frameRate: String
    var encoder = "AVAssetWriter H.264; platform-selected encoder"
    var hardwareVerification = "Requires device profiling; simulator is not evidence"
    var audioBitRate: Int = 0
    var supportedAudioBitRates: [Int] = []
    var destinationMaximumFileBytes: Int64? = nil
    var status = "running"
    var peakSampledResidentBytes: UInt64 = 0
    var memorySamplingIntervalSeconds = 1
    var performanceWindows: [PerformanceWindow] = []
    var chunks: [ChunkMeasurement] = []
    var reusedChunkIndices: [Int] = []
    var elapsedSeconds: Double = 0
    var finalizationSeconds: Double = 0
    var cacheCleanupNote: String? = nil
}

enum ExportEngine {
    static let rendererVersion = 5
    // All four output frame rates have integral frame durations at 60 kHz.
    // Five-hour movie durations also fit a 32-bit duration field at this scale.
    private static let outputVideoScale: CMTimeScale = 60_000
    static func key(_ project: Project) throws -> String {
        struct Identity: Encodable { let version: Int; let clips: [Clip]; let resolution: Resolution; let frameRate: FrameRate }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(Identity(version: rendererVersion, clips: project.clips, resolution: project.resolution, frameRate: project.frameRate))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func run(project: Project, directory: URL, jobsRoot: URL, destination: URL?, control: ExportControl, chunkSeconds: Int = 300,
                    progress: @escaping @Sendable (Double, String) -> Void) async throws -> [URL] {
        let timeline = try Timeline(project)
        guard !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.message("イベント名を入力してください。") }
        let chunks = timeline.chunks(rate: project.frameRate, seconds: chunkSeconds)
        guard !chunks.isEmpty else { throw AppError.message("動画を追加してください。") }
        let job = jobsRoot.appendingPathComponent(project.id.uuidString).appendingPathComponent(try key(project))
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        let scoped = destination?.startAccessingSecurityScopedResource() ?? false
        defer { if scoped { destination?.stopAccessingSecurityScopedResource() } }
        let outputDirectory = destination ?? job.appendingPathComponent("Completed")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let capacity = CapacityEstimate(duration: timeline.duration, resolution: project.resolution, separateDestination: destination != nil)
        let journalURL = job.appendingPathComponent("journal.json")
        var journal = (try? JSONDecoder().decode(ExportJournal.self, from: Data(contentsOf: journalURL))) ?? ExportJournal()
        if journal.rendererVersion != rendererVersion { journal = ExportJournal() }
        let clock = Date()
        var report = ExportReport(budget: DeviceBudget.current(), systemVersion: UIDevice.current.systemVersion,
            metalDevice: MTLCreateSystemDefaultDevice()?.name ?? "unavailable", resolution: project.resolution.rawValue, frameRate: project.frameRate.rawValue)
        let sampler = PerformanceSampler(budget: report.budget)
        defer {
            let sampled = sampler.snapshot()
            report.peakSampledResidentBytes = sampled.peak; report.performanceWindows = sampled.windows
            report.elapsedSeconds = Date().timeIntervalSince(clock)
            if report.status != "completed" { report.status = control.isCancelled ? "cancelled" : "failed" }
            // Preserve measurements even when a long export is interrupted. The sampled
            // peak is labelled explicitly; sub-second memory spikes can be missed.
            try? JSONEncoder().encode(report).write(to: job.appendingPathComponent("performance.json"), options: .atomic)
        }
        try JSONEncoder().encode(report).write(to: job.appendingPathComponent("performance.json"), options: .atomic)
        report.destinationMaximumFileBytes = OutputVolume.maximumFileSize(at: outputDirectory)
        try OutputFileLimit.require(Int64(Double(capacity.output) * 1.2) + 4_000_000, maximum: report.destinationMaximumFileBytes)
        trace("renderer=\(report.metalDevice)")
        progress(0, "音声の出力設定を確認しています")
        let audioEncoding = try AudioEncoding.supported()
        report.audioBitRate = audioEncoding.bitRate; report.supportedAudioBitRates = audioEncoding.supportedBitRates
        print("ARTOFFICE AAC selected=\(audioEncoding.bitRate) supported=\(audioEncoding.supportedBitRates)")
        // Persist an attempt before reading frames，so relaunch can explain an OS kill
        // even if the first chunk had not yet completed.
        try JSONEncoder().encode(report).write(to: job.appendingPathComponent("performance.json"), options: .atomic)
        progress(0, "素材を確認しています")
        let composition = try await CompositionBuilder.build(project: project, directory: directory)
        // Keep security scopes alive across asynchronous reads and finalization.
        defer { withExtendedLifetime(composition.leases) {} }
        let candidates = ChunkReuse.candidates(projectDirectory: job.deletingLastPathComponent(), excluding: job)
        var contentKeys: [Int: String] = [:], reused: Set<Int> = [], used: Int64 = 0
        for chunk in chunks {
            try control.check()
            let identity = ChunkIdentity(project: project, timeline: timeline, chunk: chunk,
                rendererVersion: rendererVersion, audioBitRate: audioEncoding.bitRate)
            let contentKey = SHA256.hash(data: try identity.encoded()).map { String(format: "%02x", $0) }.joined()
            contentKeys[chunk.index] = contentKey
            let output = chunkURL(chunk, job: job)
            if let receipt = journal.completed[String(chunk.index)], receipt.contentKey == contentKey,
               try await reusable(output, receipt: receipt, chunk: chunk, project: project) {
                reused.insert(chunk.index); used += receipt.byteCount
            } else if let receipt = try await ChunkReuse.link(candidates[contentKey] ?? [], to: output, chunk: chunk, project: project, control: control) {
                journal.completed[String(chunk.index)] = receipt
                try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
                reused.insert(chunk.index); used += receipt.byteCount
            }
        }
        report.reusedChunkIndices = reused.sorted()
        // Validated hard links already occupy storage；budget only the missing chunks
        // and the new final file，including when editing changes the job identity.
        let localVolume = try? job.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let destinationVolume = try? outputDirectory.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let sameVolume = StorageVolumeIdentity.matches(localVolume, destinationVolume)
        if destination != nil && sameVolume {
            try MediaFiles.requireSpace(max(1_000_000_000, capacity.localWorking + capacity.destinationWorking - used - 1_000_000_000), at: job)
        } else {
            try MediaFiles.requireSpace(max(1_000_000_000, capacity.localWorking - used), at: job)
            if destination != nil { try MediaFiles.requireSpace(capacity.destinationWorking, at: outputDirectory) }
        }
        for chunk in chunks {
            try control.check()
            trace("chunk \(chunk.index) range=\(Clock.seconds(chunk.start))...\(Clock.seconds(chunk.end))")
            let output = chunkURL(chunk, job: job)
            if reused.contains(chunk.index) {
                progress(Double(chunk.end) / Double(timeline.duration) * 0.94, "処理済みの区間を再利用しています")
                continue
            }
            journal.completed.removeValue(forKey: String(chunk.index))
            let partial = job.appendingPathComponent("chunk-\(chunk.index).partial.mp4")
            try? FileManager.default.removeItem(at: partial)
            let start = Date()
            do {
                try MediaFiles.requireSpace(max(250_000_000, Int64(Clock.seconds(chunk.duration) * Double(project.resolution.bitrate + 384_000) / 8 * 1.2)), at: job)
                try await writeChunk(composition: composition, chunk: chunk, project: project, audioEncoding: audioEncoding, url: partial, control: control) { ticks in
                    progress(Double(min(chunk.end, ticks)) / Double(timeline.duration) * 0.94, "動画を書き出しています（\(chunk.index + 1)/\(chunks.count)）")
                }
                try control.check()
                try await validateChunk(partial, chunk: chunk, project: project)
                if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
                try FileManager.default.moveItem(at: partial, to: output)
                let values = try output.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                journal.completed[String(chunk.index)] = ChunkReceipt(byteCount: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate,
                    range: chunk, contentKey: contentKeys[chunk.index])
                try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
                report.chunks.append(ChunkMeasurement(index: chunk.index, mediaSeconds: Clock.seconds(chunk.duration),
                    elapsedSeconds: Date().timeIntervalSince(start), residentBytes: residentMemory(), thermalState: ProcessInfo.processInfo.thermalState.rawValue))
                let sampled = sampler.snapshot()
                report.peakSampledResidentBytes = sampled.peak; report.performanceWindows = sampled.windows
                report.elapsedSeconds = Date().timeIntervalSince(clock)
                try JSONEncoder().encode(report).write(to: job.appendingPathComponent("performance.json"), options: .atomic)
            } catch { try? FileManager.default.removeItem(at: partial); throw error }
        }
        try control.check()
        progress(0.94, "処理した区間を1本にまとめています")
        let chunkBytes = try chunks.reduce(Int64(0)) { sum, chunk in
            sum + Int64((try chunkURL(chunk, job: job).resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
        }
        // Recheck actual encoded sizes before creating a multi-GB final file.
        try OutputFileLimit.require(Int64(Double(chunkBytes) * 1.02) + 4_000_000, maximum: OutputVolume.maximumFileSize(at: outputDirectory))
        let finalizeStart = Date(), stem = Naming.safeStem(project.name)
        let suffix = "_" + String(UUID().uuidString.prefix(8))
        let final = outputDirectory.appendingPathComponent(stem + suffix + ".mp4")
        let partial = outputDirectory.appendingPathComponent("." + stem + suffix + ".partial.mp4")
        let chapters = outputDirectory.appendingPathComponent(stem + suffix + "_チャプター.txt")
        let photo = outputDirectory.appendingPathComponent(stem + suffix + "_サムネイル.jpg")
        var generated: [URL] = []
        do {
            try await mux(chunks: chunks, job: job, output: partial, control: control)
            try control.check()
            let asset = AVURLAsset(url: partial)
            let duration = try await asset.load(.duration)
            guard abs(duration.seconds - Clock.seconds(chunks.last!.end)) < 0.15 else { throw AppError.message("完成動画の長さを検証できませんでした。処理済み区間は保持されています。") }
            try FileManager.default.moveItem(at: partial, to: final); generated.append(final)
            try timeline.chapters.write(to: chapters, atomically: true, encoding: .utf8); generated.append(chapters)
            if let crop = project.thumbnail { try MediaFiles.exportPhoto(crop, directory: directory, output: photo); generated.append(photo) }
            try ExportHistory.record(files: generated, job: job, destination: destination)
            report.elapsedSeconds = Date().timeIntervalSince(clock); report.finalizationSeconds = Date().timeIntervalSince(finalizeStart)
            report.status = "completed"
            do { try ExportCacheStorage.retainRecent(projectDirectory: job.deletingLastPathComponent(), currentJob: job.lastPathComponent) }
            catch { report.cacheCleanupNote = "古い処理用キャッシュを整理できませんでした。保存容量の画面から再実行できます。" }
            let reportURL = job.appendingPathComponent("performance.json")
            // Once all output files and their receipt are committed，a diagnostic write
            // failure must not remove the user's five-hour completed video.
            let reportSaved = (try? JSONEncoder().encode(report).write(to: reportURL, options: .atomic)) != nil
            progress(1, "書き出しが完了しました")
            return generated + (reportSaved ? [reportURL] : [])
        } catch {
            try? FileManager.default.removeItem(at: partial)
            for url in generated { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }
    static func chunkURL(_ chunk: ExportChunk, job: URL) -> URL { job.appendingPathComponent("chunk-\(chunk.index).mp4") }
    static func reusable(_ url: URL, receipt: ChunkReceipt, chunk: ExportChunk, project: Project) async throws -> Bool {
        guard receipt.range == chunk, let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              Int64(values.fileSize ?? -1) == receipt.byteCount, values.contentModificationDate == receipt.modifiedAt else { return false }
        do { try await validateChunk(url, chunk: chunk, project: project); return true } catch { return false }
    }
    static func validateChunk(_ url: URL, chunk: ExportChunk, project: Project) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let video = try await asset.loadTracks(withMediaType: .video).first,
              !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { throw AppError.message("出力区間の映像・音声が不足しています。") }
        let size = try await video.load(.naturalSize), fps = try await video.load(.nominalFrameRate)
        guard Int(size.width) == project.resolution.width, Int(size.height) == project.resolution.height,
              abs(Double(fps) - project.frameRate.value) < 0.05,
              abs(duration.seconds - Clock.seconds(chunk.duration)) < 0.1 else { throw AppError.message("出力区間の形式または長さが一致しません。") }
    }
    static func writeChunk(composition: RenderComposition, chunk: ExportChunk, project: Project, audioEncoding: AudioEncoding, url: URL,
                           control: ExportControl, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let reader = try AVAssetReader(asset: composition.asset)
        reader.timeRange = CMTimeRange(start: CMTime(ticks: chunk.start), duration: CMTime(ticks: chunk.duration))
        let videos = AVAssetReaderVideoCompositionOutput(videoTracks: composition.asset.tracks(withMediaType: .video), videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        videos.videoComposition = composition.video; videos.alwaysCopiesSampleData = false
        guard reader.canAdd(videos) else { throw AppError.message("動画の読込み設定を適用できません。") }; reader.add(videos)
        let audioTracks = composition.asset.tracks(withMediaType: .audio).filter { !$0.segments.isEmpty }
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
            ])
            output.audioMix = composition.audio; output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw AppError.message("音声の読込み設定を適用できません。") }; reader.add(output); audioOutput = output
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = false
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: project.resolution.width, AVVideoHeightKey: project.resolution.height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: project.resolution.bitrate,
                AVVideoExpectedSourceFrameRateKey: project.frameRate.value, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 2, AVVideoAllowFrameReorderingKey: false]
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else { throw AppError.message("この端末では選択した画質で出力できません。") }
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.mediaTimeScale = outputVideoScale
        guard writer.canApply(outputSettings: audioEncoding.settings, forMediaType: .audio) else {
            throw AppError.message("AAC音声の出力設定を適用できません。")
        }
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioEncoding.settings)
        vInput.expectsMediaDataInRealTime = false; aInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(vInput), writer.canAdd(aInput) else { throw AppError.message("動画・音声の出力設定を適用できません。") }
        writer.add(vInput); writer.add(aInput); control.attach(reader: reader, writer: writer)
        defer {
            control.setWakeup(nil); control.attach(reader: nil, writer: nil)
            if writer.status == .writing { writer.cancelWriting() }
        }
        try control.check()
        trace("starting writer")
        guard writer.startWriting() else { throw writer.error ?? AppError.message("書込みを開始できません。") }
        writer.startSession(atSourceTime: CMTime(ticks: chunk.start))
        trace("starting reader")
        guard reader.startReading() else { try control.check(); throw reader.error ?? AppError.message("読込みを開始できません。") }
        trace("reader started; audioTracks=\(audioTracks.count)")
        let audioPump = try AudioPump(output: audioOutput, chunk: chunk)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup(); group.enter(); group.enter()
            let vQueue = DispatchQueue(label: "artoffice.encode.video", qos: .userInitiated)
            let aQueue = DispatchQueue(label: "artoffice.encode.audio", qos: .userInitiated)
            var vFinished = false, aFinished = false
            var firstVideo = true, firstAudio = true
            var lastUpdate = Date.distantPast
            var lastFrameTrace = Date.distantPast
            var lastTrace = Date()
            let failure = PumpFailure()
            // Cancellation may stop readiness callbacks. Wake both queues explicitly so the
            // continuation cannot hang waiting for callbacks from a cancelled writer.
            let finishQueues: @Sendable () -> Void = {
                vQueue.async { if !vFinished { vFinished = true; group.leave() } }
                aQueue.async { if !aFinished { aFinished = true; group.leave() } }
            }
            control.setWakeup(finishQueues)
            // A failed writer can stop sending readiness callbacks altogether. Observe its
            // terminal state independently，rather than waiting forever for another callback.
            let monitor = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            monitor.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
            monitor.setEventHandler {
                if Date().timeIntervalSince(lastTrace) >= 10 {
                    lastTrace = Date()
                    trace("pump reader=\(reader.status.rawValue) writer=\(writer.status.rawValue) videoReady=\(vInput.isReadyForMoreMediaData) audioReady=\(aInput.isReadyForMoreMediaData)")
                }
                if writer.status == .failed || reader.status == .failed {
                    failure.record(writer.error ?? reader.error ?? AppError.message("動画の読込み・書込み処理が停止しました。"))
                    reader.cancelReading(); finishQueues()
                }
            }
            monitor.resume()
            vInput.requestMediaDataWhenReady(on: vQueue) {
                guard !vFinished else { return }
                while vInput.isReadyForMoreMediaData {
                    if control.isCancelled || reader.status == .failed || writer.status != .writing {
                        vFinished = true; if writer.status == .writing { vInput.markAsFinished() }; group.leave(); return
                    }
                    let sample = autoreleasepool { videos.copyNextSampleBuffer() }
                    guard let sample else { trace("video EOF"); vFinished = true; if writer.status == .writing { vInput.markAsFinished() }; group.leave(); return }
                    if firstVideo { firstVideo = false; trace("first video frame=\(CMSampleBufferGetPresentationTimeStamp(sample).seconds)") }
                    guard vInput.append(sample) else {
                        failure.record(writer.error ?? AppError.message("映像フレームを書き込めませんでした。"))
                        vFinished = true; reader.cancelReading(); group.leave()
                        aQueue.async { if !aFinished { aFinished = true; group.leave() } }; return
                    }
                    if Date().timeIntervalSince(lastUpdate) > 0.5 {
                        lastUpdate = Date(); progress(CMSampleBufferGetPresentationTimeStamp(sample).ticks)
                        if Date().timeIntervalSince(lastFrameTrace) > 5 {
                            lastFrameTrace = Date(); trace("video progress=\(CMSampleBufferGetPresentationTimeStamp(sample).seconds)")
                        }
                    }
                }
            }
            aInput.requestMediaDataWhenReady(on: aQueue) {
                guard !aFinished else { return }
                while aInput.isReadyForMoreMediaData {
                    if control.isCancelled || reader.status == .failed || writer.status != .writing {
                        aFinished = true; if writer.status == .writing { aInput.markAsFinished() }; group.leave(); return
                    }
                    do {
                        guard let sample = try autoreleasepool(invoking: { try audioPump.next() }) else {
                            trace("audio EOF")
                            aFinished = true; if writer.status == .writing { aInput.markAsFinished() }; group.leave(); return
                        }
                        if firstAudio { firstAudio = false; trace("first audio frame=\(CMSampleBufferGetPresentationTimeStamp(sample).seconds)") }
                        guard aInput.append(sample) else {
                            failure.record(writer.error ?? AppError.message("音声データを書き込めませんでした。"))
                            aFinished = true; reader.cancelReading(); group.leave()
                            vQueue.async { if !vFinished { vFinished = true; group.leave() } }; return
                        }
                    } catch {
                        failure.record(error); aFinished = true; reader.cancelReading(); group.leave()
                        vQueue.async { if !vFinished { vFinished = true; group.leave() } }; return
                    }
                }
            }
            group.notify(queue: vQueue) {
                monitor.cancel()
                trace("pumps finished; reader=\(reader.status.rawValue) writer=\(writer.status.rawValue)")
                if control.isCancelled { writer.cancelWriting(); continuation.resume(throwing: CancellationError()); return }
                if let error = failure.error ?? writer.error ?? reader.error {
                    if writer.status == .writing { writer.cancelWriting() }; continuation.resume(throwing: error); return
                }
                // The pumps are finished now. Cancellation during finishWriting can safely
                // cancel the writer on this queue as well，instead of waiting for finalization.
                control.setWakeup {
                    vQueue.async { if writer.status == .writing { writer.cancelWriting() } }
                }
                writer.endSession(atSourceTime: CMTime(ticks: chunk.end))
                writer.finishWriting {
                    trace("writer finished status=\(writer.status.rawValue)")
                    if control.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else if writer.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: writer.error ?? AppError.message("区間の書込みに失敗しました。")) }
                }
            }
        }
    }
    private static func trace(_ message: String) {
        #if DEBUG
        fputs("ARTOFFICE export \(message)\n", stderr); fflush(stderr)
        #endif
    }
    static func mux(chunks: [ExportChunk], job: URL, output: URL, control: ExportControl) async throws {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw AppError.message("結合トラックを作成できません。") }
        for chunk in chunks {
            try control.check()
            let asset = AVURLAsset(url: chunkURL(chunk, job: job))
            guard let v = try await asset.loadTracks(withMediaType: .video).first,
                  let a = try await asset.loadTracks(withMediaType: .audio).first else { throw AppError.message("処理済み区間を開けません。") }
            let range = CMTimeRange(start: .zero, duration: CMTime(ticks: chunk.duration))
            try video.insertTimeRange(range, of: v, at: CMTime(ticks: chunk.start))
            try audio.insertTimeRange(range, of: a, at: CMTime(ticks: chunk.start))
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough),
              session.supportedFileTypes.contains(.mp4) else { throw AppError.message("MP4への無変換結合を利用できません。") }
        session.outputURL = output; session.outputFileType = .mp4; session.shouldOptimizeForNetworkUse = true
        control.attach(reader: nil, writer: nil, session: session)
        defer { control.attach(reader: nil, writer: nil) }
        await withCheckedContinuation { continuation in session.exportAsynchronously { continuation.resume() } }
        try control.check()
        guard session.status == .completed else { throw session.error ?? AppError.message("完成ファイルの作成に失敗しました。") }
    }
    static func residentMemory() -> UInt64 {
        var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}

/// Fills track gaps and silent clips with bounded stereo PCM blocks. Integer 48 kHz timestamps
/// avoid adding an AAC packet's duration to the global timeline at every chunk boundary.
final class AudioPump {
    let output: AVAssetReaderAudioMixOutput?
    var cursor: Int64
    let end: Int64
    let description: CMAudioFormatDescription
    var pending: CMSampleBuffer?
    var exhausted = false
    init(output: AVAssetReaderAudioMixOutput?, chunk: ExportChunk) throws {
        self.output = output
        cursor = CMTimeConvertScale(CMTime(ticks: chunk.start), timescale: 48_000, method: .roundHalfAwayFromZero).value
        end = CMTimeConvertScale(CMTime(ticks: chunk.end), timescale: 48_000, method: .roundHalfAwayFromZero).value
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        var desc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc)
        guard status == noErr, let desc else { throw AppError.message("音声形式を作成できません。") }; description = desc
    }
    func next() throws -> CMSampleBuffer? {
        guard cursor < end else { return nil }
        while true {
            if pending == nil && !exhausted { pending = output?.copyNextSampleBuffer(); if pending == nil { exhausted = true } }
            if let buffer = pending {
                let start = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(buffer), timescale: 48_000, method: .roundHalfAwayFromZero).value
                let count = Int64(CMSampleBufferGetNumSamples(buffer))
                if start + count <= cursor { pending = nil; continue }
                if start > cursor { return try silence(frames: Int(min(4096, min(end - cursor, start - cursor)))) }
                let offset = cursor - start, frames = min(count - offset, end - cursor)
                var slice: CMSampleBuffer?
                let status = CMSampleBufferCopySampleBufferForRange(allocator: kCFAllocatorDefault, sampleBuffer: buffer,
                    sampleRange: CFRange(location: Int(offset), length: Int(frames)), sampleBufferOut: &slice)
                guard status == noErr, let slice else { throw AppError.message("音声区間の切出しに失敗しました。") }
                cursor += frames; if offset + frames >= count { pending = nil }; return slice
            }
            return try silence(frames: Int(min(4096, end - cursor)))
        }
    }
    private func silence(frames: Int) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        let length = frames * 8
        let status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block,
              CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) == noErr
        else { throw AppError.message("無音区間を作成できません。") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: CMTime(value: cursor, timescale: 48_000), decodeTimeStamp: .invalid)
        var stride = 8, sample: CMSampleBuffer?
        let result = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &stride, sampleBufferOut: &sample)
        guard result == noErr, let sample else { throw AppError.message("無音データを作成できません。") }
        cursor += Int64(frames); return sample
    }
}
