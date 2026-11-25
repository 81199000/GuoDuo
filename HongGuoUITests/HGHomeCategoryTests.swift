import XCTest

/// 顶部分区药丸按屏宽自适应（最前「全部」，选中只变色不藏别的）：真人剧 / 漫剧 / AI剧 / 系列剧 / 西饭 / 河马，放不下的收进「类别」菜单最底下「更多分区」
final class HGHomeCategoryTests: XCTestCase {
    private let all = ["真人剧", "漫剧", "AI剧", "系列剧", "西饭", "河马"]
    private func shot(_ n: String) { let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a) }

    private func launch(_ o: UIDeviceOrientation) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "discover"
        app.launchArguments += ["-hg.home.style.v1", "netflix"]
        XCUIDevice.shared.orientation = o
        app.launch()
        let allChip = app.buttons["hg.home.chip.全部"]
        XCTAssertTrue(allChip.waitForExistence(timeout: 30), "没有「全部」"); allChip.tap()
        XCTAssertTrue(app.buttons["hg.home.chip.真人剧"].waitForExistence(timeout: 30))
        return app
    }

    func testCategoryZones() throws {
        for o in [UIDeviceOrientation.portrait, .landscapeLeft] {
            let app = launch(o)
            sleep(2)
            let shown = all.filter { app.buttons["hg.home.chip.\($0)"].exists }
            let screenW = app.windows.firstMatch.frame.width
            print("CAT o=\(o.rawValue) w=\(screenW) shown=\(shown)")
            // 药丸都在一行、不出屏
            for n in shown { XCTAssertLessThanOrEqual(app.buttons["hg.home.chip.\(n)"].frame.maxX, screenW + 0.5, "\(n) 出屏") }
            XCTAssertLessThanOrEqual(app.buttons["hg.home.category"].frame.maxX, screenW + 0.5, "类别出屏")
            shot("home-\(o == .portrait ? "portrait" : "landscape")")
            let hidden = all.filter { !shown.contains($0) }
            if let last = hidden.last {
                // 收起来的在类别菜单底部
                app.buttons.matching(identifier: "hg.home.category").firstMatch.tap()
                sleep(1)
                let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", last)).firstMatch
                let w = app.windows.firstMatch
                for _ in 0..<8 where !(item.exists && item.isHittable) {
                    w.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.75)).press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.25)))
                }
                shot("menu-\(o.rawValue)")
                XCTAssertTrue(item.waitForExistence(timeout: 5), "类别里没有 \(last)")
                item.tap()
            } else {
                app.buttons["hg.home.chip.河马"].tap()
            }
            sleep(1)
            let target = hidden.last ?? "河马"
            XCTAssertTrue(app.staticTexts[target].waitForExistence(timeout: 5), "没切到 \(target)")
            // 选了分区，别的药丸还在
            for n in shown { XCTAssertTrue(app.buttons["hg.home.chip.\(n)"].exists, "选了 \(target) 后 \(n) 被藏了") }
            XCTAssertTrue(app.buttons["hg.home.chip.全部"].exists)
            // 西饭 / 河马 有内容行
            sleep(6)
            shot("zone-\(target)-\(o.rawValue)")
            // 再点一个顶部药丸：它变色、其它照旧
            app.buttons["hg.home.chip.漫剧"].tap(); sleep(3)
            XCTAssertTrue(app.buttons["hg.home.chip.漫剧"].isSelected, "漫剧没选中")
            XCTAssertFalse(app.buttons["hg.home.chip.全部"].isSelected)
            shot("zone-漫剧-\(o.rawValue)")
            app.buttons["hg.home.chip.全部"].tap()
            app.terminate()
        }
        XCUIDevice.shared.orientation = .portrait
    }
}
