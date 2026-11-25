import XCTest

/// 横版剧竖屏播放：上下黑边要有环境光；设置关掉后是纯黑
final class HGAmbientShots: XCTestCase {
    private func shot(_ n: String) { let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a) }
    private func play(_ level: String) {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "search"
        app.launchArguments += ["-douyin_ambient_dim_v1", level]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let field = app.textFields["hg.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20)); field.tap()
        // 《全球死考》横版剧（每集 16:9）
        field.typeText("https://hongguoduanju.com/player/7697459724635098174\n")
        let ep = app.buttons["hg.episode.1"]
        XCTAssertTrue(ep.waitForExistence(timeout: 25)); ep.tap()
        let surface = app.otherElements["hg.player.surface"]
        let e = expectation(for: NSPredicate(format: "value == 'playing-1'"), evaluatedWith: surface)
        XCTAssertEqual(XCTWaiter().wait(for: [e], timeout: 60), .completed)
        sleep(4)
        print("AMB level=\(level) ambient=\(app.descendants(matching: .any)["hg.player.ambient"].exists)")
        shot("amb-\(level)")
        app.terminate()
    }
    func testAmbient() throws { play("60"); play("0") }
}
