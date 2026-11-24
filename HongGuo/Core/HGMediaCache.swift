import Foundation

/// 整集下载 → CENC 解密 → 写入缓存目录的明文 MP4，交给 AVPlayer 播本地文件。
/// 同一集并发请求合并成一个任务；只保留最近几集，避免占满空间。
actor HGMediaCache {
    static let shared = HGMediaCache()

    enum Phase: Equatable { case resolving, downloading(Double), decrypting }

    private let dir: URL
    private var inflight: [String: Task<URL, Error>] = [:]
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

    /// 同步判断（不进 actor）：推荐存货恢复时用
    nonisolated static func hasFile(_ vid: String) -> Bool {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("episodes", isDirectory: true)
        return FileManager.default.fileExists(atPath: d.appendingPathComponent("\(vid).mp4").path)
    }

    func file(for vid: String, source: HGSource? = nil, progress: (@Sendable (Phase) -> Void)? = nil) async throws -> URL {
        let target = dir.appendingPathComponent("\(vid).mp4")
        if FileManager.default.fileExists(atPath: target.path) { touch(vid); return target }
        if let task = inflight[vid] { return try await task.value }
        let task = Task { try await self.prepare(vid: vid, target: target, source: source, progress: progress) }
        inflight[vid] = task
        defer { inflight[vid] = nil }
        let url = try await task.value
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
        Task { _ = try? await self.file(for: vid) }
    }

    private func touch(_ vid: String) {
        order.removeAll { $0 == vid }
        order.append(vid)
        var i = 0
        while order.count - pinned.count > keep - Self.pinBudget, i < order.count {
            let old = order[i]
            if pinned.contains(old) { i += 1; continue }
            order.remove(at: i)
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(old).mp4"))
        }
    }

    /// 离线下载复用同一条「取源 → 下载 → 解密」流水线，写到指定位置。
    /// 已经下好解密的本地文件（不触发下载）
    func cachedFile(_ vid: String) -> URL? {
        let u = dir.appendingPathComponent("\(vid).mp4")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    private nonisolated func prepare(vid: String, target: URL, source given: HGSource? = nil, progress: (@Sendable (Phase) -> Void)?) async throws -> URL {
        progress?(.resolving)
        let source: HGSource
        if let given { source = given } else { source = try await HGAPI.source(vid) }
        var failure: Error = HGError.message("没有可用片源")
        // 源给的备用地址依次尝试；只换地址，不改签名与密钥。
        for variant in source.variants.prefix(4) {
            do {
                let data = try await download(variant, progress: progress)
                try Task.checkCancellation()
                var plain = data
                if let key = variant.contentKey, !key.isEmpty {
                    progress?(.decrypting)
                    plain = try HGCencDecryptor.decrypt(data, keyHex: key)
                }
                let tmp = target.appendingPathExtension("part")
                try plain.write(to: tmp, options: .atomic)
                _ = try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: tmp, to: target)
                return target
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = error
            }
        }
        throw failure
    }

    private nonisolated func download(_ v: HGVariant, progress: (@Sendable (Phase) -> Void)?) async throws -> Data {
        guard let url = URL(string: v.url), url.scheme == "https" else { throw HGError.message("片源地址无效") }
        var referers: [String?] = [v.referer.isEmpty ? nil : v.referer]
        referers.append(v.referer.isEmpty ? "https://novelquickapp.com/" : nil) // 与桌面版一致：403 时切换一次 Referer
        var lastStatus = 0
        for referer in referers {
            var req = URLRequest(url: url)
            req.setValue(v.userAgent.isEmpty ? "Mozilla/5.0" : v.userAgent, forHTTPHeaderField: "User-Agent")
            if let referer { req.setValue(referer, forHTTPHeaderField: "Referer") }
            let watcher = ProgressWatcher { progress?(.downloading($0)) }
            let (file, response) = try await session.download(for: req, delegate: watcher)
            defer { try? FileManager.default.removeItem(at: file) }
            lastStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            if lastStatus == 403 { continue }
            guard lastStatus == 200 else { throw HGError.message("视频下载失败（HTTP \(lastStatus)）") }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0, size <= HGCencDecryptor.maxBytes else { throw HGError.message("视频大小无效") }
            return try Data(contentsOf: file)
        }
        throw HGError.message("视频下载失败（HTTP \(lastStatus)）")
    }
}

/// 观察下载任务的 Progress，节流后回报 0…1。
private final class ProgressWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: (Double) -> Void
    private var observation: NSKeyValueObservation?
    private var last = Date.distantPast
    init(_ report: @escaping (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            guard let self, Date().timeIntervalSince(self.last) > 0.15 else { return }
            self.last = Date()
            self.report(p.fractionCompleted)
        }
    }
}
