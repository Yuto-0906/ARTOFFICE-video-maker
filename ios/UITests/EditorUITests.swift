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
        XCTAssertEqual(name.value as? String, "Live UI Test")
        let save = app.buttons["saveProject"]
        XCTAssertTrue(save.waitForExistence(timeout: 10)); save.tap()
        let saved = expectation(for: NSPredicate(format: "label CONTAINS %@", "保存済み"), evaluatedWith: save)
        wait(for: [saved], timeout: 10)
        screenshot(app, name: "02-import")
        // iPadOS can present the tabs in its top toolbar rather than a TabBar.
        selectTab("編集", app: app)
        XCTAssertTrue(app.staticTexts["動画を追加してください"].waitForExistence(timeout: 5)); screenshot(app, name: "03-trim")
        selectTab("サムネイル", app: app)
        XCTAssertTrue(app.staticTexts["集合写真を16:9に切り抜く"].waitForExistence(timeout: 5)); screenshot(app, name: "04-thumbnail")
        selectTab("書き出し", app: app)
        XCTAssertTrue(app.buttons["startExport"].waitForExistence(timeout: 5)); screenshot(app, name: "05-export")
        app.terminate(); app.launch()
        screenshot(app, name: "06-relaunch-library")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "project-"))
        let project = rows.firstMatch
        let found = project.waitForExistence(timeout: 15)
        if !found {
            print(app.debugDescription.split(separator: "\n").map { "ARTOFFICE UI \($0)" }.joined(separator: "\n"))
        }
        XCTAssertTrue(found); XCTAssertEqual(rows.count, 1); project.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertEqual(name.value as? String, "Live UI Test")
    }
    private func selectTab(_ title: String, app: XCUIApplication) {
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", title))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 15))
        guard let target = matches.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("No visible tab named \(title)"); return
        }
        target.tap()
    }
    private func screenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
