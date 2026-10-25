import AVFoundation
import CoreImage
import Darwin
import Metal
import UIKit

/// Core Image executes the fused transforms/blend/title graph on Metal.
/// No CGImage/UIImage conversion or CPU pixel readback occurs per video frame.
final class MetalCompositor: NSObject, AVVideoCompositing {
    let sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange],
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]
    let supportsWideColorSourceFrames = true
    let supportsHDRSourceFrames = true
    private let queue = DispatchQueue(label: "artoffice.metal-compositor", qos: .userInitiated, attributes: .concurrent)
    private let budget = DeviceBudget.current()
    private let capacity = NSCondition()
    private var inFlight = 0
    private let context: CIContext?
    private let colorspace = CGColorSpace(name: CGColorSpace.itur_709)!
    private let titles = NSCache<NSString, CIImage>()
    private let lock = NSLock()
    private var generation = 0
    override init() {
        context = MTLCreateSystemDefaultDevice().map { device in
            CIContext(mtlDevice: device, options: [.cacheIntermediates: false,
                .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                .outputColorSpace: CGColorSpace(name: CGColorSpace.itur_709)!])
        }
        super.init(); titles.countLimit = 4
    }
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) { titles.removeAllObjects() }
    func cancelAllPendingVideoCompositionRequests() {
        lock.lock(); generation += 1; lock.unlock()
        capacity.lock(); capacity.broadcast(); capacity.unlock()
    }
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        trace("request", time: request.compositionTime)
        lock.lock(); let token = generation; lock.unlock()
        // Bound retained source and destination buffers before queueing GPU work. A hot
        // phone uses one frame; a cool iPad with sufficient memory can pipeline three.
        capacity.lock()
        while inFlight >= budget.thermalInFlight { capacity.wait() }
        inFlight += 1
        capacity.unlock()
        queue.async { [self] in
            defer { capacity.lock(); inFlight -= 1; capacity.broadcast(); capacity.unlock() }
            autoreleasepool {
                lock.lock(); let cancelled = token != generation; lock.unlock()
                if cancelled { request.finishCancelledRequest(); return }
                guard let context, let instruction = request.videoCompositionInstruction as? RenderInstruction,
                      let output = request.renderContext.newPixelBuffer() else {
                    request.finish(with: AppError.message("映像のGPU処理を開始できませんでした。")); return
                }
                trace("render beginning", time: request.compositionTime)
                let rect = CGRect(origin: .zero, size: request.renderContext.size)
                let black = CIImage(color: .black).cropped(to: rect)
                let time = request.compositionTime.ticks
                var images: [CIImage] = []
                for layer in instruction.layers {
                    guard let source = request.sourceFrame(byTrackID: layer.trackID) else {
                        request.finish(with: AppError.message("映像フレームを読み込めませんでした。")); return
                    }
                    var image = CIImage(cvPixelBuffer: source, options: [.toneMapHDRtoSDR: true])
                        .transformed(by: layer.transform).composited(over: black).cropped(to: rect)
                    let elapsed = Clock.seconds(time - layer.bandStart)
                    if elapsed >= 0 && elapsed < 5 {
                        let alpha = min(1, min(elapsed / 0.5, (5 - elapsed) / 0.5))
                        let title = title(layer.bandName, size: rect.size).applyingFilter("CIColorMatrix", parameters: [
                            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
                        ])
                        image = title.composited(over: image)
                    }
                    images.append(image)
                }
                guard var image = images.first else { request.finish(with: AppError.message("合成する映像がありません。")); return }
                if images.count == 2 {
                    let incoming = instruction.layers[1]
                    let mix = Double(time - incoming.clipStart) / Double(max(1, incoming.fadeIn))
                    image = image.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: images[1], kCIInputTimeKey: min(1, max(0, mix))])
                }
                context.render(image.cropped(to: rect), to: output, bounds: rect, colorSpace: colorspace)
                trace("render finished", time: request.compositionTime)
                request.finish(withComposedVideoFrame: output)
            }
        }
    }
    private func trace(_ message: String, time: CMTime) {
        #if DEBUG
        if time.ticks % Int64(Clock.scale) == 0 {
            fputs("ARTOFFICE export Metal \(message) t=\(time.seconds)\n", stderr); fflush(stderr)
        }
        #endif
    }
    private func title(_ text: String, size: CGSize) -> CIImage {
        let key = "\(size.width):\(text)" as NSString
        if let image = titles.object(forKey: key) { return image }
        let fontSize = size.height / 15
        let titleSize = CGSize(width: size.width * 0.9, height: fontSize * 2.7)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let raster = UIGraphicsImageRenderer(size: titleSize, format: format).image { _ in
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            let shadow = NSShadow(); shadow.shadowBlurRadius = fontSize * 0.08; shadow.shadowOffset = CGSize(width: 1, height: 2); shadow.shadowColor = UIColor.black
            (text as NSString).draw(in: CGRect(origin: .zero, size: titleSize), withAttributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .black), .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph, .shadow: shadow
            ])
        }
        let result = CIImage(cgImage: raster.cgImage!).transformed(by: CGAffineTransform(translationX: size.width * 0.05, y: size.height * 0.05))
        titles.setObject(result, forKey: key); return result
    }
}
