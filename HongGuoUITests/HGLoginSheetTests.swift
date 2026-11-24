import XCTest

/// 登录页：默认手机号登录（手机号 + 验证码），可切扫码；手机号不满 11 位不能发码
final class HGLoginSheetTests: XCTestCase {
    func testPhoneLoginForm() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "mine"
        app.launch()
        let entry = app.buttons["hg.mine.login"]
        XCTAssertTrue(entry.waitForExistence(timeout: 20))
        entry.tap()
        let phone = app.textFields["hg.login.phone"]
        XCTAssertTrue(phone.waitForExistence(timeout: 5), "默认不是手机号登录")
        XCTAssertTrue(app.textFields["hg.login.code"].exists)
        XCTAssertFalse(app.buttons["hg.login.send"].isEnabled, "没填手机号就能发码")
        phone.tap(); phone.typeText("1381234")
        XCTAssertFalse(app.buttons["hg.login.send"].isEnabled, "手机号不满 11 位就能发码")
        XCTAssertFalse(app.buttons["hg.login.submit"].isEnabled, "没发码就能登录")
        // 切扫码：提示另一台手机实时扫，不再叫人截图
        app.buttons["扫码登录"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '另一台'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '可截图'")).firstMatch.exists, "还在叫人截图")
        let a = XCTAttachment(screenshot: app.screenshot()); a.lifetime = .keepAlways; add(a)
    }
}
