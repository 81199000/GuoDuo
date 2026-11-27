// 果多 TV 遥控。
// 电视端（guoduo-tv LocalService）已有的接口，App 直接用，不改电视：
//   Bonjour `_guoduo._tcp`（TXT id / api / app）· 端口 8765 起
//   GET  /api/pair/info                 公开：电视名 / 型号 / 要不要密码 / 这台手机绑过没有
//   POST /api/pair/bind {device,password?} → {token}   以后带 `Authorization: Bearer <token>`
//   GET  /api/status                    正在播：id / 第几集(episode=集号) / position·duration(毫秒) / paused / loading / version
//   POST /api/play {id,index,cover}     电视开播某部第 index 集（0 起）
//   POST /api/control {action,position?,version}   toggle/play/pause/seek/next/previous/forward/rewind…
//   POST /api/remote/key {key}          up/down/left/right/ok/back/menu/home/playpause/vol_up/vol_down/mute
//   GET  /api/detail?id=                电视那边的分集表（index 0 起 / number 集号）
// 令牌存钥匙串（每台电视一份），电视改 / 清遥控密码后作废，重新绑定即可。
import Foundation
import Darwin

struct HGRemoteTV: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var host: String
    var port: Int
    var model: String?
    var base: URL { URL(string: "http://\(host):\(port)")! }
}

struct HGTVPairInfo: Decodable {
    let app: String?
    let id: String
    let name: String
    let model: String?
    let version: String?
    let port: Int?
    let remoteOn: Bool?
    let needPassword: Bool?
    let bound: Bool?
}

struct HGTVStatus: Decodable, Equatable {
    var id: String = ""
    var title: String = ""
    var cover: String?
    /// 集号（第几集，1 起）
    var episode: Int = 0
    /// 毫秒
    var position: Int = 0
    var duration: Int = 0
    var paused = false
    var loading = false
    var playing = false
    var ended = false
    var version: Int = 0
    var error: String?
    var coverURL: URL? { cover.flatMap { $0.isEmpty ? nil : URL(string: $0) } }
    /// 电视上真有一部剧在播（不是「未在播放」）
    var active: Bool { playing && !id.isEmpty }
}

enum HGTVRemoteError: LocalizedError {
    case server(String)
    case needPassword(String)
    case offline
    var errorDescription: String? {
        switch self {
        case .server(let m), .needPassword(let m): m
        case .offline: "连不上电视：确认电视开着 GuoDuo TV、和手机在同一个 Wi‑Fi"
        }
    }
}

/// 一台电视的接口客户端
struct HGTVClient {
    let tv: HGRemoteTV
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private var token: String? { HGKeychain.get(HGTVStore.tokenKey(tv.id)) }

    private func call(_ path: String, query: [String: String] = [:], body: [String: Any]? = nil, timeout: Double = 6) async throws -> Data {
        var comps = URLComponents(url: tv.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!, timeoutInterval: timeout)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await Self.session.data(for: req) } catch {
            HGTrace.log("tvremote \(path) 网络失败 \((error as NSError).domain) \((error as NSError).code)")
            throw HGTVRemoteError.offline
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200 { return data }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let msg = obj?["error"] as? String ?? "电视返回 \(code)"
        if obj?["needPassword"] as? Bool == true { throw HGTVRemoteError.needPassword(msg) }
        throw HGTVRemoteError.server(msg)
    }

    func info() async throws -> HGTVPairInfo {
        try JSONDecoder().decode(HGTVPairInfo.self, from: try await call("/api/pair/info", timeout: 4))
    }

    /// 绑定：成功后令牌进钥匙串
    func bind(password: String?) async throws {
        var body: [String: Any] = ["device": HGTVStore.deviceName]
        if let password, !password.isEmpty { body["password"] = password }
        let d = try await call("/api/pair/bind", body: body)
        guard let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any], let t = obj["token"] as? String else {
            throw HGTVRemoteError.server("电视没有返回令牌")
        }
        HGKeychain.set(HGTVStore.tokenKey(tv.id), t)
    }

    func status() async throws -> HGTVStatus {
        try JSONDecoder().decode(HGTVStatus.self, from: try await call("/api/status", timeout: 4))
    }

    func key(_ k: String) async throws { _ = try await call("/api/remote/key", body: ["key": k]) }

    @discardableResult
    func control(_ action: String, position: Int? = nil, version: Int? = nil) async throws -> HGTVStatus? {
        var body: [String: Any] = ["action": action]
        if let position { body["position"] = position }
        if let version { body["version"] = version }
        let d = try await call("/api/control", body: body)
        struct R: Decodable { let status: HGTVStatus? }
        return try? JSONDecoder().decode(R.self, from: d).status
    }

    func play(id: String, index: Int, cover: String?) async throws {
        _ = try await call("/api/play", body: ["id": id, "index": index, "cover": cover ?? ""], timeout: 15)
    }

    /// 手机 → 电视：电视开播同一集，等它起播后跳到手机的进度（秒）。返回电视名
    func handoff(seriesID: String, index: Int, cover: String?, seconds: Double) async throws {
        try await play(id: seriesID, index: index, cover: cover)
        var st = HGTVStatus()
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(400))
            if let s = try? await status(), s.id == seriesID, !s.loading, s.duration > 0 { st = s; break }
        }
        guard st.duration > 0 else { throw HGTVRemoteError.server("电视起播超时，已开始播这一集，进度没能接上") }
        if seconds > 3 {
            _ = try await control("seek", position: Int(seconds * 1000), version: st.version)
        }
    }
}

/// 绑过的电视（名字 / 地址存 UserDefaults，令牌在钥匙串）
@MainActor @Observable final class HGTVStore {
    static let shared = HGTVStore()
    private static let key = "hg.tvremote.devices.v1"
    nonisolated static func tokenKey(_ id: String) -> String { "tv.token.\(id)" }
    nonisolated static var deviceName: String { "GuoDuo iOS" }

    private(set) var devices: [HGRemoteTV] = []
    /// 最近用的那台（投屏默认投它）
    var current: HGRemoteTV? { devices.first }

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.key), let v = try? JSONDecoder().decode([HGRemoteTV].self, from: d) { devices = v }
    }

    func remember(_ tv: HGRemoteTV) {
        devices.removeAll { $0.id == tv.id }
        devices.insert(tv, at: 0)
        save()
    }
    func forget(_ tv: HGRemoteTV) {
        devices.removeAll { $0.id == tv.id }
        HGKeychain.delete(Self.tokenKey(tv.id))
        save()
    }
    func isPaired(_ id: String) -> Bool { HGKeychain.get(Self.tokenKey(id)) != nil }
    private func save() { if let d = try? JSONEncoder().encode(devices) { UserDefaults.standard.set(d, forKey: Self.key) } }

    /// 地址变了（电视换了 IP）：按 id 更新
    func refreshAddress(_ tv: HGRemoteTV) {
        guard let i = devices.firstIndex(where: { $0.id == tv.id }), devices[i].host != tv.host || devices[i].port != tv.port else { return }
        devices[i].host = tv.host; devices[i].port = tv.port
        save()
    }
}

/// 扫码 / 手输：`http://192.168.1.20:8765/#search`、`192.168.1.20:8765`、`192.168.1.20` 都认
func hgParseRemoteAddress(_ raw: String) -> (host: String, port: Int)? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "：", with: ":").replacingOccurrences(of: "。", with: ".")
    if !s.contains("://") { s = "http://" + s }
    guard let u = URL(string: s), let host = u.host, !host.isEmpty else { return nil }
    let oct = host.split(separator: ".")
    guard oct.count == 4, oct.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else { return nil }
    return (host, u.port ?? 8765)
}

/// 局域网发现：Bonjour `_guoduo._tcp`（电视端常驻广播）
@MainActor @Observable final class HGTVRemoteBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var found: [HGRemoteTV] = []
    var scanning = false
    private var browser: NetServiceBrowser?
    private var resolving: [NetService] = []

    func start() {
        stop()
        found = []
        scanning = true
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: "_guoduo._tcp.", inDomain: "local.")
        browser = b
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.scanning = false }
    }

    func stop() {
        browser?.stop(); browser = nil
        resolving.forEach { $0.stop() }; resolving = []
        scanning = false
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated {
            service.delegate = self
            resolving.append(service)
            service.resolve(withTimeout: 5)
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        MainActor.assumeIsolated {
            defer { resolving.removeAll { $0 === sender } }
            guard let ip = HGTVScanner.ipv4(sender.addresses ?? []) else { return }
            var id = "\(ip):\(sender.port)"
            if let txt = sender.txtRecordData() {
                let d = NetService.dictionary(fromTXTRecord: txt)
                if let v = d["id"], let s = String(data: v, encoding: .utf8), !s.isEmpty { id = s }
            }
            let tv = HGRemoteTV(id: id, name: sender.name, host: ip, port: sender.port)
            if let i = found.firstIndex(where: { $0.id == tv.id }) { found[i] = tv } else { found.append(tv) }
            HGTVStore.shared.refreshAddress(tv)
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        MainActor.assumeIsolated { resolving.removeAll { $0 === sender } }
    }
}
