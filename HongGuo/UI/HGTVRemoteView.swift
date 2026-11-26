// 「电视遥控」页 + 扫码：找到 / 绑定果多 TV，遥控（方向键 / 确定 / 返回 / 主页 / 音量 / 播放控制），
// 电视在播时一键「接到手机继续看」。播放页「更多 → 投到电视」走 HGTVHandoff。
import SwiftUI
import AVFoundation
import UIKit

struct HGTVRemoteView: View {
    /// 从「扫一扫」进来：带着扫到的内容（登录码 / 遥控地址），打开就处理
    var initialScan: String? = nil
    @State private var handledInitial = false
    @State private var store = HGTVStore.shared
    @State private var browser = HGTVRemoteBrowser()
    @State private var manual = ""
    @State private var error: String?
    @State private var scanning = false
    @State private var pairing: HGRemoteTV?
    @State private var password = ""
    @State private var busy = false
    @State private var open: HGRemoteTV?
    /// 扫到电视登录码：确认卡
    @State private var ticket: HGTVLoginTicket?
    @State private var loginNote: String?
    /// 我的电视在不在线（逐台探 /api/pair/info）
    @State private var online: [String: Bool] = [:]

    var body: some View {
        List {
            Section {
                Button { scanning = true } label: {
                    HGSettingRow(icon: "qrcode.viewfinder", tint: HGTheme.accent, title: "扫电视上的二维码",
                                 subtitle: "遥控码：电视首页右上角「手机遥控」\n登录码：电视的登录页，扫完用手机账号直接登录电视") { EmptyView() }
                }
                .accessibilityIdentifier("hg.tvr.scan")
            } footer: { Text("手机和电视要在同一个 Wi‑Fi。电视上要先装好 GuoDuo TV（我的 → 设置 → 安装到电视）。") }
            .listRowBackground(HGTheme.surface)

            if !store.devices.isEmpty {
                Section("我的电视") {
                    ForEach(store.devices) { tv in
                        Button { open = tv } label: {
                            HGSettingRow(icon: "tv.fill", tint: .teal, title: tv.name,
                                         subtitle: online[tv.id] == true ? "在线 · 点开遥控" : online[tv.id] == false ? "离线：电视没开 GuoDuo TV 或不在同一 Wi‑Fi" : "\(tv.host):\(tv.port)") {
                                Circle().fill(online[tv.id] == true ? Color.green : Color.gray.opacity(0.5)).frame(width: 8, height: 8)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(HGTheme.textTertiary)
                            }
                        }
                        .accessibilityIdentifier("hg.tvr.mine")
                        .swipeActions { Button("忘记", role: .destructive) { store.forget(tv) } }
                    }
                }
                .listRowBackground(HGTheme.surface)
            }

            Section {
                let fresh = browser.found.filter { f in !store.devices.contains { $0.id == f.id } }
                ForEach(fresh) { tv in
                    Button { Task { await connect(tv) } } label: {
                        HGSettingRow(icon: "tv", tint: .gray, title: tv.name, subtitle: "\(tv.host):\(tv.port) · 点击连接") { EmptyView() }
                    }
                    .accessibilityIdentifier("hg.tvr.found")
                }
                if fresh.isEmpty {
                    let knownHere = browser.found.contains { f in store.devices.contains { $0.id == f.id } }
                    HStack(spacing: 8) {
                        if browser.scanning && !knownHere { ProgressView().controlSize(.small) }
                        Text(knownHere ? "只找到上面「我的电视」那台" : browser.scanning ? "正在找局域网里的 GuoDuo TV…" : "没找到别的电视")
                            .font(.subheadline).foregroundStyle(HGTheme.textSecondary)
                        Spacer()
                        if !browser.scanning { Button("重新找") { browser.start() }.font(.subheadline) }
                    }
                }
            } header: { Text("局域网里的电视") }
            .listRowBackground(HGTheme.surface)

            Section {
                HStack {
                    TextField("电视地址，如 192.168.1.20:8765", text: $manual)
                        .keyboardType(.numbersAndPunctuation).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityIdentifier("hg.tvr.manual")
                    Button("连接") { Task { await connectAddress(manual) } }.disabled(manual.isEmpty || busy)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(HGTheme.accent) }
            } header: { Text("手动输入") } footer: { Text("地址在电视「手机遥控」二维码下面，如 192.168.1.20:8765。") }
            .listRowBackground(HGTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(HGTheme.background)
        .navigationTitle("连接遥控器")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            browser.start()
            if let t = initialScan, !handledInitial { handledInitial = true; Task { await handleScan(t) } }
        }
        .task(id: store.devices.map(\.id)) {
            for tv in store.devices {
                let ok = (try? await HGTVClient(tv: tv).info()) != nil
                online[tv.id] = ok
            }
        }
        .onDisappear { browser.stop() }
        .overlay { if busy { ProgressView().padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14)) } }
        .sheet(isPresented: $scanning) {
            HGQRScanner { text in
                scanning = false
                Task { await handleScan(text) }
            }
            .ignoresSafeArea()
        }
        .alert("遥控密码", isPresented: Binding(get: { pairing != nil }, set: { if !$0 { pairing = nil } })) {
            SecureField("电视上设置的遥控密码", text: $password)
            Button("取消", role: .cancel) { pairing = nil }
            Button("连接") { if let tv = pairing { Task { await bind(tv, password: password) } } }
        } message: { Text("这台电视设了遥控密码") }
        .navigationDestination(item: $open) { HGTVRemotePad(tv: $0) }
        .sheet(item: $ticket) { t in
            HGTVLoginConfirmSheet(ticket: t) { result in ticket = nil; loginNote = result }
                .presentationDetents([.height(330)])
        }
        .alert(loginNote ?? "", isPresented: Binding(get: { loginNote != nil }, set: { if !$0 { loginNote = nil } })) { Button("好") {} }
    }

    /// 扫码：红果登录码 → 手机账号确认登录电视；否则当遥控地址
    private func handleScan(_ text: String) async {
        guard await HGAPI.isLoginQR(text) else { await connectAddress(text); return }
        busy = true; defer { busy = false }
        do { ticket = try await HGAPI.tvLoginScan(text) } catch { loginNote = error.localizedDescription }
    }

    private func connectAddress(_ text: String) async {
        guard let a = hgParseRemoteAddress(text) else { error = "地址格式不对，应类似 192.168.1.20:8765"; return }
        error = nil
        await connect(HGRemoteTV(id: "\(a.host):\(a.port)", name: "电视 \(a.host)", host: a.host, port: a.port))
    }

    private func connect(_ guess: HGRemoteTV) async {
        busy = true; defer { busy = false }
        do {
            let info = try await HGTVClient(tv: guess).info()
            guard info.app == nil || info.app == "guoduo-tv" else { error = "这个地址不是 GuoDuo TV"; return }
            if info.remoteOn == false { error = "电视上关掉了手机遥控（电视：设置 → 遥控 → 手机遥控 打开）"; return }
            let tv = HGRemoteTV(id: info.id, name: info.name, host: guess.host, port: info.port ?? guess.port, model: info.model)
            if info.needPassword == true && !store.isPaired(tv.id) { password = ""; pairing = tv; return }
            await bind(tv, password: nil)
        } catch { self.error = error.localizedDescription }
    }

    private func bind(_ tv: HGRemoteTV, password: String?) async {
        busy = true; defer { busy = false }
        do {
            try await HGTVClient(tv: tv).bind(password: password)
            store.remember(tv)
            pairing = nil
            open = tv
        } catch HGTVRemoteError.needPassword(let m) {
            error = m; self.password = ""; pairing = tv
        } catch { self.error = error.localizedDescription; pairing = nil }
    }
}

// MARK: - 遥控器

struct HGTVRemotePad: View {
    let tv: HGRemoteTV
    @State private var status: HGTVStatus?
    @State private var offline = false
    @State private var note: String?
    @State private var pulling = false
    @State private var playing: HGPlayerRequest?
    private var client: HGTVClient { HGTVClient(tv: tv) }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                nowPlaying
                dpad
                HStack(spacing: 14) {
                    padKey("arrow.uturn.backward", "返回") { await key("back") }
                    padKey("house", "主页") { await key("home") }
                    padKey("line.3.horizontal", "菜单") { await key("menu") }
                }
                HStack(spacing: 14) {
                    padKey("speaker.slash", "静音") { await key("mute") }
                    padKey("speaker.minus", "音量-") { await key("vol_down") }
                    padKey("speaker.plus", "音量+") { await key("vol_up") }
                }
                if let note { Text(note).font(.footnote).foregroundStyle(HGTheme.textSecondary) }
            }
            .padding(20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(HGTheme.background)
        .navigationTitle(tv.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                do { status = try await client.status(); offline = false } catch { offline = true }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        .fullScreenCover(item: $playing) { HGPlayerScreen(request: $0) }
        .sensoryFeedback(.impact(weight: .light), trigger: note)
    }

    @ViewBuilder private var nowPlaying: some View {
        if offline {
            Label("连不上电视：确认电视开着、和手机同一个 Wi‑Fi", systemImage: "wifi.exclamationmark")
                .font(.subheadline).foregroundStyle(HGTheme.textSecondary)
                .frame(maxWidth: .infinity).padding(14).background(HGTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        } else if let s = status, s.active {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    HGCachedImage(url: s.coverURL) { Rectangle().fill(HGTheme.surfaceHigh) }
                        .frame(width: 54, height: 72).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("电视正在播").font(.caption).foregroundStyle(HGTheme.textTertiary)
                        Text(s.title).font(.headline).foregroundStyle(HGTheme.textPrimary).lineLimit(1)
                        Text("第 \(s.episode) 集 · \(clock(s.position)) / \(clock(s.duration))")
                            .font(.caption.monospacedDigit()).foregroundStyle(HGTheme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                ProgressView(value: Double(s.position), total: Double(max(s.duration, 1))).tint(HGTheme.accent)
                HStack(spacing: 10) {
                    ctrl("gobackward.10") { _ = try await client.control("rewind", version: s.version) }
                    ctrl(s.paused ? "play.fill" : "pause.fill") { _ = try await client.control("toggle", version: s.version) }
                    ctrl("goforward.10") { _ = try await client.control("forward", version: s.version) }
                    ctrl("forward.end.fill") { _ = try await client.control("next", version: s.version) }
                }
                Button { Task { await pullToPhone(s) } } label: {
                    Label(pulling ? "正在接过来…" : "接到手机继续看", systemImage: "iphone.and.arrow.forward")
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                        .background(HGTheme.accent, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white)
                }
                .buttonStyle(.plain).disabled(pulling)
                .accessibilityIdentifier("hg.tvr.pull")
            }
            .padding(14).background(HGTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        } else {
            Text("电视现在没在播剧。手机上看剧时点「更多 → 投到电视」就能接到电视上。")
                .font(.footnote).foregroundStyle(HGTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(14).background(HGTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var dpad: some View {
        ZStack {
            Circle().fill(HGTheme.surface).frame(width: 236, height: 236)
            VStack(spacing: 0) {
                arrow("chevron.up", "up")
                HStack(spacing: 0) {
                    arrow("chevron.left", "left")
                    Button { Task { await key("ok") } } label: {
                        Text("OK").font(.headline).foregroundStyle(HGTheme.textPrimary)
                            .frame(width: 84, height: 84).background(HGTheme.surfaceHigh, in: Circle())
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("hg.tvr.key.ok")
                    arrow("chevron.right", "right")
                }
                arrow("chevron.down", "down")
            }
        }
    }

    private func arrow(_ icon: String, _ k: String) -> some View {
        Button { Task { await key(k) } } label: {
            Image(systemName: icon).font(.title2.weight(.semibold)).foregroundStyle(HGTheme.textPrimary)
                .frame(width: 76, height: 76).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("hg.tvr.key.\(k)")
    }

    private func padKey(_ icon: String, _ title: String, _ act: @escaping () async -> Void) -> some View {
        Button { Task { await act() } } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption)
            }
            .foregroundStyle(HGTheme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(HGTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func ctrl(_ icon: String, _ act: @escaping () async throws -> Void) -> some View {
        Button { Task { do { try await act() } catch { note = error.localizedDescription } } } label: {
            Image(systemName: icon).font(.title3).foregroundStyle(HGTheme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 44).background(HGTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func key(_ k: String) async {
        do { try await client.key(k); note = nil } catch { note = error.localizedDescription }
    }

    /// 电视 → 手机：读电视进度、暂停电视，手机从同一集同一秒接着放
    private func pullToPhone(_ s: HGTVStatus) async {
        pulling = true; defer { pulling = false }
        do {
            let fresh = (try? await client.status()) ?? s
            let d = try await HGAPI.detail(fresh.id)
            guard let i = d.episodes.firstIndex(where: { $0.number == fresh.episode }) ?? (fresh.episode > 0 ? min(fresh.episode - 1, d.episodes.count - 1) : nil), !d.episodes.isEmpty else {
                note = "手机上找不到这一集"; return
            }
            _ = try? await client.control("pause", version: fresh.version)
            let series = HGSeries(series_id: fresh.id, series_title: d.series_title, cover: d.cover ?? fresh.cover,
                                  episode_count: d.episodes.count, description: d.description)
            playing = HGPlayerRequest(series: series, episodes: d.episodes, index: i, startAt: Double(fresh.position) / 1000)
        } catch { note = error.localizedDescription }
    }

    private func clock(_ ms: Int) -> String { let s = max(0, ms / 1000); return String(format: "%d:%02d", s / 60, s % 60) }
}

// MARK: - 播放页：投到电视

/// 播放页「更多 → 投到电视」：一台就直接投，多台弹选择；没绑过电视进遥控页去连
struct HGTVHandoff {
    @MainActor static func send(series: HGSeries, index: Int, seconds: Double, to tv: HGRemoteTV) async -> String {
        do {
            try await HGTVClient(tv: tv).handoff(seriesID: series.id, index: index, cover: series.cover, seconds: seconds)
            HGTVStore.shared.remember(tv)
            return "已投到 \(tv.name)，从 \(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60)) 接着播"
        } catch { return error.localizedDescription }
    }
}

// MARK: - 扫码

struct HGQRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerVC { let v = ScannerVC(); v.onCode = onCode; return v }
    func updateUIViewController(_ vc: ScannerVC, context: Context) {}

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            let hint = UILabel()
            hint.text = "对准电视上的二维码"
            hint.textColor = .white; hint.font = .preferredFont(forTextStyle: .headline)
            hint.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hint)
            NSLayoutConstraint.activate([hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                         hint.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40)])
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { ok ? self.setup() : (hint.text = "没有相机权限：设置 → GuoDuo → 相机") }
            }
        }

        private func setup() {
            guard let cam = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: cam),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let out = AVCaptureMetadataOutput()
            guard session.canAddOutput(out) else { return }
            session.addOutput(out)
            out.setMetadataObjectsDelegate(self, queue: .main)
            out.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.frame = view.bounds; layer.videoGravity = .resizeAspectFill
            view.layer.insertSublayer(layer, at: 0)
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            DispatchQueue.global().async { self.session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objs: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let s = (objs.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            done = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onCode?(s)
        }
    }
}


/// 扫到电视登录码后：「用这个账号登录电视？」确认（红果官方扫码登录同一流程）
struct HGTVLoginConfirmSheet: View {
    let ticket: HGTVLoginTicket
    let done: (String?) -> Void
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "tv.and.mediabox").font(.system(size: 40)).foregroundStyle(HGTheme.textPrimary).padding(.top, 26)
            Text("登录电视上的 GuoDuo TV").font(.title3.weight(.bold)).foregroundStyle(HGTheme.textPrimary)
            Text("用手机这个红果账号登录「\(ticket.title)」。登录后电视有自己的会话，手机不受影响。")
                .font(.subheadline).foregroundStyle(HGTheme.textSecondary).multilineTextAlignment(.center).padding(.horizontal, 24)
            if let error { Text(error).font(.footnote).foregroundStyle(HGTheme.accent) }
            HStack(spacing: 12) {
                Button { done(nil) } label: {
                    Text("取消").frame(maxWidth: .infinity, minHeight: 46)
                        .background(HGTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(HGTheme.textPrimary)
                }
                Button { Task { await confirm() } } label: {
                    Group { if busy { ProgressView().tint(.black) } else { Text("确认登录").fontWeight(.semibold) } }
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.black)
                }
                .disabled(busy)
                .accessibilityIdentifier("hg.tvlogin.confirm")
            }
            .buttonStyle(.plain).padding(.horizontal, 20)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HGTheme.surface)
    }

    private func confirm() async {
        busy = true; defer { busy = false }
        do { try await HGAPI.tvLoginConfirm(ticket); done("电视已登录，稍等几秒电视会自动进入首页") }
        catch { self.error = error.localizedDescription }
    }
}
