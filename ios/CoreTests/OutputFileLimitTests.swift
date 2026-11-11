import XCTest
@testable import ARTOFFICECore

final class OutputFileLimitTests: XCTestCase {
    func testFiveHourExportRejectsFATFileLimitDespiteFreeSpace() throws {
        let limit = OutputFileLimit.maximum(signedBits: -1, fileSystem: "msdos")
        XCTAssertEqual(limit, 4_294_967_295)
        for resolution in Resolution.allCases {
            let estimate = CapacityEstimate(duration: Clock.ticks(18_000), resolution: resolution, separateDestination: true)
            XCTAssertThrowsError(try OutputFileLimit.require(estimate.output, maximum: limit))
        }
        XCTAssertNoThrow(try OutputFileLimit.require(4_294_967_295, maximum: limit))
        XCTAssertThrowsError(try OutputFileLimit.require(4_294_967_296, maximum: limit))
    }
    func testSignedBitsAndUnknownLimitsAreDistinct() {
        XCTAssertEqual(OutputFileLimit.maximum(signedBits: 33, fileSystem: "other"), 4_294_967_295)
        XCTAssertEqual(OutputFileLimit.maximum(signedBits: 64, fileSystem: "apfs"), Int64.max)
        XCTAssertEqual(OutputFileLimit.maximum(signedBits: 128, fileSystem: "other"), Int64.max)
        XCTAssertNil(OutputFileLimit.maximum(signedBits: -1, fileSystem: "unknown"))
        XCTAssertNil(OutputFileLimit.maximum(signedBits: 0, fileSystem: "unknown"))
    }
}
