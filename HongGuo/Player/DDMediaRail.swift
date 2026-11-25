import SwiftUI

// 原样搬自 DouDuo（Theme.swift / DouyinFeedView.swift 默认模式右侧栏）：
// 一根竖向液态玻璃胶囊（赞 / 评论 / 收藏 / 铺满），下面单独一颗玻璃圆「更多」。尺寸、间距、字号、阴影都用 DouDuo 的值。

enum DDMedia {
    static let onMediaSecondary = Color.white.opacity(0.72)
    static let danger = Color(red: 1.0, green: 0.17, blue: 0.33)   // 抖音红（DouDuo theme.status.danger）
    static let warning = Color.orange                              // 收藏黄（DouDuo theme.status.warning）
    static let actionGlyphStroke: CGFloat = 1.8
    static let actionGlyphSize: CGFloat = 27
    static let moreGlyphSize: CGFloat = 23
    static let actionItemSpacing: CGFloat = 9
    static let actionGroupSpacing: CGFloat = 12
    static let railWidthCompact: CGFloat = 50
    static let railWidthRegular: CGFloat = 54
    static let actionColumnWidth: CGFloat = 54
    static let chromeSidePadding: CGFloat = 12

    /// DouDuo DYFormat.count
    static func count(_ n: Int) -> String {
        if n >= 100_000_000 { return String(format: "%.1f亿", Double(n) / 1e8) }
        if n >= 10_000 { return String(format: "%.1fw", Double(n) / 1e4) }
        return "\(n)"
    }
}

extension View {
    @ViewBuilder
    func ddGlassCircle(_ tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                self.foregroundStyle(.primary).glassEffect(.regular.tint(tint.opacity(0.22)).interactive(), in: .circle)
            } else {
                self.foregroundStyle(.primary).glassEffect(.regular.interactive(), in: .circle)
            }
        } else {
            self.foregroundStyle(.primary)
                .background(tint.map { $0.opacity(0.22) } ?? .clear, in: Circle())
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    /// 竖向液态玻璃胶囊（小红书式右侧栏底板）
    @ViewBuilder
    func ddGlassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.foregroundStyle(.primary).glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self.foregroundStyle(.primary).background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// 视频上的玻璃控件始终按暗色渲染；系统玻璃 + 光圈（样式见 HGEdgeHighlight.swift，设置里可切）
    func ddMediaGlassCircle(_ tint: Color? = nil) -> some View {
        modifier(HGMediaGlass(shape: Circle(), tint: tint))
    }
    func ddMediaGlassCapsule() -> some View {
        modifier(HGMediaGlass(shape: Capsule()))
    }

    /// DouDuo themeShadow(.mediaLabel)
    func ddMediaLabelShadow() -> some View { shadow(color: .black.opacity(0.45), radius: 3, y: 1) }
}

/// DouDuo 的「铺满 / 完整」角标图形：图标按「点了会怎样」显示
struct DYFitCornerGlyph: Shape {
    var inward: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let a = rect.width * 0.17, b = rect.width * 0.83
        let leg = rect.width * 0.29
        if inward {
            p.move(to: CGPoint(x: a, y: a + leg)); p.addLine(to: CGPoint(x: a + leg, y: a + leg)); p.addLine(to: CGPoint(x: a + leg, y: a))
            p.move(to: CGPoint(x: b, y: b - leg)); p.addLine(to: CGPoint(x: b - leg, y: b - leg)); p.addLine(to: CGPoint(x: b - leg, y: b))
        } else {
            p.move(to: CGPoint(x: a, y: a + leg)); p.addLine(to: CGPoint(x: a, y: a)); p.addLine(to: CGPoint(x: a + leg, y: a))
            p.move(to: CGPoint(x: b - leg, y: b)); p.addLine(to: CGPoint(x: b, y: b)); p.addLine(to: CGPoint(x: b, y: b - leg))
        }
        return p
    }
}

/// 右侧栏：玻璃胶囊 + 玻璃圆「更多」。
struct DDActionRail: View {
    struct Item: Identifiable {
        let id: String
        let icon: String          // SF Symbol；"fit" 走角标图形
        let text: String
        var tint: Color = .white
        var fitInward = false
        /// 数字位（点赞 / 评论 / 收藏）：数字还没读到时也占住文字那一行，栏不缩短再拉长
        var reservesText = false
        let action: () -> Void
    }
    let items: [Item]
    let onMore: () -> Void
    @Environment(\.horizontalSizeClass) private var hSize
    private var railWidth: CGFloat { hSize == .compact ? DDMedia.railWidthCompact : DDMedia.railWidthRegular }

    var body: some View {
        VStack(spacing: DDMedia.actionGroupSpacing) {
            VStack(spacing: DDMedia.actionItemSpacing) {
                ForEach(items) { railItem($0) }
            }
            .padding(.vertical, 8)
            .frame(width: railWidth)
            .ddMediaGlassCapsule()
            .frame(width: DDMedia.actionColumnWidth)
            Button(action: onMore) {
                Image(systemName: "ellipsis")
                    .font(.system(size: DDMedia.moreGlyphSize, weight: .regular, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .contentShape(Circle())
                    .ddMediaGlassCircle()
                    .frame(width: 54)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("更多")
            .accessibilityIdentifier("hg.rail.more")
        }
        .ddMediaLabelShadow()
    }

    private func railItem(_ item: Item) -> some View {
        Button(action: item.action) {
            VStack(spacing: 2) {
                Group {
                    if item.icon == "fit" {
                        DYFitCornerGlyph(inward: item.fitInward)
                            .stroke(item.tint, style: StrokeStyle(lineWidth: DDMedia.actionGlyphStroke, lineCap: .round, lineJoin: .round))
                            .frame(width: DDMedia.actionGlyphSize, height: DDMedia.actionGlyphSize)
                    } else {
                        Image(systemName: item.icon)
                            .font(.system(size: DDMedia.actionGlyphSize, weight: .regular, design: .rounded))
                            .foregroundStyle(item.tint)
                    }
                }
                .frame(width: 34, height: 34)
                if !item.text.isEmpty || item.reservesText {
                    Text(item.text.isEmpty ? " " : item.text).font(.caption2.weight(.medium)).monospacedDigit()
                        .foregroundStyle(DDMedia.onMediaSecondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .frame(width: railWidth, height: item.text.isEmpty && !item.reservesText ? 36 : 50, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(item.id)
    }
}


/// DouDuo DDPressHold 原样：按住 ≥ threshold 秒算长按，抬手前一直保持；不满 threshold 抬手算单击。
struct DDPressHold: ViewModifier {
    let threshold: Double
    var onHoldChanged: (Bool) -> Void = { _ in }
    let onPressChanged: (Bool) -> Void
    let onTap: () -> Void
    @State private var startedAt: Date?
    @State private var holding = false
    @State private var timer: Task<Void, Never>?

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard startedAt == nil else { return }
                    startedAt = Date()
                    onPressChanged(true)
                    timer = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(threshold * 1_000_000_000))
                        guard !Task.isCancelled, startedAt != nil else { return }
                        holding = true
                        onHoldChanged(true)
                    }
                }
                .onEnded { value in
                    timer?.cancel(); timer = nil
                    let wasHolding = holding
                    let moved = abs(value.translation.width) >= 20 || abs(value.translation.height) >= 20
                    startedAt = nil; holding = false
                    if wasHolding { onHoldChanged(false) }
                    if !wasHolding, !moved { onTap() }
                    onPressChanged(false)
                })
    }
}
