import XCTest

/// 发现（剧场）：官方 App 同款——搜索框 / 频道（找剧·真人剧·漫剧）/ 筛选·排行榜·新剧·预约 / 两列大卡
final class HGDiscoverBoardsTests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ n: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a)
        let t = XCTAttachment(string: app.debugDescription); t.name = "tree-" + n; t.lifetime = .keepAlways; add(t)
    }
    private func tap(_ app: XCUIApplication, _ id: String, _ why: String) {
        let b = app.buttons[id]
        XCTAssertTrue(b.waitForExistence(timeout: 15), why)
        b.tap()
    }
    private func back(_ app: XCUIApplication) {
        let b = app.buttons["BackButton"].firstMatch
        if b.exists { b.tap() } else { app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap() }
        sleep(1)
    }

    func testTheater() throws {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        tap(app, "hg.channel.找剧", "没有「找剧」频道")
        XCTAssertTrue(app.buttons["hg.discover.search"].exists, "没有顶部搜索框")
        XCTAssertFalse(app.buttons["hg.tab.搜索"].exists, "菜单栏不该再有搜索")
        for e in ["filter", "rank", "new", "upcoming"] { XCTAssertTrue(app.buttons["hg.entry.\(e)"].exists, "没有入口 \(e)") }
        XCTAssertTrue(app.descendants(matching: .any)["hg.card"].firstMatch.waitForExistence(timeout: 25), "找剧没有出卡片")
        sleep(3); shot(app, "1-theater")
        tap(app, "hg.channel.真人剧", "没有「真人剧」频道")
        sleep(6); shot(app, "2-real")
        tap(app, "hg.channel.漫剧", "没有「漫剧」频道")
        sleep(6); shot(app, "3-comic")
        tap(app, "hg.channel.找剧", "回不到找剧")
        // 排行榜
        tap(app, "hg.entry.rank", "排行榜进不去")
        XCTAssertTrue(app.buttons["hg.zone.human"].waitForExistence(timeout: 20), "排行榜没有分区")
        XCTAssertFalse(app.buttons["hg.board.ranklist_subscribe"].exists, "排行榜里不该有预约榜")
        sleep(3); shot(app, "4-rank")
        back(app)
        // 新剧
        tap(app, "hg.entry.new", "新剧进不去")
        XCTAssertTrue(app.buttons["hg.find.sort.online_time"].waitForExistence(timeout: 20), "新剧没有排序项")
        sleep(3); shot(app, "5-new")
        back(app)
        // 预约
        tap(app, "hg.entry.upcoming", "预约进不去")
        sleep(6); shot(app, "6-upcoming")
        back(app)
        // 筛选：换漫剧后题材重新下发
        tap(app, "hg.entry.filter", "筛选进不去")
        tap(app, "hg.find.genre.comic_series", "没有「漫剧」类型")
        XCTAssertTrue(app.buttons["hg.find.category_dim_theme.all"].waitForExistence(timeout: 15), "换类型后题材没有重新下发")
        sleep(3); shot(app, "7-filter")
    }
}
