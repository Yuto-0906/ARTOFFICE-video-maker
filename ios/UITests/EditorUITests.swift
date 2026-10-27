import Foundation
import XCTest

@MainActor final class EditorUITests: XCTestCase {
    func testEditorNavigationAndSavedProjectSurviveRelaunch() throws {
        executionTimeAllowance = 600
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARTOFFICE_UI_TEST_ROOT"] = UUID().uuidString
        stage("launch"); app.launch()
        let create = app.buttons["newProject"]
        XCTAssertTrue(create.waitForExistence(timeout: 15)); screenshot(app, name: "01-library")
        stage("create project"); create.tap()
        let name = app.textFields["eventName"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        let clearName = app.buttons["clearEventName"]
        XCTAssertTrue(clearName.waitForExistence(timeout: 10))
        stage("clear event name"); clearName.tap()
        stage("cleared field value \(String(describing: name.value))")
        let empty = expectation(for: NSPredicate(format: "value == nil OR value == %@ OR value == %@", "", "イベント名"), evaluatedWith: name)
        wait(for: [empty], timeout: 15)
        stage("enter event name"); name.tap(); name.typeText("Live UI Test")
        let entered = expectation(for: NSPredicate(format: "value == %@", "Live UI Test"), evaluatedWith: name)
        wait(for: [entered], timeout: 15)
        XCTAssertEqual(name.value as? String, "Live UI Test")
        stage("finish event name"); name.typeText("\n")
        let save = app.buttons["saveProject"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        stage("save project"); save.tap()
        let saved = expectation(for: NSPredicate(format: "label == %@", "保存しました"), evaluatedWith: app.staticTexts["saveStatus"])
        wait(for: [saved], timeout: 10)
        XCTAssertTrue(app.buttons["importVideoFolder"].exists)
        XCTAssertTrue(app.buttons["importVideoFiles"].exists)
        screenshot(app, name: "02-import")
        // iPadOS can present the tabs in its top toolbar rather than a TabBar.
        selectTab("編集", app: app)
        XCTAssertTrue(app.staticTexts["動画を追加してください"].waitForExistence(timeout: 5)); screenshot(app, name: "03-trim")
        selectTab("サムネイル", app: app)
        XCTAssertTrue(app.staticTexts["集合写真を16:9に切り抜く"].waitForExistence(timeout: 5)); screenshot(app, name: "04-thumbnail")
        selectTab("書き出し", app: app)
        XCTAssertTrue(app.buttons["startExport"].waitForExistence(timeout: 5)); screenshot(app, name: "05-export")
        stage("terminate"); app.terminate()
        stage("relaunch"); app.launch()
        screenshot(app, name: "06-relaunch-library")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "project-"))
        let project = rows.firstMatch
        stage("find saved project"); let found = project.waitForExistence(timeout: 15)
        if !found {
            print(app.debugDescription.split(separator: "\n").map { "ARTOFFICE UI \($0)" }.joined(separator: "\n"))
        }
        XCTAssertTrue(found); XCTAssertEqual(rows.count, 1)
        stage("open saved project"); project.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertEqual(name.value as? String, "Live UI Test")
        stage("saved name verified")
    }
    private func selectTab(_ title: String, app: XCUIApplication) {
        stage("select tab \(title)")
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", title))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 15))
        guard let target = matches.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("No visible tab named \(title)"); return
        }
        target.tap()
    }
    private func screenshot(_ app: XCUIApplication, name: String) {
        // Full-screen snapshots are optional diagnostics on slow hosted simulators.
        // Navigation, input, save and relaunch assertions always run.
        guard ProcessInfo.processInfo.environment["ARTOFFICE_UI_SCREENSHOTS"] == "1" else { stage("checkpoint \(name)"); return }
        stage("screenshot \(name)")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func stage(_ message: String) {
        // Write immediately so the last completed operation survives a runner timeout.
        FileHandle.standardError.write(Data("ARTOFFICE UI \(message)\n".utf8))
    }
}
