import SwiftUI
import UIKit

/// 量系统标签栏（Duo 上是右侧竖向玻璃胶囊）的实际宽度和中线：推荐页右侧栏照它对齐（2026-11-26 老板：两个菜单一样宽）
@MainActor enum HGTabBarMetrics {
    /// 量到的胶囊（窗口坐标），按窗口尺寸分开存（外屏 / 内屏、横竖屏各一份）
    private static var byWindow: [String: CGRect] = [:]
    private static func key(_ size: CGSize) -> String { "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))" }
    static func capsule(for window: CGSize) -> CGRect? { byWindow[key(window)] }
    static func measure(in window: UIWindow?) {
        guard let window else { return }
        var best: CGRect?
        func walk(_ v: UIView, depth: Int) {
            guard depth < 40, !v.isHidden, v.alpha > 0.01 else { return }
            let name = NSStringFromClass(type(of: v))
            if name.contains("TabBarItemPlatterView") {
                let f = v.convert(v.bounds, to: window)
                // 竖向胶囊：高 > 宽、贴右边、宽在 30~120
                if f.height > f.width, f.width >= 30, f.width <= 120, f.maxX > window.bounds.width * 0.7 {
                    if best == nil || f.width < best!.width { best = f }
                }
            }
            for s in v.subviews { walk(s, depth: depth + 1) }
        }
        walk(window, depth: 0)
        if let best { byWindow[key(window.bounds.size)] = best }
    }
}

struct HGTabBarProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { Probe() }
    func updateUIView(_ uiView: UIView, context: Context) {}
    final class Probe: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            let w = window
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { HGTabBarMetrics.measure(in: w) }
        }
    }
}

