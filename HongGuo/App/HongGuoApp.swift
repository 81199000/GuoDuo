import SwiftUI

final class HGAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        // 普通 iPhone：播放页在屏上时跟重力感应横竖转，其他页面竖屏；iPad 不限制。
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        // Duo 展开 / 半折时是大屏，横竖都跟系统转（DouDuo 一样）；普通 iPhone 竖屏为主
        if DYDuoMetrics.isDuoHardware || HGOrientation.allowLandscape || HGOrientation.followsSensor { return [.portrait, .landscapeLeft, .landscapeRight] }
        return .portrait
    }
}

@main
struct HongGuoApp: App {
    @UIApplicationDelegateAdaptor(HGAppDelegate.self) private var appDelegate
    init() {
        _ = HGCore.shared // 提前加载 JS 核心，首屏请求不再等启动
        // DouDuo 同款：启动后台清掉系统留下的半截下载（滑走时被取消的 CFNetworkDownload_*.tmp）
        DYStorageFiles.cleanLeftoversAtLaunch()
        // 离线下载功能已下线：清掉老版本留下的离线视频和下载记录
        DYStorageFiles.removeRetiredOfflineDownloads()
        // 封面 / 头像的图片缓存上限：内存 32MB、磁盘 200MB（系统默认磁盘只有 ~20MB，翻多了会反复重下）
        URLCache.shared = URLCache(memoryCapacity: 32 << 20, diskCapacity: 200 << 20)
        // 封面 / 头像自己的磁盘缓存（HGImageCache）：超上限按最久没用的先删
        HGImageCache.shared.trimIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            HGRootView()
                .preferredColorScheme(.dark)
                .tint(HGTheme.accent)
        }
    }
}

/// 横屏右侧标签竖栏：液态玻璃胶囊，宽度、中线跟右上角信号栏（时间 + Wi-Fi 圈）对齐；
/// 图标下面带文字，选中项用主题色。
struct HGSideTabRail: View {
    @Binding var selection: HGRootTab
    /// 右上「粘贴链接」是系统导航栏玻璃圆键，代码里没写尺寸（系统默认）；
    /// Duo 真机截图实测直径 144px ÷ 3 = 48pt，中线离屏幕右缘 48.2pt → 胶囊同宽同中线
    static let centerFromEdge: CGFloat = 48.2
    static let width: CGFloat = 48
    /// 内容右侧要让出的宽度（栏 + 8pt 间隙），扣掉系统已有的右侧安全区
    static func reserve(trailingSafeArea: CGFloat) -> CGFloat {
        max(0, centerFromEdge + width / 2 + 8 - trailingSafeArea)
    }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(HGRootTab.allCases, id: \.self) { t in
                let on = t == selection
                let locked = false
                Button { if !locked { selection = t } } label: {
                    VStack(spacing: 3) {
                        Image(systemName: on ? t.icon + ".fill" : t.icon)
                            .font(.system(size: 21, weight: .medium))
                            .frame(height: 24)
                        Text(t.rawValue).font(.system(size: 11, weight: on ? .semibold : .medium))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(on ? HGTheme.accent : Color.white.opacity(locked ? 0.3 : 0.85))
                    .frame(width: Self.width, height: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(locked)
                .accessibilityIdentifier("hg.tab.\(t.rawValue)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
        .frame(width: Self.width)
        .ddMediaGlassCapsule()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hg.tab.rail")
    }
}

/// 根级小路由：右侧胶囊里的「链接」键 → 发现页弹粘贴链接面板
@MainActor @Observable final class HGRootRouter {
    static let shared = HGRootRouter()
    /// 推荐页横屏返回键 → 切到发现
    var tabRequest: HGRootTab?
    func go(_ t: HGRootTab) { tabRequest = t }
}

extension EnvironmentValues {
    /// 横屏右侧胶囊在：导航栏上的链接圆键收起（已并进胶囊）
    @Entry var hgSideRail = false
    /// 推荐是不是当前选中的 tab（TabView 会把没选中的页也挂着，不能靠 onAppear 判断）
    @Entry var hgFeedFront = false
}

enum HGRootTab: String, CaseIterable, Hashable {
    // 搜索并进发现页顶部的搜索框（2026-11-24 老板：菜单栏的搜索去掉）
    // 顺序同奈飞：首页 / 推荐（片段）/ 我的
    // 2026-11-25 老板：搜索收进标签栏胶囊（奈飞同款：首页 / 推荐 / 搜索 / 我的）
    case discover = "发现", feed = "推荐", search = "搜索", mine = "我的"
    var icon: String {
        switch self {
        case .feed: "play.rectangle"
        case .discover: "square.grid.2x2"
        case .search: "magnifyingglass"
        case .mine: "person"
        }
    }
}

struct HGRootView: View {
    @State private var demo: HGPlayerRequest?
    /// 冷启动在发现页（推荐要等 10 部备好才能进；初值是 .feed 的话推荐页会先挂出来偷偷开播、自己往下滑）
    @State private var tab: HGRootTab = .discover
    @State private var router = HGRootRouter.shared
    @State private var feed = HGFeedModel.shared
    @State private var storageDemo = false
    /// 启动检查到的新版本（DouDuo 同款：关掉 / 去更新后这个版本不再自动弹）
    @State private var launchUpdate: HGUpdate?
    /// 首页主题：奈飞（默认）/ 红果（旧发现页）（「我的 → 设置」切）
    @AppStorage(HGHomeStyle.key) private var homeStyle = HGHomeStyle.netflix.rawValue
    var body: some View {
        GeometryReader { geo in
            // 横屏大屏：系统标签栏换成右侧液态玻璃竖栏（图标 + 文字，宽度对齐右上信号栏），内容让出位置不被遮
            // Duo（外屏 / 内屏）也用：系统竖向标签栏只显示图标，老板要图标下面带文字（2026-11-25）
            // 2026-11-25 老板：主菜单换回系统原生标签栏（Duo 上系统竖栏、只出图标，自带液态玻璃透光）；自绘胶囊停用
            let sideRail = false
            let reserve = HGSideTabRail.reserve(trailingSafeArea: geo.safeAreaInsets.trailing)
            TabView(selection: $tab) {
                ForEach(HGRootTab.allCases, id: \.self) { t in
                    Tab(tabTitle(t), systemImage: tabIcon(t), value: t) {
                        stack { page(t) }
                            .tint(HGTheme.accent)
                            // 推荐页横屏不显示主菜单胶囊（视频右侧是点赞那排 + 返回键）
                            .environment(\.hgSideRail, sideRail && t != .feed)
                            .environment(\.hgFeedFront, tab == .feed)
                            .toolbarBackgroundVisibility(t == .feed ? .hidden : .automatic, for: .tabBar)
                            .toolbarColorScheme(t == .feed ? .dark : nil, for: .tabBar)
                            // 推荐页横竖屏都不显示主菜单；靠视频上的返回键回发现
                            .toolbarVisibility(sideRail || t == .feed ? .hidden : .automatic, for: .tabBar)
                            // 胶囊让出位置：用安全区（各页按可见宽度排版，列数自适应）
                            .safeAreaPadding(.trailing, sideRail && t != .feed ? reserve : 0)
                    }
                }
            }
            // 标签栏选中项白色（奈飞同款）；各页内容在上面单独恢复主题红
            .tint(.white)
            // 推荐页（含竖屏半折叠）整个 TabView 层也压住系统标签栏，不只靠单个 Tab 内容上的修饰
            .toolbarVisibility(tab == .feed ? .hidden : .automatic, for: .tabBar)
            // 系统会把上次选中的标签恢复回来（DouDuo 也踩过）：冷启动固定回发现页
            .task {
                #if DEBUG
                if let t = ProcessInfo.processInfo.environment["HG_START_TAB"], let start = HGRootTab.allCases.first(where: { "\($0)" == t }) {
                    // 测试直接进推荐：等 10 部备好、推荐键亮了再切
                    tab = start; return
                }
                #endif
                tab = .discover
            }
            .task {
                // 停在发现页时后台先备几部推荐（等首屏封面先出来，2 秒后再开始）
                try? await Task.sleep(for: .seconds(2))
                HGFeedModel.shared.start()
            }
            .task { _ = try? await HGAPI.accountStatus() }
            .task {
                // 登录保活：一天碰一次官网账号接口，续期的 cookie 写回钥匙串（会话过期才登出）
                try? await Task.sleep(for: .seconds(5))
                let last = UserDefaults.standard.double(forKey: "hg.account.beat")
                if Date().timeIntervalSince1970 - last > 20 * 3600 {
                    await HGAPI.keepAlive()
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "hg.account.beat")
                    _ = try? await HGAPI.accountStatus()   // 会话过期被登出：库切回游客
                }
            }
            .task {
                // 等首屏稳定再查，不跟推荐流抢网络
                try? await Task.sleep(for: .seconds(3))
                launchUpdate = await HGUpdateChecker.checkAtLaunch()
            }
            .sheet(item: $launchUpdate, onDismiss: nil) { u in
                HGUpdateSheet(update: u)
                    .onDisappear { HGUpdateChecker.dismiss(u) }
            }
            .onChange(of: router.tabRequest) { _, t in
                if let t { tab = t; router.tabRequest = nil }
            }
            .overlay {
                if sideRail && tab != .feed {
                    // 以屏幕物理右缘为基准（忽略安全区），中线对齐右上信号圈 / 链接键
                    HGSideTabRail(selection: $tab)
                        .padding(.trailing, HGSideTabRail.centerFromEdge - HGSideTabRail.width / 2)
                        .padding(.bottom, 24 + geo.safeAreaInsets.bottom)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .ignoresSafeArea()
                }
            }
        }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.environment["HG_DEMO_STORAGE"] == "1" {
                Task { try? await Task.sleep(for: .seconds(25)); tab = .mine; storageDemo = true }
            }
            // 测试：往观看记录 / 收藏里塞 N 部热播剧（看「我的」页面排版用）
            if let n = Int(ProcessInfo.processInfo.environment["HG_DEMO_LIBRARY"] ?? "") {
                Task {
                    guard let page = try? await HGAPI.browse(.hot, page: 1) else { return }
                    for s in page.results.prefix(n) {
                        HGLibrary.shared.record(s, episode: 2, position: 30)
                        if !HGLibrary.shared.isFavorite(s.id) { HGLibrary.shared.toggleFavorite(s) }
                    }
                }
            }
            if let m = ProcessInfo.processInfo.environment["HG_DEMO_MINIMAL"] { UserDefaults.standard.set(m == "1", forKey: "hg.minimal") }
        }
        // 真机验收用：devicectl 带 HG_DEMO_SERIES 启动直接进播放页（XCUITest 在真机上起不来时的替代）
        .task {
            guard let sid = ProcessInfo.processInfo.environment["HG_DEMO_SERIES"],
                  let d = try? await HGAPI.detail(sid) else { return }
            let ep = Int(ProcessInfo.processInfo.environment["HG_DEMO_EP"] ?? "1") ?? 1
            let s = HGSeries(series_id: d.series_id, series_title: d.series_title, cover: d.cover,
                             episode_count: d.episodes.count, description: d.description)
            demo = HGPlayerRequest(series: s, episodes: d.episodes, index: max(0, ep - 1), startAt: 0)
        }
        .fullScreenCover(item: $demo) { HGPlayerScreen(request: $0) }
        .sheet(isPresented: $storageDemo) { NavigationStack { DYStorageScreen() } }
        #endif
    }

    @ViewBuilder private func page(_ t: HGRootTab) -> some View {
        switch t {
        case .feed: HGFeedView()
        case .discover: if homeStyle == HGHomeStyle.classic.rawValue { HGDiscoverView() } else { HGHomeView() }
        case .search: HGSearchView(isTab: true)
        case .mine: HGMineView()
        }
    }

    private func tabTitle(_ t: HGRootTab) -> String {
        t == .discover && homeStyle != HGHomeStyle.classic.rawValue ? "首页" : t.rawValue
    }

    private func tabIcon(_ t: HGRootTab) -> String {
        t == .discover && homeStyle != HGHomeStyle.classic.rawValue ? "house" : t.icon
    }

    private func stack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack {
            content()
                .background(HGTheme.background)
                .navigationDestination(for: HGSeries.self) { HGDetailView(series: $0) }
                .navigationDestination(for: HGReviewsRoute.self) { HGReviewsScreen(seriesID: $0.seriesID, title: $0.title) }
        }
    }
}
