import SwiftUI
import UIKit

// 胶囊菜单「光圈」试验（老板 2026-11-25，按奈飞 iOS 26.6.0 拆包结论）：
// 系统玻璃（.glassEffect）之上再叠一层自定义边缘高光。奈飞是 AngularGradient 锥形渐变描边 + 循环 + 三档强度；
// 老板要的是「叠在视频上，胶囊周圈有环境光变化」→ 加了「环境光」两种：光圈颜色 / 亮度取自胶囊背后正在播的画面。
// 四种样式 + 三档强度都能在「我的 → 设置 → 菜单光圈」里切，推荐页上直接对比；定了再删掉不要的。

enum HGRimStyle: String, CaseIterable, Identifiable {
    case ambientSweep = "环境光 + 扫光"
    case ambient = "环境光（静止）"
    case netflix = "奈飞配方原样"
    case off = "关（只有系统玻璃）"
    var id: String { rawValue }
    static let key = "hg.rim.style.v1"
}

/// 奈飞 border-highlight / -dim / -subtle 三档
enum HGRimStrength: String, CaseIterable, Identifiable {
    case highlight = "强", dim = "中", subtle = "弱"
    var id: String { rawValue }
    var factor: Double { switch self { case .highlight: 1; case .dim: 0.6; case .subtle: 0.35 } }
    static let key = "hg.rim.strength.v1"
}

/// 正在播的画面（48px 宽、已模糊），给光圈取色。DYAmbientFrameView 取帧时顺手发布。
@MainActor @Observable final class HGRimLight {
    static let shared = HGRimLight()
    private(set) var frame: CGImage?
    @ObservationIgnored private var viewers = 0
    /// 有环境光光圈在屏幕上：画面铺满时也照样取帧
    var wanted: Bool { viewers > 0 }
    func attach() { viewers += 1 }
    func detach() { viewers = max(0, viewers - 1) }
    func publish(_ cg: CGImage) { frame = cg }
}

/// 视频上的玻璃控件：系统玻璃 + 光圈（ddMediaGlassCapsule / ddMediaGlassCircle 用它）
struct HGMediaGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color? = nil
    @AppStorage(HGRimStyle.key) private var styleRaw = HGRimStyle.ambientSweep.rawValue
    @AppStorage(HGRimStrength.key) private var strengthRaw = HGRimStrength.highlight.rawValue

    func body(content: Content) -> some View {
        let style = HGRimStyle(rawValue: styleRaw) ?? .ambientSweep
        let k = (HGRimStrength(rawValue: strengthRaw) ?? .highlight).factor
        glass(content.foregroundStyle(.primary), style: style)
            .overlay { HGRimRing(shape: shape, style: style, k: k) }
            // 奈飞配方：外圈白色柔光
            .shadow(color: style == .netflix ? .white.opacity(0.25 * k) : .clear, radius: 6)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private func glass(_ v: some View, style: HGRimStyle) -> some View {
        if #available(iOS 26.0, *) {
            let base: Glass = tint.map { .regular.tint($0.opacity(0.22)) }
                ?? (style == .netflix ? .regular.tint(.white.opacity(0.1)) : .regular)
            v.glassEffect(base.interactive(), in: shape)
        } else {
            v.background(tint.map { $0.opacity(0.22) } ?? .clear, in: shape)
                .background(.ultraThinMaterial, in: shape)
        }
    }
}

private struct HGRimRing<S: InsettableShape>: View {
    let shape: S
    let style: HGRimStyle
    let k: Double

    var body: some View {
        Group {
            switch style {
            case .off:
                EmptyView()
            case .netflix:
                // 奈飞配方原样：白色锥形渐变描边，3 秒转一圈，screen 混合
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                    shape.strokeBorder(AngularGradient(gradient: HGRimStops.sweep(k), center: .center,
                                                       angle: HGRimStops.angle(ctx.date, period: 3)), lineWidth: 1.5)
                        .blendMode(.screen)
                }
            case .ambient, .ambientSweep:
                HGAmbientRing(shape: shape, sweep: style == .ambientSweep, k: k)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum HGRimStops {
    static func sweep(_ k: Double) -> Gradient {
        Gradient(stops: [
            .init(color: .white.opacity(0.9 * k), location: 0.0),
            .init(color: .clear, location: 0.25),
            .init(color: .white.opacity(0.5 * k), location: 0.5),
            .init(color: .clear, location: 0.75),
            .init(color: .white.opacity(0.9 * k), location: 1.0),
        ])
    }
    static func angle(_ d: Date, period: Double) -> Angle {
        .degrees((d.timeIntervalSinceReferenceDate / period).truncatingRemainder(dividingBy: 1) * 360)
    }
}

/// 环境光光圈：把背后正在播的画面（模糊小图）按胶囊在屏幕上的位置对齐，只露胶囊外沿一圈，提亮后叠加发光。
/// 画面亮 → 光圈亮；画面什么颜色 → 光圈什么颜色；视频一动，光圈跟着变。
private struct HGAmbientRing<S: InsettableShape>: View {
    let shape: S
    let sweep: Bool
    let k: Double
    @State private var light = HGRimLight.shared

    var body: some View {
        ZStack {
            if sweep {
                // 扫光：环境光那圈再乘一条转动的锥形渐变（奈飞的流动感），4 秒一圈
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                    ambient(AngularGradient(gradient: HGRimStops.sweep(1), center: .center,
                                            angle: HGRimStops.angle(ctx.date, period: 4)))
                }
            } else {
                ambient(Color.white)
            }
            // 镜面：左上一段静止亮边（玻璃受光）；画面全黑时光圈也不至于完全消失
            shape.strokeBorder(LinearGradient(stops: [
                .init(color: .white.opacity(0.45 * k), location: 0),
                .init(color: .white.opacity(0), location: 0.35),
                .init(color: .white.opacity(0), location: 0.8),
                .init(color: .white.opacity(0.18 * k), location: 1),
            ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
            .blendMode(.plusLighter)
        }
        .onAppear { light.attach() }
        .onDisappear { light.detach() }
    }

    @ViewBuilder private func ambient(_ mask: some ShapeStyle) -> some View {
        if let cg = light.frame {
            GeometryReader { g in
                let f = g.frame(in: .global)
                let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.bounds.size ?? g.size
                let picture = backdrop(cg, screen: screen, origin: f.origin, size: g.size)
                ZStack {
                    // 外溢：宽一圈、糊开（环境光往外晕）
                    picture.mask(shape.strokeBorder(mask, lineWidth: 5).blur(radius: 3))
                        .opacity(0.55 * k)
                    // 光圈本体：2pt
                    picture.mask(shape.strokeBorder(mask, lineWidth: 2))
                        .opacity(k)
                }
                .blendMode(.plusLighter)
            }
        }
    }

    /// 背后画面：按 aspectFill 铺满屏幕（同环境光背景），平移到跟胶囊对齐，裁到胶囊大小
    private func backdrop(_ cg: CGImage, screen: CGSize, origin: CGPoint, size: CGSize) -> some View {
        let a = CGFloat(cg.width) / CGFloat(max(cg.height, 1))
        let fill = screen.width / max(screen.height, 1) > a
            ? CGSize(width: screen.width, height: screen.width / a)
            : CGSize(width: screen.height * a, height: screen.height)
        return Image(decorative: cg, scale: 1)
            .resizable()
            .interpolation(.medium)
            .frame(width: fill.width, height: fill.height)
            .position(x: screen.width / 2 - origin.x, y: screen.height / 2 - origin.y)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
            // 提亮 + 加饱和：光圈是「光」，比背后画面亮、颜色更纯
            .brightness(0.22)
            .saturation(1.6)
    }
}
