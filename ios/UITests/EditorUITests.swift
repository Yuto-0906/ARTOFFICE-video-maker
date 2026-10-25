import XCTest

@MainActor final class EditorUITests: XCTestCase {
    func testEditorNavigationAndSavedProjectSurviveRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARTOFFICE_UI_TEST_ROOT"] = UUID().uuidString
        app.launch()
        let create = app.buttons["newProject"]
        XCTAssertTrue(create.waitForExistence(timeout: 15)); screenshot(app, name: "01-library")
        create.tap()
        let name = app.textFields["eventName"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.tap()
        let old = name.value as? String ?? ""
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + "Live UI Test\n")
        let save = app.buttons["saveProject"]
        XCTAssertTrue(save.waitForExistence(timeout: 10)); save.tap()
        let saved = expectation(for: NSPredicate(format: "label CONTAINS %@", "保存済み"), evaluatedWith: save)
        wait(for: [saved], timeout: 10)
        screenshot(app, name: "02-import")
        app.tabBars.buttons["編集"].tap()
        XCTAssertTrue(app.staticTexts["動画を追加してください"].waitForExistence(timeout: 5)); screenshot(app, name: "03-trim")
        app.tabBars.buttons["サムネイル"].tap()
        XCTAssertTrue(app.staticTexts["集合写真を16:9に切り抜く"].waitForExistence(timeout: 5)); screenshot(app, name: "04-thumbnail")
        app.tabBars.buttons["書き出し"].tap()
        XCTAssertTrue(app.buttons["書き出しを開始"].waitForExistence(timeout: 5)); screenshot(app, name: "05-export")
        app.terminate(); app.launch()
        let project = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Live UI Test")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertEqual(name.value as? String, "Live UI Test")
    }
    private func screenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
