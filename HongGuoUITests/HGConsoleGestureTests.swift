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
        // 大方块排版：-10 / 播放 / +10 三块等宽并排、间距小
        let back = app.buttons["hg.console.back10"].frame, play = app.buttons["hg.console.play"].frame, fwd = app.buttons["hg.console.fwd10"].frame
        print("HGW5 back=\(back) play=\(play) fwd=\(fwd) next=\(app.buttons["hg.console.next"].frame)")
        XCTAssertEqual(back.width, play.width, accuracy: 2); XCTAssertEqual(play.width, fwd.width, accuracy: 2)
        XCTAssertLessThan(play.minX - back.maxX, 12)
        XCTAssertGreaterThan(play.height, 70)
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
        XCTAssertLessThan(f.minY, 30, "提示不在最上方")
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

extension HGConsoleGestureTests {
    func testShotDeskLight() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        app.launchEnvironment["HG_START_TAB"] = "feed"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["hg.console.pad"].firstMatch.waitForExistence(timeout: 120))
        sleep(12)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "desklight"; a.lifetime = .keepAlways; add(a)
    }
}

extension HGConsoleGestureTests {
    /// 退出 App（没开画中画）：立刻停声音，回来不自动续播
    func testExitStopsPlayback() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        app.launchEnvironment["HG_START_TAB"] = "feed"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let pad = app.descendants(matching: .any)["hg.console.pad"].firstMatch
        XCTAssertTrue(pad.waitForExistence(timeout: 120)); sleep(6)
        func pos() -> Int { Int((pad.value as? String) ?? "") ?? -1 }
        let p0 = pos()
        // 这台 Duo 模拟器上 press(.home) 不会让 App 退到后台（state 仍是 4=前台），改成切到「设置」
        XCUIApplication(bundleIdentifier: "com.apple.Preferences").activate()
        sleep(5)
        app.activate()
        XCTAssertTrue(pad.waitForExistence(timeout: 10)); sleep(1)
        let p1 = pos()
        print("HGWX exit pos \(p0) -> \(p1)")
        XCTAssertLessThanOrEqual(p1 - p0, 2, "退出后还在播")
        sleep(3)
        XCTAssertLessThanOrEqual(pos() - p1, 1, "回来不该自动续播")
    }
}

extension HGConsoleGestureTests {
    /// 完整播放页竖屏（非半折叠）：返回键在右侧菜单栏最上面
    func testFullPlayerBackOnRail() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "discover"
        app.launchEnvironment["HG_DEMO_SERIES"] = "7697459724635098174"
        app.launchEnvironment["HG_DEMO_EP"] = "6"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let back = app.buttons["hg.player.close"]
        XCTAssertTrue(back.waitForExistence(timeout: 60)); sleep(6)
        let rail = app.buttons["hg.rail.likes"].exists ? app.buttons["hg.rail.likes"] : app.buttons["hg.rail.more"]
        print("HGWB back=\(back.frame) rail=\(rail.frame) win=\(app.windows.firstMatch.frame)")
        XCTAssertEqual(back.frame.midX, rail.frame.midX, accuracy: 4, "返回键没和菜单栏对齐")
        XCTAssertLessThan(back.frame.maxY, rail.frame.minY, "返回键不在菜单栏上面")
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "fullplayer"; a.lifetime = .keepAlways; add(a)
    }
}

extension HGConsoleGestureTests {
    /// 竖屏半折叠、弹幕位置 = 影片区：上半屏视频上有弹幕；弹窗里能设密度 / 透明度 / 字号
    func testTabletopDanmakuOnVideo() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        app.launchEnvironment["HG_START_TAB"] = "feed"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let any = app.descendants(matching: .any)
        let pad = any["hg.console.pad"].firstMatch
        XCTAssertTrue(pad.waitForExistence(timeout: 120)); sleep(4)
        pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["hg.console.danmakuButton"].tap()
        let video = app.buttons["hg.console.danmaku.video"]
        XCTAssertTrue(video.waitForExistence(timeout: 3)); video.tap()
        pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap()
        let layer = any["hg.player.danmaku"].firstMatch
        XCTAssertTrue(layer.waitForExistence(timeout: 20), "影片区没有弹幕层")
        XCTAssertGreaterThan(Int(layer.value as? String ?? "") ?? 0, 0, "没拉到弹幕")
        sleep(7)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "tabletop-video-danmaku"; a.lifetime = .keepAlways; add(a)
    }
}

extension HGConsoleGestureTests {
    /// 「更多」里有倍速 + 弹幕（密度 / 透明度 / 字号），标题不压拖动条；竖屏、横屏、半折叠各截一张
    func testMoreSheetLayout() throws {
        // Duo 外屏模拟器不跟着转横屏：横屏单独在展开尺寸（iPad 11 寸）模拟器上跑，HG_MORE_ONLY=landscape
        let only = ProcessInfo.processInfo.environment["HG_MORE_ONLY"]
        let cases: [(String, Bool, UIDeviceOrientation)] = only == "landscape" ? [("landscape", false, .landscapeLeft), ("unfold-portrait", false, .portrait)]
            : [("portrait", false, .portrait), ("fold", true, .portrait)]
        for (name, fold, orient) in cases {
            let app = XCUIApplication()
            app.launchEnvironment["HG_START_TAB"] = "discover"
            app.launchEnvironment["HG_DEMO_SERIES"] = "7697459724635098174"
            app.launchEnvironment["HG_DEMO_EP"] = "2"
            if fold { app.launchEnvironment["DOUDUO_FOLD"] = "1" }
            XCUIDevice.shared.orientation = orient
            app.launch()
            let any = app.descendants(matching: .any)
            if fold {
                let pad = any["hg.console.pad"].firstMatch
                XCTAssertTrue(pad.waitForExistence(timeout: 60)); sleep(4)
                pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                app.buttons["hg.console.more"].tap()
            } else {
                let more = app.buttons["hg.rail.more"]
                XCTAssertTrue(more.waitForExistence(timeout: 60)); sleep(4)
                more.tap()
            }
            let dense = app.buttons["hg.danmaku.density.2"]
            XCTAssertTrue(dense.waitForExistence(timeout: 5), "\(name): 更多里没有弹幕密度")
            sleep(1)
            let sheet = any["hg.more.sheet"].firstMatch
            print("HGWM \(name) sheet=\(sheet.frame) rate1=\(app.buttons["hg.more.rate.1.0"].frame) dense=\(dense.frame) font=\(app.buttons["hg.danmaku.font.20"].frame)")
            let a = XCTAttachment(screenshot: app.screenshot()); a.name = "more-\(name)"; a.lifetime = .keepAlways; add(a)
            if !app.buttons["hg.danmaku.font.20"].isHittable { sheet.swipeUp(); sleep(1) }
            app.buttons["hg.danmaku.font.20"].tap()
            XCTAssertEqual(app.buttons["hg.danmaku.font.20"].value as? String, "on", "\(name): 字号没切上")
            app.buttons["hg.danmaku.font.17"].tap()
            app.terminate()
        }
        XCUIDevice.shared.orientation = .portrait
    }
}
