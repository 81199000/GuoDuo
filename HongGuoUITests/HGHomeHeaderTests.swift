import XCTest

/// 首页顶栏：往下滑分类药丸收起，往上滑弹回；logo 行位置
final class HGHomeHeaderTests: XCTestCase {
    private func shot(_ n: String) { let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a) }
    func testChipsHideOnScroll() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "discover"
        app.launchArguments += ["-hg.home.style.v1", "netflix", "-hg.home.zone", ""]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let chip = app.buttons["hg.home.chip.真人剧"]
        XCTAssertTrue(chip.waitForExistence(timeout: 30))
        sleep(4)
        let logoTop = app.staticTexts["GuoDuo"].firstMatch.frame
        print("HDR start chip=\(chip.frame) title=\(logoTop) hittable=\(chip.isHittable)")
        shot("top")
        let w = app.windows.firstMatch
        w.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.8)).press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.35)))
        sleep(2)
        print("HDR down chipHittable=\(chip.isHittable) title=\(app.staticTexts["GuoDuo"].firstMatch.frame)")
        shot("down")
        XCTAssertFalse(chip.isHittable, "往下滑药丸没收起")
        w.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)).press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6)))
        sleep(2)
        print("HDR up chipHittable=\(chip.isHittable)")
        shot("up")
        XCTAssertTrue(chip.isHittable, "往上滑药丸没弹回")
    }
}
