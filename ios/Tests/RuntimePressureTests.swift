import UIKit
import XCTest
@testable import ARTOFFICE

final class RuntimePressureTests: XCTestCase {
    func testMemoryWarningIsCountedAndObserverDoesNotRetainMonitor() {
        let center = NotificationCenter()
        var monitor: RuntimePressure? = RuntimePressure(center: center)
        weak var retained = monitor
        XCTAssertEqual(monitor?.snapshot().memoryWarningCount, 0)
        XCTAssertEqual(monitor?.snapshot().memoryConstrained, false)
        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertEqual(monitor?.snapshot().memoryWarningCount, 1)
        XCTAssertEqual(monitor?.snapshot().memoryConstrained, true)
        monitor = nil
        XCTAssertNil(retained)
        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }
}
