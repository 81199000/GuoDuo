import SwiftUI
import AVFoundation

/// 推荐：红果五个片库（热播榜 / 真人剧 / 漫剧 / AI 剧 / 真人热播）拼成随机剧池，
/// 竖滑一屏一部，每部只放第 1 集；放完自动滑到下一部。感兴趣点「看全集」进整部剧。
/// 红果 App 自己的推荐流接口没逆向出来（上游也没有），这是上游「热播推荐 · 随机」同一思路。
@MainActor @Observable
final class HGFeedModel {
    struct Item: Identifiable, Hashable {
        let series: HGSeries
        var id: String { series.series_id }
    }

    /// 剧池（全部拉到的，按随机顺序）；items = 其中画幅符合当前姿态的
    private var pool: [Item] = []
    private(set) var items: [Item] = []
    private(set) var loading = false
    /// 第 1 集是不是横屏片（取源接口给宽高，不用下载）；nil = 还没探
    private(set) var landscape: [String: Bool] = [:]
    private var probing = Set<String>()
    /// 当前姿态要的画幅：true = 只放横屏片，false = 只放竖屏片
    private(set) var wantLandscape = false
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
        if unique.isEmpty && pool.isEmpty { error = "推荐加载失败，下拉重试" } else { error = nil }
        pool += unique.map(Item.init)
        probeAhead()
    }

    /// 姿态变了：当前这部不动（不打断播放），后面的按新画幅重排
    func setWant(landscape want: Bool, keep currentID: String?) {
        guard want != wantLandscape || items.isEmpty else { return }
        wantLandscape = want
        let keepIdx = currentID.flatMap { id in items.firstIndex { $0.id == id } }
        items = keepIdx.map { Array(items[...$0]) } ?? []
        consumed = keepIdx ?? 0
        rebuildTail()
        probeAhead()
    }

    /// 已探好画幅、方向对的往 items 后面接（剧池原顺序），保证列表里每一部都是对的画幅
    private func rebuildTail() {
        let have = Set(items.map(\.id))
        for it in pool where !have.contains(it.id) && !unplayable.contains(it.id) && landscape[it.id] == wantLandscape {
            items.append(it)
        }
    }

    /// 已经滑到第几部（界面告诉模型，用来判断后面还备了多少）
    var consumed = 0
    private var unplayable = Set<String>()

    /// 后台按剧池顺序探画幅（并发 4 个，约 1 秒一部）：保证当前之后至少备好 6 部对的画幅
    func probeAhead() {
        guard items.count - consumed < 6 || probing.isEmpty else { return }
        let slots = max(0, 4 - probing.count)
        let pending = pool.lazy.filter { self.landscape[$0.id] == nil && !self.probing.contains($0.id) }.prefix(slots)
        if pending.isEmpty, pool.count == landscape.count { Task { await refill() } }
        for it in pending {
            probing.insert(it.id)
            Task { [weak self] in
                let ori = await Self.firstEpisodeOrientation(it.id)
                guard let self else { return }
                self.probing.remove(it.id)
                if let d = ori.detail { self.details[it.id] = d }
                if let l = ori.landscape {
                    self.landscape[it.id] = l
                    if l == self.wantLandscape, !self.items.contains(where: { $0.id == it.id }) { self.items.append(it) }
                } else {
                    self.landscape[it.id] = !self.wantLandscape   // 放不了的（锁 / 只有 ByteVC2）：永远不进列表
                    self.unplayable.insert(it.id)
                }
                if self.pool.count - self.landscape.count < 12 { Task { await self.refill() } }
                self.probeAhead()
            }
        }
    }

    /// 拉集列表 + 取第 1 集可播的片源宽高
    private static func firstEpisodeOrientation(_ id: String) async -> (detail: HGDetail?, landscape: Bool?) {
        guard let d = try? await HGAPI.detail(id),
              let ep = d.episodes.first(where: { $0.locked != true }) else { return (nil, nil) }
        guard let src = try? await HGAPI.source(ep.vid) else { return (d, nil) }
        return (d, src.isLandscape ?? false)
    }

    func reset() async {
        items = []; pool = []; details = [:]; seen = []; nextPage = [:]; exhausted = []
        landscape = [:]; probing = []; unplayable = []; consumed = 0
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
          // 老板定的规则：横屏只放横屏片、竖屏只放竖屏片；
          // 竖屏半折叠（上视频下操作台，视频窗是横的）算横屏；横屏半折叠（左视频右选集，视频窗是竖的）算竖屏
          let posture = HGFeedPosture.wantsLandscape(outer)
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
                        // DouDuo 同款：翻页收尾 0.10s；系统「减少动态效果」打开时退回系统分页
                        .background(DYPagingSpeedBridge(ids: model.items.map(\.id), currentID: $current))
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
          .onChange(of: posture, initial: true) { _, want in
              model.setWant(landscape: want, keep: current)
              if current == nil || !model.items.contains(where: { $0.id == current }) { current = model.items.first?.id }
          }
        }
        .ignoresSafeArea()
        .toolbarVisibility(.hidden, for: .navigationBar)
        .task { if model.items.isEmpty { await model.refill() } }
        // 列表从空变有（画幅探好第一部）时落到第一部
        .onChange(of: model.items.first?.id) { _, first in if current == nil { current = first } }
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
                .overlay(alignment: .topLeading) {
                    Color.clear.frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityIdentifier("hg.feed.orientation")
                        .accessibilityLabel("want=\(model.wantLandscape ? "L" : "P") aspect=\(String(format: "%.2f", session.videoAspect)) pos=\(Int(session.position)) id=\(item.id)")
                }
        } else {
            // 相邻页（DouDuo 提前挂载思路的轻量版）：下一部第 1 集已经下好就铺它的首帧，滑过去直接是真画面；
            // 还没下好才退回模糊封面 + 转圈
            HGFeedPlaceholder(item: item, firstVid: model.details[item.id]?.episodes.first(where: { $0.locked != true })?.vid)
        }
    }

    /// 滑到某一部：停掉上一部、给这部建会话放第 1 集；顺手拉后两部的集列表并预下载下一部第 1 集
    private func focus(_ id: String?) {
        guard let id, let idx = model.items.firstIndex(where: { $0.id == id }) else { return }
        model.consumed = idx
        for j in idx..<min(model.items.count, idx + 3) { model.ensureDetail(model.items[j].id) }
        model.probeAhead()
        for j in [idx + 1, idx + 2, idx - 1] {
            if let nid = model.items[safe: j]?.id, let d = model.details[nid],
               let ep = d.episodes.first(where: { $0.locked != true }) {
                Task { await HGMediaCache.shared.prefetch(ep.vid) }
            }
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
        // 自动连播：像手滑一样把下一部推上来（DouDuo DYPagerAdvance）；没接上时退回直接切
        if !DYPagerAdvance.request(from: id, to: next.id) { withAnimation(.easeInOut(duration: 0.35)) { current = next.id } }
    }

    private func step(_ d: Int, from id: String) {
        guard let idx = model.items.firstIndex(where: { $0.id == id }), let t = model.items[safe: idx + d] else { return }
        if !DYPagerAdvance.request(from: id, to: t.id) { withAnimation(.easeInOut(duration: 0.35)) { current = t.id } }
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

/// 推荐流相邻页占位：本地已有首集文件 → 截第 0.1 秒那一帧铺满（跟播放器同一个填充规则）
private struct HGFeedPlaceholder: View {
    let item: HGFeedModel.Item
    let firstVid: String?
    @State private var frame: UIImage?
    @AppStorage("hg.fillWidth") private var fillWidth = true

    var body: some View {
        ZStack {
            Color.black
            if let frame {
                Image(uiImage: frame).resizable()
                    .aspectRatio(contentMode: fillWidth ? .fill : .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .accessibilityIdentifier("hg.feed.firstFrame")
            } else {
                HGCover(url: item.series.coverURL).blur(radius: 18).opacity(0.4)
                VStack(spacing: 8) {
                    Text(item.series.series_title).font(.headline).foregroundStyle(.white.opacity(0.85))
                    ProgressView().tint(.white)
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .task(id: firstVid) { await loadFrame() }
    }

    private func loadFrame() async {
        guard frame == nil, let vid = firstVid else { return }
        // 下载在 focus 里已经排上了；这里等它落盘（最多 20 秒），再截首帧
        for _ in 0..<40 {
            if let url = await HGMediaCache.shared.cachedFile(vid) {
                let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 1080, height: 1080)
                if let (cg, _) = try? await gen.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)) {
                    frame = UIImage(cgImage: cg)
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
        }
    }
}

/// 推荐流要哪种画幅
enum HGFeedPosture {
    static func wantsLandscape(_ geo: GeometryProxy) -> Bool {
        let w = geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing
        let h = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
        if DYDuoMetrics.foldIsActive(geo) {
            // 半折叠：看视频窗（折痕切出来的那一半）是横是竖
            if let split = DYDuoMetrics.hingeSplit(geo) { return !split.book }
            return w <= h          // 模拟器回退：窗口竖着 = 桌面姿态（上下分）= 横屏片
        }
        return w > h
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
