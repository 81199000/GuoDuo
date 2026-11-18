import Foundation

/// 整集下载 → CENC 解密 → 写入缓存目录的明文 MP4，交给 AVPlayer 播本地文件。
/// 同一集并发请求合并成一个任务；只保留最近几集，避免占满空间。
actor HGMediaCache {
    static let shared = HGMediaCache()

    enum Phase: Equatable { case resolving, downloading(Double), decrypting }

    private let dir: URL
    private var inflight: [String: Task<URL, Error>] = [:]
    private var order: [String] = []
    private let keep = 6
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
        try? FileManager.default.removeItem(at: dir) // 上次退出遗留的缓存不复用：签名 URL 早已过期，明文也不长期留存
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func file(for vid: String, progress: (@Sendable (Phase) -> Void)? = nil) async throws -> URL {
        if let offline = await HGDownloads.shared.localFile(vid) { return offline } // 已离线下载：直接播
        let target = dir.appendingPathComponent("\(vid).mp4")
        if FileManager.default.fileExists(atPath: target.path) { touch(vid); return target }
        if let task = inflight[vid] { return try await task.value }
        let task = Task { try await self.prepare(vid: vid, target: target, progress: progress) }
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
        while order.count > keep {
            let old = order.removeFirst()
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(old).mp4"))
        }
    }

    /// 离线下载复用同一条「取源 → 下载 → 解密」流水线，写到指定位置。
    nonisolated func fetch(vid: String, to target: URL, progress: (@Sendable (Phase) -> Void)?) async throws {
        _ = try await prepare(vid: vid, target: target, progress: progress)
    }

    private nonisolated func prepare(vid: String, target: URL, progress: (@Sendable (Phase) -> Void)?) async throws -> URL {
        progress?(.resolving)
        let source = try await HGAPI.source(vid)
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
