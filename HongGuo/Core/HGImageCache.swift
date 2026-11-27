import SwiftUI
import UIKit
import CryptoKit

/// 封面 / 头像缓存。
/// AsyncImage 每次出现都先显示占位、再走网络/URLCache 解码一遍，翻回来就是一闪一闪重新加载。
/// 这里两级：内存（解码好的 UIImage，命中时同步出图，不闪）+ 磁盘（Caches/hg-covers，按 URL 的 SHA256 存原始字节，
/// 重启 App 也不用重下）。磁盘超过上限时启动后按最久没用的先删。「缓存管理」清理会一起清掉。
final class HGImageCache: @unchecked Sendable {
    static let shared = HGImageCache()
    static let directoryName = "hg-covers"
    /// 磁盘上限 300MB；一张封面 30~80KB，够存几千张
    static let diskLimit: Int64 = 300 << 20

    let directory: URL
    private let memory = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = nil                       // 自己管磁盘，不再让 URLCache 存第二份
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 6
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    private init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.totalCostLimit = 80 << 20       // 解码后的位图，约 80MB
    }

    private func key(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 内存命中（同步，给视图第一帧用，命中就不显示占位）
    func cached(_ url: URL) -> UIImage? { memory.object(forKey: key(url) as NSString) }

    /// 原始字节（给取主色用）：磁盘 → 网络
    func data(_ url: URL) async -> Data? {
        let k = key(url)
        let file = directory.appendingPathComponent(k)
        if let d = try? Data(contentsOf: file) { return d }
        _ = await image(url)
        return try? Data(contentsOf: file)
    }

    /// 内存 → 磁盘 → 网络；同一个地址同时只下一次
    func image(_ url: URL) async -> UIImage? {
        let k = key(url)
        if let hit = memory.object(forKey: k as NSString) { return hit }
        lock.lock()
        if let t = inflight[k] { lock.unlock(); return await t.value }
        let task = Task.detached(priority: .userInitiated) { [self] () -> UIImage? in
            let file = directory.appendingPathComponent(k)
            var bytes = try? Data(contentsOf: file)
            if bytes != nil {
                // 摸一下修改时间，超限清理时按「最久没用」删
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            } else {
                var req = URLRequest(url: url)
                req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                if let (d, resp) = try? await session.data(for: req),
                   (resp as? HTTPURLResponse)?.statusCode == 200, !d.isEmpty {
                    bytes = d
                    try? d.write(to: file, options: .atomic)
                }
            }
            guard let bytes, let img = UIImage(data: bytes) else { return nil }
            // 提前解码，滚动时不卡主线程
            let ready = img.preparingForDisplay() ?? img
            let cost = Int(ready.size.width * ready.size.height * ready.scale * ready.scale * 4)
            memory.setObject(ready, forKey: k as NSString, cost: cost)
            return ready
        }
        inflight[k] = task
        lock.unlock()
        let img = await task.value
        lock.lock(); inflight[k] = nil; lock.unlock()
        return img
    }

    /// 清理：内存 + 磁盘全部
    @discardableResult
    func removeAll() -> Bool {
        memory.removeAllObjects()
        let fm = FileManager.default
        let ok = (try? fm.removeItem(at: directory)) != nil || !fm.fileExists(atPath: directory.path)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return ok
    }

    /// 启动后台：磁盘超过上限就按最久没用的先删，删到上限的 80%
    func trimIfNeeded() {
        Task.detached(priority: .background) { [directory] in
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
            var rows: [(URL, Int64, Date)] = files.compactMap {
                guard let v = try? $0.resourceValues(forKeys: Set(keys)) else { return nil }
                return ($0, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
            }
            var total = rows.reduce(0) { $0 + $1.1 }
            guard total > Self.diskLimit else { return }
            rows.sort { $0.2 < $1.2 }
            for (url, size, _) in rows where total > Self.diskLimit * 8 / 10 {
                if (try? fm.removeItem(at: url)) != nil { total -= size }
            }
        }
    }
}

/// AsyncImage 的替身：内存命中第一帧就出图（不闪占位），否则磁盘 / 网络加载后淡入
struct HGCachedImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var loaded: UIImage?
    @State private var loadedURL: URL?

    var body: some View {
        let now = (loadedURL == url ? loaded : nil) ?? url.flatMap { HGImageCache.shared.cached($0) }
        ZStack {
            if let now {
                Image(uiImage: now).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { loaded = nil; loadedURL = nil; return }
            if HGImageCache.shared.cached(url) != nil { return }
            let img = await HGImageCache.shared.image(url)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { loaded = img; loadedURL = url }
        }
    }
}
