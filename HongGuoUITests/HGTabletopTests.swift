import XCTest

/// 桌面半折叠全流程（DOUDUO_FOLD=1，Duo 外屏模拟器）+ 第 5 集以后评论锁
final class HGTabletopTests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testTabletopFlow() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        app.launch()
        let any = app.descendants(matching: .any)
        // 首页：上信息 / 下选集
        XCTAssertTrue(any["hg.tabletop.info"].firstMatch.waitForExistence(timeout: 25), "首页没有桌面布局")
        XCTAssertTrue(any["hg.tabletop.episodes"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["hg.episode.1"].waitForExistence(timeout: 20), "首页下半屏没出选集")
        print("HGTAB home info=\(any["hg.tabletop.info"].firstMatch.frame) eps=\(any["hg.tabletop.episodes"].firstMatch.frame)")
        sleep(1); shot(app, "home")
        // 详情页：点上半屏
        any["hg.tabletop.info"].firstMatch.tap()
        sleep(2)
        XCTAssertTrue(app.buttons["hg.tabletop.resume"].waitForExistence(timeout: 15), "详情页没有桌面布局")
        print("HGTAB detail info=\(any["hg.tabletop.info"].firstMatch.frame) eps=\(any["hg.tabletop.episodes"].firstMatch.frame)")
        shot(app, "detail")
        // 播放第 6 集 → 操作台
        let ep6 = app.buttons["hg.episode.6"]
        XCTAssertTrue(ep6.waitForExistence(timeout: 10)); ep6.tap()
        let surface = app.otherElements["hg.player.surface"]
        let e = expectation(for: NSPredicate(format: "value == 'playing-6'"), evaluatedWith: surface)
        XCTAssertEqual(XCTWaiter().wait(for: [e], timeout: 60), .completed)
        let console = any["hg.console"].firstMatch
        XCTAssertTrue(console.waitForExistence(timeout: 5))
        let back = app.buttons["hg.player.close"], comments = app.buttons["hg.rail.comments"]
        XCTAssertTrue(back.exists && comments.exists)
        print("HGTAB console=\(console.frame) back=\(back.frame) comments=\(comments.frame) more=\(app.buttons["hg.rail.more"].frame) light=\(any["hg.console.light"].firstMatch.frame) video=\(surface.frame)")
        XCTAssertGreaterThan(back.frame.minY, console.frame.minY, "返回键不在下半屏")
        XCTAssertGreaterThan(back.frame.minX, console.frame.midX, "返回键不在右边")
        sleep(6)
        print("HGTAB danmaku=\(any["hg.console.danmaku"].firstMatch.value ?? "-")")
        shot(app, "console")
        // 第 6 集评论锁
        comments.tap()
        XCTAssertTrue(any["hg.comments.lockedTip"].firstMatch.waitForExistence(timeout: 2), "第 6 集没出锁定提示")
        XCTAssertFalse(any["hg.comments.title"].firstMatch.exists, "第 6 集评论不该展开")
        print("HGTAB tip=\(any["hg.comments.lockedTip"].firstMatch.frame) label=\(any["hg.comments.lockedTip"].firstMatch.label)")
        shot(app, "locked-tip")
    }

    /// 宽屏横屏：侧滑评论在列表区右滑能关；关闭键不在右上状态栏区
    func testLandscapeCommentsSwipeClose() throws {
        let app = XCUIApplication()
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS '集'")).element(boundBy: 0)
        XCTAssertTrue(card.waitForExistence(timeout: 25)); card.tap()
        let ep2 = app.buttons["hg.episode.2"]; XCTAssertTrue(ep2.waitForExistence(timeout: 20)); ep2.tap()
        let surface = app.otherElements["hg.player.surface"]
        let e = expectation(for: NSPredicate(format: "value == 'playing-2'"), evaluatedWith: surface)
        XCTAssertEqual(XCTWaiter().wait(for: [e], timeout: 60), .completed)
        app.buttons["hg.rail.comments"].tap()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["hg.comments.title"].firstMatch.waitForExistence(timeout: 5))
        sleep(3)
        let close = app.buttons["hg.comments.close"]
        print("HGLAND window=\(app.windows.firstMatch.frame) close=\(close.frame) title=\(any["hg.comments.title"].firstMatch.frame)")
        shot(app, "land-comments")
        XCTAssertGreaterThan(close.frame.minY, 20, "关闭键压在状态栏里")
        // 列表中间右滑
        let list = any["hg.comments.list"].firstMatch
        let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        from.press(forDuration: 0.02, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.52)), withVelocity: 900, thenHoldForDuration: 0)
        sleep(1)
        XCTAssertFalse(any["hg.comments.title"].firstMatch.exists, "右滑没关掉评论")
        XCUIDevice.shared.orientation = .portrait
    }
}
