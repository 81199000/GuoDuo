import SwiftUI

/// DouDuo DYStorageScreen 原样搬：圆环 + 占用明细 + 底部「清理缓存」玻璃键。
/// 清理范围：在线播放的整集缓存、半截下载、封面图片缓存；保留离线下载的视频。

struct DYStorageScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var usage: DYStorageFiles.Usage?
    @State private var scanning = false
    @State private var clearing = false
    @State private var confirming = false
    @State private var scanFailed = false
    @State private var cleanupSucceeded: Bool?

    var body: some View {
        Form {
            if let usage {
                Section {
                    overview(usage)
                        .listRowBackground(Color.clear)
                }
            }
            if let usage {
                Section {
                    storageRow("App 大小", bytes: usage.app, total: usage.total, color: DYStorageRing.appColor)
                    // 空的类别（如已下线的离线视频）不显示，免得一排「0 bytes」
                    ForEach(DYStorageFiles.Category.allCases.filter { (usage.categories[$0] ?? 0) > 0 }, id: \.self) { category in
                        let row = storageRow(title(category), bytes: usage.categories[category, default: 0],
                                             total: usage.total, color: DYStorageRing.color(for: category))
                        if category == .other, !usage.otherAreas.isEmpty {
                            DisclosureGroup {
                                ForEach(DYStorageFiles.OtherArea.allCases, id: \.self) { area in
                                    if let bytes = usage.otherAreas[area], bytes > 0 {
                                        LabeledContent(area.rawValue, value: size(bytes))
                                    }
                                }
                            } label: {
                                row
                            }
                            .accessibilityIdentifier("storage.other.details")
                        } else {
                            row.accessibilityIdentifier("storage.bytes." + category.rawValue)
                        }
                    }
                } header: {
                    Text("占用明细")
                } footer: {
                    Text("文稿与数据 \(size(usage.data))。App 内估算包含缓存和临时文件，iOS 储存空间可能采用不同的统计范围。")
                }
            } else if !scanFailed {
                ProgressView("正在统计缓存")
            }

            if scanFailed {
                Button("统计失败，重试", systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }
                .disabled(scanning || clearing)
            }
        }
        .scrollContentBackground(.hidden)
        .modifier(HGHideBottomEdgeEffect())
        .background(HGTheme.background)
        .safeAreaInset(edge: .bottom, spacing: 0) { cleanupBar }
        .navigationTitle("缓存管理")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refresh()
            #if DEBUG
            if ProcessInfo.processInfo.environment["HG_DEMO_STORAGE"] == "1" {
                try? await Task.sleep(for: .seconds(6))
                await clear()
            }
            #endif
        }
        .refreshable { await refresh() }
        .alert("清理缓存？", isPresented: $confirming) {
            Button("清理缓存", role: .destructive) {
                Task { await clear() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清除在线播放缓存和封面图片。封面清掉后会重新下载。")
        }
    }

    private func overview(_ usage: DYStorageFiles.Usage) -> some View {
        VStack(spacing: 14) {
            DYStorageRing(usage: usage, totalLabel: size(usage.total), clearing: clearing)
            VStack(spacing: 8) {
                if let capacity = usage.deviceCapacity, capacity > 0 {
                    let share = Double(usage.total) / Double(capacity)
                    Text("占手机总容量的 \(percent(share))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("storage.device-share")
                    ProgressView(value: min(share, 1))
                        .tint(.accentColor)
                        .frame(maxWidth: 220)
                        .accessibilityHidden(true)
                } else {
                    Text("暂时无法读取手机总容量")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if usage.isPartial {
                Text("部分目录无法读取，当前仅显示已统计的占用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("storage.partial")
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func storageRow(_ title: String, bytes: Int64, total: Int64, color: Color) -> some View {
        let ratio = Double(bytes) / Double(max(total, 1))
        let labelLayout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 6))
        return LabeledContent {
            Text(size(bytes))
                .monospacedDigit()
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                labelLayout {
                    Text(title)
                    Text(percent(ratio))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var cleanupBar: some View {
        VStack(spacing: 8) {
            if let cleanupSucceeded, !clearing {
                Label {
                    Text(cleanupSucceeded ? "缓存已清理" : "部分缓存未能清理，请重试。")
                } icon: {
                    Image(systemName: cleanupSucceeded ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(cleanupSucceeded ? Color.green : Color.orange)
                        .accessibilityHidden(true)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("storage.result")
                .transition(.opacity)
            }
            Button {
                confirming = true
            } label: {
                Text(clearing ? "正在清理…" : "清理缓存")
                    .frame(maxWidth: .infinity, minHeight: 24)
            }
            .modifier(HGProminentGlassButton())
            .tint(Color(red: 1, green: 59.0 / 255, blue: 48.0 / 255))
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(scanning || clearing)
            .accessibilityIdentifier("storage.clear")
        }
        .frame(maxWidth: 480)
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: cleanupSucceeded)
    }

    private func refresh() async {
        guard !clearing, !scanning else { return }
        scanning = true
        defer { scanning = false }
        await updateUsage()
    }

    private func updateUsage() async {
        do {
            usage = try await DYStorageFiles.shared.scan()
            scanFailed = false
        } catch is CancellationError {
            return
        } catch {
            scanFailed = true
        }
    }

    private func clear() async {
        guard !clearing, !scanning else { return }
        clearing = true
        cleanupSucceeded = nil
        defer { clearing = false }

        let videos = await HGMediaCache.shared.clearForStorage()
        URLCache.shared.removeAllCachedResponses()
        let covers = HGImageCache.shared.removeAll()
        let images = DYStorageFiles.removeIfPresent(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "", isDirectory: true)
                .appendingPathComponent("fsCachedData", isDirectory: true))

        await updateUsage()
        cleanupSucceeded = videos && images && covers
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private func size(_ bytes: Int64) -> String {
        Self.byteFormatter.string(fromByteCount: bytes)
    }

    private func percent(_ ratio: Double) -> String {
        let style: FloatingPointFormatStyle<Double>.Percent = .percent.precision(.fractionLength(0...2))
        if ratio > 0 && ratio < 0.0001 {
            return "<\(0.0001.formatted(style))"
        }
        return ratio.formatted(style)
    }

    private func title(_ category: DYStorageFiles.Category) -> String {
        switch category {
        case .video: "播放缓存"
        case .offline: "离线视频"
        case .images: "封面 / 头像缓存"
        case .web: "网页数据"
        case .diagnostics: "诊断日志"
        case .other: "其他 App 数据"
        }
    }
}


/// iOS 26 才有玻璃按钮 / 滚动边缘效果；GuoDuo 最低 iOS 18，老系统退回 borderedProminent
private struct HGProminentGlassButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content.buttonStyle(.glassProminent) }
        else { content.buttonStyle(.borderedProminent) }
    }
}

private struct HGHideBottomEdgeEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content.scrollEdgeEffectHidden(true, for: .bottom) } else { content }
    }
}
