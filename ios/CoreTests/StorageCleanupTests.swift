import XCTest
@testable import ARTOFFICECore

final class StorageCleanupTests: XCTestCase {
    func testUnusedMediaRemovalKeepsCurrentFilesAndRecoverableCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(root: root)
        var project = Project()
        let directory = root.appendingPathComponent(project.id.uuidString), media = directory.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        for name in ["kept.mp4", "removed.mp4", "photo.jpg", "unused.jpg"] { try Data([1, 2, 3]).write(to: media.appendingPathComponent(name)) }
        func clip(_ name: String) -> Clip { Clip(source: MediaSource(fileName: name, relativePath: "Media/" + name, byteCount: 3,
            duration: Clock.ticks(10), nominalFPS: 30, width: 1920, height: 1080, hasAudio: true, isHDR: false), bandName: name) }
        project.clips = [clip("kept.mp4"), clip("removed.mp4")]; project.thumbnail = PhotoCrop(relativePath: "Media/photo.jpg")
        try await repository.save(project)
        let shared = root.appendingPathComponent("other-project-copy.mp4")
        try FileManager.default.linkItem(at: media.appendingPathComponent("removed.mp4"), to: shared)
        project.removeClip(project.clips[1].id); try await repository.save(project)
        let removed = try await repository.removeUnusedMedia(project.id, onlyPaths: ["Media/removed.mp4"])
        XCTAssertEqual(removed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.appendingPathComponent("kept.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.appendingPathComponent("photo.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.appendingPathComponent("unused.jpg").path))
        XCTAssertEqual(try Data(contentsOf: shared), Data([1, 2, 3]))
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent("project.json"))
        let restored = try await repository.load(project.id)
        XCTAssertTrue(restored.recovered); XCTAssertEqual(restored.project.clips.count, 1)
    }
    func testCacheRetentionRemovesOldChunksAndPartialsButKeepsFinishedMovies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent(UUID().uuidString)
        let names = [String(repeating: "a", count: 64), String(repeating: "b", count: 64), String(repeating: "c", count: 64)]
        for (index, name) in names.enumerated() {
            let job = project.appendingPathComponent(name), completed = job.appendingPathComponent("Completed")
            try FileManager.default.createDirectory(at: completed, withIntermediateDirectories: true)
            for file in ["chunk-0.mp4", "chunk-0.partial.mp4", "journal.json", "performance.json"] { try Data([1]).write(to: job.appendingPathComponent(file)) }
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index + 1))], ofItemAtPath: job.appendingPathComponent("performance.json").path)
            try Data([2]).write(to: completed.appendingPathComponent("finished.mp4"))
            try Data([3]).write(to: completed.appendingPathComponent(".interrupted.partial.mp4"))
        }
        try ExportCacheStorage.retainRecent(projectDirectory: project, currentJob: names[2])
        for (index, name) in names.enumerated() {
            let job = project.appendingPathComponent(name)
            XCTAssertEqual(FileManager.default.fileExists(atPath: job.appendingPathComponent("chunk-0.mp4").path), index > 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: job.appendingPathComponent("chunk-0.partial.mp4").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: job.appendingPathComponent("Completed/.interrupted.partial.mp4").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: job.appendingPathComponent("Completed/finished.mp4").path))
        }
    }
    func testRedirectedCacheCannotDeleteOutsideFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent(UUID().uuidString), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let file = outside.appendingPathComponent("chunk-0.mp4"); try Data([1]).write(to: file)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent(String(repeating: "a", count: 64)), withDestinationURL: outside)
        XCTAssertThrowsError(try ExportCacheStorage.remove(projectDirectory: project))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
