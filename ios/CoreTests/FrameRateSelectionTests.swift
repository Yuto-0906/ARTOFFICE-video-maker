import XCTest
@testable import ARTOFFICECore

final class FrameRateSelectionTests: XCTestCase {
    private func clip(_ fps: Double) -> Clip {
        Clip(source: MediaSource(fileName: "input.mov", relativePath: "Media/input.mov", byteCount: 100,
            duration: Clock.ticks(600), nominalFPS: fps, width: 1920, height: 1080, hasAudio: true, isHDR: false), bandName: "Band")
    }
    func testAutomaticRateFollowsFirstSourceAfterReorderAndRemoval() throws {
        var project = Project()
        XCTAssertEqual(project.matchesSourceFrameRate, true)
        project.clips = [clip(60_000.0 / 1001), clip(25)]
        XCTAssertEqual(project.outputFrameRate, .ntsc60)
        project.moveGroup(1, by: -1)
        XCTAssertEqual(project.outputFrameRate, .fps25)
        project.removeClip(project.clips[0].id)
        XCTAssertEqual(project.outputFrameRate, .ntsc60)
        let reopened = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(reopened.matchesSourceFrameRate, true)
        XCTAssertEqual(reopened.outputFrameRate, .ntsc60)
    }
    func testManualChoiceSurvivesSourceChangesAndLegacyDecode() throws {
        var project = Project()
        project.matchesSourceFrameRate = false; project.frameRate = .fps50
        project.clips = [clip(24), clip(60)]
        project.moveGroup(1, by: -1)
        var reopened = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(reopened.outputFrameRate, .fps50)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        legacy.removeValue(forKey: "matchesSourceFrameRate")
        reopened = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(reopened.matchesSourceFrameRate)
        XCTAssertEqual(reopened.outputFrameRate, .fps50)
        reopened.matchesSourceFrameRate = true
        XCTAssertEqual(reopened.outputFrameRate, .fps60)
    }
    func testStandardRatesUseExactClockAndSourceLabelKeepsFraction() {
        for rate in FrameRate.allCases { XCTAssertEqual(FrameRate.suggested(rate.value), rate) }
        XCTAssertEqual(FrameRate.ntsc24.frameTicks, 25_025)
        XCTAssertEqual(FrameRate.fps25.frameTicks, 24_000)
        XCTAssertEqual(FrameRate.fps50.frameTicks, 12_000)
        XCTAssertEqual(FrameRate.suggested(56.73), .ntsc60)
        XCTAssertEqual(clip(59.94).source.frameRateLabel, "59.94 fps")
        XCTAssertEqual(clip(60).source.frameRateLabel, "60 fps")
        XCTAssertEqual(clip(23.976).source.frameRateLabel, "23.976 fps")
    }
    func testResolvedRateChangesInvalidateCachedChunks() throws {
        var project = Project(); project.clips = [clip(60), clip(25)]
        func identity(_ value: Project) throws -> Data {
            let timeline = try Timeline(value)
            let chunk = try XCTUnwrap(timeline.chunks(rate: value.outputFrameRate).first)
            return try ChunkIdentity(project: value, timeline: timeline, chunk: chunk, rendererVersion: 5, audioBitRate: 320_000).encoded()
        }
        let automatic = try identity(project)
        project.matchesSourceFrameRate = false; project.frameRate = .fps30
        XCTAssertNotEqual(automatic, try identity(project))
        project.frameRate = .fps60
        XCTAssertEqual(automatic, try identity(project))
    }
}
