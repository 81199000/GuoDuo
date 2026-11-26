import XCTest

/// 看剧上滑下一集时录屏用：看几秒 → 上滑 → 等 → 再上滑（不限速，和真机正常网络一样）
final class HGSwipeFlashRec: XCTestCase {
    func testSwipeForRecording() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "discover"
        if let k = ProcessInfo.processInfo.environment["HG_STREAM_THROTTLE_KBPS"] { app.launchEnvironment["HG_STREAM_THROTTLE_KBPS"] = k }
        if ProcessInfo.processInfo.environment["HG_KEEP_ORIENT"] != "1" { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        let tab = app.buttons["搜索"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20)); tab.tap()
        let field = app.textFields["hg.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        let sid = ProcessInfo.processInfo.environment["HG_SID"] ?? "7708882670633094206"
        field.typeText("https://hongguoduanju.com/player/\(sid)\n")
        XCTAssertTrue(app.buttons["hg.episode.1"].waitForExistence(timeout: 25))
        sleep(2)
        let ep = app.buttons["hg.episode.3"]
        for _ in 0..<6 where !(ep.exists && ep.isHittable) { app.swipeUp(); sleep(1) }
        ep.tap()
        let surface = app.otherElements["hg.player.surface"]
        XCTAssertTrue(wait(surface, "playing-3", 30))
        // 开始录屏的标记（脚本据此对齐时间）
        print("HGREC mark-play3 \(Date().timeIntervalSince1970)")
        if ProcessInfo.processInfo.environment["HG_ORIENT"] == "landscape" {
            XCUIDevice.shared.orientation = .landscapeLeft   // 宽屏：竖视频居中、两边环境光（Duo 展开同款）
            sleep(2)
        }
        sleep(UInt32(ProcessInfo.processInfo.environment["HG_WATCH_S"] ?? "6") ?? 6)
        print("HGREC swipe1 \(Date().timeIntervalSince1970)")
        surface.swipeUp(velocity: .fast)
        XCTAssertTrue(wait(surface, "playing-4", 30))
        sleep(4)
        print("HGREC swipe2 \(Date().timeIntervalSince1970)")
        surface.swipeUp(velocity: .fast)
        XCTAssertTrue(wait(surface, "playing-5", 30))
        sleep(3)
        print("HGREC end \(Date().timeIntervalSince1970)")
    }

    private func wait(_ e: XCUIElement, _ v: String, _ t: TimeInterval) -> Bool {
        let x = expectation(for: NSPredicate(format: "value == %@", v), evaluatedWith: e)
        let start = Date()
        let ok = XCTWaiter().wait(for: [x], timeout: t) == .completed
        print("HGREC \(v) waited \(Int(Date().timeIntervalSince(start) * 1000))ms ok=\(ok)")
        return ok
    }
}
