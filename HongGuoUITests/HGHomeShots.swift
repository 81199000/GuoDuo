import XCTest

/// 奈飞式首页：外屏竖 / 横各拍顶部 + 往下滑一屏；数行数、海报、Top 10、标签栏
final class HGHomeShots: XCTestCase {
    private func shot(_ n: String) { let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a) }
    func testHome() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "discover"
        app.launchEnvironment["HG_DEMO_LIBRARY"] = "5"
        app.launchArguments += ["-hg.home.style.v1", "netflix", "-hg.home.zone", ""]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let hero = app.descendants(matching: .any).matching(identifier: "hg.home.hero").firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 30), "大海报没出来")
        sleep(5)
        shot("P-top")
        print("HOME hero=\(hero.frame) chips=\(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'hg.home.chip.'")).count) category=\(app.buttons.matching(identifier: "hg.home.category").count) tabs=\(app.tabBars.buttons.allElementsBoundByIndex.map(\.label))")
        app.swipeUp(); sleep(3); shot("P-scroll1")
        app.swipeUp(); sleep(3); shot("P-scroll2")
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'hg.home.row.'"))
        print("HOME rows=\(rows.allElementsBoundByIndex.map(\.identifier))")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(4); shot("L-mid")
        for _ in 0..<4 { app.swipeDown() }
        sleep(3); shot("L-top")
        let h = app.descendants(matching: .any).matching(identifier: "hg.home.hero").firstMatch
        if h.exists { print("HOME L hero=\(h.frame) win=\(app.windows.firstMatch.frame)") }
        XCUIDevice.shared.orientation = .portrait
    }
}
