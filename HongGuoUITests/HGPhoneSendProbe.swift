import XCTest

/// 手动探针（号码走环境变量，不入库）：真机同款 App 里点「获取验证码」，打印界面提示
final class HGPhoneSendProbe: XCTestCase {
    func testSend() throws {
        guard let phone = ProcessInfo.processInfo.environment["HG_PROBE_PHONE"], phone.count == 11 else { throw XCTSkip("no phone") }
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "mine"
        app.launch()
        XCTAssertTrue(app.buttons["hg.mine.login"].waitForExistence(timeout: 20)); app.buttons["hg.mine.login"].tap()
        let f = app.textFields["hg.login.phone"]; XCTAssertTrue(f.waitForExistence(timeout: 5)); f.tap(); f.typeText(phone)
        app.buttons["hg.login.send"].tap()
        sleep(15)
        let texts = app.staticTexts.allElementsBoundByIndex.map(\.label).filter { $0.contains("验证码") || $0.contains("失败") || $0.contains("错误") || $0.contains("频繁") }
        print("PHONEPROBE \(texts)")
    }
}
