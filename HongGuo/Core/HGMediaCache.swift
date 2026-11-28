import Foundation

/// 每集一个 HGProgressive（见 HGStream.swift）：边下边解密写进 episodes/<vid>.mp4.part，下完改名 <vid>.mp4。
/// 播放器拿 stream(for:) 边下边播；预下 / 推荐存货 / 海报等用 file(for:) 等整集落地。同一集只下一遍。
/// 只保留最近几集，避免占满空间。
actor HGMediaCache {
    static let shared = HGMediaCache()

    enum Phase: Equatable { case resolving, downloading(Double), decrypting }

    /// 能开播了：stream = 交给 HGStreamLoader 边下边播；file = 本地已经有整集
    enum Playable { case stream(HGProgressive), file(URL) }

    private let dir: URL
    private var inflight: [String: HGProgressive] = [:]
    private var order: [String] = []
    /// 推荐缓存 10 部（横竖各 5）+ 正在看的剧前后几集
    private let keep = 24
    /// 推荐存货占的名额（备 8 部 + 慢片后台下的几部）；其余 10 个名额给正在看的剧
    private static let pinBudget = 14
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.allowsExpensiveNetworkAccess = true
        c.timeoutIntervalForResource = 300
        c.httpCookieAcceptPolicy = .never
        return URLSession(configuration: c)
    }()

    init() {
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("episodes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 上次的缓存留着（推荐存货下次打开直接用）；只清半截文件，按修改时间重建淘汰顺序
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files where f.pathExtension == "part" { try? fm.removeItem(at: f) }
        order = files.filter { $0.pathExtension == "mp4" }
            .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast
                    < (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    /// 推荐存货：淘汰时跳过
    private var pinned = Set<String>()
    func setPinned(_ vids: Set<String>) { pinned = vids }
    /// 正在投到电视的那集：手机接着刷别的时不能被淘汰（电视还在从手机上拉）
    private var castPin: String?
    func setCastPin(_ vid: String?) { castPin = vid }

    /// 同步判断（不进 actor）：推荐存货恢复时用
    nonisolated static func hasFile(_ vid: String) -> Bool {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("episodes", isDirectory: true)
        return FileManager.default.fileExists(atPath: d.appendingPathComponent("\(vid).mp4").path)
    }

    private func job(_ vid: String, source: HGSource?, progress: (@Sendable (Phase) -> Void)?) -> HGProgressive {
        if let p = inflight[vid] { p.addProgress(progress); return p }
        let p = HGProgressive(vid: vid, target: dir.appendingPathComponent("\(vid).mp4"), session: session) { [weak self] ok in
            Task { await self?.done(vid, ok: ok) }
        }
        p.addProgress(progress)
        inflight[vid] = p
        p.start(source: source)
        return p
    }

    private func done(_ vid: String, ok: Bool) {
        inflight[vid] = nil
        if ok { touch(vid) }
    }

    /// 播放用：文件头一到就能开播，不等整集
    func stream(for vid: String, source: HGSource? = nil, progress: (@Sendable (Phase) -> Void)? = nil) async throws -> Playable {
        let target = dir.appendingPathComponent("\(vid).mp4")
        if FileManager.default.fileExists(atPath: target.path) { touch(vid); return .file(target) }
        let p = job(vid, source: source, progress: progress)
        switch try await p.ready() {
        case .stream: return .stream(p)
        case .file(let u): return .file(u)
        }
    }

    /// 等整集落地（预下、推荐存货、离线、海报）
    func file(for vid: String, source: HGSource? = nil, progress: (@Sendable (Phase) -> Void)? = nil) async throws -> URL {
        let target = dir.appendingPathComponent("\(vid).mp4")
        if FileManager.default.fileExists(atPath: target.path) { touch(vid); return target }
        let p = job(vid, source: source, progress: progress)
        let url = try await p.finishedFile()
        touch(vid)
        return url
    }

    /// 储存空间页「清理缓存」：停掉在下的、删掉整集缓存目录重建（正在播放的那集 AVPlayer 已打开文件句柄，照常播完）
    func clearForStorage() -> Bool {
        inflight.values.forEach { $0.cancel() }
        inflight.removeAll()
        order.removeAll()
        let ok = DYStorageFiles.resetCacheDirectory(dir)
        return ok && DYStorageFiles.removeVideoWork()
    }

    func prefetch(_ vid: String) {
        guard inflight[vid] == nil, !FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(vid).mp4").path) else { return }
        _ = job(vid, source: nil, progress: nil)
    }

    private func touch(_ vid: String) {
        order.removeAll { $0 == vid }
        order.append(vid)
        var i = 0
        while order.count - pinned.count > keep - Self.pinBudget, i < order.count {
            let old = order[i]
            if pinned.contains(old) || old == castPin { i += 1; continue }
            order.remove(at: i)
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(old).mp4"))
        }
    }

    /// 已经下好解密的本地文件（不触发下载）
    func cachedFile(_ vid: String) -> URL? {
        let u = dir.appendingPathComponent("\(vid).mp4")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
}
