import SwiftUI

struct HGDiscoverView: View {
    @State private var category: HGCategory = .hot
    @State private var items: [HGSeries] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(HGCategory.allCases) { c in
                            Button { category = c } label: {
                                Text(c.title).font(.subheadline.weight(c == category ? .semibold : .regular))
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(c == category ? HGTheme.accent : HGTheme.surface, in: Capsule())
                                    .foregroundStyle(c == category ? Color.white : HGTheme.textSecondary)
                            }
                            .accessibilityIdentifier("hg.category.\(c.rawValue)")
                        }
                    }
                    .padding(.horizontal)
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
        .task(id: category) { await reload() }
        .navigationTitle("发现")
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
            let current = category
            let r = try await HGAPI.browse(current, page: page)
            guard current == category else { return }
            let seen = Set(items.map(\.id))
            items += r.results.filter { !seen.contains($0.id) }
            hasMore = r.hasMore ?? false
            page += 1
        } catch {
            self.error = error.localizedDescription
            hasMore = false
        }
    }
}

struct HGSearchView: View {
    @State private var query = ""
    @State private var submitted = ""
    @State private var items: [HGSeries] = []
    @State private var page = 1
    @State private var cursor: HGCursor?
    @State private var hasMore = false
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
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
        .navigationTitle("搜索")
    }

    private func load(more: Bool) async {
        guard !submitted.isEmpty, !loading, !more || hasMore else { return }
        if !more { items = []; page = 1; cursor = nil }
        loading = true; error = nil; defer { loading = false }
        do {
            let r = try await HGAPI.search(submitted, page: page, cursor: cursor)
            let seen = Set(items.map(\.id))
            items += r.results.filter { !seen.contains($0.id) }
            hasMore = r.hasMore ?? false
            cursor = r.cursor; page += 1
        } catch { self.error = error.localizedDescription }
    }
}

struct HGMineView: View {
    @State private var library = HGLibrary.shared
    var body: some View {
        List {
            Section("继续观看") {
                if library.history.isEmpty { Text("还没有观看记录").foregroundStyle(HGTheme.textTertiary) }
                ForEach(library.history, id: \.series.id) { p in
                    NavigationLink(value: p.series) {
                        HStack(spacing: 12) {
                            HGCover(url: p.series.coverURL).frame(width: 46)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.series.series_title).foregroundStyle(HGTheme.textPrimary).lineLimit(1)
                                Text("看到第 \(p.episodeIndex + 1) 集").font(.caption).foregroundStyle(HGTheme.textSecondary)
                            }
                        }
                    }
                    .swipeActions { Button("删除", role: .destructive) { library.removeHistory(p.series.id) } }
                }
            }
            .listRowBackground(HGTheme.surface)
            Section("收藏") {
                if library.favorites.isEmpty { Text("还没有收藏").foregroundStyle(HGTheme.textTertiary) }
                ForEach(library.favorites) { s in
                    NavigationLink(value: s) { Text(s.series_title).foregroundStyle(HGTheme.textPrimary) }
                }
            }
            .listRowBackground(HGTheme.surface)
            Section {
                Text("片源来自红果公开接口，接口变化时可能失效。仅供个人学习使用。").font(.caption).foregroundStyle(HGTheme.textTertiary)
            }
            .listRowBackground(HGTheme.background)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("我的")
    }
}
