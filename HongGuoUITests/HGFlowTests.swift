import XCTest

/// 真网络冒烟（二期）：发现 → 详情 → 竖滑播放器 → 热评 / 选集 / 上滑下一集 / 铺满 / 清屏 / 收藏 → 下载一集。
final class HGFlowTests: XCTestCase {
    func testPlayerPhase2() throws {
        let app = XCUIApplication()
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS '集'")).element(boundBy: 0)
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
        print("HGSTATS comments=\(comments.label) likes=\(app.buttons["hg.rail.likes"].label) fav=\(app.buttons["hg.rail.favorite"].label)")

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

        // 热评面板
        app.buttons["hg.rail.comments"].tap()
        XCTAssertTrue(app.staticTexts["本集热评"].waitForExistence(timeout: 5))
        sleep(3)
        attach(app, "comments")
        app.swipeDown(velocity: .fast)
        sleep(1)

        // 选集面板切第 4 集
        app.buttons["hg.rail.episodes"].tap()
        let ep4 = app.buttons["4"].firstMatch
        XCTAssertTrue(ep4.waitForExistence(timeout: 5))
        ep4.tap()
        XCTAssertTrue(playing(app, 4), "选集切到第 4 集失败")

        // 上滑到下一集
        app.otherElements["hg.player.surface"].swipeUp(velocity: .fast)
        XCTAssertTrue(playing(app, 5), "上滑未切到第 5 集")
        attach(app, "swiped-ep5")

        // 铺满 / 完整切换、清屏
        app.buttons["hg.rail.fill"].tap()
        sleep(1)
        attach(app, "fit-mode")
        app.buttons["hg.rail.fill"].tap()
        app.buttons["hg.rail.clean"].tap()
        XCTAssertTrue(app.buttons["hg.player.exitClean"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["hg.rail.favorite"].exists, "清屏后右侧栏应隐藏")
        attach(app, "clean")
        app.buttons["hg.player.exitClean"].tap()
        XCTAssertTrue(app.buttons["hg.rail.favorite"].waitForExistence(timeout: 3))

        // 收藏：点两次，状态应来回切换（上次运行可能已收藏）
        let fav = app.buttons["hg.rail.favorite"]
        let before = fav.value as? String
        fav.tap()
        XCTAssertNotEqual(app.buttons["hg.rail.favorite"].value as? String, before, "收藏状态未切换")
        app.buttons["hg.rail.favorite"].tap()
        XCTAssertEqual(app.buttons["hg.rail.favorite"].value as? String, before, "收藏状态未切回")

        // 退出，下载第 1 集
        app.buttons["hg.player.close"].tap()
        let dl = app.buttons["hg.detail.download"]
        XCTAssertTrue(dl.waitForExistence(timeout: 5))
        dl.tap()
        app.buttons["hg.episode.1"].tap()
        app.buttons["hg.detail.download.confirm"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["我的"].tap()
        let entry = app.buttons["hg.mine.downloads"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        let done = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '1/1 集'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 90), "离线下载未完成")
        attach(app, "downloads")

        // 红果扫码登录：二维码出现即可（确认需要真人手机扫码）
        app.navigationBars.buttons.element(boundBy: 0).tap()
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

    private func attach(_ app: XCUIApplication, _ name: String) {
        _ = app
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
