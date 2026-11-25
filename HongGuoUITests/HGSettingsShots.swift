import XCTest

/// 设置页 / 缓存管理截图；封面二次打开秒出（磁盘缓存）
final class HGSettingsShots: XCTestCase {
    private func shot(_ n: String) { let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a) }

    func testSettings() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "mine"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "设置")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 20)); entry.tap()
        XCTAssertTrue(app.segmentedControls["hg.home.style"].waitForExistence(timeout: 5) || app.otherElements["hg.home.style"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["奈飞"].exists && app.buttons["红果"].exists, "首页主题没有奈飞/红果")
        sleep(3); shot("settings")
        let cache = app.buttons["hg.settings.cache"]
        XCTAssertTrue(cache.waitForExistence(timeout: 5)); cache.tap()
        XCTAssertTrue(app.navigationBars["缓存管理"].waitForExistence(timeout: 10), "缓存管理标题不对")
        sleep(4); shot("cache")
    }

    /// 首页两次冷启动：第二次封面直接从磁盘出（记录首屏多少张封面已出图）
    func testCoverCache() throws {
        for round in 1...2 {
            let app = XCUIApplication()
            app.launchEnvironment["HG_START_TAB"] = "discover"
            app.launch()
            XCTAssertTrue(app.buttons["hg.home.chip.真人剧"].waitForExistence(timeout: 30))
            let t0 = Date()
            sleep(1)
            shot("home-\(round)")
            print("COVER round=\(round) shotAfter=\(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
            app.terminate()
        }
    }
}
