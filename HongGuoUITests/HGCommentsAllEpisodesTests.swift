import XCTest

/// 第 5 集以后也能看评论（App 分集评论接口），不再弹「不支持观看」
final class HGCommentsAllEpisodesTests: XCTestCase {
    func testEpisode10Comments() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "discover"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        // 《归墟》（12 集，第 10 集有 48 条评论）：走粘贴分享链接入口
        // 搜索框直接粘分享链接打开
        let tab = app.buttons["搜索"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20)); tab.tap()
        let field = app.textFields["hg.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        field.typeText("https://hongguoduanju.com/player/7708882670633094206\n")
        let ep = app.buttons["hg.episode.10"]
        XCTAssertTrue(app.buttons["hg.episode.1"].waitForExistence(timeout: 25))
        for _ in 0..<6 where !ep.isHittable { app.swipeUp() }
        XCTAssertTrue(ep.waitForExistence(timeout: 5)); ep.tap()
        let c = app.buttons["hg.rail.comments"]
        XCTAssertTrue(c.waitForExistence(timeout: 30)); sleep(3); c.tap()
        XCTAssertFalse(app.descendants(matching: .any)["hg.comments.lockedTip"].waitForExistence(timeout: 2), "第 10 集还在提示不支持")
        XCTAssertTrue(app.staticTexts["hg.comments.title"].waitForExistence(timeout: 10), "评论面板没打开")
        sleep(5)
        let title = app.staticTexts["hg.comments.title"].label
        let rows = app.descendants(matching: .any)["hg.comments.list"].staticTexts.count
        print("CMT10 title=\(title) texts=\(rows)")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "comments"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertGreaterThan(rows, 6, "第 10 集评论没出来")
    }
}
