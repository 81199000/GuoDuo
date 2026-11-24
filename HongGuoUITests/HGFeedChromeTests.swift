import XCTest

/// 推荐页上下滑：菜单栏（右侧按钮栏）在拖动过程中也不能跟着视频动
final class HGFeedChromeTests: XCTestCase {
    func testChromeStable() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "feed"
        app.launchEnvironment["HG_DEMO_CHROMELOG"] = "1"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["hg.rail.likes"].waitForExistence(timeout: 30))
        sleep(3)
        let y0 = app.buttons["hg.rail.likes"].frame.minY
        // 慢拖一半再松手（会弹回）、再慢拖到底（翻页）、再快速连滑两下
        let w = app.windows.firstMatch
        let a = w.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.75))
        a.press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)), withVelocity: 150, thenHoldForDuration: 1)
        sleep(2)
        a.press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.1)), withVelocity: 250, thenHoldForDuration: 0.3)
        sleep(3)
        app.swipeUp(velocity: .fast); sleep(1); app.swipeUp(velocity: .fast); sleep(3)
        XCTAssertTrue(app.buttons["hg.rail.likes"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["hg.rail.likes"].frame.minY, y0, accuracy: 1, "停稳后菜单栏位置变了")
    }
}
