import SwiftUI
import AVKit
import Observation

struct HGPlayerRequest: Identifiable {
    let id = UUID()
    let series: HGSeries
    let episodes: [HGEpisode]
    let index: Int
    let startAt: Double
}

@MainActor @Observable
final class HGPlayerModel {
    let series: HGSeries
    let episodes: [HGEpisode]
    private(set) var index: Int
    let player = AVPlayer()
    var status: String?
    var failed: String?
    var showsEpisodes = false
    var isPlaying = false
    var position: Double = 0
    var duration: Double = 0

    private var startAt: Double
    private var loadTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var lastSaved = Date.distantPast
    private let library = HGLibrary.shared

    init(_ r: HGPlayerRequest) {
        series = r.series; episodes = r.episodes; index = r.index; startAt = r.startAt
        player.automaticallyWaitsToMinimizeStalling = false
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var title: String { "\(series.series_title) · 第 \(episodes[index].number) 集" }
    var hasNext: Bool { index + 1 < episodes.count }

    func start() { load(index, at: startAt) }

    func play(_ i: Int) {
        guard episodes.indices.contains(i) else { return }
        save(force: true)
        load(i, at: 0)
    }

    func next() { if hasNext { play(index + 1) } }
    func previous() { if index > 0 { play(index - 1) } }

    func togglePlay() {
        if player.timeControlStatus == .paused { player.playImmediately(atRate: library.rate) } else { player.pause() }
    }

    func seek(by delta: Double) { seek(to: max(0, min(duration, position + delta))) }
    func seek(to t: Double) { player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }

    func setRate(_ r: Float) {
        library.rate = r
        if player.timeControlStatus != .paused { player.rate = r }
    }
    var rate: Float { library.rate }

    func retry() { load(index, at: position) }

    func stop() {
        save(force: true)
        loadTask?.cancel()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    private func load(_ i: Int, at offset: Double) {
        loadTask?.cancel()
        index = i; failed = nil; status = "正在获取片源…"
        position = 0; duration = 0
        player.pause()
        player.replaceCurrentItem(with: nil)
        let vid = episodes[i].vid
        loadTask = Task { [weak self] in
            do {
                let file = try await HGMediaCache.shared.file(for: vid) { phase in
                    Task { @MainActor in
                        switch phase {
                        case .resolving: self?.status = "正在获取片源…"
                        case .downloading(let p): self?.status = p > 0 ? "正在加载 \(Int(p * 100))%" : "正在加载…"
                        case .decrypting: self?.status = "正在处理视频…"
                        }
                    }
                }
                guard let self, !Task.isCancelled, self.index == i else { return }
                self.attach(file, offset: offset)
                if self.hasNext { await HGMediaCache.shared.prefetch(self.episodes[i + 1].vid) }
            } catch {
                guard let self, !Task.isCancelled, self.index == i else { return }
                self.status = nil
                self.failed = error.localizedDescription
            }
        }
    }

    private func attach(_ file: URL, offset: Double) {
        let item = AVPlayerItem(url: file)
        item.audioTimePitchAlgorithm = .timeDomain
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.hasNext { self.next() } else { self.save(force: true, finished: true) }
            }
        }
        player.replaceCurrentItem(with: item)
        if offset > 1 { seek(to: offset) }
        status = nil
        player.playImmediately(atRate: library.rate)
        save(force: true)
    }

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        position = t
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        isPlaying = player.timeControlStatus != .paused
        save(force: false)
    }

    private func save(force: Bool, finished: Bool = false) {
        guard force || Date().timeIntervalSince(lastSaved) > 5 else { return }
        lastSaved = Date()
        // 一集看完且无下一集时把断点清零，下次从头重看该集。
        library.record(series, episode: index, position: finished ? 0 : (duration > 0 && position > duration - 2 ? 0 : position))
    }
}

struct HGPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: HGPlayerModel
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var boosted = false

    private static let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

    init(request: HGPlayerRequest) { _model = State(initialValue: HGPlayerModel(request)) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            HGVideoSurface(player: model.player).ignoresSafeArea()
                .accessibilityElement()
                .accessibilityIdentifier("hg.player.surface")
                .accessibilityValue(model.isPlaying && model.position > 0.5 ? "playing-\(model.episodes[model.index].number)" : "idle")
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }
                .onLongPressGesture(minimumDuration: 0.3, maximumDistance: 30) {} onPressingChanged: { pressing in
                    // 长按临时 2 倍速，松手恢复
                    if pressing { boosted = true; model.player.rate = 2 }
                    else if boosted { boosted = false; if model.isPlaying { model.player.rate = model.rate } }
                }
                .gesture(DragGesture(minimumDistance: 40).onEnded { v in
                    if abs(v.translation.height) > abs(v.translation.width) {
                        if v.translation.height < -60 { model.next() } else if v.translation.height > 60 { model.previous() }
                    }
                })

            if let status = model.status {
                VStack(spacing: 10) { ProgressView().tint(.white); Text(status).font(.footnote).foregroundStyle(.white.opacity(0.8)) }
            }
            if let failed = model.failed {
                VStack(spacing: 12) {
                    Text(failed).font(.footnote).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                    HStack {
                        Button("重试") { model.retry() }.buttonStyle(.borderedProminent).tint(HGTheme.accent)
                        if model.hasNext { Button("下一集") { model.next() }.buttonStyle(.bordered).tint(.white) }
                    }
                }
                .padding(32)
            }
            if boosted {
                Text("2× 快进中").font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white)
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 60)
            }
            if controlsVisible { controls.transition(.opacity) }
        }
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $model.showsEpisodes) { episodeSheet.presentationDetents([.medium, .large]) }
        .onAppear { model.start(); scheduleHide() }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { model.player.pause() } }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: { Image(systemName: "chevron.down").font(.title3.weight(.semibold)) }
                    .accessibilityIdentifier("hg.player.close")
                Text(model.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 8)
            Spacer()
            HStack(spacing: 44) {
                Button { model.seek(by: -10) } label: { Image(systemName: "gobackward.10") }
                Button { model.togglePlay(); scheduleHide() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 40))
                }
                .accessibilityIdentifier("hg.player.toggle")
                Button { model.seek(by: 10) } label: { Image(systemName: "goforward.10") }
            }
            .font(.title2)
            Spacer()
            VStack(spacing: 10) {
                if model.duration > 0 {
                    Slider(value: Binding(get: { model.position }, set: { model.seek(to: $0) }), in: 0...model.duration)
                        .tint(HGTheme.accent)
                    HStack {
                        Text(fmt(model.position)); Spacer(); Text(fmt(model.duration))
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                }
                HStack(spacing: 20) {
                    Button { model.previous() } label: { Image(systemName: "backward.end.fill") }.disabled(model.status != nil && model.failed == nil)
                    Button { model.next() } label: { Image(systemName: "forward.end.fill") }.disabled(!model.hasNext)
                    Spacer()
                    Menu {
                        ForEach(Self.rates, id: \.self) { r in
                            Button { model.setRate(r) } label: {
                                if r == model.rate { Label(rateText(r), systemImage: "checkmark") } else { Text(rateText(r)) }
                            }
                        }
                    } label: { Text(rateText(model.rate)).font(.subheadline.weight(.semibold)).monospacedDigit() }
                    Button { model.showsEpisodes = true } label: { Label("选集", systemImage: "list.number").font(.subheadline) }
                        .accessibilityIdentifier("hg.player.episodes")
                }
                .font(.title3)
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .foregroundStyle(.white)
        .background {
            LinearGradient(colors: [.black.opacity(0.6), .clear, .clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
        }
        .simultaneousGesture(TapGesture().onEnded { scheduleHide() })
    }

    private var episodeSheet: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 8)], spacing: 8) {
                    ForEach(Array(model.episodes.enumerated()), id: \.element.id) { i, ep in
                        Button { model.play(i); model.showsEpisodes = false } label: {
                            Text("\(ep.number)").font(.subheadline.monospacedDigit())
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(i == model.index ? HGTheme.accent : HGTheme.surfaceHigh,
                                            in: RoundedRectangle(cornerRadius: HGTheme.radiusSmall, style: .continuous))
                                .foregroundStyle(i == model.index ? Color.white : HGTheme.textPrimary)
                        }
                        .id(i)
                    }
                }
                .padding()
            }
            .background(HGTheme.surface)
            .onAppear { proxy.scrollTo(model.index, anchor: .center) }
        }
    }

    private func toggleControls() {
        withAnimation(.easeOut(duration: 0.2)) { controlsVisible.toggle() }
        if controlsVisible { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, model.isPlaying else { return }
            withAnimation(.easeOut(duration: 0.3)) { controlsVisible = false }
        }
    }

    private func rateText(_ r: Float) -> String { r == 1 ? "倍速" : String(format: "%g×", r) }
    private func fmt(_ t: Double) -> String {
        guard t.isFinite else { return "0:00" }
        let s = Int(t); return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// 只渲染画面的 AVPlayerLayer（控件自绘）；支持系统画中画。
struct HGVideoSurface: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView(); v.playerLayer.player = player; v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }
    func updateUIView(_ v: PlayerView, context: Context) { v.playerLayer.player = player }
    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
