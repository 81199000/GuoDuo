import SwiftUI

struct HGDiscoverView: View {
    @State private var category: HGCategory = .hot
    @State private var genre = ""
    @State private var genres: [HGGenre] = []
    @State private var items: [HGSeries] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?
    @State private var showShare = false
    @State private var openSeries: HGSeries?
    @State private var tabletop = false
    @State private var loadedKey = ""

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 12, alignment: .top)]

    var body: some View {
        GeometryReader { geo in
            if let crease = HGTabletop.crease(geo), !items.isEmpty {
                // 桌面姿态：标题收成小标题，分类条保留在最上面，下面一部一部翻
                VStack(spacing: 0) {
                    chips(HGCategory.allCases.map { ($0.rawValue, $0.title) }, selected: category.rawValue, prefix: "hg.category") {
                        category = HGCategory(rawValue: $0) ?? .hot
                    }
                    .padding(.vertical, 4)
                    HGDiscoverTabletop(items: items, crease: HGTabletop.Crease(top: crease.top - 36, bottom: crease.bottom - 36),
                                       loadMore: { Task { await loadMore() } },
                                       openDetail: { openSeries = $0 })
                        .id(category.rawValue)
                }
                .onAppear { tabletop = true }
                .onDisappear { tabletop = false }
            } else {
                regular
            }
        }
        // 返回首页时不重拉（否则列表清空 → 桌面布局闪回普通网格、翻到哪部也丢了）
        .task(id: "\(category.rawValue)|\(genre)") {
            let key = "\(category.rawValue)|\(genre)"
            guard key != loadedKey || items.isEmpty else { return }
            loadedKey = key
            await reload()
        }
        .onChange(of: category) { _, _ in genre = ""; genres = [] }
        .navigationTitle("发现")
        .navigationBarTitleDisplayMode(tabletop ? .inline : .automatic)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showShare = true } label: { Image(systemName: "link") }.accessibilityIdentifier("hg.share")
            }
        }
        .sheet(isPresented: $showShare) { HGShareLinkSheet { openSeries = $0; showShare = false }.presentationDetents([.height(240)]) }
        .navigationDestination(item: $openSeries) { HGDetailView(series: $0) }
    }

    private var regular: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                chips(HGCategory.allCases.map { ($0.rawValue, $0.title) }, selected: category.rawValue, prefix: "hg.category") {
                    category = HGCategory(rawValue: $0) ?? .hot
                }
                if category.supportsGenres && !genres.isEmpty {
                    chips([("", "全部")] + genres.map { ($0.slug, $0.label) }, selected: genre, small: true, prefix: "hg.genre") { genre = $0 }
                }
                if let error, items.isEmpty {
                    HGErrorView(message: error) { Task { await reload() } }
                }
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(items) { s in
                        NavigationLink(value: s) { HGSeriesCard(series: s, subtitle: s.tags?.prefix(2).joined(separator: " · ")) }
                            .buttonStyle(.plain)
                            .onAppear { if s.id == items.last?.id { Task { await loadMore() } } }
                    }
                }
                .padding(.horizontal)
                if loading { ProgressView().tint(HGTheme.textSecondary).frame(maxWidth: .infinity).padding() }
            }
            .padding(.vertical, 8)
        }
        .refreshable { await reload() }
    }

    private func chips(_ options: [(String, String)], selected: String, small: Bool = false, prefix: String, pick: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.0) { value, title in
                    let on = value == selected
                    Button { pick(value) } label: {
                        Text(title).font((small ? Font.footnote : .subheadline).weight(on ? .semibold : .regular))
                            .padding(.horizontal, small ? 11 : 14).padding(.vertical, small ? 5 : 7)
                            .background(on ? (small ? HGTheme.accent.opacity(0.2) : HGTheme.accent) : HGTheme.surface, in: Capsule())
                            .foregroundStyle(on ? (small ? HGTheme.accent : Color.white) : HGTheme.textSecondary)
                    }
                    .accessibilityIdentifier("\(prefix).\(value.isEmpty ? "all" : value)")
                }
            }
            .padding(.horizontal)
        }
    }

    private func reload() async {
        page = 1; hasMore = true; error = nil
        items = []
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, hasMore else { return }
        loading = true; defer { loading = false }
        do {
            let current = category, g = genre
            let r = try await HGAPI.browse(current, page: page, genre: current.supportsGenres ? g : "")
            guard current == category, g == genre else { return }
            let seen = Set(items.map(\.id))
            items += r.results.filter { !seen.contains($0.id) }
            if let gs = r.genres, !gs.isEmpty, current.supportsGenres { genres = gs }
            hasMore = r.hasMore ?? false
            page += 1
        } catch {
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
