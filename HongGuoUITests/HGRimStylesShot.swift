import XCTest

/// 菜单光圈四种样式各拍一张（推荐页，视频在播）：看效果用
final class HGRimStylesShot: XCTestCase {
    func testShots() throws {
        for style in ["环境光 + 扫光", "环境光（静止）", "奈飞配方原样", "关（只有系统玻璃）"] {
            let app = XCUIApplication()
            app.launchEnvironment["HG_START_TAB"] = "feed"
            app.launchArguments += ["-hg.rim.style.v1", style, "-hg.rim.strength.v1", "强"]
            XCUIDevice.shared.orientation = .portrait
            app.launch()
            XCTAssertTrue(app.buttons["hg.rail.likes"].waitForExistence(timeout: 40))
            sleep(6)
            let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = style; a.lifetime = .keepAlways; add(a)
            usleep(1_200_000)
            let b = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); b.name = style + "-2"; b.lifetime = .keepAlways; add(b)
            app.terminate()
        }
    }
}
