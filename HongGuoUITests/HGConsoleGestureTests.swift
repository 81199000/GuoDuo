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

extension HGConsoleGestureTests {
    /// 截图：控制层五键排布 + 长按时左上角提示
    func testShotControlsAndBadge() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        app.launchEnvironment["HG_START_TAB"] = "feed"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let pad = app.descendants(matching: .any)["hg.console.pad"].firstMatch
        XCTAssertTrue(pad.waitForExistence(timeout: 120))
        sleep(8)
        pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); sleep(1)
        let prev = app.buttons["hg.console.prev"].frame, back = app.buttons["hg.console.back10"].frame
        let play = app.buttons["hg.console.play"].frame, fwd = app.buttons["hg.console.fwd10"].frame, next = app.buttons["hg.console.next"].frame
        print("HGW5 prev=\(prev) back=\(back) play=\(play) fwd=\(fwd) next=\(next)")
        XCTAssertLessThan(back.minX - prev.maxX, 16); XCTAssertLessThan(play.minX - back.maxX, 20)
        XCTAssertGreaterThanOrEqual(back.width, 58)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "controls"; a.lifetime = .keepAlways; add(a)
        pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap(); sleep(1)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            let b = XCTAttachment(screenshot: app.screenshot()); b.name = "badge"; b.lifetime = .keepAlways; self.add(b)
            print("HGWB badge=\(app.descendants(matching: .any)["hg.player.boostBadge"].firstMatch.frame)")
        }
        pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).press(forDuration: 3)
    }
}

extension HGConsoleGestureTests {
    /// 锁定提示在最上方；沉浸式下锁定后 5 秒消失，普通状态不消失
    func testLockBadgeTopAndImmersiveTimeout() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        app.launchEnvironment["HG_START_TAB"] = "feed"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let any = app.descendants(matching: .any)
        let pad = any["hg.console.pad"].firstMatch
        XCTAssertTrue(pad.waitForExistence(timeout: 120)); sleep(8)
        let badge = any["hg.player.boostBadge"].firstMatch
        let from = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let down = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        // 普通状态：锁定后提示一直在，且在最上方居中
        from.press(forDuration: 1.0, thenDragTo: down); sleep(1)
        XCTAssertTrue(badge.exists, "锁定后没有提示")
        let f = badge.frame; let w = app.windows.firstMatch.frame
        print("HGWL badge=\(f) window=\(w)")
        XCTAssertLessThan(f.minY, 80, "提示不在最上方")
        XCTAssertEqual(f.midX, w.midX, accuracy: 6, "提示没居中")
        sleep(7); XCTAssertTrue(badge.exists, "非沉浸式不该 5 秒消失")
        // 解锁，进沉浸式
        down.press(forDuration: 1.0, thenDragTo: pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))); sleep(1)
        XCTAssertFalse(badge.exists, "解锁后提示该消失")
        pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["hg.console.more"].tap()
        XCTAssertTrue(app.buttons["hg.more.clean"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["hg.more.clean"].label.contains("沉浸式"), true, "名字没改：\(app.buttons["hg.more.clean"].label)")
        app.buttons["hg.more.clean"].tap(); sleep(2)
        from.press(forDuration: 1.0, thenDragTo: down)
        let t0 = Date(); sleep(1)
        XCTAssertTrue(badge.exists, "沉浸式锁定后应先显示")
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "immersive-lock"; a.lifetime = .keepAlways; add(a)
        sleep(3); XCTAssertTrue(badge.exists, "4 秒时不该消失")
        sleep(3)
        XCTAssertFalse(badge.exists, "5 秒后没消失 \(Date().timeIntervalSince(t0))")
        print("HGWL gone at ~\(Date().timeIntervalSince(t0))s")
    }
}
