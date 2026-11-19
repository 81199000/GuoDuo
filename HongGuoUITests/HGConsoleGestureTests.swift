import XCTest
final class HGConsoleGestureTests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ n: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a)
    }
    /// 推荐页（竖屏半折叠）不显示主菜单
    func testFeedHidesTabBar() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        app.launchEnvironment["HG_START_TAB"] = "feed"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["hg.console.pad"].firstMatch.waitForExistence(timeout: 120))
        sleep(3)
        XCTAssertEqual(app.tabBars.count, 0, "推荐页不该有系统标签栏")
        XCTAssertFalse(app.buttons["hg.tab.推荐"].exists, "推荐页不该有侧边主菜单")
    }
    /// 触控板长按 2×，按住后下滑锁定、上滑解锁
    func testLockBoost() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        app.launchEnvironment["HG_START_TAB"] = "feed"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let pad = app.descendants(matching: .any)["hg.console.pad"].firstMatch
        XCTAssertTrue(pad.waitForExistence(timeout: 120))
        sleep(8)
        func pos() -> Double { Double((pad.value as? String) ?? "") ?? -1 }
        func rate(_ label: String) -> Double {
            let t0 = Date(); let p0 = pos(); sleep(4)
            let r = (pos() - p0) / Date().timeIntervalSince(t0); print("HGW \(label) rate=\(r)"); return r
        }
        let from = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let down = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let up = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let r0 = rate("before")
        from.press(forDuration: 1.0, thenDragTo: down)   // 长按后下滑 → 锁定
        sleep(1); shot(app, "locked-badge")
        let r1 = rate("after-lock-release")
        XCTAssertGreaterThan(r1, 1.6, "下滑没锁住 2×")
        XCTAssertEqual(app.descendants(matching: .any)["hg.console.pad"].firstMatch.label.isEmpty, false)
        down.press(forDuration: 1.0, thenDragTo: up)     // 长按后上滑 → 解锁
        sleep(1)
        let r2 = rate("after-unlock")
        XCTAssertLessThan(r2, 1.4, "上滑没解锁")
        print("HGW r0=\(r0) r1=\(r1) r2=\(r2)")
    }
    func testHoldBoost() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        app.launchEnvironment["HG_START_TAB"] = "feed"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let pad = app.descendants(matching: .any)["hg.console.pad"].firstMatch
        XCTAssertTrue(pad.waitForExistence(timeout: 120))
        sleep(8)
        func pos() -> Double { Double((pad.value as? String) ?? "") ?? -1 }
        let t0 = Date(); let p0 = pos()
        pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).press(forDuration: 4)
        let r = (pos() - p0) / Date().timeIntervalSince(t0)
        XCTAssertGreaterThan(r, 1.5, "长按没加速 \(r)")
        sleep(1)
        XCTAssertEqual(app.descendants(matching: .any)["hg.console"].firstMatch.value as? String, "idle", "长按松手不该呼出控制层")
    }
}
