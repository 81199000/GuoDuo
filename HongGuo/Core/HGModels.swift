import Foundation

struct HGSeries: Codable, Identifiable, Hashable {
    let series_id: String
    let series_title: String
    var cover: String?
    var episode_count: Int?
    var description: String?
    var tags: [String]?
    /// 榜单名次（只有榜单里有）
    var rank: Int? = nil
    /// 播放量（榜单 / 找剧带回）
    var plays: Int? = nil
    /// 封面左下角：「4381万热度」「共62万人在追」「3805万期待」（官方卡片同款，服务端给的原文）
    var heat: String? = nil
    /// 「爆剧」「新剧」「爆款新剧」等运营角标
    var badge: String? = nil
    /// 预约中（还没上线，不能播）
    var upcoming: Bool? = nil
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
    /// 片源画幅（取源就带回来，不用下载）；接口没给宽高时 nil
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
    var items: [HGReview]
    var episodeLikes: Int? = nil
    var favorites: Int? = nil
    /// App 接口才有：翻页
    var next: Int? = nil
    var hasMore: Bool? = nil
    /// 新接口（登录后，真昵称）的翻页游标
    var cursor: String? = nil
}

struct HGEpisodeStat: Codable, Hashable { let vid: String; let comments: Int?; let likes: Int? }
struct HGSeriesStats: Codable { let follows: Int?; let plays: Int?; let episodes: [HGEpisodeStat] }

struct HGAccountProfile: Codable, Hashable { let id: String; let nickname: String }
struct HGAccountStatus: Codable { let signedIn: Bool; let account: HGAccountProfile? }
struct HGQRLogin: Codable { let loginId: String; let image: String; let expiresIn: Int }
struct HGPhoneStep: Codable { let state: String; var number: String? = nil; var content: String? = nil }
struct HGQRPoll: Codable { let status: String?; let signedIn: Bool?; let error: String? }

struct HGCloudHistoryRow: Codable, Hashable, Identifiable {
    let series_id: String
    let series_title: String
    let cover: String?
    let episode_id: String
    let vid_index: Int
    let currentTime: Double
    let total: Int?
    /// 最后观看时间（毫秒）；旧接口没有
    var updatedAt: Double? = nil
    var id: String { series_id }
    var series: HGSeries { HGSeries(series_id: series_id, series_title: series_title, cover: cover, episode_count: (total ?? 0) > 0 ? total : nil) }
}

struct HGCloudHistory: Codable { let results: [HGCloudHistoryRow]? }

/// 红果首页「推荐」一页：登录了是账号个性化推荐（personal）；next / session 续页
struct HGForYouPage: Codable {
    let results: [HGSeries]
    let next: Int
    let session: String
    let hasMore: Bool
    let personal: Bool?
}

/// 官方榜单目录：分区（全部 / 真人剧 / 漫剧 / AI 剧 / 系列剧）→ 各自的榜
struct HGRankBoard: Codable, Hashable, Identifiable { let id: String; let name: String }
struct HGRankZone: Codable, Hashable, Identifiable { let id: String; let name: String; let boards: [HGRankBoard] }
struct HGRankPage: Codable {
    let results: [HGSeries]
    let next: Int
    let session: String
    let hasMore: Bool
    let zones: [HGRankZone]?
}

/// 找剧筛选：一组（类型 / 排序 / 上新 / 题材 / 人设 / 背景 / 频道）
struct HGFindOption: Codable, Hashable, Identifiable { let id: String; let name: String }
struct HGFindFilter: Codable, Hashable, Identifiable {
    let type: String
    let name: String
    let items: [HGFindOption]
    var id: String { type }
}
struct HGFindPage: Codable {
    let results: [HGSeries]
    let next: Int
    let session: String
    let hasMore: Bool
    let filters: [HGFindFilter]?
}

/// 详情补充：播放 / 在追 / 热度、角标、题材、演员、第几季、完结状态、系列编号
struct HGSeriesInfo: Codable, Hashable {
    let plays: Int?
    let followers: Int?
    let heat: Int?
    let badge: String?
    let tags: [String]?
    let actors: String?
    let season: Int?
    let status: String?
    let album: String?
}
/// 系列剧的一季
struct HGSeason: Codable, Hashable, Identifiable {
    let season: Int
    let series_id: String
    let series_title: String
    let cover: String?
    let episode_count: Int?
    var id: String { series_id }
    var series: HGSeries { HGSeries(series_id: series_id, series_title: series_title, cover: cover, episode_count: episode_count) }
}
struct HGSeasons: Codable { let results: [HGSeason]; let album: String? }
/// 剧评（整部剧）
struct HGSeriesReview: Codable, Hashable, Identifiable {
    let id: String
    let author: String
    let avatar: String?
    let content: String
    let created_at: Double?
    let likes: Int?
    let score: Int?
}
struct HGSeriesReviews: Codable { let items: [HGSeriesReview]; let total: Int; let next: Int; let hasMore: Bool }

/// 红果账号资料（「我的」顶部）
struct HGAccountInfo: Codable, Hashable {
    let signedIn: Bool
    var uid: String? = nil
    var name: String? = nil
    var avatar: String? = nil
    var signature: String? = nil
    var vip: Bool? = nil
    var watchMinutes: Int? = nil
    var activeDays: Int? = nil
    var follows: Int? = nil
    var fans: Int? = nil
    var likes: Int? = nil
}
struct HGReservations: Codable { let results: [HGSeries] }

/// 红果 App 云端收藏（追剧书架）
struct HGCloudFavorite: Codable, Hashable {
    let series_id: String
    let series_title: String
    let cover: String?
    let episode_count: Int?
    var series: HGSeries { HGSeries(series_id: series_id, series_title: series_title, cover: cover, episode_count: (episode_count ?? 0) > 0 ? episode_count : nil) }
}
struct HGCloudFavorites: Codable { let results: [HGCloudFavorite]? }

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

    static func comments(series: String, vid: String, offset: Int = 0, cursor: String? = nil) async throws -> HGComments {
        try core.decode(HGComments.self, try await core.call("comments", [series, vid, offset, cursor ?? ""]))
    }

    /// 发评论（挂整部剧，带当前集）/ 发弹幕（这一集这个时间点）；要登录
    static func postComment(series: String, vid: String, text: String) async throws {
        _ = try await core.call("postComment", [series, vid, text])
    }
    static func postDanmaku(series: String, vid: String, text: String, offsetMs: Int) async throws {
        _ = try await core.call("postDanmaku", [series, vid, text, offsetMs])
    }

    static func stats(series: String) async throws -> HGSeriesStats {
        try core.decode(HGSeriesStats.self, try await core.call("stats", [series]))
    }

    static func resolveShare(_ text: String) async throws -> String {
        struct R: Codable { let series_id: String }
        return try core.decode(R.self, try await core.call("resolveShare", [text])).series_id
    }

    static func accountStatus() async throws -> HGAccountStatus {
        let st = try core.decode(HGAccountStatus.self, try await core.call("accountStatus", []))
        // 观看记录 / 收藏 / 点赞按账号分开：状态一出来就切到这个账号那份（没登录 = 游客那份）
        await MainActor.run { HGLibrary.shared.switchAccount(st.signedIn ? st.account?.id : nil) }
        return st
    }
    static func startLogin() async throws -> HGQRLogin { try core.decode(HGQRLogin.self, try await core.call("accountStartLogin", [])) }
    static func pollLogin(_ id: String) async throws -> HGQRPoll { try core.decode(HGQRPoll.self, try await core.call("accountPollLogin", [id])) }
    static func cancelLogin(_ id: String) async { _ = try? await core.call("accountCancelLogin", [id]) }
    /// 手机号登录：发验证码
    static func phoneSend(_ phone: String) async throws { _ = try await core.call("accountPhoneSend", [phone]) }
    /// 手机号登录：验证码登录 / 上行短信验证后确认（state: ok / mfa / pending / cancelled）
    static func phoneLogin(_ code: String) async throws -> HGPhoneStep { try core.decode(HGPhoneStep.self, try await core.call("accountPhoneLogin", [code])) }
    static func phoneVerify() async throws -> HGPhoneStep { try core.decode(HGPhoneStep.self, try await core.call("accountPhoneVerify", [])) }
    static func phoneCancel() async { _ = try? await core.call("accountPhoneCancel", []) }
    static func logout() async throws {
        _ = try await core.call("accountLogout", [])
        await MainActor.run { HGLibrary.shared.switchAccount(nil) }
    }
    static func cloudHistory(refresh: Bool) async throws -> [HGCloudHistoryRow] {
        try core.decode(HGCloudHistory.self, try await core.call("accountHistory", [refresh])).results ?? []
    }
    /// 完整云端观看记录（分页拉完，最新在前）
    static func cloudHistoryAll() async throws -> [HGCloudHistoryRow] {
        try core.decode(HGCloudHistory.self, try await core.call("accountHistoryAll", [])).results ?? []
    }
    static func cloudFavorites() async throws -> [HGCloudFavorite] {
        try core.decode(HGCloudFavorites.self, try await core.call("accountFavorites", [])).results ?? []
    }
    static func rank(zone: String, board: String, offset: Int, session: String) async throws -> HGRankPage {
        try core.decode(HGRankPage.self, try await core.call("rank", [zone, board, offset, session]))
    }
    static func find(_ select: [String: String], offset: Int, session: String) async throws -> HGFindPage {
        let json = (try? String(decoding: JSONEncoder().encode(select), as: UTF8.self)) ?? "{}"
        return try core.decode(HGFindPage.self, try await core.call("find", [json, offset, session]))
    }
    /// 红果首页推荐流；登录了带账号 cookie
    static func suggest(_ q: String) async throws -> [String] {
        struct R: Codable { let results: [String] }
        return try core.decode(R.self, try await core.call("suggest", [q])).results
    }
    static func seriesInfo(_ sid: String) async throws -> HGSeriesInfo { try core.decode(HGSeriesInfo.self, try await core.call("seriesInfo", [sid])) }
    static func seasons(_ sid: String, album: String?) async throws -> HGSeasons {
        try core.decode(HGSeasons.self, try await core.call("seasons", [sid, album ?? ""]))
    }
    static func reviews(_ sid: String, offset: Int) async throws -> HGSeriesReviews {
        try core.decode(HGSeriesReviews.self, try await core.call("reviews", [sid, offset]))
    }
    static func accountInfo() async throws -> HGAccountInfo { try core.decode(HGAccountInfo.self, try await core.call("accountProfile", [])) }
    static func reservations() async throws -> [HGSeries] { try core.decode(HGReservations.self, try await core.call("accountReservations", [])).results }
    /// 登录保活；回 true = 仍登录
    @discardableResult static func keepAlive() async -> Bool {
        struct R: Codable { let signedIn: Bool }
        return (try? core.decode(R.self, try await core.call("accountKeepAlive", [])))?.signedIn ?? false
    }
    /// channel：16 推荐 / 39 真人剧 / 36 漫剧
    static func forYou(offset: Int, session: String, channel: String = "16") async throws -> HGForYouPage {
        try core.decode(HGForYouPage.self, try await core.call("forYou", [offset, session, channel]))
    }
}
