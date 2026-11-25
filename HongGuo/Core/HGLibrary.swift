import Foundation
import Observation

import CryptoKit

/// 观看记录（断点）/ 收藏 / 点赞，按账号分开存（照绿果TV：每个账号一份本地库，退出就看不到这个账号的）。
/// 未登录 = 「游客」一份；登录哪个红果账号就切到哪个账号那份。存 Application Support 下的 JSON。
@MainActor @Observable
final class HGLibrary {
    static let shared = HGLibrary()
    /// 当前是哪份库：nil = 未登录
    private(set) var accountID: String?

    struct Progress: Codable, Hashable {
        var series: HGSeries
        var episodeIndex: Int
        var position: Double
        var updatedAt: Date
    }

    private(set) var history: [Progress] = []
    private(set) var favorites: [HGSeries] = []
    private(set) var liked: Set<String> = []
    var rate: Float = 1.0 { didSet { UserDefaults.standard.set(rate, forKey: "hg.rate") } }

    private let dir: URL
    private var file: URL
    private var space = "guest"

    private init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("library-guest.json")
        // 旧版本只有一份 library.json（登录前后混在一起）：留给下一个登录的账号认领，游客从空开始
        let legacy = dir.appendingPathComponent("library.json")
        if FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: dir.appendingPathComponent("library-legacy.json"))
            let d = UserDefaults.standard
            if let v = d.array(forKey: "hg.liked") { d.set(v, forKey: "hg.liked.legacy"); d.removeObject(forKey: "hg.liked") }
            if let v = d.data(forKey: "hg.likedSeries") { d.set(v, forKey: "hg.likedSeries.legacy"); d.removeObject(forKey: "hg.likedSeries") }
        }
        // 启动先用上次的那份（账号状态要等 JS 核心起来才知道，避免先闪一下游客的）
        load(UserDefaults.standard.string(forKey: "hg.library.account"))
        let r = UserDefaults.standard.float(forKey: "hg.rate")
        rate = r > 0 ? r : 1.0
    }

    private struct Saved: Codable { var history: [Progress]; var favorites: [HGSeries] }

    /// 登录 / 退出 / 换号时调：切到这个账号的那份库（nil = 游客）
    func switchAccount(_ id: String?) {
        let id = id.flatMap { $0.isEmpty ? nil : $0 }
        guard id != accountID else { return }
        load(id)
        UserDefaults.standard.set(id, forKey: "hg.library.account")
    }

    private func load(_ id: String?) {
        accountID = id
        space = id.map { "a-" + SHA256.hash(data: Data($0.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() } ?? "guest"
        file = dir.appendingPathComponent("library-\(space).json")
        // 第一次登录这个账号：认领旧版本那份混合记录
        let legacy = dir.appendingPathComponent("library-legacy.json")
        if id != nil, !FileManager.default.fileExists(atPath: file.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: file)
            let d = UserDefaults.standard
            if let v = d.array(forKey: "hg.liked.legacy") { d.set(v, forKey: "hg.liked.\(space)"); d.removeObject(forKey: "hg.liked.legacy") }
            if let v = d.data(forKey: "hg.likedSeries.legacy") { d.set(v, forKey: "hg.likedSeries.\(space)"); d.removeObject(forKey: "hg.likedSeries.legacy") }
        }
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            history = saved.history; favorites = saved.favorites
        } else {
            history = []; favorites = []
        }
        liked = Set(UserDefaults.standard.stringArray(forKey: "hg.liked.\(space)") ?? [])
        likedSeries = UserDefaults.standard.data(forKey: "hg.likedSeries.\(space)").flatMap { try? JSONDecoder().decode([HGSeries].self, from: $0) } ?? []
    }

    func progress(for id: String) -> Progress? { history.first { $0.series.id == id } }

    func record(_ series: HGSeries, episode: Int, position: Double) {
        history.removeAll { $0.series.id == series.id }
        history.insert(Progress(series: series, episodeIndex: episode, position: position, updatedAt: Date()), at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        save()
    }

    func removeHistory(_ id: String) { history.removeAll { $0.series.id == id }; save() }

    func isFavorite(_ id: String) -> Bool { favorites.contains { $0.id == id } }

    func toggleFavorite(_ series: HGSeries) {
        if isFavorite(series.id) { favorites.removeAll { $0.id == series.id } } else { favorites.insert(series, at: 0) }
        save()
    }

    func isLiked(_ vid: String) -> Bool { liked.contains(vid) }
    func toggleLike(_ vid: String, series: HGSeries? = nil) {
        if liked.contains(vid) {
            liked.remove(vid)
        } else {
            liked.insert(vid)
            // 「我的 → 点赞」按剧列：点过赞的剧放最前
            if let series { likedSeries.removeAll { $0.id == series.id }; likedSeries.insert(series, at: 0); saveLikedSeries() }
        }
        UserDefaults.standard.set(Array(liked.suffix(5000)), forKey: "hg.liked.\(space)")
    }
    /// 点过赞的剧（新→旧）
    private(set) var likedSeries: [HGSeries] = []
    private func saveLikedSeries() {
        if likedSeries.count > 300 { likedSeries.removeLast(likedSeries.count - 300) }
        if let d = try? JSONEncoder().encode(likedSeries) { UserDefaults.standard.set(d, forKey: "hg.likedSeries.\(space)") }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Saved(history: history, favorites: favorites)) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
