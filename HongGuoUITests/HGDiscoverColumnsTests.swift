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
        // 2026-11-25 起搜索在标签栏里
        // 右侧主菜单：图标 + 文字（自己的玻璃胶囊），内容不被它盖住
        let rail = app.descendants(matching: .any)["hg.tab.rail"]
        XCTAssertTrue(rail.waitForExistence(timeout: 10), "右侧主菜单不是带文字的胶囊")
        XCTAssertTrue(app.staticTexts["发现"].exists, "主菜单没有文字")
        let ch = app.buttons["hg.channel.找剧"]
        XCTAssertTrue(ch.waitForExistence(timeout: 15)); ch.tap()
        let card = app.descendants(matching: .any)["hg.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        sleep(3)
        // 外屏不溢出：所有卡片、入口都在窗口里
        let win = app.windows.firstMatch.frame
        let cards = app.descendants(matching: .any).matching(identifier: "hg.card").allElementsBoundByIndex.prefix(8)
        for c in cards where c.frame.width > 0 {
            XCTAssertLessThanOrEqual(c.frame.maxX, win.maxX + 1, "卡片出屏：\(c.frame)")
            XCTAssertLessThanOrEqual(c.frame.maxX, rail.frame.minX + 1, "卡片被右侧主菜单盖住：\(c.frame)")
        }
        // 入口一行、官方尺寸（高 36）；外屏放不下左右滑
        let f0 = app.buttons["hg.entry.filter"].frame, f3 = app.buttons["hg.entry.upcoming"].frame
        XCTAssertEqual(f0.minY, f3.minY, accuracy: 1, "四个入口应在一行")
        XCTAssertLessThanOrEqual(f0.height, 40, "入口太高：\(f0)")
        if f3.maxX > win.maxX + 1 {
            app.buttons["hg.entry.rank"].swipeLeft(); sleep(1)
            XCTAssertLessThanOrEqual(app.buttons["hg.entry.upcoming"].frame.maxX, win.maxX + 1, "左滑后看不到「预约」")
            app.buttons["hg.entry.new"].swipeRight(); sleep(1)
        }
        XCTAssertTrue(app.descendants(matching: .any)["hg.waterfall.2"].exists, "外屏应是 2 列")
        shot(app, "1-outer")
        // 漫剧：分类标签行 + 推荐榜卡（前 3 + 查看全部）；点分类出该分类的剧；⌄ 展开全部分类
        app.buttons["hg.channel.漫剧"].tap()
        XCTAssertTrue(app.buttons["hg.chip.推荐"].waitForExistence(timeout: 20), "漫剧没有分类标签行")
        XCTAssertTrue(app.descendants(matching: .any)["hg.top"].waitForExistence(timeout: 20), "漫剧没有推荐榜卡")
        XCTAssertFalse(app.buttons["hg.entry.filter"].exists, "四个入口只在找剧里")
        sleep(3); shot(app, "1b-comic")
        let chip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'hg.chip.' AND identifier != 'hg.chip.推荐'")).firstMatch
        let chipName = chip.label
        chip.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 20), "点分类「\(chipName)」没有出剧")
        XCTAssertFalse(app.descendants(matching: .any)["hg.top"].exists, "选了分类不该再有推荐榜卡")
        sleep(2); shot(app, "1c-comic-chip")
        app.buttons["hg.chips.all"].tap(); sleep(1); shot(app, "1d-comic-allchips")
        app.buttons["hg.chips.all"].tap()
        app.buttons["hg.chip.推荐"].tap()
        XCTAssertTrue(app.buttons["hg.top.all"].waitForExistence(timeout: 20))
        app.buttons["hg.top.all"].tap()
        XCTAssertTrue(app.buttons["hg.board.comic_series_hot_rank"].waitForExistence(timeout: 20), "查看全部没落到漫剧推荐榜")
        sleep(2); shot(app, "1e-comic-rank")
        back(app)
        app.buttons["hg.channel.找剧"].tap()
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
        // 系列剧详情：补充信息 / 选季 / 剧评（系列剧榜第一部不一定挂了系列编号——红果自己也没选季——用搜索直达一部固定的多季剧）
        app.buttons["hg.discover.search"].tap()
        let f2 = app.textFields["hg.search.field"]
        XCTAssertTrue(f2.waitForExistence(timeout: 10))
        f2.typeText("持械入宋\n")
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
