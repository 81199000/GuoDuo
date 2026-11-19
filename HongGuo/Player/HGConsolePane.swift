import SwiftUI
import MediaPlayer
import Photos
import AVFoundation
import AVKit

/// 竖屏半折叠（桌面姿态）下半屏：触控操作台。照老板给的参考图做三态：
/// - 平时：全黑 + 环境光投影 + 四角取景框，整块是触控板（左右滑快进退，轻点呼出控制）
/// - 控制：返回 / 音量 / 亮度 / 锁定 / 截图；-10 · 播放 · +10，两侧长按 2× 快进；
///         下一集 + 进度条（弹幕热度点）；弹 / 环境光 / 倍速 / 选集 / 更多。4 秒无操作自动收起
/// - 拖动：中间大预览 + 时间 + 集数，进度条跟手
struct HGConsolePane: View {
    let session: HGPlaybackSession
    @Binding var deskLight: Bool
    @Binding var controlsShown: Bool
    @Binding var danmakuOn: Bool
    @Binding var danmakuInConsole: Bool
    /// 折痕带落在本面板顶部的那一截，内容从它下面开始
    var creaseTop: CGFloat
    var bottomInset: CGFloat
    var onBack: () -> Void
    var onEpisodes: () -> Void
    var onMore: () -> Void
    var flash: (String) -> Void
    /// 触控板上下滑：上滑下一部 / 下一集，下滑上一部 / 上一集
    var onNext: () -> Void = {}
    var onPrevious: () -> Void = {}

    @State private var seeking = false
    @State private var anchor: Double = 0
    @State private var target: Double = 0
    @State private var locked = false
    @State private var lockHint = false
    @State private var popover: Popover?
    @State private var hideTask: Task<Void, Never>?
    @State private var lockHintTask: Task<Void, Never>?
    @State private var volume: Float = 0.5
    @State private var brightness: CGFloat = 0.5
    /// 触控板长按 2×：按住期间 true（GestureState，松手 / 被系统取消都会复位，不会卡在加速）
    @GestureState private var padHolding = false
    @State private var padBoostOn = false
    @State private var padLockDone = false
    @State private var lastBoostEnd = Date.distantPast
    /// 一次拖动只认一个方向：横 = 快进退，竖 = 切视频
    @State private var dragAxis: Axis?
    enum Popover { case danmaku, rate }

    private static let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0, 3.0]
    private let side: CGFloat = 16
    private var bottomPad: CGFloat { max(bottomInset, 12) }

    var body: some View {
        GeometryReader { g in
            ZStack {
                background
                if danmakuOn && danmakuInConsole && !seeking && !controlsShown && !locked {
                    HGConsoleDanmaku(items: session.danmaku, clock: session.clock, top: creaseTop + 8)
                        .accessibilityElement()
                        .accessibilityIdentifier("hg.console.danmaku")
                        .accessibilityValue("\(session.danmaku.count)")
                }
                pad(g.size)
                if locked {
                    lockedLayer
                } else if seeking {
                    seekLayer(g.size)
                } else if controlsShown {
                    controlsLayer.transition(.opacity)
                } else {
                    HGCornerBrackets()
                        .padding(.horizontal, 20)
                        .padding(.top, creaseTop + 18)
                        .padding(.bottom, bottomPad + 10)
                        .allowsHitTesting(false)
                }
                HGVolumeHost().frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.2), value: controlsShown)
            .animation(.easeOut(duration: 0.15), value: seeking)
        }
        .onAppear {
            volume = AVAudioSession.sharedInstance().outputVolume
            brightness = HGScreenBrightness.value
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            // 物理音量键改了也跟上（KVO 在 SwiftUI 里不好挂，1 秒轮询足够）
            guard controlsShown else { return }
            let v = AVAudioSession.sharedInstance().outputVolume
            if abs(v - volume) > 0.01 { volume = v }
        }
        .onChange(of: controlsShown) { _, on in if on { poke() } else { popover = nil } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hg.console")
        .accessibilityValue(locked ? "locked" : controlsShown ? "controls" : seeking ? "seeking" : "idle")
    }

    // MARK: 背景：黑底 + 环境光投影（画面颜色从折痕倒影下来）

    private var background: some View {
        ZStack {
            Color.black
            if deskLight {
                DYDeskLight().blendMode(.screen).opacity(0.9)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: 触控板

    private func pad(_ size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 10)
                .onChanged { v in
                    guard !locked, !padHolding, !padBoostOn else { return }
                    if dragAxis == nil {
                        dragAxis = abs(v.translation.width) > abs(v.translation.height) ? .horizontal : .vertical
                    }
                    guard dragAxis == .horizontal else { return }
                    if !seeking { beginSeek() }
                    let d = session.duration
                    guard d > 0 else { return }
                    target = max(0, min(d, anchor + Double(v.translation.width / max(size.width, 1)) * d * 0.9))
                    session.requestPreview(target)
                }
                .onEnded { v in
                    defer { dragAxis = nil }
                    // 长按加速 / 锁定手势里的滑动，松手不再当成快进或翻页
                    if padBoostOn || padHolding || Date().timeIntervalSince(lastBoostEnd) < 0.5 { return }
                    guard !locked else { return }
                    if dragAxis == .vertical {
                        // DouDuo 竖滑翻页的手感：位移 60pt 或甩出去（预测 180pt）就翻
                        let dy = v.translation.height, p = v.predictedEndTranslation.height
                        if dy < -60 || p < -180 { UIImpactFeedbackGenerator(style: .light).impactOccurred(); onNext() }
                        else if dy > 60 || p > 180 { UIImpactFeedbackGenerator(style: .light).impactOccurred(); onPrevious() }
                        return
                    }
                    endSeek()
                })
            // 长按 2× 倍速（DouDuo 同款）：按住期间 2×，按住后手指下滑一段 = 锁定 2×，上滑一段 = 解锁
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.3)
                .sequenced(before: DragGesture(minimumDistance: 0))
                .updating($padHolding) { value, state, _ in
                    if case .second(true, _) = value { state = true }
                }
                .onChanged { value in
                    guard case .second(true, let drag?) = value, padBoostOn, !padLockDone else { return }
                    let dy = drag.translation.height
                    guard abs(dy) > 50 else { return }
                    padLockDone = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if dy > 0 { session.lockBoost() } else { session.unlockBoost() }
                })
            .onChange(of: padHolding) { _, on in
                if on {
                    guard !locked, !seeking else { return }
                    padBoostOn = true; padLockDone = false
                    hideTask?.cancel()
                    session.setBoost(true)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } else if padBoostOn {
                    padBoostOn = false
                    lastBoostEnd = Date()
                    session.setBoost(false)
                    if controlsShown { poke() }
                }
            }
            .simultaneousGesture(TapGesture().onEnded {
                // 长按松手后系统会补一个单击，吞掉
                if padBoostOn || Date().timeIntervalSince(lastBoostEnd) < 0.8 { return }
                if locked { showLockHint(); return }
                guard !seeking else { return }
                if popover != nil { popover = nil; poke(); return }
                controlsShown.toggle()
            })
            .accessibilityIdentifier("hg.console.pad")
            .accessibilityLabel("sid=\(session.series.series_id) ep=\(session.episode.number)")
            .accessibilityValue("\(Int(session.position))")
    }

    private func beginSeek() {
        seeking = true; anchor = session.position; target = anchor; popover = nil
        hideTask?.cancel()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func endSeek() {
        if seeking { session.seek(to: target); session.endPreview() }
        seeking = false
        if controlsShown { poke() }
    }

    /// 有操作就重新计时，4 秒没动收起控制
    private func poke() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !seeking, popover == nil, !padBoostOn else { return }
            controlsShown = false
        }
    }

    // MARK: 控制层

    /// 控制层照老板 2026-11-19 的参考图排：
    /// 顶排（返回 · 剧名 + 第几集 | 时长 · AirPlay · 锁定 · 截图）→ 音量 | 亮度合并一块 →
    /// 上集 · -10 · 播放 · +10 · 下集 → 时间 + 进度条 + 总时长 → 弹 / 环境光 / 倍速 / 选集 / 更多（竖线隔开）。
    /// 多出来的高度按比例分给各段间距。
    private var controlsLayer: some View {
        GeometryReader { g in
            let fixed: CGFloat = 10 + 40 + 46 + 28 + 40
            let avail = max(0, g.size.height - creaseTop - bottomPad - fixed)
            let middleH = min(110, max(72, avail * 0.42))
            let rest = max(0, avail - middleH)
            VStack(spacing: 0) {
                Color.clear.frame(height: creaseTop + 10)
                topRow
                Color.clear.frame(height: rest * 0.2)
                sliderCard
                Color.clear.frame(height: rest * 0.3)
                middleRow(height: middleH)
                Color.clear.frame(height: rest * 0.25)
                progressRow
                Color.clear.frame(height: rest * 0.25)
                bottomRow
            }
            .padding(.horizontal, side)
            .padding(.bottom, bottomPad)
            .frame(width: g.size.width, height: g.size.height, alignment: .top)
            .overlay(alignment: .top) {
                Capsule().fill(.white.opacity(0.28)).frame(width: 38, height: 4)
                    .padding(.top, creaseTop + 5).allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottom) { popoverView.padding(.bottom, bottomPad + 48) }
    }

    private var topRow: some View {
        HStack(spacing: 10) {
            circleButton("chevron.backward", id: "hg.player.close", label: "返回") { onBack() }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.series.series_title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("第\(session.episode.number)集" + (session.duration > 0 ? " | \(Int((session.duration / 60).rounded(.up)))分钟" : ""))
                    .font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("hg.console.panelTitle")
            HGAirPlayButton()
                .frame(width: 40, height: 40)
                .ddMediaGlassCircle()
                .accessibilityLabel("投屏")
                .accessibilityIdentifier("hg.console.airplay")
            circleButton("lock.open", id: "hg.console.lock", label: "锁定") {
                locked = true; controlsShown = false
                flash("已锁定，轻点下半屏显示解锁")
            }
            circleButton("camera", id: "hg.console.shot", label: "截图") { takeShot() }
        }
        .frame(height: 40)
    }

    /// 音量 | 亮度：一块圆角底板，中间一条竖线隔开
    private var sliderCard: some View {
        HStack(spacing: 8) {
            HGCapsuleSlider(icon: volume <= 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            value: Double(volume)) { v in
                volume = Float(v); HGSystemVolume.set(Float(v)); poke()
            }
            .accessibilityIdentifier("hg.console.volume")
            Rectangle().fill(.white.opacity(0.16)).frame(width: 1, height: 22)
            HGCapsuleSlider(icon: "sun.max.fill", value: Double(brightness)) { v in
                brightness = CGFloat(v); HGScreenBrightness.set(CGFloat(v)); poke()
            }
            .accessibilityIdentifier("hg.console.brightness")
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .frame(height: 46)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 23, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private func middleRow(height: CGFloat) -> some View {
        // 五个键靠拢放大（2026-11-19 老板要求）：固定小间距居中排；窄屏按可用宽度等比缩小
        let gap: CGFloat = 10, tileW: CGFloat = 66, tileH: CGFloat = 60, small: CGFloat = 62
        let big = min(max(height, 64), 84)
        let natural = tileW * 2 + small * 2 + big + gap * 4
        return GeometryReader { g in
            let k = min(1, g.size.width / natural)
            HStack(spacing: gap) {
                stepTile("backward.end.fill", label: "上集", enabled: session.index > 0, id: "hg.console.prev", w: tileW, h: tileH) {
                    session.previous(); poke()
                }
                roundButton("gobackward.10", size: small, glyph: 26, id: "hg.console.back10") {
                    session.seek(to: max(0, session.position - 10)); poke()
                }
                roundButton(session.isPlaying ? "pause.fill" : "play.fill", size: big, glyph: big * 0.4, id: "hg.console.play") {
                    session.togglePlay(); poke()
                }
                .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1.5).padding(-4))
                roundButton("goforward.10", size: small, glyph: 26, id: "hg.console.fwd10") {
                    session.seek(to: min(session.duration, session.position + 10)); poke()
                }
                stepTile("forward.end.fill", label: "下集", enabled: session.hasNext, id: "hg.console.next", w: tileW, h: tileH) {
                    session.next(); poke()
                }
            }
            .scaleEffect(k)
            .frame(width: g.size.width, height: g.size.height)
        }
        .frame(height: height)
    }

    /// 上集 / 下集：圆角方块，图标在上、字在下
    private func stepTile(_ icon: String, label: String, enabled: Bool, id: String, w: CGFloat, h: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 19, weight: .bold))
                Text(label).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white.opacity(enabled ? 1 : 0.3))
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .ddGlassRounded(16)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private var progressRow: some View {
        HStack(spacing: 10) {
            Text(fmt(seeking ? target : session.position)).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
            HGHeatBar(position: seeking ? target : session.position, duration: session.duration,
                      heat: HGHeat.peaks(session.danmaku, duration: session.duration),
                      active: seeking) { frac, phase in
                let d = session.duration
                guard d > 0 else { return }
                switch phase {
                case .began: beginSeek(); target = frac * d; session.requestPreview(target)
                case .changed: target = frac * d; session.requestPreview(target)
                case .ended: target = frac * d; endSeek()
                }
            }
            .accessibilityIdentifier("hg.console.bar")
            Text(fmt(session.duration)).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
        }
        .frame(height: 28)
    }

    private var bottomRow: some View {
        HStack(spacing: 0) {
            tile(id: "hg.console.danmakuButton", on: popover == .danmaku) {
                HStack(spacing: 1) {
                    Text("弹").font(.system(size: 17, weight: .semibold))
                    Image(systemName: danmakuOn ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(danmakuOn ? Color.green : .white.opacity(0.5))
                        .offset(y: 6)
                }
            } action: { popover = popover == .danmaku ? nil : .danmaku; poke() }
            tileDivider
            tile(id: "hg.console.ambient", on: deskLight) {
                iconLabel("airplayvideo", "环境光")
            } action: {
                withAnimation(.easeOut(duration: 0.3)) { deskLight.toggle() }
                flash(deskLight ? "环境光投影：开" : "环境光投影：关"); poke()
            }
            .accessibilityValue(deskLight ? "on" : "off")
            tileDivider
            tile(id: "hg.console.rate", on: popover == .rate) {
                iconLabel("play.circle", session.rate == 1 ? "倍速" : String(format: "%g×", session.rate))
            } action: { popover = popover == .rate ? nil : .rate; poke() }
            tileDivider
            tile(id: "hg.console.episodes") { iconLabel("list.bullet", "选集") } action: { onEpisodes() }
            tileDivider
            tile(id: "hg.console.more") { iconLabel("ellipsis", "更多") } action: { onMore() }
        }
        .frame(height: 40)
    }

    private var tileDivider: some View {
        Rectangle().fill(.white.opacity(0.16)).frame(width: 1, height: 20).padding(.horizontal, 3)
    }

    private func iconLabel(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
            Text(text).font(.footnote).lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    @ViewBuilder private var popoverView: some View {
        switch popover {
        case .danmaku:
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $danmakuOn) { Text("弹幕").font(.subheadline.weight(.semibold)).foregroundStyle(.white) }
                    .tint(.green)
                    .accessibilityIdentifier("hg.console.danmaku.toggle")
                Text("显示位置").font(.caption).foregroundStyle(.white.opacity(0.6))
                HStack(spacing: 8) {
                    choice("影片区", on: !danmakuInConsole, id: "hg.console.danmaku.video") { danmakuInConsole = false; poke() }
                    choice("触控区", on: danmakuInConsole, id: "hg.console.danmaku.console") { danmakuInConsole = true; poke() }
                }
                .disabled(!danmakuOn).opacity(danmakuOn ? 1 : 0.4)
            }
            .padding(14)
            .frame(width: 240)
            .ddGlassCard()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, side)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        case .rate:
            HStack(spacing: 6) {
                ForEach(Self.rates, id: \.self) { r in
                    choice(String(format: "%g×", r), on: r == session.rate, id: "hg.console.rate.\(r)") {
                        session.setRate(r); popover = nil; poke()
                    }
                }
            }
            .padding(10)
            .ddGlassCard()
            .padding(.horizontal, side)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        case nil:
            EmptyView()
        }
    }

    // MARK: 拖动层（参考图 1：预览居中、时间、集数，进度条跟手）

    private func seekLayer(_ size: CGSize) -> some View {
        let reserved: CGFloat = bottomPad + 40 + 10 + 28 + 14
        let area = max(80, size.height - creaseTop - 6 - reserved)
        let textH: CGFloat = 52
        let aspect = max(0.4, min(2.4, session.videoAspect))
        let imgH0 = max(40, area - textH - 8)
        let imgW = min(size.width - 2 * side, imgH0 * aspect)
        let imgH = imgW / aspect
        return VStack(spacing: 0) {
            Spacer(minLength: creaseTop + 6)
            VStack(spacing: 4) {
                Group {
                    if let img = session.seekPreviewImage {
                        Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.06).overlay(ProgressView().tint(.white))
                    }
                }
                .frame(width: imgW, height: imgH)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityIdentifier("hg.console.preview")
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(fmt(target)).font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    Text("/ " + fmt(session.duration)).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                }
                Text("第 \(session.episode.number) 集").font(.footnote).foregroundStyle(.white.opacity(0.85))
            }
            .foregroundStyle(.white)
            Spacer(minLength: 6)
            progressRow
            Spacer().frame(height: 10)
            Color.clear.frame(height: 40)
        }
        .padding(.horizontal, side)
        .padding(.bottom, bottomPad)
        .allowsHitTesting(false)
    }

    // MARK: 锁定层

    private var lockedLayer: some View {
        ZStack {
            if lockHint {
                Button {
                    locked = false; lockHint = false; controlsShown = true
                    flash("已解锁")
                } label: {
                    Label("解锁", systemImage: "lock.fill").font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .ddMediaGlassCapsule()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("hg.console.unlock")
                .transition(.opacity)
            }
        }
        .padding(.top, creaseTop)
        .animation(.easeOut(duration: 0.2), value: lockHint)
    }

    private func showLockHint() {
        lockHint = true
        lockHintTask?.cancel()
        lockHintTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            lockHint = false
        }
    }

    // MARK: 截图

    private func takeShot() {
        poke()
        Task { @MainActor in
            guard let img = await session.snapshot() else { flash("截图失败"); return }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { flash("没有相册写入权限"); return }
            do {
                try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: img) }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                flash("截图已存到相册")
            } catch { flash("截图保存失败") }
        }
    }

    // MARK: 零件

    private func circleButton(_ icon: String, id: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
                .ddMediaGlassCircle()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func roundButton(_ icon: String, size: CGFloat, glyph: CGFloat, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: glyph, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .contentShape(Circle())
                .ddMediaGlassCircle()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func tile<L: View>(id: String, on: Bool = false, @ViewBuilder label: () -> L, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .background(.white.opacity(on ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .ddGlassRounded(10)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func choice(_ title: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.footnote.weight(on ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(on ? .black : .white)
                .padding(.horizontal, 10).frame(minHeight: 32)
                .frame(maxWidth: .infinity)
                .background(on ? Color.white : Color.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityValue(on ? "on" : "off")
    }

    private func fmt(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "00:00" }
        let s = Int(t); return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - 进度条（带弹幕热度点）

enum HGHeat {
    /// 弹幕扎堆的时间点 = 高能点：40 段直方图里超过均值 1.8 倍的段，最多 6 个
    static func peaks(_ items: [DYDanmaku], duration: Double) -> [Double] {
        guard duration > 10, items.count >= 20 else { return [] }
        let bins = 40
        var c = [Int](repeating: 0, count: bins)
        for d in items {
            let i = min(bins - 1, max(0, Int(d.offset / duration * Double(bins))))
            c[i] += 1
        }
        let mean = Double(items.count) / Double(bins)
        return c.enumerated()
            .filter { Double($0.element) > mean * 1.8 }
            .sorted { $0.element > $1.element }
            .prefix(6)
            .map { (Double($0.offset) + 0.5) / Double(bins) }
    }
}

struct HGHeatBar: View {
    enum Phase { case began, changed, ended }
    let position: Double
    let duration: Double
    let heat: [Double]
    let active: Bool
    let scrub: (Double, Phase) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let frac = duration > 0 ? min(1, max(0, position / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2)).frame(height: 6)
                Capsule().fill(.white.opacity(0.9))
                    .frame(width: max(6, w * frac), height: 6)
                ForEach(heat, id: \.self) { h in
                    Circle().fill(.white.opacity(0.9)).frame(width: 5, height: 5)
                        .offset(x: w * h - 2.5)
                }
                Circle().fill(.white.opacity(0.85))
                    .frame(width: active ? 22 : 18, height: active ? 22 : 18)
                    .shadow(color: .black.opacity(0.3), radius: 3)
                    .offset(x: w * frac - (active ? 11 : 9))
            }
            .frame(height: g.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let f = min(1, max(0, v.location.x / max(w, 1)))
                    scrub(f, dragging ? .changed : .began); dragging = true
                }
                .onEnded { v in
                    scrub(min(1, max(0, v.location.x / max(w, 1))), .ended); dragging = false
                })
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityValue(String(format: "%.0f", position))
    }
}

// MARK: - 音量 / 亮度

/// 胶囊滑条（参考图：左侧图标，浅色填充表示当前值，整条可拖）
struct HGCapsuleSlider: View {
    let icon: String
    let value: Double
    let set: (Double) -> Void
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.08))
                Rectangle().fill(.white.opacity(0.42)).frame(width: g.size.width * min(1, max(0, value)))
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.leading, 14)
            }
            .clipShape(Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                set(min(1, max(0, v.location.x / max(g.size.width, 1))))
            })
        }
        .frame(height: 38)
        .accessibilityElement()
        .accessibilityValue(String(format: "%.2f", value))
    }
}

/// 系统音量：借 MPVolumeView 里的滑条设值（同时压掉系统音量 HUD）
@MainActor enum HGSystemVolume {
    static weak var view: MPVolumeView?
    static func set(_ v: Float) {
        guard let slider = view?.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.value = v
        slider.sendActions(for: .valueChanged)
    }
}

struct HGVolumeHost: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        v.alpha = 0.01
        HGSystemVolume.view = v
        return v
    }
    func updateUIView(_ v: MPVolumeView, context: Context) { HGSystemVolume.view = v }
}

@MainActor enum HGScreenBrightness {
    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
    }
    static var value: CGFloat { screen?.brightness ?? 0.5 }
    static func set(_ v: CGFloat) { screen?.brightness = v }
}

/// AirPlay 投屏按钮：系统 AVRoutePickerView（点开系统设备列表），白色图标
struct HGAirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = .systemGreen
        v.prioritizesVideoDevices = true
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}

// MARK: - 四角取景框

struct HGCornerBrackets: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height, l: CGFloat = 26, r: CGFloat = 8
            Path { p in
                p.move(to: CGPoint(x: 0, y: l)); p.addLine(to: CGPoint(x: 0, y: r))
                p.addQuadCurve(to: CGPoint(x: r, y: 0), control: .zero); p.addLine(to: CGPoint(x: l, y: 0))
                p.move(to: CGPoint(x: w - l, y: 0)); p.addLine(to: CGPoint(x: w - r, y: 0))
                p.addQuadCurve(to: CGPoint(x: w, y: r), control: CGPoint(x: w, y: 0)); p.addLine(to: CGPoint(x: w, y: l))
                p.move(to: CGPoint(x: 0, y: h - l)); p.addLine(to: CGPoint(x: 0, y: h - r))
                p.addQuadCurve(to: CGPoint(x: r, y: h), control: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: l, y: h))
                p.move(to: CGPoint(x: w - l, y: h)); p.addLine(to: CGPoint(x: w - r, y: h))
                p.addQuadCurve(to: CGPoint(x: w, y: h - r), control: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: w, y: h - l))
            }
            .stroke(.white.opacity(0.22), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .accessibilityIdentifier("hg.console.brackets")
    }
}

// MARK: - 玻璃小件

extension View {
    func ddGlassRounded(_ radius: CGFloat) -> some View { modifier(HGGlassRounded(radius: radius)) }
    func ddGlassCard() -> some View { modifier(HGGlassRounded(radius: 16)) }
}

private struct HGGlassRounded: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape).environment(\.colorScheme, .dark)
        } else {
            content.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 1))
                .environment(\.colorScheme, .dark)
        }
    }
}

/// 操作台弹幕：DouDuo 弹幕引擎，区域铺满整块操作台（折痕以下），轨道数按高度算、上限 8 条。
private struct HGConsoleDanmaku: View {
    let items: [DYDanmaku]
    let clock: DYDanmakuClock
    let top: CGFloat
    @AppStorage(DYDanmakuPolicy.deduplicateKey) private var deduplicate = true
    var body: some View {
        GeometryReader { g in
            let height = max(0, g.size.height - 40 - top)
            let lanes = min(8, Int(height / DYDanmakuStyle.laneHeight))
            DYDanmakuLiveSurface(items: items, clock: clock, regionTop: top, regionHeight: height,
                                 lanes: lanes, density: .dense, deduplicate: deduplicate)
                .frame(width: g.size.width, height: g.size.height)
        }
        .allowsHitTesting(false)
    }
}
