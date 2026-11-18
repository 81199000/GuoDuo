import SwiftUI
import AVKit

/// DouDuo 式竖滑短剧播放页：一集一页，上下滑切集；手势层原样用 DouDuo 的 PlayerGestureView。
struct HGPlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: HGPlaybackSession
    @State private var page: Int?
    @State private var library = HGLibrary.shared

    @AppStorage("hg.danmaku.on") private var danmakuOn = true
    @AppStorage("hg.fillWidth") private var fillWidth = true

    @State private var clean = false               // 清屏（全屏）：只留画面
    @State private var showComments = false
    @State private var showEpisodes = false
    @State private var showSpeed = false
    @State private var seeking = false
    @State private var seekPreview: Double = 0
    @State private var seekAnchor: Double = 0
    @State private var pinchScale: CGFloat = 1
    @State private var userScale: CGFloat = 1
    @State private var edgeOffset: CGFloat = 0
    @State private var toast: String?
    @State private var heartBurst = false
    @State private var landscape = false

    private static let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

    init(request: HGPlayerRequest) {
        _session = State(initialValue: HGPlaybackSession(request))
        _page = State(initialValue: request.index)
    }

    var body: some View {
        GeometryReader { geo in
          ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(session.episodes.enumerated()), id: \.element.id) { i, ep in
                        pageView(i, ep, size: geo.size)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .id(i)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)
            .scrollIndicators(.hidden)
            .scrollDisabled(seeking)
            .ignoresSafeArea()
            .background(Color.black)
            .offset(x: edgeOffset)
            .onChange(of: page) { _, p in if let p, p != session.index { session.go(to: p) } }
            .onChange(of: session.index) { _, i in if page != i { withAnimation(.easeInOut(duration: 0.3)) { page = i } } }
            // scrollPosition 的初值对 LazyVStack 不生效：首帧后显式滚到起始集
            .onAppear { proxy.scrollTo(session.index, anchor: .top); page = session.index }
          }
        }
        .ignoresSafeArea()
        .statusBarHidden(clean)
        .persistentSystemOverlays(clean ? .hidden : .automatic)
        .overlay(alignment: .top) { toastView }
        .sheet(isPresented: $showComments) {
            HGCommentSheet(series: session.series, episode: session.episode)
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showEpisodes) {
            HGEpisodeSheet(session: session) { showEpisodes = false }
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .confirmationDialog("倍速", isPresented: $showSpeed, titleVisibility: .visible) {
            ForEach(Self.rates, id: \.self) { r in
                Button(r == session.rate ? "✓ \(rateText(r))" : rateText(r)) { session.setRate(r) }
            }
        }
        .onAppear { session.start() }
        .onDisappear { session.stop(); setOrientation(landscape: false) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, !HGBackgroundPlayback.enabled, !session.pip.keepsPlaybackOnExit { session.player.pause() }
        }
    }

    // MARK: 一页

    @ViewBuilder
    private func pageView(_ i: Int, _ ep: HGEpisode, size: CGSize) -> some View {
        ZStack {
            Color.black
            if i == session.index {
                HGVideoLayer(player: session.player, fillWidth: fillWidth, pip: session.pip)
                    .scaleEffect(userScale * pinchScale)
                    .clipped()
                if danmakuOn && !clean {
                    DYDanmakuLayer(items: session.danmaku, clock: session.clock, topInset: safeTop)
                        .accessibilityElement()
                        .accessibilityIdentifier("hg.player.danmaku")
                        .accessibilityValue("\(session.danmaku.count)")
                }
                PlayerGestureView(
                    onSingleTap: { session.togglePlay() },
                    onDoubleTap: { _, _ in doubleTapLike() },
                    onLongPress: { pressing in session.setBoost(pressing) },
                    onLongPressLock: { session.lockBoost(); flash("已锁定 2× 倍速") },
                    onLongPressUnlock: { session.unlockBoost(); flash("已取消锁定") },
                    onSeekBegan: { seekAnchor = session.position; seekPreview = session.position; seeking = true },
                    onSeekChanged: { dx, w in seekPreview = max(0, min(session.duration, seekAnchor + dx / max(w, 1) * session.duration * 0.9)) },
                    onSeekEnded: { if seeking { session.seek(to: seekPreview); seeking = false } },
                    onEdgeChanged: { edgeOffset = $0 },
                    onEdgeEnded: { dx, v, w in
                        if dx > w * 0.3 || v > 800 { dismiss() } else { withAnimation(.spring(duration: 0.25)) { edgeOffset = 0 } }
                    },
                    verticalFirst: true,
                    onPinchBegan: {},
                    onPinchChanged: { pinchScale = $0 },
                    onPinchEnded: { s in
                        userScale = max(1, min(3, userScale * s)); pinchScale = 1
                        if userScale < 1.05 { withAnimation(.spring(duration: 0.25)) { userScale = 1 } }
                    },
                    onPinchCancelled: { pinchScale = 1 })
                    .accessibilityElement()
                    .accessibilityIdentifier("hg.player.surface")
                    .accessibilityValue(session.isPlaying && session.position > 0.5 && page == i ? "playing-\(ep.number)" : "idle")
                if heartBurst { Image(systemName: "heart.fill").font(.system(size: 96)).foregroundStyle(HGTheme.accent).transition(.scale.combined(with: .opacity)).allowsHitTesting(false) }
                if !session.isPlaying && session.status == nil && session.failed == nil && !seeking {
                    Image(systemName: "play.fill").font(.system(size: 54)).foregroundStyle(.white.opacity(0.75)).allowsHitTesting(false)
                }
                if session.boosting || session.lockedBoost { boostBadge }
                if seeking { seekOverlay }
                statusOverlay
                if !clean { chrome(ep) } else { exitCleanButton }
            } else {
                // 相邻页只显示封面占位，滑动时不黑屏
                HGCover(url: session.series.coverURL).blur(radius: 18).opacity(0.35).allowsHitTesting(false)
                Text("第 \(ep.number) 集").font(.headline).foregroundStyle(.white.opacity(0.7))
            }
        }
        .clipped()
    }

    // MARK: 叠加层

    private var safeTop: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.safeAreaInsets.top ?? 47
    }

    private func chrome(_ ep: HGEpisode) -> some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { dismiss() } label: { Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 36, height: 36) }
                        .accessibilityIdentifier("hg.player.close")
                    Spacer()
                    if let notice = session.danmakuNotice, danmakuOn {
                        Text(notice).font(.caption2).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 12).padding(.top, safeTop)
                Spacer()
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.series.series_title).font(.headline)
                    Text("第 \(ep.number) 集 / 共 \(session.episodes.count) 集").font(.subheadline).foregroundStyle(.white.opacity(0.75))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16).padding(.trailing, 84)
                progressBar.padding(.top, 10).padding(.bottom, 28)
            }
            rail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 10).padding(.bottom, 110)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 3)
    }

    private var rail: some View {
        VStack(spacing: 18) {
            let fav = library.isFavorite(session.series.id)
            railButton(fav ? "heart.fill" : "heart", fav ? "已收藏" : "收藏", tint: fav ? HGTheme.accent : .white, id: "hg.rail.favorite") {
                library.toggleFavorite(session.series)
            }
            if session.series.source == .hongguo {
                railButton("text.bubble.fill", "热评", id: "hg.rail.comments") { showComments = true }
            }
            railButton(danmakuOn ? "captions.bubble.fill" : "captions.bubble", danmakuOn ? "弹幕开" : "弹幕关", id: "hg.rail.danmaku") {
                danmakuOn.toggle()
            }
            railButton("list.number", "选集", id: "hg.rail.episodes") { showEpisodes = true }
            railButton("gauge.with.dots.needle.67percent", session.rate == 1 ? "倍速" : rateText(session.rate), id: "hg.rail.speed") { showSpeed = true }
            railButton(fillWidth ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", fillWidth ? "完整" : "铺满", id: "hg.rail.fill") {
                fillWidth.toggle(); userScale = 1
            }
            if session.videoAspect > 1.05 {
                railButton("rotate.right", landscape ? "竖屏" : "横屏", id: "hg.rail.rotate") { setOrientation(landscape: !landscape) }
            }
            railButton("arrow.up.left.and.arrow.down.right.rectangle", "全屏", id: "hg.rail.clean") {
                withAnimation(.easeOut(duration: 0.2)) { clean = true }
            }
            if session.pip.supported {
                railButton("pip.enter", "画中画", id: "hg.rail.pip") { session.pip.start() }
            }
        }
    }

    private func railButton(_ icon: String, _ label: String, tint: Color = .white, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 26, weight: .semibold)).foregroundStyle(tint).frame(height: 30)
                Text(label).font(.caption2.weight(.medium))
            }
            .frame(width: 60)
        }
        .accessibilityIdentifier(id)
    }

    private var progressBar: some View {
        GeometryReader { g in
            let pos = seeking ? seekPreview : session.position
            let frac = session.duration > 0 ? min(1, max(0, pos / session.duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: seeking ? 6 : 3)
                Capsule().fill(.white).frame(width: g.size.width * frac, height: seeking ? 6 : 3)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !seeking { seeking = true }
                    seekPreview = max(0, min(session.duration, v.location.x / max(g.size.width, 1) * session.duration))
                }
                .onEnded { _ in session.seek(to: seekPreview); seeking = false })
        }
        .frame(height: 24)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("hg.player.progress")
    }

    private var seekOverlay: some View {
        VStack(spacing: 4) {
            Text("\(fmt(seekPreview)) / \(fmt(session.duration))").font(.title3.weight(.bold).monospacedDigit())
            let delta = seekPreview - session.position
            Text(String(format: "%@%d 秒", delta >= 0 ? "+" : "-", Int(abs(delta)))).font(.footnote).foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: HGTheme.radius, style: .continuous))
        .foregroundStyle(.white)
        .allowsHitTesting(false)
    }

    private var boostBadge: some View {
        Text(session.lockedBoost ? "2× 已锁定 · 上滑取消" : "2× 快进中 · 下滑锁定")
            .font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 6)
            .background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white)
            .frame(maxHeight: .infinity, alignment: .top).padding(.top, safeTop + 48)
            .allowsHitTesting(false)
    }

    @ViewBuilder private var statusOverlay: some View {
        if let status = session.status {
            VStack(spacing: 10) { ProgressView().tint(.white); Text(status).font(.footnote).foregroundStyle(.white.opacity(0.8)) }
                .allowsHitTesting(false)
        }
        if let failed = session.failed {
            VStack(spacing: 12) {
                Text(failed).font(.footnote).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                HStack {
                    Button("重试") { session.retry() }.buttonStyle(.borderedProminent).tint(HGTheme.accent)
                    if session.hasNext { Button("下一集") { session.next() }.buttonStyle(.bordered).tint(.white) }
                }
            }
            .padding(32)
        }
    }

    private var exitCleanButton: some View {
        Button { withAnimation(.easeOut(duration: 0.2)) { clean = false } } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left").font(.footnote.weight(.semibold))
                .padding(10).background(.black.opacity(0.4), in: Circle()).foregroundStyle(.white.opacity(0.85))
        }
        .accessibilityIdentifier("hg.player.exitClean")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 16).padding(.bottom, 36)
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Text(toast).font(.footnote.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 8)
                .background(.black.opacity(0.65), in: Capsule()).foregroundStyle(.white)
                .padding(.top, safeTop + 50).transition(.opacity)
        }
    }

    // MARK: 动作

    private func doubleTapLike() {
        if !library.isFavorite(session.series.id) { library.toggleFavorite(session.series); flash("已收藏") }
        withAnimation(.spring(duration: 0.25)) { heartBurst = true }
        Task { try? await Task.sleep(for: .milliseconds(650)); withAnimation(.easeOut(duration: 0.2)) { heartBurst = false } }
    }

    private func flash(_ s: String) {
        withAnimation { toast = s }
        Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation { if toast == s { toast = nil } } }
    }

    private func setOrientation(landscape on: Bool) {
        landscape = on
        HGOrientation.allowLandscape = on
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: on ? .landscapeRight : .portrait))
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private func rateText(_ r: Float) -> String { String(format: "%g×", r) }
    private func fmt(_ t: Double) -> String {
        guard t.isFinite else { return "0:00" }
        let s = Int(t); return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// AVPlayerLayer + DouDuo 同款铺满规则（只在视频与屏幕同向时铺满）+ 画中画挂载。
struct HGVideoLayer: UIViewRepresentable {
    let player: AVPlayer
    let fillWidth: Bool
    let pip: DYPictureInPicture
    func makeUIView(context: Context) -> HGPlayerLayerView {
        let v = HGPlayerLayerView()
        v.playerLayer.player = player
        v.fillWidth = fillWidth
        pip.attach(to: v.playerLayer, enabled: true, onBackgroundClose: {}, onUnavailable: {})
        return v
    }
    func updateUIView(_ v: HGPlayerLayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        v.fillWidth = fillWidth
        v.applyGravity()
    }
}

final class HGPlayerLayerView: UIView {
    var fillWidth = true
    private var sizeObs: NSKeyValueObservation?
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        sizeObs = playerLayer.observe(\.videoRect, options: [.new]) { [weak self] _, _ in DispatchQueue.main.async { self?.applyGravity() } }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() { super.layoutSubviews(); applyGravity() }
    func applyGravity() {
        guard let size = playerLayer.player?.currentItem?.presentationSize, size.width > 1, size.height > 1,
              bounds.width > 1, bounds.height > 1 else { return }
        let g: AVLayerVideoGravity = DYVideoFit.presentation(fillWidth: fillWidth, videoAspect: size.width / size.height,
                                                             screenAspect: bounds.width / bounds.height) == .aspectFill ? .resizeAspectFill : .resizeAspect
        if playerLayer.videoGravity != g { playerLayer.videoGravity = g }
    }
}

/// 横屏只在播放页按「横屏」后放开。
enum HGOrientation {
    nonisolated(unsafe) static var allowLandscape = false
}

enum HGBackgroundPlayback {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "hg.bgPlay") as? Bool ?? true }
}
