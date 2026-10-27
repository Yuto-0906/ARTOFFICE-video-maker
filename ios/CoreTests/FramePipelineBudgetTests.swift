import XCTest
@testable import ARTOFFICECore

final class FramePipelineBudgetTests: XCTestCase {
    func testPowerHeatAndMemoryPressureLimitOutstandingFrames() {
        for maximum in [2, 3] {
            XCTAssertEqual(FramePipelineBudget.active(maximum: maximum, lowPowerMode: false, seriousHeat: false, memoryPressure: false), maximum)
            XCTAssertEqual(FramePipelineBudget.active(maximum: maximum, lowPowerMode: true, seriousHeat: false, memoryPressure: false), 1)
            XCTAssertEqual(FramePipelineBudget.active(maximum: maximum, lowPowerMode: false, seriousHeat: true, memoryPressure: false), 1)
            XCTAssertEqual(FramePipelineBudget.active(maximum: maximum, lowPowerMode: false, seriousHeat: false, memoryPressure: true), 1)
            XCTAssertEqual(FramePipelineBudget.active(maximum: maximum, lowPowerMode: true, seriousHeat: true, memoryPressure: true), 1)
        }
    }
    func testReportedM4MemoryEnablesTabletPipelineWithoutExpandingPhoneBudget() {
        let observedM4Memory: UInt64 = 7_732_772_864
        XCTAssertEqual(FramePipelineBudget.maximum(isTablet: true, reportedMemory: observedM4Memory), 3)
        XCTAssertEqual(FramePipelineBudget.maximum(isTablet: false, reportedMemory: observedM4Memory), 2)
        XCTAssertEqual(FramePipelineBudget.maximum(isTablet: true, reportedMemory: 6 * 1024 * 1024 * 1024), 2)
    }
}
