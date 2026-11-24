import SwiftUI

/// 发现（剧场）：官方 App 同款排版——
/// 顶部搜索框 → 频道（找剧 / 真人剧 / 漫剧 / 西饭 / 河马）→ 四个入口（筛选 / 排行榜 / 新剧 / 预约）→ 两列大卡瀑布流。
/// 找剧 / 真人剧 / 漫剧是红果首页推荐流（登录了按账号推荐）；榜单目录和筛选项都由服务端下发。
struct HGDiscoverView: View {
    /// 频道：推荐流（找剧 / 真人剧 / 漫剧）、AI 剧（找剧筛选）、系列剧 + 官方各榜（排行榜接口）、西饭 / 河马
    enum Channel: String, CaseIterable {
        case all = "16", real = "39", comic = "36", ai, series
        case hot, new, search, must, chase, followed, prestige
        case xifan, hema
        var title: String {
            switch self {
            case .all: "找剧"; case .real: "真人剧"; case .comic: "漫剧"; case .ai: "AI剧"; case .series: "系列剧"
            case .hot: "热播榜"; case .new: "新剧榜"; case .search: "热搜榜"; case .must: "必看榜"
            case .chase: "追更榜"; case .followed: "收藏榜"; case .prestige: "臻果榜"
            case .xifan: "西饭"; case .hema: "河马"
            }
        }
        var isFeed: Bool { [.all, .real, .comic].contains(self) }
        /// 排行榜接口：(分区, 榜)
        var board: (zone: String, board: String)? {
            switch self {
            case .series: ("series_album", "series_album_hot_sc")
            case .hot: ("all", "ranklist_hot_play_sc"); case .new: ("all", "ranklist_new_rank_sc")
            case .search: ("all", "ranklist_hot_search_sc"); case .must: ("all", "ranklist_must_watch")
            case .chase: ("all", "ranklist_chase_update"); case .followed: ("all", "ranklist_followed")
            case .prestige: ("all", "ranklist_prestige")
            default: nil
            }
        }
        var showsRank: Bool { board != nil && self != .series }
    }
    enum Entry: String, Identifiable { case filter, rank, new, upcoming
        var id: String { rawValue }
        var title: String { switch self { case .filter: "筛选"; case .rank: "排行榜"; case .new: "新剧"; case .upcoming: "预约" } }
        var icon: String { switch self { case .filter: "line.3.horizontal.decrease"; case .rank: "flame.fill"; case .new: "play.fill"; case .upcoming: "calendar" } }
    }
    @AppStorage("hg.discover.channel") private var channel: Channel = .all
    @State private var items: [HGSeries] = []
    @State private var offset = 0
    @State private var session = ""
    @State private var page = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?
    @State private var showShare = false
    @State private var openSeries: HGSeries?
    @State private var entry: Entry?
    @State private var tabletop = false
    @Environment(\.hgSideRail) private var sideRail
    @State private var router = HGRootRouter.shared
    @State private var loadedKey = ""

    var body: some View {
        GeometryReader { geo in
            if let crease = HGTabletop.crease(geo), !items.isEmpty {
                VStack(spacing: 0) {
                    channelBar.padding(.vertical, 4)
                    HGDiscoverTabletop(items: items, crease: HGTabletop.Crease(top: crease.top - 36, bottom: crease.bottom - 36),
                                       loadMore: { Task { await loadMore() } },
                                       openDetail: { openSeries = $0 })
                        .id(channel.rawValue)
                }
                .onAppear { tabletop = true }
                .onDisappear { tabletop = false }
            } else {
                regular(width: geo.size.width)
            }
        }
        .task(id: channel) {
            guard channel.rawValue != loadedKey || items.isEmpty else { return }
            loadedKey = channel.rawValue
            await reload()
        }
        .toolbarVisibility(tabletop ? .automatic : .hidden, for: .navigationBar)
        .navigationTitle("发现")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: router.shareTick) { _, _ in showShare = true }
        .sheet(isPresented: $showShare) { HGShareLinkSheet { openSeries = $0; showShare = false }.presentationDetents([.height(240)]) }
        .navigationDestination(item: $openSeries) { HGDetailView(series: $0) }
        .navigationDestination(item: $entry) { e in
            switch e {
            case .filter: HGFindScreen()
            case .rank: HGRankScreen()
            case .new: HGFindScreen(title: "新剧", preset: ["sort": "online_time", "online_time": "days_30"])
            case .upcoming: HGRankScreen(title: "预约", fixedBoard: "ranklist_subscribe")
            }
        }
    }

    // MARK: 顶部

    private var searchBar: some View {
        HStack(spacing: 10) {
            Button { router.go(.search) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(HGTheme.textTertiary)
                    Text("搜索短剧").foregroundStyle(HGTheme.textTertiary)
                    Spacer(minLength: 0)
                }
                .font(.subheadline)
                .padding(.horizontal, 14).frame(height: 40)
                .background(HGTheme.surface, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("hg.discover.search")
            if !sideRail {
                Button { showShare = true } label: {
                    Image(systemName: "link").font(.subheadline.weight(.semibold)).foregroundStyle(HGTheme.textSecondary)
                        .frame(width: 40, height: 40).background(HGTheme.surface, in: Circle())
                }
                .accessibilityIdentifier("hg.share")
            }
        }
        .padding(.horizontal, 16)
    }

    private var channelBar: some View {
        // 放得下（内屏）整排平铺；放不下（外屏）左右滑
        // 14 个频道整排约 900pt：Duo 展开竖屏（约 1003pt 宽）整排放得下、不滑；外屏（382pt）左右滑
        ScrollView(.horizontal, showsIndicators: false) { channelRow(spacing: 16).padding(.horizontal, 16) }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .clipped()
        .animation(.snappy(duration: 0.2), value: channel)
    }

    private func channelRow(spacing: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) {
            ForEach(Channel.allCases, id: \.self) { c in
                let on = c == channel
                Button { channel = c } label: {
                    Text(c.title)
                        .font(on ? .title2.weight(.bold) : .title3)
                        .foregroundStyle(on ? HGTheme.textPrimary : HGTheme.textSecondary)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("hg.channel.\(c.title)")
            }
        }
    }

    private var entries: some View {
        HStack(spacing: 8) {
            ForEach([Entry.filter, .rank, .new, .upcoming]) { e in
                Button { entry = e } label: {
                    HStack(spacing: 7) {
                        Image(systemName: e.icon).font(.footnote.weight(.bold)).foregroundStyle(HGTheme.textPrimary)
                            .frame(width: 26, height: 26)
                            .background(HGTheme.accent.gradient, in: RoundedRectangle(cornerRadius: HGTheme.radiusSmall + 2, style: .continuous))
                        Text(e.title).font(.subheadline.weight(.medium)).foregroundStyle(HGTheme.textPrimary).lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(HGTheme.surface, in: RoundedRectangle(cornerRadius: HGTheme.radius, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("hg.entry.\(e.rawValue)")
            }
        }
        .padding(.horizontal, 16)
    }

    private func regular(width: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                searchBar
                channelBar
                if channel.isFeed { entries }
                if let error, items.isEmpty {
                    HGErrorView(message: error) { Task { await reload() } }
                }
                HGWaterfall(items: items, showRank: channel.showsRank, loadMore: { Task { await loadMore() } })
                    .padding(.horizontal, 16)
                if loading { ProgressView().tint(HGTheme.textSecondary).frame(maxWidth: .infinity).padding() }
            }
            .padding(.vertical, 8)
        }
        .refreshable { await reload() }
    }

    // MARK: 数据

    private func reload() async {
        offset = 0; session = ""; page = 1; hasMore = true; error = nil
        items = []
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, hasMore else { return }
        loading = true; defer { loading = false }
        let c = channel
        do {
            var results: [HGSeries]
            if c.isFeed {
                // 推荐流一页只有 6~7 部：一次拉到 12 部以上再显示，两列不会空一截
                results = []
                repeat {
                    let r = try await HGAPI.forYou(offset: offset, session: session, channel: c.rawValue)
                    guard c == channel else { return }
                    results += r.results; offset = r.next; session = r.session; hasMore = r.hasMore
                } while hasMore && results.count < 24 && items.isEmpty
            } else if let b = c.board {
                let r = try await HGAPI.rank(zone: b.zone, board: b.board, offset: offset, session: session)
                guard c == channel else { return }
                results = r.results; offset = r.next; session = r.session; hasMore = r.hasMore
            } else if c == .ai {
                let r = try await HGAPI.find(["genre": "ai_series", "sort": "hot_score"], offset: offset, session: session)
                guard c == channel else { return }
                results = r.results; offset = r.next; session = r.session; hasMore = r.hasMore
            } else {
                let r = try await HGAPI.browse(c == .xifan ? .xifan : .hema, page: page)
                guard c == channel else { return }
                results = r.results; hasMore = r.hasMore ?? false; page += 1
            }
            let seen = Set(items.map(\.id))
            var fresh: [HGSeries] = []
            for s in results where !seen.contains(s.id) && !fresh.contains(where: { $0.id == s.id }) { fresh.append(s) }
            items += fresh
        } catch {
            guard c == channel else { return }
            self.error = error.localizedDescription
            hasMore = false
        }
    }
}

// MARK: - 两列瀑布流大卡（官方剧场同款）

/// 瀑布流：卡片宽度固定在外屏两列时的大小（约 170pt），列数按实际可用宽度算——
/// Duo 外屏 2 列，展开内屏竖着 5 列、横着 7 列，iPad 同理。每张卡按估高放进当前最矮的那列（新的只往后排，不跳位）。
struct HGWaterfall: View {
    let items: [HGSeries]
    var showRank = false
    let loadMore: () -> Void
    /// 外屏（Duo 合上，内容区 382pt）两列时的卡宽
    static let cardWidth: CGFloat = 170
    static let gap: CGFloat = 10
    @State private var width: CGFloat = 0

    static func columns(for width: CGFloat) -> Int {
        max(2, Int((width + gap) / (cardWidth + gap)))
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            if width > 0 {
                let n = Self.columns(for: width)
                let colW = (width - Self.gap * CGFloat(n - 1)) / CGFloat(n)
                let cols = split(n, colW)
                HStack(alignment: .top, spacing: Self.gap) {
                    ForEach(0..<n, id: \.self) { i in
                        LazyVStack(spacing: Self.gap) {
                            ForEach(cols[i]) { s in
                                NavigationLink(value: s) { HGBigCard(series: s, showRank: showRank) }
                                    .buttonStyle(.plain)
                                    .onAppear { if s.id == items.last?.id || s.id == cols[i].last?.id { loadMore() } }
                            }
                        }
                        .frame(width: colW)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("hg.waterfall.\(n)")
            }
        }
    }

    private func split(_ n: Int, _ w: CGFloat) -> [[HGSeries]] {
        var cols = Array(repeating: [HGSeries](), count: n), h = Array(repeating: CGFloat(0), count: n)
        for s in items {
            let i = h.indices.min { h[$0] < h[$1] } ?? 0
            cols[i].append(s)
            h[i] += HGBigCard.estimate(s, width: w) + Self.gap
        }
        return cols
    }
}

struct HGBigCard: View {
    let series: HGSeries
    var showRank = false

    /// 封面 3:4 + 标题 1~2 行 + 标签行
    static func estimate(_ s: HGSeries, width: CGFloat) -> CGFloat {
        let chars = max(1, Int((width - 24) / 15))
        let lines: CGFloat = s.series_title.count > chars ? 2 : 1
        return width * 4 / 3 + 20 + lines * 21 + ((s.tags ?? []).isEmpty ? 0 : 30)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.aspectRatio(3 / 4, contentMode: .fit)
                .overlay { HGCoverFill(url: series.coverURL) }
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom).frame(height: 56)
                }
                .overlay(alignment: .bottomLeading) {
                    if let heat = series.heat ?? playsText {
                        Label(heat, systemImage: "flame.fill").labelStyle(HGHeatLabel())
                            .padding(.horizontal, 10).padding(.bottom, 8)
                    }
                }
                .overlay(alignment: .topLeading) { rankBadge }
                .overlay(alignment: .topTrailing) { badge }
                .clipped()
            VStack(alignment: .leading, spacing: 8) {
                Text(series.series_title).font(.subheadline.weight(.medium)).foregroundStyle(HGTheme.textPrimary)
                    .lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                if let tags = series.tags, !tags.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(tags.prefix(3), id: \.self) { t in
                            Text(t).font(.caption2).foregroundStyle(HGTheme.textSecondary).lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(HGTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(HGTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: HGTheme.radius + 2, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hg.card")
    }

    private var playsText: String? {
        guard let n = series.plays, n >= 10_000 else { return nil }
        return n >= 100_000_000 ? String(format: "%.1f亿播放", Double(n) / 1e8) : "\(n / 10_000)万播放"
    }

    @ViewBuilder private var rankBadge: some View {
        if showRank, let r = series.rank {
            Text("\(r)").font(.subheadline.weight(.heavy)).monospacedDigit()
                .frame(minWidth: 28, minHeight: 26).padding(.horizontal, 4)
                .background(r <= 3 ? HGTheme.accent : HGTheme.surfaceHigh.opacity(0.92),
                            in: UnevenRoundedRectangle(bottomTrailingRadius: HGTheme.radius, style: .continuous))
                .foregroundStyle(HGTheme.textPrimary)
                .accessibilityLabel("第 \(r) 名")
        }
    }

    @ViewBuilder private var badge: some View {
        if series.upcoming == true {
            tag("待上线")
        } else if let b = series.badge, !b.isEmpty {
            tag(b)
        }
    }

    private func tag(_ t: String) -> some View {
        Text(t).font(.caption2.weight(.bold)).foregroundStyle(HGTheme.textPrimary)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(HGTheme.accent, in: UnevenRoundedRectangle(bottomLeadingRadius: HGTheme.radiusSmall, style: .continuous))
    }
}

/// 封面铺满（不留边）
struct HGCoverFill: View {
    let url: URL?
    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            if case .success(let image) = phase { image.resizable().scaledToFill() }
            else { Rectangle().fill(HGTheme.surfaceHigh).overlay(Image(systemName: "film").foregroundStyle(HGTheme.textTertiary)) }
        }
    }
}

struct HGHeatLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.caption2)
            configuration.title.font(.caption.weight(.semibold)).monospacedDigit()
        }
        .foregroundStyle(HGTheme.textPrimary)
        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
    }
}

// MARK: - 排行榜（分区 × 榜）

struct HGRankScreen: View {
    var title = "排行榜"
    /// 预约入口：固定预约榜（分区可切）
    var fixedBoard: String? = nil
    @AppStorage("hg.rank.zone") private var zone = "all"
    @AppStorage("hg.rank.board") private var board = "ranklist_hot_play_sc"
    @State private var zones: [HGRankZone] = []
    @State private var items: [HGSeries] = []
    @State private var offset = 0
    @State private var session = ""
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?

    private var isUpcoming: Bool { fixedBoard != nil }
    private var currentBoard: String {
        guard isUpcoming else { return board }
        return zones.first { $0.id == zone }?.boards.first { $0.id.contains("subscribe") }?.id ?? fixedBoard ?? board
    }
    private var key: String { "\(zone)|\(currentBoard)" }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !zones.isEmpty {
                        HGChips(options: zones.filter { z in !isUpcoming || z.boards.contains { $0.id.contains("subscribe") } }.map { ($0.id, $0.name) },
                                selected: zone, prefix: "hg.zone") { z in
                            guard z != zone else { return }
                            let name = zones.first { $0.id == zone }?.boards.first { $0.id == board }?.name
                            zone = z
                            let boards = visible(z)
                            board = boards.first { $0.name == name }?.id ?? boards.first?.id ?? board
                        }
                        if !isUpcoming {
                            HGChips(options: visible(zone).map { ($0.id, $0.name) }, selected: board, small: true, prefix: "hg.board") { board = $0 }
                        }
                    }
                    if let error, items.isEmpty { HGErrorView(message: error) { Task { await reload() } } }
                    HGWaterfall(items: items, showRank: !isUpcoming, loadMore: { Task { await loadMore() } })
                        .padding(.horizontal, 16)
                    if loading { ProgressView().tint(HGTheme.textSecondary).frame(maxWidth: .infinity).padding() }
                }
                .padding(.vertical, 8)
            }
            .refreshable { await reload() }
        }
        .background(HGTheme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: key) { await reload() }
    }

    /// 预约榜是还没上线的剧，只在「预约」入口里出现
    private func visible(_ z: String) -> [HGRankBoard] {
        (zones.first { $0.id == z }?.boards ?? []).filter { !$0.id.contains("subscribe") }
    }

    private func reload() async {
        offset = 0; session = ""; hasMore = true; error = nil; items = []
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, hasMore else { return }
        loading = true; defer { loading = false }
        let k = key
        do {
            let r = try await HGAPI.rank(zone: zone, board: currentBoard, offset: offset, session: session)
            guard k == key else { return }
            if let z = r.zones, !z.isEmpty {
                zones = z
                // 记住的分区 / 榜服务端没了：回到第一个
                if !z.contains(where: { $0.id == zone }) { zone = z.first?.id ?? "all" }
                if !isUpcoming, !visible(zone).contains(where: { $0.id == board }) { board = visible(zone).first?.id ?? board }
            }
            let seen = Set(items.map(\.id))
            items += r.results.filter { !seen.contains($0.id) }
            offset = r.next; session = r.session; hasMore = r.hasMore
        } catch {
            guard k == key else { return }
            self.error = error.localizedDescription; hasMore = false
        }
    }
}

// MARK: - 筛选 / 新剧（分类落地页）

struct HGFindScreen: View {
    var title = "筛选"
    var preset: [String: String] = [:]
    @State private var select: [String: String] = [:]
    @State private var filters: [HGFindFilter] = []
    @State private var moreFilters = false
    @State private var items: [HGSeries] = []
    @State private var offset = 0
    @State private var session = ""
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?
    @State private var started = false

    private static let mainFilters: Set<String> = ["genre", "sort", "online_time", "category_dim_theme"]
    private var key: String { select.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&") }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(filters.filter { Self.mainFilters.contains($0.type) || moreFilters }) { f in row(f) }
                    if filters.contains(where: { !Self.mainFilters.contains($0.type) }) {
                        Button { withAnimation(.snappy) { moreFilters.toggle() } } label: {
                            Label(moreFilters ? "收起" : "更多筛选（人设 / 背景 / 频道）", systemImage: moreFilters ? "chevron.up" : "slider.horizontal.3")
                                .font(.footnote).foregroundStyle(HGTheme.textSecondary)
                        }
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("hg.find.more")
                    }
                    if let error, items.isEmpty { HGErrorView(message: error) { Task { await reload() } } }
                    else if items.isEmpty && !loading && !hasMore {
                        Text("没有符合条件的剧").font(.footnote).foregroundStyle(HGTheme.textTertiary).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    HGWaterfall(items: items, loadMore: { Task { await loadMore() } })
                        .padding(.horizontal, 16).padding(.top, 4)
                    if loading { ProgressView().tint(HGTheme.textSecondary).frame(maxWidth: .infinity).padding() }
                }
                .padding(.vertical, 8)
            }
            .refreshable { await reload() }
        }
        .background(HGTheme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if !started { started = true; select = ["genre": "short_play", "sort": "hot_score"].merging(preset) { $1 } } }
        .task(id: key) { if started { await reload() } }
    }

    private func row(_ f: HGFindFilter) -> some View {
        let required = f.type == "genre" || f.type == "sort"
        let opts = (required ? [] : [("", "不限")]) + f.items.map { ($0.id, $0.name) }
        return HStack(spacing: 0) {
            Text(f.name).font(.caption).foregroundStyle(HGTheme.textTertiary).frame(width: 38, alignment: .leading).padding(.leading, 16)
            HGChips(options: opts, selected: select[f.type] ?? "", small: true, prefix: "hg.find.\(f.type)", leading: 4) { v in
                if f.type == "genre" {
                    // 换类型：题材 / 人设等 ID 每个类型不同，清掉重新拿
                    guard v != select["genre"] else { return }
                    select = ["genre": v, "sort": select["sort"] ?? "hot_score", "online_time": select["online_time"] ?? ""].filter { !$0.value.isEmpty }
                    filters = filters.filter { $0.type == "genre" }
                } else {
                    select[f.type] = v.isEmpty ? nil : v
                }
            }
        }
    }

    private func reload() async {
        offset = 0; session = ""; hasMore = true; error = nil; items = []
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, hasMore else { return }
        loading = true; defer { loading = false }
        let k = key
        do {
            let r = try await HGAPI.find(select, offset: offset, session: session)
            guard k == key else { return }
            if let f = r.filters, !f.isEmpty { filters = f }
            let seen = Set(items.map(\.id))
            items += r.results.filter { !seen.contains($0.id) }
            offset = r.next; session = r.session; hasMore = r.hasMore
        } catch {
            guard k == key else { return }
            self.error = error.localizedDescription; hasMore = false
        }
    }
}

/// 横滑胶囊选项
struct HGChips: View {
    let options: [(String, String)]
    let selected: String
    var small = false
    let prefix: String
    var leading: CGFloat = 16
    let pick: (String) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.0) { value, title in
                    let on = value == selected
                    Button { pick(value) } label: {
                        Text(title).font((small ? Font.footnote : .subheadline).weight(on ? .semibold : .regular))
                            .padding(.horizontal, small ? 11 : 14).padding(.vertical, small ? 5 : 7)
                            .background(on ? (small ? HGTheme.accent.opacity(0.2) : HGTheme.accent) : HGTheme.surface, in: Capsule())
                            .foregroundStyle(on ? (small ? HGTheme.accent : HGTheme.textPrimary) : HGTheme.textSecondary)
                    }
                    .accessibilityIdentifier("\(prefix).\(value.isEmpty ? "all" : value)")
                }
            }
            .padding(.leading, leading).padding(.trailing, 16)
        }
    }
}

/// 粘贴红果分享链接（或整段分享口令）→ 打开剧集。
struct HGShareLinkSheet: View {
    let open: (HGSeries) -> Void
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("粘贴红果分享链接").font(.headline)
            TextField("https://… 或整段分享文字", text: $text, axis: .vertical)
                .lineLimit(2...3).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("hg.share.field")
            if let error { Text(error).font(.footnote).foregroundStyle(HGTheme.accent) }
            HStack {
                Button("从剪贴板粘贴") { text = UIPasteboard.general.string ?? "" }
                Spacer()
                Button { Task { await go() } } label: { if busy { ProgressView() } else { Text("打开") } }
                    .buttonStyle(.borderedProminent).tint(HGTheme.accent).disabled(text.isEmpty || busy)
                    .accessibilityIdentifier("hg.share.open")
            }
        }
        .padding(20)
    }

    private func go() async {
        busy = true; error = nil; defer { busy = false }
        do {
            let sid = try await HGAPI.resolveShare(text)
            let detail = try await HGAPI.detail(sid)
            open(HGSeries(series_id: sid, series_title: detail.series_title, cover: detail.cover, episode_count: detail.episodes.count, description: detail.description))
        } catch { self.error = error.localizedDescription }
    }
}

struct HGSearchView: View {
    @State private var query = ""
    @State private var submitted = ""
    @State private var source: HGSourceKind = .hongguo
    @State private var items: [HGSeries] = []
    @State private var page = 1
    @State private var cursor: HGCursor?
    @State private var hasMore = false
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            Picker("来源", selection: $source) {
                ForEach(HGSourceKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(HGTheme.background).listRowSeparator(.hidden)
            if let error { Text(error).font(.footnote).foregroundStyle(HGTheme.textSecondary).listRowBackground(HGTheme.background) }
            ForEach(items) { s in
                NavigationLink(value: s) {
                    HStack(spacing: 12) {
                        HGCover(url: s.coverURL).frame(width: 54)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.series_title).font(.body.weight(.medium)).foregroundStyle(HGTheme.textPrimary).lineLimit(2)
                            if let n = s.episode_count, n > 0 { Text("共 \(n) 集").font(.caption).foregroundStyle(HGTheme.textSecondary) }
                        }
                    }
                }
                .listRowBackground(HGTheme.background)
                .onAppear { if s.id == items.last?.id { Task { await load(more: true) } } }
            }
            if loading { ProgressView().frame(maxWidth: .infinity).listRowBackground(HGTheme.background) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if items.isEmpty && !loading && error == nil {
                ContentUnavailableView(submitted.isEmpty ? "搜索短剧" : "没有结果", systemImage: "magnifyingglass")
                    .foregroundStyle(HGTheme.textSecondary)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "剧名")
        .onSubmit(of: .search) {
            submitted = query.trimmingCharacters(in: .whitespaces)
            Task { await load(more: false) }
        }
        .onChange(of: source) { _, _ in Task { await load(more: false) } }
        .navigationTitle("搜索")
    }

    private func load(more: Bool) async {
        guard !submitted.isEmpty, !loading, !more || hasMore else { return }
        if !more { items = []; page = 1; cursor = nil }
        loading = true; error = nil; defer { loading = false }
        do {
            let r = try await HGAPI.search(submitted, source: source, page: page, cursor: cursor)
            let seen = Set(items.map(\.id))
            items += r.results.filter { !seen.contains($0.id) }
            hasMore = r.hasMore ?? false
            cursor = r.cursor; page += 1
        } catch { self.error = error.localizedDescription }
    }
}
