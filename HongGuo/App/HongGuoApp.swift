import SwiftUI

final class HGAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        // 竖屏为主；播放页按「横屏」后才放开横向（横屏片源）。iPad 不限制。
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        return HGOrientation.allowLandscape ? [.portrait, .landscapeLeft, .landscapeRight] : .portrait
    }
}

@main
struct HongGuoApp: App {
    @UIApplicationDelegateAdaptor(HGAppDelegate.self) private var appDelegate
    init() {
        _ = HGCore.shared // 提前加载 JS 核心，首屏请求不再等启动
    }

    var body: some Scene {
        WindowGroup {
            HGRootView()
                .preferredColorScheme(.dark)
                .tint(HGTheme.accent)
        }
    }
}

struct HGRootView: View {
    var body: some View {
        TabView {
            Tab("发现", systemImage: "play.square.stack") { stack { HGDiscoverView() } }
            Tab("搜索", systemImage: "magnifyingglass") { stack { HGSearchView() } }
            Tab("我的", systemImage: "person") { stack { HGMineView() } }
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
