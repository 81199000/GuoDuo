import SwiftUI
import QuartzCore

/// 推荐：登录了红果账号 → 先用红果首页「推荐」流（账号个性化，同绿果TV forYou）；
/// 没登录 / 推荐流失败或翻完 → 红果五个片库（热播榜 / 真人剧 / 漫剧 / AI 剧 / 真人热播）拼成随机剧池。
/// 竖滑一屏一部，每部只放第 1 集；放完自动滑到下一部。感兴趣点「看全集」进整部剧。
@MainActor @Observable
final class HGFeedModel {
    /// 全 App 一份：打开 App 就在后台备片，点进推荐直接放本地文件
    static let shared = HGFeedModel()

    /// 一部推荐：哪部剧、放第几集（剧池放完了改放第 2 集）、画幅、本地文件已就绪
    struct Item: Identifiable, Hashable, Codable {
        let series: HGSeries
        let detail: HGDetail
        let index: Int
        let landscape: Bool
        var id: String { series.series_id }
        var episode: HGEpisode { detail.episodes[index] }
    }

    /// 当前这部后面始终备好几部（本地文件）。没有数量门槛、不分横竖，推荐键一直能点
    /// （真机：5 部 + 一部一部串行下，一秒一划十几部就追上、卡住等下载；改 8 部 + 3 路并行）
    static let ahead = 8
    /// 同时备几部（取详情 → 取源 → 下载解密）
    static let parallel = 4
    /// 单部下载超过这么久就先跳过换下一部（真机/模拟器实测：多数 0.4~2 秒，个别 CDN 节点 20~40 秒，会把补货堵死）
    static let slowLimit: Duration = .seconds(8)
    /// 正在备的剧（并行时别重复备同一部）
    private var preparing = Set<String>()
    /// 下载慢被跳过的：过一会儿再排回剧池（多半已在后台下完，秒进）
    private var slowSkipped: [HGSeries] = []
    /// 推荐列表：下好的都在这里（看过的也留着，划回去还能看）
    private(set) var items: [Item] = []
    private(set) var wantLandscape = false
    var isReady: Bool { true }
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

    // 账号推荐流（红果首页「推荐」，带登录 cookie）
    private var signedIn = false
    private var checkedAccount = false
    private var forYouPool: [HGSeries] = []
    private var forYouOffset = 0
    private var forYouSession = ""
    private var forYouFails = 0
    /// 连续失败 3 次 / 翻完：本次启动不再走推荐流，全用片库随机
    private var forYouDown = false
    /// 当前推荐是不是来自账号推荐流（调试 / 界面提示用）
    private(set) var personal = false
    /// 推荐频道：16 推荐 / 39 真人剧 / 36 漫剧（同红果首页顶部）
    private(set) var channel = UserDefaults.standard.string(forKey: "hg.feed.channel") ?? "16"
    static let channels: [(String, String)] = [("16", "推荐"), ("39", "真人剧"), ("36", "漫剧")]

    /// 换频道：当前这部和已预热的下一部留着，后面没划到的存货换成新频道的
    func setChannel(_ c: String) {
        guard c != channel else { return }
        channel = c
        UserDefaults.standard.set(c, forKey: "hg.feed.channel")
        forYouPool = []; forYouOffset = 0; forYouSession = ""; forYouFails = 0; forYouDown = false
        if items.count > consumed + 2 { items = Array(items.prefix(consumed + 2)); persist() }
        start()
    }

    // MARK: 看过的（跨次启动记住，下次不再推荐同一部的同一集）

    private static let watchedKey = "hg.feed.watched.v1"
    /// "seriesID#集序号"
    private var watched: Set<String> = Set(UserDefaults.standard.stringArray(forKey: watchedKey) ?? [])
    private func key(_ id: String, _ index: Int) -> String { "\(id)#\(index)" }

    /// 推荐页里真正看过（开播超过 3 秒）才记
    func markWatched(_ item: Item) {
        guard watched.insert(key(item.id, item.index)).inserted else { return }
        UserDefaults.standard.set(Array(watched), forKey: Self.watchedKey)
        persist()
    }

    // MARK: 存货持久化（下次打开不用重新下）

    private static let stockURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("hg-feed-stock.json")

    init() {
        try? FileManager.default.createDirectory(at: Self.stockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: Self.stockURL),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            var seenIDs = Set<String>()
            items = saved.filter { HGMediaCache.hasFile($0.episode.vid) && !watched.contains(key($0.id, $0.index)) && seenIDs.insert($0.id).inserted }
        }
        pinStock()
    }

    /// 存货变了：写盘 + 告诉缓存这些文件别淘汰
    private func persist() {
        let stock = items.filter { !watched.contains(key($0.id, $0.index)) }
        if let data = try? JSONEncoder().encode(stock) { try? data.write(to: Self.stockURL, options: .atomic) }
        pinStock()
    }

    private func pinStock() {
        let vids = Set(items.dropFirst(max(0, consumed - 1)).map(\.episode.vid))
        Task { await HGMediaCache.shared.setPinned(vids) }
    }

    // MARK: 后台备片

    /// App 启动调一次；之后每放掉一部就自动补
    func start() {
        guard !working else { return }
        working = true
        Task { await fillLoop(); working = false }
    }

    /// 推荐页当前划到第几部
    var consumed = 0
    private var stockAhead: Int { items.count - consumed - 1 }

    /// 一部一部来：取集列表 → 取源 → 下载解密 → 进列表。拿到什么放什么，不按横竖挑
    private func fillLoop() async {
        // 登录 / 退出了：推荐流从头来（换成新账号的推荐）
        let nowSignedIn = (try? await HGAPI.accountStatus())?.signedIn == true
        if nowSignedIn != signedIn || !checkedAccount {
            checkedAccount = true
            signedIn = nowSignedIn
            // 已备好的存货不丢（丢了就得现下、划几部就卡住）；账号推荐接在后面
            forYouPool = []; forYouOffset = 0; forYouSession = ""; forYouFails = 0; forYouDown = false
        }
        // 最多 parallel 部同时备；哪部先下完先进列表
        await withTaskGroup(of: (String, Item?).self) { group in
            var running = 0
            var drained = false
            while true {
                while !drained && running < Self.parallel && stockAhead + running < Self.ahead {
                    guard let s = await nextCandidate() else {
                        if running == 0 {
                            if round == 0 { round = 1; poolSeen = []; pool = []; nextPage = [:]; exhausted = []; continue }
                            drained = true
                        }
                        break
                    }
                    if inStock(s.series_id) || preparing.contains(s.series_id) { continue }
                    preparing.insert(s.series_id)
                    let r = round
                    group.addTask { @MainActor in (s.series_id, await self.prepare(s, round: r)) }
                    running += 1
                }
                guard running > 0, let (id, item) = await group.next() else { break }
                running -= 1
                preparing.remove(id)
                if let item, !inStock(item.id) {
                    insert(item)
                    error = nil
                    persist()
                }
            }
        }
        if items.isEmpty { error = "推荐加载失败" }
    }

    /// 备一部：取集列表 → 取源 → 下载解密；失败 / 这集看过了回 nil
    private func prepare(_ s: HGSeries, round: Int) async -> Item? {
        let t0 = CACurrentMediaTime()
        guard let d = try? await HGAPI.detail(s.series_id) else { HGTrace.log("fill 详情失败 \(s.series_title)"); return nil }
        let t1 = CACurrentMediaTime()
        let idx = round == 0 ? d.episodes.firstIndex { $0.locked != true }
                             : d.episodes.indices.dropFirst().first { d.episodes[$0].locked != true }
        guard let idx, !watched.contains(key(s.series_id, idx)) else { return nil }
        guard let src = try? await HGAPI.source(d.episodes[idx].vid) else { HGTrace.log("fill 取源失败 \(s.series_title)"); return nil }
        let t2 = CACurrentMediaTime()
        let vid = d.episodes[idx].vid
        // 超时不取消：后台接着下完留在缓存里，下次轮到这部直接用；推荐先拿别的快的
        let download = Task { try await HGMediaCache.shared.file(for: vid, source: src) }
        let ok = await withTaskGroup(of: Bool?.self) { g in
            g.addTask { (try? await download.value) != nil }
            g.addTask { try? await Task.sleep(for: Self.slowLimit); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
        guard let ok else { HGTrace.log("fill 下载慢跳过 \(s.series_title)"); slowSkipped.append(s); return nil }
        guard ok else { HGTrace.log("fill 下载失败 \(s.series_title)"); return nil }
        HGTrace.log(String(format: "fill 详情%.0fms 取源%.0fms 下载%.0fms 余%d %@", (t1 - t0) * 1000, (t2 - t1) * 1000,
                           (CACurrentMediaTime() - t2) * 1000, stockAhead, s.series_title))
        var series = s
        series.episode_count = d.episodes.count
        if (series.description ?? "").isEmpty { series.description = d.description }
        return Item(series: series, detail: d, index: idx, landscape: src.isLandscape ?? false)
    }

    /// 只往列表末尾追加：在中间插会让分页滚动位置跳（真机：补货插进来，推荐页一路滚回第 1 部）
    private func insert(_ item: Item) {
        items.append(item)
    }

    private func inStock(_ id: String) -> Bool {
        items.contains { $0.id == id }
    }

    /// 账号推荐流里下一部（第一轮才用：推荐流每部都从第 1 集放，看过第 1 集的跳过）
    private func nextForYou() async -> HGSeries? {
        guard round == 0, !forYouDown else { return nil }
        for _ in 0..<6 {
            while !forYouPool.isEmpty {
                let s = forYouPool.removeFirst()
                if !watched.contains(key(s.series_id, 0)) && !inStock(s.series_id) { return s }
            }
            guard let page = try? await HGAPI.forYou(offset: forYouOffset, session: forYouSession, channel: channel) else {
                forYouFails += 1
                if forYouFails >= 3 { forYouDown = true }
                return nil
            }
            forYouFails = 0
            personal = page.personal == true
            forYouSession = page.session
            // 推荐流每次请求都会变，去重靠 poolSeen（片库随机那边也不会再出同一部）
            forYouPool = page.results.filter { poolSeen.insert($0.series_id).inserted }
            if !page.hasMore || page.next <= forYouOffset { forYouDown = true }
            forYouOffset = page.next
            if forYouPool.isEmpty && forYouDown { return nil }
        }
        return nil
    }

    /// 剧池里下一部（没看过的、红果来源）；不够就翻下一页。登录了先从账号推荐流里拿
    private func nextCandidate() async -> HGSeries? {
        // 跳过的慢片：后台大概率下完了，先把它们排回来
        if slowSkipped.count >= 2 || (!slowSkipped.isEmpty && Int.random(in: 0..<3) == 0) {
            let s = slowSkipped.removeFirst()
            poolSeen.insert(s.series_id)
            return s
        }
        if let s = await nextForYou() { return s }
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

    /// 进推荐 / 换姿态：当前这部之后，同画幅的往前排
    func setWant(landscape want: Bool, keep currentID: String?) {
        wantLandscape = want
        let keepIdx = currentID.flatMap { id in items.firstIndex { $0.id == id } } ?? -1
        let from = keepIdx + 1
        if from < items.count {
            let tail = items[from...]
            items = Array(items[..<from]) + tail.filter { $0.landscape == want } + tail.filter { $0.landscape != want }
        }
        start()
    }

    /// 推荐页划到第 idx 部：后面不够就补
    func advanced(to idx: Int) {
        if idx != consumed { HGTrace.log("feed 划到 \(idx + 1)/\(items.count) 余\(items.count - idx - 1) 补货中=\(working)") }
        consumed = idx
        pinStock()
        start()
    }

    /// 下拉刷新：没看过的打乱重排
    func reshuffle() {
        items = items.filter { !watched.contains(key($0.id, $0.index)) }.shuffled()
        consumed = 0
        setWant(landscape: wantLandscape, keep: nil)
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
    /// 下一部的播放器：提前建好、打开本地文件、停在第一帧（只备 1 个，不抢解码）
    @State private var warm: HGPlaybackSession?
    @State private var warmID: String?
    @AppStorage("hg.fillWidth") private var fillWidth = true
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
                            Text("正在准备推荐…")
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
                        .hgDisableScrollToTop()   // 点屏幕顶部不再跳回第一部
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $current)
                    .scrollIndicators(.hidden)
                    .refreshable {
                        session?.stop(); session = nil; sessionID = nil
                        warm?.stop(); warm = nil; warmID = nil
                        model.reshuffle(); current = model.items.first?.id
                    }
                    .accessibilityIdentifier("hg.feed")
                }
            }
            .frame(width: geo.width, height: geo.height)
            .clipped()
            // 顶部频道：推荐 / 真人剧 / 漫剧（红果首页同款；登录了按账号推荐）
            .overlay(alignment: .top) {
                HStack(spacing: 18) {
                    ForEach(HGFeedModel.channels, id: \.0) { id, name in
                        let on = id == model.channel
                        Button { model.setChannel(id) } label: {
                            Text(name).font(on ? .headline : .subheadline)
                                .foregroundStyle(.white.opacity(on ? 1 : 0.6))
                                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("hg.feed.channel.\(name)")
                    }
                }
                .padding(.top, max(outer.safeAreaInsets.top, 12) + 4)
            }
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
        // 推荐页不要主菜单（竖屏半折叠下半屏是触控板，系统标签栏会盖在上面）
        .toolbarVisibility(.hidden, for: .tabBar)
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
            guard let n = Double(ProcessInfo.processInfo.environment["HG_DEMO_AUTOSWIPE"] ?? "") else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let s = session, s.position > n, let id = sessionID else { continue }
                step(+1, from: id)
                try? await Task.sleep(for: .seconds(1))
            }
        }
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
        } else if item.id == warmID, let warm {
            // 下一部：真画面停在第一帧，滑的过程中就能看到
            ZStack {
                Color.black
                HGVideoLayer(player: warm.player, fillWidth: fillWidth, pip: warm.pip)
            }
            .clipped()
            .allowsHitTesting(false)
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
        session?.stop()
        if warmID == id, let w = warm {
            // 预热好的那部直接转正：已经打开、首帧已解，接着放
            warm = nil; warmID = nil
            session = w; sessionID = id
            if active && full == nil { w.resumeIfSuspended() }
        } else {
            warm?.stop(); warm = nil; warmID = nil
            let new = makeSession(model.items[idx])
            if !active || full != nil { new.suspend() }
            session = new; sessionID = id
            new.start()
        }
        // 当前这部开播后再备下一部（不跟它抢解码）
        let next = model.items[safe: idx + 1]
        Task { @MainActor in
            // 当前这部稳定播过 2 秒再备下一部（真机：一开播就预热下一部，两个播放器抢解码，当前这部会跳回开头）
            for _ in 0..<100 where sessionID == id && (session?.position ?? 0) < 2 { try? await Task.sleep(for: .milliseconds(100)) }
            guard sessionID == id, warmID == nil, let next, next.id != id else { return }
            let w = makeSession(next)
            w.suspend()
            warm = w; warmID = next.id
            w.start()
        }
    }

    private func makeSession(_ it: HGFeedModel.Item) -> HGPlaybackSession {
        let s = HGPlaybackSession(HGPlayerRequest(series: it.series, episodes: it.detail.episodes, index: it.index, startAt: 0), feedMode: true)
        s.onFeedEnd = { [id = it.id] in advance(from: id) }
        return s
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

enum HGT {
    static let t0 = CACurrentMediaTime()
    static func log(_ s: String) { print(String(format: "HGT %6d %@", Int((CACurrentMediaTime() - t0) * 1000), s)) }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
