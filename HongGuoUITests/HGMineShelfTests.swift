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
        // 官方排版：历史 / 收藏 / 点赞 / 预约 标签 + 封面网格（本机 + 云端合并）
        let shelf = app.descendants(matching: .any)["hg.shelf.history"].firstMatch
        XCTAssertTrue(shelf.waitForExistence(timeout: 15), "历史网格没出来")
        app.buttons["hg.mine.tab.收藏"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["hg.shelf.favorites"].firstMatch.waitForExistence(timeout: 5), "收藏网格没出来")
        app.buttons["hg.mine.tab.历史"].tap()
        XCTAssertFalse(app.buttons["hg.mine.downloads"].exists, "「我的」里不应再有离线下载")
        shot(app, "mine-top")
        // 底部
        for _ in 0..<6 { app.swipeUp() }
        sleep(1)
        XCTAssertTrue(app.buttons["hg.footer.repo"].exists, "底部没有仓库链接")
        XCTAssertTrue(app.staticTexts["GuoDuo"].exists)
        shot(app, "mine-footer")
    }
}
