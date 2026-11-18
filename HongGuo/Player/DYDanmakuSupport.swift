import SwiftUI

// 原样搬自 DouDuo（DouyinExtras.swift / ShortVideoPlayer.swift）：弹幕数据、调度策略、时钟、长按加速时长。

struct DYDanmaku: Identifiable, Decodable, Equatable {
    let id: String
    let text: String
    let offset: Double      // 秒
}

extension DYDanmaku {
    /// 合并分窗拉到的弹幕：按 id 去重，按时间排序（搬自 DouDuo）
    static func merged(_ a: [DYDanmaku], _ b: [DYDanmaku]) -> [DYDanmaku] {
        var seen = Set<String>()
        var out: [DYDanmaku] = []
        for d in a + b where seen.insert(d.id).inserted { out.append(d) }
        return out.sorted { $0.offset < $1.offset }
    }
}

enum DYBoostTiming {
    static let holdSeconds: Double = 0.3
}

enum HGLog {
    static func log(_ s: String) {
        #if DEBUG
        print("[HG]", s)
        #endif
    }
}

// MARK: - 弹幕调度策略

/// 仅影响视频滚动弹幕：上方三分之一、密度限流与短时间相同内容去重。
enum DYDanmakuPolicy {
    static let laneHeight: CGFloat = 28
    static let gap: CGFloat = 28
    static let densityKey = "douyin_video_danmaku_density_v1"
    static let deduplicateKey = "douyin_video_danmaku_deduplicate_v1"

    enum Density: Int, CaseIterable, Identifiable {
        case sparse = 0, standard = 1, dense = 2
        var id: Int { rawValue }
        var title: String {
            switch self { case .sparse: "稀疏"; case .standard: "标准"; case .dense: "密集" }
        }
        var maxLanes: Int {
            switch self { case .sparse: 2; case .standard: 4; case .dense: 6 }
        }
        var maxPerSecond: Int {
            switch self { case .sparse: 1; case .standard: 2; case .dense: 4 }
        }
    }
    struct Region { let top: CGFloat; let bottom: CGFloat; let lanes: Int }
    struct Placed { let d: DYDanmaku; let lane: Int; let width: CGFloat; let dur: Double; let start: Double }

    static func region(height: CGFloat, topInset: CGFloat, density: Density) -> Region {
        guard height.isFinite, height >= 0, topInset.isFinite else { return Region(top: 0, bottom: 0, lanes: 0) }
        let bottom = height / 3
        let top = max(0, topInset) + 64
        let available = max(0, ((bottom - top) / laneHeight).rounded(.down))
        return Region(top: top, bottom: bottom, lanes: Int(min(CGFloat(density.maxLanes), available)))
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
            .split(whereSeparator: { $0.isWhitespace }).joined()
    }

    static func layout(_ items: [DYDanmaku], w: CGFloat, lanes: Int, speed: CGFloat,
                       density: Density, deduplicate: Bool) -> [Placed] {
        guard w.isFinite, w > 0, speed.isFinite, speed > 0, lanes > 0 else { return [] }
        let laneCount = min(lanes, density.maxLanes)
        var free = Array(repeating: -Double.infinity, count: laneCount)
        var out: [Placed] = []
        var seenIDs = Set<String>(), lastShown: [String: Double] = [:]
        // 源数据一扎堆就只放前几条、后面直接丢，视觉上会「一片一片」。
        // 改成：能放就放在原时刻；轨道都占着就顺延（最多 2.5 秒），把成团的弹幕摊成连续流。
        let maxDelay = 2.5
        let sorted = items.enumerated().filter { $0.element.offset.isFinite && $0.element.offset >= 0 }
            .sorted { $0.element.offset == $1.element.offset ? $0.offset < $1.offset : $0.element.offset < $1.element.offset }
        for entry in sorted {
            let d = entry.element
            let text = normalized(d.text)
            guard !d.id.isEmpty, !text.isEmpty, !seenIDs.contains(d.id) else { continue }
            if deduplicate, let last = lastShown[text], d.offset - last < 10 { continue }
            let width = d.text.unicodeScalars.reduce(CGFloat(6)) { $0 + ($1.value < 0x2E80 ? 9 : 16) }
            // 选最早空出来的轨道
            var lane = -1
            var start = Double.infinity
            for (i, f) in free.enumerated() {
                let candidate = max(d.offset, f)
                if candidate < start { start = candidate; lane = i }
            }
            guard lane >= 0, start - d.offset <= maxDelay else { continue }
            free[lane] = start + Double((width + gap) / speed)
            out.append(Placed(d: d, lane: lane, width: width, dur: Double((w + width) / speed), start: start))
            seenIDs.insert(d.id); lastShown[text] = d.offset
        }
        return out
    }
}

// MARK: - 弹幕层（视频）

/// 弹幕时钟：播放器每 0.25 秒报一次进度，弹幕按帧插值出「现在」的视频时间，否则位置一跳一跳。
/// 播放器报一次就校准一次（锚点 = 报的时间 + 报的时刻），中间按播放速率往前推。
struct DYDanmakuClock {
    var anchorTime: Double = 0
    var anchorDate = Date()
    var rate: Double = 1
    var playing = false
    /// 微调速率（±8%）：跟播放器对不上时不再把位置往回拽，而是让弹幕稍快/稍慢一点点追上。
    /// 原来每 0.25 秒把锚点拉回一次 → 弹幕每秒往回抖 4 下（实测平稳时偏差 20～90ms），看着不顺。
    var slew: Double = 0
    /// 快进/拖动后的「冷静期」：播放器在重建音频、缓冲，报上来的时间与暂停状态在抖，只做平滑追赶不硬跳
    var settleUntil = Date.distantPast
    /// 用户每跳转一次 +1：弹幕层看到变化就清屏、从新位置重新出（抖音同款）
    var epoch = 0

    func now(_ d: Date) -> Double {
        playing ? anchorTime + d.timeIntervalSince(anchorDate) * rate * (1 + slew) : anchorTime
    }

    /// 用户主动跳转（拖进度、快进/快退）：直接对齐到目标，并进入冷静期
    mutating func seek(_ t: Double, playing p: Bool, rate r: Double) {
        anchorTime = t; anchorDate = Date(); playing = p; rate = r; slew = 0
        settleUntil = Date().addingTimeInterval(2.5)
        epoch += 1
    }

    /// 用户点了暂停/播放：立刻生效
    mutating func userToggle(_ t: Double, playing p: Bool, rate r: Double) {
        settleUntil = .distantPast
        anchorTime = t; anchorDate = Date(); playing = p; rate = r; slew = 0
    }

    /// 诊断：每次校准时预测值与播放器报告值的偏差（秒）
    static var errSamples: [Double] = []

    mutating func sync(_ t: Double, playing p: Bool, rate r: Double) {
        let now = Date()
        let predicted = self.now(now)
        let err = t - predicted
        let settling = now < settleUntil
        if p, playing {
            Self.errSamples.append(err)
            if Self.errSamples.count >= 40 {
                let e = Self.errSamples
                let absMax = e.map { abs($0) }.max() ?? 0
                let mean = e.reduce(0, +) / Double(e.count)
                HGLog.log("DDDMCLOCK n=\(e.count) mean=\(String(format: "%+.3f", mean))s maxAbs=\(String(format: "%.3f", absMax))s over50ms=\(e.filter { abs($0) > 0.05 }.count)")
                Self.errSamples.removeAll()
            }
        }
        // 冷静期里播放器短暂报「暂停」（缓冲）不跟着停；其余情况状态/倍速变了就硬对齐
        let pausedBlip = settling && !p && playing
        let stateChanged = !pausedBlip && (p != playing || r != rate)
        let hardLimit = settling ? 1.5 : 0.35
        if stateChanged || !playing || abs(err) > hardLimit {
            anchorTime = t; anchorDate = now; slew = 0
            if !pausedBlip { playing = p }
            rate = r
            return
        }
        // 连续：位置不跳，只在 1 秒内用 ±8% 的速率把偏差追平
        anchorTime = predicted; anchorDate = now
        slew = max(-0.08, min(0.08, err / max(rate, 0.25)))
        if settling, abs(err) < 0.1 { settleUntil = .distantPast }
        rate = r
    }
}


/// 抖音同款滚动弹幕：所有弹幕同一速度从右往左飘（同速 → 同一轨道里后面的永远追不上前面的）。
/// 轨道按「前一条尾巴已经完全进屏 + 间距」分配，整条视频一次排好（布局只在弹幕列表 / 屏幕宽变化时重算）；
/// 某个时刻所有轨道都满就丢掉这一条（抖音也是这样）。
/// 位置用 TimelineView(.animation) 逐帧算（跟屏幕刷新率走，ProMotion 上 120Hz），不靠 SwiftUI 补间动画。
struct DYDanmakuLayer: View {
    let items: [DYDanmaku]
    let clock: DYDanmakuClock
    let topInset: CGFloat
    @AppStorage(DYDanmakuPolicy.densityKey) private var densityRaw = DYDanmakuPolicy.Density.standard.rawValue
    @AppStorage(DYDanmakuPolicy.deduplicateKey) private var deduplicate = true

    private var renderItems: [DYDanmaku] {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_DM_STRESS"] == "1" {
            return (0..<600).map { DYDanmaku(id: "stress-\($0)", text: "弹幕流畅度测试 \($0)", offset: Double($0) * 0.15) }
        }
        #endif
        return items
    }

    var body: some View {
        GeometryReader { g in
            let density = DYDanmakuPolicy.Density(rawValue: densityRaw) ?? .standard
            let region = DYDanmakuPolicy.region(height: g.size.height, topInset: topInset, density: density)
            // 字号变大后轨道变高：按新行高重算这块区域能放几条轨道
            let lanes = min(density.maxLanes, Int(max(0, (region.bottom - region.top) / DYDanmakuStyle.laneHeight)))
            DYDanmakuLiveSurface(items: renderItems, clock: clock, regionTop: region.top,
                                 regionHeight: max(0, region.bottom - region.top), lanes: lanes,
                                 density: density, deduplicate: deduplicate)
                .frame(width: g.size.width, height: g.size.height)
        }
        .allowsHitTesting(false)
    }
}
