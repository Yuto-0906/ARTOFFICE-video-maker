import Foundation

/// Describes only content that can contribute to this interval. Global positions
/// remain part of the identity，including the inherited title of joined files.
struct ChunkIdentity: Encodable {
    struct Layer: Encodable {
        var source: MediaSource
        var sourceStart: Int64
        var start: Int64
        var end: Int64
        var incoming: Int64
        var outgoing: Int64
        var title: String?
        var titleStart: Int64?
    }
    var rendererVersion: Int
    var range: ExportChunk
    var resolution: Resolution
    var frameRate: FrameRate
    var audioBitRate: Int
    var layers: [Layer]

    init(project: Project, timeline: Timeline, chunk: ExportChunk, rendererVersion: Int, audioBitRate: Int) {
        self.rendererVersion = rendererVersion; range = chunk
        resolution = project.resolution; frameRate = project.outputFrameRate; self.audioBitRate = audioBitRate
        var bandName = "", bandStart: Int64 = 0
        var result: [Layer] = []
        for segment in timeline.segments {
            if segment.isBandHead { bandName = segment.clip.bandName; bandStart = segment.start }
            guard segment.start < chunk.end, segment.end > chunk.start else { continue }
            let hasTitle = max(segment.start, chunk.start, bandStart) < min(segment.end, chunk.end, bandStart + Clock.ticks(5))
            result.append(Layer(source: segment.clip.source, sourceStart: segment.clip.start,
                start: segment.start, end: segment.end, incoming: segment.incoming, outgoing: segment.outgoing,
                title: hasTitle ? bandName : nil, titleStart: hasTitle ? bandStart : nil))
        }
        layers = result
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }
}
