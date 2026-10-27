import Foundation

enum FramePipelineBudget {
    static func active(maximum: Int, lowPowerMode: Bool, seriousHeat: Bool, memoryPressure: Bool) -> Int {
        lowPowerMode || seriousHeat || memoryPressure ? 1 : maximum
    }
    static func maximum(isTablet: Bool, reportedMemory: UInt64) -> Int {
        // The tested 8 GB M4 iPad reports 7,732,772,864 bytes after reserved memory.
        // Leave room for that reservation while excluding tablets with 6 GB or less.
        let tabletMemoryFloor: UInt64 = 7 * 1024 * 1024 * 1024
        return isTablet && reportedMemory >= tabletMemoryFloor ? 3 : 2
    }
}
