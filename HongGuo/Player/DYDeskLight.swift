import SwiftUI
import UIKit

/// 桌面投光：竖屏半折叠（桌面姿态）时，上半屏视频像一块立着的屏幕，
/// 把画面的光投到下半屏评论区这张「桌面」上。
/// - 光源复用环境光取帧（DYAmbientFrameView，48px 宽、已模糊），不另挂播放器输出。
/// - 2026-11-19 老板给了奈飞实拍照：倒影同宽、翻转、只占视频高度、很暗、半糊（见下面 DYDeskLight 注释）。
/// - 直接把帧推给投光视图，不经过 SwiftUI 状态（12 帧/秒的值挂到视图树上会让整页反复重算）。
@MainActor
enum DYDeskLightHub {
    private static let sinks = NSHashTable<DYDeskLightView>.weakObjects()
    /// 有投光视图在屏幕上时，环境光即使被铺满的画面盖住也继续取帧
    static var wanted: Bool { sinks.allObjects.contains { $0.window != nil } }
    static func add(_ v: DYDeskLightView) { sinks.add(v) }
    static func remove(_ v: DYDeskLightView) { sinks.remove(v) }
    /// image = 倒影（半糊），glow = 环境光（极糊的小图）
    static func publish(_ image: CGImage, glow: CGImage?) {
        for v in sinks.allObjects where v.window != nil { v.show(image, glow: glow) }
    }
}

struct DYDeskLight: UIViewRepresentable {
    /// 折痕带下沿（倒影从这里往下排）
    var top: CGFloat = 0
    /// 上半屏视频窗格高度，用来算画面实际显示宽度（竖片按高度适配时倒影要同宽）
    var videoHeight: CGFloat = 0
    func makeUIView(context: Context) -> DYDeskLightView { DYDeskLightView() }
    func updateUIView(_ v: DYDeskLightView, context: Context) {
        v.topInset = top; v.videoHeight = videoHeight
    }
}

/// 照奈飞半折叠实拍（老板 2026-11-19 照片）做的「桌面倒影」：
/// - 和上方视频同宽、同比例，左右位置一一对应（不拉伸铺满）；
/// - 上下翻转，只占视频那么高，下面留黑；
/// - 很暗、起点离折痕一小段、先淡入再淡出；
/// - 糊：只剩色块和大轮廓（老板反馈 150px+σ1.6 太清楚太亮 → 72px+σ2.4，峰值 0.3）；
/// - 底下垫一层环境光：同画面缩到 16px 重度模糊，比视频宽 1.5 倍、铺满下半屏后淡出，像屏幕的光洒在桌面上。
final class DYDeskLightView: UIView {
    var topInset: CGFloat = 0 { didSet { if topInset != oldValue { setNeedsLayout() } } }
    var videoHeight: CGFloat = 0 { didSet { if videoHeight != oldValue { setNeedsLayout() } } }
    private let glowView = UIImageView()
    private let glowMask = CAGradientLayer()
    private let box = UIView()
    private let imageView = UIImageView()
    private let falloff = CAGradientLayer()
    private var aspect: CGFloat = 16.0 / 9.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = true
        alpha = 0
        // 环境光：同一画面缩到很小、重度模糊，翻转后向两侧和下方铺开，只留颜色氛围
        glowView.contentMode = .scaleToFill
        glowView.layer.magnificationFilter = .linear
        glowView.alpha = 0.32
        glowMask.startPoint = CGPoint(x: 0.5, y: 0)
        glowMask.endPoint = CGPoint(x: 0.5, y: 1)
        glowMask.colors = [UIColor(white: 1, alpha: 0.9).cgColor,
                           UIColor(white: 1, alpha: 0.45).cgColor,
                           UIColor(white: 1, alpha: 0).cgColor]
        glowMask.locations = [0, 0.45, 1]
        glowView.layer.mask = glowMask
        addSubview(glowView)
        box.clipsToBounds = true
        imageView.contentMode = .scaleToFill
        imageView.layer.magnificationFilter = .linear
        imageView.transform = CGAffineTransform(scaleX: 1, y: -1)
        box.addSubview(imageView)
        addSubview(box)
        // 竖向：折痕处先淡入（~12%），峰值约 0.5，之后一路淡出到全黑
        falloff.startPoint = CGPoint(x: 0.5, y: 0)
        falloff.endPoint = CGPoint(x: 0.5, y: 1)
        falloff.colors = [UIColor(white: 1, alpha: 0).cgColor,
                          UIColor(white: 1, alpha: 0.3).cgColor,
                          UIColor(white: 1, alpha: 0.16).cgColor,
                          UIColor(white: 1, alpha: 0).cgColor]
        falloff.locations = [0, 0.14, 0.55, 1]
        box.layer.mask = falloff
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 画面在上半屏里的实际显示宽度：横片适配宽度，竖片按窗格高度适配
        var w = bounds.width
        if videoHeight > 1, aspect > 0 { w = min(w, videoHeight * aspect) }
        let h = w / max(aspect, 0.1)
        box.frame = CGRect(x: (bounds.width - w) / 2, y: topInset + 6, width: w, height: h)
        // 环境光比倒影宽一圈（溢出屏幕两侧），往下铺满整块下半屏后淡出
        let gw = max(bounds.width, w) * 1.5
        glowView.transform = .identity
        glowView.frame = CGRect(x: (bounds.width - gw) / 2, y: topInset, width: gw, height: max(1, bounds.height - topInset))
        glowView.transform = CGAffineTransform(scaleX: 1, y: -1)
        glowMask.frame = glowView.bounds
        imageView.transform = .identity
        imageView.frame = box.bounds
        imageView.transform = CGAffineTransform(scaleX: 1, y: -1)
        falloff.frame = box.bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { DYDeskLightHub.add(self) } else { DYDeskLightHub.remove(self); alpha = 0 }
    }

    func show(_ image: CGImage, glow: CGImage?) {
        if let glow { glowView.image = UIImage(cgImage: glow) }
        let a = CGFloat(image.width) / CGFloat(max(image.height, 1))
        if abs(a - aspect) > 0.01 { aspect = a; setNeedsLayout() }
        imageView.image = UIImage(cgImage: image)
        if alpha == 0 { UIView.animate(withDuration: 0.35) { self.alpha = 1 } }
    }
}

extension View {
    /// 桌面姿态下给评论区加投光；其他姿态原样返回
    @ViewBuilder
    func dyDeskLight(_ on: Bool) -> some View {
        if on {
            overlay {
                DYDeskLight()
                    .blendMode(.screen)
                    .opacity(0.8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("douyin.comments.deskLight")
            }
        } else {
            self
        }
    }
}
