import XCTest

/// 检查更新：启动弹窗显示版本对比 + 更新说明；「我的 → 关于」有版本号 / 检查更新 / 开源仓库
final class HGUpdateTests: XCTestCase {
    func testLaunchUpdateSheetAndAbout() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_FAKEUPDATE"] = "1"
        app.launchEnvironment["HG_START_TAB"] = "mine"
        app.launch()

        // 启动 3 秒后自动弹新版本
        let sheet = app.otherElements["hg.update.sheet"].firstMatch
        let open = app.buttons["hg.update.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 20), "启动没有弹出新版本提醒")
        XCTAssertTrue(app.staticTexts["v9.9.9"].exists, "弹窗没显示新版本号")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '按姿态选片'")).firstMatch.exists, "弹窗没显示更新内容")
        XCTAssertTrue(app.staticTexts["新功能"].exists, "Markdown 标题没渲染")
        _ = sheet
        attach(app, "update-sheet")
        app.buttons["hg.update.later"].tap()
        XCTAssertTrue(open.waitForNonExistence(timeout: 5), "「以后再说」没关掉弹窗")

        // 关于：滚到底
        let check = app.buttons["hg.about.check"]
        for _ in 0..<8 where !check.isHittable { app.swipeUp() }
        XCTAssertTrue(check.isHittable, "没有「检查更新」")
        XCTAssertTrue(app.buttons["hg.about.repo"].exists, "没有「开源仓库」")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'jackotom/hongguo-drama'")).firstMatch.exists, "没写上游致谢")
        attach(app, "about-section")

        // 手动检查：同样弹出（手动检查不受「以后再说」影响）
        check.tap()
        XCTAssertTrue(open.waitForExistence(timeout: 15), "手动检查更新没有弹窗")
        attach(app, "update-sheet-manual")
        app.buttons["hg.update.later"].tap()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
