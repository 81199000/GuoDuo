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
    static func publish(_ image: CGImage) {
        for v in sinks.allObjects where v.window != nil { v.show(image) }
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
/// - 很暗（整体约 25%）、起点离折痕一小段、先淡入再淡出；
/// - 半糊：能看出色块和轮廓，认不出五官。
final class DYDeskLightView: UIView {
    var topInset: CGFloat = 0 { didSet { if topInset != oldValue { setNeedsLayout() } } }
    var videoHeight: CGFloat = 0 { didSet { if videoHeight != oldValue { setNeedsLayout() } } }
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
                          UIColor(white: 1, alpha: 0.55).cgColor,
                          UIColor(white: 1, alpha: 0.32).cgColor,
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
        imageView.transform = .identity
        imageView.frame = box.bounds
        imageView.transform = CGAffineTransform(scaleX: 1, y: -1)
        falloff.frame = box.bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { DYDeskLightHub.add(self) } else { DYDeskLightHub.remove(self); alpha = 0 }
    }

    func show(_ image: CGImage) {
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
