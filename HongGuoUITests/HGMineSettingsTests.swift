import XCTest

/// 「我的」：右上 ☰ 已去掉，「设置」入口能打开设置页
final class HGMineSettingsTests: XCTestCase {
    func testSettingsEntry() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "mine"
        app.launch()
        let s = app.buttons["hg.mine.settings"]
        XCTAssertTrue(s.waitForExistence(timeout: 20))
        XCTAssertEqual(app.buttons.matching(identifier: "hg.mine.settings").count, 1, "设置入口重复")
        XCTAssertFalse(app.images["line.3.horizontal"].exists)
        s.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5), "设置页没打开")
        print("MINESET top=\(s.frame)")
    }
}
