import SwiftUI

/// 新版本弹窗：版本对比 + 完整更新说明 + 去下载 / 以后再说
struct HGUpdateSheet: View {
    let update: HGUpdate
    /// 关闭时回调；launch=true 的弹窗关掉后记住这个版本不再自动弹
    var onClose: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if update.notes.isEmpty {
                        Text("这个版本没有写更新说明。")
                            .font(.subheadline).foregroundStyle(HGTheme.textSecondary)
                    } else {
                        HGMarkdownView(markdown: update.notes)
                    }
                    Text("打开电脑上的一键签就会自动装上新版，观看记录和收藏会保留。还没装一键签的点下面按钮去 oneduo.app 下载。")
                        .font(.footnote).foregroundStyle(HGTheme.textTertiary)
                        .padding(.top, 4)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(HGTheme.background)
            .safeAreaInset(edge: .bottom) { actions }
            .navigationTitle("有新版本")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("hg.update.sheet")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("v\(HGUpdateChecker.currentVersion)").foregroundStyle(HGTheme.textSecondary)
            Image(systemName: "arrow.right").foregroundStyle(HGTheme.textTertiary)
            Text("v\(update.version)").fontWeight(.semibold).foregroundStyle(HGTheme.accent)
        }
        .font(.title3.monospacedDigit())
        .padding(.vertical, 10).padding(.horizontal, 14)
        .background(HGTheme.surface, in: RoundedRectangle(cornerRadius: HGTheme.radius))
        .accessibilityIdentifier("hg.update.versions")
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button {
                onClose(); dismiss(); openURL(update.pageURL)
            } label: {
                Text("去一键签更新").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).tint(HGTheme.accent)
            .accessibilityIdentifier("hg.update.open")
            Button("以后再说") { onClose(); dismiss() }
                .foregroundStyle(HGTheme.textSecondary)
                .accessibilityIdentifier("hg.update.later")
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
        .background(HGTheme.background)
    }
}

/// 轻量 Markdown 块渲染：# 标题 / - * 列表 / 1. 序号 / > 引用 / 段落；行内粗体、代码、链接交给 AttributedString
struct HGMarkdownView: View {
    let markdown: String

    private enum Block: Hashable {
        case heading(Int, String), bullet(String), ordered(String, String), quote(String), paragraph(String)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var para: [String] = []
        func flush() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] } }
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("```") || line.hasPrefix("---") || line.hasPrefix("<") { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                let level = line.prefix(while: { $0 == "#" }).count
                out.append(.heading(level, line.dropFirst(level).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flush(); out.append(.bullet(String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line[line.index(after: dot)...].hasPrefix(" ") {
                flush(); out.append(.ordered(String(line[..<dot]), line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix(">") {
                flush(); out.append(.quote(line.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else {
                para.append(line)
            }
        }
        flush()
        return out
    }

    private func inline(_ s: String) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? AttributedString(markdown: s, options: opts) { return Text(a) }
        return Text(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .heading(let level, let s):
                    inline(s)
                        .font(level <= 1 ? .title3.weight(.bold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                        .foregroundStyle(HGTheme.textPrimary)
                        .padding(.top, level <= 2 ? 8 : 4)
                case .bullet(let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(HGTheme.accent)
                        inline(s).foregroundStyle(HGTheme.textPrimary)
                    }
                case .ordered(let n, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(n).").monospacedDigit().foregroundStyle(HGTheme.accent)
                        inline(s).foregroundStyle(HGTheme.textPrimary)
                    }
                case .quote(let s):
                    inline(s).foregroundStyle(HGTheme.textSecondary)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(HGTheme.surfaceHigh).frame(width: 3) }
                case .paragraph(let s):
                    inline(s).foregroundStyle(HGTheme.textSecondary)
                }
            }
        }
        .font(.subheadline)
        .tint(HGTheme.accent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

/// 「设置」里的「关于」：只留一行入口（右边显示版本号），点进去是详情页
struct HGAboutSection: View {
    var body: some View {
        Section {
            NavigationLink { HGAboutScreen() } label: {
                HGSettingRow(icon: "info.circle.fill", tint: .gray, title: "关于 GuoDuo") {
                    Text("v\(HGUpdateChecker.currentVersion)").font(.subheadline.monospacedDigit()).foregroundStyle(HGTheme.textSecondary)
                }
            }
            .accessibilityIdentifier("hg.about.entry")
        } header: { Text("关于") }
        .listRowBackground(HGTheme.surface)
    }
}

/// 关于详情：版本 / 检查更新、开源仓库、开源致谢（取源核心 hongguo-drama + 参考实现绿果TV + DouDuo）、协议
struct HGAboutScreen: View {
    private enum CheckState: Equatable { case idle, checking, upToDate(String), failed(String) }
    @State private var state: CheckState = .idle
    @State private var found: HGUpdate?
    @Environment(\.openURL) private var openURL

    /// 开源致谢：名称、仓库、协议、用在哪
    private struct Credit: Identifiable { let name: String; let repo: String; let license: String; let use: String; var id: String { repo } }
    private let credits: [Credit] = [
        Credit(name: "hongguo-drama", repo: HGUpdateChecker.upstreamRepo, license: "GPL-3.0",
               use: "取源核心：签名、取片源、解密、搜索、分类、弹幕（core/upstream 原样搬运）"),
        Credit(name: "绿果TV", repo: "Amor5207/lvguo-tv", license: "GPL-3.0",
               use: "参考实现：账号推荐流、云端历史 / 收藏、手机号登录、分集评论、头像地址、写接口签名"),
        Credit(name: "DouDuo", repo: "81199000/DouDuo", license: "MIT",
               use: "播放器、手势、弹幕引擎、右侧栏、缓存管理界面"),
    ]

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "play.rectangle.on.rectangle.fill")
                        .font(.system(size: 34, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(HGTheme.accent.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Text("GuoDuo").font(.title2.weight(.bold)).foregroundStyle(HGTheme.textPrimary)
                    Text("版本 \(HGUpdateChecker.currentVersion)（\(HGUpdateChecker.currentBuild)）")
                        .font(.footnote.monospacedDigit()).foregroundStyle(HGTheme.textSecondary)
                        .accessibilityIdentifier("hg.about.version")
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                Button { Task { await check() } } label: {
                    HGSettingRow(icon: "arrow.triangle.2.circlepath", tint: .blue, title: "检查更新") {
                        switch state {
                        case .idle: EmptyView()
                        case .checking: ProgressView().controlSize(.small)
                        case .upToDate(let v): Text("已是最新 v\(v)").font(.footnote).foregroundStyle(HGTheme.textSecondary)
                        case .failed(let m): Text(m).font(.footnote).foregroundStyle(HGTheme.accent).lineLimit(2).multilineTextAlignment(.trailing)
                        }
                    }
                }
                .disabled(state == .checking)
                .accessibilityIdentifier("hg.about.check")
                Button { openURL(HGUpdateChecker.releasesURL) } label: {
                    HGSettingRow(icon: "list.bullet.rectangle.fill", tint: .indigo, title: "历史版本与更新说明") { link }
                }
                .accessibilityIdentifier("hg.about.releases")
                Button { openURL(HGUpdateChecker.repoURL) } label: {
                    HGSettingRow(icon: "chevron.left.forwardslash.chevron.right", tint: Color(white: 0.32), title: "GuoDuo 开源仓库",
                                 subtitle: HGUpdateChecker.repo) { link }
                }
                .accessibilityIdentifier("hg.about.repo")
            } header: { Text("版本") }
            .listRowBackground(HGTheme.surface)

            Section {
                ForEach(credits) { c in
                    Button { if let u = URL(string: "https://github.com/\(c.repo)") { openURL(u) } } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(c.name).font(.body.weight(.semibold)).foregroundStyle(HGTheme.textPrimary)
                                Text(c.license).font(.caption2.weight(.semibold)).foregroundStyle(HGTheme.textSecondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(HGTheme.surfaceHigh, in: Capsule())
                                Spacer(minLength: 4)
                                link
                            }
                            Text(c.repo).font(.caption.monospaced()).foregroundStyle(HGTheme.textTertiary)
                            Text(c.use).font(.footnote).foregroundStyle(HGTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("hg.about.credit.\(c.name)")
                }
            } header: { Text("开源致谢") } footer: {
                Text("感谢以上项目的原作者，以及他们致谢的上游贡献者（woshishiq1/drpys、N3urda/hongguoTV、tsukiyo-zero/hongguoTV、charlie901208/HGTV 等）。")
            }
            .listRowBackground(HGTheme.surface)

            Section {
                Text("GuoDuo 以 GPL-3.0 协议开源。本 App 只做第三方播放，内容版权归红果短剧及原作者所有。")
                    .font(.footnote).foregroundStyle(HGTheme.textSecondary)
            } header: { Text("协议") }
            .listRowBackground(HGTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(HGTheme.background)
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $found) { HGUpdateSheet(update: $0) }
    }

    private var link: some View {
        Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(HGTheme.textTertiary)
    }

    private func check() async {
        state = .checking
        do {
            let remote = try await HGUpdateChecker.latest()
            if HGUpdateChecker.isNewer(remote.version, than: HGUpdateChecker.currentVersion) {
                state = .idle; found = remote
            } else {
                state = .upToDate(HGUpdateChecker.currentVersion)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
