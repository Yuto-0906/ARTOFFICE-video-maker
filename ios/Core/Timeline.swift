import Foundation

struct TimelineSegment: Equatable {
    var clip: Clip
    var index: Int
    var start: Int64
    var incoming: Int64
    var outgoing: Int64
    var end: Int64 { start + clip.duration }
    var isBandHead: Bool { index == 0 || !clip.joinPrevious }
}

struct ExportChunk: Codable, Equatable, Identifiable {
    var index: Int
    var start: Int64
    var end: Int64
    var id: Int { index }
    var duration: Int64 { end - start }
}

struct Timeline {
    let segments: [TimelineSegment]
    var duration: Int64 { segments.last?.end ?? 0 }
    init(_ project: Project) throws {
        try project.validate()
        var result: [TimelineSegment] = [], cursor: Int64 = 0
        for (index, clip) in project.clips.enumerated() {
            let incoming = index > 0 && !clip.joinPrevious ? Clock.fade : 0
            let outgoing = index + 1 < project.clips.count && !project.clips[index + 1].joinPrevious ? Clock.fade : 0
            guard clip.duration > incoming + outgoing else { throw AppError.message("\(clip.bandName)の範囲が短すぎます。フェードが重ならないように広げてください。") }
            guard !clip.bandName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.message("バンド名を入力してください。") }
            cursor -= incoming
            result.append(TimelineSegment(clip: clip, index: index, start: cursor, incoming: incoming, outgoing: outgoing))
            cursor += clip.duration
        }
        segments = result
    }
    var chapters: String {
        segments.filter(\.isBandHead).map {
            Clock.text($0.start) + " " + $0.clip.bandName.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        }.joined(separator: "\n") + (segments.isEmpty ? "" : "\n")
    }
    var warnings: [String] {
        let bands = segments.filter(\.isBandHead)
        var result: [String] = []
        if bands.count < 3 && !bands.isEmpty { result.append("YouTubeのチャプター表示には3件以上の時刻が必要です。") }
        for (i, band) in bands.enumerated() {
            let end = i + 1 < bands.count ? bands[i + 1].start : duration
            if end / Int64(Clock.scale) - band.start / Int64(Clock.scale) < 10 { result.append("\(band.clip.bandName)のチャプターは10秒未満です。") }
        }
        return result
    }
    func chunks(rate: FrameRate, seconds: Int = 300) -> [ExportChunk] {
        guard duration > 0 else { return [] }
        let totalFrames = max(1, duration / rate.frameTicks)
        let framesPerChunk = max(1, Int64(seconds) * Int64(Clock.scale) / rate.frameTicks)
        var frame: Int64 = 0, result: [ExportChunk] = []
        while frame < totalFrames {
            let next = min(totalFrames, frame + framesPerChunk)
            result.append(ExportChunk(index: result.count, start: frame * rate.frameTicks, end: next * rate.frameTicks))
            frame = next
        }
        return result
    }
}

struct CapacityEstimate {
    let output: Int64
    let localWorking: Int64
    let destinationWorking: Int64
    init(duration: Int64, resolution: Resolution, separateDestination: Bool) {
        let bytes = Clock.seconds(duration) * Double(resolution.bitrate + 384_000) / 8
        output = Int64(bytes.rounded(.up))
        // Chunks coexist with the final file. Include 20% rate/container headroom and 1 GB spare.
        localWorking = Int64(bytes * (separateDestination ? 1.2 : 2.4)) + 1_000_000_000
        destinationWorking = separateDestination ? Int64(bytes * 1.2) + 1_000_000_000 : 0
    }
}
