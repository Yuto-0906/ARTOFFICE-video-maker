import XCTest
@testable import ARTOFFICECore

final class ClipArrangementTests: XCTestCase {
    func clip(_ name: String) -> Clip {
        Clip(source: MediaSource(fileName: name + ".mp4", relativePath: "Media/" + UUID().uuidString + ".mp4", byteCount: 10,
            duration: Clock.ticks(20), nominalFPS: 30, width: 1920, height: 1080, hasAudio: true, isHDR: false), bandName: name)
    }
    func testBandReorderingKeepsJoinedPartsAndSourceLocations() throws {
        var project = Project(); project.clips = [clip("A"), clip("A続き"), clip("B"), clip("C")]
        project.clips[1].joinPrevious = true
        let original = project.clips
        project.moveGroups(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(project.clips.map(\.id), [original[2].id, original[3].id, original[0].id, original[1].id])
        XCTAssertTrue(project.clips[3].joinPrevious)
        project.movePart(original[1].id, by: -1)
        XCTAssertEqual(project.clips[2].bandName, "A")
        XCTAssertFalse(project.clips[2].joinPrevious); XCTAssertTrue(project.clips[3].joinPrevious)
        for value in project.clips { XCTAssertEqual(value.source, original.first(where: { $0.id == value.id })?.source) }
        XCTAssertNoThrow(try Timeline(project))
    }
    func testDisplayNameSortDoesNotRenameOriginalOrOverwriteBandTitle() throws {
        var project = Project(); project.clips = [clip("cameraA"), clip("cameraB")]
        project.clips[0].displayName = "02_後半"; project.clips[1].displayName = "01_前半"
        let original = project.clips
        project.sortGroupsByDisplayName()
        XCTAssertEqual(project.clips.map(\.id), [original[1].id, original[0].id])
        XCTAssertEqual(project.clips[0].source.fileName, "cameraB.mp4")
        XCTAssertEqual(project.clips[0].bandName, "cameraB")
        let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(restored.clips[0].displayTitle, "01_前半")
    }
    func testExistingProjectWithoutNewOptionalFieldsStillOpens() throws {
        var project = Project(); project.clips = [clip("既存素材")]
        let data = try JSONEncoder().encode(project)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var clips = try XCTUnwrap(json["clips"] as? [[String: Any]])
        clips[0].removeValue(forKey: "displayName")
        var source = try XCTUnwrap(clips[0]["source"] as? [String: Any]); source.removeValue(forKey: "folderBookmark")
        clips[0]["source"] = source; json["clips"] = clips
        let restored = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json))
        try restored.validate()
        XCTAssertEqual(restored, project)
        XCTAssertEqual(restored.clips[0].displayTitle, "既存素材")
    }
}
