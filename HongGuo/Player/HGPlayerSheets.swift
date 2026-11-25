import SwiftUI

/// 本集热评面板（DouDuo DYCommentPanel 经典样式）：标题「N 条评论」居中 + 右侧关闭、分隔线、
/// 头像 32 / 昵称 caption 次要色 / 正文 subheadline / 时间 caption2 / 右侧点赞列。
/// 内容只放官网公开的前 15 条热评（老板定）；总数取 App 详情接口的本集评论数。
enum HGCommentPolicy {
    /// 以前走官网公开页只有前 5 集有评论；现在走 App 分集评论接口（同绿果TV），每一集都能看
    static let publicEpisodes = Int.max
}

struct HGCommentPanel: View {
    let series: HGSeries
    let episode: HGEpisode
    var total: Int?
    /// 发弹幕要当前播放进度、发完插进屏幕弹幕；nil = 只能发评论
    var session: HGPlaybackSession? = nil
    let onClose: (() -> Void)?
    var fillsPane = false
    var trailingInset: CGFloat = 0
    var horizontalStatus = false
    /// 横屏侧滑面板：整块（含列表）右滑都能关；标题栏顶部让出状态栏，关闭键放左边不被信号 / 电量挡
    var swipeRightClosesAnywhere = false
    @State private var data: HGComments?
    @State private var error: String?
    // 发评论 / 弹幕
    @State private var draft = ""
    @State private var asDanmaku = false
    @State private var sending = false
    @State private var sendNote: String?
    @State private var signedIn: Bool?
    @State private var me: HGAccountInfo?
    @FocusState private var composing: Bool

    private var count: Int? { total ?? data?.total }

    var body: some View {
        VStack(spacing: 0) {
            heading
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let data {
                        ForEach(data.items) { HGReviewRow(review: $0) }
                        if data.items.isEmpty {
                            Text("本集还没有评论").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        } else if data.hasMore == true {
                            // 滑到底自动加载下一页
                            ProgressView().frame(maxWidth: .infinity)
                                .task(id: data.next) { await loadMore() }
                        }
                    } else if let error {
                        Text(error).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.trailing, trailingInset)
                .padding(.vertical, 16)
            }
            .accessibilityIdentifier("hg.comments.list")
            .scrollDismissesKeyboard(.interactively)
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(fillsPane ? Color(uiColor: .secondarySystemBackground) : .clear)
        .environment(\.colorScheme, .dark)
        .clipped()
        .modifier(DYPanelDismissGesture(isAtTop: false, allowsSwipeRight: swipeRightClosesAnywhere,
                                        onClose: swipeRightClosesAnywhere ? onClose : nil))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hg.comments.panel")
        .task(id: episode.vid) { await load() }
        .task {
            signedIn = (try? await HGAPI.accountStatus())?.signedIn ?? false
            if signedIn == true { me = try? await HGAPI.accountInfo() }
        }
    }

    // MARK: 发评论 / 弹幕
    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sendNote {
                Text(sendNote).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .accessibilityIdentifier("hg.comments.sendNote")
            }
            HStack(spacing: 8) {
                if session != nil {
                    // 评论 ⇄ 弹幕
                    Button { asDanmaku.toggle(); sendNote = nil } label: {
                        Text(asDanmaku ? "弹幕" : "评论").font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).frame(height: 32)
                            .background(Capsule().fill(asDanmaku ? HGTheme.accent.opacity(0.85) : Color.primary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(asDanmaku ? "切到发评论" : "切到发弹幕")
                    .accessibilityIdentifier("hg.comments.mode")
                }
                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.subheadline)
                    .focused($composing)
                    .submitLabel(.send)
                    .onSubmit { Task { await send() } }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.08)))
                    .disabled(signedIn != true || sending)
                    .accessibilityIdentifier("hg.comments.field")
                Button { Task { await send() } } label: {
                    if sending { ProgressView().frame(width: 32, height: 32) }
                    else {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                            .foregroundStyle(canSend ? HGTheme.accent : Color.secondary.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("发送")
                .accessibilityIdentifier("hg.comments.send")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .padding(.trailing, trailingInset)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var placeholder: String {
        if signedIn == false { return "登录红果账号后可发评论（我的 → 登录）" }
        if asDanmaku, let s = session { return "在 \(Self.clock(s.position)) 发一条弹幕" }
        return "说说你对这部剧的看法"
    }
    private var canSend: Bool { signedIn == true && !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        sending = true; sendNote = nil
        defer { sending = false }
        do {
            if asDanmaku, let s = session {
                let at = s.position
                try await HGAPI.postDanmaku(series: series.series_id, vid: episode.vid, text: text, offsetMs: Int(at * 1000))
                // 发出的弹幕立刻在画面上飘一次（接口那边审核后别人才看得到）
                s.danmaku.append(DYDanmaku(id: "mine-\(Int(Date().timeIntervalSince1970 * 1000))", text: text, offset: at + 0.3))
                s.danmaku.sort { $0.offset < $1.offset }
                sendNote = "弹幕已发出"
            } else {
                try await HGAPI.postComment(series: series.series_id, vid: episode.vid, text: text)
                // 先插到列表最上面；红果那边审核通过后刷新才会出现在公开列表里
                // 用自己账号的头像 / 昵称（「我的」页同一份资料）
                let mine = HGReview(author: me?.name ?? "我", avatar: me?.avatar, content: text,
                                    created_at: Date().timeIntervalSince1970 * 1000, likes: 0)
                if data != nil { data?.items.insert(mine, at: 0) } else { data = HGComments(total: nil, items: [mine]) }
                sendNote = "评论已发出，红果审核后公开显示"
            }
            draft = ""; composing = false
        } catch {
            sendNote = error.localizedDescription
            HGTrace.log("发\(asDanmaku ? "弹幕" : "评论")失败: \(error.localizedDescription)")
        }
    }

    static func clock(_ t: Double) -> String {
        let s = max(0, Int(t)); return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var title: some View {
        Text(count.map { $0 > 0 ? "\(DDMedia.count($0)) 条评论" : "评论" } ?? "评论")
            .font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("hg.comments.title")
    }

    @ViewBuilder private var closeButton: some View {
        if let onClose {
            Button(action: onClose) {
                Image(systemName: "xmark").font(.subheadline.weight(.semibold))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭评论")
            .accessibilityIdentifier("hg.comments.close")
        }
    }

    private var heading: some View {
        VStack(spacing: 0) {
            Group {
                if horizontalStatus {
                    // 关闭键在左（右上角是信号 / 电量），整行压在状态栏下面
                    HStack(spacing: 4) { closeButton; title; Spacer(minLength: 0) }
                        .frame(minHeight: 44)
                        .padding(.top, DYDuoMetrics.windowSafeTop)
                } else {
                    ZStack(alignment: .trailing) { title.frame(maxWidth: .infinity); closeButton }
                        .frame(minHeight: 44)
                }
            }
            .padding(.horizontal, 16)
            .padding(.trailing, trailingInset)
            Divider()
        }
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
        .modifier(DYPanelDismissGesture(allowsSwipeRight: true, onClose: onClose))
    }

    private func load() async {
        error = nil; data = nil
        do { data = try await HGAPI.comments(series: series.series_id, vid: episode.vid) }
        catch { self.error = "评论暂时打不开，稍后再试" }
    }

    private func loadMore() async {
        guard let cur = data, cur.hasMore == true, let next = cur.next else { return }
        guard let page = try? await HGAPI.comments(series: series.series_id, vid: episode.vid, offset: next) else {
            data?.hasMore = false; return
        }
        guard data?.next == next else { return }   // 换集了
        let seen = Set(cur.items.map(\.id))
        data?.items += page.items.filter { !seen.contains($0.id) }
        data?.next = page.next
        data?.hasMore = page.hasMore == true && !page.items.isEmpty
    }
}

/// DouDuo rowBody 同款
private struct HGReviewRow: View {
    let review: HGReview
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: review.avatar.flatMap(URL.init(string:))) { img in img.resizable().scaledToFill() } placeholder: { Color.primary.opacity(0.08) }
                .frame(width: 32, height: 32).clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(review.author.isEmpty ? "红果用户" : review.author).font(.caption.weight(.semibold)).foregroundStyle(.primary.opacity(0.72))
                Text(review.content).font(.subheadline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                if let t = review.created_at { Text(Self.time(t / 1000)).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 4)
            if let likes = review.likes {
                VStack(spacing: 2) {
                    Image(systemName: "heart").font(.caption)
                    Text(DDMedia.count(max(0, likes))).font(.caption2)
                }
                .foregroundStyle(.secondary)
                .frame(minWidth: 32, minHeight: 36)
            }
        }
    }

    /// DouDuo DYFormat.time
    static func time(_ ts: Double) -> String {
        let d = Date().timeIntervalSince1970 - ts
        if d < 3600 { return "\(max(1, Int(d / 60)))分钟前" }
        if d < 86400 { return "\(Int(d / 3600))小时前" }
        if d < 86400 * 30 { return "\(Int(d / 86400))天前" }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}

struct HGEpisodeSheet: View {
    let session: HGPlaybackSession
    let close: () -> Void
    /// 书本半折叠常驻：铺满右半屏、深色、让开右侧系统栏
    var fillsPane = false
    var trailingInset: CGFloat = 0
    /// 推荐流：点集不在本会话里换集，而是打开整部剧
    var onPick: ((Int) -> Void)? = nil
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(session.series.series_title).font(.headline).lineLimit(1)
                Spacer()
                Text("共 \(session.episodes.count) 集").font(.caption).foregroundStyle(HGTheme.textSecondary)
            }
            .padding(.horizontal, 18).padding(.trailing, trailingInset).padding(.top, 20).padding(.bottom, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 8)], spacing: 8) {
                        ForEach(Array(session.episodes.enumerated()), id: \.element.id) { i, ep in
                            Button { if let onPick { onPick(i) } else { session.go(to: i) }; close() } label: {
                                Text("\(ep.number)").font(.subheadline.monospacedDigit())
                                    .frame(maxWidth: .infinity, minHeight: 40)
                                    .background(i == session.index ? HGTheme.accent : HGTheme.surfaceHigh,
                                                in: RoundedRectangle(cornerRadius: HGTheme.radiusSmall, style: .continuous))
                                    .foregroundStyle(i == session.index ? Color.white : (ep.locked == true ? HGTheme.textTertiary : HGTheme.textPrimary))
                                    .overlay(alignment: .topTrailing) {
                                        if ep.locked == true { Image(systemName: "lock.fill").font(.system(size: 8)).padding(4).foregroundStyle(HGTheme.textTertiary) }
                                    }
                            }
                            .id(i)
                            .accessibilityIdentifier("hg.ep.\(ep.number)")
                        }
                    }
                    .padding(.horizontal, 16).padding(.trailing, trailingInset).padding(.bottom, 24)
                }
                .onAppear { proxy.scrollTo(session.index, anchor: .center) }
                .onChange(of: session.index) { _, i in withAnimation(.snappy) { proxy.scrollTo(i, anchor: .center) } }
            }
        }
        .padding(.trailing, 0)
        .background(fillsPane ? Color(uiColor: .secondarySystemBackground) : HGTheme.surface)
        .environment(\.colorScheme, .dark)
    }
}
