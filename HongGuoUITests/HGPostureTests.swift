import XCTest

/// 姿态冒烟：开播后点评论截图（外屏底部面板 / 展开横屏右侧滑出 / 半折常驻），由外部脚本切姿态。
final class HGPostureTests: XCTestCase {
    func testCommentsInCurrentPosture() throws {
        let app = XCUIApplication()
        if let fold = ProcessInfo.processInfo.environment["TEST_RUNNER_HG_FOLD"] ?? ProcessInfo.processInfo.environment["HG_FOLD"] { app.launchEnvironment["DOUDUO_FOLD"] = fold }
        app.launchEnvironment["HG_START_TAB"] = "discover"
        app.launch()
        if (ProcessInfo.processInfo.environment["TEST_RUNNER_HG_LANDSCAPE"] ?? "") == "1" {
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(2)
        }
        if let sid = ProcessInfo.processInfo.environment["TEST_RUNNER_HG_SERIES"] {
            // 指定剧（弹幕多的），走粘贴分享链接入口
            XCTAssertTrue(app.buttons["hg.share"].waitForExistence(timeout: 15))
            app.buttons["hg.share"].tap()
            let field = app.textFields["hg.share.field"].exists ? app.textFields["hg.share.field"] : app.textViews["hg.share.field"]
            field.tap(); field.typeText("https://hongguoduanju.com/player/\(sid)")
            app.buttons["hg.share.open"].tap()
        } else {
            let card = app.buttons.matching(NSPredicate(format: "label CONTAINS '集'")).element(boundBy: 0)
            XCTAssertTrue(card.waitForExistence(timeout: 25))
            card.tap()
        }
        let ep1 = app.buttons["hg.episode.1"]
        XCTAssertTrue(ep1.waitForExistence(timeout: 20))
        ep1.tap()
        let surface = app.otherElements["hg.player.surface"]
        let e = expectation(for: NSPredicate(format: "value == 'playing-1'"), evaluatedWith: surface)
        XCTAssertEqual(XCTWaiter().wait(for: [e], timeout: 60), .completed)
        sleep(2)
        let any = app.descendants(matching: .any)
        if any["hg.console"].exists {
            // 桌面姿态：操作台
            let console = any["hg.console"].firstMatch
            sleep(4)
            print("HGCONSOLE frame=\(console.frame) danmaku=\(any["hg.console.danmaku"].firstMatch.value ?? "-") light=\(any["hg.console.light"].firstMatch.value ?? "-") video=\(surface.frame)")
            shot(app, "console")
            // 左右滑 → 快进，期间截预览
            let from = console.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.4))
            let to = console.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4))
            func pos() -> Int {
                // hint 不暴露给 XCUI；用 debugDescription 里的 hint 文本
                let d = app.otherElements["hg.player.surface"].debugDescription
                guard let r = d.range(of: "pos=") else { return -1 }
                return Int(d[r.upperBound...].prefix { $0.isNumber }) ?? -1
            }
            let posBefore = pos()
            print("HGSEEKSTART")
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: 300, thenHoldForDuration: 2.5)
            print("HGSEEKEND")
            sleep(1)
            let posAfter = pos()
            print("HGSEEK before=\(posBefore) after=\(posAfter)")
            XCTAssertTrue(posAfter > posBefore + 20 || posAfter < 5, "操作台横滑没有快进（before=\(posBefore) after=\(posAfter)）")
            shot(app, "console-seek")
            sleep(1)
            // 金光投影开关
            let light = any["hg.console.light"].firstMatch
            let before = light.value as? String
            light.tap()
            sleep(1)
            XCTAssertNotEqual(any["hg.console.light"].firstMatch.value as? String, before, "金光投影开关无效")
            shot(app, "console-light-toggled")
            light.tap()
            // 单击 = 暂停
            console.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).tap()
            sleep(1)
            XCTAssertEqual(surface.value as? String, "idle", "单击操作台没有暂停")
            return
        }
        if any["hg.episodes.resident"].exists {
            let rail = app.buttons["hg.rail.likes"]
            print("HGBOOK episodes frame=\(any["hg.episodes.resident"].firstMatch.frame) video=\(surface.frame) rail=\(rail.frame) more=\(app.buttons["hg.rail.more"].frame)")
            XCTAssertTrue(rail.exists, "书本姿态视频上没有菜单栏")
            XCTAssertGreaterThan(rail.frame.midX, surface.frame.midX, "菜单栏不在视频右边")
            shot(app, "book-episodes")
            app.buttons["hg.ep.3"].firstMatch.tap()
            let e3 = expectation(for: NSPredicate(format: "value == 'playing-3'"), evaluatedWith: surface)
            XCTAssertEqual(XCTWaiter().wait(for: [e3], timeout: 60), .completed, "书本姿态点选集没切到第 3 集")
            return
        }
        if !app.otherElements["hg.comments.resident"].exists { app.buttons["hg.rail.comments"].tap() }
        XCTAssertTrue(app.staticTexts["hg.comments.title"].waitForExistence(timeout: 5), "评论没出现")
        sleep(4)
        let pane = ["hg.comments.resident", "hg.comments.side"].first { app.descendants(matching: .any)[$0].exists } ?? "sheet"
        print("HGPOSTURE pane=\(pane) window=\(app.windows.firstMatch.frame) panel=\(app.descendants(matching: .any)["hg.comments.title"].firstMatch.frame) surface=\(surface.frame)")
        shot(app, "posture")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
