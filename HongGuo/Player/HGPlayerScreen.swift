import SwiftUI
import AVKit

/// DouDuo 式竖滑短剧播放页：一集一页，上下滑切集；手势层原样用 DouDuo 的 PlayerGestureView。
struct HGPlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var session: HGPlaybackSession
    @State private var page: Int?
    @State private var library = HGLibrary.shared

    @AppStorage("hg.danmaku.on") private var danmakuOn = true
    @AppStorage("hg.fillWidth") private var fillWidth = true

    @State private var clean = false               // 清屏（全屏）：只留画面
    @State private var showComments = false
    @State private var showEpisodes = false
    @State private var showMore = false
    @State private var commentTip = false
    @State private var commentTipTask: Task<Void, Never>?
    /// 评论是否占着一侧（侧滑 / 半折常驻）：本视图自己的 body 里算出来，不能用环境值读回自己
    @State private var commentsInPane = false
    /// 桌面姿态操作台在：弹幕搬到操作台上，视频上不再画
    @State private var consoleShown = false
    @AppStorage("hg.deskLight") private var deskLight = true
    /// 桌面姿态弹幕位置：false = 影片区（上半屏），true = 触控区（下半屏）
    @AppStorage("hg.danmaku.inConsole") private var danmakuInConsole = false
    @State private var consoleControls = false
    @State private var seeking = false
    @State private var seekPreview: Double = 0
    @State private var seekAnchor: Double = 0
    @State private var pinchScale: CGFloat = 1
    @State private var userScale: CGFloat = 1
    @State private var edgeOffset: CGFloat = 0
    @State private var toast: String?
    @State private var heartBurst = false
    @State private var landscape = false

    private static let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

    init(request: HGPlayerRequest) {
        _session = State(initialValue: HGPlaybackSession(request))
        _page = State(initialValue: request.index)
    }

    /// DouDuo DYCommentStage / DYCommentPlayerLayout 同一套几何（原样搬的 DYCommentPaneMetrics）：
    /// - 内屏平放 / 横屏（宽 ≥ 700）：点评论 → 视频缩窄，评论从右侧滑出
    /// - 半折叠书本：左视频、右评论常驻；桌面：上视频、下评论常驻 + 倒影环境光（dyDeskLight）
    /// - 外屏 / 普通竖屏：贴边底部液态玻璃面板
    var body: some View {
        GeometryReader { outer in
            let showsComments = showComments && session.series.source == .hongguo
            let layout = DYCommentPaneMetrics(outer, isPresented: showsComments, allowsResident: true)
            ZStack(alignment: .topLeading) {
                pager
                    .frame(width: layout.videoSize.width, height: layout.videoSize.height)
                    .clipped()
                if layout.resident && !layout.sideBySide {
                    // 竖屏半折叠（桌面）：下半屏 = 全黑操作台
                    HGConsolePane(session: session, deskLight: $deskLight, controlsShown: $consoleControls,
                                  danmakuOn: $danmakuOn, danmakuInConsole: $danmakuInConsole,
                                  creaseTop: layout.creaseInset,
                                  bottomInset: DYDuoMetrics.windowBottomInset,
                                  onBack: { dismiss() },
                                  onEpisodes: { showEpisodes = true },
                                  onMore: { showMore = true },
                                  flash: { flash($0) })
                        .frame(width: layout.paneSize.width, height: layout.paneSize.height)
                        .clipped()
                        .offset(x: layout.paneOrigin.x, y: layout.paneOrigin.y)
                        .transition(.move(edge: .bottom))
                } else if layout.resident && layout.sideBySide && showsComments {
                    // 书本姿态点了评论：右半屏临时换成评论，关掉回选集
                    HGCommentPanel(series: session.series, episode: session.episode, total: session.episodeStat?.comments,
                                   onClose: { showComments = false },
                                   fillsPane: true, trailingInset: layout.trailingInset,
                                   horizontalStatus: true, swipeRightClosesAnywhere: true)
                        .id(session.episode.vid)
                        .frame(width: layout.paneSize.width, height: layout.paneSize.height)
                        .clipped()
                        .overlay(alignment: .leading) { Color(uiColor: .separator).frame(width: 0.5) }
                        .offset(x: layout.paneOrigin.x, y: layout.paneOrigin.y)
                        .transition(.move(edge: .trailing))
                        .accessibilityIdentifier("hg.comments.side")
                } else if layout.resident && layout.sideBySide {
                    // 横屏半折叠（书本）：右半屏 = 选集
                    HGEpisodeSheet(session: session, close: {}, fillsPane: true, trailingInset: layout.trailingInset)
                        .padding(.top, DYDuoMetrics.isDuoHardware ? 0 : DYDuoMetrics.windowSafeTop)
                        .frame(width: layout.paneSize.width, height: layout.paneSize.height)
                        .clipped()
                        .overlay(alignment: .leading) { Color(uiColor: .separator).frame(width: 0.5) }
                        .offset(x: layout.paneOrigin.x, y: layout.paneOrigin.y)
                        .transition(.move(edge: .trailing))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("hg.episodes.resident")
                } else if layout.showsPane {
                    HGCommentPanel(series: session.series, episode: session.episode, total: session.episodeStat?.comments,
                                   onClose: { showComments = false },
                                   fillsPane: true, trailingInset: layout.trailingInset,
                                   horizontalStatus: true, swipeRightClosesAnywhere: true)
                        .id(session.episode.vid)
                        .frame(width: layout.paneSize.width, height: layout.paneSize.height)
                        .clipped()
                        .overlay(alignment: .leading) {
                            if layout.sideBySide { Color(uiColor: .separator).frame(width: 0.5) }
                        }
                        .offset(x: layout.paneOrigin.x, y: layout.paneOrigin.y)
                        .transition(.move(edge: .trailing))
                        .accessibilityIdentifier("hg.comments.side")
                }
            }
            .frame(width: outer.size.width, height: outer.size.height, alignment: .topLeading)
            .background(Color.black.ignoresSafeArea())
            // 书本姿态：右边是常驻选集，视频上照常显示完整菜单栏（右侧 DouDuo 液态玻璃栏）
            .onChange(of: layout.showsPane && !(layout.resident && layout.sideBySide && !showsComments), initial: true) { _, v in commentsInPane = v }
            .onChange(of: layout.resident && !layout.sideBySide, initial: true) { _, v in consoleShown = v }
            .animation(.snappy, value: layout.showsPane)
            .animation(.snappy, value: layout.resident)
            .dyBottomSheet(isPresented: Binding(
                get: { showsComments && !layout.sideBySide && !layout.resident },
                set: { if !layout.sideBySide && !layout.resident { showComments = $0 } }
            ), kind: .comments) {
                HGCommentPanel(series: session.series, episode: session.episode, total: session.episodeStat?.comments,
                               onClose: { showComments = false })
            }
        }
        .modifier(DYHingeStateRoot())
        .ignoresSafeArea()
        .statusBarHidden(clean)
        .persistentSystemOverlays(clean ? .hidden : .automatic)
        .overlay(alignment: .top) { toastView }
        .sheet(isPresented: $showMore) { moreSheet.presentationDetents([.height(consoleShown ? 400 : 300)]).presentationDragIndicator(.visible) }
        .sheet(isPresented: $showEpisodes) {
            HGEpisodeSheet(session: session) { showEpisodes = false }
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .onAppear { session.start() }
        .onDisappear { session.stop(); setOrientation(landscape: false) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, !HGBackgroundPlayback.enabled, !session.pip.active, !session.pip.starting { session.pauseForBackground() }
        }
    }

    private var pager: some View {
        GeometryReader { geo in
          ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(session.episodes.enumerated()), id: \.element.id) { i, ep in
                        pageView(i, ep, size: geo.size)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .id(i)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)
            .scrollIndicators(.hidden)
            .scrollDisabled(seeking)
            .ignoresSafeArea()
            .background(Color.black)
            .offset(x: edgeOffset)
            .onChange(of: page) { _, p in if let p, p != session.index { session.go(to: p) } }
            .onChange(of: session.index) { _, i in if page != i { withAnimation(.easeInOut(duration: 0.3)) { page = i } } }
            // scrollPosition 的初值对 LazyVStack 不生效：首帧后显式滚到起始集
            .onAppear { proxy.scrollTo(session.index, anchor: .top); page = session.index }
          }
        }
    }

    // MARK: 一页

    @ViewBuilder
    private func pageView(_ i: Int, _ ep: HGEpisode, size: CGSize) -> some View {
        ZStack {
            Color.black
            if i == session.index {
                DYAmbientBackdrop(player: session.player, active: true, dim: 0.6, fillWidth: fillWidth)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                HGVideoLayer(player: session.player, fillWidth: fillWidth, pip: session.pip)
                    .scaleEffect(userScale * pinchScale)
                    .clipped()
                if danmakuOn && !clean && (!consoleShown || !danmakuInConsole) {
                    DYDanmakuLayer(items: session.danmaku, clock: session.clock, topInset: safeTop)
                        .accessibilityElement()
                        .accessibilityIdentifier("hg.player.danmaku")
                        .accessibilityValue("\(session.danmaku.count)")
                }
                PlayerGestureView(
                    onSingleTap: { session.togglePlay() },
                    onDoubleTap: { _, _ in doubleTapLike() },
                    onLongPress: { pressing in session.setBoost(pressing) },
                    onLongPressLock: { session.lockBoost(); flash("已锁定 2× 倍速") },
                    onLongPressUnlock: { session.unlockBoost(); flash("已取消锁定") },
                    onSeekBegan: { seekAnchor = session.position; seekPreview = session.position; seeking = true },
                    onSeekChanged: { dx, w in
                        seekPreview = max(0, min(session.duration, seekAnchor + dx / max(w, 1) * session.duration * 0.9))
                        session.requestPreview(seekPreview)
                    },
                    onSeekEnded: { if seeking { session.seek(to: seekPreview); seeking = false; session.endPreview() } },
                    onEdgeChanged: { edgeOffset = $0 },
                    onEdgeEnded: { dx, v, w in
                        if dx > w * 0.3 || v > 800 { dismiss() } else { withAnimation(.spring(duration: 0.25)) { edgeOffset = 0 } }
                    },
                    verticalFirst: true,
                    onPinchBegan: {},
                    onPinchChanged: { pinchScale = $0 },
                    onPinchEnded: { s in
                        userScale = max(1, min(3, userScale * s)); pinchScale = 1
                        if userScale < 1.05 { withAnimation(.spring(duration: 0.25)) { userScale = 1 } }
                    },
                    onPinchCancelled: { pinchScale = 1 })
                    .accessibilityElement()
                    .accessibilityIdentifier("hg.player.surface")
                    .accessibilityValue(session.isPlaying && session.position > 0.5 && page == i ? "playing-\(ep.number)" : "idle")
                    .accessibilityHint("pos=\(Int(session.position))")
                if heartBurst { Image(systemName: "heart.fill").font(.system(size: 96)).foregroundStyle(HGTheme.accent).transition(.scale.combined(with: .opacity)).allowsHitTesting(false) }
                if !session.isPlaying && session.status == nil && session.failed == nil && !seeking {
                    Image(systemName: "play.fill").font(.system(size: 54)).foregroundStyle(.white.opacity(0.75)).allowsHitTesting(false)
                }
                if session.boosting || session.lockedBoost { boostBadge }
                if seeking && !consoleShown { seekOverlay }
                statusOverlay
                if clean { exitCleanButton } else if consoleShown { consoleTitle(ep) } else { chrome(ep) }   // 横屏评论从右滑出时，视频缩到左边，菜单栏仍贴视频右侧
            } else {
                // 相邻页只显示封面占位，滑动时不黑屏
                HGCover(url: session.series.coverURL).blur(radius: 18).opacity(0.35).allowsHitTesting(false)
                Text("第 \(ep.number) 集").font(.headline).foregroundStyle(.white.opacity(0.7))
            }
        }
        .clipped()
    }

    // MARK: 叠加层

    private var safeTop: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.safeAreaInsets.top ?? 47
    }

    /// DouDuo 默认模式布局：左下信息、右侧玻璃按钮栏底部对齐，左右 12pt，底部给进度条留位；返回键是玻璃圆。
    private func chrome(_ ep: HGEpisode) -> some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.backward")
                            .font(.title2.weight(.medium))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                            .ddMediaGlassCircle()
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("hg.player.close")
                    Spacer()
                    if let notice = session.danmakuNotice, danmakuOn {
                        Text(notice).font(.caption2).foregroundStyle(DDMedia.onMediaSecondary).ddMediaLabelShadow()
                    }
                }
                .padding(.horizontal, DDMedia.chromeSidePadding).padding(.top, safeTop)
                Spacer()
            }
            // DouDuo 默认模式的数值：栏整体 offset(x: -9)（compact）、栏底 56、整行离底 max(安全区,18)+36；进度条在这 36 里
            HStack(alignment: .bottom, spacing: 12) {
                info(ep)
                Spacer(minLength: 0)
                rail
                    .offset(x: hSize == .compact ? -9 : 0)
                    .padding(.bottom, 56)
            }
            .padding(.horizontal, DDMedia.chromeSidePadding)
            .padding(.bottom, max(safeBottom, 18) + 36)
            progressBar.padding(.bottom, max(safeBottom, 18) + 4)
        }
        .foregroundStyle(.white)
    }

    /// 第 5 集以后：评论按钮旁边弹一个小气泡，2.5 秒自动收
    private func showCommentTip() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        commentTipTask?.cancel()
        withAnimation(.snappy) { commentTip = true }
        commentTipTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { commentTip = false }
        }
    }

    /// 评论按钮左侧的提示气泡（锚在菜单栏上，跟着栏走：视频上 / 操作台右栏都适用）
    private var commentTipBubble: some View {
        Text("第 \(HGCommentPolicy.publicEpisodes) 集以后的评论，目前不支持观看")
            .font(.caption.weight(.medium)).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .ddMediaGlassCapsule()
            .fixedSize()
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            .accessibilityIdentifier("hg.comments.lockedTip")
    }

    /// 桌面姿态：控制面板呼出时视频左上角显示剧名 + 第几集 · 时长，跟面板一起收
    @ViewBuilder private func consoleTitle(_ ep: HGEpisode) -> some View {
        if consoleControls {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.series.series_title).font(.headline).lineLimit(1)
                Text("第\(ep.number)集" + (session.duration > 0 ? " | \(Int((session.duration / 60).rounded(.up)))分钟" : ""))
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
            }
            .foregroundStyle(.white)
            .ddMediaLabelShadow()
            .padding(.leading, 16).padding(.top, max(safeTop, 12))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityIdentifier("hg.console.title")
        }
    }

    /// 桌面姿态操作台右侧竖栏：返回键在上，下面就是视频上那根 DouDuo 菜单栏
    private var consoleColumn: some View {
        VStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.backward").font(.title2.weight(.medium)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).contentShape(Circle()).ddMediaGlassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("hg.player.close")
            rail
        }
        .environment(\.horizontalSizeClass, .compact)
    }

    /// 评论占一侧时视频上只留返回键（DouDuo：评论打开 / 常驻时按钮栏直接隐藏）
    private var paneChrome: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.backward").font(.title2.weight(.medium)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).contentShape(Circle()).ddMediaGlassCircle()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("hg.player.close")
                Spacer()
            }
            .padding(.horizontal, DDMedia.chromeSidePadding).padding(.top, safeTop)
            Spacer()
            if !consoleShown { progressBar.padding(.bottom, 12) }
        }
    }

    private var safeBottom: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom ?? 34
    }

    /// 左下信息：剧名（加粗）+ 集数 / 播放量（次要色），DouDuo 信息区同款字号与阴影
    private func info(_ ep: HGEpisode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.series.series_title).font(.subheadline.weight(.semibold)).lineLimit(1)
            HStack(spacing: 8) {
                Text("第 \(ep.number) 集 · 共 \(session.episodes.count) 集")
                if let plays = session.stats?.plays { Text("\(DDMedia.count(plays))次播放") }
            }
            .font(.subheadline).foregroundStyle(DDMedia.onMediaSecondary)
            if let d = session.series.description, !d.isEmpty {
                Text(d).font(.subheadline).foregroundStyle(.white).lineLimit(2)
            }
        }
        .ddMediaLabelShadow()
    }

    /// DouDuo 同款右侧栏：玻璃胶囊（点赞 / 评论 / 收藏 / 铺满）+ 玻璃圆「更多」
    private var rail: some View {
        let fav = library.isFavorite(session.series.id)
        let liked = library.isLiked(session.episode.vid)
        let stat = session.episodeStat
        var items: [DDActionRail.Item] = []
        if session.series.source == .hongguo {
            items.append(.init(id: "hg.rail.likes", icon: liked ? "heart.fill" : "heart",
                               text: stat?.likes.map { DDMedia.count($0 + (liked ? 1 : 0)) } ?? "",
                               tint: liked ? DDMedia.danger : .white) { toggleLike() })
            let locked = session.episode.number > HGCommentPolicy.publicEpisodes
            items.append(.init(id: "hg.rail.comments", icon: "ellipsis.bubble",
                               text: stat?.comments.map(DDMedia.count) ?? "",
                               tint: locked ? .white.opacity(0.45) : .white) {
                if locked { showCommentTip() } else { showComments = true }
            })
        }
        items.append(.init(id: "hg.rail.favorite", icon: fav ? "star.fill" : "star",
                           text: session.stats?.follows.map { DDMedia.count($0 + (fav ? 1 : 0)) } ?? "",
                           tint: fav ? DDMedia.warning : .white) { library.toggleFavorite(session.series) })
        items.append(.init(id: "hg.rail.fill", icon: "fit", text: "", fitInward: !fillWidth) {
            fillWidth.toggle(); userScale = 1
            flash(fillWidth ? "铺满：开" : "完整画面")
        })
        return DDActionRail(items: items) { showMore = true }
            .overlay(alignment: .topLeading) {
                if commentTip {
                    // 宽 0 + 右对齐：气泡从栏左边缘往左长，不会出屏
                    commentTipBubble
                        .frame(width: 0, height: 34, alignment: .trailing)
                        .offset(x: -10, y: 92 - 17)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("hg.rail")
            .accessibilityValue(fav ? "已收藏" : "未收藏")
    }

    private var moreSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(session.title).font(.headline).lineLimit(1)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 16) {
                if consoleShown { socialItems }
                moreItem("list.number", "选集", id: "hg.more.episodes") { showMore = false; showEpisodes = true }
                moreItem(danmakuOn ? "captions.bubble.fill" : "captions.bubble", danmakuOn ? "关弹幕" : "开弹幕", on: danmakuOn, id: "hg.more.danmaku") { danmakuOn.toggle() }
                moreItem("arrow.up.left.and.arrow.down.right.rectangle", "全屏", id: "hg.more.clean") {
                    showMore = false; withAnimation(.easeOut(duration: 0.2)) { clean = true }
                }
                if session.pip.supported {
                    moreItem("pip.enter", "画中画", id: "hg.more.pip") { showMore = false; session.pip.start() }
                }
                if session.videoAspect > 1.05 {
                    moreItem("rotate.right", landscape ? "竖屏" : "横屏", id: "hg.more.rotate") { showMore = false; setOrientation(landscape: !landscape) }
                }
            }
            Text("倍速").font(.subheadline).foregroundStyle(HGTheme.textSecondary)
            HStack(spacing: 8) {
                ForEach(Self.rates, id: \.self) { r in
                    let on = r == session.rate
                    Button { session.setRate(r) } label: {
                        Text(String(format: "%g×", r)).font(.subheadline.weight(on ? .semibold : .regular).monospacedDigit())
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(on ? HGTheme.accent : HGTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: HGTheme.radiusSmall, style: .continuous))
                            .foregroundStyle(on ? Color.white : HGTheme.textPrimary)
                    }
                    .accessibilityIdentifier("hg.more.rate.\(r)")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HGTheme.surface)
    }

    /// 桌面姿态没有右侧栏：点赞 / 评论 / 收藏 / 画面收进「更多」
    @ViewBuilder private var socialItems: some View {
        let fav = library.isFavorite(session.series.id)
        let liked = library.isLiked(session.episode.vid)
        let stat = session.episodeStat
        if session.series.source == .hongguo {
            moreItem(liked ? "heart.fill" : "heart", stat?.likes.map { DDMedia.count($0 + (liked ? 1 : 0)) } ?? "点赞",
                     on: liked, id: "hg.more.like") { toggleLike() }
            let locked = session.episode.number > HGCommentPolicy.publicEpisodes
            moreItem("ellipsis.bubble", locked ? "评论" : (stat?.comments.map { DDMedia.count($0) + "评论" } ?? "评论"),
                     id: "hg.more.comments") {
                if locked { flash("第 \(HGCommentPolicy.publicEpisodes) 集以后的评论，目前不支持观看") }
                else { showMore = false; showComments = true }
            }
        }
        moreItem(fav ? "star.fill" : "star", fav ? "已收藏" : "收藏", on: fav, id: "hg.more.favorite") { library.toggleFavorite(session.series) }
        moreItem("aspectratio", fillWidth ? "完整画面" : "铺满", id: "hg.more.fill") {
            fillWidth.toggle(); userScale = 1; flash(fillWidth ? "铺满：开" : "完整画面")
        }
    }

    private func moreItem(_ icon: String, _ title: String, on: Bool = false, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3).frame(width: 52, height: 52)
                    .background(on ? HGTheme.accent.opacity(0.2) : HGTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: HGTheme.radius, style: .continuous))
                    .foregroundStyle(on ? HGTheme.accent : HGTheme.textPrimary)
                Text(title).font(.caption).foregroundStyle(HGTheme.textSecondary)
            }
        }
        .accessibilityIdentifier(id)
    }


    private var progressBar: some View {
        GeometryReader { g in
            let pos = seeking ? seekPreview : session.position
            let frac = session.duration > 0 ? min(1, max(0, pos / session.duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: seeking ? 6 : 3)
                Capsule().fill(.white).frame(width: g.size.width * frac, height: seeking ? 6 : 3)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !seeking { seeking = true }
                    seekPreview = max(0, min(session.duration, v.location.x / max(g.size.width, 1) * session.duration))
                    session.requestPreview(seekPreview)
                }
                .onEnded { _ in session.seek(to: seekPreview); seeking = false; session.endPreview() })
        }
        .frame(height: 24)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("hg.player.progress")
    }

    private var seekOverlay: some View {
        VStack(spacing: 8) {
            let vertical = session.videoAspect < 1
            Group {
                if let img = session.seekPreviewImage {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.black.opacity(0.4).overlay(ProgressView().tint(.white))
                }
            }
            .frame(width: vertical ? 124 : 196, height: vertical ? 220 : 110)
            .clipShape(RoundedRectangle(cornerRadius: HGTheme.radius, style: .continuous))
            .accessibilityIdentifier("hg.player.seekPreview")
            HStack(spacing: 8) {
                Text(fmt(seekPreview)).font(.subheadline.weight(.bold).monospacedDigit())
                Text("/ " + fmt(session.duration)).font(.caption.monospacedDigit()).opacity(0.6)
                let delta = seekPreview - session.position
                Text((delta >= 0 ? "+" : "") + String(format: "%.0fs", delta)).font(.caption.weight(.semibold))
                    .foregroundStyle(delta >= 0 ? HGTheme.textPrimary : HGTheme.textSecondary)
            }
        }
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: HGTheme.radius, style: .continuous))
        .foregroundStyle(.white)
        .allowsHitTesting(false)
    }

    private var boostBadge: some View {
        Text(session.lockedBoost ? "2× 已锁定 · 上滑取消" : "2× 快进中 · 下滑锁定")
            .font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 6)
            .background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white)
            .frame(maxHeight: .infinity, alignment: .top).padding(.top, safeTop + 48)
            .allowsHitTesting(false)
    }

    @ViewBuilder private var statusOverlay: some View {
        if let status = session.status {
            VStack(spacing: 10) { ProgressView().tint(.white); Text(status).font(.footnote).foregroundStyle(.white.opacity(0.8)) }
                .allowsHitTesting(false)
        }
        if let failed = session.failed {
            VStack(spacing: 12) {
                Text(failed).font(.footnote).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                HStack {
                    Button("重试") { session.retry() }.buttonStyle(.borderedProminent).tint(HGTheme.accent)
                    if session.hasNext { Button("下一集") { session.next() }.buttonStyle(.bordered).tint(.white) }
                }
            }
            .padding(32)
        }
    }

    private var exitCleanButton: some View {
        Button { withAnimation(.easeOut(duration: 0.2)) { clean = false } } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left").font(.footnote.weight(.semibold))
                .padding(10).background(.black.opacity(0.4), in: Circle()).foregroundStyle(.white.opacity(0.85))
        }
        .accessibilityIdentifier("hg.player.exitClean")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 16).padding(.bottom, 36)
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Text(toast).font(.footnote.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 8)
                .background(.black.opacity(0.65), in: Capsule()).foregroundStyle(.white)
                .padding(.top, safeTop + 50).transition(.opacity)
        }
    }

    // MARK: 动作

    /// 点赞只记在本机（红果账号登录也是只读，没法替你在官方点赞）；数字显示官方点赞数 + 自己这一下。
    private func toggleLike() { library.toggleLike(session.episode.vid) }

    private func doubleTapLike() {
        if !library.isLiked(session.episode.vid) { library.toggleLike(session.episode.vid) }
        withAnimation(.spring(duration: 0.25)) { heartBurst = true }
        Task { try? await Task.sleep(for: .milliseconds(650)); withAnimation(.easeOut(duration: 0.2)) { heartBurst = false } }
    }

    private func flash(_ s: String) {
        withAnimation { toast = s }
        Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation { if toast == s { toast = nil } } }
    }

    private func setOrientation(landscape on: Bool) {
        landscape = on
        HGOrientation.allowLandscape = on
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: on ? .landscapeRight : .portrait))
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }


    private func rateText(_ r: Float) -> String { String(format: "%g×", r) }
    private func fmt(_ t: Double) -> String {
        guard t.isFinite else { return "0:00" }
        let s = Int(t); return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// AVPlayerLayer + DouDuo 同款铺满规则（只在视频与屏幕同向时铺满）+ 画中画挂载。
struct HGVideoLayer: UIViewRepresentable {
    let player: AVPlayer
    let fillWidth: Bool
    let pip: DYPictureInPicture
    func makeUIView(context: Context) -> HGPlayerLayerView {
        let v = HGPlayerLayerView()
        v.playerLayer.player = player
        v.fillWidth = fillWidth
        v.pip = pip
        pip.prepareManual(layer: v.playerLayer)   // 不建控制器：退出 App 不会自动画中画
        return v
    }
    func updateUIView(_ v: HGPlayerLayerView, context: Context) {
        if v.playerLayer.player !== player, UIApplication.shared.applicationState != .background { v.playerLayer.player = player }
        v.fillWidth = fillWidth
        v.applyGravity()
    }
}

final class HGPlayerLayerView: UIView {
    var fillWidth = true
    weak var pip: DYPictureInPicture?
    private var sizeObs: NSKeyValueObservation?
    private var detached: AVPlayer?
    private var bgObs: [NSObjectProtocol] = []
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        sizeObs = playerLayer.observe(\.videoRect, options: [.new]) { [weak self] _, _ in DispatchQueue.main.async { self?.applyGravity() } }
        let nc = NotificationCenter.default
        bgObs = [
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard HGBackgroundPlayback.enabled, let self, self.pip?.active != true, let p = self.playerLayer.player else { return }
                    p.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
                    self.detached = p; self.playerLayer.player = nil
                }
            },
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let p = self.detached else { return }
                    self.playerLayer.player = p; self.detached = nil
                }
            },
        ]
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { bgObs.forEach(NotificationCenter.default.removeObserver) }
    override func layoutSubviews() { super.layoutSubviews(); applyGravity() }
    func applyGravity() {
        guard let size = playerLayer.player?.currentItem?.presentationSize, size.width > 1, size.height > 1,
              bounds.width > 1, bounds.height > 1 else { return }
        let g: AVLayerVideoGravity = DYVideoFit.presentation(fillWidth: fillWidth, videoAspect: size.width / size.height,
                                                             screenAspect: bounds.width / bounds.height) == .aspectFill ? .resizeAspectFill : .resizeAspect
        if playerLayer.videoGravity != g { playerLayer.videoGravity = g }
    }
}

/// 横屏只在播放页按「横屏」后放开。
enum HGOrientation {
    nonisolated(unsafe) static var allowLandscape = false
}

enum HGBackgroundPlayback {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "hg.bgPlay.v2") }
}
