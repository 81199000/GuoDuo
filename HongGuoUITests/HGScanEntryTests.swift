import XCTest

/// 扫一扫入口：「我的」右上图标；长按 App 图标快捷菜单（模拟 HG_SHORTCUT）；扫到遥控地址进「连接遥控器」
final class HGScanEntryTests: XCTestCase {
    private func shot(_ n: String) { let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a) }

    func testMineScanIcon() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "mine"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let scan = app.buttons["hg.mine.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 20), "我的右上没有扫一扫")
        sleep(2); shot("mine")
        scan.tap()
        XCTAssertTrue(app.buttons["hg.scan.close"].waitForExistence(timeout: 5), "没弹出扫码")
        sleep(1); shot("scanner")
        app.buttons["hg.scan.close"].tap()
    }

    func testShortcutRemote() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_SHORTCUT"] = "me.rrmm.hongguo.remote"
        app.launch()
        XCTAssertTrue(app.navigationBars["连接遥控器"].waitForExistence(timeout: 10), "快捷菜单没打开连接遥控器")
        sleep(2); shot("shortcut-remote")
    }

    func testFakeScanAddress() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_FAKE_SCAN"] = "http://192.168.1.100:8765/#search"
        app.launch()
        // 电视在线会直接连上进遥控器；不在线停在「连接遥控器」页
        let pad = app.buttons["hg.tvr.key.ok"], page = app.navigationBars["连接遥控器"]
        XCTAssertTrue(pad.waitForExistence(timeout: 15) || page.exists, "扫到遥控地址没进连接遥控器")
        sleep(2); shot("fake-scan")
    }
}
