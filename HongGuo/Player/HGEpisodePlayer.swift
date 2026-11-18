import SwiftUI
import AVKit
import MediaPlayer
import Observation

struct HGPlayerRequest: Identifiable {
    let id = UUID()
    let series: HGSeries
    let episodes: [HGEpisode]
    let index: Int
    let startAt: Double
}

/// 一部剧的播放会话：当前集、预载、断点、倍速、弹幕、锁屏信息。
/// 只有一个 AVPlayer —— 竖滑翻页时换 item，避免多个解密文件同时占内存。
@MainActor @Observable
final class HGPlaybackSession {
    let series: HGSeries
    let episodes: [HGEpisode]
    private(set) var index: Int
    let player = AVPlayer()

    var status: String?
    var failed: String?
    var isPlaying = false
    var position: Double = 0
    var duration: Double = 0
    var videoAspect: Double = 9.0 / 16.0
    var danmaku: [DYDanmaku] = []
    var danmakuNotice: String?
    var clock = DYDanmakuClock()
    var lockedBoost = false
    /// 官方统计（App 详情接口）：本剧追剧数 / 播放量，每集评论数 / 点赞数
    var stats: HGSeriesStats?
    var seekPreviewImage: UIImage?
    private var imageGenerator: AVAssetImageGenerator?
    private var lastPreviewAt = Date.distantPast
    var boosting = false
    let pip = DYPictureInPicture()

    private var startAt: Double
    private var loadTask: Task<Void, Never>?
    private var danmakuTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var lastSaved = Date.distantPast
    private let library = HGLibrary.shared

    init(_ r: HGPlayerRequest) {
        series = r.series; episodes = r.episodes; index = r.index; startAt = r.startAt
        player.automaticallyWaitsToMinimizeStalling = false
        player.allowsExternalPlayback = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        setupRemoteCommands()
    }

    var episode: HGEpisode { episodes[index] }
    var title: String { "\(series.series_title) · 第 \(episode.number) 集" }
    var hasNext: Bool { index + 1 < episodes.count }
    var rate: Float { library.rate }
    var effectiveRate: Float { boosting || lockedBoost ? 2 : library.rate }

    func start() {
        load(index, at: startAt)
        guard series.source == .hongguo else { return }
        let sid = series.series_id
        Task { [weak self] in self?.stats = try? await HGAPI.stats(series: sid) }
    }

    var episodeStat: HGEpisodeStat? { stats?.episodes.first { $0.vid == episode.vid } }

    /// 拖动进度时的预览画面（DouDuo 同款：节流 0.15 秒取一帧）。本地明文文件，取帧很快。
    func requestPreview(_ t: Double) {
        guard let gen = imageGenerator, Date().timeIntervalSince(lastPreviewAt) > 0.15 else { return }
        lastPreviewAt = Date()
        gen.cancelAllCGImageGeneration()
        gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: t, preferredTimescale: 600))]) { [weak self] _, cg, _, result, _ in
            guard result == .succeeded, let cg else { return }
            let img = UIImage(cgImage: cg)
            Task { @MainActor in self?.seekPreviewImage = img }
        }
    }
    func endPreview() { seekPreviewImage = nil }

    func go(to i: Int) {
        guard episodes.indices.contains(i), i != index else { return }
        save(force: true)
        lockedBoost = false
        load(i, at: 0)
    }
    func next() { if hasNext { go(to: index + 1) } }
    func previous() { if index > 0 { go(to: index - 1) } }

    func togglePlay() {
        if player.timeControlStatus == .paused { player.playImmediately(atRate: effectiveRate) } else { player.pause() }
        isPlaying = player.timeControlStatus != .paused
        clock.userToggle(position, playing: isPlaying, rate: Double(effectiveRate))
    }

    func seek(to t: Double) {
        let target = max(0, min(duration, t))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        position = target
        clock.seek(target, playing: isPlaying, rate: Double(effectiveRate))
    }

    func setRate(_ r: Float) {
        library.rate = r
        applyRate()
    }

    func setBoost(_ on: Bool) { boosting = on; applyRate() }
    func lockBoost() { lockedBoost = true; applyRate() }
    func unlockBoost() { lockedBoost = false; applyRate() }

    private func applyRate() {
        if player.timeControlStatus != .paused { player.rate = effectiveRate }
        clock.sync(position, playing: isPlaying, rate: Double(effectiveRate))
        updateNowPlaying()
    }

    func retry() { load(index, at: position) }

    func stop() {
        save(force: true)
        loadTask?.cancel(); danmakuTask?.cancel()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let c = MPRemoteCommandCenter.shared()
        [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand, c.nextTrackCommand, c.previousTrackCommand, c.changePlaybackPositionCommand]
            .forEach { $0.removeTarget(nil) }
    }

    // MARK: 加载

    private func load(_ i: Int, at offset: Double) {
        loadTask?.cancel()
        index = i; failed = nil; status = "正在获取片源…"
        position = 0; duration = 0; danmaku = []; danmakuNotice = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        clock = DYDanmakuClock()
        let vid = episodes[i].vid
        if episodes[i].locked == true {
            status = nil; failed = "本集在来源平台需要解锁，暂不能播放"
            return
        }
        startAtForDanmaku = offset
        loadDanmaku(vid)
        loadTask = Task { [weak self] in
            do {
                let file = try await HGMediaCache.shared.file(for: vid) { phase in
                    Task { @MainActor in
                        guard let self, self.index == i else { return }
                        switch phase {
                        case .resolving: self.status = "正在获取片源…"
                        case .downloading(let p): self.status = p > 0 ? "正在加载 \(Int(p * 100))%" : "正在加载…"
                        case .decrypting: self.status = "正在处理视频…"
                        }
                    }
                }
                guard let self, !Task.isCancelled, self.index == i else { return }
                self.attach(file, offset: offset)
                if self.hasNext, self.episodes[i + 1].locked != true { await HGMediaCache.shared.prefetch(self.episodes[i + 1].vid) }
            } catch {
                guard let self, !Task.isCancelled, self.index == i else { return }
                self.status = nil
                self.failed = error.localizedDescription
            }
        }
    }

    /// 分窗拉弹幕：先拉开头一窗，播放进度接近已拉范围末尾 10 秒内再拉下一窗（一窗约 30 秒、上千条）。
    private var danmakuNext: Int?
    private var danmakuVid = ""
    private var danmakuFetching = false

    private func loadDanmaku(_ vid: String) {
        danmakuTask?.cancel()
        danmakuNext = 0; danmakuVid = vid; danmakuFetching = false
        guard series.source == .hongguo else { danmakuNext = nil; danmakuNotice = "该来源没有弹幕"; return }
        fetchDanmakuWindow(from: max(0, Int(startAtForDanmaku * 1000)))
    }

    private var startAtForDanmaku: Double = 0

    private func fetchDanmakuWindow(from start: Int) {
        guard !danmakuFetching else { return }
        danmakuFetching = true
        let sid = series.series_id, vid = danmakuVid
        let dur = duration > 0 ? Int(duration * 1000) + 5000 : 3_600_000
        danmakuTask = Task { [weak self] in
            do {
                let r = try await HGAPI.danmaku(series: sid, vid: vid, startMs: start, durationMs: dur)
                guard let self, !Task.isCancelled, self.danmakuVid == vid else { return }
                self.danmaku = DYDanmaku.merged(self.danmaku, r.items)
                self.danmakuNext = r.next
                self.danmakuNotice = self.danmaku.isEmpty && r.next == nil ? "本集暂无弹幕" : nil
                self.danmakuFetching = false
            } catch {
                guard let self, !Task.isCancelled, self.danmakuVid == vid else { return }
                self.danmakuFetching = false
                self.danmakuNext = nil
                if self.danmaku.isEmpty { self.danmakuNotice = "弹幕源暂不可用" }
            }
        }
    }

    private func pumpDanmaku() {
        guard let next = danmakuNext, !danmakuFetching, position * 1000 > Double(next) - 10_000 else { return }
        fetchDanmakuWindow(from: next)
    }

    private func attach(_ file: URL, offset: Double) {
        let item = AVPlayerItem(url: file)
        item.audioTimePitchAlgorithm = .timeDomain
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.hasNext { self.next() } else { self.save(force: true, finished: true); self.isPlaying = false }
            }
        }
        player.replaceCurrentItem(with: item)
        let gen = AVAssetImageGenerator(asset: item.asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 360, height: 360)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        imageGenerator = gen
        seekPreviewImage = nil
        Task { [weak self] in
            if let track = try? await AVURLAsset(url: file).loadTracks(withMediaType: .video).first,
               let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let r = size.applying(transform)
                if abs(r.height) > 1 { self?.videoAspect = Double(abs(r.width) / abs(r.height)) }
            }
        }
        if offset > 1 { player.seek(to: CMTime(seconds: offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        status = nil
        player.playImmediately(atRate: effectiveRate)
        isPlaying = true
        clock.seek(offset, playing: true, rate: Double(effectiveRate))
        save(force: true)
        updateNowPlaying()
    }

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        position = t
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        isPlaying = player.timeControlStatus != .paused
        clock.sync(t, playing: isPlaying, rate: Double(player.rate > 0 ? player.rate : effectiveRate))
        save(force: false)
        pumpDanmaku()
        if Int(t * 4) % 4 == 0 { updateNowPlaying() }
    }

    private func save(force: Bool, finished: Bool = false) {
        guard force || Date().timeIntervalSince(lastSaved) > 5 else { return }
        lastSaved = Date()
        library.record(series, episode: index, position: finished ? 0 : (duration > 0 && position > duration - 2 ? 0 : position))
    }

    // MARK: 锁屏 / 控制中心

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { if self?.player.timeControlStatus == .paused { self?.togglePlay() } }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { if self?.player.timeControlStatus != .paused { self?.togglePlay() } }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.togglePlay() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: e.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "第 \(episode.number) 集",
            MPMediaItemPropertyAlbumTitle: series.series_title,
            MPMediaItemPropertyArtist: series.series_title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(effectiveRate) : 0,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
