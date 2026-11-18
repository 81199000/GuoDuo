import SwiftUI

@main
struct HongGuoApp: App {
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
