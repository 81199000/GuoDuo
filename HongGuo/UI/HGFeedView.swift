import SwiftUI

/// 推荐：红果五个片库（热播榜 / 真人剧 / 漫剧 / AI 剧 / 真人热播）拼成随机剧池，
/// 竖滑一屏一部，每部只放第 1 集；放完自动滑到下一部。感兴趣点「看全集」进整部剧。
/// 红果 App 自己的推荐流接口没逆向出来（上游也没有），这是上游「热播推荐 · 随机」同一思路。
@MainActor @Observable
final class HGFeedModel {
    struct Item: Identifiable, Hashable {
        let series: HGSeries
        var id: String { series.series_id }
    }

    private(set) var items: [Item] = []
    private(set) var loading = false
    private(set) var error: String?
    /// 每部剧的第 1 集详情（集列表）：滑到附近才拉，拉过就缓存
    private(set) var details: [String: HGDetail] = [:]
    private var detailTasks: [String: Task<Void, Never>] = [:]
    private var seen = Set<String>()
    /// 每个类目下一次拉第几页
    private var nextPage: [HGCategory: Int] = [:]
    private var exhausted = Set<HGCategory>()
    private static let sources: [HGCategory] = [.hot, .real, .comic, .ai, .hotReal]

    /// 剧池补货：每个类目各拉一页，合并去重、打乱；已经看过 / 收藏过的往后排
    func refill() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        var fresh: [HGSeries] = []
        await withTaskGroup(of: [HGSeries].self) { group in
            for c in Self.sources where !exhausted.contains(c) {
                let page = nextPage[c] ?? 1
                group.addTask {
                    guard let r = try? await HGAPI.browse(c, page: page) else { return [] }
                    return r.results
                }
            }
            for await batch in group { fresh += batch }
        }
        for c in Self.sources where !exhausted.contains(c) {
            let p = (nextPage[c] ?? 1) + 1
            if p > 20 { exhausted.insert(c) } else { nextPage[c] = p }
        }
        let lib = HGLibrary.shared
        var unique: [HGSeries] = []
        for s in fresh where s.source == .hongguo && !seen.contains(s.series_id) {
            seen.insert(s.series_id); unique.append(s)
        }
        unique.shuffle()
        // 没看过的在前，看过 / 收藏过的往后
        let known = { (s: HGSeries) in lib.progress(for: s.id) != nil || lib.isFavorite(s.id) }
        unique = unique.filter { !known($0) } + unique.filter(known)
        if unique.isEmpty && items.isEmpty { error = "推荐加载失败，下拉重试" } else { error = nil }
        items += unique.map(Item.init)
    }

    func reset() async {
        items = []; details = [:]; seen = []; nextPage = [:]; exhausted = []
        detailTasks.values.forEach { $0.cancel() }; detailTasks = [:]
        await refill()
    }

    func ensureDetail(_ id: String) {
        guard details[id] == nil, detailTasks[id] == nil else { return }
        detailTasks[id] = Task { [weak self] in
            let d = try? await HGAPI.detail(id)
            guard let self else { return }
            self.detailTasks[id] = nil
            if let d { self.details[id] = d }
        }
    }
}

struct HGFeedView: View {
    @State private var model = HGFeedModel()
    @State private var current: String?
    /// 当前一屏的播放会话（只有一个 AVPlayer 在跑）；下一部的第 1 集提前下好
    @State private var session: HGPlaybackSession?
    @State private var sessionID: String?
    @State private var full: HGPlayerRequest?
    /// 「全集」→ 推进这部剧的详情页（推荐页自己的导航栈里，返回就回推荐）
    @State private var detailSeries: HGSeries?
    @State private var active = true
    @Environment(\.scenePhase) private var scenePhase
    /// 横屏右侧标签胶囊在：整块推荐画面往左让出胶囊位置，胶囊不压视频、不跟视频右侧菜单栏叠在一起
    @Environment(\.hgSideRail) private var sideRail
    private var railReserve: CGFloat { HGSideTabRail.centerFromEdge + HGSideTabRail.width / 2 + 8 }

    var body: some View {
        GeometryReader { outer in
          let geo = CGSize(width: max(0, outer.size.width + outer.safeAreaInsets.leading + outer.safeAreaInsets.trailing - (sideRail ? railReserve : 0)),
                           height: outer.size.height + outer.safeAreaInsets.top + outer.safeAreaInsets.bottom)
          HStack(spacing: 0) {
            ZStack {
                Color.black
                if model.items.isEmpty {
                    if model.loading { ProgressView().tint(.white) }
                    else if let e = model.error {
                        VStack(spacing: 12) {
                            Text(e).foregroundStyle(.white.opacity(0.7)).font(.footnote)
                            Button("重试") { Task { await model.reset() } }.buttonStyle(.bordered).tint(HGTheme.accent)
                        }
                    }
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(model.items) { item in
                                page(item, size: geo)
                                    .frame(width: geo.width, height: geo.height)
                                    .id(item.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $current)
                    .scrollIndicators(.hidden)
                    .refreshable { await model.reset(); current = model.items.first?.id }
                    .accessibilityIdentifier("hg.feed")
                }
            }
            .frame(width: geo.width, height: geo.height)
            .clipped()
            if sideRail { Color.black.frame(width: railReserve) }
          }
          .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .toolbarVisibility(.hidden, for: .navigationBar)
        .task { if model.items.isEmpty { await model.refill(); current = model.items.first?.id } }
        .onChange(of: current) { _, id in focus(id) }
        .onChange(of: model.details) { _, _ in if session == nil || sessionID != current { focus(current) } }
        .onAppear { active = true; session?.resumeIfSuspended() }
        .onDisappear { active = false; session?.suspend() }
        .onChange(of: scenePhase) { _, p in
            if p == .background, !HGBackgroundPlayback.enabled, let s = session, !s.pip.active, !s.pip.starting { s.pauseForBackground() }
        }
        .navigationDestination(item: $detailSeries) { HGDetailView(series: $0) }
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.environment["HG_DEMO_DETAIL"] == "1" else { return }
            for _ in 0..<40 {
                try? await Task.sleep(for: .seconds(1))
                if let s = session, s.isPlaying, s.position > 3 { openDetail(); return }
            }
        }
        #endif
        .fullScreenCover(item: $full, onDismiss: { if active { session?.resumeIfSuspended() } }) { HGPlayerScreen(request: $0) }
    }

    @ViewBuilder private func page(_ item: HGFeedModel.Item, size: CGSize) -> some View {
        if item.id == sessionID, let session {
            HGPlayerScreen(feedSession: session, hooks: HGFeedHooks(
                openSeries: { _ in openDetail() },
                openEpisode: { i in openFull(item, episode: i, at: 0) },
                back: { HGRootRouter.shared.go(.discover) },
                next: { step(+1, from: item.id) },
                previous: { step(-1, from: item.id) }))
                .id(item.id)
        } else {
            // 相邻页：封面占位，滑动不黑屏
            ZStack {
                HGCover(url: item.series.coverURL).blur(radius: 18).opacity(0.4)
                VStack(spacing: 8) {
                    Text(item.series.series_title).font(.headline).foregroundStyle(.white.opacity(0.85))
                    ProgressView().tint(.white)
                }
            }
            .clipped()
            .allowsHitTesting(false)
        }
    }

    /// 滑到某一部：停掉上一部、给这部建会话放第 1 集；顺手拉后两部的集列表并预下载下一部第 1 集
    private func focus(_ id: String?) {
        guard let id, let idx = model.items.firstIndex(where: { $0.id == id }) else { return }
        for j in idx..<min(model.items.count, idx + 3) { model.ensureDetail(model.items[j].id) }
        if idx >= model.items.count - 4 { Task { await model.refill() } }
        if let nextID = model.items[safe: idx + 1]?.id, let d = model.details[nextID],
           let ep = d.episodes.first(where: { $0.locked != true }) {
            HGMediaCache.shared.prefetch(ep.vid)
        }
        guard sessionID != id else { return }
        guard let d = model.details[id] else { return }   // 详情回来后 onChange(details) 再进来
        guard let first = d.episodes.firstIndex(where: { $0.locked != true }) else {
            advance(from: id); return                       // 整部锁着：直接跳下一部
        }
        session?.stop()
        var s = model.items[idx].series
        s.episode_count = d.episodes.count
        if (s.description ?? "").isEmpty { s.description = d.description }
        let new = HGPlaybackSession(HGPlayerRequest(series: s, episodes: d.episodes, index: first, startAt: 0), feedMode: true)
        new.onFeedEnd = { [id] in advance(from: id) }
        if !active || full != nil { new.suspend() }
        session = new
        sessionID = id
        new.start()
    }

    private func advance(from id: String) {
        guard active, full == nil, detailSeries == nil, current == id, let idx = model.items.firstIndex(where: { $0.id == id }),
              let next = model.items[safe: idx + 1] else { return }
        withAnimation(.easeInOut(duration: 0.35)) { current = next.id }
    }

    private func step(_ d: Int, from id: String) {
        guard let idx = model.items.firstIndex(where: { $0.id == id }), let t = model.items[safe: idx + d] else { return }
        withAnimation(.easeInOut(duration: 0.35)) { current = t.id }
    }

    private func openDetail() {
        guard let s = session else { return }
        s.suspend()
        detailSeries = s.series
    }

    private func openFull(_ item: HGFeedModel.Item, episode: Int, at pos: Double) {
        guard let d = model.details[item.id], let s = session else { return }
        s.suspend()
        full = HGPlayerRequest(series: s.series, episodes: d.episodes, index: episode, startAt: episode == s.index ? pos : 0)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
