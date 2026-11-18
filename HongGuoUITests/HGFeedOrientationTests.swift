import XCTest

/// 推荐流按姿态选片：竖屏只放竖屏片、横屏只放横屏片；竖屏半折叠（桌面）算横屏
final class HGFeedOrientationTests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ n: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a)
    }
    /// 等当前这部真正开播（pos ≥ 2），读出 want / aspect / id
    private func current(_ app: XCUIApplication, timeout: Double = 60) -> (want: String, aspect: Double, id: String)? {
        let el = app.descendants(matching: .any)["hg.feed.orientation"].firstMatch
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if el.exists {
                let parts = Dictionary(uniqueKeysWithValues: el.label.split(separator: " ").compactMap { kv -> (String, String)? in
                    let p = kv.split(separator: "=", maxSplits: 1); return p.count == 2 ? (String(p[0]), String(p[1])) : nil })
                if let pos = Int(parts["pos"] ?? ""), pos >= 2, let a = Double(parts["aspect"] ?? "") {
                    return (parts["want"] ?? "?", a, parts["id"] ?? "")
                }
            }
            usleep(500_000)
        }
        return nil
    }
    private func swipeNext(_ app: XCUIApplication) {
        let w = app.windows.firstMatch
        w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            .press(forDuration: 0.02, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)), withVelocity: 1500, thenHoldForDuration: 0)
    }

    func testPortraitPlaysPortraitOnly() throws {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        var seen = Set<String>()
        for i in 0..<3 {
            guard let c = current(app) else { return XCTFail("第 \(i + 1) 部没开播") }
            print("HGORI portrait #\(i) want=\(c.want) aspect=\(c.aspect) id=\(c.id)")
            XCTAssertEqual(c.want, "P")
            XCTAssertLessThan(c.aspect, 1, "竖屏放了横屏片 \(c.id)")
            XCTAssertFalse(seen.contains(c.id)); seen.insert(c.id)
            if i == 0 { shot(app, "portrait") }
            swipeNext(app); sleep(2)
        }
    }

    func testTabletopPlaysLandscapeOnly() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        var seen = Set<String>()
        let pad = app.descendants(matching: .any)["hg.console.pad"].firstMatch
        for i in 0..<3 {
            guard let c = current(app) else { return XCTFail("桌面姿态第 \(i + 1) 部没开播") }
            print("HGORI tabletop #\(i) want=\(c.want) aspect=\(c.aspect) id=\(c.id)")
            XCTAssertEqual(c.want, "L")
            XCTAssertGreaterThan(c.aspect, 1, "桌面姿态放了竖屏片 \(c.id)")
            XCTAssertFalse(seen.contains(c.id)); seen.insert(c.id)
            if i == 0 { shot(app, "tabletop") }
            // 桌面姿态在下半屏触控板上滑翻下一部
            pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.02, thenDragTo: pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)), withVelocity: 900, thenHoldForDuration: 0)
            sleep(2)
        }
    }

    func testLandscapePlaysLandscapeOnly() throws {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        var seen = Set<String>()
        for i in 0..<3 {
            guard let c = current(app) else { return XCTFail("横屏第 \(i + 1) 部没开播") }
            print("HGORI landscape #\(i) want=\(c.want) aspect=\(c.aspect) id=\(c.id)")
            XCTAssertEqual(c.want, "L")
            XCTAssertGreaterThan(c.aspect, 1, "横屏放了竖屏片 \(c.id)")
            XCTAssertFalse(seen.contains(c.id)); seen.insert(c.id)
            if i == 0 { shot(app, "landscape") }
            swipeNext(app); sleep(2)
        }
    }

    func testBookFoldPlaysPortraitOnly() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        guard let c = current(app) else { return XCTFail("书本姿态没开播") }
        print("HGORI book want=\(c.want) aspect=\(c.aspect) id=\(c.id)")
        XCTAssertEqual(c.want, "P")
        XCTAssertLessThan(c.aspect, 1, "书本姿态放了横屏片")
        shot(app, "book")
    }
}
