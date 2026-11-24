import XCTest

/// 量菜单栏各按钮位置（外屏竖 / 横）
final class HGRailMeasure: XCTestCase {
    func testMeasure() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "feed"
        for o in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = o
            if o == .portrait { app.launch() }
            XCTAssertTrue(app.buttons["hg.rail.likes"].waitForExistence(timeout: 30))
            sleep(4)
            let w = app.windows.firstMatch.frame
            var line = "RAILM \(o == .portrait ? "P" : "L") win=\(w.size)"
            for id in ["hg.player.close", "hg.rail.episodes", "hg.rail.likes", "hg.rail.more"] {
                let e = app.descendants(matching: .any)[id].firstMatch
                if e.exists { line += " \(id)=\(e.frame)" }
            }
            print(line)
            let shot = XCUIScreen.main.screenshot()
            let a = XCTAttachment(screenshot: shot); a.lifetime = .keepAlways; add(a)
        }
    }
}
