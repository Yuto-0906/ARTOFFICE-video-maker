import Foundation

enum MediaFormats {
    static let videoExtensions = ["mp4", "mov", "m4v", "mkv", "webm", "mts", "m2ts", "avi", "wmv"]
    static let imageExtensions = ["jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff", "bmp", "avif", "gif"]
    static func isVideo(_ url: URL) -> Bool { videoExtensions.contains(url.pathExtension.lowercased()) }
}

enum ThumbnailOutputFormat: String, Codable, CaseIterable {
    case jpeg = "jpg"
    case png
    var label: String { self == .jpeg ? "JPEG" : "PNG" }
}
