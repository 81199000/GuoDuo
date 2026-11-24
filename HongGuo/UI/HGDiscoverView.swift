import SwiftUI

/// 发现：红果 App 官方榜单（分区 × 榜）/ 找剧（类型、最新上架、上新时间、题材、人设…）/ 西饭 / 河马。
/// 榜单目录和筛选项都由红果服务端下发，不写死。
struct HGDiscoverView: View {
    enum Mode: String, CaseIterable { case rank, find, xifan, hema
        var title: String { switch self { case .rank: "榜单"; case .find: "找剧"; case .xifan: "西饭"; case .hema: "河马" } }
    }
    @AppStorage("hg.discover.mode") private var mode: Mode = .rank
    @AppStorage("hg.discover.zone") private var zone = "all"
    @AppStorage("hg.discover.board") private var board = "ranklist_hot_play_sc"
    @State private var zones: [HGRankZone] = []
    /// 找剧：当前选的（每组单选；空 = 不限）
    @State private var select: [String: String] = ["genre": "short_play", "sort": "hot_score"]
    @State private var filters: [HGFindFilter] = []
    @State private var moreFilters = false

    @State private var items: [HGSeries] = []
    @State private var offset = 0
    @State private var session = ""
    @State private var page = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?
    @State private var showShare = false
    @State private var openSeries: HGSeries?
    @State private var tabletop = false
    @Environment(\.hgSideRail) private var sideRail
    @State private var router = HGRootRouter.shared
    @State private var loadedKey = ""

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 12, alignment: .top)]
    /// 预约榜是还没上线的剧（点进去不能播），不放
    private static let hiddenBoards: Set<String> = ["ranklist_subscribe", "human_subscribe", "comic_series_subscribe", "ai_playlet_subscribe"]
    /// 找剧里外面常驻的几组；其余收进「更多筛选」
    private static let mainFilters: Set<String> = ["genre", "sort", "online_time", "category_dim_theme"]

    private var key: String {
        switch mode {
        case .rank: "rank|\(zone)|\(board)"
        case .find: "find|" + select.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        case .xifan, .hema: mode.rawValue
        }
    }

    var body: some View {
        GeometryReader { geo in
            if let crease = HGTabletop.crease(geo), !items.isEmpty {
                // 桌面姿态：标题收成小标题，选项条保留在最上面，下面一部一部翻
                VStack(spacing: 0) {
                    modeChips.padding(.vertical, 4)
                    HGDiscoverTabletop(items: items, crease: HGTabletop.Crease(top: crease.top - 36, bottom: crease.bottom - 36),
                                       loadMore: { Task { await loadMore() } },
                                       openDetail: { openSeries = $0 })
                        .id(key)
                }
                .onAppear { tabletop = true }
                .onDisappear { tabletop = false }
            } else {
                regular
            }
        }
        // 返回首页时不重拉（否则列表清空 → 桌面布局闪回普通网格、翻到哪部也丢了）
        .task(id: key) {
            guard key != loadedKey || items.isEmpty else { return }
            loadedKey = key
            await reload()
        }
        .navigationTitle("发现")
        .navigationBarTitleDisplayMode(tabletop ? .inline : .automatic)
        .toolbar {
            if !sideRail {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showShare = true } label: { Image(systemName: "link") }.accessibilityIdentifier("hg.share")
                }
            }
        }
        .onChange(of: router.shareTick) { _, _ in showShare = true }
        .sheet(isPresented: $showShare) { HGShareLinkSheet { openSeries = $0; showShare = false }.presentationDetents([.height(240)]) }
        .navigationDestination(item: $openSeries) { HGDetailView(series: $0) }
    }

    private var modeChips: some View {
        chips(Mode.allCases.map { ($0.rawValue, $0.title) }, selected: mode.rawValue, prefix: "hg.mode") {
            mode = Mode(rawValue: $0) ?? .rank
        }
    }

    @ViewBuilder private var options: some View {
        switch mode {
        case .rank:
            if !zones.isEmpty {
                chips(zones.map { ($0.id, $0.name) }, selected: zone, small: true, prefix: "hg.zone") { z in
                    guard z != zone else { return }
                    zone = z
                    // 换分区：落到该区同名的榜（热播 → 热播），没有就第一个
                    let boards = visibleBoards(z)
                    let name = zones.first { $0.id == zone }?.boards.first { $0.id == board }?.name
                    board = boards.first { $0.name == name }?.id ?? boards.first?.id ?? board
                }
                chips(visibleBoards(zone).map { ($0.id, $0.name) }, selected: board, small: true, prefix: "hg.board") { board = $0 }
            }
        case .find:
            ForEach(filters.filter { Self.mainFilters.contains($0.type) || moreFilters }) { f in filterRow(f) }
            if filters.contains(where: { !Self.mainFilters.contains($0.type) }) {
                Button { withAnimation(.snappy) { moreFilters.toggle() } } label: {
                    Label(moreFilters ? "收起筛选" : "更多筛选（人设 / 背景 / 频道）", systemImage: moreFilters ? "chevron.up" : "slider.horizontal.3")
                        .font(.footnote).foregroundStyle(HGTheme.textSecondary)
                }
                .padding(.horizontal)
                .accessibilityIdentifier("hg.find.more")
            }
        case .xifan, .hema:
            EmptyView()
        }
    }

    private func visibleBoards(_ z: String) -> [HGRankBoard] {
        (zones.first { $0.id == z }?.boards ?? []).filter { !Self.hiddenBoards.contains($0.id) }
    }

    /// 一组筛选：类型 / 排序必选；其余带「不限」
    private func filterRow(_ f: HGFindFilter) -> some View {
        let required = f.type == "genre" || f.type == "sort"
        let opts = (required ? [] : [("", "不限")]) + f.items.map { ($0.id, $0.name) }
        return HStack(spacing: 0) {
            Text(f.name).font(.caption).foregroundStyle(HGTheme.textTertiary).frame(width: 38, alignment: .leading).padding(.leading)
            chips(opts, selected: select[f.type] ?? "", small: true, prefix: "hg.find.\(f.type)", leading: 4) { v in
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

    private var regular: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                modeChips
                options
                if let error, items.isEmpty {
                    HGErrorView(message: error) { Task { await reload() } }
                } else if items.isEmpty && !loading && !hasMore {
                    Text("没有符合条件的剧").font(.footnote).foregroundStyle(HGTheme.textTertiary)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                }
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(items) { s in
                        NavigationLink(value: s) {
                            HGSeriesCard(series: s, subtitle: subtitle(s))
                                .overlay(alignment: .topLeading) { rankBadge(s) }
                        }
                        .buttonStyle(.plain)
                        .onAppear { if s.id == items.last?.id { Task { await loadMore() } } }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 4)
                if loading { ProgressView().tint(HGTheme.textSecondary).frame(maxWidth: .infinity).padding() }
            }
            .padding(.vertical, 8)
        }
        .refreshable { await reload() }
    }

    private func subtitle(_ s: HGSeries) -> String? {
        if let n = s.plays, n >= 10_000 {
            return n >= 100_000_000 ? String(format: "%.1f 亿次播放", Double(n) / 1e8) : "\(n / 10_000) 万次播放"
        }
        return s.tags?.prefix(2).joined(separator: " · ")
    }

    @ViewBuilder private func rankBadge(_ s: HGSeries) -> some View {
        if mode == .rank, let r = s.rank {
            Text("\(r)").font(.caption.weight(.heavy)).monospacedDigit()
                .frame(minWidth: 22, minHeight: 20).padding(.horizontal, 3)
                .background(r <= 3 ? HGTheme.accent : HGTheme.surfaceHigh.opacity(0.9),
                            in: UnevenRoundedRectangle(topLeadingRadius: HGTheme.radius, bottomTrailingRadius: HGTheme.radiusSmall, style: .continuous))
                .foregroundStyle(HGTheme.textPrimary)
                .accessibilityLabel("第 \(r) 名")
        }
    }

    private func chips(_ options: [(String, String)], selected: String, small: Bool = false, prefix: String, leading: CGFloat? = nil, pick: @escaping (String) -> Void) -> some View {
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
            .padding(.leading, leading ?? 16).padding(.trailing, 16)
        }
    }

    private func reload() async {
        offset = 0; session = ""; page = 1; hasMore = true; error = nil
        items = []
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, hasMore else { return }
        loading = true; defer { loading = false }
        let k = key
        do {
            let results: [HGSeries]
            switch mode {
            case .rank:
                let r = try await HGAPI.rank(zone: zone, board: board, offset: offset, session: session)
                guard k == key else { return }
                if let z = r.zones, !z.isEmpty { zones = z }
                results = r.results; offset = r.next; session = r.session; hasMore = r.hasMore
            case .find:
                let r = try await HGAPI.find(select, offset: offset, session: session)
                guard k == key else { return }
                if let f = r.filters, !f.isEmpty { filters = f }
                results = r.results; offset = r.next; session = r.session; hasMore = r.hasMore
            case .xifan, .hema:
                let r = try await HGAPI.browse(mode == .xifan ? .xifan : .hema, page: page)
                guard k == key else { return }
                results = r.results; hasMore = r.hasMore ?? false; page += 1
            }
            let seen = Set(items.map(\.id))
            items += results.filter { !seen.contains($0.id) }
        } catch {
            guard k == key else { return }
            self.error = error.localizedDescription
            hasMore = false
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
