import XCTest
@testable import ARTOFFICECore

final class CropInteractionTests: XCTestCase {
    func testFullSizeLandscapeHasNoInvisiblePanPosition() {
        var crop = PhotoCrop(relativePath: "Media/photo.jpg"); crop.centerX = 0
        crop = crop.dragged(x: 1000, y: -500, viewportWidth: 400, width: 1600, height: 900)
        XCTAssertEqual(crop.centerX, 0.5, accuracy: 0.000001)
        XCTAssertEqual(crop.centerY, 0.5, accuracy: 0.000001)
        let zoomed = crop.zoomed(to: 2, width: 1600, height: 900)
        XCTAssertEqual(zoomed.rect(width: 1600, height: 900).x, 400, accuracy: 0.000001)
    }
    func testPortraitPhotoOnlyMovesWhereThereIsCroppableArea() {
        let crop = PhotoCrop(relativePath: "Media/photo.jpg")
        let moved = crop.dragged(x: 100, y: 100, viewportWidth: 500, width: 1000, height: 1500)
        let before = crop.rect(width: 1000, height: 1500), after = moved.rect(width: 1000, height: 1500)
        XCTAssertEqual(after.x, 0, accuracy: 0.000001)
        XCTAssertEqual(before.y - after.y, 200, accuracy: 0.000001)
        XCTAssertEqual(after.width / after.height, 16.0 / 9, accuracy: 0.000001)
    }
    func testPinchPreservesImagePointUnderAnchor() {
        var crop = PhotoCrop(relativePath: "Media/photo.jpg"); crop.zoom = 2
        let before = crop.rect(width: 1600, height: 900)
        let after = crop.zoomed(to: 3, width: 1600, height: 900, anchorX: 0.25, anchorY: 0.75).rect(width: 1600, height: 900)
        XCTAssertEqual(before.x + before.width * 0.25, after.x + after.width * 0.25, accuracy: 0.000001)
        XCTAssertEqual(before.y + before.height * 0.75, after.y + after.height * 0.75, accuracy: 0.000001)
    }
}
