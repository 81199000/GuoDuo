import XCTest

/// 推荐「更多」面板：液态玻璃
final class HGMoreGlassTests: XCTestCase {
    func testMoreGlass() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "feed"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let more = app.buttons["hg.rail.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 40))
        sleep(4)
        more.tap()
        XCTAssertTrue(app.buttons["hg.more.fill"].waitForExistence(timeout: 5))
        sleep(2)
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = "more-glass"; a.lifetime = .keepAlways; add(a)
    }
}
