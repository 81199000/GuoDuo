import SwiftUI

/// 冷炭底 + 单一红色强调（红果）。所有颜色/圆角从这里取，不在页面里写死。
enum HGTheme {
    static let background = Color(red: 0.06, green: 0.06, blue: 0.07)
    static let surface = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let surfaceHigh = Color(red: 0.16, green: 0.16, blue: 0.18)
    static let accent = Color(red: 0.93, green: 0.23, blue: 0.27)
    static let textPrimary = Color(white: 0.96)
    static let textSecondary = Color(white: 0.62)
    static let textTertiary = Color(white: 0.42)
    static let radius: CGFloat = 10
    static let radiusSmall: CGFloat = 6
}

struct HGCover: View {
    let url: URL?
    var body: some View {
        CachedAsyncImage(url: url, thumbnailMaxPixel: 720) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(HGTheme.surfaceHigh).overlay(Image(systemName: "film").foregroundStyle(HGTheme.textTertiary))
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: HGTheme.radius, style: .continuous))
    }
}

struct HGSeriesCard: View {
    let series: HGSeries
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HGCover(url: series.coverURL)
                .overlay(alignment: .bottomTrailing) {
                    if let n = series.episode_count, n > 0 {
                        Text("\(n) 集").font(.caption2.weight(.semibold)).monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule())
                            .foregroundStyle(HGTheme.textPrimary).padding(6)
                    }
                }
            Text(series.series_title).font(.subheadline.weight(.medium)).foregroundStyle(HGTheme.textPrimary).lineLimit(2)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(HGTheme.textSecondary).lineLimit(1) }
        }
    }
}

struct HGErrorView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.title2).foregroundStyle(HGTheme.textTertiary)
            Text(message).font(.footnote).foregroundStyle(HGTheme.textSecondary).multilineTextAlignment(.center)
            Button("重试", action: retry).buttonStyle(.bordered).tint(HGTheme.accent)
        }
        .padding(32).frame(maxWidth: .infinity)
    }
}
