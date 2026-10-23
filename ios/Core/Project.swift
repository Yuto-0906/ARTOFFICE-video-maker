import Foundation

/// Integer media clock. 600000 represents all supported output frame rates exactly.
enum Clock {
    static let scale: Int32 = 600_000
    static let fade: Int64 = 300_000
    static func ticks(_ seconds: Double) -> Int64 { Int64((seconds * Double(scale)).rounded()) }
    static func seconds(_ ticks: Int64) -> Double { Double(ticks) / Double(scale) }
    static func text(_ ticks: Int64, precise: Bool = false) -> String {
        let t = max(0, ticks), seconds = t / Int64(scale)
        let base = String(format: "%lld:%02lld:%02lld", seconds / 3600, seconds / 60 % 60, seconds % 60)
        return precise ? base + String(format: ".%03lld", t % Int64(scale) / 600) : base
    }
}

enum Resolution: String, Codable, CaseIterable, Identifiable {
    case fullHD = "1080p", quadHD = "1440p"
    var id: String { rawValue }
    var width: Int { self == .fullHD ? 1920 : 2560 }
    var height: Int { self == .fullHD ? 1080 : 1440 }
    var bitrate: Int { self == .fullHD ? 15_000_000 : 30_000_000 }
}

enum FrameRate: String, Codable, CaseIterable, Identifiable {
    case ntsc30 = "29.97", fps30 = "30", ntsc60 = "59.94", fps60 = "60"
    var id: String { rawValue }
    var frameTicks: Int64 {
        switch self { case .ntsc30: return 20_020; case .fps30: return 20_000
        case .ntsc60: return 10_010; case .fps60: return 10_000 }
    }
    var value: Double { Double(Clock.scale) / Double(frameTicks) }
    static func suggested(_ fps: Double) -> Self {
        if fps > 45 { return abs(fps - 59.94) < 0.02 ? .ntsc60 : .fps60 }
        return abs(fps - 29.97) < 0.02 ? .ntsc30 : .fps30
    }
}

struct MediaSource: Codable, Equatable {
    var fileName: String
    var relativePath: String?
    var bookmark: Data?
    var byteCount: Int64
    var modifiedAt: Date?
    var duration: Int64
    var nominalFPS: Double
    var width: Int
    var height: Int
    var hasAudio: Bool
    var isHDR: Bool
}

struct Clip: Codable, Identifiable, Equatable {
    var id = UUID()
    var source: MediaSource
    var bandName: String
    var start: Int64 = 0
    var end: Int64
    var joinPrevious = false
    init(source: MediaSource, bandName: String) {
        self.source = source; self.bandName = bandName; self.end = source.duration
    }
    var duration: Int64 { end - start }
    mutating func trimStart(_ ticks: Int64) { start = min(max(0, ticks), end - 1) }
    mutating func trimEnd(_ ticks: Int64) { end = max(start + 1, min(source.duration, ticks)) }
}

struct PhotoCrop: Codable, Equatable {
    var relativePath: String
    var centerX = 0.5
    var centerY = 0.5
    var zoom = 1.0
    func rect(width: Double, height: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        let w = min(width, height * 16 / 9) / min(5, max(1, zoom)), h = w * 9 / 16
        return (min(max(0, centerX * width - w / 2), width - w),
                min(max(0, centerY * height - h / 2), height - h), w, h)
    }
}

struct Project: Codable, Identifiable, Equatable {
    var schemaVersion = 1
    var id = UUID()
    var name = "新しいライブ"
    var modifiedAt = Date()
    var clips: [Clip] = []
    var resolution: Resolution = .fullHD
    var frameRate: FrameRate = .fps30
    var thumbnail: PhotoCrop?
    var selectedClip: UUID?
    var groups: [[Clip]] {
        var result: [[Clip]] = []
        for clip in clips {
            if clip.joinPrevious && !result.isEmpty { result[result.count - 1].append(clip) }
            else { result.append([clip]) }
        }
        return result
    }
    mutating func moveGroup(_ index: Int, by delta: Int) {
        var bands = groups
        guard bands.indices.contains(index), bands.indices.contains(index + delta) else { return }
        bands.swapAt(index, index + delta); clips = bands.flatMap { $0 }
        clips[0].joinPrevious = false
    }
    mutating func removeClip(_ id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        if !clips[i].joinPrevious, i + 1 < clips.count, clips[i + 1].joinPrevious {
            clips[i + 1].joinPrevious = false; clips[i + 1].bandName = clips[i].bandName
        }
        clips.remove(at: i)
        if !clips.isEmpty { clips[0].joinPrevious = false }
        if selectedClip == id { selectedClip = clips.first?.id }
    }
    func validate() throws {
        guard schemaVersion == 1 else { throw AppError.message("未対応の保存形式です。") }
        guard Set(clips.map(\.id)).count == clips.count else { throw AppError.message("動画の識別情報が重複しています。") }
        for (i, clip) in clips.enumerated() {
            let s = clip.source
            guard s.duration > 0, s.duration < 100_000 * 3600 * Int64(Clock.scale),
                  s.nominalFPS.isFinite, (1...480).contains(s.nominalFPS),
                  s.width > 0, s.height > 0, s.byteCount >= 0,
                  clip.start >= 0, clip.end > clip.start, clip.end <= s.duration,
                  !(i == 0 && clip.joinPrevious),
                  (s.relativePath != nil) != (s.bookmark != nil) else {
                throw AppError.message("動画の情報またはカット範囲が不正です。")
            }
            if let path = s.relativePath, !Self.safeMediaPath(path) { throw AppError.message("素材の保存先が不正です。") }
        }
        if let p = thumbnail {
            guard Self.safeMediaPath(p.relativePath), p.centerX.isFinite, p.centerY.isFinite,
                  (0...1).contains(p.centerX), (0...1).contains(p.centerY), p.zoom.isFinite, (1...5).contains(p.zoom)
            else { throw AppError.message("写真の切抜き情報が不正です。") }
        }
    }
    static func safeMediaPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0] == "Media" && !parts[1].isEmpty && parts[1] != "." && parts[1] != ".."
            && !path.contains("\\") && !path.contains(":") && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let message): return message } }
}

enum Naming {
    static func parse(_ file: String) -> (order: Int, band: String)? {
        let stem = (file as NSString).deletingPathExtension
        guard let split = stem.firstIndex(of: "_") else { return nil }
        let number = stem[..<split], band = stem[stem.index(after: split)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty, number.allSatisfy({ $0 >= "0" && $0 <= "9" }), let order = Int(number), order > 0, !band.isEmpty else { return nil }
        return (order, band)
    }
    static func safeStem(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)
        let value = String(name.unicodeScalars.map { bad.contains($0) ? Character("_") : Character($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return value.isEmpty ? "ライブ動画" : String(value.prefix(100))
    }
}
