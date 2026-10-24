import AVFoundation
import CoreTransferable
import CryptoKit
import ImageIO
import UIKit
import UniformTypeIdentifiers

extension CMTime {
    init(ticks: Int64) { self.init(value: ticks, timescale: Clock.scale) }
    var ticks: Int64 { CMTimeConvertScale(self, timescale: Clock.scale, method: .roundHalfAwayFromZero).value }
}

/// Keeps a security-scoped resource alive for the whole playback/export，not only the import.
final class SourceLease {
    let url: URL
    private let scoped: Bool
    init(source: MediaSource, projectDirectory: URL) throws {
        if let relative = source.relativePath {
            guard Project.safeMediaPath(relative) else { throw AppError.message("素材パスが不正です。") }
            url = projectDirectory.appendingPathComponent(relative); scoped = false
            let actual = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard actual.hasPrefix(projectDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/") else {
                throw AppError.message("素材の保存先がプロジェクトの外にあります。")
            }
        } else if let bookmark = source.bookmark {
            var stale = false
            url = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, bookmarkDataIsStale: &stale)
            scoped = url.startAccessingSecurityScopedResource()
        } else { throw AppError.message("素材の参照がありません。") }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw AppError.message("\(source.fileName)を開けません。「素材を選び直す」で復旧してください。")
        }
    }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

enum MediaFiles {
    static func freeBytes(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
    }
    static func requireSpace(_ bytes: Int64, at url: URL) throws {
        guard try freeBytes(at: url) >= bytes else { throw AppError.message("空き容量が不足しています。必要容量の目安：\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))") }
    }
    static func probe(_ url: URL, relativePath: String?, bookmark: Data?) async throws -> MediaSource {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let videos = try await asset.loadTracks(withMediaType: .video)
        guard duration.isNumeric, duration.seconds > 0, let video = videos.first else { throw AppError.message("再生できる動画がありません。") }
        let size = try await video.load(.naturalSize), transform = try await video.load(.preferredTransform)
        let display = CGRect(origin: .zero, size: size).applying(transform)
        let fps = try await video.load(.nominalFrameRate)
        let descriptions = try await video.load(.formatDescriptions)
        let hdr = descriptions.contains { description in
            let transfer = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            return transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
                || transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return MediaSource(fileName: url.lastPathComponent, relativePath: relativePath, bookmark: bookmark,
                           byteCount: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate,
                           duration: duration.ticks, nominalFPS: fps > 0 ? Double(fps) : 30,
                           width: Int(abs(display.width)), height: Int(abs(display.height)),
                           hasAudio: !(try await asset.loadTracks(withMediaType: .audio)).isEmpty, isHDR: hdr)
    }
    static func importVideo(_ url: URL, copy: Bool, directory: URL, ownedTemporary: Bool = false,
                            selectionIdentity: String? = nil, existingIDs: Set<String> = []) async throws -> Clip {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let original = url.lastPathComponent
        let metadata = try await probe(url, relativePath: nil, bookmark: nil)
        var source = metadata
        // Identify the selected asset，rather than treating a partial content hash as proof
        // that distinct concert recordings are identical. No full-file hash is needed.
        let origin = selectionIdentity ?? "file:\(url.standardizedFileURL.path):\(metadata.byteCount):\(metadata.modifiedAt?.timeIntervalSince1970 ?? 0)"
        let identity = SHA256.hash(data: Data(origin.utf8)).map { String(format: "%02x", $0) }.joined()
        guard !existingIDs.contains(identity) else { throw AppError.message("同じ素材は既に取り込まれています。") }
        source.importIdentity = identity
        if copy {
            let media = directory.appendingPathComponent("Media", isDirectory: true)
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            try requireSpace((ownedTemporary ? 0 : metadata.byteCount) + 100_000_000, at: media)
            let relative = "Media/\(UUID().uuidString).\(url.pathExtension.lowercased())"
            let dest = directory.appendingPathComponent(relative)
            do {
                if ownedTemporary { try FileManager.default.moveItem(at: url, to: dest) }
                else { try FileManager.default.copyItem(at: url, to: dest) }
                try Task.checkCancellation()
            }
            catch { try? FileManager.default.removeItem(at: dest); throw error }
            source.relativePath = relative
            source.modifiedAt = try dest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            source.modifiedAt = try dest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        } else {
            source.bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            // Prove the persisted reference resolves before committing it to the project.
            let lease = try SourceLease(source: source, projectDirectory: directory)
            guard lease.url.standardizedFileURL == url.standardizedFileURL else { throw AppError.message("素材の参照を保存できません。コピーして取り込んでください。") }
        }
        source.fileName = original
        return Clip(source: source, bandName: Naming.parse(original)?.band ?? (original as NSString).deletingPathExtension)
    }
    static func photo(_ url: URL, maxPixels: Int = 4096) throws -> UIImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw AppError.message("写真を読み込めませんでした。") }
        return UIImage(cgImage: cgImage)
    }
    static func importPhoto(_ url: URL, directory: URL) throws -> PhotoCrop {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let image = try photo(url)
        let relative = "Media/\(UUID().uuidString).jpg"
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Media"), withIntermediateDirectories: true)
        guard let data = image.jpegData(compressionQuality: 0.95) else { throw AppError.message("写真の保存に失敗しました。") }
        try requireSpace(Int64(data.count) + 10_000_000, at: directory)
        try data.write(to: directory.appendingPathComponent(relative), options: .atomic)
        return PhotoCrop(relativePath: relative)
    }
    static func exportPhoto(_ crop: PhotoCrop, directory: URL, output: URL) throws {
        let image = try photo(directory.appendingPathComponent(crop.relativePath))
        let rect = crop.rect(width: image.size.width, height: image.size.height)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let result = UIGraphicsImageRenderer(size: CGSize(width: 1920, height: 1080), format: format).image { _ in
            image.draw(in: CGRect(x: -rect.x * 1920 / rect.width, y: -rect.y * 1080 / rect.height,
                                  width: image.size.width * 1920 / rect.width, height: image.size.height * 1080 / rect.height))
        }
        guard let data = result.jpegData(compressionQuality: 0.94) else { throw AppError.message("サムネイルを作成できませんでした。") }
        try data.write(to: output, options: .atomic)
    }
}

/// The Photos picker URL is ephemeral. Copy it inside the Transferable callback.
struct PickedMedia: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let dest = directory.appendingPathComponent(received.file.lastPathComponent)
            try MediaFiles.requireSpace(Int64((try received.file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0) + 100_000_000, at: directory)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMedia(url: dest)
        }
    }
}
