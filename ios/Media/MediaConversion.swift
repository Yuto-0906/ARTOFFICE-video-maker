import AVFoundation
import Foundation
import ffmpegkit
import NativeFFmpeg

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
        let information = try probe(source)
        let duration = information.duration, width = information.width, height = information.height
        guard duration >= Clock.seconds(minimumDuration) else { throw AppError.message("元のカット範囲より短い動画です。対応する素材を選んでください。") }
        let codec = information.codec
        let pixelFormat = information.pixelFormat
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

    private struct Information {
        let duration: Double
        let width: Int
        let height: Int
        let codec: String
        let pixelFormat: String
    }

    /// Each source owns its format context. FFprobe's CLI keeps process-global
    /// output state in this dependency and cannot safely be called repeatedly.
    private static func probe(_ source: URL) throws -> Information {
        var context: UnsafeMutablePointer<AVFormatContext>?
        defer { avformat_close_input(&context) }
        let opened = avformat_open_input(&context, source.path, nil, nil)
        guard opened >= 0, let format = context else {
            throw AppError.message("動画を開けませんでした。")
        }
        guard avformat_find_stream_info(format, nil) >= 0, let streams = format.pointee.streams else {
            throw AppError.message("動画の情報を取得できませんでした。")
        }
        for index in 0..<Int(format.pointee.nb_streams) {
            guard let stream = streams[index], let pointer = stream.pointee.codecpar,
                  pointer.pointee.codec_type == AVMEDIA_TYPE_VIDEO else { continue }
            let parameters = pointer.pointee
            var duration = Double(format.pointee.duration) / 1_000_000
            if !duration.isFinite || duration <= 0 {
                let base = stream.pointee.time_base
                duration = Double(stream.pointee.duration) * Double(base.num) / Double(base.den)
            }
            guard duration.isFinite, duration > 0, parameters.width > 0, parameters.height > 0 else {
                throw AppError.message("動画の映像または長さを取得できませんでした。")
            }
            let codec = avcodec_get_name(parameters.codec_id).map { String(cString: $0) } ?? ""
            let pixelFormat = av_get_pix_fmt_name(AVPixelFormat(rawValue: parameters.format)).map { String(cString: $0) } ?? ""
            return Information(duration: duration, width: Int(parameters.width), height: Int(parameters.height), codec: codec, pixelFormat: pixelFormat)
        }
        throw AppError.message("映像のある動画を選択してください。")
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
