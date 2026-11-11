import XCTest
@testable import ARTOFFICECore

final class MediaFormatsTests: XCTestCase {
    func testVideoExtensionsAreCaseInsensitiveAndExcludeImages() {
        for extensionName in ["mp4", "MKV", "MOV", "webm", "MTS", "m2ts", "AVI", "wmv"] {
            XCTAssertTrue(MediaFormats.isVideo(URL(fileURLWithPath: "/動画/1_バンド.\(extensionName)")))
        }
        XCTAssertFalse(MediaFormats.isVideo(URL(fileURLWithPath: "/写真/group.png")))
        XCTAssertFalse(MediaFormats.isVideo(URL(fileURLWithPath: "/動画/fake.mp4.exe")))
    }
    func testOldPhotoCropDefaultsToJPEGAndPNGRoundTrips() throws {
        let old = Data(#"{"relativePath":"Media/photo.jpg","centerX":0.5,"centerY":0.5,"zoom":1}"#.utf8)
        var crop = try JSONDecoder().decode(PhotoCrop.self, from: old)
        XCTAssertEqual(crop.resolvedOutputFormat, .jpeg)
        crop.outputFormat = .png
        let restored = try JSONDecoder().decode(PhotoCrop.self, from: JSONEncoder().encode(crop))
        XCTAssertEqual(restored.resolvedOutputFormat, .png)
        XCTAssertEqual(restored.relativePath, crop.relativePath)
    }
}
