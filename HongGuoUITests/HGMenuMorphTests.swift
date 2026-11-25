import XCTest

/// 首页系统标签栏胶囊 vs 推荐页右侧栏：同宽、同中线；进出推荐有过渡；顶部频道点击区够大
final class HGMenuMorphTests: XCTestCase {
    private func shot(_ n: String) { let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a) }

    func testMorphAndChannels() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "discover"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        sleep(8)
        let tabs = app.buttons.allElementsBoundByIndex.filter { ["首页", "推荐", "搜索", "我的"].contains($0.label) }
        let tabX = tabs.map(\.frame.midX)
        print("MORPH tabs=\(tabs.map { "\($0.label)@\($0.frame)" })")
        shot("home")
        let feedTab = app.buttons["推荐"].firstMatch
        for _ in 0..<30 where !feedTab.isEnabled { sleep(1) }
        sleep(4)   // 录屏起头
        feedTab.tap()
        // 过渡中间帧
        usleep(180_000); shot("enter-mid")
        let likes = app.buttons["hg.rail.likes"]
        XCTAssertTrue(likes.waitForExistence(timeout: 40))
        sleep(2)
        let rail = app.otherElements["hg.rail"].frame
        print("MORPH rail=\(rail) likes=\(likes.frame) more=\(app.buttons["hg.rail.more"].frame) back=\(app.buttons["hg.player.close"].frame)")
        if let x = tabX.first { XCTAssertEqual(rail.midX, x, accuracy: 3, "右侧栏中线没对齐首页胶囊") }
        shot("feed")
        // 频道：点在字外面 7pt（以前点不中的地方）
        for n in ["合集", "关注", "推荐"] {
            let b = app.buttons["hg.feed.channel.\(n)"]
            XCTAssertTrue(b.exists)
            print("MORPH ch \(n)=\(b.frame)")
            b.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: 3, dy: 4)).tap()
            sleep(3)
            XCTAssertTrue(b.isSelected, "点 \(n) 左上角没点中")
        }
        // 返回首页
        sleep(2)
        app.buttons["hg.player.close"].tap()
        usleep(120_000); shot("leave-mid")
        sleep(2); shot("home-back")
        XCTAssertTrue(app.buttons["首页"].firstMatch.waitForExistence(timeout: 5))
        for k in 0..<4 {
            let t = app.buttons["首页"].firstMatch
            print("MORPH back t=\(k) 首页 exists=\(t.exists) hittable=\(t.isHittable) frame=\(t.frame)")
            sleep(1)
        }
        shot("home-back-5s")
        XCTAssertTrue(app.buttons["首页"].firstMatch.isHittable, "回首页后标签栏没回来")
    }
}
