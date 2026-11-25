import SwiftUI

/// 发现（剧场）：官方 App 同款排版——
/// 顶部搜索框 → 频道（找剧 / 真人剧 / 漫剧 / 西饭 / 河马）→ 四个入口（筛选 / 排行榜 / 新剧 / 预约）→ 两列大卡瀑布流。
/// 找剧 / 真人剧 / 漫剧是红果首页推荐流（登录了按账号推荐）；榜单目录和筛选项都由服务端下发。
struct HGDiscoverView: View {
    /// 频道（官方剧场同款）：找剧 = 首页推荐流 + 四个入口；真人剧 / 漫剧 / AI剧 = 分类标签行 + 推荐榜卡 + 推荐流；
    /// 系列剧 = 系列剧推荐榜；西饭 / 河马 = 其他片源。热播 / 新剧 / 热搜 / 必看…各榜都在「排行榜」里。
    enum Channel: String, CaseIterable {
        case all = "16", real = "39", comic = "36", ai, series, xifan, hema
        var title: String {
            switch self {
            case .all: "找剧"; case .real: "真人剧"; case .comic: "漫剧"; case .ai: "AI剧"; case .series: "系列剧"
            case .xifan: "西饭"; case .hema: "河马"
            }
        }
        /// 首页推荐流频道（不选分类时）
        var isFeed: Bool { [.all, .real, .comic].contains(self) }
        /// 找剧筛选里的类型（分类标签按它下发，题材 ID 每个类型不同）
        var genre: String? { switch self { case .real: "short_play"; case .comic: "comic_series"; case .ai: "ai_series"; default: nil } }
        /// 推荐榜卡（前 3 名 + 查看全部）用的 (分区, 榜)
        var topBoard: (zone: String, board: String)? {
            switch self {
            case .real: ("human", "human_hot_sc"); case .comic: ("comic_series_rank", "comic_series_hot_rank")
            case .ai: ("ai_playlet", "ai_playlet_hot_sc"); default: nil
            }
        }
        /// 整个频道就是一个榜
        var board: (zone: String, board: String)? { self == .series ? ("series_album", "series_album_hot_sc") : nil }
    }
    /// 分类标签：一组里的一项（题材 / 背景 / 人设）
    struct Chip: Hashable { let type: String; let id: String; let name: String }
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
    @State private var openSeries: HGSeries?
    @State private var entry: Entry?
    @State private var tabletop = false
    @Environment(\.hgSideRail) private var sideRail
    @State private var loadedKey = ""
    /// 真人剧 / 漫剧 / AI剧：当前选的分类（nil = 推荐）、各类型的分类标签、展开全部分类
    @State private var chip: Chip?
    @State private var chips: [String: [HGFindFilter]] = [:]
    @State private var showAllChips = false
    /// 推荐榜卡：前 3 名
    @State private var top: [HGSeries] = []
    @State private var rankZone: String?
    /// 加载代次：换频道 / 刷新就 +1，旧请求回来直接丢、也不再挡新请求（以前「加载中」挡住新频道 → 白屏）
    @State private var generation = 0

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
        .task(id: loadKey) {
            guard loadKey != loadedKey || items.isEmpty else { return }
            loadedKey = loadKey
            await reload()
        }
        .task(id: channel) { await loadChipsAndTop() }
        .onChange(of: channel) { _, _ in chip = nil; showAllChips = false }
        .toolbarVisibility(tabletop ? .automatic : .hidden, for: .navigationBar)
        .navigationTitle("发现")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openSeries) { HGDetailView(series: $0) }
        .navigationDestination(item: $entry) { e in
            switch e {
            case .filter: HGFindScreen()
            case .rank: HGRankScreen()
            case .new: HGFindScreen(title: "新剧", preset: ["sort": "online_time", "online_time": "days_30"])
            case .upcoming: HGRankScreen(title: "预约", fixedBoard: "ranklist_subscribe")
            }
        }
        .navigationDestination(item: $rankZone) { z in HGRankScreen(initialZone: z) }
    }

    private var loadKey: String { channel.rawValue + "|" + (chip.map { "\($0.type)=\($0.id)" } ?? "") }

    // MARK: 顶部

    private var searchBar: some View {
        HStack(spacing: 10) {
            NavigationLink { HGSearchView() } label: {
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
        }
        .padding(.horizontal, 16)
    }

    private var channelBar: some View {
        // 放得下（内屏）整排平铺；放不下（外屏）左右滑
        // 14 个频道整排约 900pt：Duo 展开竖屏（约 1003pt 宽）整排放得下、不滑；外屏（382pt）左右滑
        ScrollView(.horizontal, showsIndicators: false) { channelRow(spacing: 16).padding(.horizontal, 16) }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .frame(maxWidth: .infinity)
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

    /// 四个入口一行（官方剧场同款尺寸：约 84×36，图标 22）；宽度够就一行铺开，不够（外屏）左右滑
    private var entries: some View {
        let all = [Entry.filter, .rank, .new, .upcoming]
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { ForEach(all) { entryButton($0).frame(minWidth: 82, maxWidth: 150) } }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { ForEach(all) { entryButton($0).frame(width: 88) } }
                    .padding(.horizontal, 16)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }

    /// 分类标签行（官方同款：圆角胶囊一行，放不下左右滑，最右 ⌄ 展开全部分类）
    @ViewBuilder private var chipBar: some View {
        let groups = (channel.genre.flatMap { chips[$0] } ?? []).filter { ["category_dim_theme", "category_dim_epoch", "category_dim_role"].contains($0.type) }
        if !groups.isEmpty {
            // 一行：题材在前、再背景、再人设（同名去重），选中的排最前
            var seen = Set<String>()
            let flat = groups.flatMap { g in g.items.map { Chip(type: g.type, id: $0.id, name: $0.name) } }.filter { seen.insert($0.name).inserted }
            let row = [Chip?.none] + (chip.map { [$0] } ?? []) + flat.filter { $0 != chip }.prefix(30).map { Optional($0) }
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(row, id: \.self) { c in chipButton(c) }
                    }
                    .padding(.leading, 16).padding(.trailing, 8)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                Button { withAnimation(.snappy) { showAllChips.toggle() } } label: {
                    Image(systemName: showAllChips ? "chevron.up" : "chevron.down").font(.footnote.weight(.semibold))
                        .foregroundStyle(HGTheme.textSecondary)
                        .frame(width: 40, height: 34).background(HGTheme.surface, in: RoundedRectangle(cornerRadius: HGTheme.radiusSmall + 2, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 16)
                .accessibilityIdentifier("hg.chips.all")
            }
            if showAllChips {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groups) { g in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(g.name).font(.caption).foregroundStyle(HGTheme.textTertiary)
                            FlowLayout(spacing: 8) {
                                ForEach(g.items) { it in chipButton(Chip(type: g.type, id: it.id, name: it.name)) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .transition(.opacity)
            }
        }
    }

    private func chipButton(_ c: Chip?) -> some View {
        let on = c == chip
        return Button { chip = c; showAllChips = false } label: {
            Text(c?.name ?? "推荐").font(.subheadline.weight(on ? .semibold : .regular)).lineLimit(1).fixedSize()
                .padding(.horizontal, 16).frame(height: 34)
                .background(on ? HGTheme.accent.opacity(0.22) : HGTheme.surface, in: RoundedRectangle(cornerRadius: HGTheme.radiusSmall + 2, style: .continuous))
                .foregroundStyle(on ? HGTheme.accent : HGTheme.textPrimary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("hg.chip.\(c?.name ?? "推荐")")
    }

    /// 推荐榜卡（官方漫剧页同款）：前 3 名 + 查看全部
    private var topCard: AnyView? {
        guard chip == nil, top.count >= 3, let tb = channel.topBoard else { return nil }
        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                Text("《 推荐榜 》").font(.subheadline.weight(.bold)).foregroundStyle(HGTheme.textPrimary)
                ForEach(Array(top.prefix(3).enumerated()), id: \.element.id) { i, s in
                    NavigationLink(value: s) {
                        HStack(alignment: .top, spacing: 10) {
                            HGCoverFill(url: s.coverURL).frame(width: 52, height: 70)
                                .clipShape(RoundedRectangle(cornerRadius: HGTheme.radiusSmall, style: .continuous))
                            Text("\(i + 1)").font(.subheadline.weight(.heavy)).foregroundStyle(i == 0 ? HGTheme.accent : HGTheme.textSecondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(s.series_title).font(.subheadline).foregroundStyle(HGTheme.textPrimary).lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                if let h = s.heat { Text(h).font(.caption).foregroundStyle(HGTheme.textTertiary) }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button { rankZone = tb.zone } label: {
                    Text("查看全部").font(.subheadline.weight(.medium)).foregroundStyle(HGTheme.textPrimary)
                        .frame(maxWidth: .infinity).frame(height: 38)
                        .background(HGTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: HGTheme.radiusSmall + 2, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("hg.top.all")
            }
            .padding(14)
            .background(HGTheme.surface, in: RoundedRectangle(cornerRadius: HGTheme.radius + 2, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("hg.top")
        )
    }

    private func loadChipsAndTop() async {
        let c = channel
        top = []
        if let g = c.genre, chips[g] == nil, let r = try? await HGAPI.find(["genre": g], offset: 0, session: ""), let f = r.filters {
            chips[g] = f
        }
        if let tb = c.topBoard, let r = try? await HGAPI.rank(zone: tb.zone, board: tb.board, offset: 0, session: ""), c == channel {
            top = Array(r.results.prefix(3))
        }
    }

    private func entryButton(_ e: Entry) -> some View {
        Button { entry = e } label: {
            HStack(spacing: 6) {
                Image(systemName: e.icon).font(.caption2.weight(.bold)).foregroundStyle(HGTheme.textPrimary)
                    .frame(width: 22, height: 22)
                    .background(HGTheme.accent.gradient, in: RoundedRectangle(cornerRadius: HGTheme.radiusSmall, style: .continuous))
                Text(e.title).font(.footnote.weight(.medium)).foregroundStyle(HGTheme.textPrimary).lineLimit(1).fixedSize()
            }
            .frame(maxWidth: .infinity).frame(height: 36)
            .background(HGTheme.surface, in: RoundedRectangle(cornerRadius: HGTheme.radiusSmall + 2, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("hg.entry.\(e.rawValue)")
    }

    private func regular(width: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                searchBar
                channelBar
                if channel == .all { entries }
                if channel.genre != nil { chipBar }
                if let error, items.isEmpty {
                    HGErrorView(message: error) { Task { await reload() } }
                }
                HGWaterfall(items: items, width: width - 32, showRank: false, lead: topCard, leadHeight: 330, loadMore: { Task { await loadMore() } })
                    .padding(.horizontal, 16)
                if loading { ProgressView().tint(HGTheme.textSecondary).frame(maxWidth: .infinity).padding() }
            }
            .padding(.vertical, 8)
            // 内容宽度钉死在屏幕可见宽度：横滑的频道条 / 搜索框不许把整页撑宽
            .frame(width: width)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .refreshable { await reload() }
    }

    // MARK: 数据

    private func reload() async {
        generation += 1
        offset = 0; session = ""; page = 1; hasMore = true; error = nil
        items = []; loading = false
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, hasMore else { return }
        loading = true
        let gen = generation
        defer { if gen == generation { loading = false } }
        let c = channel, chipNow = chip
        do {
            var results: [HGSeries]
            if let ch = chip, let g = c.genre {
                // 选了分类：找剧筛选（这个类型 + 这个分类，按热度）
                let r = try await HGAPI.find(["genre": g, "sort": "hot_score", ch.type: ch.id], offset: offset, session: session)
                guard c == channel, chipNow == chip, gen == generation else { return }
                results = r.results; offset = r.next; session = r.session; hasMore = r.hasMore
            } else if c.isFeed {
                // 推荐流一页只有 4~7 部、每页约 1.6 秒：拿到一页先显示，首屏不够一屏再接着补（不白等）
                let r = try await HGAPI.forYou(offset: offset, session: session, channel: c.rawValue)
                guard c == channel, chipNow == chip, gen == generation else { return }
                results = r.results; offset = r.next; session = r.session; hasMore = r.hasMore
                if items.count + results.count < 16 && hasMore {
                    Task { @MainActor in try? await Task.sleep(for: .milliseconds(50)); await loadMore() }
                }
            } else if let b = c.board {
                let r = try await HGAPI.rank(zone: b.zone, board: b.board, offset: offset, session: session)
                guard c == channel, chipNow == chip, gen == generation else { return }
                results = r.results; offset = r.next; session = r.session; hasMore = r.hasMore
            } else if c == .ai {
                let r = try await HGAPI.find(["genre": "ai_series", "sort": "hot_score"], offset: offset, session: session)
                guard c == channel, chipNow == chip, gen == generation else { return }
                results = r.results; offset = r.next; session = r.session; hasMore = r.hasMore
            } else {
                let r = try await HGAPI.browse(c == .xifan ? .xifan : .hema, page: page)
                guard c == channel, chipNow == chip, gen == generation else { return }
                results = r.results; hasMore = r.hasMore ?? false; page += 1
            }
            let seen = Set(items.map(\.id))
            var fresh: [HGSeries] = []
            for s in results where !seen.contains(s.id) && !fresh.contains(where: { $0.id == s.id }) { fresh.append(s) }
            items += fresh
        } catch {
            guard c == channel, chipNow == chip, gen == generation else { return }
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
    /// 可用宽度（屏幕可见宽度减左右边距），由外层 GeometryReader 给
    let width: CGFloat
    var showRank = false
    /// 第一列顶部插的卡（推荐榜）和它的估高
    var lead: AnyView? = nil
    var leadHeight: CGFloat = 0
    let loadMore: () -> Void
    /// 外屏（Duo 合上，内容区 382pt）两列时的卡宽
    static let cardWidth: CGFloat = 170
    static let gap: CGFloat = 10

    static func columns(for width: CGFloat) -> Int {
        max(2, Int((width + gap) / (cardWidth + gap)))
    }

    var body: some View {
        let n = Self.columns(for: width)
        let colW = max(60, (width - Self.gap * CGFloat(n - 1)) / CGFloat(n))
        let cols = split(n, colW)
        HStack(alignment: .top, spacing: Self.gap) {
            ForEach(0..<n, id: \.self) { i in
                LazyVStack(spacing: Self.gap) {
                    if i == 0, let lead { lead }
                    ForEach(cols[i]) { s in
                        NavigationLink(value: s) { HGBigCard(series: s, showRank: showRank) }
                            .buttonStyle(.plain)
                            .onAppear { if s.id == items.last?.id || s.id == cols[i].last?.id { loadMore() } }
                    }
                }
                .frame(width: colW)
            }
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hg.waterfall.\(n)")
    }

    private func split(_ n: Int, _ w: CGFloat) -> [[HGSeries]] {
        var cols = Array(repeating: [HGSeries](), count: n), h = Array(repeating: CGFloat(0), count: n)
        if lead != nil { h[0] = leadHeight + Self.gap }
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
        HGCachedImage(url: url) { Rectangle().fill(HGTheme.surfaceHigh).overlay(Image(systemName: "film").foregroundStyle(HGTheme.textTertiary)) }
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
    /// 从推荐榜卡「查看全部」进来：落到该分区的推荐榜
    var initialZone: String? = nil
    /// 首页某一行「查看全部」：落到这个榜
    var initialBoard: String? = nil
    @State private var appliedInitial = false
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
                    HGWaterfall(items: items, width: geo.size.width - 32, showRank: !isUpcoming, loadMore: { Task { await loadMore() } })
                        .padding(.horizontal, 16)
                    if loading { ProgressView().tint(HGTheme.textSecondary).frame(maxWidth: .infinity).padding() }
                }
                .padding(.vertical, 8)
                .frame(width: geo.size.width)
            }
            .refreshable { await reload() }
        }
        .background(HGTheme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
        .task(id: key) {
            if let z = initialZone, !appliedInitial {
                appliedInitial = true
                if zone != z { zone = z; board = initialBoard ?? ""; return }   // 换分区触发重新加载；没指定榜就落到第一个（推荐榜）
                if let b = initialBoard, board != b { board = b; return }
            }
            await reload()
        }
    }

    static func defaultBoard(_ zone: String) -> String {
        ["all": "ranklist_hot_sc", "human": "human_hot_sc", "comic_series_rank": "comic_series_hot_rank",
         "ai_playlet": "ai_playlet_hot_sc", "series_album": "series_album_hot_sc"][zone] ?? "ranklist_hot_sc"
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
            // board 为空（刚换分区）：先按分区的推荐榜请求，目录回来再落位
            let b = currentBoard.isEmpty ? Self.defaultBoard(zone) : currentBoard
            let r = try await HGAPI.rank(zone: zone, board: b, offset: offset, session: session)
            guard k == key else { return }
            if let z = r.zones, !z.isEmpty {
                zones = z
                // 记住的分区 / 榜服务端没了：回到第一个
                if !z.contains(where: { $0.id == zone }) { zone = z.first?.id ?? "all" }
                if !isUpcoming, !visible(zone).contains(where: { $0.id == board }) { board = b }
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
                    HGWaterfall(items: items, width: geo.size.width - 32, loadMore: { Task { await loadMore() } })
                        .padding(.horizontal, 16).padding(.top, 4)
                    if loading { ProgressView().tint(HGTheme.textSecondary).frame(maxWidth: .infinity).padding() }
                }
                .padding(.vertical, 8)
                .frame(width: geo.size.width)
            }
            .refreshable { await reload() }
        }
        .background(HGTheme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
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
        .frame(maxWidth: .infinity)
    }
}

/// 粘贴红果分享链接（或整段分享口令）→ 打开剧集。
struct HGSearchView: View {
    /// 在标签栏里当根页：不自动弹键盘
    var isTab = false
    @State private var query = ""
    @State private var submitted = ""
    @State private var source: HGSourceKind = .hongguo
    @State private var items: [HGSeries] = []
    @State private var page = 1
    @State private var cursor: HGCursor?
    @State private var hasMore = false
    @State private var loading = false
    @State private var error: String?
    /// 边打字边出的剧名联想（红果官方搜索联想）
    @State private var suggestions: [String] = []
    @FocusState private var focused: Bool
    @State private var linked: HGSeries?

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(HGTheme.textTertiary)
                        TextField("剧名 / 演员 / 题材 / 分享链接", text: $query)
                            .textFieldStyle(.plain).foregroundStyle(HGTheme.textPrimary)
                            .focused($focused).submitLabel(.search)
                            .onSubmit { submit(query) }
                            .accessibilityIdentifier("hg.search.field")
                        if !query.isEmpty {
                            Button { query = ""; suggestions = []; focused = true } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(HGTheme.textTertiary)
                            }
                        }
                    }
                    .padding(.horizontal, 14).frame(height: 42)
                    .background(HGTheme.surface, in: Capsule())
                    .padding(.horizontal, 16)
                    Picker("来源", selection: $source) {
                        ForEach(HGSourceKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).padding(.horizontal, 16)
                    if !suggestions.isEmpty && query != submitted {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(suggestions, id: \.self) { t in
                                Button { query = t; submit(t) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(HGTheme.textTertiary)
                                        Text(t).font(.subheadline).foregroundStyle(HGTheme.textPrimary).lineLimit(1)
                                        Spacer()
                                        Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(HGTheme.textTertiary)
                                    }
                                    .padding(.vertical, 11).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("hg.search.suggest")
                                Divider().overlay(HGTheme.surfaceHigh)
                            }
                        }
                        .padding(.horizontal, 16)
                    } else {
                        if let error { Text(error).font(.footnote).foregroundStyle(HGTheme.textSecondary).padding(.horizontal, 16) }
                        if items.isEmpty && !loading && error == nil {
                            ContentUnavailableView(submitted.isEmpty ? "搜索短剧" : "没有结果", systemImage: "magnifyingglass")
                                .foregroundStyle(HGTheme.textSecondary).padding(.top, 40)
                        }
                        HGWaterfall(items: items, width: geo.size.width - 32, loadMore: { Task { await load(more: true) } })
                            .padding(.horizontal, 16)
                        if loading { ProgressView().tint(HGTheme.textSecondary).frame(maxWidth: .infinity).padding() }
                    }
                }
                .padding(.vertical, 8)
                .frame(width: geo.size.width)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .background(HGTheme.background)
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
        .onAppear { if submitted.isEmpty && !isTab { focused = true } }
        .navigationDestination(item: $linked) { HGDetailView(series: $0) }
        .task(id: query) {
            // 联想：停手 0.25 秒再请求；只有红果有联想
            let q = query.trimmingCharacters(in: .whitespaces)
            guard source == .hongguo, !q.isEmpty, q != submitted else { suggestions = []; return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let r = try? await HGAPI.suggest(q), q == query.trimmingCharacters(in: .whitespaces) else { return }
            suggestions = r.filter { $0 != "热搜" }
        }
        .onChange(of: source) { _, _ in Task { await load(more: false) } }
    }

    private func submit(_ text: String) {
        submitted = text.trimmingCharacters(in: .whitespaces)
        suggestions = []; focused = false
        // 粘的是红果分享链接 / 口令：直接打开那部剧（原来单独的「链接」按钮并进搜索框）
        if submitted.contains("http") || submitted.contains("hongguo") || submitted.contains("红果") {
            let t = submitted
            Task {
                if let id = try? await HGAPI.resolveShare(t), let d = try? await HGAPI.detail(id) {
                    linked = HGSeries(series_id: d.series_id, series_title: d.series_title, cover: d.cover,
                                      episode_count: d.episodes.count, description: d.description)
                } else {
                    await load(more: false)
                }
            }
            return
        }
        Task { await load(more: false) }
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

/// 换行排布（展开全部分类用）
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { y += rowH + spacing; x = 0; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
