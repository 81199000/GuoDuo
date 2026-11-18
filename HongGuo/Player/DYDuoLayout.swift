import SwiftUI
import UIKit

// 原样搬自 DouDuo DouyinDuoLayout.swift：Duo 三姿态几何（外屏 / 半折叠书本·桌面 / 内屏平放）、
// 贴边底部评论面板、窗格几何、铰链状态根。只把日志与主题常量换成 GuoDuo 本地实现。

enum DDTheme { static let sheetCornerRadius: CGFloat = 32; static let shareSheetHeight: CGFloat = 300 }

extension EnvironmentValues {
    @Entry var dyHingeClosed: Bool = false
    @Entry var dyStacksLandscapeComments = false
    @Entry var dyDuoLandscapeWindow = false
}

enum DYDuoMetrics {
    /// 合屏竖屏视频左贴边试验；展开内屏与横屏内容不移动。
    static func closedPortraitVideoOffset(viewport: CGSize, videoAspect: Double,
                                          fills: Bool, isDuo: Bool, isClosed: Bool) -> CGFloat {
        guard isDuo, isClosed, viewport.height > viewport.width,
              videoAspect > 0, videoAspect < 1, !fills else { return 0 }
        let fittedWidth = min(viewport.width, viewport.height * videoAspect)
        return -(viewport.width - fittedWidth) / 2
    }

    static func hingeSplit(_ geo: GeometryProxy) -> (video: CGRect, panel: CGRect, book: Bool)? {
        guard DYDuoMetrics.foldIsActive(geo) else { return nil }
        guard #available(iOS 27.1, *) else { return nil }
        let divisions = geo.reservedRegions(kind: .division).map {
            DYLiveDivision(frame: $0.frame, isActive: $0.isActive)
        }
        guard let p = DYLiveAdaptiveLayoutEngine.hingePanes(
            bounds: CGRect(origin: .zero, size: geo.size), divisions: divisions) else { return nil }
        return (p.first, p.second, p.book)
    }

    static func videoCommentPanes(_ geo: GeometryProxy) -> (video: CGRect, panel: CGRect, book: Bool)? {
        guard let hinge = hingeSplit(geo) else { return nil }
        let panes = DYLiveAdaptiveLayoutEngine.videoCommentPanes(
            video: hinge.video, panel: hinge.panel, book: hinge.book)
        return (panes.video, panes.panel, hinge.book)
    }

    /// 窗格右侧被系统遮挡区（状态栏时间/信号）占掉的宽度，最多让 120pt。
    static func trailingOcclusionInset(_ geo: GeometryProxy, pane: CGRect) -> CGFloat {
        guard #available(iOS 27.1, *) else { return 0 }
        var inset: CGFloat = 0
        for region in geo.reservedRegions(kind: .occlusion) where region.isActive {
            let f = region.frame
            guard f.width > 1, f.height > 1, f.intersects(pane), f.midX > pane.midX else { continue }
            inset = max(inset, pane.maxX - f.minX)
        }
        return min(max(0, inset), 120)
    }


    static func actionRailHorizontalOffset(isRegular: Bool, trailingInset: CGFloat,
                                          columnWidth: CGFloat, outerPadding: CGFloat,
                                          opticalLeadingInset: CGFloat = 0) -> CGFloat {
        guard isRegular, trailingInset > 0 else { return 0 }
        return outerPadding + columnWidth / 2 - trailingInset / 2 - opticalLeadingInset
    }


    /// Full-bleed media and sheets deliberately extend past SwiftUI's safe
    /// area. Their controls still clear the physical home-indicator region.
    static var windowBottomInset: CGFloat {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)?.safeAreaInsets.bottom ?? 0
    }

    static func bottomSafeAreaExtension(in geo: GeometryProxy) -> CGFloat {
        let inset = geo.safeAreaInsets.bottom
        let physicalBottom = windowBottomInset
        return inset <= physicalBottom + 1 ? min(inset, physicalBottom) : 0
    }

    static func mediaBottomPadding(_ containerInset: CGFloat) -> CGFloat {
        // The progress line sits 8 pt above its view's bottom. Lift the info
        // and progress together, retaining their existing music/line spacing.
        max(max(containerInset - 16, 8), windowBottomInset - 8)
    }

    static func bottomSafeAreaOverlap(in proxy: GeometryProxy) -> CGFloat {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else { return 0 }
        let inset = window.safeAreaInsets.bottom
        return min(inset, max(0, proxy.frame(in: .global).maxY - (window.bounds.maxY - inset)))
    }

    /// iOS 17–27.0 的宽屏回退，和改版前同一条线。
    static let legacyWideMin: CGFloat = 700

    /// 是不是 iPhone Duo 真机/模拟器（iPhone19,4）。
    /// 外屏顶栏的 -80 贴顶只对 Duo 成立：Duo 外屏窗口内容区比物理屏顶端低约 80pt；
    /// 普通 iPhone 窗口从物理顶端开始，再往上推 80 就把顶栏推出屏幕（issue #16：点不到）。
    static let isDuoHardware: Bool = {
        #if targetEnvironment(simulator)
        let id = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        #else
        var s = utsname()
        uname(&s)
        let id = withUnsafeBytes(of: &s.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        #endif
        return id == "iPhone19,4"
    }()

    /// 窗口顶部安全区（状态栏 / 灵动岛高度）。播放页整层忽略了安全区，GeometryProxy 量到的 top 为 0，只能读窗口。
    @MainActor static var windowSafeTop: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets.top ?? 0
    }

    /// A system split or floating window can still receive the display's
    /// active hinge region. Only use it to lay out an app occupying the display.
    static var canUseFoldLayout: Bool {
        guard #available(iOS 27.1, *),
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first(where: { $0.keyWindow != nil }) else { return false }
        let space = scene.effectiveGeometry.coordinateSpace
        let display = scene.screen.coordinateSpace
        return DYLiveAdaptiveLayoutEngine.occupiesDisplay(
            scene: display.convert(space.bounds, from: space), display: display.bounds)
    }

    /// 折痕是否处于激活状态（半折叠）。iOS 27.1 以下恒为 false。
    static func foldIsActive(_ proxy: GeometryProxy) -> Bool {
        #if DEBUG
        // 演示/截图用：模拟器没有物理折痕，用环境变量强制进入半折叠布局
        if ProcessInfo.processInfo.environment["DOUDUO_FOLD"] == "1" { return true }
        #endif
        if #available(iOS 27.1, *) {
            return canUseFoldLayout && proxy.reservedRegions(kind: .division).contains { $0.isActive }
        }
        return false
    }

    /// 顶栏左移量：合屏时前摄挖孔压在右上，整排往左让出它的宽度，避免「推荐/直播」被啃掉。
    /// 只认靠上且靠右的 occlusion；下方/居中的（如外屏下缘）不动顶栏。
    static func topBarLeftShift(_ proxy: GeometryProxy) -> CGFloat {
        guard #available(iOS 27.1, *) else { return 0 }
        let w = proxy.size.width
        var shift: CGFloat = 0
        for r in proxy.reservedRegions(kind: .occlusion) where r.isActive {
            let f = r.frame
            guard f.height > 1, f.width > 1 else { continue }
            // 顶部 140pt 内、且位于右半边 → 认定为前摄
            if f.minY < 140, f.minX > w * 0.5 {
                shift = max(shift, f.width)
            }
        }
        return min(shift, 56)
    }
}

enum DYBottomSheetKind {
    case comments, share, options
}

struct DYSheetDragActions {
    let update: (CGFloat) -> Void
    let finish: (Bool) -> Void
}

extension EnvironmentValues {
    @Entry var dySheetDrag: DYSheetDragActions? = nil
}

/// Shared dismissal arbitration. A vertical scroll that began below the top
/// never becomes a dismissal; a horizontal gesture can close from any row.
struct DYPanelDismissGesture: ViewModifier {
    @Environment(\.dySheetDrag) private var sheetDrag
    var isAtTop = true
    var allowsSwipeRight = false
    var onClose: (() -> Void)?
    @State private var direction: Axis?
    @State private var startedAtTop = false

    func body(content: Content) -> some View {
        content.simultaneousGesture(DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                guard onClose != nil else { return }
                if direction == nil {
                    startedAtTop = isAtTop
                    direction = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                }
                if direction == .vertical, startedAtTop,
                   value.translation.height > abs(value.translation.width) {
                    sheetDrag?.update(value.translation.height)
                }
            }
            .onEnded { value in
                defer { direction = nil }
                guard let onClose else { return }
                let dx = value.translation.width, dy = value.translation.height
                let right = allowsSwipeRight && direction == .horizontal && dx > abs(dy) * 1.2 &&
                    (dx > 70 || (dx > 25 && value.predictedEndTranslation.width > 160))
                let down = direction == .vertical && startedAtTop && dy > abs(dx) * 1.2 &&
                    (dy > 70 || (dy > 20 && value.predictedEndTranslation.height > 150))
                if right || down { onClose() }
                else { sheetDrag?.finish(false) }
            })
    }
}


extension View {
    func dyBottomSheet<Panel: View>(isPresented: Binding<Bool>, kind: DYBottomSheetKind,
                                   hidesStatusBar: Bool = false,
                                   @ViewBuilder content: @escaping () -> Panel) -> some View {
        modifier(DYBottomSheetPresenter(isPresented: isPresented, kind: kind,
                                        hidesStatusBar: hidesStatusBar, panel: content))
    }

    @ViewBuilder
    func dyCommentStatusVisibility(hidden: Bool) -> some View {
        if #available(iOS 27.0, *) {
            toolbarVisibility(hidden ? .hidden : .automatic, for: .statusBar)
        } else {
            self
        }
    }
}


/// Compact presentations reach the display edges. A full-screen presentation
/// supplies modal focus/dismissal; only its bottom panel draws Liquid Glass.
private struct DYBottomSheetPresenter<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    let kind: DYBottomSheetKind
    let hidesStatusBar: Bool
    @ViewBuilder var panel: () -> Panel

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $isPresented) {
            DYEdgeBottomPanel(kind: kind, panel: panel)
                .presentationBackground(.clear)
                .dyCommentStatusVisibility(hidden: hidesStatusBar)
        }
    }
}

struct DYBottomPanelContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct DYEdgeBottomPanel<Panel: View>: View {
    @Environment(\.dismiss) private var dismiss
    @State private var contentHeight: CGFloat?
    let kind: DYBottomSheetKind
    @ViewBuilder var panel: () -> Panel

    var body: some View {
        GeometryReader { geo in
            let panelHeight: CGFloat = switch kind {
            case .comments: min(geo.size.height, (geo.size.height + geo.safeAreaInsets.bottom) * 0.62)
            case .options: min(geo.size.height * 0.78, contentHeight ?? 320)
            case .share: min(geo.size.height, contentHeight ?? DDTheme.shareSheetHeight)
            }
            let trailingHalf = kind != .comments && geo.size.width >= DYDuoMetrics.legacyWideMin
            let panelWidth = trailingHalf ? geo.size.width / 2 : geo.size.width
            ZStack(alignment: .bottomTrailing) {
                Color.clear.ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                    .accessibilityHidden(true)
                DYEdgePanelSurface(width: panelWidth, height: panelHeight, onClose: { dismiss() }) {
                    panel()
                        .onPreferenceChange(DYBottomPanelContentHeightKey.self) { height in
                            if height > 0 { contentHeight = height }
                        }
                }
            }
        }
        // Respect the keyboard, while the glass reaches the physical edges.
        .ignoresSafeArea(.container)
        .dyDisableVerticalToolbar()
    }
}

private struct DYEdgePanelSurface<Panel: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0
    let width: CGFloat
    let height: CGFloat
    let onClose: () -> Void
    @ViewBuilder var panel: () -> Panel

    var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: DDTheme.sheetCornerRadius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: DDTheme.sheetCornerRadius)
        VStack(spacing: 0) {
            panel()
                .environment(\.dySheetDrag, DYSheetDragActions(update: { offset in
                    dragOffset = min(height, max(0, offset))
                }, finish: { shouldClose in
                    if shouldClose { onClose() }
                    else { withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { dragOffset = 0 } }
                }))
        }
        .frame(width: width, height: height, alignment: .top)
        .dyPanelGlass(in: shape)
        .clipShape(shape)
        .offset(y: dragOffset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("douyin.sheet.edgeSurface")
    }
}


/// Shared geometry for recommendation, following, profile/search works and
/// comment links from messages. Changing pane size never replaces the pager.
struct DYCommentPaneMetrics {
    let resident: Bool
    let sideBySide: Bool
    let showsPane: Bool
    let videoSize: CGSize
    let paneSize: CGSize
    let paneOrigin: CGPoint
    let trailingInset: CGFloat

    init(_ geo: GeometryProxy, isPresented: Bool, allowsResident: Bool = true,
         paneFraction: CGFloat? = nil, keepsSideBySide: Bool = false) {
        let w = geo.size.width, h = geo.size.height
        resident = allowsResident && DYDuoMetrics.foldIsActive(geo)
        if resident, let hinge = DYDuoMetrics.videoCommentPanes(geo) {
            sideBySide = hinge.book
            showsPane = true
            videoSize = hinge.video.size
            // The hinge panes are measured inside the navigation safe area.
            // Extend the comment surface to the physical edges, just like the
            // video, instead of leaving a black border around a smaller card.
            let bottomExtension = DYDuoMetrics.bottomSafeAreaExtension(in: geo)
            if hinge.book {
                let split = hinge.panel.minX
                paneOrigin = CGPoint(x: split, y: -geo.safeAreaInsets.top)
                paneSize = CGSize(width: w + geo.safeAreaInsets.trailing - split,
                                  height: h + geo.safeAreaInsets.top + bottomExtension)
                trailingInset = max(geo.safeAreaInsets.trailing,
                    DYDuoMetrics.trailingOcclusionInset(geo, pane: hinge.panel))
            } else {
                let split = hinge.panel.minY
                paneOrigin = CGPoint(x: -geo.safeAreaInsets.leading, y: split)
                paneSize = CGSize(width: w + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing,
                                  height: h + bottomExtension - split)
                trailingInset = geo.safeAreaInsets.trailing
            }
            return
        }
        let tableFold = resident && w <= h
        sideBySide = keepsSideBySide || w >= DYDuoMetrics.legacyWideMin || (resident && w > h)
        showsPane = resident || (sideBySide && isPresented)
        // Preserve v1.3.11's comment width. Author panes still split in half.
        let paneW: CGFloat
        if showsPane && sideBySide {
            if let paneFraction {
                paneW = max(0, (w + geo.safeAreaInsets.trailing) * paneFraction - geo.safeAreaInsets.trailing)
            } else {
                paneW = resident ? w * 0.45 : min(380, w * 0.42)
            }
        } else {
            paneW = 0
        }
        let paneH = tableFold ? h * 0.45 : 0
        videoSize = CGSize(width: w - paneW, height: h - paneH)
        trailingInset = geo.safeAreaInsets.trailing
        // Keyboard insets must not be added back to the panel height. Keep the
        // input above the keyboard while the background reaches the screen edge.
        let bottom = DYDuoMetrics.bottomSafeAreaExtension(in: geo)
        paneSize = CGSize(width: sideBySide ? paneW + trailingInset : w,
                          height: tableFold ? paneH : h + geo.safeAreaInsets.top + bottom)
        paneOrigin = CGPoint(x: sideBySide ? videoSize.width : 0,
                             y: tableFold ? videoSize.height : -geo.safeAreaInsets.top)
    }
}


extension View {
    @ViewBuilder func dyDisableVerticalToolbar() -> some View {
        if #available(iOS 27.1, *) { self.toolbarVerticalBehavior(.disabled) }
        else { self }
    }
    @ViewBuilder func dyPanelGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) { self.glassEffect(.regular, in: shape) }
        else { self.background(.ultraThinMaterial, in: shape) }
    }
}


/// 挂在 App 根视图：整个 App 只读一次铰链状态，放进环境给所有页面用。
struct DYHingeStateRoot: ViewModifier {
    @State private var closed = false
    @State private var fullyOpen = false
    @State private var compactWindow = false

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content
                .environment(\.dyHingeClosed, closed)
                .environment(\.dyStacksLandscapeComments,
                             DYDuoMetrics.isDuoHardware && (closed || (fullyOpen && compactWindow)))
                .environment(\.dyDuoLandscapeWindow,
                             DYDuoMetrics.isDuoHardware && fullyOpen && !compactWindow)
                .onGeometryChange(for: Bool.self) { geo in
                    // Use the app window, including half-width Split View panes.
                    let insets = geo.safeAreaInsets
                    let width = geo.size.width + insets.leading + insets.trailing
                    let height = geo.size.height + insets.top + insets.bottom
                    return width < DYDuoMetrics.legacyWideMin || width < height
                } action: { compactWindow = $0 }
                .onHingeChange { _, context in
                    closed = context.hinge?.status == .closed
                    fullyOpen = context.hinge?.status == .fullyOpen
                    HGLog.log("DDHINGE root status=\(String(describing: context.hinge?.status))")
                }
        } else {
            content
        }
    }
}
