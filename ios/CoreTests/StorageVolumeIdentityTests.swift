import Foundation
import XCTest
@testable import ARTOFFICECore

final class StorageVolumeIdentityTests: XCTestCase {
    func testUnknownProviderVolumesKeepDestinationCapacityCheck() {
        let local = NSString(string: "internal-volume")
        XCTAssertFalse(StorageVolumeIdentity.matches(nil, nil))
        XCTAssertFalse(StorageVolumeIdentity.matches(local, nil))
        XCTAssertFalse(StorageVolumeIdentity.matches(nil, local))
        XCTAssertFalse(StorageVolumeIdentity.matches(local, NSString(string: "external-volume")))
        XCTAssertTrue(StorageVolumeIdentity.matches(local, NSString(string: "internal-volume")))
    }
}
