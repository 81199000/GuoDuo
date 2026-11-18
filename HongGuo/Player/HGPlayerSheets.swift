import SwiftUI

/// 本集热评：官网公开页最多 15 条（老板定：只放热评，不混弹幕）。
struct HGCommentSheet: View {
    let series: HGSeries
    let episode: HGEpisode
    @State private var data: HGComments?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("本集热评").font(.headline)
                if let total = data?.total { Text("共 \(total.formatted()) 条").font(.caption).foregroundStyle(HGTheme.textSecondary) }
                Spacer()
                if let likes = data?.episodeLikes {
                    Label(likes.formatted(.number.notation(.compactName)), systemImage: "hand.thumbsup").font(.caption).foregroundStyle(HGTheme.textSecondary)
                }
            }
            .padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 10)
            Divider().overlay(HGTheme.surfaceHigh)
            Group {
                if let data {
                    if data.items.isEmpty {
                        ContentUnavailableView("官网暂无本集评论", systemImage: "text.bubble")
                    } else {
                        List {
                            ForEach(data.items) { HGReviewRow(review: $0) }.listRowBackground(Color.clear)
                            Text("官网只公开每集前 15 条热评，更多评论请到红果 App 查看")
                                .font(.caption2).foregroundStyle(HGTheme.textTertiary)
                                .frame(maxWidth: .infinity).listRowBackground(Color.clear).listRowSeparator(.hidden)
                        }
                        .listStyle(.plain).scrollContentBackground(.hidden)
                    }
                } else if let error {
                    HGErrorView(message: error) { Task { await load() } }.frame(maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(HGTheme.surface)
        .task { await load() }
    }

    private func load() async {
        error = nil
        do { data = try await HGAPI.comments(series: series.series_id, vid: episode.vid) }
        catch { self.error = "官网暂无本集评论（\(error.localizedDescription)）" }
    }
}

private struct HGReviewRow: View {
    let review: HGReview
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.locale = Locale(identifier: "zh_CN"); f.unitsStyle = .full; return f
    }()
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: review.avatar.flatMap(URL.init(string:))) { img in img.resizable().scaledToFill() } placeholder: { HGTheme.surfaceHigh }
                .frame(width: 34, height: 34).clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(review.author.isEmpty ? "红果用户" : review.author).font(.caption.weight(.medium)).foregroundStyle(HGTheme.textSecondary)
                Text(review.content).font(.subheadline).foregroundStyle(HGTheme.textPrimary).fixedSize(horizontal: false, vertical: true)
                if let t = review.created_at {
                    Text(Self.relative.localizedString(for: Date(timeIntervalSince1970: t / 1000), relativeTo: Date())).font(.caption2).foregroundStyle(HGTheme.textTertiary)
                }
            }
            Spacer(minLength: 8)
            if let likes = review.likes {
                VStack(spacing: 2) {
                    Image(systemName: "heart").font(.footnote)
                    Text(likes.formatted(.number.notation(.compactName))).font(.caption2.monospacedDigit())
                }
                .foregroundStyle(HGTheme.textTertiary)
            }
        }
        .padding(.vertical, 6)
    }
}

struct HGEpisodeSheet: View {
    let session: HGPlaybackSession
    let close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(session.series.series_title).font(.headline).lineLimit(1)
                Spacer()
                Text("共 \(session.episodes.count) 集").font(.caption).foregroundStyle(HGTheme.textSecondary)
            }
            .padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 8)], spacing: 8) {
                        ForEach(Array(session.episodes.enumerated()), id: \.element.id) { i, ep in
                            Button { session.go(to: i); close() } label: {
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
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 24)
                }
                .onAppear { proxy.scrollTo(session.index, anchor: .center) }
            }
        }
        .background(HGTheme.surface)
    }
}
