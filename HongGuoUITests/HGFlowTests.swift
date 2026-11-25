import XCTest

/// 真网络冒烟（二期）：发现 → 详情 → 竖滑播放器 → 热评 / 选集 / 上滑下一集 / 铺满 / 清屏 / 收藏 → 下载一集。
final class HGFlowTests: XCTestCase {
    func testPlayerPhase2() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "discover"
        app.launchArguments += ["-hg.home.style.v1", "classic"]   // 走红果主题（两列大卡）
        app.launch()
        // 发现页是官方剧场大卡（不显示集数）：按卡片标识找
        let card = app.descendants(matching: .any).matching(identifier: "hg.card").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "发现页没有剧集")
        card.tap()
        let ep2 = app.buttons["hg.episode.2"]
        XCTAssertTrue(ep2.waitForExistence(timeout: 20), "详情页没有选集")
        ep2.tap()
        XCTAssertTrue(playing(app, 2), "第 2 集未开始")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '第 2 集'")).firstMatch.isHittable, "屏上显示的不是第 2 集")
        // 弹幕：首个 30 秒窗口到了（来源剧本身弹幕少时也应 > 0）
        let dm = app.otherElements["hg.player.danmaku"]
        let loaded = expectation(for: NSPredicate(format: "value != '0'"), evaluatedWith: dm)
        XCTAssertEqual(XCTWaiter().wait(for: [loaded], timeout: 15), .completed, "弹幕没有加载")
        sleep(4)
        attach(app, "player-ep2-danmaku")

        // 官方统计：评论数 / 点赞数显示成数字（不是「热评」「点赞」占位）
        let comments = app.buttons["hg.rail.comments"]
        let hasCount = expectation(for: NSPredicate(format: "label MATCHES '.*[0-9].*'"), evaluatedWith: comments)
        XCTAssertEqual(XCTWaiter().wait(for: [hasCount], timeout: 10), .completed, "评论数未显示")
        print("HGSTATS comments=\(comments.label) likes=\(app.buttons["hg.rail.likes"].label) fav=\(app.buttons["hg.rail.favorite"].label) railFrame=\(app.otherElements["hg.rail"].frame) window=\(app.windows.firstMatch.frame)")

        // 拖进度条：出现预览画面
        let bar = app.otherElements["hg.player.progress"].firstMatch
        let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        let mid = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: mid, withVelocity: 200, thenHoldForDuration: 1.5)
        attach(app, "seek-preview")

        // 切后台：不应自动进入画中画（回来后仍是播放页，而不是系统画中画窗）
        XCUIDevice.shared.press(.home)
        sleep(2)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        attach(springboard, "background")
        XCTAssertFalse(springboard.otherElements["PIPUIView"].exists || springboard.windows["PictureInPicture"].exists, "切后台自动进入了画中画")
        app.activate()
        XCTAssertTrue(app.buttons["hg.rail.comments"].waitForExistence(timeout: 5))
        // 没开听书模式：退出后应已暂停（不再出声），回来停在暂停状态
        XCTAssertEqual(app.otherElements["hg.player.surface"].value as? String, "idle", "退出 App 后仍在播放")
        app.otherElements["hg.player.surface"].tap()   // 单击继续播放，后续步骤照常

        // 热评面板
        app.buttons["hg.rail.comments"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["hg.comments.title"].waitForExistence(timeout: 5))
        sleep(3)
        attach(app, "comments")
        app.buttons["hg.comments.close"].tap()
        sleep(1)

        // 右侧栏只剩 点赞 / 评论 / 收藏 / 更多（铺满 2026-11-26 收进更多）
        for id in ["hg.rail.likes", "hg.rail.comments", "hg.rail.favorite", "hg.rail.more"] {
            XCTAssertTrue(app.buttons[id].exists, "缺少 \(id)")
        }
        for id in ["hg.rail.episodes", "hg.rail.speed", "hg.rail.danmaku", "hg.rail.clean", "hg.rail.pip", "hg.rail.fill"] {
            XCTAssertFalse(app.buttons[id].exists, "\(id) 应收进更多")
        }
        XCTAssertTrue(app.buttons["hg.rail.likes"].frame.minY > 140, "右侧栏顶部被状态栏挡住")
        attach(app, "rail")

        // 更多 → 选集，切第 4 集
        app.buttons["hg.rail.more"].tap()
        let pick = app.buttons["hg.more.episodes"]
        XCTAssertTrue(pick.waitForExistence(timeout: 3), "更多面板没有打开")
        attach(app, "more-menu")
        pick.tap()
        let ep4 = app.buttons["4"].firstMatch
        XCTAssertTrue(ep4.waitForExistence(timeout: 5))
        ep4.tap()
        XCTAssertTrue(playing(app, 4), "选集切到第 4 集失败")

        // 上滑到下一集
        app.otherElements["hg.player.surface"].swipeUp(velocity: .fast)
        XCTAssertTrue(playing(app, 5), "上滑未切到第 5 集")
        attach(app, "swiped-ep5")

        // 铺满 / 完整切换、清屏
        app.buttons["hg.rail.more"].tap()
        XCTAssertTrue(app.buttons["hg.more.fill"].waitForExistence(timeout: 3), "更多里没有铺满")
        app.buttons["hg.more.fill"].tap()
        sleep(1)
        attach(app, "fit-mode")
        app.buttons["hg.rail.more"].tap()
        XCTAssertTrue(app.buttons["hg.more.fill"].waitForExistence(timeout: 3))
        attach(app, "more-fill")
        app.buttons["hg.more.fill"].tap()
        sleep(1)
        app.buttons["hg.rail.more"].tap()
        XCTAssertTrue(app.buttons["hg.more.clean"].waitForExistence(timeout: 3))
        app.buttons["hg.more.clean"].tap()
        XCTAssertTrue(app.buttons["hg.player.exitClean"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["hg.rail.favorite"].exists, "清屏后右侧栏应隐藏")
        attach(app, "clean")
        app.buttons["hg.player.exitClean"].tap()
        XCTAssertTrue(app.buttons["hg.rail.favorite"].waitForExistence(timeout: 3))

        // 收藏：点两次，状态应来回切换（上次运行可能已收藏）
        let rail = app.otherElements["hg.rail"]
        let before = rail.value as? String
        app.buttons["hg.rail.favorite"].tap()
        XCTAssertNotEqual(app.otherElements["hg.rail"].value as? String, before, "收藏状态未切换")
        app.buttons["hg.rail.favorite"].tap()
        XCTAssertEqual(app.otherElements["hg.rail"].value as? String, before, "收藏状态未切回")

        // 退出：离线下载已下线，详情页不应再有「下载」，「我的」里也没有「离线下载」
        app.buttons["hg.player.close"].tap()
        XCTAssertTrue(app.buttons["hg.episode.1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["hg.detail.download"].exists, "详情页不应再有下载按钮")
        attach(app, "detail-no-download")
        back(app)
        (app.tabBars.buttons["我的"].exists ? app.tabBars.buttons["我的"] : app.buttons["我的"].firstMatch).tap()
        XCTAssertTrue(app.buttons["hg.mine.login"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["hg.mine.downloads"].exists, "「我的」里不应再有离线下载")

        // 红果扫码登录：二维码出现即可（确认需要真人手机扫码）
        app.buttons["hg.mine.login"].tap()
        XCTAssertTrue(app.staticTexts["等待扫码…"].waitForExistence(timeout: 15), "二维码未加载")
        attach(app, "login-qr")
    }

    /// 片源 + 下载 + 解密完成、画面时间前进后，播放面才标成 playing-N。
    private func playing(_ app: XCUIApplication, _ n: Int) -> Bool {
        let surface = app.otherElements["hg.player.surface"]
        let e = expectation(for: NSPredicate(format: "value == %@", "playing-\(n)"), evaluatedWith: surface)
        return XCTWaiter().wait(for: [e], timeout: 60) == .completed
    }

    /// iPhone 是导航栏返回键；Duo 外屏系统竖栏里叫 BackButton
    private func back(_ app: XCUIApplication) {
        let nav = app.navigationBars.buttons.element(boundBy: 0)
        if nav.exists { nav.tap() } else { app.buttons["BackButton"].firstMatch.tap() }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        _ = app
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
