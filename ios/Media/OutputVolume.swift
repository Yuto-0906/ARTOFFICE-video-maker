import Darwin
import Foundation

enum OutputVolume {
    /// Returns nil when the provider/driver does not expose its limit. This is
    /// a filesystem query，not a probe that allocates or writes a large file.
    static func maximumFileSize(at directory: URL) -> Int64? {
        directory.withUnsafeFileSystemRepresentation { path -> Int64? in
            guard let path else { return nil }
            let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }
            var volume = statfs()
            guard fstatfs(descriptor, &volume) == 0 else { return nil }
            let name = withUnsafeBytes(of: volume.f_fstypename) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            return OutputFileLimit.maximum(signedBits: fpathconf(descriptor, _PC_FILESIZEBITS), fileSystem: name)
        }
    }
}
