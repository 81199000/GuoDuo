import SwiftUI

/// 竖屏半折叠（桌面姿态）判定：返回折痕在本视图里的 y；不是桌面姿态返回 nil。
/// 真机走系统铰链区域（DouDuo hingeSplit）；模拟器 DOUDUO_FOLD=1 时按 DouDuo 回退比例 55 / 45。
enum HGTabletop {
    /// 折痕带（上沿 top、下沿 bottom），上下内容都躲开它
    struct Crease { let top: CGFloat; let bottom: CGFloat }
    static func crease(_ geo: GeometryProxy) -> Crease? {
        guard DYDuoMetrics.foldIsActive(geo) else { return nil }
        if let h = DYDuoMetrics.hingeSplit(geo) {
            return h.book ? nil : Crease(top: h.video.maxY, bottom: h.panel.minY)
        }
        // 模拟器回退：在全屏 55% 处假装有一条 24pt 的折痕带（换算到本视图坐标）。
        // 竖横判断看窗口，不看本视图（大标题导航栏会把视图压成宽 > 高）
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.bounds.size
            ?? CGSize(width: geo.size.width, height: geo.size.height)
        guard window.width <= window.height else { return nil }
        let frame = geo.frame(in: .global)
        let screenH = window.height
        let mid = screenH * 0.55 - frame.minY
        return Crease(top: mid - 12, bottom: mid + 12)
    }
}

/// 选集网格（首页 / 详情页桌面姿态的下半屏共用）
struct HGEpisodeGrid: View {
    let episodes: [HGEpisode]
    var current: Int?
    let play: (Int) -> Void
    private let grid = [GridItem(.adaptive(minimum: 52), spacing: 8)]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: grid, spacing: 8) {
                    ForEach(Array(episodes.enumerated()), id: \.element.id) { i, ep in
                        Button { play(i) } label: {
                            let on = i == current
                            Text("\(ep.number)").font(.subheadline.monospacedDigit())
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(on ? HGTheme.accent.opacity(0.18) : HGTheme.surface,
                                            in: RoundedRectangle(cornerRadius: HGTheme.radiusSmall, style: .continuous))
                                .foregroundStyle(on ? HGTheme.accent : (ep.locked == true ? HGTheme.textTertiary : HGTheme.textPrimary))
                                .overlay(alignment: .topTrailing) {
                                    if ep.locked == true {
                                        Image(systemName: "lock.fill").font(.system(size: 8)).padding(4).foregroundStyle(HGTheme.textTertiary)
                                    }
                                }
                        }
                        .id(i)
                        .accessibilityIdentifier("hg.episode.\(ep.number)")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
        }
    }
}

/// 下半屏标题行：「选集 · 共 N 集」+ 右侧续播
private struct HGEpisodeHeader: View {
    let count: Int
    var resume: String?
    var onResume: (() -> Void)?
    var body: some View {
        HStack {
            Text("选集").font(.headline).foregroundStyle(HGTheme.textPrimary)
            Text("共 \(count) 集").font(.footnote).foregroundStyle(HGTheme.textSecondary)
            Spacer()
            if let resume, let onResume {
                Button(action: onResume) {
                    Label(resume, systemImage: "play.fill").font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(HGTheme.accent, in: Capsule()).foregroundStyle(.white)
                }
                .accessibilityIdentifier("hg.tabletop.resume")
            }
        }
        .padding(.horizontal, 16).padding(.top, 14)
    }
}

/// 上半屏影片信息（大封面 + 剧名 + 集数 / 题材 + 简介）
struct HGSeriesInfoPane: View {
    let series: HGSeries
    var episodeCount: Int?
    var description: String?
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            HGCover(url: series.coverURL)
                .aspectRatio(3 / 4, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: HGTheme.radius, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Text(series.series_title).font(.title3.weight(.bold)).foregroundStyle(HGTheme.textPrimary).lineLimit(2)
                HStack(spacing: 8) {
                    if let n = episodeCount ?? series.episode_count, n > 0 { Text("全 \(n) 集") }
                    if let tags = series.tags, !tags.isEmpty { Text(tags.prefix(3).joined(separator: " · ")) }
                }
                .font(.footnote).foregroundStyle(HGTheme.textSecondary).lineLimit(1)
                if let d = description ?? series.description, !d.isEmpty {
                    Text(d).font(.footnote).foregroundStyle(HGTheme.textSecondary).lineSpacing(3)
                        .lineLimit(nil).frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hg.tabletop.info")
    }
}

/// 详情页桌面姿态：上影片信息，下选集
struct HGDetailTabletop: View {
    let series: HGSeries
    let detail: HGDetail?
    let crease: HGTabletop.Crease
    let current: Int?
    let resumeTitle: String
    let play: (Int, Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HGSeriesInfoPane(series: series, episodeCount: detail?.episodes.count, description: detail?.description)
                .frame(height: max(0, crease.top))
            Color.clear.frame(height: max(0, crease.bottom - crease.top))   // 折痕带空出来
            VStack(spacing: 0) {
                if let d = detail {
                    HGEpisodeHeader(count: d.episodes.count, resume: resumeTitle) { play(current ?? 0, true) }
                    HGEpisodeGrid(episodes: d.episodes, current: current) { play($0, $0 == current) }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            .background(HGTheme.surface.opacity(0.35))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("hg.tabletop.episodes")
        }
    }
}

/// 首页桌面姿态：上半屏横滑翻剧（一次一部，大封面 + 信息），下半屏是当前这部的选集，点集直接播
struct HGDiscoverTabletop: View {
    let items: [HGSeries]
    let crease: HGTabletop.Crease
    let loadMore: () -> Void
    let openDetail: (HGSeries) -> Void
    @SceneStorage("hg.tabletop.focus") private var focused: String?
    @State private var detail: HGDetail?
    @State private var detailError: String?
    @State private var playing: HGPlayerRequest?
    @State private var library = HGLibrary.shared

    private var focus: HGSeries? { items.first { $0.id == focused } ?? items.first }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { s in
                        HGSeriesInfoPane(series: s)
                            .contentShape(Rectangle())
                            .onTapGesture { openDetail(s) }
                            .containerRelativeFrame(.horizontal)
                            .id(s.id)
                            .onAppear { if s.id == items.last?.id { loadMore() } }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $focused)
            .scrollIndicators(.hidden)
            .frame(height: max(0, crease.top))
            .overlay(alignment: .bottom) { pager }
            Color.clear.frame(height: max(0, crease.bottom - crease.top))
            VStack(spacing: 0) {
                if let s = focus, let d = detail, d.series_id == s.series_id {
                    let p = library.progress(for: s.id)
                    HGEpisodeHeader(count: d.episodes.count,
                                    resume: p.map { "续播第 \($0.episodeIndex + 1) 集" } ?? "播放") { play(s, d, p?.episodeIndex ?? 0, resume: true) }
                    HGEpisodeGrid(episodes: d.episodes, current: p?.episodeIndex) { play(s, d, $0, resume: $0 == p?.episodeIndex) }
                } else if let detailError {
                    Text(detailError).font(.footnote).foregroundStyle(HGTheme.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            .background(HGTheme.surface.opacity(0.35))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("hg.tabletop.episodes")
        }
        .task(id: focus?.id) { await loadDetail() }
        .fullScreenCover(item: $playing) { HGPlayerScreen(request: $0) }
    }

    private var pager: some View {
        let idx = items.firstIndex { $0.id == focus?.id } ?? 0
        return Text("\(idx + 1) / \(items.count) · 左右滑换剧")
            .font(.caption2.monospacedDigit()).foregroundStyle(HGTheme.textTertiary)
            .padding(.bottom, 6)
    }

    private func play(_ s: HGSeries, _ d: HGDetail, _ i: Int, resume: Bool) {
        let pos = resume ? (library.progress(for: s.id)?.position ?? 0) : 0
        var series = s
        series.episode_count = d.episodes.count
        if (series.description ?? "").isEmpty { series.description = d.description }
        playing = HGPlayerRequest(series: series, episodes: d.episodes, index: i, startAt: pos)
    }

    private func loadDetail() async {
        guard let s = focus else { return }
        detailError = nil
        if detail?.series_id == s.series_id { return }
        do {
            try await Task.sleep(for: .milliseconds(250))   // 快速连翻时只拉停下来的那部
            let d = try await HGAPI.detail(s.series_id)
            if focus?.id == s.id { detail = d }
        } catch is CancellationError {
        } catch { if focus?.id == s.id { detailError = error.localizedDescription } }
    }
}
