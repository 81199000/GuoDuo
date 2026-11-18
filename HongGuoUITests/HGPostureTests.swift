import XCTest

/// 姿态冒烟：开播后点评论截图（外屏底部面板 / 展开横屏右侧滑出 / 半折常驻），由外部脚本切姿态。
final class HGPostureTests: XCTestCase {
    func testCommentsInCurrentPosture() throws {
        let app = XCUIApplication()
        if let fold = ProcessInfo.processInfo.environment["TEST_RUNNER_HG_FOLD"] ?? ProcessInfo.processInfo.environment["HG_FOLD"] { app.launchEnvironment["DOUDUO_FOLD"] = fold }
        app.launch()
        if (ProcessInfo.processInfo.environment["TEST_RUNNER_HG_LANDSCAPE"] ?? "") == "1" {
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(2)
        }
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS '集'")).element(boundBy: 0)
        XCTAssertTrue(card.waitForExistence(timeout: 25))
        card.tap()
        let ep1 = app.buttons["hg.episode.1"]
        XCTAssertTrue(ep1.waitForExistence(timeout: 20))
        ep1.tap()
        let surface = app.otherElements["hg.player.surface"]
        let e = expectation(for: NSPredicate(format: "value == 'playing-1'"), evaluatedWith: surface)
        XCTAssertEqual(XCTWaiter().wait(for: [e], timeout: 60), .completed)
        sleep(2)
        if !app.otherElements["hg.comments.resident"].exists { app.buttons["hg.rail.comments"].tap() }
        XCTAssertTrue(app.staticTexts["hg.comments.title"].waitForExistence(timeout: 5), "评论没出现")
        sleep(4)
        let pane = ["hg.comments.resident", "hg.comments.side"].first { app.descendants(matching: .any)[$0].exists } ?? "sheet"
        print("HGPOSTURE pane=\(pane) window=\(app.windows.firstMatch.frame) panel=\(app.descendants(matching: .any)["hg.comments.title"].firstMatch.frame) surface=\(surface.frame)")
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "posture"; a.lifetime = .keepAlways; add(a)
    }
}
