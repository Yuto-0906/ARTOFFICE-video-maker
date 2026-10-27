import XCTest
@testable import ARTOFFICECore

final class FramePipelineBudgetTests: XCTestCase {
    func testReportedM4MemoryEnablesTabletPipelineWithoutExpandingPhoneBudget() {
        let observedM4Memory: UInt64 = 7_732_772_864
        XCTAssertEqual(FramePipelineBudget.maximum(isTablet: true, reportedMemory: observedM4Memory), 3)
        XCTAssertEqual(FramePipelineBudget.maximum(isTablet: false, reportedMemory: observedM4Memory), 2)
        XCTAssertEqual(FramePipelineBudget.maximum(isTablet: true, reportedMemory: 6 * 1024 * 1024 * 1024), 2)
    }
}
