import Foundation
import Observation
import Photos
import AVFoundation

/// 离线下载：解密好的明文 MP4 长期存到 Application Support/Downloads/<剧>/<集>.mp4。
/// 串行下载（一次一集，失败自动重试 2 次），可存相册或导出到「文件」，可把选中集合并成一个 MP4。
@MainActor @Observable
final class HGDownloads {
    static let shared = HGDownloads()

    enum State: Codable, Equatable {
        case queued, downloading(Double), done, failed(String)
        var isDone: Bool { self == .done }
    }

    struct Item: Codable, Identifiable, Equatable {
        let vid: String
        let number: Int
        let seriesID: String
        var state: State
        var bytes: Int64 = 0
        var id: String { vid }
    }

    struct Series: Codable, Identifiable, Equatable {
        let series: HGSeries
        var items: [Item]
        var id: String { series.id }
        var doneCount: Int { items.filter { $0.state.isDone }.count }
        var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    }

    private(set) var all: [Series] = []
    private var worker: Task<Void, Never>?
    private let root: URL
    private let index: URL
    /// 后台 actor 读取用：vid → 本地文件（已完成的）
    private nonisolated(unsafe) static var doneFiles: [String: URL] = [:]
    private static let lock = NSLock()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("Downloads", isDirectory: true)
        index = base.appendingPathComponent("downloads.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var excluded = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        if let data = try? Data(contentsOf: index), let saved = try? JSONDecoder().decode([Series].self, from: data) {
            // 中途被杀的任务重新排队
            all = saved.map { s in var s = s; s.items = s.items.map { var i = $0; if case .downloading = i.state { i.state = .queued }; return i }; return s }
        }
        refreshIndex()
        if all.contains(where: { $0.items.contains { $0.state == .queued } }) { pump() }
    }

    func file(_ seriesID: String, _ vid: String) -> URL {
        root.appendingPathComponent(Self.safe(seriesID), isDirectory: true).appendingPathComponent("\(Self.safe(vid)).mp4")
    }

    private static func safe(_ s: String) -> String { s.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_") }

    nonisolated func localFile(_ vid: String) -> URL? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let url = Self.doneFiles[vid], FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func state(_ vid: String) -> State? {
        for s in all { if let i = s.items.first(where: { $0.vid == vid }) { return i.state } }
        return nil
    }

    // MARK: 操作

    func enqueue(_ series: HGSeries, episodes: [HGEpisode]) {
        var entry = all.first { $0.id == series.id } ?? Series(series: series, items: [])
        for ep in episodes where ep.locked != true && !entry.items.contains(where: { $0.vid == ep.vid }) {
            entry.items.append(Item(vid: ep.vid, number: ep.number, seriesID: series.id, state: .queued))
        }
        for i in entry.items.indices { if case .failed = entry.items[i].state, episodes.contains(where: { $0.vid == entry.items[i].vid }) { entry.items[i].state = .queued } }
        entry.items.sort { $0.number < $1.number }
        if let at = all.firstIndex(where: { $0.id == series.id }) { all[at] = entry } else { all.insert(entry, at: 0) }
        save(); pump()
    }

    func retryFailed(_ seriesID: String) {
        guard let s = all.firstIndex(where: { $0.id == seriesID }) else { return }
        for i in all[s].items.indices { if case .failed = all[s].items[i].state { all[s].items[i].state = .queued } }
        save(); pump()
    }

    func delete(seriesID: String, vids: Set<String>? = nil) {
        guard let s = all.firstIndex(where: { $0.id == seriesID }) else { return }
        let targets = all[s].items.filter { vids == nil || vids!.contains($0.vid) }
        for i in targets { try? FileManager.default.removeItem(at: file(seriesID, i.vid)) }
        all[s].items.removeAll { t in targets.contains { $0.vid == t.vid } }
        if all[s].items.isEmpty {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(Self.safe(seriesID)))
            all.remove(at: s)
        }
        save(); refreshIndex()
    }

    // MARK: 串行下载

    private func pump() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, let (s, i) = self.nextQueued() {
                await self.run(seriesIndex: s, itemIndex: i)
            }
            self?.worker = nil
        }
    }

    private func nextQueued() -> (Int, Int)? {
        for (s, series) in all.enumerated() { if let i = series.items.firstIndex(where: { $0.state == .queued }) { return (s, i) } }
        return nil
    }

    private func run(seriesIndex s: Int, itemIndex i: Int) async {
        let item = all[s].items[i]
        let target = file(item.seriesID, item.vid)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        update(item.vid) { $0.state = .downloading(0) }
        var lastError = "下载失败"
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(Double(attempt) * 3)) }
            do {
                let vid = item.vid
                try await HGMediaCache.shared.fetch(vid: vid, to: target) { phase in
                    if case .downloading(let p) = phase { Task { @MainActor in HGDownloads.shared.update(vid) { $0.state = .downloading(p) } } }
                }
                let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                update(item.vid) { $0.state = .done; $0.bytes = size }
                save(); refreshIndex()
                return
            } catch {
                lastError = error.localizedDescription
                if (error as? HGError)?.code == "UNSUPPORTED_CODEC" || (error as? HGError)?.code == "LOCKED" { break }
            }
        }
        update(item.vid) { $0.state = .failed(lastError) }
        save()
    }

    private func update(_ vid: String, _ change: (inout Item) -> Void) {
        for s in all.indices { if let i = all[s].items.firstIndex(where: { $0.vid == vid }) { change(&all[s].items[i]); return } }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: index, options: .atomic) }
    }

    private func refreshIndex() {
        var map: [String: URL] = [:]
        for s in all { for i in s.items where i.state.isDone { map[i.vid] = file(s.id, i.vid) } }
        Self.lock.lock(); Self.doneFiles = map; Self.lock.unlock()
    }

    // MARK: 导出

    func saveToPhotos(_ urls: [URL]) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw HGError.message("没有相册写入权限") }
        try await PHPhotoLibrary.shared().performChanges {
            for url in urls { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }
        }
    }

    /// 把选中的集按顺序无重编码拼成一个 MP4（同一部剧编码参数一致）。
    func merge(seriesID: String, vids: [String], title: String, progress: @escaping @Sendable (Float) -> Void) async throws -> URL {
        let urls = vids.map { file(seriesID, $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard urls.count >= 2 else { throw HGError.message("至少选择两集已下载的视频") }
        let composition = AVMutableComposition()
        guard let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw HGError.message("无法创建合并轨道")
        }
        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                try v.insertTimeRange(range, of: track, at: cursor)
                if cursor == .zero { v.preferredTransform = try await track.load(.preferredTransform) }
            }
            if let track = try await asset.loadTracks(withMediaType: .audio).first { try a.insertTimeRange(range, of: track, at: cursor) }
            cursor = CMTimeAdd(cursor, duration)
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(title).mp4")
        try? FileManager.default.removeItem(at: out)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw HGError.message("无法导出合并视频")
        }
        let watcher = Task {
            for await state in export.states(updateInterval: 0.3) {
                if case .exporting(let p) = state { progress(Float(p.fractionCompleted)) }
            }
        }
        defer { watcher.cancel() }
        try await export.export(to: out, as: .mp4)
        return out
    }
}
