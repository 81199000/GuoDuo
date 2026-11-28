// 局域网找安卓电视（Bonjour `_adb._tcp`）+ 「安装到电视」整条流程的状态机。
import Foundation
import CryptoKit
import UIKit
import Darwin

struct HGTVDevice: Identifiable, Hashable {
    var name: String
    var host: String
    var port: UInt16 = 5555
    var id: String { "\(host):\(port)" }
}

/// 解析手动输入：`192.168.1.20` 或 `192.168.1.20:5555`。不是合法 IPv4 返回 nil。
func hgParseTVAddress(_ raw: String) -> HGTVDevice? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "：", with: ":").replacingOccurrences(of: "。", with: ".")
    let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 1 || parts.count == 2 else { return nil }
    let oct = parts[0].split(separator: ".", omittingEmptySubsequences: false)
    guard oct.count == 4, oct.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) && (Int($0) ?? 256) <= 255 }) else { return nil }
    var port: UInt16 = 5555
    if parts.count == 2 {
        guard let p = UInt16(parts[1]), p > 0 else { return nil }
        port = p
    }
    return HGTVDevice(name: "电视 \(parts[0])", host: oct.map { String(Int($0)!) }.joined(separator: "."), port: port)
}

@Observable
final class HGTVScanner: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var devices: [HGTVDevice] = []
    var scanning = false
    private var browser: NetServiceBrowser?
    private var resolving: [NetService] = []

    private var sweepTask: Task<Void, Never>?

    func start() {
        stop()
        devices = []
        scanning = true
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: "_adb._tcp.", inDomain: "local.")
        browser = b
        // 电视的 adbd 跑久了会停止 Bonjour 广播（实测：端口还开着、广播没了），所以再并行探测本网段的 5555 端口兜底
        let token = ObjectIdentifier(b)
        sweepTask = Task { [weak self] in
            let found = await Self.sweep(Self.subnetHosts())
            await MainActor.run { [weak self] in
                guard let self, let cur = self.browser, ObjectIdentifier(cur) == token else { return }
                for ip in found where !self.devices.contains(where: { $0.host == ip && $0.port == 5555 }) {
                    self.devices.append(HGTVDevice(name: "安卓电视", host: ip))
                }
                self.scanning = false
            }
        }
        // 兜底：无论如何 12 秒后结束「扫描中」状态
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            if let cur = self?.browser, ObjectIdentifier(cur) == token { self?.scanning = false }
        }
    }

    /// 本机 Wi‑Fi（en0）所在 /24 网段里除自己外的 254 个地址
    static func subnetHosts() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        var mine: [UInt8]?
        while let p = cur {
            defer { cur = p.pointee.ifa_next }
            guard let a = p.pointee.ifa_addr, a.pointee.sa_family == sa_family_t(AF_INET),
                  String(cString: p.pointee.ifa_name) == "en0" else { continue }
            let v = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            mine = [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)]
        }
        guard let m = mine, m[0] != 169 else { return [] }
        return (1...254).filter { $0 != Int(m[3]) }.map { "\(m[0]).\(m[1]).\(m[2]).\($0)" }
    }

    /// 非阻塞 connect 探测：256 个并发、约 1.2 秒超时
    static func sweep(_ hosts: [String]) async -> [String] {
        await withTaskGroup(of: String?.self) { g in
            for h in hosts { g.addTask { await probe(h, port: 5555, timeout: 1.2) ? h : nil } }
            var out: [String] = []
            for await r in g { if let r { out.append(r) } }
            return out.sorted()
        }
    }

    private static func probe(_ host: String, port: UInt16, timeout: Double) async -> Bool {
        await withCheckedContinuation { c in
            DispatchQueue.global().async {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { c.resume(returning: false); return }
                defer { close(fd) }
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                var a = sockaddr_in()
                a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
                a.sin_port = port.bigEndian; inet_pton(AF_INET, host, &a.sin_addr)
                let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                if r == 0 { c.resume(returning: true); return }
                guard errno == EINPROGRESS else { c.resume(returning: false); return }
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { c.resume(returning: false); return }
                var err: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                c.resume(returning: err == 0)
            }
        }
    }

    func stop() {
        sweepTask?.cancel(); sweepTask = nil
        browser?.stop(); browser = nil
        resolving.forEach { $0.stop() }; resolving = []
        scanning = false
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) { scanning = false }

    func netServiceDidResolveAddress(_ sender: NetService) {
        defer { resolving.removeAll { $0 === sender } }
        guard let ip = Self.ipv4(sender.addresses ?? []) else { return }
        let tv = HGTVDevice(name: Self.prettyName(sender.name), host: ip, port: UInt16(clamping: sender.port))
        if !devices.contains(where: { $0.id == tv.id }) { devices.append(tv) }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) { resolving.removeAll { $0 === sender } }

    static func ipv4(_ addrs: [Data]) -> String? {
        for d in addrs {
            let ip: String? = d.withUnsafeBytes { raw -> String? in
                guard raw.count >= MemoryLayout<sockaddr_in>.size else { return nil }
                let sa = raw.bindMemory(to: sockaddr.self).baseAddress!
                guard sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                var sin = raw.load(as: sockaddr_in.self)
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                return String(cString: buf)
            }
            if let ip { return ip }
        }
        return nil
    }

    /// Bonjour 实例名是 `adb-<序列号>`，对用户没意义，先用占位名；连上后会换成型号
    private static func prettyName(_ n: String) -> String { n.hasPrefix("adb-") ? "安卓电视" : n }
}

// MARK: - 安装包清单

struct HGTVManifest: Decodable {
    var version: String
    var url: URL
    var sha256: String?
    var size: Int?
    var notes: String?
}

enum HGTVPackage {
    static let packageName = "me.rrmm.guoduo.tv"
    /// 清单地址；调试时可用启动参数 `-hg.tv.manifest <url>` 覆盖。
    static var manifestURL: URL {
        if let s = UserDefaults.standard.string(forKey: "hg.tv.manifest"), let u = URL(string: s) { return u }
        return URL(string: "\(HGUpdateChecker.distBase)/tv/latest.json")!
    }

    static func fetchManifest() async throws -> HGTVManifest {
        var req = URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw HGAdbError.failed("电视版安装包还没有发布，请稍后再试") }
            return try JSONDecoder().decode(HGTVManifest.self, from: data)
        } catch let e as HGAdbError { throw e }
        catch { throw HGAdbError.failed("获取电视版安装包信息失败，请检查手机网络") }
    }

    /// 下载（有缓存且校验过就直接用）。`progress` 0…1
    static func fetchAPK(_ m: HGTVManifest, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("guoduo-tv-\(m.version).apk")
        func ok(_ d: Data) -> Bool {
            if let n = m.size, d.count != n { return false }
            if let h = m.sha256 { return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() == h.lowercased() }
            return d.count > 100_000
        }
        if let d = try? Data(contentsOf: cache), ok(d) { progress(1); return d }
        let (bytes, resp) = try await URLSession.shared.bytes(from: m.url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw HGAdbError.failed("下载电视版安装包失败") }
        let total = Double(resp.expectedContentLength > 0 ? resp.expectedContentLength : Int64(m.size ?? 0))
        var data = Data(); data.reserveCapacity(Int(total))
        var buf = [UInt8](); buf.reserveCapacity(65536)
        for try await b in bytes {
            buf.append(b)
            if buf.count == 65536 { data.append(contentsOf: buf); buf.removeAll(keepingCapacity: true); if total > 0 { progress(min(1, Double(data.count) / total)) } }
        }
        data.append(contentsOf: buf)
        guard ok(data) else { throw HGAdbError.failed("安装包校验没通过，请重试") }
        try? data.write(to: cache, options: .atomic)
        progress(1)
        return data
    }
}

// MARK: - 安装流程

@MainActor @Observable
final class HGTVInstaller {
    enum Phase: Equatable {
        case idle, connecting, approving, downloading(Double), installing(Double), done, failed(String)
    }
    var phase: Phase = .idle
    var tvTitle = ""
    var installedBefore: String?     // 电视上原来的版本，nil = 没装
    var newVersion = ""
    var launched: Bool?
    private var session: HGAdbSession?
    private var task: Task<Void, Never>?

    var busy: Bool { switch phase { case .idle, .done, .failed: false; default: true } }

    func start(_ tv: HGTVDevice) {
        guard !busy else { return }
        phase = .connecting; launched = nil; installedBefore = nil
        HGScreenAwake.set("tv-install", true)      // 安装时别让手机锁屏，iOS 一退后台连接就断
        task = Task { [weak self] in
            await self?.run(tv)
            HGScreenAwake.set("tv-install", false)
        }
    }

    func cancel() {
        task?.cancel(); session?.close(); session = nil
        HGScreenAwake.set("tv-install", false)
        phase = .idle
    }

    private func run(_ tv: HGTVDevice) async {
        let s = HGAdbSession(host: tv.host, port: tv.port)
        session = s
        defer { s.close(); session = nil }
        do {
            try await s.connect(onApproval: { [weak self] in Task { @MainActor in self?.phase = .approving } })
            tvTitle = s.info.title
            phase = .connecting
            installedBefore = Self.parseVersion(try? await s.shell("dumpsys package \(HGTVPackage.packageName) | grep versionName"))
            let manifest = try await HGTVPackage.fetchManifest()
            newVersion = manifest.version
            phase = .downloading(0)
            let apk = try await HGTVPackage.fetchAPK(manifest) { p in Task { @MainActor [weak self] in self?.phase = .downloading(p) } }
            try Task.checkCancellation()
            phase = .installing(0)
            try await s.install(apk: apk) { p in Task { @MainActor [weak self] in self?.phase = .installing(p) } }
            phase = .done
            HGTVRecent.remember(tv, title: tvTitle)
            // 顺手拉起；失败不算安装失败
            let out = try? await s.shell("monkey -p \(HGTVPackage.packageName) -c android.intent.category.LEANBACK_LAUNCHER 1")
            launched = out?.contains("Events injected") == true
        } catch is CancellationError {
            phase = .idle
        } catch {
            if case .idle = phase { return }
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private static func parseVersion(_ out: String?) -> String? {
        guard let out, let r = out.range(of: "versionName=") else { return nil }
        let v = out[r.upperBound...].prefix { !$0.isWhitespace }
        return v.isEmpty ? nil : String(v)
    }
}

/// 最近连过的电视（手机重启 / 电视换了 IP 以外都能一点就连）
enum HGTVRecent {
    private static let key = "hg.tv.recent.v1"
    static func load() -> [HGTVDevice] {
        (UserDefaults.standard.array(forKey: key) as? [[String: String]] ?? []).compactMap {
            guard let h = $0["host"], let p = UInt16($0["port"] ?? "") else { return nil }
            return HGTVDevice(name: $0["name"] ?? "电视", host: h, port: p)
        }
    }
    static func remember(_ tv: HGTVDevice, title: String) {
        var list = load().filter { $0.id != tv.id }
        list.insert(HGTVDevice(name: title.isEmpty ? tv.name : title, host: tv.host, port: tv.port), at: 0)
        UserDefaults.standard.set(list.prefix(5).map { ["host": $0.host, "port": String($0.port), "name": $0.name] }, forKey: key)
    }
}
