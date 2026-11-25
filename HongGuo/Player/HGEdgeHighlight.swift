import SwiftUI

/// 玻璃胶囊 / 圆钮的「透视光圈」——奈飞胶囊边缘高光的做法（老板 2026-11-25：不是光圈旋转，是叠在背景上透出来的光圈）：
/// 1. 透视圈：沿轮廓一圈浅色毛玻璃，取的是背后真实画面 → 背后亮这圈就亮、背后什么颜色这圈就带什么颜色，
///    视频一动、栏一滑，光圈跟着背景变
/// 2. 镜面高光：左上 / 右下两段静止的细亮边（玻璃受光），叠加发光混合
/// 静止不做动画：不额外耗电，也不跟视频抢注意力。数值对着奈飞截图调的近似，不是它的原始参数。
struct HGEdgeHighlight<S: InsettableShape>: ViewModifier {
    let shape: S
    /// 透视圈宽度
    var rim: CGFloat = 2.5
    /// 镜面亮边线宽
    var lineWidth: CGFloat = 1

    func body(content: Content) -> some View {
        content.overlay {
            ZStack {
                // 透视圈：浅色材质只露出轮廓这一圈（材质本身取背后画面做模糊 + 提亮）
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .light)
                    .mask(shape.strokeBorder(lineWidth: rim))
                    .opacity(0.85)
                // 镜面高光：左上最亮、右下次亮，中段淡出
                shape.strokeBorder(
                    LinearGradient(stops: [
                        .init(color: .white.opacity(0.85), location: 0.00),
                        .init(color: .white.opacity(0.18), location: 0.28),
                        .init(color: .white.opacity(0.00), location: 0.50),
                        .init(color: .white.opacity(0.14), location: 0.72),
                        .init(color: .white.opacity(0.55), location: 1.00),
                    ], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: lineWidth)
                    .blendMode(.plusLighter)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
