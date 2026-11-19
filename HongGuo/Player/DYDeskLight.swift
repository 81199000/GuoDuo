import SwiftUI
import UIKit

/// 桌面投光：竖屏半折叠（桌面姿态）时，上半屏视频像一块立着的屏幕，
/// 把画面的光投到下半屏评论区这张「桌面」上。
/// - 光源复用环境光取帧（DYAmbientFrameView，48px 宽、已模糊），不另挂播放器输出。
/// - 2026-11-19 老板要求改成「真影片倒映」：清晰（360 宽、不糊）、整块下半屏铺满、竖向渐隐；靠近折痕的是视频底边，最亮。
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
    func makeUIView(context: Context) -> DYDeskLightView { DYDeskLightView() }
    func updateUIView(_ v: DYDeskLightView, context: Context) {}
}

final class DYDeskLightView: UIView {
    private let imageView = UIImageView()
    private let falloff = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = true
        alpha = 0
        // 真影片倒映：不糊，按下半屏整块铺满（aspectFill），上下翻转——视频底边贴着折痕
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.magnificationFilter = .linear
        imageView.transform = CGAffineTransform(scaleX: 1, y: -1)
        addSubview(imageView)
        // 竖向渐隐：折痕处最亮，往下逐渐暗，但整块下半屏都有画面（底部仍留约三成）
        falloff.startPoint = CGPoint(x: 0.5, y: 0)
        falloff.endPoint = CGPoint(x: 0.5, y: 1)
        falloff.colors = [UIColor(white: 1, alpha: 0.95).cgColor,
                          UIColor(white: 1, alpha: 0.6).cgColor,
                          UIColor(white: 1, alpha: 0.28).cgColor]
        falloff.locations = [0, 0.55, 1]
        layer.mask = falloff
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.transform = .identity
        imageView.frame = bounds
        imageView.transform = CGAffineTransform(scaleX: 1, y: -1)
        falloff.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { DYDeskLightHub.add(self) } else { DYDeskLightHub.remove(self); alpha = 0 }
    }

    func show(_ image: CGImage) {
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
