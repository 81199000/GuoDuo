import AVFoundation
import Foundation

/// 边下边播（2026-11-26）：红果 App 片源是 CENC 加密 MP4（moov 在前），以前要整集下完、整集解密才能播。
/// 现在一集只下一遍：先 Range 拿文件头（≈256KB，含 moov）算出解密后的文件头，AVPlayer 立刻就能开播；
/// 正文顺序下载、到一块解一块写进 episodes/<vid>.mp4.part，AVPlayer 通过 hgs:// 读已经到的部分；
/// 拖到还没下到的地方就单独 Range 取那一段现解现给。下完改名成 <vid>.mp4，预下 / 海报 / 再看照旧走本地文件。
/// moov 不在文件头（或文件头解析失败）时退回整集下载解密（老流程）。
final class HGProgressive: @unchecked Sendable {
    enum Ready { case stream, file(URL) }

    let vid: String
    private let target: URL
    private let part: URL
    private let session: URLSession
    private let onDone: @Sendable (Bool) -> Void
    private let lock = NSLock()

    private var plan: HGCencDecryptor.StreamPlan?
    private var variant: HGVariant?
    private var referer: String?
    private var headerLen = 0
    private var outLen = 0
    private var available = 0
    private var finished: URL?
    private var failure: Error?
    private var streamable = false
    private var dataWaiters: [(Int, CheckedContinuation<Void, Error>)] = []
    private var readyWaiters: [CheckedContinuation<Ready, Error>] = []
    private var doneWaiters: [CheckedContinuation<URL, Error>] = []
    private var progress: [@Sendable (HGMediaCache.Phase) -> Void] = []
    private var readHandle: FileHandle?
    private var lastFarLog = Date.distantPast
    private var task: Task<Void, Never>?

    static let headBytes = 256 * 1024
    /// 拖动目标离已下载位置超过这么多，就单独 Range 取，不等顺序下载
    static let farGap = 1_536 * 1024

    init(vid: String, target: URL, session: URLSession, onDone: @escaping @Sendable (Bool) -> Void) {
        self.vid = vid; self.target = target; self.session = session; self.onDone = onDone
        part = target.appendingPathExtension("part")
    }

    var totalLength: Int { lock.withLock { outLen } }

    func addProgress(_ p: (@Sendable (HGMediaCache.Phase) -> Void)?) {
        guard let p else { return }
        lock.withLock { progress.append(p) }
    }

    private func report(_ ph: HGMediaCache.Phase) {
        for p in lock.withLock({ progress }) { p(ph) }
    }

    func start(source: HGSource?) {
        task = Task.detached(priority: .userInitiated) { [self] in await self.run(source) }
    }

    func cancel() { task?.cancel(); fail(CancellationError()) }

    // MARK: 等待

    /// 能开播了：.stream = 走 hgs://；.file = 已经整集下好（或退回了老流程）
    func ready() async throws -> Ready {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if let f = finished { lock.unlock(); c.resume(returning: .file(f)); return }
            if streamable { lock.unlock(); c.resume(returning: .stream); return }
            if let e = failure { lock.unlock(); c.resume(throwing: e); return }
            readyWaiters.append(c); lock.unlock()
        }
    }

    func finishedFile() async throws -> URL {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if let f = finished { lock.unlock(); c.resume(returning: f); return }
            if let e = failure { lock.unlock(); c.resume(throwing: e); return }
            doneWaiters.append(c); lock.unlock()
        }
    }

    private func waitData(_ n: Int) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            if available >= n || finished != nil { lock.unlock(); c.resume(); return }
            if let e = failure { lock.unlock(); c.resume(throwing: e); return }
            dataWaiters.append((n, c)); lock.unlock()
        }
    }

    /// 读解密后文件 [off, off+len) 的一段（可能比 len 短，至少 1 字节）
    func read(_ off: Int, _ len: Int) async throws -> Data {
        let (avail, hdr, total, done) = lock.withLock { (available, headerLen, outLen, finished != nil) }
        guard off < total else { return Data() }
        let n = min(len, total - off)
        if !done, off >= hdr, off > avail + Self.farGap {
            let now = Date()
            if lock.withLock({ now.timeIntervalSince(lastFarLog) > 5 ? { lastFarLog = now; return true }() : false }) {
                HGTrace.log("stream \(vid) 跳读 @\(off / 1024)KB（已下 \(avail / 1024)KB）")
            }
            return try await fetchDecrypted(off, n)
        }
        try await waitData(min(off + n, off + 64 * 1024))
        let got = lock.withLock { finished != nil ? total : available }
        let m = min(n, max(0, got - off))
        guard m > 0, let h = lock.withLock({ readHandle }) else { throw HGError.message("视频读取失败") }
        return try lock.withLock {
            try h.seek(toOffset: UInt64(off))
            return try h.read(upToCount: m) ?? Data()
        }
    }

    /// 还没顺序下到的远处：单独 Range 取源文件对应区间，现场解密
    private func fetchDecrypted(_ outOff: Int, _ n: Int) async throws -> Data {
        guard let v = variant else { throw HGError.message("片源未就绪") }
        let delta = plan?.delta ?? 0
        let src = outOff + delta
        let (data, status) = try await get(v, range: "bytes=\(src)-\(src + n - 1)")
        guard status == 206 || status == 200 else { throw HGError.message("视频加载失败（HTTP \(status)）") }
        var buf = [UInt8](status == 200 ? data.dropFirst(src).prefix(n) : data.prefix(n))
        if let plan { try HGCencDecryptor.decrypt(&buf, at: src, plan: plan) }
        return Data(buf)
    }

    // MARK: 下载

    private func run(_ given: HGSource?) async {
        do {
            report(.resolving)
            let source: HGSource
            if let given { source = given } else { source = try await HGAPI.source(vid) }
            var lastErr: Error = HGError.message("没有可用片源")
            for v in source.variants.prefix(4) {
                try Task.checkCancellation()
                do {
                    if try await stream(v) { return }
                    // 不能边下边播（moov 在后面等）：整集下载解密
                    HGTrace.log("stream \(vid) 不能边下边播，退回整集下载")
                    let url = try await HGProgressive.whole(v, target: target, session: session, progress: { [weak self] in self?.report($0) })
                    finish(url); return
                } catch is CancellationError { throw CancellationError() }
                catch { lastErr = error; resetForRetry() }
            }
            throw lastErr
        } catch {
            fail(error)
        }
    }

    /// 返回 false = 这个片源不适合边下边播（交给整集下载）
    private func stream(_ v: HGVariant) async throws -> Bool {
        let (head, total) = try await fetchHead(v)
        guard total > 0, total <= HGCencDecryptor.maxBytes else { throw HGError.message("视频大小无效") }
        var bytes = [UInt8](head)
        var p: HGCencDecryptor.StreamPlan?
        if let key = v.contentKey, !key.isEmpty {
            // moov 可能比 256KB 大：照 moov 的长度补齐
            let top = HGCencDecryptor.parseBoxes(bytes, 0, bytes.count)
            if top.first(where: { $0.typ == "moov" }) == nil {
                var off = 0
                while off + 8 <= bytes.count {
                    var size = Int(HGCencDecryptor.u32(bytes, off)); let typ = HGCencDecryptor.fourcc(bytes, off + 4)
                    if size == 1 { size = Int(HGCencDecryptor.u64(bytes, off + 8)) }
                    if typ == "mdat" || size < 8 { return false }
                    if typ == "moov" {
                        guard off + size <= min(total, 16 * 1024 * 1024) else { return false }
                        let (more, st) = try await get(v, range: "bytes=\(bytes.count)-\(off + size + 64 * 1024 - 1)")
                        guard st == 206 else { return false }
                        bytes += [UInt8](more)
                        break
                    }
                    off += size
                }
            }
            guard let made = try? HGCencDecryptor.streamPlan(head: bytes, total: total, keyHex: key) else { return false }
            p = made
        }
        try Task.checkCancellation()
        let header = p?.header ?? []
        let delta = p?.delta ?? 0
        let bodyStart = p?.bodyStart ?? 0
        let out = total - delta
        // 建 .part：先写解密后的文件头，再写文件头里已经带着的那段正文
        _ = try? FileManager.default.removeItem(at: part)
        FileManager.default.createFile(atPath: part.path, contents: nil)
        let w = try FileHandle(forWritingTo: part)
        defer { try? w.close() }
        try w.write(contentsOf: Data(header))
        var src = bodyStart
        if bytes.count > bodyStart {
            var first = Array(bytes[bodyStart...])
            if let p { try HGCencDecryptor.decrypt(&first, at: src, plan: p) }
            try w.write(contentsOf: Data(first))
            src += first.count
        }
        let rh = try FileHandle(forReadingFrom: part)
        HGTrace.log("stream \(vid) 文件头就绪 \(bytes.count / 1024)KB/\(total / 1024)KB 加密=\(p != nil) 头\(header.count)B")
        lock.withLock {
            plan = p; variant = v; headerLen = header.count; outLen = out
            available = src - delta; readHandle = rh; streamable = true
        }
        resume()
        // 正文顺序下载（断了从断点续，最多 3 次）
        var tries = 0
        while src < total {
            try Task.checkCancellation()
            do {
                for try await chunk in chunks(v, from: src) {
                    try Task.checkCancellation()
                    #if DEBUG
                    // 测试用：模拟慢网（模拟器网太快，测不到「拖到还没下到的地方」）
                    if let kbps = Double(ProcessInfo.processInfo.environment["HG_STREAM_THROTTLE_KBPS"] ?? ""), kbps > 0 {
                        try await Task.sleep(for: .seconds(Double(chunk.count) / 1024 / kbps))
                    }
                    #endif
                    var b = [UInt8](chunk)
                    if b.count > total - src { b.removeLast(b.count - (total - src)) }
                    if let p { try HGCencDecryptor.decrypt(&b, at: src, plan: p) }
                    try w.write(contentsOf: Data(b))
                    src += b.count
                    lock.withLock { available = src - delta }
                    resume()
                    report(.downloading(Double(src) / Double(total)))
                    if src >= total { break }
                }
                if src < total { throw HGError.message("视频下载中断") }
            } catch is CancellationError { throw CancellationError() }
            catch {
                tries += 1
                if tries > 3 { throw error }
                try await Task.sleep(for: .milliseconds(500 * tries))
            }
        }
        try w.synchronize()
        _ = try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: part, to: target)
        HGTrace.log("stream \(vid) 整集下完 \(total / 1024)KB")
        finish(target)
        return true
    }

    private func fetchHead(_ v: HGVariant) async throws -> (Data, Int) {
        let (d, status, total) = try await getWithTotal(v, range: "bytes=0-\(Self.headBytes - 1)")
        if status == 200 { return (d, d.count) }     // 不支持 Range：整个文件已经在手上
        guard status == 206, total > 0 else { throw HGError.message("视频加载失败（HTTP \(status)）") }
        return (d, total)
    }

    private func request(_ v: HGVariant, range: String?, referer ref: String?) throws -> URLRequest {
        guard let url = URL(string: v.url), url.scheme == "https" else { throw HGError.message("片源地址无效") }
        var req = URLRequest(url: url)
        req.setValue(v.userAgent.isEmpty ? "Mozilla/5.0" : v.userAgent, forHTTPHeaderField: "User-Agent")
        if let ref, !ref.isEmpty { req.setValue(ref, forHTTPHeaderField: "Referer") }
        if let range { req.setValue(range, forHTTPHeaderField: "Range") }
        return req
    }

    /// 与老流程一致：403 时换一次 Referer；选中的 Referer 记住给后面的请求用
    private func getWithTotal(_ v: HGVariant, range: String) async throws -> (Data, Int, Int) {
        let refs: [String?] = lock.withLock({ referer }).map { [$0] }
            ?? [v.referer.isEmpty ? nil : v.referer, v.referer.isEmpty ? "https://novelquickapp.com/" : nil]
        var last = 0
        for ref in refs {
            let (d, r) = try await session.data(for: try request(v, range: range, referer: ref))
            let h = r as? HTTPURLResponse
            last = h?.statusCode ?? 0
            if last == 403 { continue }
            lock.withLock { referer = ref ?? "" }
            let total = Int((h?.value(forHTTPHeaderField: "Content-Range") ?? "").split(separator: "/").last ?? "") ?? 0
            return (d, last, total)
        }
        return (Data(), last, 0)
    }

    private func get(_ v: HGVariant, range: String) async throws -> (Data, Int) {
        let (d, s, _) = try await getWithTotal(v, range: range)
        return (d, s)
    }

    private func chunks(_ v: HGVariant, from: Int) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { cont in
            do {
                let req = try request(v, range: "bytes=\(from)-", referer: lock.withLock { referer })
                let feed = ChunkFeed(cont)
                let t = session.dataTask(with: req)
                t.delegate = feed
                cont.onTermination = { _ in t.cancel() }
                t.resume()
            } catch { cont.finish(throwing: error) }
        }
    }

    // MARK: 状态

    private func resume() {
        lock.lock()
        let avail = available
        let ready = readyWaiters; readyWaiters = []
        var go: [CheckedContinuation<Void, Error>] = []
        dataWaiters.removeAll { if $0.0 <= avail { go.append($0.1); return true }; return false }
        lock.unlock()
        ready.forEach { $0.resume(returning: .stream) }
        go.forEach { $0.resume() }
    }

    private func finish(_ url: URL) {
        lock.lock()
        finished = url
        let r = readyWaiters, d = doneWaiters, w = dataWaiters
        readyWaiters = []; doneWaiters = []; dataWaiters = []
        lock.unlock()
        r.forEach { $0.resume(returning: streamable ? .stream : .file(url)) }
        d.forEach { $0.resume(returning: url) }
        w.forEach { $0.1.resume() }
        onDone(true)
    }

    private func fail(_ e: Error) {
        lock.lock()
        guard finished == nil, failure == nil else { lock.unlock(); return }
        failure = e
        let r = readyWaiters, d = doneWaiters, w = dataWaiters
        readyWaiters = []; doneWaiters = []; dataWaiters = []
        lock.unlock()
        r.forEach { $0.resume(throwing: e) }
        d.forEach { $0.resume(throwing: e) }
        w.forEach { $0.1.resume(throwing: e) }
        onDone(false)
    }

    /// 换下一个片源前：还没开播的状态全部清掉
    private func resetForRetry() {
        lock.withLock {
            if !streamable { plan = nil; variant = nil; referer = nil; headerLen = 0; outLen = 0; available = 0 }
        }
    }

    // MARK: 老流程（整集下载 → 整集解密）

    static func whole(_ v: HGVariant, target: URL, session: URLSession,
                      progress: (@Sendable (HGMediaCache.Phase) -> Void)?) async throws -> URL {
        guard let url = URL(string: v.url), url.scheme == "https" else { throw HGError.message("片源地址无效") }
        var referers: [String?] = [v.referer.isEmpty ? nil : v.referer]
        referers.append(v.referer.isEmpty ? "https://novelquickapp.com/" : nil)
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
            var plain = try Data(contentsOf: file)
            try Task.checkCancellation()
            if let key = v.contentKey, !key.isEmpty {
                progress?(.decrypting)
                plain = try HGCencDecryptor.decrypt(plain, keyHex: key)
            }
            let tmp = target.appendingPathExtension("part")
            try plain.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: tmp, to: target)
            return target
        }
        throw HGError.message("视频下载失败（HTTP \(lastStatus)）")
    }
}

/// URLSession 数据任务 → 一块一块的 Data（不攒整集）
private final class ChunkFeed: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let cont: AsyncThrowingStream<Data, Error>.Continuation
    init(_ c: AsyncThrowingStream<Data, Error>.Continuation) { cont = c }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 206 { completionHandler(.allow) }
        else { cont.finish(throwing: HGError.message("视频加载失败（HTTP \(code)）")); completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { cont.yield(data) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { cont.finish(throwing: error) } else { cont.finish() }
    }
}

/// 观察下载任务的 Progress，节流后回报 0…1。
final class ProgressWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

/// AVPlayer 读 hgs://<vid>.mp4 → 从 HGProgressive 拿解密后的字节。AVURLAsset 对 delegate 是弱引用，播放器要自己持有。
final class HGStreamLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let queue = DispatchQueue(label: "hg.stream.loader")
    static let scheme = "hgs"
    let source: HGProgressive
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]   // 只在 queue 上读写

    init(_ p: HGProgressive) { source = p }

    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: URL(string: "\(Self.scheme)://stream/\(source.vid).mp4")!)
        asset.resourceLoader.setDelegate(self, queue: Self.queue)
        return asset
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let id = ObjectIdentifier(loadingRequest)
        let p = source
        tasks[id] = Task { [weak self] in
            await HGStreamLoader.serve(loadingRequest, p)
            HGStreamLoader.queue.async { self?.tasks[id] = nil }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }

    private static func serve(_ r: AVAssetResourceLoadingRequest, _ p: HGProgressive) async {
        do {
            let total = p.totalLength
            if let info = r.contentInformationRequest {
                info.contentType = AVFileType.mp4.rawValue
                info.contentLength = Int64(total)
                info.isByteRangeAccessSupported = true
            }
            if let dr = r.dataRequest {
                var off = Int(dr.requestedOffset)
                let end = dr.requestsAllDataToEndOfResource ? total : min(total, off + dr.requestedLength)
                while off < end {
                    try Task.checkCancellation()
                    let d = try await p.read(off, min(512 * 1024, end - off))
                    if d.isEmpty { break }
                    try Task.checkCancellation()
                    dr.respond(with: d)
                    off += d.count
                }
            }
            if !Task.isCancelled { r.finishLoading() }
        } catch is CancellationError {
        } catch {
            if !r.isCancelled { r.finishLoading(with: error) }
        }
    }
}
