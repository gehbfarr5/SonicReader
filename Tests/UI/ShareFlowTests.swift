import XCTest

final class ShareFlowTests: XCTestCase {
    func testSystemShareOpensExtensionWithSelectedText() throws {
        let app = XCUIApplication()
        app.launch()
        if app.alerts.firstMatch.exists { app.alerts.buttons["好"].tap() }
        let homeScreenshot = XCTAttachment(screenshot: app.screenshot())
        homeScreenshot.name = "Home trial buttons"
        homeScreenshot.lifetime = .keepAlways
        add(homeScreenshot)
        app.buttons["shareExampleButton"].tap()
        let extensionCell = app.cells.matching(NSPredicate(format: "label == '英文随听'")).firstMatch
        XCTAssertTrue(extensionCell.waitForExistence(timeout: 5), "Share extension must be in the activity list")
        extensionCell.tap()
        let selected = app.staticTexts["selectedText"]
        XCTAssertTrue(selected.waitForExistence(timeout: 10))
        XCTAssertEqual(selected.label, "Small steps every day lead to meaningful progress.")
        XCTAssertTrue(app.buttons["rate-0.8"].exists)
        XCTAssertTrue(app.buttons["rate-1.2"].exists)
        let ready = app.buttons["playPauseButton"]
        let enabled = NSPredicate(format: "enabled == true")
        let playable = XCTNSPredicateExpectation(predicate: enabled, object: ready)
        XCTAssertEqual(XCTWaiter.wait(for: [playable], timeout: 45), .completed, "Extension must generate/cache and prepare actual audio")
        app.buttons["rate-0.8"].tap()
        XCTAssertEqual(app.buttons["rate-0.8"].value as? String, "已选择")
        app.buttons["loopButton"].tap()
        XCTAssertEqual(app.buttons["loopButton"].value as? String, "已开启")
        app.buttons["replayButton"].tap()
        app.buttons["playerSettings"].tap()
        XCTAssertTrue(app.staticTexts["共享存储可用"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["密钥已保存"].exists, "Extension must read the Keychain item stored by the main App")
        app.buttons["完成"].tap()
        app.buttons["replayButton"].tap()
        XCTAssertFalse(app.staticTexts["playerError"].exists, "Returning from settings must keep playback functional")
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Share extension player"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["closePlayer"].tap()
        // Closing the extension returns to the host; dismiss any remaining system share sheet.
        let shareClose = app.buttons["header.closeButton"]
        if shareClose.waitForExistence(timeout: 2) { shareClose.tap() }
        XCTAssertTrue(app.buttons["shareExampleButton"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        let history = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history-'")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5), "Extension history must be visible after app relaunch")
        history.tap()
        XCTAssertTrue(app.staticTexts["selectedText"].waitForExistence(timeout: 5))
        app.buttons["closePlayer"].tap()
    }
}
