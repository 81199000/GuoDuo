import SwiftUI

struct HGMineView: View {
    @State private var library = HGLibrary.shared
    @State private var account: HGAccountStatus?
    @State private var cloud: [HGCloudHistoryRow] = []
    @State private var cloudFavorites: [HGCloudFavorite] = []
    @State private var cloudError: String?
    @State private var showLogin = false
    @State private var resume: HGPlayerRequest?
    @AppStorage("hg.bgPlay.v2") private var bgPlay = false

    var body: some View {
        List {
            accountSection
            // 外面只放一排前几部（横滑），点「全部」进完整列表
            if signedIn {
                // 登录了：本机 + 红果 App 云端观看记录合成一排，按最后观看时间新→旧；点了直接从进度续播
                let rows = mergedHistory
                HGShelfSection(title: "继续观看", empty: "还没有观看记录", id: "history",
                               items: rows.map { ($0.series, "看到第 \(max(1, $0.vid_index)) 集") },
                               tap: { s in if let r = rows.first(where: { $0.series_id == s.id }) { Task { await play(r) } } }) {
                    HGCloudHistoryScreen(rows: rows) { r in Task { await play(r) } }
                }
                let favs = mergedFavorites
                HGShelfSection(title: "收藏", empty: "还没有收藏", id: "favorites",
                               items: favs.map { ($0, $0.episode_count.map { "共 \($0) 集" }) }) {
                    HGSeriesGridScreen(title: "收藏", items: favs)
                }
            } else {
                HGShelfSection(title: "继续观看", empty: "还没有观看记录", id: "history",
                               items: library.history.map { ($0.series, "看到第 \($0.episodeIndex + 1) 集") }) {
                    HGSeriesListScreen(title: "继续观看", kind: .history)
                }
                HGShelfSection(title: "收藏", empty: "还没有收藏", id: "favorites",
                               items: library.favorites.map { ($0, $0.episode_count.map { "共 \($0) 集" }) }) {
                    HGSeriesListScreen(title: "收藏", kind: .favorites)
                }
            }
            Section {
                NavigationLink { DYStorageScreen() } label: {
                    Label("储存空间", systemImage: "internaldrive")
                }
                .accessibilityIdentifier("hg.mine.storage")
                Toggle("听书模式（退出后继续播放声音）", isOn: $bgPlay).tint(HGTheme.accent)
            }
            .listRowBackground(HGTheme.surface)
            HGAboutSection()
            Section { HGBrandFooter() }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 24, trailing: 16))
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("我的")
        .task { await refreshAccount() }
        .sheet(isPresented: $showLogin, onDismiss: { Task { await refreshAccount() } }) {
            HGLoginSheet { showLogin = false }.presentationDetents([.medium])
        }
        .fullScreenCover(item: $resume) { HGPlayerScreen(request: $0) }
    }

    @ViewBuilder private var accountSection: some View {
        Section {
            if let a = account?.account, account?.signedIn == true {
                HStack {
                    Label(a.nickname, systemImage: "person.crop.circle.fill").foregroundStyle(HGTheme.textPrimary)
                    Spacer()
                    Button("退出") { Task { try? await HGAPI.logout(); await refreshAccount() } }.font(.footnote)
                }
                if let cloudError { Text(cloudError).font(.caption).foregroundStyle(HGTheme.textTertiary) }
            } else {
                Button { showLogin = true } label: {
                    HStack {
                        Label("登录红果账号", systemImage: "qrcode.viewfinder")
                        Spacer()
                        Text("同步推荐 / 观看记录 / 收藏").font(.caption).foregroundStyle(HGTheme.textTertiary)
                    }
                }
                .accessibilityIdentifier("hg.mine.login")
            }
        } header: { Text("红果账号") }
        .listRowBackground(HGTheme.surface)
    }

    private var signedIn: Bool { account?.signedIn == true }

    /// 本机记录 + 云端记录：同一部取最后看的那条（本机记录转成同一种行，episode_id 为空 = 按集序号定位）
    private var mergedHistory: [HGCloudHistoryRow] {
        let local = library.history.map { p in
            HGCloudHistoryRow(series_id: p.series.id, series_title: p.series.series_title, cover: p.series.cover,
                              episode_id: "", vid_index: p.episodeIndex + 1, currentTime: p.position,
                              total: p.series.episode_count, updatedAt: p.updatedAt.timeIntervalSince1970 * 1000)
        }
        var best: [String: HGCloudHistoryRow] = [:]
        for r in cloud + local {
            if let old = best[r.series_id], (old.updatedAt ?? 0) >= (r.updatedAt ?? 0) {
                // 封面 / 集数互相补
                if (old.cover ?? "").isEmpty, let c = r.cover, !c.isEmpty { best[r.series_id] = old.with(cover: c) }
                continue
            }
            var r = r
            if (r.cover ?? "").isEmpty, let c = best[r.series_id]?.cover { r = r.with(cover: c) }
            best[r.series_id] = r
        }
        return best.values.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
    }

    /// 红果 App 收藏在前（按收藏时间），再接本机收藏里云端没有的
    private var mergedFavorites: [HGSeries] {
        var seen = Set<String>()
        return (cloudFavorites.map(\.series) + library.favorites).filter { seen.insert($0.id).inserted }
    }

    private func row(_ s: HGSeries, subtitle: String?) -> some View {
        HStack(spacing: 12) {
            HGCover(url: s.coverURL).frame(width: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text(s.series_title).foregroundStyle(HGTheme.textPrimary).lineLimit(1)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(HGTheme.textSecondary) }
            }
        }
    }

    private func refreshAccount() async {
        #if DEBUG
        // 测试：假装已登录、云端有 N 条记录（看排版用，不连红果账号）
        if let n = Int(ProcessInfo.processInfo.environment["HG_DEMO_CLOUD"] ?? ""),
           let page = try? await HGAPI.browse(.hot, page: 1) {
            account = HGAccountStatus(signedIn: true, account: HGAccountProfile(id: "demo", nickname: "用户 演示"))
            let now = Date().timeIntervalSince1970 * 1000
            cloud = page.results.prefix(n).enumerated().map { i, s in
                HGCloudHistoryRow(series_id: s.series_id, series_title: s.series_title, cover: s.cover,
                                  episode_id: "", vid_index: i % 9 + 1, currentTime: 0, total: s.episode_count,
                                  updatedAt: now - Double(i) * 3_600_000 - 60_000)
            }
            cloudFavorites = page.results.suffix(4).map { HGCloudFavorite(series_id: $0.series_id, series_title: $0.series_title, cover: $0.cover, episode_count: $0.episode_count) }
            return
        }
        #endif
        account = try? await HGAPI.accountStatus()
        guard account?.signedIn == true else { cloud = []; cloudFavorites = []; return }
        async let h = Result { try await HGAPI.cloudHistoryAll() }
        async let f = Result { try await HGAPI.cloudFavorites() }
        var errors: [String] = []
        switch await h {
        case .success(let rows): cloud = rows
        case .failure(let e): errors.append("观看记录读取失败：\(e.localizedDescription)")
        }
        switch await f {
        case .success(let rows): cloudFavorites = rows
        case .failure(let e): errors.append("收藏读取失败：\(e.localizedDescription)")
        }
        cloudError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    /// 云端记录续播：按分集编号定位，找不到就从记录的集序号开始，不把云端进度套到第 1 集。
    private func play(_ r: HGCloudHistoryRow) async {
        guard let d = try? await HGAPI.detail(r.series_id) else { return }
        let byVid = r.episode_id.isEmpty ? nil : d.episodes.firstIndex { $0.vid == r.episode_id }
        let idx = byVid ?? (r.vid_index > 0 && !d.episodes.isEmpty ? min(d.episodes.count - 1, r.vid_index - 1) : nil)
        guard let idx else { return }
        var s = r.series; s.episode_count = d.episodes.count
        if (s.cover ?? "").isEmpty { s.cover = d.cover }
        // 云端记录：分集编号对上才续进度；本机记录（没有分集编号）按集序号续
        let exact = byVid != nil || (r.episode_id.isEmpty && idx == r.vid_index - 1)
        resume = HGPlayerRequest(series: s, episodes: d.episodes, index: idx, startAt: exact ? r.currentTime : 0)
    }
}

/// 红果 App 扫码登录（官网二维码，手机红果 App 扫码并确认）。
struct HGLoginSheet: View {
    let done: () -> Void
    @State private var qr: HGQRLogin?
    @State private var image: UIImage?
    @State private var message = "正在获取二维码…"
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 16) {
            Text("用红果 App 扫码登录").font(.headline)
            ZStack {
                RoundedRectangle(cornerRadius: HGTheme.radius).fill(.white).frame(width: 200, height: 200)
                if let image { Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 184, height: 184) }
                else { ProgressView().tint(.black) }
            }
            Text(message).font(.footnote).foregroundStyle(HGTheme.textSecondary).multilineTextAlignment(.center)
            Text("可截图后在另一台手机的红果 App「我的 → 扫一扫」打开。登录后推荐按你的红果账号来，并同步红果 App 的观看记录和收藏（只读，不会改动账号）。")
                .font(.caption2).foregroundStyle(HGTheme.textTertiary).multilineTextAlignment(.center).padding(.horizontal)
            Button("刷新二维码") { start() }.font(.footnote)
        }
        .padding(24)
        .onAppear { start() }
        .onDisappear { task?.cancel(); if let id = qr?.loginId { Task { await HGAPI.cancelLogin(id) } } }
    }

    private func start() {
        task?.cancel()
        image = nil; message = "正在获取二维码…"
        task = Task {
            do {
                let q = try await HGAPI.startLogin()
                qr = q
                if let b64 = q.image.split(separator: ",").last, let data = Data(base64Encoded: String(b64)) { image = UIImage(data: data) }
                message = "等待扫码…"
                let deadline = Date().addingTimeInterval(TimeInterval(max(30, q.expiresIn)))
                while !Task.isCancelled, Date() < deadline {
                    try await Task.sleep(for: .seconds(2))
                    let p = try await HGAPI.pollLogin(q.loginId)
                    if p.signedIn == true || p.status == "signed-in" { message = "登录成功"; done(); return }
                    switch p.status {
                    case "expired": message = "二维码已过期，点刷新"; return
                    case "cancelled": message = "已取消，点刷新重试"; return
                    default: break
                    }
                }
                if !Task.isCancelled { message = "二维码已过期，点刷新" }
            } catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
        }
    }
}


/// 一排横滑卡片（前 8 部）+ 右上角「全部 N」
struct HGShelfSection<Destination: View>: View {
    let title: String
    let empty: String
    let id: String
    let items: [(HGSeries, String?)]
    /// 给了就点卡片回调（如云端记录直接续播），不给就推详情页
    var tap: ((HGSeries) -> Void)? = nil
    @ViewBuilder let all: () -> Destination
    private static var limit: Int { 8 }

    var body: some View {
        Section {
            if items.isEmpty {
                Text(empty).foregroundStyle(HGTheme.textTertiary)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items.prefix(Self.limit), id: \.0.id) { s, sub in
                            if let tap {
                                Button { tap(s) } label: { HGSeriesCard(series: s, subtitle: sub).frame(width: 96) }
                                    .buttonStyle(.plain)
                            } else {
                                NavigationLink(value: s) { HGSeriesCard(series: s, subtitle: sub).frame(width: 96) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("hg.shelf.\(id)")
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                if !items.isEmpty {
                    NavigationLink { all() } label: {
                        HStack(spacing: 2) {
                            Text("全部 \(items.count)")
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                        }
                        .font(.footnote)
                        .foregroundStyle(HGTheme.textSecondary)
                    }
                    .accessibilityIdentifier("hg.shelf.\(id).all")
                }
            }
            .textCase(nil)
        }
        .listRowBackground(Color.clear)
    }
}

/// 「全部」页：完整网格，长按删除 / 取消收藏
struct HGSeriesListScreen: View {
    enum Kind { case history, favorites }
    let title: String
    let kind: Kind
    @State private var library = HGLibrary.shared
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                switch kind {
                case .history:
                    ForEach(library.history, id: \.series.id) { p in
                        NavigationLink(value: p.series) { HGSeriesCard(series: p.series, subtitle: "看到第 \(p.episodeIndex + 1) 集") }
                            .buttonStyle(.plain)
                            .contextMenu { Button("删除记录", systemImage: "trash", role: .destructive) { library.removeHistory(p.series.id) } }
                    }
                case .favorites:
                    ForEach(library.favorites) { s in
                        NavigationLink(value: s) { HGSeriesCard(series: s, subtitle: s.episode_count.map { "共 \($0) 集" }) }
                            .buttonStyle(.plain)
                            .contextMenu { Button("取消收藏", systemImage: "heart.slash", role: .destructive) { library.toggleFavorite(s) } }
                    }
                }
            }
            .padding(16)
        }
        .background(HGTheme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 「我的」最底下：logo、名字、一句介绍、仓库链接
struct HGBrandFooter: View {
    @Environment(\.openURL) private var openURL
    var body: some View {
        VStack(spacing: 10) {
            Image("AppLogo").resizable().scaledToFit()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .accessibilityHidden(true)
            Text("GuoDuo").font(.headline).foregroundStyle(HGTheme.textPrimary)
            Text("原生 SwiftUI 的红果短剧客户端，适配 iPhone Duo 折叠屏、iPad 与普通 iPhone。开源免费，非官方。")
                .font(.caption).foregroundStyle(HGTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button { openURL(HGUpdateChecker.repoURL) } label: {
                Text("github.com/\(HGUpdateChecker.repo)").font(.caption.monospaced())
            }
            .tint(HGTheme.accent)
            .accessibilityIdentifier("hg.footer.repo")
            Text("片源来自红果 / 西饭 / 河马公开接口，接口变化时可能失效。仅供个人学习使用。")
                .font(.caption2).foregroundStyle(HGTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hg.footer")
    }
}


/// 红果 App 云端观看记录「全部」页：网格，点了从云端进度续播
struct HGCloudHistoryScreen: View {
    let rows: [HGCloudHistoryRow]
    let play: (HGCloudHistoryRow) -> Void
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 12, alignment: .top)]
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(rows) { r in
                    Button { play(r) } label: { HGSeriesCard(series: r.series, subtitle: "看到第 \(max(1, r.vid_index)) 集") }
                        .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(HGTheme.background)
        .navigationTitle("继续观看")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 登录后的收藏「全部」页（红果 App 收藏 + 本机收藏）；本机收藏可长按取消
struct HGSeriesGridScreen: View {
    let title: String
    let items: [HGSeries]
    @State private var library = HGLibrary.shared
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 12, alignment: .top)]
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(items) { s in
                    NavigationLink(value: s) { HGSeriesCard(series: s, subtitle: s.episode_count.map { "共 \($0) 集" }) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if library.isFavorite(s.id) {
                                Button("取消本机收藏", systemImage: "heart.slash", role: .destructive) { library.toggleFavorite(s) }
                            }
                        }
                }
            }
            .padding(16)
        }
        .background(HGTheme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension HGCloudHistoryRow {
    func with(cover: String) -> HGCloudHistoryRow {
        HGCloudHistoryRow(series_id: series_id, series_title: series_title, cover: cover, episode_id: episode_id,
                          vid_index: vid_index, currentTime: currentTime, total: total, updatedAt: updatedAt)
    }
}
