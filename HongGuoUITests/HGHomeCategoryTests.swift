import XCTest

/// 顶部药丸只剩真人剧 / 漫剧；AI剧 / 系列剧在「类别」菜单最底下，能切过去
final class HGHomeCategoryTests: XCTestCase {
    func testCategoryZones() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "discover"
        app.launchArguments += ["-hg.home.style.v1", "netflix"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let clear = app.buttons["hg.home.chip.clear"]
        if clear.waitForExistence(timeout: 15) { clear.tap() }
        XCTAssertTrue(app.buttons["hg.home.chip.真人剧"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["hg.home.chip.漫剧"].exists)
        XCTAssertFalse(app.buttons["hg.home.chip.AI剧"].exists, "AI剧还在顶部")
        XCTAssertFalse(app.buttons["hg.home.chip.系列剧"].exists, "系列剧还在顶部")
        let title = app.staticTexts["GuoDuo"].firstMatch
        print("CAT title=\(title.frame)")
        sleep(3)
        app.buttons.matching(identifier: "hg.home.category").firstMatch.tap()
        let ai = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "AI剧")).firstMatch
        // 在 26 个题材后面：菜单里往下翻到底
        sleep(1)
        let w = app.windows.firstMatch
        for _ in 0..<6 where !(ai.exists && ai.isHittable) {
            w.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.75)).press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.25)))
        }
        let a0 = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a0.name = "menu"; a0.lifetime = .keepAlways; add(a0)
        XCTAssertTrue(ai.waitForExistence(timeout: 5), "类别里没有 AI剧")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "系列剧")).firstMatch.exists, "类别里没有系列剧")
        print("CAT ai=\(ai.label)")
        print("CAT ai hittable=\(ai.isHittable) frame=\(ai.frame)")
        ai.tap()
        sleep(2)
        let b0 = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); b0.name = "after"; b0.lifetime = .keepAlways; add(b0)
        print("CAT after texts=\(app.staticTexts.allElementsBoundByIndex.prefix(8).map(\.label)) clear=\(app.buttons["hg.home.chip.clear"].exists)")
        XCTAssertTrue(app.staticTexts["AI剧"].waitForExistence(timeout: 5), "没切到 AI剧")
        XCTAssertTrue(app.buttons["hg.home.chip.clear"].exists)
        app.buttons["hg.home.chip.clear"].tap()   // 还原，别影响别的测试
    }
}
