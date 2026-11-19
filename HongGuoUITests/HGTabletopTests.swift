import XCTest

/// 桌面半折叠全流程（DOUDUO_FOLD=1，Duo 外屏模拟器）+ 第 5 集以后评论锁
final class HGTabletopTests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testTabletopFlow() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        XCUIDevice.shared.orientation = .portrait
        app.launchEnvironment["HG_START_TAB"] = "discover"
        app.launch()
        let any = app.descendants(matching: .any)
        // 首页：上片库网格 / 下选集
        XCTAssertTrue(any["hg.tabletop.grid"].firstMatch.waitForExistence(timeout: 25), "首页没有桌面布局")
        let cards = any.matching(identifier: "hg.tabletop.card")
        XCTAssertGreaterThan(cards.count, 3, "上半屏网格没出来")
        XCTAssertTrue(app.buttons["hg.episode.1"].waitForExistence(timeout: 20), "首页下半屏没出选集")
        print("HGTAB home grid=\(any["hg.tabletop.grid"].firstMatch.frame) cards=\(cards.count) eps=\(any["hg.tabletop.episodes"].firstMatch.frame)")
        sleep(1); shot(app, "home")
        // 点第 2 张：选中、下半屏换成它的选集
        let second = cards.element(boundBy: 1)
        let name0 = (any["hg.tabletop.info"].firstMatch.label)
        second.tap(); sleep(2)
        XCTAssertEqual(second.value as? String, "selected", "点卡片没选中")
        let name1 = any["hg.tabletop.info"].firstMatch.label
        print("HGTAB switch \(name0.prefix(12)) -> \(name1.prefix(12))")
        XCTAssertNotEqual(name0, name1, "下半屏没换成选中剧")
        shot(app, "home-switched")
        // 再点一次 → 详情
        second.tap()
        sleep(2)
        XCTAssertTrue(app.buttons["hg.tabletop.resume"].waitForExistence(timeout: 15), "详情页没有桌面布局")
        let info = any["hg.tabletop.info"].firstMatch.frame, eps = any["hg.tabletop.episodes"].firstMatch.frame
        print("HGTAB detail info=\(info) eps=\(eps) gap=\(eps.minY - info.maxY)")
        XCTAssertGreaterThanOrEqual(eps.minY - info.maxY, 20, "详情页信息区压到折痕了")
        shot(app, "detail")
        // 播放第 6 集 → 操作台
        let ep6 = app.buttons["hg.episode.6"]
        XCTAssertTrue(ep6.waitForExistence(timeout: 10)); ep6.tap()
        let surface = app.otherElements["hg.player.surface"]
        let e = expectation(for: NSPredicate(format: "value == 'playing-6'"), evaluatedWith: surface)
        XCTAssertEqual(XCTWaiter().wait(for: [e], timeout: 60), .completed)
        let console = any["hg.console"].firstMatch
        XCTAssertTrue(console.waitForExistence(timeout: 5))
        sleep(3)
        print("HGTAB console=\(console.frame) state=\(console.value ?? "-") video=\(surface.frame) brackets=\(any["hg.console.brackets"].firstMatch.exists)")
        shot(app, "console-idle")
        // 轻点呼出控制
        any["hg.console.pad"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["hg.console.play"].waitForExistence(timeout: 2), "轻点没呼出控制")
        let back = app.buttons["hg.player.close"]
        print("HGTAB back=\(back.frame) play=\(app.buttons["hg.console.play"].frame) bar=\(any["hg.console.bar"].firstMatch.frame) tiles=\(app.buttons["hg.console.danmakuButton"].frame) more=\(app.buttons["hg.console.more"].frame) title=\(any["hg.console.title"].firstMatch.exists)")
        XCTAssertGreaterThan(back.frame.minY, console.frame.minY, "返回键不在下半屏")
        // 大方块铺满排版（2026-11-19）：顶排 ~11%、播放键中心 ~38%
        let rel = { (y: CGFloat) in (y - console.frame.minY) / console.frame.height }
        let playC = app.buttons["hg.console.play"].frame.midY
        print("HGTAB spread top=\(rel(back.frame.midY)) play=\(rel(playC)) bar=\(rel(any["hg.console.bar"].firstMatch.frame.midY))")
        XCTAssertTrue((0.08...0.24).contains(rel(back.frame.midY)), "顶排位置不对")  // 2026-11-19 参考图：顶排紧贴面板上沿（~11%）
        XCTAssertTrue((0.28...0.52).contains(rel(playC)), "播放键位置不对")  // 大方块铺满排版：中排在 ~38%
        shot(app, "console-controls")
        // 暂停 / 继续
        app.buttons["hg.console.play"].tap(); sleep(1)
        XCTAssertEqual(surface.value as? String, "idle", "暂停键无效")
        app.buttons["hg.console.play"].tap(); sleep(1)
        // +10
        func pos() -> Int { Int((any["hg.console.pad"].firstMatch.value as? String) ?? "") ?? -1 }
        let p0 = pos(); app.buttons["hg.console.fwd10"].tap(); sleep(1)
        let p1 = pos(); print("HGTAB fwd10 \(p0)->\(p1)")
        // 缓存跨启动保留后会从历史进度续播：离结尾不到 10 秒时 +10 直接进下一集（位置回到开头）也算有效
        XCTAssertTrue(p1 >= p0 + 8 || (p0 > 30 && p1 < 5), "+10 无效 \(p0)->\(p1)")
        // 弹幕位置：切到触控区
        app.buttons["hg.console.danmakuButton"].tap()
        XCTAssertTrue(app.buttons["hg.console.danmaku.console"].waitForExistence(timeout: 2))
        shot(app, "console-danmaku-popover")
        app.buttons["hg.console.danmaku.console"].tap(); sleep(1)
        XCTAssertEqual(app.buttons["hg.console.danmaku.console"].value as? String, "on")
        // 环境光
        let amb = app.buttons["hg.console.ambient"]; let before = amb.value as? String
        amb.tap(); sleep(1); XCTAssertNotEqual(app.buttons["hg.console.ambient"].value as? String, before)
        app.buttons["hg.console.ambient"].tap()
        // 收起后弹幕在触控区
        app.buttons["hg.console.danmakuButton"].tap()   // 再点一次关 popover
        sleep(6)
        print("HGTAB after-hide state=\(console.value ?? "-") consoleDanmaku=\(any["hg.console.danmaku"].firstMatch.exists) videoDanmaku=\(any["hg.player.danmaku"].firstMatch.exists)")
        shot(app, "console-danmaku-in-pad")
        // 拖动快进
        let p2 = pos()
        let padEl = any["hg.console.pad"].firstMatch
        padEl.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: padEl.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)), withVelocity: 300, thenHoldForDuration: 1.5)
        sleep(1)
        let p3 = pos(); print("HGTAB drag \(p2)->\(p3)")
        // 锁定
        padEl.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["hg.console.lock"].waitForExistence(timeout: 2))
        app.buttons["hg.console.lock"].tap(); sleep(1)
        XCTAssertEqual(console.value as? String, "locked")
        padEl.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7)).tap()
        XCTAssertTrue(app.buttons["hg.console.unlock"].waitForExistence(timeout: 2), "锁定后没出解锁")
        shot(app, "console-locked")
        app.buttons["hg.console.unlock"].tap(); sleep(1)
        // 更多里有评论：第 6 集提示
        app.buttons["hg.console.more"].tap()
        XCTAssertTrue(app.buttons["hg.more.comments"].waitForExistence(timeout: 3), "更多里没有评论")
        XCTAssertTrue(app.buttons["hg.more.like"].exists && app.buttons["hg.more.favorite"].exists)
        shot(app, "more")
        app.buttons["hg.more.comments"].tap(); sleep(1)
        XCTAssertFalse(any["hg.comments.title"].firstMatch.exists)
        app.swipeDown(); sleep(1)
        // 返回 → 详情 → 首页
        padEl.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["hg.player.close"].waitForExistence(timeout: 2))
        app.buttons["hg.player.close"].tap(); sleep(2)
        XCTAssertTrue(app.buttons["hg.tabletop.resume"].waitForExistence(timeout: 5), "没回到详情")
        let back2 = app.buttons["hg.tabletop.back"]
        XCTAssertTrue(back2.exists, "详情页下半屏没有返回首页键")
        print("HGTAB tabletopBack=\(back2.frame)")
        back2.tap(); sleep(2)
        XCTAssertTrue(app.navigationBars["发现"].waitForExistence(timeout: 3), "回不到首页")
        sleep(2)
        XCTAssertTrue(any["hg.tabletop.grid"].firstMatch.exists, "回首页后不是上下布局")
        shot(app, "back-home")
    }

    /// 宽屏横屏：侧滑评论在列表区右滑能关；关闭键不在右上状态栏区
    func testLandscapeCommentsSwipeClose() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "discover"
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
