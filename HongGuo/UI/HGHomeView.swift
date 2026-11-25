import SwiftUI
import CoreImage
import UIKit

// 奈飞式首页（老板 2026-11-25 截图为准）：
// 顶部「logo + 首页」大标题 + 玻璃圆角药丸分类（真人剧 / 漫剧 / AI剧 / 系列剧 / 类别 ▾），滚动后顶栏垫磨砂；
// 大海报卡（取封面主色给整页染底色）+ 播放 / 追剧；下面一行一类左右滑：继续观看、我的追剧、Top 10（描边大数字）、各榜单。
// 纯黑底、海报小圆角、行标题加粗、海报底部红白角标、TOP 10 角标；数据全部来自红果榜单接口，滑到哪行才拉哪行。
// 跟红果版首页（旧发现页）在「我的 → 设置 → 首页主题」里切换。

enum HGHomeStyle: String {
    case netflix, classic
    static let key = "hg.home.style.v1"
}

struct HGHomeRow: Identifiable, Hashable {
    enum Kind { case poster, top10, upcoming }
    let zone: String
    let board: String
    let title: String
    let kind: Kind
    var id: String { "\(zone)|\(board)" }
}

/// 各行数据（按 分区|榜 缓存；滑回来不重拉）
@MainActor @Observable final class HGHomeModel {
    static let shared = HGHomeModel()
    var zones: [HGRankZone] = []
    var rows: [String: [HGSeries]] = [:]
    var failed: Set<String> = []
    /// 西饭 / 河马的题材（browse 带回来），它们没有红果的榜单目录，首页按题材一行一行排
    var sourceGenres: [String: [HGGenre]] = [:]
    @ObservationIgnored private var inflight: Set<String> = []

    func load(_ zone: String, _ board: String, force: Bool = false) async {
        let k = "\(zone)|\(board)"
        guard force || rows[k] == nil, !inflight.contains(k) else { return }
        inflight.insert(k); defer { inflight.remove(k) }
        do {
            if let src = HGHomeView.otherSource(zone) {
                // 西饭 / 河马：board = 题材 slug（空 = 默认题材）
                let r = try await HGAPI.browse(src, page: 1, genre: board)
                if let g = r.genres, !g.isEmpty { sourceGenres[zone] = g }
                rows[k] = r.results
                failed.remove(k)
                return
            }
            let r = try await HGAPI.rank(zone: zone, board: board, offset: 0, session: "")
            if let z = r.zones, !z.isEmpty { zones = z }
            rows[k] = r.results
            failed.remove(k)
        } catch {
            failed.insert(k)
        }
    }

    /// 热播榜前 10：海报左上角挂 TOP 10
    var top10: Set<String> { Set((rows["all|ranklist_hot_play_sc"] ?? []).prefix(10).map(\.id)) }
}

struct HGHomeView: View {
    /// 分区（空 = 全部）。2026-11-26 老板：AI剧 / 系列剧放回顶部，再加西饭 / 河马；
    /// 顶部按屏宽自适应——放得下几个摆几个，放不下的从后往前收进「类别」菜单最底下（`fittingPills`）
    static let zoneChips: [(id: String, name: String, genre: String)] = [
        ("human", "真人剧", "short_play"), ("comic_series_rank", "漫剧", "comic_series"),
        ("ai_playlet", "AI剧", "ai_series"), ("series_album", "系列剧", "short_play"),
        ("xifan", "西饭", ""), ("hema", "河马", ""),
    ]
    /// 西饭 / 河马是另外的片源（不走红果榜单）
    static func otherSource(_ zone: String) -> HGCategory? { zone == "xifan" ? .xifan : zone == "hema" ? .hema : nil }
    /// 菜单里收起来的分区的图标 / 说明
    static func zoneInfo(_ id: String) -> (icon: String, note: String) {
        switch id {
        case "human": ("person.2.fill", "真人出演的短剧")
        case "comic_series_rank": ("paintpalette.fill", "动画 / 漫画短剧")
        case "ai_playlet": ("sparkles", "AI 生成的短剧")
        case "series_album": ("square.stack.3d.up", "一部剧多季连播")
        case "xifan": ("play.square.stack", "西饭短剧片源")
        default: ("play.rectangle.on.rectangle", "河马短剧片源")
        }
    }
    /// 顶部一行能放几个分区药丸：可用宽度 − 「类别」药丸，按字宽逐个累加，放不下的进菜单
    static func fittingPills(width: CGFloat) -> Int {
        let font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .medium)
        let pill = { (t: String) -> CGFloat in ceil((t as NSString).size(withAttributes: [.font: font]).width) + 32 }
        var used = pill("类别") + 16 + pill("全部") + 8   // 类别（+ 箭头）+ 最前面的「全部」
        var n = 0
        for c in zoneChips {
            let w = pill(c.name) + 8
            if used + w > width { break }
            used += w; n += 1
        }
        return n
    }
    struct FindRoute: Hashable { let title: String; let preset: [String: String] }

    @State private var model = HGHomeModel.shared
    @State private var library = HGLibrary.shared
    @AppStorage("hg.home.zone") private var zone = ""
    @State private var themes: [String: [HGFindOption]] = [:]
    @State private var heroTint: Color = .black
    @State private var scrolled = false
    @State private var cloud: [HGCloudHistoryRow] = []
    @State private var cloudFavorites: [HGSeries] = []
    @State private var playing: HGPlayerRequest?
    @State private var find: FindRoute?
    @State private var openSeries: HGSeries?

    /// 顶栏离屏幕上沿（整页忽略顶部安全区，自己算）。
    /// Duo 展开：照老板 11-25 奈飞截图实测（截图短边 900px ≈ 内屏短边 1003pt）——N 标志竖屏 49～94pt、横屏 47～90pt，
    /// 中线都在约 70pt，跟右上角时间同一行；我们 logo 行高约 34pt → 行顶 53pt，竖横屏一样（不跟系统安全区走）。
    /// 外屏：保持原位（按系统安全区）；其它设备按系统安全区
    static func topInset(width: CGFloat, safeTop: CGFloat) -> CGFloat {
        guard DYDuoMetrics.isDuoHardware else { return safeTop }
        // 外屏：老板 11-25 嫌 logo 太贴顶 → 往下半个图标（logo 高 30 → 15pt）
        return width >= 600 ? 53 : safeTop + 15
    }
    /// 往下滑分类药丸那行弹上去收起，往上滑弹回来（奈飞同款）
    @State private var chipsHidden = false
    @State private var lastY: CGFloat = 0
    @State private var headerH: CGFloat = 110

    private var zoneName: String? { Self.zoneChips.first { $0.id == zone }?.name }
    private var genre: String { (Self.zoneChips.first { $0.id == zone }?.genre).flatMap { $0.isEmpty ? nil : $0 } ?? "short_play" }
    @State private var pillCount = 2
    @State private var sourceGenre: HGGenreRoute?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let posterW: CGFloat = w < 600 ? 110 : 132
            let top = Self.topInset(width: w, safeTop: geo.safeAreaInsets.top)
          ZStack(alignment: .top) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    hero(width: w < 600 ? min(w - 32, 520) : w - 32, wide: w >= 600)
                        .padding(.horizontal, 16)
                    if zone.isEmpty {
                        continueRow(posterW)
                        favoritesRow(posterW)
                    }
                    ForEach(rows) { r in
                        HGHomeRowView(row: r, posterW: posterW, model: model)
                    }
                }
                // 内容从顶栏（展开态）下面开始；顶栏收起时内容不跟着跳
                .padding(.top, headerH + 4)
                .padding(.bottom, 32)
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in
                scrollMoved(y)
            }
            .refreshable { await refresh() }
            // 顶栏浮在内容上面（不占位）：药丸收起只是顶栏自己动
            header(top: top)
                .onAppear { pillCount = Self.fittingPills(width: w - 32) }
                .onChange(of: w) { _, nw in withAnimation(.snappy) { pillCount = Self.fittingPills(width: nw - 32) } }
          }
          // Duo：右上角 / 右侧是信号时间，左上是空的 → 整页不让顶部安全区，顶栏位置自己按 topInset 算
          .ignoresSafeArea(.container, edges: .top)
            .background {
                ZStack {
                    Color.black
                    // 大海报主色从顶上铺下来，往下渐黑（奈飞首页同款）；滚走后淡掉
                    LinearGradient(stops: [.init(color: heroTint, location: 0), .init(color: .black, location: 0.7)],
                                   startPoint: .top, endPoint: .bottom)
                        .opacity(scrolled ? 0.35 : 1)
                }
                .ignoresSafeArea()
            }
        }
        // 标题自己画（logo + 首页）；搜索在标签栏胶囊里，导航栏整条不要
        .toolbarVisibility(.hidden, for: .navigationBar)
        // 工具键（搜索 / 链接）白色，同奈飞投屏 / 下载 / 通知那组；页面里的红色角标是写死的主题色，不受影响
        .tint(.white)
        .navigationTitle("首页")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: zone) { await loadHero() }
        .task(id: genre) { await loadThemes() }
        .task { await loadAccountShelves() }
        .navigationDestination(item: $openSeries) { HGDetailView(series: $0) }
        .navigationDestination(item: $find) { HGFindScreen(title: $0.title, preset: $0.preset) }
        .navigationDestination(item: $sourceGenre) { HGSourceGenreScreen(route: $0) }
        .fullScreenCover(item: $playing) { HGPlayerScreen(request: $0) }
    }

    // MARK: 顶部

    private func header(top: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: chipsHidden ? 0 : 10) {
            HStack(spacing: 10) {
                Image("AppLogo").resizable().scaledToFit().frame(height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(zoneName ?? "GuoDuo").font(.system(size: 28, weight: .bold)).foregroundStyle(.white)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // 2026-11-26 老板：选了分区不再把别的藏起来，只把选中的那个字变主题色；最前面加「全部」
                    chip("全部", on: zone.isEmpty) { withAnimation(.snappy) { zone = "" } }
                    ForEach(Self.zoneChips.prefix(pillCount), id: \.id) { c in
                        chip(c.name, on: zone == c.id) { withAnimation(.snappy) { zone = c.id } }
                    }
                    categoryMenu
                }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            // 往下滑：整行往上弹进标题行后面、淡出，高度收成 0（顶栏底色跟着变矮）
            .frame(height: chipsHidden ? 0 : 36, alignment: .top)
            .offset(y: chipsHidden ? -24 : 0)
            .opacity(chipsHidden ? 0 : 1)
            .clipped()
            .allowsHitTesting(!chipsHidden)
        }
        .padding(.horizontal, 16)
        .padding(.top, top)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
            // 只记药丸展开时的高度：内容顶边按它留，收起时内容不跳
            if !chipsHidden { headerH = h }
        }
        .background {
            // 滚起来后顶栏垫深灰底（奈飞截图实测 RGB 35,35,35），海报从底下穿过
            Rectangle().fill(Color(white: 0.137).opacity(0.97)).opacity(scrolled ? 1 : 0)
                .ignoresSafeArea(edges: [.top, .horizontal])
        }
    }

    /// 滚动方向判断：下滑超过 10pt 收药丸，上滑超过 10pt 弹回；回到顶部一定展开
    private func scrollMoved(_ y: CGFloat) {
        let bounce = Animation.spring(response: 0.34, dampingFraction: 0.62)
        if (y > 12) != scrolled { withAnimation(.easeOut(duration: 0.2)) { scrolled = y > 12 } }
        if y < 40 {
            if chipsHidden { withAnimation(bounce) { chipsHidden = false } }
            lastY = y
            return
        }
        let d = y - lastY
        if d > 10 {
            if !chipsHidden { withAnimation(bounce) { chipsHidden = true } }
            lastY = y
        } else if d < -10 {
            if chipsHidden { withAnimation(bounce) { chipsHidden = false } }
            lastY = y
        }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(on ? .bold : .medium)).foregroundStyle(on ? HGTheme.accent : .white)
                .padding(.horizontal, 16).frame(height: 36)
                .hgGlassPill(12)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("hg.home.chip.\(title)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var categoryMenu: some View {
        Menu {
            if let src = Self.otherSource(zone) {
                // 西饭 / 河马：题材是它们自己的（点了进该片源该题材的列表）
                Section("题材") {
                    ForEach(model.sourceGenres[zone] ?? []) { g in
                        Button(g.label) { sourceGenre = HGGenreRoute(source: src, genre: g) }
                    }
                    if (model.sourceGenres[zone] ?? []).isEmpty { Text("分类加载中…") }
                }
            } else {
                Section("题材") {
                    ForEach(themes[genre] ?? []) { t in
                        Button(t.name) { find = FindRoute(title: t.name, preset: ["genre": genre, "category_dim_theme": t.id]) }
                    }
                    if (themes[genre] ?? []).isEmpty { Text("分类加载中…") }
                }
            }
            // 顶部放不下的分区（按屏宽自适应）：放最底下，单独一组 + 图标 + 说明
            let hidden = Array(Self.zoneChips.dropFirst(pillCount))
            if !hidden.isEmpty {
                Section("更多分区") {
                    ForEach(hidden, id: \.id) { c in
                        let info = Self.zoneInfo(c.id)
                        Button { withAnimation(.snappy) { zone = c.id } } label: {
                            Image(systemName: zone == c.id ? "checkmark" : info.icon)
                            Text(c.name)
                            Text(info.note)
                        }
                        .accessibilityIdentifier("hg.home.zone.\(c.name)")
                    }
                }
            }
        } label: {
            let inMenu = Self.zoneChips.dropFirst(pillCount).first { $0.id == zone }
            HStack(spacing: 6) {
                Text(inMenu?.name ?? "类别").font(.subheadline.weight(inMenu != nil ? .bold : .medium))
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .foregroundStyle(inMenu != nil ? HGTheme.accent : .white)
            .padding(.horizontal, 16).frame(height: 36)
            .hgGlassPill(12)
        }
        .accessibilityIdentifier("hg.home.category")
    }

    // MARK: 大海报

    private var heroBoard: String {
        if zone.isEmpty { return "ranklist_hot_sc" }
        if Self.otherSource(zone) != nil { return "" }
        return model.zones.first { $0.id == zone }?.boards.first { $0.name == "推荐榜" }?.id
            ?? HGRankScreen.defaultBoard(zone)
    }

    @ViewBuilder private func hero(width: CGFloat, wide: Bool) -> some View {
        let key = "\(zone.isEmpty ? "all" : zone)|\(heroBoard)"
        if let s = model.rows[key]?.first {
            Group {
                if wide { HGWideHeroCard(series: s, width: width, play: { Task { await play(s) } }, open: { openSeries = s }) }
                else { HGHeroCard(series: s, width: width, play: { Task { await play(s) } }, open: { openSeries = s }) }
            }
                .task(id: s.id) {
                    if let url = s.coverURL, let c = await HGHeroTint.color(url) {
                        withAnimation(.easeOut(duration: 0.4)) { heroTint = c }
                    }
                }
                .accessibilityIdentifier("hg.home.hero")
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06))
                .frame(width: width, height: wide ? HGWideHeroCard.height(width) : width / 0.82)
                .overlay { if model.failed.contains(key) { Button("加载失败，点我重试") { Task { await loadHero() } } } else { ProgressView() } }
        }
    }

    // MARK: 继续观看 / 我的追剧

    private var continueItems: [HGCloudHistoryRow] {
        let local = library.history.map { p in
            HGCloudHistoryRow(series_id: p.series.id, series_title: p.series.series_title, cover: p.series.cover,
                              episode_id: "", vid_index: p.episodeIndex + 1, currentTime: p.position,
                              total: p.series.episode_count, updatedAt: p.updatedAt.timeIntervalSince1970 * 1000)
        }
        var best: [String: HGCloudHistoryRow] = [:]
        for r in cloud + local {
            if let old = best[r.series_id], (old.updatedAt ?? 0) >= (r.updatedAt ?? 0) {
                if (old.cover ?? "").isEmpty, let c = r.cover, !c.isEmpty { best[r.series_id] = old.with(cover: c) }
                continue
            }
            best[r.series_id] = r
        }
        return Array(best.values.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }.prefix(20))
    }

    @ViewBuilder private func continueRow(_ posterW: CGFloat) -> some View {
        let items = continueItems
        if !items.isEmpty {
            HGHomeShelf(title: "继续观看", id: "continue") {
                ForEach(items) { r in
                    Button { Task { await resume(r) } } label: { HGContinueCard(row: r, width: posterW) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private func favoritesRow(_ posterW: CGFloat) -> some View {
        let items: [HGSeries] = {
            var seen = Set<String>()
            return (library.favorites + cloudFavorites).filter { seen.insert($0.id).inserted }
        }()
        if !items.isEmpty {
            HGHomeShelf(title: "我的追剧", id: "favorites", all: { AnyView(HGSeriesListScreen(title: "我的追剧", kind: .favorites)) }) {
                ForEach(items) { s in
                    NavigationLink(value: s) { HGPoster(series: s, width: posterW, top10: model.top10.contains(s.id)) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 各行

    private var rows: [HGHomeRow] {
        if zone.isEmpty {
            return [
                .init(zone: "all", board: "ranklist_hot_play_sc", title: "今日热播 Top 10", kind: .top10),
                .init(zone: "all", board: "ranklist_hot_sc", title: "为你推荐", kind: .poster),
                .init(zone: "all", board: "ranklist_new_rank_sc", title: "新剧上线", kind: .poster),
                .init(zone: "all", board: "ranklist_must_watch", title: "口碑必看", kind: .poster),
                .init(zone: "comic_series_rank", board: "comic_series_hot_rank", title: "漫剧推荐", kind: .poster),
                .init(zone: "all", board: "ranklist_hot_search_sc", title: "大家都在搜", kind: .poster),
                .init(zone: "human", board: "human_hot_play", title: "真人剧热播", kind: .poster),
                .init(zone: "all", board: "ranklist_chase_update", title: "正在追更", kind: .poster),
                .init(zone: "series_album", board: "series_album_new_rank", title: "系列剧新季", kind: .poster),
                .init(zone: "ai_playlet", board: "ai_playlet_hot_sc", title: "AI剧推荐", kind: .poster),
                .init(zone: "all", board: "ranklist_followed", title: "收藏最多", kind: .poster),
                .init(zone: "all", board: "ranklist_prestige", title: "臻果精选", kind: .poster),
                .init(zone: "all", board: "ranklist_subscribe", title: "即将上线", kind: .upcoming),
            ]
        }
        // 西饭 / 河马：第一行默认题材（大海报也取它），下面按它们自己的题材一行一个
        if Self.otherSource(zone) != nil {
            let gs = (model.sourceGenres[zone] ?? []).filter { $0.label != "都市" }.prefix(14)
            return [.init(zone: zone, board: "", title: zone == "xifan" ? "都市热播" : "全部短剧", kind: .poster)]
                + gs.map { .init(zone: zone, board: $0.slug, title: $0.label, kind: .poster) }
        }
        // 选了分区：按服务端目录排这个分区的各榜（热播做 Top 10 放最前，预约放最后）
        let name = zoneName ?? ""
        let boards = model.zones.first { $0.id == zone }?.boards ?? []
        func title(_ b: HGRankBoard) -> (String, HGHomeRow.Kind) {
            switch b.name {
            case "热播榜": ("\(name)热播 Top 10", .top10)
            case "推荐榜": ("为你推荐", .poster)
            case "新剧榜": ("新剧上线", .poster)
            case "新季榜": ("新季上线", .poster)
            case "必看榜": ("口碑必看", .poster)
            case "热搜榜": ("大家都在搜", .poster)
            case "收藏榜": ("收藏最多", .poster)
            case "预约榜": ("即将上线", .upcoming)
            default: (b.name, .poster)
            }
        }
        let all = boards.map { b -> HGHomeRow in let t = title(b); return .init(zone: zone, board: b.id, title: t.0, kind: t.1) }
        return all.filter { $0.kind == .top10 } + all.filter { $0.kind == .poster } + all.filter { $0.kind == .upcoming }
    }

    // MARK: 数据 / 播放

    private func loadHero() async {
        await model.load(zone.isEmpty ? "all" : zone, heroBoard)
        // 分区目录刚回来（第一次进某个分区）：按目录里的推荐榜再拉一次
        let key = "\(zone.isEmpty ? "all" : zone)|\(heroBoard)"
        if model.rows[key] == nil { await model.load(zone.isEmpty ? "all" : zone, heroBoard) }
    }

    private func loadThemes() async {
        let g = genre
        guard themes[g] == nil, let r = try? await HGAPI.find(["genre": g], offset: 0, session: "") else { return }
        themes[g] = r.filters?.first { $0.type == "category_dim_theme" }?.items ?? []
    }

    private func loadAccountShelves() async {
        guard (try? await HGAPI.accountStatus())?.signedIn == true else { cloud = []; cloudFavorites = []; return }
        async let h = try? HGAPI.cloudHistoryAll()
        async let f = try? HGAPI.cloudFavorites()
        cloud = await h ?? []
        cloudFavorites = (await f ?? []).map(\.series)
    }

    private func refresh() async {
        model.rows = [:]
        await loadHero()
        await loadAccountShelves()
    }

    private func play(_ s: HGSeries) async {
        guard let d = try? await HGAPI.detail(s.id), !d.episodes.isEmpty else { openSeries = s; return }
        let p = library.progress(for: s.id)
        var series = s
        series.episode_count = d.episodes.count
        if (series.description ?? "").isEmpty { series.description = d.description }
        let i = min(d.episodes.count - 1, p?.episodeIndex ?? 0)
        playing = HGPlayerRequest(series: series, episodes: d.episodes, index: i, startAt: p?.position ?? 0)
    }

    /// 继续观看：云端记录按分集编号定位；本机记录按集序号续进度
    private func resume(_ r: HGCloudHistoryRow) async {
        guard let d = try? await HGAPI.detail(r.series_id), !d.episodes.isEmpty else { return }
        let byVid = r.episode_id.isEmpty ? nil : d.episodes.firstIndex { $0.vid == r.episode_id }
        let idx = byVid ?? min(d.episodes.count - 1, max(0, r.vid_index - 1))
        var s = r.series; s.episode_count = d.episodes.count
        if (s.cover ?? "").isEmpty { s.cover = d.cover }
        let exact = byVid != nil || (r.episode_id.isEmpty && idx == r.vid_index - 1)
        playing = HGPlayerRequest(series: s, episodes: d.episodes, index: idx, startAt: exact ? r.currentTime : 0)
    }
}

// MARK: - 一行（标题 + 查看全部 + 横滑）

struct HGHomeShelf<Content: View>: View {
    let title: String
    let id: String
    var all: (() -> AnyView)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title3.weight(.bold)).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 8)
                if let all {
                    NavigationLink { all() } label: {
                        HStack(spacing: 2) { Text("查看全部"); Image(systemName: "chevron.right").font(.caption.weight(.semibold)) }
                            .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                    }
                    .accessibilityIdentifier("hg.home.row.\(id).all")
                }
            }
            .padding(.horizontal, 16)
            // 海报横滑：不裁，滑进右侧系统竖栏下面（奈飞同款，玻璃透出海报）
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 8) { content() }
                    .padding(.horizontal, 16)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hg.home.row.\(id)")
    }
}

struct HGHomeRowView: View {
    let row: HGHomeRow
    let posterW: CGFloat
    let model: HGHomeModel

    var body: some View {
        let items = model.rows[row.id]
        Group {
            if let items, items.isEmpty {
                EmptyView()
            } else {
                HGHomeShelf(title: row.title, id: row.board, all: allScreen) {
                    if let items {
                        switch row.kind {
                        case .top10:
                            ForEach(Array(items.prefix(10).enumerated()), id: \.element.id) { i, s in
                                NavigationLink(value: s) { HGTop10Card(series: s, rank: i + 1, width: posterW) }.buttonStyle(.plain)
                            }
                        case .poster, .upcoming:
                            ForEach(items) { s in
                                NavigationLink(value: s) {
                                    HGPoster(series: s, width: posterW, top10: row.kind == .poster && model.top10.contains(s.id))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        ForEach(0..<6, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.06))
                                .frame(width: posterW, height: posterW * 4 / 3)
                        }
                    }
                }
            }
        }
        .task { await model.load(row.zone, row.board) }
    }

    private var allScreen: () -> AnyView {
        let r = row
        if let src = HGHomeView.otherSource(r.zone) {
            return { AnyView(HGSourceGenreScreen(route: HGGenreRoute(source: src, genre: HGGenre(slug: r.board, label: r.title)))) }
        }
        return {
            r.kind == .upcoming
                ? AnyView(HGRankScreen(title: "即将上线", fixedBoard: r.board))
                : AnyView(HGRankScreen(initialZone: r.zone, initialBoard: r.board))
        }
    }
}

// MARK: - 卡片

/// 竖版海报：小圆角、不带标题（封面自带剧名，奈飞同款）；左上 TOP 10、底部红白角标
struct HGPoster: View {
    let series: HGSeries
    let width: CGFloat
    var top10 = false

    var body: some View {
        Color.clear.frame(width: width, height: width * 4 / 3)
            .overlay { HGCoverFill(url: series.coverURL) }
            .overlay(alignment: .topLeading) { if top10 { HGTop10Badge().padding(4) } }
            .overlay(alignment: .bottom) {
                if let l = label { HGPosterLabel(main: l.0, sub: l.1).padding(.bottom, 6) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(series.series_title)
            .accessibilityIdentifier("hg.home.poster")
    }

    private var label: (String, String?)? {
        if series.upcoming == true { return ("即将上线", series.heat) }
        guard let b = series.badge, !b.isEmpty else { return nil }
        if b.contains("新") { return ("新剧", "立即观看") }
        return (b, nil)
    }
}

struct HGPosterLabel: View {
    let main: String
    let sub: String?
    var body: some View {
        VStack(spacing: 0) {
            Text(main).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(HGTheme.accent)
            if let sub {
                Text(sub).font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.white)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

struct HGTop10Badge: View {
    var body: some View {
        VStack(spacing: -2) {
            Text("TOP").font(.system(size: 6, weight: .heavy))
            Text("10").font(.system(size: 10, weight: .heavy))
        }
        .foregroundStyle(.white)
        .frame(width: 18, height: 22)
        .background(HGTheme.accent, in: RoundedRectangle(cornerRadius: 2, style: .continuous))
    }
}

/// Top 10：海报左边一个描边大数字（海报压在数字上）
struct HGTop10Card: View {
    let series: HGSeries
    let rank: Int
    let width: CGFloat
    var body: some View {
        let h = width * 4 / 3
        HStack(alignment: .bottom, spacing: -width * 0.22) {
            HGOutlinedNumber(n: rank, size: h * 0.78)
                .frame(width: rank == 10 ? width * 0.78 : width * 0.46, alignment: .trailing)
            HGPoster(series: series, width: width)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第\(rank)名 \(series.series_title)")
    }
}

struct HGOutlinedNumber: View {
    let n: Int
    let size: CGFloat
    var body: some View {
        let t = Text("\(n)").font(.system(size: size, weight: .heavy)).fontWidth(.condensed)
        let d: CGFloat = 1.6
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                let a = Double(i) * .pi / 4
                t.foregroundStyle(.white.opacity(0.9)).offset(x: cos(a) * d, y: sin(a) * d)
            }
            t.foregroundStyle(.black)
        }
        .fixedSize()
        .offset(y: size * 0.1)
    }
}

/// 继续观看：海报中间播放圈 + 底下红色进度条 + 第几集
struct HGContinueCard: View {
    let row: HGCloudHistoryRow
    let width: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HGPoster(series: row.series, width: width)
                .overlay {
                    Image(systemName: "play.fill").font(.system(size: 18)).foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.45), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                }
            GeometryReader { g in
                Capsule().fill(.white.opacity(0.25))
                    .overlay(alignment: .leading) { Capsule().fill(HGTheme.accent).frame(width: g.size.width * fraction) }
            }
            .frame(width: width, height: 3)
            Text(caption).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
        }
        .frame(width: width)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.series_title) \(caption)")
        .accessibilityIdentifier("hg.home.continue")
    }
    private var fraction: CGFloat {
        guard let t = row.total, t > 0 else { return 0.05 }
        return min(1, max(0.05, CGFloat(row.vid_index) / CGFloat(t)))
    }
    private var caption: String {
        row.total.map { "第\(max(1, row.vid_index))集 / 共\($0)集" } ?? "第\(max(1, row.vid_index))集"
    }
}

/// 大海报卡：封面铺满、底部渐黑，剧名 + 标签 + 白色「播放」+ 玻璃「追剧」
struct HGHeroCard: View {
    let series: HGSeries
    let width: CGFloat
    let play: () -> Void
    let open: () -> Void
    @State private var library = HGLibrary.shared

    var body: some View {
        let fav = library.isFavorite(series.id)
        Button(action: open) {
            Color.clear.frame(width: width, height: width / 0.82)
                .overlay { HGCoverFill(url: series.coverURL) }
                .overlay {
                    LinearGradient(stops: [.init(color: .clear, location: 0.4), .init(color: .black.opacity(0.88), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                // 封面自带剧名艺术字（奈飞同款只放标题图），这里不再叠文字标题；剧名给读屏
                if !meta.isEmpty {
                    Text(meta).font(.subheadline).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                }
                HStack(spacing: 10) {
                    Button(action: play) {
                        Label("播放", systemImage: "play.fill").font(.headline).foregroundStyle(.black)
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(.white, in: Capsule())
                    }
                    .accessibilityIdentifier("hg.home.hero.play")
                    Button { library.toggleFavorite(series) } label: {
                        Label(fav ? "已追剧" : "追剧", systemImage: fav ? "checkmark" : "plus").font(.headline).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .hgGlassPill(22)
                    }
                    .accessibilityIdentifier("hg.home.hero.favorite")
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .accessibilityLabel(series.series_title)
        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
    }

    private var meta: String {
        var parts: [String] = []
        if let h = series.heat, !h.isEmpty { parts.append(h) }
        parts += (series.tags ?? []).prefix(3)
        return parts.joined(separator: " • ")
    }
}

/// 内屏 / 横屏大海报：短剧只有竖海报（2026-11-25 实测红果没有横版长封面，每集封面是随手截帧）→
/// 同一张竖海报放大模糊铺底 + 左侧压暗放简介和按钮 + 右侧清晰竖海报完整不裁（奈飞内屏横版大卡的排法）
struct HGWideHeroCard: View {
    let series: HGSeries
    let width: CGFloat
    let play: () -> Void
    let open: () -> Void
    @State private var library = HGLibrary.shared

    /// 高度：宽 ÷ 2.1，夹在 300～460（内屏横屏一屏能露出下面一行）
    static func height(_ w: CGFloat) -> CGFloat { min(460, max(300, w / 2.1)) }

    var body: some View {
        let h = Self.height(width)
        let fav = library.isFavorite(series.id)
        let posterH = h - 40
        let posterW = posterH * 3 / 4
        ZStack(alignment: .leading) {
            // 铺底：同一张海报放大糊开
            HGCoverFill(url: series.coverURL)
                .frame(width: width, height: h)
                .blur(radius: 28, opaque: true)
                .scaleEffect(1.15)
                .clipped()
            // 左侧压暗（文字区），右侧透出底色
            LinearGradient(stops: [.init(color: .black.opacity(0.78), location: 0),
                                   .init(color: .black.opacity(0.55), location: 0.45),
                                   .init(color: .black.opacity(0.15), location: 1)],
                           startPoint: .leading, endPoint: .trailing)
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(series.series_title).font(.system(size: 34, weight: .heavy)).foregroundStyle(.white)
                        .lineLimit(2).minimumScaleFactor(0.6)
                        .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                    if !meta.isEmpty {
                        Text(meta).font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    }
                    if let d = series.description, !d.isEmpty {
                        Text(d).font(.subheadline).foregroundStyle(.white.opacity(0.8)).lineLimit(3)
                            .frame(maxWidth: 460, alignment: .leading)
                    }
                    HStack(spacing: 12) {
                        Button(action: play) {
                            Label("播放", systemImage: "play.fill").font(.headline).foregroundStyle(.black)
                                .frame(width: 180, height: 46)
                                .background(.white, in: Capsule())
                        }
                        .accessibilityIdentifier("hg.home.hero.play")
                        Button { library.toggleFavorite(series) } label: {
                            Label(fav ? "已追剧" : "追剧", systemImage: fav ? "checkmark" : "plus").font(.headline).foregroundStyle(.white)
                                .frame(width: 180, height: 46)
                                .hgGlassPill(23)
                        }
                        .accessibilityIdentifier("hg.home.hero.favorite")
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // 清晰竖海报：完整不裁
                Button(action: open) {
                    Color.clear.frame(width: posterW, height: posterH)
                        .overlay { HGCoverFill(url: series.coverURL) }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 32)
        }
        .frame(width: width, height: h)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(series.series_title)
    }

    private var meta: String {
        var parts: [String] = []
        if let h = series.heat, !h.isEmpty { parts.append(h) }
        if let n = series.episode_count, n > 0 { parts.append("共\(n)集") }
        parts += (series.tags ?? []).prefix(3)
        return parts.joined(separator: " • ")
    }
}

/// 封面主色（整页染底色用）：CIAreaAverage 取平均色，压暗、略提饱和，避免太亮抢海报
enum HGHeroTint {
    static func color(_ url: URL) async -> Color? {
        guard let data = await HGImageCache.shared.data(url) else { return nil }
        return await Task.detached(priority: .utility) { () -> Color? in
            guard let ci = CIImage(data: data),
                  let out = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)])?.outputImage
            else { return nil }
            var px = [UInt8](repeating: 0, count: 4)
            CIContext(options: [.workingColorSpace: NSNull()])
                .render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
                .getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return Color(hue: h, saturation: min(1, s * 1.25 + 0.1), brightness: min(0.42, max(0.16, b * 0.55)))
        }.value
    }
}

extension View {
    /// 奈飞药丸：圆角矩形玻璃（系统液态玻璃；iOS 26 以下退磨砂）
    @ViewBuilder func hgGlassPill(_ radius: CGFloat = 12) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: radius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}


struct HGGenreRoute: Hashable { let source: HGCategory; let genre: HGGenre }

/// 西饭 / 河马某个题材的全部剧（两列瀑布流，滑到底翻页）
struct HGSourceGenreScreen: View {
    let route: HGGenreRoute
    @State private var items: [HGSeries] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 12) {
                    if let error, items.isEmpty {
                        ContentUnavailableView(error, systemImage: "exclamationmark.triangle").foregroundStyle(HGTheme.textSecondary)
                    }
                    HGWaterfall(items: items, width: geo.size.width - 32, loadMore: { Task { await load() } })
                        .padding(.horizontal, 16)
                    if loading { ProgressView().tint(HGTheme.textSecondary).padding() }
                }
                .padding(.vertical, 8)
            }
        }
        .background(HGTheme.background)
        .navigationTitle("\(route.source.title) · \(route.genre.label)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
        .task { if items.isEmpty { await load() } }
    }

    private func load() async {
        guard hasMore, !loading else { return }
        loading = true; defer { loading = false }
        do {
            let r = try await HGAPI.browse(route.source, page: page, genre: route.genre.slug)
            let seen = Set(items.map(\.id))
            items += r.results.filter { !seen.contains($0.id) }
            hasMore = (r.hasMore ?? false) && !r.results.isEmpty
            page += 1
        } catch { self.error = error.localizedDescription; hasMore = false }
    }
}
