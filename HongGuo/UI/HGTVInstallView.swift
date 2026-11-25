// 「安装到电视」：教用户打开电视 ADB 调试 → 局域网找电视（或手填 IP）→ 手机下载 GuoDuo TV 安装包推过去装上。
import SwiftUI

struct HGTVInstallView: View {
    @State private var scanner = HGTVScanner()
    @State private var installer = HGTVInstaller()
    @State private var recent = HGTVRecent.load()
    @State private var manual = ""
    @State private var manualError: String?
    @State private var picked: HGTVDevice?
    @State private var showTutorial = false
    @AppStorage("hg.tv.tutorialSeen") private var tutorialSeen = false

    var body: some View {
        List {
            Section {
                DisclosureGroup(isExpanded: $showTutorial) { tutorial } label: {
                    Label("先在电视上打开 ADB 调试（教程）", systemImage: "list.number").foregroundStyle(HGTheme.textPrimary)
                }
                .accessibilityIdentifier("hg.tv.tutorial")
            } footer: {
                Text("手机和电视需要连同一个 Wi‑Fi。电视版是 GuoDuo 的安卓电视客户端，用遥控器看剧。")
            }
            .hgRowBackground()

            if let picked, installer.phase != .idle { progressSection(picked) }
            else { deviceSections }
        }
        .scrollContentBackground(.hidden)
        .hgPageBackground()
        .navigationTitle("安装到电视")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if !tutorialSeen { showTutorial = true; tutorialSeen = true }; scanner.start() }
        .onDisappear { scanner.stop(); if installer.busy { installer.cancel() } }
    }

    // MARK: 找到的电视

    @ViewBuilder private var deviceSections: some View {
        Section {
            ForEach(scanner.devices) { tvRow($0) }
            if scanner.devices.isEmpty {
                HStack(spacing: 10) {
                    if scanner.scanning { ProgressView() }
                    Text(scanner.scanning ? "正在局域网里找电视…" : "没找到电视。确认已打开 ADB 调试，或在下面手动输入电视 IP")
                        .font(.footnote).foregroundStyle(HGTheme.textSecondary)
                }
            }
        } header: {
            HStack { Text("附近的电视"); Spacer(); Button("重新扫描") { scanner.start() }.font(.footnote).disabled(scanner.scanning) }
        }
        .hgRowBackground()

        let extra = recent.filter { r in !scanner.devices.contains { $0.id == r.id } }
        if !extra.isEmpty {
            Section("最近连过") { ForEach(extra) { tvRow($0) } }.hgRowBackground()
        }

        Section {
            HStack {
                TextField("例如 192.168.1.20", text: $manual)
                    .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("hg.tv.ip")
                    .onSubmit(connectManual)
                Button("连接", action: connectManual).disabled(manual.isEmpty).accessibilityIdentifier("hg.tv.connect")
            }
            if let manualError { Text(manualError).font(.caption).foregroundStyle(HGTheme.accent) }
        } header: { Text("找不到？手动输入电视 IP") }
        footer: { Text("在电视「设置 → 网络 → 当前网络」里能看到 IP 地址（如 192.168.1.20）。端口默认 5555，不用填。") }
        .hgRowBackground()
    }

    private func tvRow(_ tv: HGTVDevice) -> some View {
        Button { begin(tv) } label: {
            HStack {
                Image(systemName: "tv").foregroundStyle(HGTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tv.name).foregroundStyle(HGTheme.textPrimary)
                    Text(tv.host).font(.caption).foregroundStyle(HGTheme.textTertiary)
                }
                Spacer()
                Text("安装").font(.footnote.weight(.semibold)).foregroundStyle(HGTheme.accent)
            }
        }
        .accessibilityIdentifier("hg.tv.device.\(tv.host)")
    }

    private func connectManual() {
        guard let tv = hgParseTVAddress(manual) else { manualError = "IP 格式不对，应类似 192.168.1.20"; return }
        manualError = nil
        begin(tv)
    }

    private func begin(_ tv: HGTVDevice) { picked = tv; installer.start(tv) }

    // MARK: 进度

    @ViewBuilder private func progressSection(_ tv: HGTVDevice) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "tv").font(.title2).foregroundStyle(HGTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(installer.tvTitle.isEmpty ? tv.name : installer.tvTitle).font(.headline).foregroundStyle(HGTheme.textPrimary)
                        Text(tv.host).font(.caption).foregroundStyle(HGTheme.textTertiary)
                    }
                }
                statusBody
            }
            .padding(.vertical, 6)
            .accessibilityIdentifier("hg.tv.status")
        }
        .hgRowBackground()
    }

    @ViewBuilder private var statusBody: some View {
        switch installer.phase {
        case .idle: EmptyView()
        case .connecting:
            step("正在连接电视…", spinner: true)
        case .approving:
            step("请看电视屏幕：在「允许 USB 调试？」里勾选「始终允许」，再点「允许」", spinner: true)
            Text("没弹窗？确认电视已开启 ADB 调试，并按遥控器「确定」键唤醒屏幕。").font(.caption).foregroundStyle(HGTheme.textTertiary)
        case .downloading(let p):
            bar("正在下载电视版安装包…", p)
        case .installing(let p):
            bar(p >= 1 ? "电视正在安装…" : "正在把安装包传到电视…", p)
        case .done:
            Label(installer.installedBefore == nil ? "已安装到电视" : "已更新到 \(installer.newVersion)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.headline)
            Text(installer.launched == true ? "已在电视上打开，用遥控器就能看了。" : "在电视的应用列表里找「GuoDuo TV」打开。")
                .font(.footnote).foregroundStyle(HGTheme.textSecondary)
            Button("完成") { installer.phase = .idle; picked = nil; recent = HGTVRecent.load() }.buttonStyle(.borderedProminent).tint(HGTheme.accent)
        case .failed(let msg):
            Label("没装成功", systemImage: "exclamationmark.triangle.fill").foregroundStyle(HGTheme.accent).font(.headline)
            Text(msg).font(.footnote).foregroundStyle(HGTheme.textSecondary)
            HStack {
                Button("重试") { if let picked { installer.phase = .idle; installer.start(picked) } }.buttonStyle(.borderedProminent).tint(HGTheme.accent)
                Button("换一台") { installer.phase = .idle; picked = nil }.buttonStyle(.bordered)
            }
        }
        if installer.busy { Button("取消", role: .cancel) { installer.cancel(); picked = nil }.font(.footnote) }
    }

    private func step(_ text: String, spinner: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if spinner { ProgressView() }
            Text(text).font(.subheadline).foregroundStyle(HGTheme.textPrimary)
        }
    }

    private func bar(_ text: String, _ p: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.subheadline).foregroundStyle(HGTheme.textPrimary)
            ProgressView(value: p).tint(HGTheme.accent)
        }
    }

    // MARK: 教程

    private var tutorial: some View {
        VStack(alignment: .leading, spacing: 14) {
            tip(1, "打开开发者模式", "电视「设置 → 关于（设备信息）」，找到「版本号 / 内部版本」，用遥控器连按「确定」键 7 次，看到「已进入开发者模式」。")
            tip(2, "打开 ADB 调试", "回到「设置」，进入「开发者选项」（有的在「系统」或「更多设置」里），打开「USB 调试」。小米电视同时打开「ADB 调试」，部分品牌叫「网络调试 / ADB 网络调试」。")
            tip(3, "确认同一个 Wi‑Fi", "手机和电视连同一个路由器（电视用网线也行，只要在同一个局域网）。")
            tip(4, "找不到电视时查 IP", "「设置 → 网络 → 当前网络」能看到 IP 地址，下面手动输入。")
            tip(5, "点安装并在电视上允许", "第一次连接，电视会弹「允许 USB 调试？」，勾选「始终允许」再点「允许」，之后就不用再点了。")
            Text("装完可以回电视「开发者选项」把 USB 调试关掉。部分电视每次开机会自动关掉 ADB 调试，下次安装前需要再打开。")
                .font(.caption).foregroundStyle(HGTheme.textTertiary)
        }
        .padding(.vertical, 4)
    }

    private func tip(_ n: Int, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(HGTheme.accent, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(HGTheme.textPrimary)
                Text(body).font(.footnote).foregroundStyle(HGTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
