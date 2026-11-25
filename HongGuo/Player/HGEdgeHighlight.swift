import SwiftUI

/// 玻璃胶囊 / 圆钮的「流光高光边」——思路来自奈飞 iOS 的胶囊边缘高光（老板 2026-11-25 拆包实证）：
/// - 路线 A（主力）：沿轮廓画一圈锥形渐变描边（亮—暗—次亮—暗），渐变角度随时间旋转 → 光沿边缘流动
/// - SHIMMER：亮度做慢呼吸
/// - 外圈一层很淡的柔光，让边缘「发光」而不是只有一条线
/// 注意：转的是渐变的起始角度，不是 rotationEffect 转形状——竖长胶囊整个转起来轮廓会歪。
/// 系统「减弱动态效果」打开时只留静态亮边。数值是对着奈飞截图调的近似，不是它的原始参数。
struct HGEdgeHighlight<S: InsettableShape>: ViewModifier {
    let shape: S
    /// 线宽：1.2pt（奈飞截图里亮边很细）
    var lineWidth: CGFloat = 1.2
    /// 扫一圈的秒数：慢一点，不抢视频
    var period: Double = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            if reduceMotion {
                ring(angle: .degrees(-90), breathe: 0.85)
            } else {
                // 30fps 足够顺滑，比 60fps 省电（视频同时在播）
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    let angle = Angle.degrees((t / period).truncatingRemainder(dividingBy: 1) * 360)
                    // 呼吸：0.7 ↔ 1.0，周期 3.2s
                    let breathe = 0.85 + 0.15 * sin(t * 2 * .pi / 3.2)
                    ring(angle: angle, breathe: breathe)
                }
            }
        }
    }

    private func ring(angle: Angle, breathe: Double) -> some View {
        let gradient = Gradient(stops: [
            .init(color: .white.opacity(0.95), location: 0.00),
            .init(color: .white.opacity(0.10), location: 0.18),
            .init(color: .white.opacity(0.00), location: 0.32),
            .init(color: .white.opacity(0.45), location: 0.50),
            .init(color: .white.opacity(0.00), location: 0.68),
            .init(color: .white.opacity(0.10), location: 0.82),
            .init(color: .white.opacity(0.95), location: 1.00),
        ])
        let stroke = AngularGradient(gradient: gradient, center: .center, angle: angle)
        return ZStack {
            // 外圈柔光：同一条渐变线，模糊后垫在下面
            shape.strokeBorder(stroke, lineWidth: lineWidth * 2.5)
                .blur(radius: 3)
                .opacity(0.35 * breathe)
            shape.strokeBorder(stroke, lineWidth: lineWidth)
                .opacity(breathe)
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
