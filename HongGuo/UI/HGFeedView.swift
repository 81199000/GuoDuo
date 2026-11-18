import SwiftUI

/// 推荐：红果五个片库（热播榜 / 真人剧 / 漫剧 / AI 剧 / 真人热播）拼成随机剧池，
/// 竖滑一屏一部，每部只放第 1 集；放完自动滑到下一部。感兴趣点「看全集」进整部剧。
/// 红果 App 自己的推荐流接口没逆向出来（上游也没有），这是上游「热播推荐 · 随机」同一思路。
@MainActor @Observable
final class HGFeedModel {
    /// 全 App 一份：打开 App 就在后台备片，点进推荐直接放本地文件
    static let shared = HGFeedModel()

    /// 一部推荐：哪部剧、放第几集（剧池放完了改放第 2 集）、画幅、本地文件已就绪
    struct Item: Identifiable, Hashable {
        let series: HGSeries
        let detail: HGDetail
        let index: Int
        let landscape: Bool
        var id: String { series.series_id }
        var episode: HGEpisode { detail.episodes[index] }
    }

    /// 老板定：横竖各备 5 部，全部下载解密完（共 10 部）推荐键才亮
    static let perBucket = 5
    /// 已经下好、还没放过的（按画幅分两桶）
    private(set) var ready: [Bool: [Item]] = [true: [], false: []]
    /// 推荐页正在滑的列表（只放当前姿态那一桶）
    private(set) var items: [Item] = []
    private(set) var wantLandscape = false
    var readyCount: Int { (ready[true]?.count ?? 0) + (ready[false]?.count ?? 0) + items.count }
    var isReady: Bool { (ready[true]?.count ?? 0) + (ready[false]?.count ?? 0) >= Self.perBucket * 2 || unlocked }
    /// 第一次凑齐 10 部后就一直亮（之后边看边补，不再变灰）
    private(set) var unlocked = false
    private(set) var error: String?

    // 剧池
    private var pool: [HGSeries] = []
    private var poolSeen = Set<String>()
    private var nextPage: [HGCategory: Int] = [:]
    private var exhausted = Set<HGCategory>()
    private static let sources: [HGCategory] = [.hot, .real, .comic, .ai, .hotReal]
    /// 第一轮（第 1 集）用完了：改从第 2 集推荐
    private var round = 0
    private var working = false

    // MARK: 看过的（跨次启动记住，下次不再推荐同一部的同一集）

    private static let watchedKey = "hg.feed.watched.v1"
    /// "seriesID#集序号"
    private var watched: Set<String> = Set(UserDefaults.standard.stringArray(forKey: watchedKey) ?? [])
    private func key(_ id: String, _ index: Int) -> String { "\(id)#\(index)" }

    /// 推荐页里真正看过（开播超过 3 秒）才记
    func markWatched(_ item: Item) {
        guard watched.insert(key(item.id, item.index)).inserted else { return }
        UserDefaults.standard.set(Array(watched), forKey: Self.watchedKey)
    }

    // MARK: 后台备片

    /// App 启动调一次；之后每放掉一部就自动补
    func start() {
        guard !working else { return }
        working = true
        Task { await fillLoop(); working = false }
    }

    private func need(_ l: Bool) -> Int {
        let queued = (ready[l]?.count ?? 0) + (l == wantLandscape ? items.count - consumed : 0)
        return Self.perBucket - queued
    }
    /// 推荐页已经划过的条数（当前那部算划过）
    var consumed = 0

    /// 一部一部来：取集列表 → 取源（拿画幅）→ 那一桶缺货才下载；两桶都满就停
    private func fillLoop() async {
        var misses = 0
        while need(true) > 0 || need(false) > 0 {
            guard let s = await nextCandidate() else {
                if round == 0 { round = 1; poolSeen = []; pool = []; nextPage = [:]; exhausted = []; continue }
                break
            }
            guard let d = try? await HGAPI.detail(s.series_id) else { misses += 1; continue }
            let idx = round == 0 ? d.episodes.firstIndex { $0.locked != true }
                                 : d.episodes.indices.dropFirst().first { d.episodes[$0].locked != true }
            guard let idx, !watched.contains(key(s.series_id, idx)) else { continue }
            guard let src = try? await HGAPI.source(d.episodes[idx].vid) else { continue }
            let l = src.isLandscape ?? false
            guard need(l) > 0 else { continue }            // 这一桶已经满了：跳过，找另一种画幅
            guard (try? await HGMediaCache.shared.file(for: d.episodes[idx].vid, source: src)) != nil else { continue }
            var series = s
            series.episode_count = d.episodes.count
            if (series.description ?? "").isEmpty { series.description = d.description }
            let item = Item(series: series, detail: d, index: idx, landscape: l)
            if l == wantLandscape && !items.isEmpty { items.append(item) } else { ready[l, default: []].append(item) }
            if isReady { unlocked = true }
            error = nil
            _ = misses
        }
        if readyCount == 0 { error = "推荐加载失败" }
    }

    /// 剧池里下一部（没看过的、红果来源）；不够就翻下一页
    private func nextCandidate() async -> HGSeries? {
        for _ in 0..<6 {
            if let i = pool.firstIndex(where: { _ in true }) { return pool.remove(at: i) }
            var fresh: [HGSeries] = []
            await withTaskGroup(of: [HGSeries].self) { group in
                for c in Self.sources where !exhausted.contains(c) {
                    let page = nextPage[c] ?? 1
                    group.addTask { (try? await HGAPI.browse(c, page: page))?.results ?? [] }
                }
                for await batch in group { fresh += batch }
            }
            for c in Self.sources where !exhausted.contains(c) {
                let p = (nextPage[c] ?? 1) + 1
                if p > 20 { exhausted.insert(c) } else { nextPage[c] = p }
            }
            let unique = fresh.filter { $0.source == .hongguo && poolSeen.insert($0.series_id).inserted }
            // 第一轮：看过第 1 集的直接不要；第二轮全要（第 2 集没看过）
            pool = unique.shuffled().filter { round > 0 || !watched.contains(key($0.series_id, 0)) }
            if fresh.isEmpty { return nil }
        }
        return nil
    }

    // MARK: 推荐页取片

    /// 进推荐 / 换姿态：把要的那一桶倒进列表（当前这部不动）
    func setWant(landscape want: Bool, keep currentID: String?) {
        let changed = want != wantLandscape
        wantLandscape = want
        if changed {
            let keepIdx = currentID.flatMap { id in items.firstIndex { $0.id == id } }
            let tail = keepIdx.map { Array(items[($0 + 1)...]) } ?? items
            // 换下来的还没看的放回原来的桶
            for it in tail where !watched.contains(key(it.id, it.index)) { ready[it.landscape, default: []].append(it) }
            items = keepIdx.map { Array(items[...$0]) } ?? []
            consumed = keepIdx ?? 0
        }
        items += ready[want] ?? []
        ready[want] = []
        start()
    }

    /// 推荐页划到第 idx 部：后面不够就补
    func advanced(to idx: Int) {
        consumed = idx
        start()
    }

    /// 下拉刷新：已经在列表里但没看的放回桶里，列表从桶重新排
    func reshuffle() {
        for it in items where !watched.contains(key(it.id, it.index)) { ready[it.landscape, default: []].append(it) }
        items = []; consumed = 0
        ready[true]?.shuffle(); ready[false]?.shuffle()
        setWant(landscape: wantLandscape, keep: nil)
        items += ready[wantLandscape] ?? []; ready[wantLandscape] = []
    }
}

/// 推荐要哪种画幅：横屏 / 竖屏半折叠（桌面）= 横屏片；竖屏 / 横屏半折叠（书本）= 竖屏片
enum HGFeedPosture {
    static func wantsLandscape(_ geo: GeometryProxy) -> Bool {
        let w = geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing
        let h = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
        if DYDuoMetrics.foldIsActive(geo) {
            if let split = DYDuoMetrics.hingeSplit(geo) { return !split.book }
            return w <= h          // 模拟器强制半折叠：窗口竖着 = 桌面姿态
        }
        return w > h
    }
}

struct HGFeedView: View {
    @State private var model = HGFeedModel.shared
    @State private var current: String?
    /// 当前一屏的播放会话（只有一个 AVPlayer 在跑）；下一部的第 1 集提前下好
    @State private var session: HGPlaybackSession?
    @State private var sessionID: String?
    @State private var full: HGPlayerRequest?
    /// 「全集」→ 推进这部剧的详情页（推荐页自己的导航栈里，返回就回推荐）
    @State private var detailSeries: HGSeries?
    @State private var active = false
    @Environment(\.hgFeedFront) private var front
    @Environment(\.scenePhase) private var scenePhase
    /// 横屏右侧标签胶囊在：整块推荐画面往左让出胶囊位置，胶囊不压视频、不跟视频右侧菜单栏叠在一起
    @Environment(\.hgSideRail) private var sideRail
    private var railReserve: CGFloat { HGSideTabRail.centerFromEdge + HGSideTabRail.width / 2 + 8 }

    var body: some View {
        GeometryReader { outer in
          let geo = CGSize(width: max(0, outer.size.width + outer.safeAreaInsets.leading + outer.safeAreaInsets.trailing - (sideRail ? railReserve : 0)),
                           height: outer.size.height + outer.safeAreaInsets.top + outer.safeAreaInsets.bottom)
          let posture = HGFeedPosture.wantsLandscape(outer)
          HStack(spacing: 0) {
            ZStack {
                Color.black
                if model.items.isEmpty {
                    VStack(spacing: 12) {
                        if let e = model.error {
                            Text(e).foregroundStyle(.white.opacity(0.7)).font(.footnote)
                            Button("重试") { model.start() }.buttonStyle(.bordered).tint(HGTheme.accent)
                        } else {
                            ProgressView().tint(.white)
                            Text(posture ? "正在准备横屏推荐…" : "正在准备竖屏推荐…")
                                .font(.footnote).foregroundStyle(.white.opacity(0.6))
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
                    .refreshable {
                        session?.stop(); session = nil; sessionID = nil
                        model.reshuffle(); current = model.items.first?.id
                    }
                    .accessibilityIdentifier("hg.feed")
                }
            }
            .frame(width: geo.width, height: geo.height)
            .clipped()
            if sideRail { Color.black.frame(width: railReserve) }
          }
          .ignoresSafeArea()
          .onChange(of: posture, initial: true) { _, want in
              model.setWant(landscape: want, keep: current)
              if current == nil || !model.items.contains(where: { $0.id == current }) { current = model.items.first?.id }
          }
        }
        .ignoresSafeArea()
        .toolbarVisibility(.hidden, for: .navigationBar)
        .onChange(of: current) { _, id in focus(id) }
        // 列表从空到有（切到还没备好的那种画幅、等它下完）：落到第一部
        .onChange(of: model.items.first?.id) { _, first in if current == nil { current = first } }
        // 开播 3 秒算看过：下次启动不再推荐同一集
        .onChange(of: (session?.position ?? 0) >= 3) { _, watched in
            if watched, let id = sessionID, let it = model.items.first(where: { $0.id == id }) { model.markWatched(it) }
        }
        // 只有推荐真的在前台才放：切到别的 tab 暂停，切回来接着放
        .onChange(of: front, initial: true) { _, f in
            active = f
            if f { if session == nil { focus(current) } else { session?.resumeIfSuspended() } }
            else { session?.suspend() }
        }
        .onDisappear { if !front { active = false; session?.suspend() } }
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
            // 相邻页：封面占位（片子已经在本地，滑到就开播）
            ZStack {
                HGCover(url: item.series.coverURL).blur(radius: 18).opacity(0.4)
                Text(item.series.series_title).font(.headline).foregroundStyle(.white.opacity(0.85))
            }
            .clipped()
            .allowsHitTesting(false)
        }
    }

    /// 滑到某一部：停掉上一部、给这部建会话。片子都是提前下好的本地文件，建好就能播
    private func focus(_ id: String?) {
        guard let id, let idx = model.items.firstIndex(where: { $0.id == id }) else { return }
        model.advanced(to: idx)
        guard sessionID != id, active else { return }
        let it = model.items[idx]
        session?.stop()
        let new = HGPlaybackSession(HGPlayerRequest(series: it.series, episodes: it.detail.episodes, index: it.index, startAt: 0), feedMode: true)
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
        guard let s = session else { return }
        s.suspend()
        full = HGPlayerRequest(series: s.series, episodes: item.detail.episodes, index: episode, startAt: episode == s.index ? pos : 0)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
