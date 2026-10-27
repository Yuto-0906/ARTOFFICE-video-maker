import Foundation
import UIKit

struct DeviceBudget: Codable {
    var deviceClass: String
    var memoryBytes: UInt64
    var inFlightFrames: Int
    var previewHeight: Double
    var lowPowerModeEnabled: Bool? = nil
    var memoryWarningCount: Int? = nil
    static func current() -> Self {
        let memory = ProcessInfo.processInfo.physicalMemory
        let tablet = UIDevice.current.userInterfaceIdiom == .pad
        // Budget from actual memory and form factor，not a fabricated chip-name lookup.
        return Self(deviceClass: tablet ? "iPad" : "iPhone", memoryBytes: memory,
                    inFlightFrames: FramePipelineBudget.maximum(isTablet: tablet, reportedMemory: memory),
                    previewHeight: tablet ? 720 : 540,
                    lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
                    memoryWarningCount: RuntimePressure.shared.snapshot().memoryWarningCount)
    }
    var currentInFlight: Int {
        FramePipelineBudget.active(maximum: inFlightFrames,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            seriousHeat: ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue,
            memoryPressure: RuntimePressure.shared.snapshot().memoryConstrained)
    }
}
