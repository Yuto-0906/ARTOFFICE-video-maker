import AVFoundation
import CoreImage
import Metal

struct RenderLayer {
    var trackID: CMPersistentTrackID
    var transform: CGAffineTransform
    var bandName: String
    var bandStart: Int64
    var clipStart: Int64
    var fadeIn: Int64
}

final class RenderInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let requiredSourceTrackIDs: [NSValue]?
    let layers: [RenderLayer]
    init(range: CMTimeRange, layers: [RenderLayer]) {
        timeRange = range; self.layers = layers
        requiredSourceTrackIDs = layers.map { NSNumber(value: $0.trackID) }
    }
}

struct RenderComposition {
    let asset: AVMutableComposition
    let video: AVMutableVideoComposition
    let audio: AVMutableAudioMix
    let leases: [SourceLease]
}

enum CompositionBuilder {
    static func build(project: Project, directory: URL, previewHeight: Int? = nil) async throws -> RenderComposition {
        guard MTLCreateSystemDefaultDevice() != nil else { throw AppError.message("Metalによる映像処理を利用できません。") }
        let timeline = try Timeline(project)
        guard !timeline.segments.isEmpty else { throw AppError.message("動画を追加してください。") }
        let composition = AVMutableComposition()
        var videos: [AVMutableCompositionTrack] = [], audios: [AVMutableCompositionTrack] = []
        for _ in 0..<2 {
            guard let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw AppError.message("編集用トラックを作成できませんでした。") }
            videos.append(v); audios.append(a)
        }
        let audioParameters = audios.map { AVMutableAudioMixInputParameters(track: $0) }
        var leases: [SourceLease] = [], layers: [RenderLayer] = []
        var bandStart: Int64 = 0, bandName = ""
        // Only the preview opts into a smaller render target. Export always uses
        // the project's selected size and the same timing，fades and title logic.
        let height = previewHeight.map { max(180, min(project.resolution.height, $0)) } ?? project.resolution.height
        let size = previewHeight == nil ? CGSize(width: project.resolution.width, height: height)
            : CGSize(width: height * 16 / 9, height: height)
        for segment in timeline.segments {
            try Task.checkCancellation()
            let lease = try SourceLease(source: segment.clip.source, projectDirectory: directory)
            leases.append(lease)
            let values = try lease.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard Int64(values.fileSize ?? -1) == segment.clip.source.byteCount,
                  segment.clip.source.modifiedAt == nil || values.contentModificationDate == segment.clip.source.modifiedAt
            else { throw AppError.message("\(segment.clip.source.fileName)が変更されています。素材を選び直してください。") }
            let asset = AVURLAsset(url: lease.url)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw AppError.message("動画トラックがありません。") }
            let range = CMTimeRange(start: CMTime(ticks: segment.clip.start), duration: CMTime(ticks: segment.clip.duration))
            let at = CMTime(ticks: segment.start), index = segment.index % 2
            try videos[index].insertTimeRange(range, of: video, at: at)
            if let audio = try await asset.loadTracks(withMediaType: .audio).first {
                let available = try await audio.load(.timeRange)
                let intersection = CMTimeRangeGetIntersection(range, otherRange: available)
                if intersection.duration > .zero {
                    let offset = intersection.start - range.start
                    try audios[index].insertTimeRange(intersection, of: audio, at: at + offset)
                }
                let parameters = audioParameters[index]
                parameters.setVolume(1, at: at)
                if segment.incoming > 0 {
                    parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                        timeRange: CMTimeRange(start: at, duration: CMTime(ticks: segment.incoming)))
                }
                if segment.outgoing > 0 {
                    parameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                        timeRange: CMTimeRange(start: CMTime(ticks: segment.end - segment.outgoing), duration: CMTime(ticks: segment.outgoing)))
                }
            }
            let natural = try await video.load(.naturalSize), preferred = try await video.load(.preferredTransform)
            let bounds = CGRect(origin: .zero, size: natural).applying(preferred)
            let scale = min(size.width / abs(bounds.width), size.height / abs(bounds.height))
            let transform = preferred.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: (size.width - abs(bounds.width) * scale) / 2,
                                               y: (size.height - abs(bounds.height) * scale) / 2))
            // Track transforms use video coordinates with the origin at the top left.
            // Core Image uses the bottom left，so convert both coordinate systems.
            let coreTransform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: natural.height)
                .concatenating(transform)
                .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height))
            if segment.isBandHead { bandStart = segment.start; bandName = segment.clip.bandName }
            layers.append(RenderLayer(trackID: videos[index].trackID, transform: coreTransform, bandName: bandName,
                                      bandStart: bandStart, clipStart: segment.start, fadeIn: segment.incoming))
        }
        let boundaries = Array(Set(timeline.segments.flatMap { [$0.start, $0.end] })).sorted()
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = MetalCompositor.self
        videoComposition.renderSize = size
        videoComposition.frameDuration = CMTime(ticks: project.outputFrameRate.frameTicks)
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        videoComposition.instructions = zip(boundaries, boundaries.dropFirst()).compactMap { start, end in
            let active = timeline.segments.filter { $0.start <= start && $0.end > start }.map { layers[$0.index] }
            guard !active.isEmpty, end > start else { return nil }
            return RenderInstruction(range: CMTimeRange(start: CMTime(ticks: start), duration: CMTime(ticks: end - start)), layers: active)
        }
        let audioMix = AVMutableAudioMix(); audioMix.inputParameters = audioParameters
        return RenderComposition(asset: composition, video: videoComposition, audio: audioMix, leases: leases)
    }
}
