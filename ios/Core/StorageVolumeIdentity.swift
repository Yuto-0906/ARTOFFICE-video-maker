import Foundation

enum StorageVolumeIdentity {
    static func matches(_ local: NSObject?, _ destination: NSObject?) -> Bool {
        // Two providers omitting their identifiers are not evidence of one volume.
        guard let local, let destination else { return false }
        return local == destination
    }
}
