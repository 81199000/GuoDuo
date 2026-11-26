import XCTest

/// 边下边播：点一集到出画面不该等整集下完；中途拖到后面没下到的地方也要能接着播；连滑下一集照常
final class HGStreamPlaybackTests: XCTestCase {
    func testStreamStartSeekAndSwipe() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "discover"
        // 限速 400KB/s：一集几十 MB 要下好几分钟，才能测到「没下完就开播」「拖到没下到的地方」
        app.launchEnvironment["HG_STREAM_THROTTLE_KBPS"] = "400"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        // 《归墟》：粘贴分享链接直达；第 7 集（推荐流 / 历史都不会提前缓存到这集）
        let tab = app.buttons["搜索"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20)); tab.tap()
        let field = app.textFields["hg.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        field.typeText("https://hongguoduanju.com/player/7708882670633094206\n")
        XCTAssertTrue(app.buttons["hg.episode.1"].waitForExistence(timeout: 25))
        sleep(2)   // 集列表布局稳定
        let ep = app.buttons["hg.episode.7"]
        for _ in 0..<6 where !(ep.exists && ep.isHittable) { app.swipeUp(); sleep(1) }
        XCTAssertTrue(ep.exists && ep.isHittable, "找不到第 7 集")
        let t0 = Date()
        ep.tap()
        let surface = app.otherElements["hg.player.surface"]
        XCTAssertTrue(wait(surface, "playing-7", 30), "第 7 集没起播")
        print("HGSTREAM first-play \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        shot(app, "ep7-playing")
        sleep(2)
        // 往后拖：进度条拖到 80% 处（这时后面大半集还没下到，走单独 Range 取那一段）
        let bar = app.descendants(matching: .any)["hg.player.progress"].firstMatch
        if !bar.exists { surface.tap() }
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "找不到进度条")
        let before = Int(bar.value as? String ?? "") ?? -1
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: bar.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        print("HGSTREAM seek from=\(before)s")
        let seekT = Date()
        XCTAssertTrue(wait(surface, "playing-7", 10), "拖动后不播了")
        sleep(3)
        if !bar.exists { surface.tap() }
        _ = bar.waitForExistence(timeout: 3)
        let after = Int(bar.value as? String ?? "") ?? -1
        print("HGSTREAM after-seek pos=\(after)s (\(Int(Date().timeIntervalSince(seekT) * 1000))ms after drag)")
        XCTAssertGreaterThan(after, before + 20, "拖动没生效")
        shot(app, "ep7-after-seek")
        // 连滑下一集
        surface.swipeUp(velocity: .fast)
        XCTAssertTrue(wait(surface, "playing-8", 20), "第 8 集没起播")
        sleep(2)
        shot(app, "ep8-playing")
    }

    private func wait(_ e: XCUIElement, _ v: String, _ t: TimeInterval) -> Bool {
        let x = expectation(for: NSPredicate(format: "value == %@", v), evaluatedWith: e)
        let start = Date()
        let ok = XCTWaiter().wait(for: [x], timeout: t) == .completed
        print("HGSTREAM \(v) waited \(Int(Date().timeIntervalSince(start) * 1000))ms ok=\(ok)")
        return ok
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
