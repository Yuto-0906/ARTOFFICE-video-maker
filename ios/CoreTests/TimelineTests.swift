import XCTest
@testable import ARTOFFICECore

final class TimelineTests: XCTestCase {
    func clip(_ name: String, seconds: Double) -> Clip {
        Clip(source: MediaSource(fileName: name + ".mp4", relativePath: "Media/" + UUID().uuidString + ".mp4",
                                 byteCount: 100, duration: Clock.ticks(seconds), nominalFPS: 59.94,
                                 width: 1920, height: 1080, hasAudio: true, isHDR: false), bandName: name)
    }
    func testJoinedPartsAndChaptersUseOneClock() throws {
        var p = Project(); p.clips = [clip("日本語", seconds: 20), clip("続き", seconds: 10), clip("次のバンド", seconds: 20)]
        p.clips[1].joinPrevious = true
        let timeline = try Timeline(p)
        XCTAssertEqual(timeline.duration, Clock.ticks(49.5))
        XCTAssertEqual(timeline.chapters, "0:00:00 日本語\n0:00:29 次のバンド\n")
        XCTAssertEqual(timeline.segments[1].incoming, 0)
    }
    func testFiveHoursHasContiguousFrameAlignedChunks() throws {
        var p = Project(); p.clips = [clip("5時間", seconds: 18_000)]
        let timeline = try Timeline(p)
        for rate in FrameRate.allCases {
            let chunks = timeline.chunks(rate: rate)
            XCTAssertGreaterThanOrEqual(chunks.count, 60)
            XCTAssertEqual(chunks.first?.start, 0)
            for (a, b) in zip(chunks, chunks.dropFirst()) { XCTAssertEqual(a.end, b.start) }
            XCTAssertLessThan(timeline.duration - chunks.last!.end, rate.frameTicks)
            XCTAssertTrue(chunks.allSatisfy { $0.start % rate.frameTicks == 0 && $0.end % rate.frameTicks == 0 })
        }
    }
    func testRejectsTripleOverlapAndTraversal() throws {
        var p = Project(); p.clips = [clip("a", seconds: 10), clip("b", seconds: 0.9), clip("c", seconds: 10)]
        XCTAssertThrowsError(try Timeline(p))
        for bad in ["../secret", "Media/../secret", "/Media/x", "Media/..", "Media/a\\b"] { XCTAssertFalse(Project.safeMediaPath(bad)) }
        XCTAssertTrue(Project.safeMediaPath("Media/日本語.mp4"))
    }
    func testGroupMoveAndHeadRemoval() {
        var p = Project(); p.clips = [clip("a", seconds: 20), clip("a2", seconds: 20), clip("b", seconds: 20)]
        p.clips[1].joinPrevious = true; p.moveGroup(0, by: 1)
        XCTAssertEqual(p.clips.map(\.bandName), ["b", "a", "a2"])
        p.removeClip(p.clips[1].id)
        XCTAssertFalse(p.clips[1].joinPrevious); XCTAssertEqual(p.clips[1].bandName, "a")
    }
    func testCapacityIncludesFinalizationPeak() {
        let value = CapacityEstimate(duration: Clock.ticks(18_000), resolution: .fullHD, separateDestination: false)
        XCTAssertEqual(value.output, 34_614_000_000)
        XCTAssertGreaterThan(value.localWorking, value.output * 2)
    }
    func testRepositoryRecoveryAndFutureSchema() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(root: root)
        var p = Project(); try await repository.save(p)
        p.name = "変更後"; try await repository.save(p)
        let directory = await repository.directory(p.id)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("project.json"))
        let recovered = try await repository.load(p.id)
        XCTAssertTrue(recovered.recovered); XCTAssertEqual(recovered.project.name, "新しいライブ")
        p.schemaVersion = 999; XCTAssertThrowsError(try p.validate())
    }
}
