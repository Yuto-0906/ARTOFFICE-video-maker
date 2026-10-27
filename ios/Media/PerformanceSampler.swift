import Foundation

struct PerformanceWindow: Codable {
    var elapsedSeconds: Double
    var peakResidentBytes: UInt64
    var thermalState: Int
    var lowPowerModeEnabled: Bool? = nil
    var memoryWarningCount: Int? = nil
    var minimumInFlightFrameLimit: Int? = nil
}

/// Keep one aggregate per minute. The timer never retains video/audio buffers，and
/// a fixed window limit bounds its own memory during unusually long exports.
final class PerformanceSampler: @unchecked Sendable {
    private let lock = NSLock()
    private let budget: DeviceBudget
    private let started = ProcessInfo.processInfo.systemUptime
    private var windows: [PerformanceWindow] = []
    private var peak: UInt64 = 0
    private var timer: DispatchSourceTimer?
    init(budget: DeviceBudget) {
        self.budget = budget
        sample()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer; timer.resume()
    }
    deinit { timer?.cancel() }
    private func sample() {
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let bytes = ExportEngine.residentMemory(), thermal = ProcessInfo.processInfo.thermalState.rawValue
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let pressure = RuntimePressure.shared.snapshot()
        let frameLimit = FramePipelineBudget.active(maximum: budget.inFlightFrames, lowPowerMode: lowPower,
            seriousHeat: thermal >= ProcessInfo.ThermalState.serious.rawValue, memoryPressure: pressure.memoryConstrained)
        lock.lock(); defer { lock.unlock() }
        peak = max(peak, bytes)
        if let last = windows.last, Int(last.elapsedSeconds / 60) == Int(elapsed / 60) {
            windows[windows.count - 1].peakResidentBytes = max(last.peakResidentBytes, bytes)
            windows[windows.count - 1].thermalState = max(last.thermalState, thermal)
            windows[windows.count - 1].lowPowerModeEnabled = (last.lowPowerModeEnabled ?? false) || lowPower
            windows[windows.count - 1].memoryWarningCount = max(last.memoryWarningCount ?? 0, pressure.memoryWarningCount)
            windows[windows.count - 1].minimumInFlightFrameLimit = min(last.minimumInFlightFrameLimit ?? frameLimit, frameLimit)
        } else {
            if windows.count == 4096 { windows.removeFirst() }
            windows.append(PerformanceWindow(elapsedSeconds: elapsed, peakResidentBytes: bytes, thermalState: thermal,
                lowPowerModeEnabled: lowPower, memoryWarningCount: pressure.memoryWarningCount,
                minimumInFlightFrameLimit: frameLimit))
        }
    }
    func snapshot() -> (peak: UInt64, windows: [PerformanceWindow]) {
        sample()
        lock.lock(); defer { lock.unlock() }
        return (peak, windows)
    }
}
