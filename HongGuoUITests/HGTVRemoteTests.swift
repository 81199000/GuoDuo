import XCTest

/// 电视遥控：设置 → 电视遥控 → 手输地址连上真电视 → 遥控页；更多面板有「投到电视」
/// 需要局域网里开着 GuoDuo TV：TEST_RUNNER_HG_TVR=192.168.1.100:8765；没给就只测页面
final class HGTVRemoteTests: XCTestCase {
    private func shot(_ n: String) { let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a) }

    func testRemotePage() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "mine"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let settings = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "设置")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20)); settings.tap()
        let entry = app.buttons["hg.mine.tvRemote"].firstMatch
        for _ in 0..<6 where !entry.exists { app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "设置里没有电视遥控"); entry.tap()
        XCTAssertTrue(app.navigationBars["电视遥控"].waitForExistence(timeout: 5))
        sleep(5); shot("remote-list")
        guard let addr = ProcessInfo.processInfo.environment["HG_TVR"] else { return }
        // 优先点局域网发现的电视，没有再手输
        let found = app.buttons["hg.tvr.found"].firstMatch
        if found.waitForExistence(timeout: 8) {
            found.tap()
        } else {
            let field = app.textFields["hg.tvr.manual"]
            field.tap(); _ = app.keyboards.firstMatch.waitForExistence(timeout: 3); field.typeText(addr)
            app.buttons["连接"].tap()
        }
        let ok = app.buttons["hg.tvr.key.ok"].waitForExistence(timeout: 15)
        if !ok {
            app.navigationBars.firstMatch.tap()
            print("TVR texts=\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
            shot("remote-fail")
        }
        XCTAssertTrue(ok, "没进遥控器")
        sleep(3); shot("remote-pad")
    }

    func testMoreHasCast() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "feed"
        app.launch()
        let more = app.buttons["hg.rail.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 40)); sleep(3); more.tap()
        XCTAssertTrue(app.buttons["hg.more.tv"].waitForExistence(timeout: 5), "更多里没有投到电视")
        sleep(1); shot("more-white")
    }

    /// 真电视闭环：推荐页 更多 → 投到电视（打印手机进度，外面用 curl 核对电视）→ 设置 → 电视遥控 → 接到手机
    func testCastAndPull() throws {
        guard ProcessInfo.processInfo.environment["HG_TVR"] != nil else { throw XCTSkip("没给电视地址") }
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "feed"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let more = app.buttons["hg.rail.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 40))
        sleep(12)   // 播一会儿，有进度
        more.tap()
        XCTAssertTrue(app.buttons["hg.more.tv"].waitForExistence(timeout: 5)); app.buttons["hg.more.tv"].tap()
        let done = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "已投到")).firstMatch
        let ok = done.waitForExistence(timeout: 25)
        print("CAST toast=\(app.staticTexts.allElementsBoundByIndex.map(\.label).filter { $0.contains("投") || $0.contains("电视") })")
        shot("cast-done")
        XCTAssertTrue(ok, "没投成功")
        sleep(4)
        // 回到我的 → 设置 → 电视遥控 → 我的电视 → 接到手机
        app.buttons["hg.player.close"].tap()
        sleep(2)
        app.buttons["我的"].firstMatch.tap()
        let settings = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "设置")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let entry = app.buttons["hg.mine.tvRemote"].firstMatch
        for _ in 0..<6 where !entry.exists { app.swipeUp() }
        entry.tap()
        let mine = app.buttons["hg.tvr.mine"].firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 5)); mine.tap()
        let pull = app.buttons["hg.tvr.pull"]
        XCTAssertTrue(pull.waitForExistence(timeout: 10), "遥控页没显示电视在播")
        sleep(2); shot("pad-playing")
        pull.tap()
        XCTAssertTrue(app.buttons["hg.rail.more"].waitForExistence(timeout: 20) || app.otherElements["hg.player.surface"].waitForExistence(timeout: 5), "没接到手机")
        sleep(5)
        print("PULL surface=\(app.otherElements["hg.player.surface"].value as? String ?? "?") ep=\(app.staticTexts.allElementsBoundByIndex.map(\.label).filter { $0.contains("第") }.prefix(3))")
        shot("pulled")
    }
}

