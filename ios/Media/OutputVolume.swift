import Darwin
import Foundation

enum OutputVolume {
    /// Returns nil when the provider/driver does not expose its limit. This is
    /// a filesystem query，not a probe that allocates or writes a large file.
    static func maximumFileSize(at directory: URL) -> Int64? {
        directory.withUnsafeFileSystemRepresentation { path -> Int64? in
            guard let path else { return nil }
            var volume = statfs()
            guard Darwin.statfs(path, &volume) == 0 else { return nil }
            let name = withUnsafeBytes(of: volume.f_fstypename) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            return OutputFileLimit.maximum(signedBits: pathconf(path, _PC_FILESIZEBITS), fileSystem: name)
        }
    }
}
