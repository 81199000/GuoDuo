import SwiftUI

struct HGDownloadsView: View {
    @State private var downloads = HGDownloads.shared

    var body: some View {
        List {
            if downloads.all.isEmpty {
                ContentUnavailableView("还没有下载", systemImage: "arrow.down.circle", description: Text("在剧集详情页点「下载」选择集数"))
                    .listRowBackground(Color.clear)
            }
            ForEach(downloads.all) { s in
                NavigationLink { HGDownloadSeriesView(seriesID: s.id) } label: {
                    HStack(spacing: 12) {
                        HGCover(url: s.series.coverURL).frame(width: 46)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.series.series_title).foregroundStyle(HGTheme.textPrimary).lineLimit(1)
                            Text("\(s.doneCount)/\(s.items.count) 集 · \(ByteCountFormatter.string(fromByteCount: s.bytes, countStyle: .file))")
                                .font(.caption).foregroundStyle(HGTheme.textSecondary)
                        }
                    }
                }
                .swipeActions { Button("删除", role: .destructive) { downloads.delete(seriesID: s.id) } }
            }
            .listRowBackground(HGTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(HGTheme.background)
        .navigationTitle("离线下载")
    }
}

struct HGDownloadSeriesView: View {
    let seriesID: String
    @State private var downloads = HGDownloads.shared
    @State private var selected: Set<String> = []
    @State private var editing = false
    @State private var playing: HGPlayerRequest?
    @State private var busy: String?
    @State private var shareURLs: [URL] = []
    @State private var showShare = false
    @State private var alert: String?

    private var entry: HGDownloads.Series? { downloads.all.first { $0.id == seriesID } }

    var body: some View {
        List {
            if let e = entry {
                ForEach(e.items) { item in
                    HStack {
                        if editing {
                            Image(systemName: selected.contains(item.vid) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(item.vid) ? HGTheme.accent : HGTheme.textTertiary)
                        }
                        Text("第 \(item.number) 集").foregroundStyle(HGTheme.textPrimary)
                        Spacer()
                        stateView(item)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if editing { if item.state.isDone { selected.formSymmetricDifference([item.vid]) } }
                        else if item.state.isDone { play(e, item) }
                    }
                    .swipeActions { Button("删除", role: .destructive) { downloads.delete(seriesID: seriesID, vids: [item.vid]) } }
                }
                .listRowBackground(HGTheme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(HGTheme.background)
        .navigationTitle(entry?.series.series_title ?? "下载")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editing ? "完成" : "选择") { editing.toggle(); selected = [] }
            }
            if editing {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("全选") { selected = Set(entry?.items.filter { $0.state.isDone }.map(\.vid) ?? []) }
                    Spacer()
                    Button { Task { await toPhotos() } } label: { Label("存相册", systemImage: "photo.badge.arrow.down") }.disabled(selected.isEmpty)
                    Button { share(selectedURLs) } label: { Label("导出", systemImage: "square.and.arrow.up") }.disabled(selected.isEmpty)
                    Button { Task { await merge() } } label: { Label("合并", systemImage: "rectangle.stack.badge.plus") }.disabled(selected.count < 2)
                    Button(role: .destructive) { downloads.delete(seriesID: seriesID, vids: selected); selected = [] } label: { Image(systemName: "trash") }.disabled(selected.isEmpty)
                }
            } else if entry?.items.contains(where: { if case .failed = $0.state { true } else { false } }) == true {
                ToolbarItem(placement: .bottomBar) { Button("重试失败的集") { downloads.retryFailed(seriesID) } }
            }
        }
        .overlay { if let busy { ProgressView(busy).padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: HGTheme.radius)) } }
        .fullScreenCover(item: $playing) { HGPlayerScreen(request: $0) }
        .sheet(isPresented: $showShare) { HGActivityView(items: shareURLs) }
        .alert(alert ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) { Button("好") {} }
    }

    @ViewBuilder private func stateView(_ item: HGDownloads.Item) -> some View {
        switch item.state {
        case .queued: Text("等待中").font(.caption).foregroundStyle(HGTheme.textTertiary)
        case .downloading(let p): ProgressView(value: p).frame(width: 80).tint(HGTheme.accent)
        case .done: Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).font(.caption).foregroundStyle(HGTheme.textSecondary)
        case .failed(let e): Text(e).font(.caption).foregroundStyle(HGTheme.accent).lineLimit(1)
        }
    }

    private var selectedURLs: [URL] {
        (entry?.items ?? []).filter { selected.contains($0.vid) }.map { downloads.file(seriesID, $0.vid) }
    }

    private func play(_ e: HGDownloads.Series, _ item: HGDownloads.Item) {
        let eps = e.items.filter { $0.state.isDone }.map { HGEpisode(vid: $0.vid, number: $0.number) }
        guard let idx = eps.firstIndex(where: { $0.vid == item.vid }) else { return }
        playing = HGPlayerRequest(series: e.series, episodes: eps, index: idx, startAt: 0)
    }

    private func toPhotos() async {
        busy = "正在存入相册…"; defer { busy = nil }
        do { try await downloads.saveToPhotos(selectedURLs); alert = "已存入相册（\(selected.count) 集）" }
        catch { alert = error.localizedDescription }
    }

    private func merge() async {
        guard let e = entry else { return }
        let vids = e.items.filter { selected.contains($0.vid) }.sorted { $0.number < $1.number }
        let title = "\(e.series.series_title) 第\(vids.first!.number)-\(vids.last!.number)集"
        busy = "正在合并…"; defer { busy = nil }
        do {
            let url = try await downloads.merge(seriesID: seriesID, vids: vids.map(\.vid), title: title) { _ in }
            share([url])
        } catch { alert = error.localizedDescription }
    }

    private func share(_ urls: [URL]) { shareURLs = urls; showShare = !urls.isEmpty }
}

struct HGActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
