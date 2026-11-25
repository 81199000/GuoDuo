import XCTest

/// 搜索页：空着时有热门搜索 + 为你推荐；打字时联想带封面
final class HGSearchSuggestTests: XCTestCase {
    private func shot(_ n: String) { let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a) }

    func testSearchIdleAndSuggest() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "search"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let rec = app.descendants(matching: .any).matching(identifier: "hg.search.rec").firstMatch
        XCTAssertTrue(rec.waitForExistence(timeout: 30), "搜索页没有为你推荐")
        XCTAssertTrue(app.buttons.matching(identifier: "hg.search.hot").firstMatch.waitForExistence(timeout: 10), "没有热门搜索")
        sleep(3); shot("search-idle")
        let field = app.textFields["hg.search.field"]
        field.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        field.typeText("归墟")
        XCTAssertTrue(app.buttons.matching(identifier: "hg.search.suggest").firstMatch.waitForExistence(timeout: 15), "没有联想")
        sleep(4); shot("search-suggest")
        field.typeText("\n")
        sleep(5); shot("search-result")
    }
}
