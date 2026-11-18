import Foundation
import Observation

/// 本机观看记录（断点）与收藏，存 Application Support 下的 JSON。
@MainActor @Observable
final class HGLibrary {
    static let shared = HGLibrary()

    struct Progress: Codable, Hashable {
        var series: HGSeries
        var episodeIndex: Int
        var position: Double
        var updatedAt: Date
    }

    private(set) var history: [Progress] = []
    private(set) var favorites: [HGSeries] = []
    private(set) var liked: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hg.liked") ?? [])
    var rate: Float = 1.0 { didSet { UserDefaults.standard.set(rate, forKey: "hg.rate") } }

    private let file: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("library.json")
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            history = saved.history; favorites = saved.favorites
        }
        let r = UserDefaults.standard.float(forKey: "hg.rate")
        rate = r > 0 ? r : 1.0
    }

    private struct Saved: Codable { var history: [Progress]; var favorites: [HGSeries] }

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
    func toggleLike(_ vid: String) {
        if liked.contains(vid) { liked.remove(vid) } else { liked.insert(vid) }
        UserDefaults.standard.set(Array(liked.suffix(5000)), forKey: "hg.liked")
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Saved(history: history, favorites: favorites)) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
