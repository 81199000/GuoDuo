import XCTest

/// 发现：官方榜单（分区 × 榜）、找剧（最新上架 / 7 天内上新 / 题材）
final class HGDiscoverBoardsTests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ n: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a)
    }
    private func tap(_ app: XCUIApplication, _ id: String, _ why: String) {
        let b = app.buttons[id]
        XCTAssertTrue(b.waitForExistence(timeout: 15), why)
        b.tap()
    }

    func testBoardsAndFind() throws {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        tap(app, "hg.mode.rank", "没有「榜单」")
        // 榜单目录服务端下发：分区 + 榜
        XCTAssertTrue(app.buttons["hg.zone.human"].waitForExistence(timeout: 20), "没有拿到榜单分区（真人剧）")
        XCTAssertTrue(app.buttons["hg.board.ranklist_new_rank_sc"].exists, "没有新剧榜")
        XCTAssertFalse(app.buttons["hg.board.ranklist_subscribe"].exists, "预约榜不该出现")
        XCTAssertTrue(app.staticTexts["第 1 名"].waitForExistence(timeout: 15) || app.otherElements["第 1 名"].exists || app.descendants(matching: .any)["第 1 名"].exists, "榜单没有名次")
        shot(app, "rank-hot")
        tap(app, "hg.board.ranklist_new_rank_sc", "新剧榜点不了")
        sleep(4); shot(app, "rank-new")
        tap(app, "hg.zone.human", "真人剧分区点不了")
        XCTAssertTrue(app.buttons["hg.board.human_new_rank"].waitForExistence(timeout: 10), "换分区没有落到同名的新剧榜")
        sleep(4); shot(app, "rank-human-new")
        // 找剧：最新上架 + 7 天内上新
        tap(app, "hg.mode.find", "没有「找剧」")
        tap(app, "hg.find.sort.online_time", "没有「最新上架」")
        tap(app, "hg.find.online_time.days_7", "没有「7 天内上新」")
        sleep(5); shot(app, "find-new7")
        tap(app, "hg.find.genre.comic_series", "没有「漫剧」类型")
        sleep(5)
        XCTAssertTrue(app.buttons["hg.find.category_dim_theme.all"].waitForExistence(timeout: 10), "换类型后题材没有重新下发")
        tap(app, "hg.find.more", "没有「更多筛选」")
        sleep(2); shot(app, "find-comic-more")
    }
}
