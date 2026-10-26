import XCTest
@testable import ARTOFFICECore

final class ChunkIdentityTests: XCTestCase {
    private func project() -> Project {
        let source = MediaSource(fileName: "long.mov", relativePath: "Media/long.mov", byteCount: 50_000,
            duration: Clock.ticks(18_000), nominalFPS: 30, width: 3840, height: 2160, hasAudio: true, isHDR: false)
        var project = Project(); project.clips = [Clip(source: source, bandName: "最初の名前")]
        return project
    }
    private func identity(_ project: Project, index: Int = 0, audio: Int = 320_000, version: Int = 5) throws -> Data {
        let timeline = try Timeline(project), chunk = timeline.chunks(rate: project.frameRate)[index]
        return try ChunkIdentity(project: project, timeline: timeline, chunk: chunk, rendererVersion: version, audioBitRate: audio).encoded()
    }
    func testFiveHourTitleEditKeepsUnchangedLaterChunks() throws {
        let original = project()
        var edited = original; edited.clips[0].bandName = "訂正した名前"
        XCTAssertNotEqual(try identity(original), try identity(edited))
        let count = try Timeline(original).chunks(rate: original.frameRate).count
        XCTAssertEqual(count, 60)
        for index in 1..<count { XCTAssertEqual(try identity(original, index: index), try identity(edited, index: index)) }
        edited.name = "イベント名の変更"; edited.clips[0].id = UUID()
        XCTAssertEqual(try identity(original, index: 1), try identity(edited, index: 1))
    }
    func testJoinedFileInheritsTitleFromOutsideChunk() throws {
        var original = project()
        original.clips[0].end = Clock.ticks(3)
        var joined = Clip(source: original.clips[0].source, bandName: "連結ファイルの非表示名")
        joined.end = Clock.ticks(600); joined.joinPrevious = true; original.clips.append(joined)
        let chunk = ExportChunk(index: 0, start: Clock.ticks(3), end: Clock.ticks(4))
        func value(_ project: Project) throws -> Data {
            try ChunkIdentity(project: project, timeline: Timeline(project), chunk: chunk, rendererVersion: 5, audioBitRate: 320_000).encoded()
        }
        var edited = original; edited.clips[0].bandName = "先頭ファイルの訂正名"
        XCTAssertNotEqual(try value(original), try value(edited))
        edited = original; edited.clips[1].bandName = "表示に影響しない変更"
        XCTAssertEqual(try value(original), try value(edited))
    }
    func testSourceTimingFadeAndEncodingChangesInvalidate() throws {
        let original = project(), baseline = try identity(original, index: 1)
        var edited = original; edited.clips[0].source.modifiedAt = Date(timeIntervalSince1970: 123)
        XCTAssertNotEqual(baseline, try identity(edited, index: 1))
        edited = original; edited.clips[0].start = Clock.ticks(1)
        XCTAssertNotEqual(baseline, try identity(edited, index: 1))
        edited = original; edited.resolution = .quadHD
        XCTAssertNotEqual(baseline, try identity(edited, index: 1))
        edited = original; edited.frameRate = .ntsc30
        XCTAssertNotEqual(baseline, try identity(edited, index: 1))
        XCTAssertNotEqual(baseline, try identity(original, index: 1, audio: 384_000))
        XCTAssertNotEqual(baseline, try identity(original, index: 1, version: 6))
        edited = original; edited.clips[0].end = Clock.ticks(600); edited.clips.append(Clip(source: edited.clips[0].source, bandName: "次"))
        let faded = try identity(edited, index: 1)
        edited.clips[1].joinPrevious = true
        XCTAssertNotEqual(faded, try identity(edited, index: 1))
    }
}
