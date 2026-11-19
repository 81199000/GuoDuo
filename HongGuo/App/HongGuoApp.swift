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
        // 封面 / 头像的图片缓存上限：内存 32MB、磁盘 200MB（系统默认磁盘只有 ~20MB，翻多了会反复重下）
        URLCache.shared = URLCache(memoryCapacity: 32 << 20, diskCapacity: 200 << 20)
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
            // 粘贴链接并进胶囊最上面（横屏时导航栏上那颗圆键收起）
            Button { HGRootRouter.shared.requestShare(); selection = .discover } label: {
                VStack(spacing: 3) {
                    Image(systemName: "link").font(.system(size: 21, weight: .medium)).frame(height: 24)
                    Text("链接").font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                }
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: Self.width, height: 54)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("hg.tab.share")
            Capsule().fill(.white.opacity(0.15)).frame(width: 24, height: 1)
            ForEach(HGRootTab.allCases, id: \.self) { t in
                let on = t == selection
                let locked = false
                Button { if !locked { selection = t } } label: {
                    VStack(spacing: 3) {
                        Image(systemName: on && t != .search ? t.icon + ".fill" : t.icon)
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
    var shareTick = 0
    func requestShare() { shareTick += 1 }
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
    case feed = "推荐", discover = "发现", search = "搜索", mine = "我的"
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
    var body: some View {
        GeometryReader { geo in
            let full = CGSize(width: geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing,
                              height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom)
            // 横屏大屏：系统标签栏换成右侧液态玻璃竖栏（图标 + 文字，宽度对齐右上信号栏），内容让出位置不被遮
            let sideRail = full.width > full.height && full.width >= 700
            let reserve = HGSideTabRail.reserve(trailingSafeArea: geo.safeAreaInsets.trailing)
            TabView(selection: $tab) {
                ForEach(HGRootTab.allCases, id: \.self) { t in
                    Tab(t.rawValue, systemImage: t.icon, value: t) {
                        stack { page(t) }
                            // 推荐页横屏不显示主菜单胶囊（视频右侧是点赞那排 + 返回键）
                            .environment(\.hgSideRail, sideRail && t != .feed)
                            .environment(\.hgFeedFront, tab == .feed)
                            .toolbarBackgroundVisibility(t == .feed ? .hidden : .automatic, for: .tabBar)
                            .toolbarColorScheme(t == .feed ? .dark : nil, for: .tabBar)
                            // 推荐页横竖屏都不显示主菜单；靠视频上的返回键回发现
                            .toolbarVisibility(sideRail || t == .feed ? .hidden : .automatic, for: .tabBar)
                            .contentMargins(.trailing, sideRail && t != .feed ? reserve : 0, for: .scrollContent)
                    }
                }
            }
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
        case .discover: HGDiscoverView()
        case .search: HGSearchView()
        case .mine: HGMineView()
        }
    }

    private func stack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack {
            content()
                .background(HGTheme.background)
                .navigationDestination(for: HGSeries.self) { HGDetailView(series: $0) }
        }
    }
}
