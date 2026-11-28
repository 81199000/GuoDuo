// 普通投屏的电视列表（没绑过 GuoDuo TV 时「更多 → 投到电视」弹这个）
import SwiftUI

struct HGCastPicker: View {
    let onPick: (HGCastTarget) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var browser = HGCastBrowser()
    @State private var manual = ""
    @State private var checking = false
    @State private var manualError: String?

    var body: some View {
        List {
            Section {
                ForEach(browser.found) { t in
                    Button { onPick(t); dismiss() } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "tv").font(.title3).foregroundStyle(HGTheme.accent).frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).foregroundStyle(HGTheme.textPrimary).lineLimit(1)
                                Text("\(t.kind.rawValue) · \(t.host)").font(.caption).foregroundStyle(HGTheme.textSecondary)
                            }
                            Spacer()
                        }
                    }
                    .accessibilityIdentifier("hg.cast.target.\(t.kind.rawValue).\(t.host)")
                }
                if browser.scanning {
                    HStack(spacing: 10) { ProgressView(); Text("正在找同一 Wi-Fi 下的电视…").foregroundStyle(HGTheme.textSecondary) }
                } else if browser.found.isEmpty {
                    Text("没找到电视。确认手机和电视连的是同一个 Wi-Fi，电视已开机。").font(.footnote).foregroundStyle(HGTheme.textSecondary)
                }
            } header: { Text("同一 Wi-Fi 下的电视") } footer: {
                Text("电视会自己从手机上拉这一集来放，投屏期间别关 GuoDuo。")
            }
            Section("找不到？输入电视的 IP") {
                HStack {
                    TextField("如 192.168.1.20", text: $manual).keyboardType(.decimalPad).textInputAutocapitalization(.never)
                    Button(checking ? "查找中…" : "连接") { Task { await connectManual() } }.disabled(checking || manual.isEmpty)
                }
                if let manualError { Text(manualError).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("投到电视")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button { browser.start() } label: { Label("重新查找", systemImage: "arrow.clockwise") }.disabled(browser.scanning)
            }
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    private func connectManual() async {
        let ip = manual.trimmingCharacters(in: .whitespaces)
        guard ip.split(separator: ".").count == 4 else { manualError = "IP 格式不对"; return }
        checking = true; manualError = nil
        defer { checking = false }
        let list = await HGCastBrowser.findDLNA([ip])
        if let t = list.first { onPick(t); dismiss(); return }
        // AirPlay 默认端口（7000，小米这类是 47000）
        for p: UInt16 in [7000, 47000] where await HGCastProbe.open(ip, port: p, timeout: 1.5) {
            onPick(HGCastTarget(kind: .airplay, name: "电视 \(ip)", host: ip, port: Int(p))); dismiss(); return
        }
        manualError = "这个地址上没找到能投屏的电视"
    }
}

/// 播放页顶部：正在投屏的提示条（点「停止」收回手机接着放）
struct HGCastBanner: View {
    let session: HGCastSession
    let onStop: () -> Void
    var body: some View {
        if let t = session.target {
            HStack(spacing: 10) {
                Image(systemName: "tv.fill").foregroundStyle(HGTheme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("正在投到 \(t.name)").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(session.title).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("停止", action: onStop).buttonStyle(.borderedProminent).tint(HGTheme.accent).controlSize(.small)
                    .accessibilityIdentifier("hg.cast.stop")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: HGTheme.radius, style: .continuous))
            .padding(.horizontal, 16)
            .accessibilityElement(children: .contain)   // 不然外层 id 会盖掉「停止」按钮自己的 id
            .accessibilityIdentifier("hg.cast.banner")
        } else if let n = session.note {
            Text(n).font(.footnote.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 8)
                .background(.black.opacity(0.65), in: Capsule()).foregroundStyle(.white)
        }
    }
}
