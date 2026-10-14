import XCTest
import CryptoKit

final class HistoryActionsTests: XCTestCase {
    private let shortText = "UI fixture: Keep going."
    private let longText = "UI fixture: " + String(repeating: "Learning English becomes easier when we listen carefully and practise every day. ", count: 8)

    private func id(_ text: String) -> String {
        SHA256.hash(data: Data("sonic-3.6\u{0}47c38ca4-5f35-497b-b1a3-415245fb35e1\u{0}\(text)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func reveal(_ row: XCUIElement, right: Bool) {
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.25 : 0.75, dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.55 : 0.45, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    func testVerticalScrollingAndTappingHistoryStillOpensCachedPlayer() throws {
        let app = XCUIApplication()
        app.launch()
        let row = app.buttons["history-\(id(longText))"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let initialY = row.frame.minY
        app.swipeUp()
        XCTAssertLessThan(row.frame.minY, initialY, "Horizontal recognizer must leave vertical List scrolling available")
        row.tap()
        XCTAssertTrue(app.staticTexts["selectedText"].waitForExistence(timeout: 5), "An ordinary tap must still open the player")
        XCTAssertEqual(app.staticTexts["selectedText"].label, longText.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(app.buttons["rate-0.8"].exists)
        XCTAssertTrue(app.buttons["rate-1.2"].exists)
        XCTAssertTrue(app.buttons["closePlayer"].exists)
        app.buttons["closePlayer"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertTrue(app.alerts.allElementsBoundByIndex.isEmpty)
    }

    func testEqualRowAndSwipeHeightsFavoritePinAndImmediateDeletion() throws {
        let app = XCUIApplication()
        app.launch()
        let short = app.buttons["history-\(id(shortText))"]
        let long = app.buttons["history-\(id(longText))"]
        XCTAssertTrue(short.waitForExistence(timeout: 5), "Seeded history must load from the real shared store")
        app.swipeUp()
        XCTAssertTrue(long.waitForExistence(timeout: 3))
        XCTAssertEqual(short.frame.height, long.frame.height, accuracy: 1, "Long and short sentences must share one row height")
        let regular = XCTAttachment(screenshot: app.screenshot()); regular.name = "Uniform history rows"; regular.lifetime = .keepAlways; add(regular)

        reveal(long, right: true)
        let favorite = app.buttons["favorite-\(id(longText))"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 3))
        XCTAssertEqual(favorite.frame.height, long.frame.height, accuracy: 1, "Favorite control must fill the same row height")
        let leading = XCTAttachment(screenshot: app.screenshot()); leading.name = "Right swipe favorite alignment"; leading.lifetime = .keepAlways; add(leading)
        favorite.tap()
        XCTAssertTrue(app.alerts.allElementsBoundByIndex.isEmpty, "Favorite must not require a second confirmation")
        XCTAssertEqual(long.value as? String, "已收藏")
        XCTAssertLessThan(long.frame.minY, short.frame.minY, "Favorite must move above ordinary rows")
        app.terminate(); app.launch(); app.swipeUp()
        XCTAssertEqual(long.value as? String, "已收藏", "Favorite must survive relaunch")
        reveal(long, right: true)
        XCTAssertTrue(favorite.waitForExistence(timeout: 3))
        favorite.tap()
        XCTAssertEqual(long.value as? String, "未收藏")
        XCTAssertTrue(app.alerts.allElementsBoundByIndex.isEmpty)

        reveal(short, right: false)
        let delete = app.buttons["delete-\(id(shortText))"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        XCTAssertEqual(delete.frame.height, short.frame.height, accuracy: 1, "Delete control must fill the same row height")
        let trailing = XCTAttachment(screenshot: app.screenshot()); trailing.name = "Left swipe delete alignment"; trailing.lifetime = .keepAlways; add(trailing)
        delete.tap()
        XCTAssertTrue(app.alerts.allElementsBoundByIndex.isEmpty, "Delete must not require a second confirmation")
        XCTAssertFalse(short.waitForExistence(timeout: 1), "One tap must remove the recording")
        app.terminate(); app.launch()
        XCTAssertFalse(short.exists, "Deleted recording must remain absent after relaunch")
    }
}
