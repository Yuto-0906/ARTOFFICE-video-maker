import Foundation

enum OutputFileLimit {
    static func maximum(signedBits: Int, fileSystem: String) -> Int64? {
        // FAT's on-disk file size is an unsigned 32-bit quantity. Some drivers
        // do not implement FILESIZEBITS，so do not depend on that query for FAT.
        if fileSystem == "msdos" { return 4_294_967_295 }
        guard signedBits > 1 else { return nil }
        if signedBits >= 64 { return Int64.max }
        return (Int64(1) << (signedBits - 1)) - 1
    }
    static func require(_ expectedBytes: Int64, maximum: Int64?) throws {
        guard let maximum, expectedBytes > maximum else { return }
        let size = ByteCountFormatter.string(fromByteCount: maximum, countStyle: .file)
        throw AppError.message("この保存先では1ファイルを\(size)までしか保存できません。動画の必要サイズが上限を超えるため，この場所へ保存できません。アプリ内または大きなファイルを保存できる別の保存先を選んでください。確定済みの処理区間は保持されます。")
    }
}
