// 检查 GitHub 有没有新版本（DouDuo 同款思路），并拉取更新说明。
// 版本号：读 releases/latest 的 302 跳转（不走 api.github.com，匿名 60 次/小时容易 403），
//         最终 URL 是 .../releases/tag/vX.Y.Z。
// 更新说明：优先读仓库里该 tag 下的 docs/releases/vX.Y.Z.md（raw 域名无频率限制，内容随版本走），
//         读不到再退回 api.github.com 的 release 正文。
import Foundation
import UIKit

struct HGUpdate: Equatable, Identifiable {
    let version: String        // 1.0.0（不带 v）
    let tag: String            // v1.0.0
    var notes: String          // Markdown 更新说明，可能为空
    var id: String { tag }
    var pageURL: URL { URL(string: "https://github.com/\(HGUpdateChecker.repo)/releases/tag/\(tag)")! }
}

enum HGUpdateChecker {
    static let repo = "81199000/GuoDuo"
    /// 上游取源核心（GPL-3.0），「关于」里注明出处
    static let upstreamRepo = "jackotom/hongguo-drama"
    static let dismissedKey = "hg.update.dismissed.v1"

    static var repoURL: URL { URL(string: "https://github.com/\(repo)")! }
    static var releasesURL: URL { URL(string: "https://github.com/\(repo)/releases")! }
    static var upstreamURL: URL { URL(string: "https://github.com/\(upstreamRepo)")! }

    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }
    static var currentBuild: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }

    /// 用户点过「以后再说 / 去更新」的版本，启动时不再弹这个版本（手动检查仍然显示）
    static var dismissedVersion: String {
        get { UserDefaults.standard.string(forKey: dismissedKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: dismissedKey) }
    }

    enum Failure: Error, LocalizedError {
        case network, noRelease
        var errorDescription: String? {
            switch self {
            case .network: "连不上 GitHub，请检查网络后重试"
            case .noRelease: "仓库还没有发布过版本"
            }
        }
    }

    private static var session: URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.httpShouldSetCookies = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }

    private static func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("GuoDuo-iOS", forHTTPHeaderField: "User-Agent")
        return req
    }

    /// 远端最新版（含更新说明）
    static func latest() async throws -> HGUpdate {
        #if DEBUG
        // 调试：HG_FAKEUPDATE=1 假装远端有 9.9.9，看弹窗长什么样
        if ProcessInfo.processInfo.environment["HG_FAKEUPDATE"] == "1" {
            return HGUpdate(version: "9.9.9", tag: "v9.9.9", notes: """
            # GuoDuo 9.9.9 · 调试用假版本

            ## 新功能
            - 推荐页按姿态选片：横屏看**横屏片**，竖屏看竖屏片
            - 「我的 → 关于」可以检查更新、打开开源仓库

            ## 修复
            - 半折叠时菜单栏不再挡住视频
            """)
        }
        #endif
        guard let url = URL(string: "https://github.com/\(repo)/releases/latest") else { throw Failure.network }
        let resp: URLResponse
        do { (_, resp) = try await session.data(for: request(url)) } catch { throw Failure.network }
        guard let final = (resp as? HTTPURLResponse)?.url else { throw Failure.network }
        // 没发过 release 会停在 /releases 或 404（私有仓也是 404）
        let comps = final.pathComponents
        guard let idx = comps.firstIndex(of: "tag"), idx + 1 < comps.count else { throw Failure.noRelease }
        let tag = comps[idx + 1]
        let ver = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !ver.isEmpty else { throw Failure.noRelease }
        return HGUpdate(version: ver, tag: tag, notes: await notes(for: tag))
    }

    /// 更新说明：仓库 docs/releases/<tag>.md → 退回 Release 正文 → 空
    static func notes(for tag: String) async -> String {
        if let url = URL(string: "https://raw.githubusercontent.com/\(repo)/\(tag)/docs/releases/\(tag).md"),
           let (data, resp) = try? await session.data(for: request(url)),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let s = String(data: data, encoding: .utf8), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
        if let url = URL(string: "https://api.github.com/repos/\(repo)/releases/tags/\(tag)") {
            var req = request(url)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            if let (data, resp) = try? await session.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let body = obj["body"] as? String {
                return body
            }
        }
        return ""
    }

    /// 远端版本比本机新？
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(remote), b = parts(local)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// 启动时调用：有新版本且没被关掉过才返回；查不到静默
    static func checkAtLaunch() async -> HGUpdate? {
        guard let remote = try? await latest(),
              isNewer(remote.version, than: currentVersion) else { return nil }
        #if DEBUG
        if ProcessInfo.processInfo.environment["HG_FAKEUPDATE"] == "1" { return remote } // 调试每次都弹
        #endif
        guard dismissedVersion != remote.version else { return nil }
        return remote
    }

    static func dismiss(_ update: HGUpdate) { dismissedVersion = update.version }
}
