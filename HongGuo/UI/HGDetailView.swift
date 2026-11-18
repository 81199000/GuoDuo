import SwiftUI

struct HGDetailView: View {
    let series: HGSeries
    @State private var detail: HGDetail?
    @State private var error: String?
    @State private var playing: HGPlayerRequest?
    @State private var library = HGLibrary.shared
    @State private var downloads = HGDownloads.shared
    @State private var selecting = false
    @State private var picked: Set<String> = []

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
        .task { if detail == nil { await load() } }
        .fullScreenCover(item: $playing) { req in HGPlayerScreen(request: req) }
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

                if let text = resolvedSeries.description, !text.isEmpty {
                    Text(text).font(.footnote).foregroundStyle(HGTheme.textSecondary).lineSpacing(3)
                }

                if let error { HGErrorView(message: error) { Task { await load() } } }

                if let d = detail {
                    HStack {
                        Text(selecting ? "选择要下载的集（\(picked.count)）" : "选集").font(.headline).foregroundStyle(HGTheme.textPrimary)
                        Spacer()
                        if selecting {
                            Button(picked.count == d.episodes.filter({ $0.locked != true }).count ? "全不选" : "全选") {
                                let all = Set(d.episodes.filter { $0.locked != true }.map(\.vid))
                                picked = picked == all ? [] : all
                            }.font(.footnote)
                            Button("取消") { selecting = false; picked = [] }.font(.footnote)
                        } else {
                            Button { selecting = true } label: { Label("下载", systemImage: "arrow.down.circle") }
                                .font(.footnote).accessibilityIdentifier("hg.detail.download")
                        }
                    }
                    let current = library.progress(for: series.id)?.episodeIndex
                    LazyVGrid(columns: grid, spacing: 8) {
                        ForEach(Array(d.episodes.enumerated()), id: \.element.id) { i, ep in
                            Button {
                                if selecting { if ep.locked != true { picked.formSymmetricDifference([ep.vid]) } }
                                else { start(at: i, resume: i == current) }
                            } label: {
                                let on = selecting ? picked.contains(ep.vid) : i == current
                                Text("\(ep.number)").font(.subheadline.monospacedDigit())
                                    .frame(maxWidth: .infinity, minHeight: 40)
                                    .background(on ? HGTheme.accent.opacity(selecting ? 0.85 : 0.18) : HGTheme.surface,
                                                in: RoundedRectangle(cornerRadius: HGTheme.radiusSmall, style: .continuous))
                                    .foregroundStyle(selecting && on ? Color.white : on ? HGTheme.accent : (ep.locked == true ? HGTheme.textTertiary : HGTheme.textPrimary))
                                    .overlay(alignment: .topTrailing) { badge(ep) }
                            }
                            .accessibilityIdentifier("hg.episode.\(ep.number)")
                        }
                    }
                    if selecting {
                        Button {
                            downloads.enqueue(resolvedSeries, episodes: d.episodes.filter { picked.contains($0.vid) })
                            selecting = false; picked = []
                        } label: {
                            Text("下载 \(picked.count) 集").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(picked.isEmpty ? HGTheme.surfaceHigh : HGTheme.accent, in: RoundedRectangle(cornerRadius: HGTheme.radius))
                                .foregroundStyle(.white)
                        }
                        .disabled(picked.isEmpty)
                        .accessibilityIdentifier("hg.detail.download.confirm")
                    }
                } else if error == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding()
        }
    }

    @ViewBuilder private func badge(_ ep: HGEpisode) -> some View {
        if ep.locked == true {
            Image(systemName: "lock.fill").font(.system(size: 8)).padding(4).foregroundStyle(HGTheme.textTertiary)
        } else if let st = downloads.state(ep.vid) {
            switch st {
            case .done: Image(systemName: "arrow.down.circle.fill").font(.system(size: 9)).padding(3).foregroundStyle(HGTheme.textSecondary)
            case .downloading, .queued: Image(systemName: "arrow.down.circle").font(.system(size: 9)).padding(3).foregroundStyle(HGTheme.textTertiary)
            case .failed: Image(systemName: "exclamationmark.circle").font(.system(size: 9)).padding(3).foregroundStyle(HGTheme.accent)
            }
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
