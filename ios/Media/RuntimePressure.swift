import Foundation
import UIKit

final class RuntimePressure: @unchecked Sendable {
    static let shared = RuntimePressure()
    struct Snapshot {
        var memoryWarningCount: Int
        var memoryConstrained: Bool
    }
    private let lock = NSLock()
    private let center: NotificationCenter
    private var observer: NSObjectProtocol?
    private var warningCount = 0
    private var lastWarning: TimeInterval?
    init(center: NotificationCenter = .default) {
        self.center = center
        observer = center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            self?.recordMemoryWarning()
        }
    }
    deinit { if let observer { center.removeObserver(observer) } }
    private func recordMemoryWarning() {
        lock.lock(); defer { lock.unlock() }
        warningCount += 1; lastWarning = ProcessInfo.processInfo.systemUptime
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        // A warning reduces new work for at least a minute. Repeated warnings renew it.
        let constrained = lastWarning.map { ProcessInfo.processInfo.systemUptime - $0 < 60 } ?? false
        return Snapshot(memoryWarningCount: warningCount, memoryConstrained: constrained)
    }
}
