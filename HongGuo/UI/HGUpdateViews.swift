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

/// 「我的 → 关于」：当前版本、检查更新、开源仓库、上游致谢
struct HGAboutSection: View {
    private enum CheckState: Equatable { case idle, checking, upToDate(String), failed(String) }
    @State private var state: CheckState = .idle
    @State private var found: HGUpdate?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            LabeledContent("当前版本", value: "\(HGUpdateChecker.currentVersion) (\(HGUpdateChecker.currentBuild))")
                .accessibilityIdentifier("hg.about.version")
            Button { Task { await check() } } label: {
                HStack {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
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
            Button { openURL(HGUpdateChecker.repoURL) } label: {
                Label("开源仓库", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .accessibilityIdentifier("hg.about.repo")
            Button { openURL(HGUpdateChecker.releasesURL) } label: {
                Label("历史版本与更新说明", systemImage: "list.bullet.rectangle")
            }
            .accessibilityIdentifier("hg.about.releases")
        } header: {
            Text("关于")
        } footer: {
            Text("GuoDuo 以 GPL-3.0 协议开源。取源核心来自 \(HGUpdateChecker.upstreamRepo)（GPL-3.0），感谢原作者及其上游贡献者。")
        }
        .listRowBackground(HGTheme.surface)
        .sheet(item: $found) { HGUpdateSheet(update: $0) }
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
