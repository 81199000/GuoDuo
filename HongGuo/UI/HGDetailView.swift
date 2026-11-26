import SwiftUI

struct HGDetailView: View {
    let series: HGSeries
    @State private var detail: HGDetail?
    @State private var error: String?
    @State private var playing: HGPlayerRequest?
    @State private var library = HGLibrary.shared
    @State private var info: HGSeriesInfo?
    @State private var seasons: [HGSeason] = []
    @State private var reviews: [HGSeriesReview] = []
    @State private var reviewTotal = 0

    private let grid = [GridItem(.adaptive(minimum: 56), spacing: 8)]

    private var resolvedSeries: HGSeries {
        var s = series
        if let d = detail {
            if (s.cover ?? "").isEmpty { s.cover = d.cover }
            if (s.description ?? "").isEmpty { s.description = d.description }
            s.episode_count = d.episodes.count
        }
        return s
    }

    var body: some View {
        GeometryReader { geo in
            if let crease = HGTabletop.crease(geo) {
                HGDetailTabletop(series: resolvedSeries, detail: detail, crease: crease,
                                 current: library.progress(for: series.id)?.episodeIndex,
                                 resumeTitle: continueTitle) { start(at: $0, resume: $1) }
            } else {
                regular
            }
        }
        .background(HGTheme.background)
        .navigationBarTitleDisplayMode(.inline)
        // 发现页把导航栏藏了（官方剧场排版），详情要显示回来，不然没有返回键
        .toolbarVisibility(.visible, for: .navigationBar)
        .task { if detail == nil { await load() } }
        .task { await loadExtras() }

        .hgPresentsPlayer($playing)
    }

    private var regular: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    HGCover(url: resolvedSeries.coverURL).frame(width: 112)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(series.series_title).font(.title3.weight(.semibold)).foregroundStyle(HGTheme.textPrimary)
                        if let n = detail?.episodes.count ?? series.episode_count, n > 0 {
                            Text("全 \(n) 集").font(.footnote).foregroundStyle(HGTheme.textSecondary)
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 10) {
                            Button { start(at: library.progress(for: series.id)?.episodeIndex ?? 0, resume: true) } label: {
                                Label(continueTitle, systemImage: "play.fill").font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 16).padding(.vertical, 9)
                                    .background(HGTheme.accent, in: Capsule()).foregroundStyle(.white)
                            }
                            .disabled(detail == nil)
                            .accessibilityIdentifier("hg.detail.play")
                            Button { library.toggleFavorite(resolvedSeries) } label: {
                                Image(systemName: library.isFavorite(series.id) ? "heart.fill" : "heart")
                                    .font(.title3).foregroundStyle(library.isFavorite(series.id) ? HGTheme.accent : HGTheme.textSecondary)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .fixedSize(horizontal: false, vertical: true)

                infoBlock
                if seasons.count > 1 { seasonBar }

                if let text = resolvedSeries.description, !text.isEmpty {
                    Text(text).font(.footnote).foregroundStyle(HGTheme.textSecondary).lineSpacing(3)
                }

                if !reviews.isEmpty { reviewBlock }

                if let error { HGErrorView(message: error) { Task { await load() } } }

                if let d = detail {
                    HStack {
                        Text("选集").font(.headline).foregroundStyle(HGTheme.textPrimary)
                        Spacer()
                    }
                    let current = library.progress(for: series.id)?.episodeIndex
                    LazyVGrid(columns: grid, spacing: 8) {
                        ForEach(Array(d.episodes.enumerated()), id: \.element.id) { i, ep in
                            Button {
                                start(at: i, resume: i == current)
                            } label: {
                                let on = i == current
                                Text("\(ep.number)").font(.subheadline.monospacedDigit())
                                    .frame(maxWidth: .infinity, minHeight: 40)
                                    .background(on ? HGTheme.accent.opacity(0.18) : HGTheme.surface,
                                                in: RoundedRectangle(cornerRadius: HGTheme.radiusSmall, style: .continuous))
                                    .foregroundStyle(on ? HGTheme.accent : (ep.locked == true ? HGTheme.textTertiary : HGTheme.textPrimary))
                                    .overlay(alignment: .topTrailing) { badge(ep) }
                            }
                            .accessibilityIdentifier("hg.episode.\(ep.number)")
                        }
                    }
                } else if error == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding()
        }
    }

    // MARK: 补充信息 / 选季 / 剧评

    private static func count(_ n: Int) -> String {
        n >= 100_000_000 ? String(format: "%.1f亿", Double(n) / 1e8) : n >= 10_000 ? "\(n / 10_000)万" : "\(n)"
    }

    @ViewBuilder private var infoBlock: some View {
        if let info {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    if let h = info.heat, h > 0 { stat("flame.fill", Self.count(h) + "热度") }
                    if let p = info.plays, p > 0 { stat("play.fill", Self.count(p) + "播放") }
                    if let f = info.followers, f > 0 { stat("heart.fill", Self.count(f) + "在追") }
                    if let b = info.badge {
                        Text(b).font(.caption2.weight(.bold)).foregroundStyle(HGTheme.textPrimary)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(HGTheme.accent, in: Capsule())
                    }
                }
                if let tags = info.tags, !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(tags, id: \.self) { t in
                                Text(t).font(.caption).foregroundStyle(HGTheme.textSecondary)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(HGTheme.surface, in: RoundedRectangle(cornerRadius: HGTheme.radiusSmall, style: .continuous))
                            }
                        }
                    }
                }
                if let a = info.actors, !a.isEmpty {
                    Text("演员：\(a)").font(.caption).foregroundStyle(HGTheme.textTertiary).lineLimit(1)
                }
            }
            .accessibilityIdentifier("hg.detail.info")
        }
    }

    private func stat(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.caption.weight(.medium)).foregroundStyle(HGTheme.textSecondary).labelStyle(.titleAndIcon)
    }

    private var seasonBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选季").font(.headline).foregroundStyle(HGTheme.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(seasons) { s in
                        let on = s.series_id == series.series_id
                        NavigationLink(value: s.series) {
                            Text("第\(s.season)季").font(.subheadline.weight(on ? .semibold : .regular))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(on ? HGTheme.accent : HGTheme.surface, in: Capsule())
                                .foregroundStyle(on ? HGTheme.textPrimary : HGTheme.textSecondary)
                        }
                        .disabled(on)
                        .accessibilityIdentifier("hg.season.\(s.season)")
                    }
                }
            }
        }
    }

    private var reviewBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: HGReviewsRoute(seriesID: series.series_id, title: series.series_title)) {
                HStack {
                    Text("剧评").font(.headline).foregroundStyle(HGTheme.textPrimary)
                    Text("\(reviewTotal)").font(.subheadline).foregroundStyle(HGTheme.textTertiary)
                    Spacer()
                    Text("全部").font(.subheadline).foregroundStyle(HGTheme.textSecondary)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(HGTheme.textTertiary)
                }
                // 整行可点（中间 Spacer 默认点不中）
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("hg.detail.reviews")
            ForEach(reviews.prefix(2)) { r in HGSeriesReviewRow(review: r, lines: 3) }
        }
    }

    private func loadExtras() async {
        guard series.source == .hongguo else { return }
        async let i = try? HGAPI.seriesInfo(series.series_id)
        async let r = try? HGAPI.reviews(series.series_id, offset: 0)
        info = await i
        if let r = await r { reviews = r.items; reviewTotal = r.total }
        if let album = info?.album, let s = try? await HGAPI.seasons(series.series_id, album: album) { seasons = s.results }
    }

    @ViewBuilder private func badge(_ ep: HGEpisode) -> some View {
        if ep.locked == true {
            Image(systemName: "lock.fill").font(.system(size: 8)).padding(4).foregroundStyle(HGTheme.textTertiary)
        }
    }

    private var continueTitle: String {
        if let p = library.progress(for: series.id) { return "续播第 \(p.episodeIndex + 1) 集" }
        return "播放"
    }

    private func start(at index: Int, resume: Bool) {
        guard let d = detail else { return }
        let pos = resume ? (library.progress(for: series.id)?.position ?? 0) : 0
        playing = HGPlayerRequest(series: resolvedSeries, episodes: d.episodes, index: index, startAt: pos)
    }

    private func load() async {
        error = nil
        do { detail = try await HGAPI.detail(series.series_id) }
        catch { self.error = error.localizedDescription }
    }
}

/// 一条剧评
struct HGSeriesReviewRow: View {
    let review: HGSeriesReview
    var lines: Int? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            HGCachedImage(url: review.avatar.flatMap(URL.init(string:))) { Circle().fill(HGTheme.surfaceHigh) }
            .frame(width: 30, height: 30).clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(review.author).font(.caption.weight(.medium)).foregroundStyle(HGTheme.textSecondary)
                    if let s = review.score, s > 0 {
                        Text(String(format: "%.0f分", Double(s))).font(.caption2.weight(.semibold)).foregroundStyle(HGTheme.accent)
                    }
                    Spacer()
                    if let l = review.likes, l > 0 {
                        Label("\(l)", systemImage: "hand.thumbsup").font(.caption2).foregroundStyle(HGTheme.textTertiary)
                    }
                }
                Text(review.content).font(.subheadline).foregroundStyle(HGTheme.textPrimary).lineLimit(lines)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 全部剧评
struct HGReviewsScreen: View {
    let seriesID: String
    let title: String
    @State private var items: [HGSeriesReview] = []
    @State private var total = 0
    @State private var next = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        List {
            if let error, items.isEmpty { Text(error).foregroundStyle(HGTheme.textSecondary).listRowBackground(HGTheme.background) }
            ForEach(items) { r in
                HGSeriesReviewRow(review: r).listRowBackground(HGTheme.background)
                    .onAppear { if r.id == items.last?.id { Task { await load() } } }
            }
            if loading { ProgressView().frame(maxWidth: .infinity).listRowBackground(HGTheme.background) }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(HGTheme.background)
        .toolbarVisibility(.visible, for: .navigationBar)
        .accessibilityIdentifier("hg.reviews.list")
        .navigationTitle(total > 0 ? "剧评 \(total)" : "剧评").navigationBarTitleDisplayMode(.inline)
        .task { if items.isEmpty { await load() } }
    }
    private func load() async {
        guard !loading, hasMore else { return }
        loading = true; defer { loading = false }
        do {
            let r = try await HGAPI.reviews(seriesID, offset: next)
            let seen = Set(items.map(\.id))
            items += r.items.filter { !seen.contains($0.id) }
            total = r.total; next = r.next; hasMore = r.hasMore
        } catch { self.error = error.localizedDescription; hasMore = false }
    }
}

/// 剧评页路由（跟剧集详情一样走根导航栈的 value 导航）
struct HGReviewsRoute: Hashable { let seriesID: String; let title: String }
