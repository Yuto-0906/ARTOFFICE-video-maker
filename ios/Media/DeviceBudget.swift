import Foundation
import UIKit

struct DeviceBudget: Codable {
    var deviceClass: String
    var memoryBytes: UInt64
    var inFlightFrames: Int
    var previewHeight: Double
    static func current() -> Self {
        let memory = ProcessInfo.processInfo.physicalMemory
        let tablet = UIDevice.current.userInterfaceIdiom == .pad
        // Budget from actual memory and form factor，not a fabricated chip-name lookup.
        return Self(deviceClass: tablet ? "iPad" : "iPhone", memoryBytes: memory,
                    inFlightFrames: tablet && memory >= 8_000_000_000 ? 3 : 2,
                    previewHeight: tablet ? 720 : 540)
    }
    var thermalInFlight: Int {
        ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue ? 1 : inFlightFrames
    }
}
