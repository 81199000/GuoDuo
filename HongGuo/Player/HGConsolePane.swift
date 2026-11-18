import SwiftUI

/// 竖屏半折叠（桌面姿态）下半屏：全黑操作台。
/// - 整块是触控板：左右滑 = 快进快退（滑满一屏宽 ≈ 整集 90%，同视频上的横滑手感），单击 = 播放 / 暂停
/// - 弹幕整块铺开在这里飞（视频上不再挡画面）
/// - 拖动时大号预览图 + 时间显示在操作台中央
/// - 右下角液态玻璃按钮：开关「金光投影」（视频画面投到台面上的倒影环境光，DouDuo dyDeskLight）
struct HGConsolePane: View {
    let session: HGPlaybackSession
    @Binding var deskLight: Bool
    var danmakuOn: Bool
    var bottomInset: CGFloat

    @State private var seeking = false
    @State private var anchor: Double = 0
    @State private var target: Double = 0
    @State private var dragStartX: CGFloat?

    var body: some View {
        GeometryReader { g in
            ZStack {
                Color.black
                if deskLight {
                    DYDeskLight()
                        .blendMode(.screen)
                        .opacity(0.8)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("hg.console.deskLight")
                }
                if danmakuOn && !seeking {
                    HGConsoleDanmaku(items: session.danmaku, clock: session.clock)
                        .accessibilityElement()
                        .accessibilityIdentifier("hg.console.danmaku")
                        .accessibilityValue("\(session.danmaku.count)")
                }
                if seeking { preview(in: g.size) } else { idleHint }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 8)
                .onChanged { v in
                    if !seeking {
                        seeking = true; anchor = session.position; target = anchor
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    let d = session.duration
                    guard d > 0 else { return }
                    target = max(0, min(d, anchor + Double(v.translation.width / max(g.size.width, 1)) * d * 0.9))
                    session.requestPreview(target)
                }
                .onEnded { _ in
                    if seeking { session.seek(to: target); session.endPreview() }
                    seeking = false
                })
            .simultaneousGesture(TapGesture().onEnded { if !seeking { session.togglePlay() } })
            .overlay(alignment: .bottomTrailing) { lightButton.padding(.trailing, 16).padding(.bottom, max(bottomInset, 16)) }
            .overlay(alignment: .bottomLeading) { progress.padding(.leading, 16).padding(.trailing, 84).padding(.bottom, max(bottomInset, 16) + 18) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hg.console")
        .accessibilityValue("pos=\(Int(session.position))")
    }

    private var idleHint: some View {
        VStack(spacing: 6) {
            Image(systemName: session.isPlaying ? "hand.draw" : "play.fill")
                .font(.system(size: 22, weight: .regular, design: .rounded))
            Text(session.isPlaying ? "左右滑动快进快退 · 轻点暂停" : "轻点继续播放").font(.caption)
        }
        .foregroundStyle(.white.opacity(0.4))
        .allowsHitTesting(false)
    }

    /// 大号预览：竖屏片源时图在左、时间在右（高度吃满操作台 82%）；横屏片源时图在上、时间在下
    private func preview(in size: CGSize) -> some View {
        let vertical = session.videoAspect < 1
        let aspect = max(0.4, min(2.4, session.videoAspect))
        let imgH = vertical ? size.height * 0.82 : min(size.height * 0.66, size.width * 0.8 / aspect)
        let imgW = imgH * aspect
        let delta = target - session.position
        let image = Group {
            if let img = session.seekPreviewImage {
                Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.06).overlay(ProgressView().tint(.white))
            }
        }
        .frame(width: imgW, height: imgH)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
        .accessibilityIdentifier("hg.console.preview")
        let time = VStack(alignment: vertical ? .leading : .center, spacing: 6) {
            Text(fmt(target)).font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
            Text("/ " + fmt(session.duration)).font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.55))
            Text((delta >= 0 ? "快进 " : "快退 ") + String(format: "%.0f 秒", abs(delta)))
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
        }
        .foregroundStyle(.white)
        return Group {
            if vertical { HStack(spacing: 22) { image; time } }
            else { VStack(spacing: 10) { image; time } }
        }
        .allowsHitTesting(false)
    }

    private var progress: some View {
        GeometryReader { g in
            let pos = seeking ? target : session.position
            let frac = session.duration > 0 ? min(1, max(0, pos / session.duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(.white.opacity(0.85)).frame(width: g.size.width * frac)
            }
            .frame(height: seeking ? 5 : 3)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 12)
        .allowsHitTesting(false)
    }

    /// 液态玻璃圆（DouDuo ddMediaGlassCircle，开着时带暖金色调）
    private var lightButton: some View {
        Button { withAnimation(.easeOut(duration: 0.3)) { deskLight.toggle() } } label: {
            Image(systemName: deskLight ? "light.max" : "light.min")
                .font(.system(size: 21, weight: .regular, design: .rounded))
                .foregroundStyle(deskLight ? Color(red: 1, green: 0.82, blue: 0.45) : .white)
                .frame(width: 50, height: 50)
                .contentShape(Circle())
                .ddMediaGlassCircle(deskLight ? Color(red: 1, green: 0.78, blue: 0.3) : nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(deskLight ? "关闭金光投影" : "打开金光投影")
        .accessibilityIdentifier("hg.console.light")
        .accessibilityValue(deskLight ? "on" : "off")
    }

    private func fmt(_ t: Double) -> String {
        guard t.isFinite else { return "0:00" }
        let s = Int(t); return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// 操作台弹幕：DouDuo 弹幕引擎，区域铺满整块操作台（上下各留一点边），轨道数按高度算、上限 8 条。
private struct HGConsoleDanmaku: View {
    let items: [DYDanmaku]
    let clock: DYDanmakuClock
    @AppStorage(DYDanmakuPolicy.deduplicateKey) private var deduplicate = true
    var body: some View {
        GeometryReader { g in
            let top: CGFloat = 16
            let height = max(0, g.size.height - 90 - top)
            let lanes = min(8, Int(height / DYDanmakuStyle.laneHeight))
            DYDanmakuLiveSurface(items: items, clock: clock, regionTop: top, regionHeight: height,
                                 lanes: lanes, density: .dense, deduplicate: deduplicate)
                .frame(width: g.size.width, height: g.size.height)
        }
        .allowsHitTesting(false)
    }
}
