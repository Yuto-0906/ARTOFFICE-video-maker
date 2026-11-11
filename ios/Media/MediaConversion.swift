import AVFoundation
import Foundation
import ffmpegkit

/// Convert only sources that AVFoundation cannot play. Imported originals stay intact.
enum MediaConversion {
    private static let queue = DispatchQueue(label: "com.yuto0906.artoffice.media-conversion", qos: .userInitiated)

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var session: Int64?
        private var cancelled = false
        func install(_ id: Int64) {
            lock.lock(); session = id; let stop = cancelled; lock.unlock()
            if stop { FFmpegKit.cancel(id) }
        }
        func cancel() {
            lock.lock(); cancelled = true; let id = session; lock.unlock()
            if let id { FFmpegKit.cancel(id) }
        }
    }

    static func run(_ arguments: [String]) async throws {
        let cancellation = Cancellation()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let session = FFmpegKit.executeWithArgumentsAsync(arguments, withCompleteCallback: { session in
                    if ReturnCode.isSuccess(session.getReturnCode()) { continuation.resume() }
                    else if ReturnCode.isCancel(session.getReturnCode()) { continuation.resume(throwing: CancellationError()) }
                    else {
                        #if DEBUG
                        print("ARTOFFICE conversion diagnostic: \(session.getOutput())")
                        #endif
                        continuation.resume(throwing: AppError.message("この動画を変換できませんでした。映像・音声形式を確認してください。"))
                    }
                }, onDispatchQueue: queue)
                cancellation.install(session.getSessionId())
            }
            try Task.checkCancellation()
        } onCancel: { cancellation.cancel() }
    }

    static func normalize(_ source: URL, output: URL, storage: URL, minimumDuration: Int64) async throws {
        // This FFmpegKit bridge captures av_log, not FFprobe's JSON stdout.
        // Write machine-readable metadata separately so decoder messages cannot mix with it.
        let metadataURL = output.deletingLastPathComponent().appendingPathComponent("metadata-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: metadataURL) }
        let session = FFprobeKit.executeWithArguments(["-v", "error", "-hide_banner", "-protocol_whitelist", "file,pipe",
            "-show_format", "-show_streams", "-of", "json", "-o", metadataURL.path, source.path])
        guard ReturnCode.isSuccess(session.getReturnCode()),
              let json = try? String(contentsOf: metadataURL, encoding: .utf8),
              let information = MediaInformationJsonParser.from(json),
              let video = information.getStreams().first(where: { $0.getType() == "video" }),
              let duration = information.getDuration().flatMap(Double.init), duration.isFinite, duration > 0,
              let width = video.getWidth()?.intValue, let height = video.getHeight()?.intValue,
              width > 0, height > 0 else {
            #if DEBUG
            print("ARTOFFICE metadata diagnostic: \(session.getOutput())")
            #endif
            throw AppError.message("動画の映像または長さを取得できませんでした。")
        }
        guard duration >= Clock.seconds(minimumDuration) else { throw AppError.message("元のカット範囲より短い動画です。対応する素材を選んでください。") }
        let codec = video.getCodec() ?? ""
        let pixelFormat = video.getFormat() ?? ""
        let copyVideo = (codec == "h264" && pixelFormat == "yuv420p") || (codec == "hevc" && ["yuv420p", "yuv420p10le"].contains(pixelFormat))
        let bitrate = min(60_000_000.0, max(4_000_000.0, Double(width) * Double(height) * 6))
        let sourceBytes = Double((try source.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
        let estimated = (copyVideo ? sourceBytes * 1.2 + duration * 384_000 / 8 : duration * (bitrate + 384_000) / 8 * 1.15) + 100_000_000
        guard estimated.isFinite, estimated < Double(Int64.max) else { throw AppError.message("動画が大きすぎます。") }
        try MediaFiles.requireSpace(Int64(estimated), at: storage)
        let input = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-protocol_whitelist", "file,pipe", "-i", source.path,
                     "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn"]
        let outputOptions = ["-c:a", "aac", "-b:a", "384k", "-ar", "48000", "-ac", "2", "-movflags", "+faststart", output.path]
        if copyVideo {
            do {
                try await run(input + ["-c:v", "copy", "-tag:v", codec == "hevc" ? "hvc1" : "avc1"] + outputOptions)
                if try await isPlayable(output) { return }
            } catch is CancellationError { throw CancellationError() } catch { /* Try a decoded conversion below. */ }
        }
        let transcodeBytes = duration * (bitrate + 384_000) / 8 * 1.15 + 100_000_000
        guard transcodeBytes.isFinite, transcodeBytes < Double(Int64.max) else { throw AppError.message("動画が大きすぎます。") }
        try MediaFiles.requireSpace(Int64(transcodeBytes), at: storage)
        // Preserve the source dimensions and frame rate. VideoToolbox uses the device encoder.
        let filter = ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p"]
        do {
            try await run(input + filter + ["-c:v", "h264_videotoolbox", "-allow_sw", "1", "-b:v", String(Int(bitrate))] + outputOptions)
            if try await isPlayable(output) { return }
        } catch is CancellationError { throw CancellationError() } catch { /* Simulator/older hardware may lack an H.264 encoder. */ }
        try await run(input + filter + ["-c:v", "mpeg4", "-q:v", "2"] + outputOptions)
        guard try await isPlayable(output) else { throw AppError.message("変換後の動画を再生できませんでした。") }
    }

    static func isPlayable(_ url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        return try await asset.load(.isPlayable)
    }

    /// ImageIO handles standard pictures; FFmpeg supplies a first-frame fallback.
    static func decodeImage(_ source: URL, output: URL, maxPixels: Int) throws {
        let filter = "scale=\(maxPixels):\(maxPixels):force_original_aspect_ratio=decrease"
        let session = FFmpegKit.executeWithArguments(["-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-protocol_whitelist", "file,pipe", "-i", source.path, "-frames:v", "1", "-vf", filter, "-update", "1", output.path])
        guard ReturnCode.isSuccess(session.getReturnCode()) else { throw AppError.message("写真を読み込めませんでした。") }
    }
}
