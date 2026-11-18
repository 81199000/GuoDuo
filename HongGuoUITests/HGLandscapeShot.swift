import XCTest
final class HGLandscapeShot: XCTestCase {
    func testLandscapeChrome() throws {
        let app = XCUIApplication()
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(1)
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS '集'")).element(boundBy: 0)
        XCTAssertTrue(card.waitForExistence(timeout: 25)); card.tap()
        let ep = app.buttons["hg.episode.2"]; XCTAssertTrue(ep.waitForExistence(timeout: 20)); ep.tap()
        let surface = app.otherElements["hg.player.surface"]
        let e = expectation(for: NSPredicate(format: "value == 'playing-2'"), evaluatedWith: surface)
        XCTAssertEqual(XCTWaiter().wait(for: [e], timeout: 60), .completed)
        sleep(2)
        let any = app.descendants(matching: .any)
        print("HGLS window=\(app.windows.firstMatch.frame) surface=\(surface.frame) likes=\(app.buttons["hg.rail.likes"].frame) more=\(app.buttons["hg.rail.more"].frame) console=\(any["hg.console"].firstMatch.exists) epsPane=\(any["hg.episodes.resident"].firstMatch.exists) close=\(app.buttons["hg.player.close"].frame)")
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "ls"; a.lifetime = .keepAlways; add(a)
        app.buttons["hg.rail.comments"].tap(); sleep(3)
        let likes = app.buttons["hg.rail.likes"]
        print("HGLS2 surface=\(surface.frame) likes=\(likes.exists) \(likes.frame) close=\(app.buttons["hg.player.close"].frame)")
        XCTAssertTrue(likes.exists, "横屏开评论后菜单栏没了")
        XCTAssertLessThan(likes.frame.maxX, surface.frame.maxX + 1, "菜单栏不在视频里")
        XCTAssertGreaterThan(likes.frame.minX, surface.frame.maxX - 90, "菜单栏不在视频右边")
        let b = XCTAttachment(screenshot: app.screenshot()); b.name = "ls-comments"; b.lifetime = .keepAlways; add(b)
        XCUIDevice.shared.orientation = .portrait
    }
}
