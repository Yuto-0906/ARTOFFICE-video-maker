import XCTest
@testable import ARTOFFICE

final class FolderVideoImportTests: XCTestCase {
    func testFolderScansNestedMoviesWithoutFollowingLinksOrImportingPhotos() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("input"), nested = folder.appendingPathComponent("parts"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data([0]).write(to: folder.appendingPathComponent("01_first.mp4"))
        try Data([0]).write(to: nested.appendingPathComponent("02_second.MOV"))
        try Data([0]).write(to: folder.appendingPathComponent("photo.jpg"))
        try Data([0]).write(to: outside.appendingPathComponent("not-selected.mp4"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked"), withDestinationURL: outside)
        let files = try FolderVideoImport.scan(folder)
        XCTAssertEqual(files.map(\.lastPathComponent), ["01_first.mp4", "02_second.MOV"])
    }
}
