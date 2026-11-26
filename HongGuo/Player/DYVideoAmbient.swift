import SwiftUI
import AVFoundation
import CoreImage
import UIKit

/// 视频环境光：从正在播的 AVPlayerItem 取帧（AVPlayerItemVideoOutput），缩成 48px 宽、模糊后铺满背景再压暗。
/// 主色保持黑，颜色跟着画面实时变（TikTok 式）。替代原来的「模糊封面」静态背景。
/// 试过放弃的两条路（2026-11 Duo 真机实测）：
/// - 同一个 AVPlayer 再挂第二个 AVPlayerLayer：第二层一直不出帧（isReadyForDisplay=false）。
/// - 系统 UIBackgroundExtensionView：是把画面边缘镜像拉伸出去，出竖条色带，不是环境光。
enum DYVideoAmbient {
    static let key = "douyin_ambient_dim_v1"
    /// 0 = 关（退回模糊封面）；其余数值 = 压暗百分比
    static let levels = [0, 45, 60, 70, 80]
    static let defaultLevel = 60
    /// 和实时取帧同一套处理（缩成 48px 宽、模糊、降饱和）：给还没起播的页用首帧海报先做出一样的环境光
    static func image(from cg: CGImage) -> UIImage? {
        let src = CIImage(cgImage: cg)
        let scale = 48 / max(src.extent.width, 1)
        let small = src.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 3).cropped(to: small.extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.85])
        guard let out = CIContext(options: [.cacheIntermediates: false]).createCGImage(blurred, from: small.extent) else { return nil }
        return UIImage(cgImage: out)
    }
    static func title(_ v: Int) -> String {
        switch v { case 0: "关"; case 45: "亮"; case 60: "中"; case 70: "暗"; default: "很暗" }
    }
}

struct DYAmbientBackdrop: UIViewRepresentable {
    let player: AVPlayer
    /// 播放器建 item 时已挂好的取帧输出；本视图绝不再给 item 加/摘输出（会让播放管线重建）
    var output: AVPlayerItemVideoOutput?
    var active: Bool
    var dim: Double
    var fillWidth: Bool
    /// 起播前先显示的环境光（本集首帧海报做的）；没有就沿用上一集最后一帧
    var seed: UIImage? = nil
    func makeUIView(context: Context) -> DYAmbientFrameView { DYAmbientFrameView(player: player, seed: seed) }
    func updateUIView(_ v: DYAmbientFrameView, context: Context) {
        v.player = player
        v.output = output
        v.setSeed(seed)
        v.dim = dim
        v.fillWidth = fillWidth
        v.active = active
    }
}

final class DYAmbientFrameView: UIView {
    var player: AVPlayer
    /// 只有当前页取帧；预加载页、滑走的页停掉，不白耗电
    var active = false { didSet { if active != oldValue { updateLink() } } }
    var dim: Double = 0.45 { didSet { dimView.backgroundColor = UIColor.black.withAlphaComponent(dim) } }
    var fillWidth = true
    private let imageView = UIImageView()
    private let dimView = UIView()
    weak var output: AVPlayerItemVideoOutput?
    private var link: CADisplayLink?
    private static let ci = CIContext(options: [.cacheIntermediates: false])
    private static let queue = DispatchQueue(label: "guoduo.ambient", qos: .utility)
    /// 上一帧还没处理完就不取新帧（不堆积）
    private var working = false
    /// 最近一帧环境光（各页共用，新页先用它顶着）
    private static var lastImage: UIImage?
    /// 已经换成本集实时帧（之前显示的是海报做的 / 上一集的光，第一次换要渐变）
    private var live = false

    init(player: AVPlayer, seed: UIImage? = nil) {
        self.player = player
        super.init(frame: .zero)
        // 出第一帧之前透明，下面的模糊封面先顶着
        backgroundColor = .clear
        isUserInteractionEnabled = false
        clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.layer.magnificationFilter = .linear
        // 换集时这一页是新建的：先顶上一集最后一帧的环境光，不从全黑再淡入（上滑切集「两边先黑一下再亮」）
        if let last = seed ?? Self.lastImage {
            imageView.image = last
            imageView.alpha = 1
            dimView.alpha = 1
        } else {
            imageView.alpha = 0
            dimView.alpha = 0
        }
        dimView.backgroundColor = UIColor.black.withAlphaComponent(dim)
        addSubview(imageView)
        addSubview(dimView)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { link?.invalidate() }

    /// 预备页先用海报做的光；已经换成实时帧就不动
    func setSeed(_ seed: UIImage?) {
        guard let seed, !live, imageView.image !== seed else { return }
        imageView.image = seed
        imageView.alpha = 1; dimView.alpha = 1
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        dimView.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateLink()
    }

    private func updateLink() {
        // 发热（serious 及以上）停掉取帧：背景停在最后一帧（DouDuo 同款发热降载）
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        if active && window != nil && !hot {
            guard link == nil else { return }
            let l = CADisplayLink(target: DYAmbientTick(self), selector: #selector(DYAmbientTick.tick))
            // 背景光变化慢，6 帧足够（DouDuo 实测 12 帧占主线程约 1 成）
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 4, maximum: 8, preferred: 6)
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            link?.invalidate(); link = nil
        }
    }

    /// 铺满模式下画面盖住整页，没有地方露背景，不取帧
    private var covered: Bool {
        guard let s = player.currentItem?.presentationSize, s.width > 1, s.height > 1,
              bounds.width > 1, bounds.height > 1 else { return false }
        return DYVideoFit.presentation(fillWidth: fillWidth, videoAspect: s.width / s.height,
                                       screenAspect: bounds.width / bounds.height) == .aspectFill
    }

    fileprivate func tick() {
        // 画面铺满时背景看不见，但桌面姿态的评论区还在等投光，照样取帧
        guard !covered || DYDeskLightHub.wanted, let output, let item = player.currentItem, item.outputs.contains(output) else { return }
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard !working, output.hasNewPixelBuffer(forItemTime: t),
              let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return }
        // 缩图 + 模糊 + 生成图片放后台队列，主线程只换图（DouDuo 同款）
        working = true
        let desk = DYDeskLightHub.wanted
        Self.queue.async { [weak self] in
            let src = CIImage(cvPixelBuffer: pb)
            let scale = 48 / max(src.extent.width, 1)
            let small = src.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 3).cropped(to: small.extent)
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.85])
            let cg = Self.ci.createCGImage(blurred, from: small.extent)
            // 桌面投影（只有投影视图在屏幕上时才算）
            let proj = desk ? DYDeskProjection.render(src, ci: Self.ci) : nil
            let aspect = src.extent.width / max(src.extent.height, 1)
            DispatchQueue.main.async {
                guard let self else { return }
                self.working = false
                if let cg {
                    let img = UIImage(cgImage: cg)
                    // 新一集的第一帧：从上一集的光渐变过去，不硬切
                    if self.imageView.image != nil, !self.live, self.imageView.alpha == 1 {
                        UIView.transition(with: self.imageView, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                            self.imageView.image = img
                        }
                    } else {
                        self.imageView.image = img
                    }
                    Self.lastImage = img
                    self.live = true
                }
                if let proj { DYDeskLightHub.publish(proj.image, glow: proj.glow, aspect: aspect) }
                if self.imageView.alpha == 0, cg != nil {
                    UIView.animate(withDuration: 0.25) { self.imageView.alpha = 1; self.dimView.alpha = 1 }
                }
            }
        }
    }
}

private final class DYAmbientTick: NSObject {
    weak var view: DYAmbientFrameView?
    init(_ v: DYAmbientFrameView) { view = v }
    @objc func tick() { view?.tick() }
}

