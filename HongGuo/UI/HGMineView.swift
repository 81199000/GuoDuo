import SwiftUI

struct HGMineView: View {
    @State private var library = HGLibrary.shared
    @State private var downloads = HGDownloads.shared
    @State private var account: HGAccountStatus?
    @State private var cloud: [HGCloudHistoryRow] = []
    @State private var cloudError: String?
    @State private var showLogin = false
    @State private var resume: HGPlayerRequest?
    @AppStorage("hg.bgPlay") private var bgPlay = true

    var body: some View {
        List {
            accountSection
            Section("继续观看") {
                if library.history.isEmpty { Text("还没有观看记录").foregroundStyle(HGTheme.textTertiary) }
                ForEach(library.history.prefix(20), id: \.series.id) { p in
                    NavigationLink(value: p.series) {
                        row(p.series, subtitle: "看到第 \(p.episodeIndex + 1) 集")
                    }
                    .swipeActions { Button("删除", role: .destructive) { library.removeHistory(p.series.id) } }
                }
            }
            .listRowBackground(HGTheme.surface)
            Section("收藏") {
                if library.favorites.isEmpty { Text("还没有收藏").foregroundStyle(HGTheme.textTertiary) }
                ForEach(library.favorites) { s in
                    NavigationLink(value: s) { row(s, subtitle: s.episode_count.map { "共 \($0) 集" }) }
                        .swipeActions { Button("取消收藏", role: .destructive) { library.toggleFavorite(s) } }
                }
            }
            .listRowBackground(HGTheme.surface)
            Section {
                NavigationLink { HGDownloadsView() } label: {
                    HStack {
                        Label("离线下载", systemImage: "arrow.down.circle")
                        Spacer()
                        let n = downloads.all.reduce(0) { $0 + $1.doneCount }
                        if n > 0 { Text("\(n) 集").foregroundStyle(HGTheme.textSecondary) }
                    }
                }
                .accessibilityIdentifier("hg.mine.downloads")
                Toggle("切到后台继续播放", isOn: $bgPlay).tint(HGTheme.accent)
            }
            .listRowBackground(HGTheme.surface)
            Section {
                Text("片源来自红果 / 西饭 / 河马公开接口，接口变化时可能失效。仅供个人学习使用。").font(.caption).foregroundStyle(HGTheme.textTertiary)
            }
            .listRowBackground(HGTheme.background)
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
                ForEach(cloud.prefix(10)) { r in
                    Button { Task { await play(r) } } label: {
                        row(r.series, subtitle: "红果 App 看到第 \(max(1, r.vid_index)) 集")
                    }
                }
            } else {
                Button { showLogin = true } label: {
                    HStack {
                        Label("登录红果账号", systemImage: "qrcode.viewfinder")
                        Spacer()
                        Text("同步 App 观看记录").font(.caption).foregroundStyle(HGTheme.textTertiary)
                    }
                }
                .accessibilityIdentifier("hg.mine.login")
            }
        } header: { Text("红果账号") }
        .listRowBackground(HGTheme.surface)
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
        account = try? await HGAPI.accountStatus()
        guard account?.signedIn == true else { cloud = []; return }
        do { cloud = try await HGAPI.cloudHistory(refresh: false); cloudError = nil }
        catch { cloudError = "观看记录读取失败：\(error.localizedDescription)" }
    }

    /// 云端记录续播：按分集编号定位，找不到就从记录的集序号开始，不把云端进度套到第 1 集。
    private func play(_ r: HGCloudHistoryRow) async {
        guard let d = try? await HGAPI.detail(r.series_id) else { return }
        let idx = d.episodes.firstIndex { $0.vid == r.episode_id } ?? (r.vid_index > 0 ? min(d.episodes.count - 1, r.vid_index - 1) : nil)
        guard let idx else { return }
        var s = r.series; s.episode_count = d.episodes.count
        if (s.cover ?? "").isEmpty { s.cover = d.cover }
        resume = HGPlayerRequest(series: s, episodes: d.episodes, index: idx, startAt: d.episodes[idx].vid == r.episode_id ? r.currentTime : 0)
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
            Text("可截图后在另一台手机的红果 App「我的 → 扫一扫」打开。登录只用于读取观看记录。")
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
