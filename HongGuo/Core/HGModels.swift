import Foundation

struct HGSeries: Codable, Identifiable, Hashable {
    let series_id: String
    let series_title: String
    var cover: String?
    var episode_count: Int?
    var description: String?
    var tags: [String]?
    var id: String { series_id }
    var coverURL: URL? { cover.flatMap { $0.isEmpty ? nil : URL(string: $0) } }
    /// 红果之外的来源（西饭 / 河马）编号带前缀；弹幕和热评只有红果有。
    var source: HGSourceKind { HGSourceKind(id: series_id) }

    init(series_id: String, series_title: String, cover: String? = nil, episode_count: Int? = nil, description: String? = nil, tags: [String]? = nil) {
        self.series_id = series_id; self.series_title = series_title; self.cover = cover
        self.episode_count = episode_count; self.description = description; self.tags = tags
    }
}

enum HGSourceKind: String, CaseIterable, Identifiable {
    case hongguo, xifan, hema
    init(id: String) { self = id.hasPrefix("xifan:") ? .xifan : id.hasPrefix("hema:") ? .hema : .hongguo }
    var id: String { rawValue }
    var title: String { switch self { case .hongguo: "红果"; case .xifan: "西饭"; case .hema: "河马" } }
}

struct HGGenre: Codable, Hashable, Identifiable {
    let slug: String
    let label: String
    var id: String { slug }
}

struct HGPage: Codable {
    let results: [HGSeries]
    let hasMore: Bool?
    let page: Int?
    let cursor: HGCursor?
    let genres: [HGGenre]?
}

struct HGCursor: Codable, Hashable {
    let search_id: String?
    let passback: String?
    let next_offset: Int?
}

struct HGEpisode: Codable, Hashable, Identifiable {
    let vid: String
    let number: Int
    var locked: Bool?
    var id: String { vid }
}

struct HGDetail: Codable, Hashable {
    let series_id: String
    let series_title: String
    let cover: String?
    let description: String?
    let episodes: [HGEpisode]
}

struct HGVariant: Codable, Hashable {
    let url: String
    let contentKey: String?
    let codec: String
    let quality: String
    let userAgent: String
    let referer: String
}

struct HGSource: Codable {
    let vid: String
    let variants: [HGVariant]
    var width: Int?
    var height: Int?
    /// 片源宽高（取源接口给的，不用下载）；拿不到时 nil
    var isLandscape: Bool? {
        guard let w = width, let h = height, w > 0, h > 0 else { return nil }
        return w > h
    }
}

struct HGDanmakuItem: Codable {
    let time: Double
    let text: String
    let color: String?
    let mode: String?
}

struct HGReview: Codable, Hashable, Identifiable {
    let author: String
    let avatar: String?
    let content: String
    let created_at: Double?
    let likes: Int?
    var id: String { "\(author)|\(created_at ?? 0)|\(content.prefix(24))" }
}

struct HGComments: Codable {
    let total: Int?
    let items: [HGReview]
    let episodeLikes: Int?
    let favorites: Int?
}

struct HGEpisodeStat: Codable, Hashable { let vid: String; let comments: Int?; let likes: Int? }
struct HGSeriesStats: Codable { let follows: Int?; let plays: Int?; let episodes: [HGEpisodeStat] }

struct HGAccountProfile: Codable, Hashable { let id: String; let nickname: String }
struct HGAccountStatus: Codable { let signedIn: Bool; let account: HGAccountProfile? }
struct HGQRLogin: Codable { let loginId: String; let image: String; let expiresIn: Int }
struct HGQRPoll: Codable { let status: String?; let signedIn: Bool?; let error: String? }

struct HGCloudHistoryRow: Codable, Hashable, Identifiable {
    let series_id: String
    let series_title: String
    let cover: String?
    let episode_id: String
    let vid_index: Int
    let currentTime: Double
    let total: Int?
    var id: String { series_id }
    var series: HGSeries { HGSeries(series_id: series_id, series_title: series_title, cover: cover, episode_count: total) }
}

struct HGCloudHistory: Codable { let results: [HGCloudHistoryRow]? }

enum HGCategory: String, CaseIterable, Identifiable {
    case hot = "hot-drama", real = "real-drama", comic = "comic-drama", ai = "ai-drama", hotReal = "hot-real-drama"
    case xifan = "xifan", hema = "hema"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hot: return "热播榜"
        case .real: return "真人剧"
        case .comic: return "漫剧"
        case .ai: return "AI 剧"
        case .hotReal: return "真人热播"
        case .xifan: return "西饭"
        case .hema: return "河马"
        }
    }
    /// 只有红果分类页返回题材筛选
    var supportsGenres: Bool { [.real, .comic, .ai].contains(self) }
}

/// Swift 侧对 JS 核心的类型化封装。
enum HGAPI {
    private static var core: HGCore { HGCore.shared }

    static func browse(_ category: HGCategory, page: Int, genre: String = "") async throws -> HGPage {
        try core.decode(HGPage.self, try await core.call("browse", [category.rawValue, page, genre]))
    }

    static func search(_ keyword: String, source: HGSourceKind, page: Int, cursor: HGCursor?) async throws -> HGPage {
        let c = cursor.flatMap { try? String(decoding: JSONEncoder().encode($0), as: UTF8.self) } ?? ""
        return try core.decode(HGPage.self, try await core.call("search", [keyword, page, c, source.rawValue]))
    }

    static func detail(_ seriesID: String) async throws -> HGDetail {
        try core.decode(HGDetail.self, try await core.call("episodes", [seriesID]))
    }

    static func source(_ vid: String) async throws -> HGSource {
        try core.decode(HGSource.self, try await core.call("source", [vid, "auto"]))
    }

    /// 一个时间窗的弹幕；next = 下一窗的起点（毫秒），nil = 没有了。
    static func danmaku(series: String, vid: String, startMs: Int, durationMs: Int) async throws -> (items: [DYDanmaku], next: Int?) {
        struct R: Codable { let items: [HGDanmakuItem]; let next: Int? }
        let r = try core.decode(R.self, try await core.call("danmaku", [series, vid, startMs, durationMs]))
        let items = r.items.enumerated().map { i, d in DYDanmaku(id: "\(vid)-\(i)-\(Int(d.time * 1000))", text: d.text, offset: d.time) }
        return (items, r.next)
    }

    static func comments(series: String, vid: String) async throws -> HGComments {
        try core.decode(HGComments.self, try await core.call("comments", [series, vid]))
    }

    static func stats(series: String) async throws -> HGSeriesStats {
        try core.decode(HGSeriesStats.self, try await core.call("stats", [series]))
    }

    static func resolveShare(_ text: String) async throws -> String {
        struct R: Codable { let series_id: String }
        return try core.decode(R.self, try await core.call("resolveShare", [text])).series_id
    }

    static func accountStatus() async throws -> HGAccountStatus { try core.decode(HGAccountStatus.self, try await core.call("accountStatus", [])) }
    static func startLogin() async throws -> HGQRLogin { try core.decode(HGQRLogin.self, try await core.call("accountStartLogin", [])) }
    static func pollLogin(_ id: String) async throws -> HGQRPoll { try core.decode(HGQRPoll.self, try await core.call("accountPollLogin", [id])) }
    static func cancelLogin(_ id: String) async { _ = try? await core.call("accountCancelLogin", [id]) }
    static func logout() async throws { _ = try await core.call("accountLogout", []) }
    static func cloudHistory(refresh: Bool) async throws -> [HGCloudHistoryRow] {
        try core.decode(HGCloudHistory.self, try await core.call("accountHistory", [refresh])).results ?? []
    }
}
