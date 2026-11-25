import XCTest

/// 「我的 → 安装到电视」：局域网找到电视 → 点安装 → 下载 → 推送 → 装完。
/// 需要真电视在线：`TEST_RUNNER_HG_TV_IP` 指定其 IP；没给就跳过。默认走线上清单，调试可用 `TEST_RUNNER_HG_TV_MANIFEST` 覆盖。
final class HGTVInstallTests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ n: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a)
    }

    private func openPage(_ app: XCUIApplication) {
        let link = app.buttons["hg.mine.tvInstall"].firstMatch
        for _ in 0..<6 where !link.exists { app.swipeUp() }
        XCTAssertTrue(link.waitForExistence(timeout: 5), "「我的」里没有「安装到电视」入口")
        link.tap()
    }

    func testManualIPValidation() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "mine"
        app.launch()
        openPage(app)
        let ip = app.textFields["hg.tv.ip"]
        XCTAssertTrue(ip.waitForExistence(timeout: 8))
        ip.tap(); ip.typeText("abc")
        app.buttons["hg.tv.connect"].tap()
        XCTAssertTrue(app.staticTexts["IP 格式不对，应类似 192.168.1.20"].waitForExistence(timeout: 3), "非法 IP 没有提示")
        shot(app, "tv-bad-ip")
    }

    func testDiscoverAndInstall() throws {
        let env = ProcessInfo.processInfo.environment
        guard let tvIP = env["HG_TV_IP"] else { throw XCTSkip("没给 HG_TV_IP") }
        let manifest = env["HG_TV_MANIFEST"]   // 不给就走线上清单（真实用户路径）
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "mine"
        app.launchArguments += ["-hg.tv.tutorialSeen", "YES"]
        if let manifest { app.launchArguments += ["-hg.tv.manifest", manifest] }
        app.launch()
        openPage(app)
        // 局域网扫描应当自己找到这台电视（不靠手填）
        let row = app.buttons["hg.tv.device.\(tvIP)"]
        let found = row.waitForExistence(timeout: 25)
        shot(app, "tv-list")
        XCTAssertTrue(found, "Bonjour 没扫到电视 \(tvIP)")
        row.tap()
        let done = app.staticTexts["已安装到电视"].firstMatch, upd = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '已更新到'")).firstMatch
        let fail = app.staticTexts["没装成功"].firstMatch
        let end = Date().addingTimeInterval(90)
        var sawProgress = false
        while Date() < end, !done.exists, !upd.exists, !fail.exists {
            if app.progressIndicators.count > 0 { sawProgress = true }
            usleep(300_000)
        }
        XCTAssertTrue(app.staticTexts["已在电视上打开，用遥控器就能看了。"].waitForExistence(timeout: 15), "装完没有把电视版拉起来")
        shot(app, "tv-result")
        XCTAssertFalse(fail.exists, "安装失败")
        XCTAssertTrue(done.exists || upd.exists, "90 秒内没装完")
        XCTAssertTrue(sawProgress)
    }
}
