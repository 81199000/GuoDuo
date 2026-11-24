import XCTest

/// 发现瀑布流列数自适应：卡宽跟外屏两列一样（约 170pt），展开 / 横屏按宽度多放几列；频道条放得下就平铺
final class HGDiscoverColumnsTests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ n: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a)
        let t = XCTAttachment(string: app.debugDescription); t.name = "tree-" + n; t.lifetime = .keepAlways; add(t)
    }
    func testColumns() throws {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let ch = app.buttons["hg.channel.找剧"]
        XCTAssertTrue(ch.waitForExistence(timeout: 15))
        ch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["hg.card"].firstMatch.waitForExistence(timeout: 30))
        sleep(4); shot(app, "portrait")
        // 外屏：2 列、卡宽 170；频道条放不下 → 可左右滑（最后一个频道在屏外）
        XCTAssertTrue(app.descendants(matching: .any)["hg.waterfall.2"].exists, "外屏应是 2 列")
        XCTAssertGreaterThan(app.buttons["hg.channel.河马"].frame.minX, app.windows.firstMatch.frame.width, "外屏频道条应该左右滑")
        app.buttons["hg.channel.漫剧"].swipeLeft()
        sleep(1)
        let hema = app.buttons["hg.channel.河马"]
        XCTAssertLessThan(hema.frame.maxX, app.windows.firstMatch.frame.width + 1, "左滑后应能看到最后的频道")
        hema.tap(); sleep(5); shot(app, "hema")
    }
}
