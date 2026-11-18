import XCTest

/// 推荐流翻页速度：每次上滑后多久新的一部真正开播（pos ≥ 1），以及期间有没有出现「正在获取片源」
final class HGFeedSpeedTests: XCTestCase {
    func testSwipeToPlayLatency() throws { try run(gap: 6) }
    /// 真人刷法：开播后看 2 秒就划
    func testFastSwipes() throws { try run(gap: 2) }

    private func run(gap: UInt32) throws {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let el = app.descendants(matching: .any)["hg.feed.orientation"].firstMatch
        func state() -> (id: String, pos: Int, ms: Int) {
            guard el.exists else { return ("", -1, -1) }
            var id = "", pos = -1, ms = -1
            for kv in el.label.split(separator: " ") {
                let p = kv.split(separator: "=", maxSplits: 1); guard p.count == 2 else { continue }
                if p[0] == "id" { id = String(p[1]) }; if p[0] == "pos" { pos = Int(p[1]) ?? -1 }
                if p[0] == "ms" { ms = Int(p[1]) ?? -1 }
            }
            return (id, pos, ms)
        }
        // 第一部开播
        let t0 = Date()
        while state().pos < 1 && Date().timeIntervalSince(t0) < 60 { usleep(200_000) }
        print(String(format: "HGSPD first %.1fs", Date().timeIntervalSince(t0)))
        sleep(6)   // 给预载留时间（正常看几秒再划）
        var lat: [Double] = []
        for i in 0..<8 {
            let before = state().id
            let w = app.windows.firstMatch
            w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                .press(forDuration: 0.02, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)), withVelocity: 1500, thenHoldForDuration: 0)
            let s = Date(); var sawFetching = false
            while Date().timeIntervalSince(s) < 40 {
                let st = state()
                if app.staticTexts["正在获取片源…"].exists { sawFetching = true }
                // 画面真正动起来：新的一部 position 走过 100ms
                if st.id != before && st.ms >= 100 { break }
                usleep(150_000)
            }
            let d = Date().timeIntervalSince(s); lat.append(d)
            print(String(format: "HGSPD gap%d swipe#%d %.1fs fetchingText=%@", gap, i, d, sawFetching ? "yes" : "no"))
            sleep(gap)
        }
        print(String(format: "HGSPD avg %.1fs max %.1fs", lat.reduce(0, +) / Double(lat.count), lat.max() ?? 0))
    }
}
