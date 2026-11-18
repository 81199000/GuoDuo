import XCTest

/// 竖屏半折叠：下半屏触控板上下滑切视频（推荐页切剧、完整播放页切集）；横滑仍是快进退
final class HGTabletopSwipeTests: XCTestCase {
    private func label(_ e: XCUIElement) -> String { (e.label) }
    private func shot(_ app: XCUIApplication, _ n: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a)
    }

    func testFeedPadSwipe() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        app.launchEnvironment["HG_START_TAB"] = "feed"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let pad = app.descendants(matching: .any)["hg.console.pad"].firstMatch
        XCTAssertTrue(pad.waitForExistence(timeout: 120), "推荐页没出触控板")
        let playing = NSPredicate(format: "value != '0' AND value != '1' AND value != '2'")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: playing, evaluatedWith: pad)], timeout: 60), .completed, "第一部没开播")
        let first = pad.label
        print("HGSW feed first=\(first)")
        shot(app, "feed-1")
        // 上滑 → 下一部
        pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            .press(forDuration: 0.02, thenDragTo: pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)), withVelocity: 900, thenHoldForDuration: 0)
        let changed = NSPredicate(format: "label != %@", first)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: changed, evaluatedWith: pad)], timeout: 30), .completed, "上滑没切到下一部")
        let second = pad.label
        print("HGSW feed second=\(second)")
        XCTAssertNotEqual(first.components(separatedBy: " ").first, second.components(separatedBy: " ").first, "不是另一部剧")
        sleep(3); shot(app, "feed-2")
        // 下滑 → 回上一部
        pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            .press(forDuration: 0.02, thenDragTo: pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)), withVelocity: 900, thenHoldForDuration: 0)
        let back = NSPredicate(format: "label == %@", first)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: back, evaluatedWith: pad)], timeout: 30), .completed, "下滑没回到上一部")
        print("HGSW feed back=\(pad.label)")
        // 横滑仍然是快进
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: playing, evaluatedWith: pad)], timeout: 60), .completed)
        let p0 = Int(pad.value as? String ?? "") ?? 0
        pad.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: pad.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.52)), withVelocity: 300, thenHoldForDuration: 1)
        sleep(1)
        let p1 = Int(pad.value as? String ?? "") ?? 0
        print("HGSW feed seek \(p0)->\(p1) label=\(pad.label)")
        XCTAssertGreaterThan(p1, p0 + 15, "横滑没快进")
        XCTAssertEqual(pad.label, first, "横滑不该切剧")
    }

    func testFullPlayerPadSwipe() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        app.launchEnvironment["HG_START_TAB"] = "feed"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        // 推荐 → 全集 → 详情第 2 集
        let pad = app.descendants(matching: .any)["hg.console.pad"].firstMatch
        XCTAssertTrue(pad.waitForExistence(timeout: 90))
        pad.tap()
        let more = app.buttons["hg.console.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 3)); more.tap()
        let all = app.buttons["hg.more.episodes"]
        XCTAssertTrue(all.waitForExistence(timeout: 3)); all.tap()
        let ep2 = app.buttons["hg.episode.2"]
        XCTAssertTrue(ep2.waitForExistence(timeout: 20), "没进详情页"); ep2.tap()
        let pad2 = app.descendants(matching: .any).matching(identifier: "hg.console.pad").allElementsBoundByIndex.last!
        let ep2p = NSPredicate(format: "label ENDSWITH 'ep=2'")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: ep2p, evaluatedWith: pad2)], timeout: 40), .completed, "没开第 2 集：\(pad2.label)")
        sleep(2)
        pad2.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            .press(forDuration: 0.02, thenDragTo: pad2.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)), withVelocity: 900, thenHoldForDuration: 0)
        let ep3p = NSPredicate(format: "label ENDSWITH 'ep=3'")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: ep3p, evaluatedWith: pad2)], timeout: 30), .completed, "上滑没到第 3 集：\(pad2.label)")
        print("HGSW full up=\(pad2.label)")
        pad2.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            .press(forDuration: 0.02, thenDragTo: pad2.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)), withVelocity: 900, thenHoldForDuration: 0)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: ep2p, evaluatedWith: pad2)], timeout: 30), .completed, "下滑没回第 2 集：\(pad2.label)")
        print("HGSW full down=\(pad2.label)")
        shot(app, "full")
    }
}
