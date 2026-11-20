// 检查有没有新版本，并拉取更新说明。
// 2026-11-20：GitHub 旧号 81199000 被封、Gitee 镜像不对外，更新统一指向自家 oneduo.app：
// 版本号：读 dl.oneduo.app/guoduo/guoduo.json（Cloudflare R2 上的软件源，发版时同步）的 apps[0].version。
// 更新说明：读 dl.oneduo.app/guoduo/notes/vX.Y.Z.md，读不到退回软件源里的 versionDescription。
// 更新方式：打开电脑上的一键签（GuoDuo 在一键签应用列表里，开着一键签会自动装新版）；
// 「去一键签更新」打开 oneduo.app（还没装一键签的从这里下载）。
import Foundation
import UIKit

struct HGUpdate: Equatable, Identifiable {
    let version: String        // 1.0.0（不带 v）
    let tag: String            // v1.0.0
    var notes: String          // Markdown 更新说明，可能为空
    var id: String { tag }
    var pageURL: URL { HGUpdateChecker.updatePage }
}

enum HGUpdateChecker {
    static let repo = "WuWeiDuo/GuoDuo"
    /// 自家分发（Cloudflare R2 + 一键签官网）
    static let distBase = "https://dl.oneduo.app/guoduo"
    static let updatePage = URL(string: "https://oneduo.app/")!
    /// 上游取源核心（GPL-3.0），「关于」里注明出处
    static let upstreamRepo = "jackotom/hongguo-drama"
    static let dismissedKey = "hg.update.dismissed.v1"

    static var repoURL: URL { URL(string: "https://github.com/\(repo)")! }
    static var releasesURL: URL { updatePage }
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
            case .network: "连不上更新服务器，请检查网络后重试"
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
        guard let url = URL(string: "\(distBase)/guoduo.json") else { throw Failure.network }
        let data: Data
        do {
            let (d, resp) = try await session.data(for: request(url))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.network }
            data = d
        } catch { throw Failure.network }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let app = (obj["apps"] as? [[String: Any]])?.first,
              let ver = app["version"] as? String, ver.first?.isNumber == true else { throw Failure.noRelease }
        let tag = "v" + ver
        let fallback = app["versionDescription"] as? String ?? ""
        return HGUpdate(version: ver, tag: tag, notes: await notes(for: tag, fallback: fallback))
    }

    /// 更新说明：dl.oneduo.app 上的 docs/releases/<tag>.md → 软件源里的纯文本说明
    static func notes(for tag: String, fallback: String = "") async -> String {
        if let url = URL(string: "\(distBase)/notes/\(tag).md"),
           let (data, resp) = try? await session.data(for: request(url)),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let s = String(data: data, encoding: .utf8), s.hasPrefix("#") {
            return s
        }
        return fallback
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
