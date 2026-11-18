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
}

struct HGPage: Codable {
    let results: [HGSeries]
    let hasMore: Bool?
    let page: Int?
    let cursor: HGCursor?
}

struct HGCursor: Codable, Hashable {
    let search_id: String?
    let passback: String?
    let next_offset: Int?
}

struct HGEpisode: Codable, Hashable, Identifiable {
    let vid: String
    let number: Int
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
}

enum HGCategory: String, CaseIterable, Identifiable {
    case hot = "hot-drama", real = "real-drama", comic = "comic-drama", ai = "ai-drama", hotReal = "hot-real-drama"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hot: return "热播榜"
        case .real: return "真人剧"
        case .comic: return "漫剧"
        case .ai: return "AI 剧"
        case .hotReal: return "真人热播"
        }
    }
}

/// Swift 侧对 JS 核心的类型化封装。
enum HGAPI {
    static func browse(_ category: HGCategory, page: Int) async throws -> HGPage {
        try HGCore.shared.decode(HGPage.self, try await HGCore.shared.call("browse", [category.rawValue, page]))
    }

    static func search(_ keyword: String, page: Int, cursor: HGCursor?) async throws -> HGPage {
        let c = cursor.flatMap { try? String(decoding: JSONEncoder().encode($0), as: UTF8.self) } ?? ""
        return try HGCore.shared.decode(HGPage.self, try await HGCore.shared.call("search", [keyword, page, c]))
    }

    static func detail(_ seriesID: String) async throws -> HGDetail {
        try HGCore.shared.decode(HGDetail.self, try await HGCore.shared.call("episodes", [seriesID]))
    }

    static func source(_ vid: String) async throws -> HGSource {
        try HGCore.shared.decode(HGSource.self, try await HGCore.shared.call("source", [vid, "auto"]))
    }
}
