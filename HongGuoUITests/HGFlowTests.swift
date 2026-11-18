import XCTest

/// 真网络冒烟：发现 → 详情 → 播放第 2 集 → 自动出画面 → 选集切到第 3 集。
final class HGFlowTests: XCTestCase {
    func testDiscoverToPlayback() throws {
        let app = XCUIApplication()
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS '集'")).element(boundBy: 0)
        XCTAssertTrue(card.waitForExistence(timeout: 20), "发现页没有剧集")
        card.tap()
        let ep2 = app.buttons["hg.episode.2"]
        XCTAssertTrue(ep2.waitForExistence(timeout: 20), "详情页没有选集")
        attach(app, "detail")
        ep2.tap()
        let toggle = app.buttons["hg.player.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertTrue(playing(app, 2), "第 2 集未开始")
        sleep(3)
        attach(app, "playing-ep2")
        if !app.buttons["hg.player.episodes"].isHittable { app.tap() }
        app.buttons["hg.player.episodes"].tap()
        let ep3 = app.buttons["3"].firstMatch
        XCTAssertTrue(ep3.waitForExistence(timeout: 5))
        ep3.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '第 3 集'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(playing(app, 3), "第 3 集未开始")
        sleep(3)
        attach(app, "playing-ep3")
    }

    /// 片源 + 下载 + 解密完成、画面时间前进后，播放面才标成 playing-N。
    private func playing(_ app: XCUIApplication, _ n: Int) -> Bool {
        let surface = app.otherElements["hg.player.surface"]
        let e = expectation(for: NSPredicate(format: "value == %@", "playing-\(n)"), evaluatedWith: surface)
        return XCTWaiter().wait(for: [e], timeout: 60) == .completed
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
