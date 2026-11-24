import XCTest

/// 「我的」：收藏 / 继续观看只露一排，点「全部」进完整网格；最底下 logo + 名字 + 仓库链接
final class HGMineShelfTests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ n: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a)
    }
    func testShelvesAndFooter() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "mine"
        app.launchEnvironment["HG_DEMO_LIBRARY"] = "12"
        app.launchEnvironment["HG_DEMO_CLOUD"] = "15"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        // 登录后：本机 + 云端观看记录合成一排「继续观看」，不再单独一排「红果 App 观看记录」
        let shelf = app.descendants(matching: .any)["hg.shelf.history"].firstMatch
        XCTAssertTrue(shelf.waitForExistence(timeout: 15), "继续观看没有变成横排")
        XCTAssertFalse(app.descendants(matching: .any)["hg.shelf.cloud"].exists, "云端记录应合进继续观看")
        XCTAssertTrue(app.descendants(matching: .any)["hg.shelf.favorites"].firstMatch.exists, "收藏没有变成横排")
        XCTAssertFalse(app.buttons["hg.mine.downloads"].exists, "「我的」里不应再有离线下载")
        XCTAssertFalse(app.staticTexts["离线下载"].exists, "「我的」里不应再有离线下载")
        shot(app, "mine-top")
        // 底部
        for _ in 0..<6 { app.swipeUp() }
        sleep(1)
        XCTAssertTrue(app.buttons["hg.footer.repo"].exists, "底部没有仓库链接")
        XCTAssertTrue(app.staticTexts["GuoDuo"].exists)
        shot(app, "mine-footer")
        // 继续观看「全部」
        for _ in 0..<8 { app.swipeDown() }
        app.buttons["hg.shelf.history.all"].tap()
        XCTAssertTrue(app.navigationBars["继续观看"].waitForExistence(timeout: 5))
        shot(app, "mine-all")
    }
}
