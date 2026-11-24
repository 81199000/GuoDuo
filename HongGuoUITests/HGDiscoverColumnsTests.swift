import XCTest

/// 外屏不溢出 + 列数自适应 + 搜索（联想 / 瀑布流结果）+ 详情（补充信息 / 选季 / 剧评）+ 推荐频道
final class HGDiscoverColumnsTests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ n: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a)
        let t = XCTAttachment(string: app.debugDescription); t.name = "tree-" + n; t.lifetime = .keepAlways; add(t)
    }
    private func back(_ app: XCUIApplication) {
        let b = app.buttons["BackButton"].firstMatch
        if b.exists { b.tap() } else { app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap() }
        sleep(1)
    }

    func testOuterFitsAndFeatures() throws {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertFalse(app.buttons["hg.tab.搜索"].exists, "菜单栏不该再有搜索")
        let ch = app.buttons["hg.channel.真人剧"]
        XCTAssertTrue(ch.waitForExistence(timeout: 15)); ch.tap()
        let card = app.descendants(matching: .any)["hg.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        sleep(3)
        // 外屏不溢出：所有卡片、入口都在窗口里
        let win = app.windows.firstMatch.frame
        let cards = app.descendants(matching: .any).matching(identifier: "hg.card").allElementsBoundByIndex.prefix(8)
        for c in cards where c.frame.width > 0 { XCTAssertLessThanOrEqual(c.frame.maxX, win.maxX + 1, "卡片出屏：\(c.frame)") }
        for e in ["filter", "rank", "new", "upcoming"] {
            let b = app.buttons["hg.entry.\(e)"]; XCTAssertTrue(b.exists)
            XCTAssertLessThanOrEqual(b.frame.maxX, win.maxX + 1, "入口出屏：\(e) \(b.frame)")
        }
        XCTAssertTrue(app.descendants(matching: .any)["hg.waterfall.2"].exists, "外屏应是 2 列")
        shot(app, "1-outer")
        // 搜索：联想 → 结果
        app.buttons["hg.discover.search"].tap()
        let field = app.textFields["hg.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("重生")
        XCTAssertTrue(app.buttons["hg.search.suggest"].firstMatch.waitForExistence(timeout: 15), "没有搜索联想")
        sleep(1); shot(app, "2-suggest")
        app.buttons["hg.search.suggest"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["hg.card"].firstMatch.waitForExistence(timeout: 20), "搜索没有结果")
        sleep(2); shot(app, "3-search-result")
        back(app)
        // 系列剧 → 详情：补充信息 / 选季 / 剧评
        app.buttons["hg.channel.系列剧"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 20)); sleep(2)
        app.descendants(matching: .any).matching(identifier: "hg.card").firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["hg.detail.info"].waitForExistence(timeout: 20), "详情没有补充信息")
        XCTAssertTrue(app.buttons["BackButton"].exists || app.navigationBars.buttons.count > 0, "详情没有返回键")
        XCTAssertTrue(app.buttons["hg.season.2"].waitForExistence(timeout: 25), "系列剧没有选季")
        sleep(2); shot(app, "4-detail")
        if app.buttons["hg.detail.reviews"].waitForExistence(timeout: 10) {
            sleep(2)
            app.buttons["hg.detail.reviews"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["hg.reviews.list"].waitForExistence(timeout: 10), "剧评页没打开")
            sleep(3); shot(app, "5-reviews")
        } else { XCTFail("详情没有剧评") }
    }

    func testFeedChannels() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "feed"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let real = app.buttons["hg.feed.channel.真人剧"]
        XCTAssertTrue(real.waitForExistence(timeout: 20), "推荐页没有频道")
        sleep(8); shot(app, "6-feed")
        real.tap(); sleep(15); shot(app, "7-feed-real")
    }
}
