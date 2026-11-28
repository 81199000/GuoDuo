// 普通投屏（没绑过 GuoDuo TV 时）：App 自己当片源，把网址推给电视，电视自己来拉。
//
// 为什么不用系统 AirPlay 列表：片子是手机本地解密的，系统只能镜像式往电视送画面；小米电视这类
// 「仿 Apple TV 3」的接收端这种方式只收得到声音（实测）。改成推网址后同一集 H.265 有画面（实测）。
//
// - HGCastServer：局域网 HTTP（Network.framework），只发当前这一集解密后的 mp4，支持 Range；
//   每次投屏换一个随机路径，别的设备猜不到。
// - 发现：AirPlay 走 Bonjour `_airplay._tcp`；DLNA 的 SSDP 组播要苹果特批权限（自签装不上），
//   改成扫本网段常见 UPnP 端口 + 读 description.xml，认 MediaRenderer。
// - 推送：AirPlay = POST /play（二进制 plist，带 Session-ID 保持连接）；DLNA = AVTransport SetAVTransportURI + Play。
import Foundation
import Network
import UIKit

// MARK: - 设备

struct HGCastTarget: Identifiable, Hashable {
    enum Kind: String { case airplay = "AirPlay", dlna = "DLNA" }
    let kind: Kind
    let name: String
    let host: String
    let port: Int
    /// DLNA：AVTransport 控制地址（完整 URL）
    var control: URL?
    var id: String { "\(kind.rawValue)|\(host)" }
}

// MARK: - 局域网片源

final class HGCastServer: @unchecked Sendable {
    static let shared = HGCastServer()
    private let queue = DispatchQueue(label: "hg.cast.server")
    private var listener: NWListener?
    private var port: UInt16 = 0
    private let lock = NSLock()
    private var file: URL?
    private var path = ""
    private(set) var hits = 0

    /// 发布一个本地文件，返回电视能访问的网址（nil = 没拿到局域网 IP / 监听失败）
    func publish(_ file: URL) async -> URL? {
        guard let ip = Self.wifiIPv4() else { HGTrace.log("cast server 没有 Wi-Fi 地址"); return nil }
        let p = "/v/\(UUID().uuidString.prefix(12).lowercased()).mp4"
        lock.withLock { self.file = file; self.path = p; self.hits = 0 }
        guard let port = await ensureListening() else { return nil }
        return URL(string: "http://\(ip):\(port)\(p)")
    }

    func unpublish() { lock.withLock { file = nil; path = "" } }

    private func ensureListening() async -> UInt16? {
        if listener != nil, port != 0 { return port }
        return await withCheckedContinuation { (c: CheckedContinuation<UInt16?, Never>) in
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                params.requiredInterfaceType = .wifi
                let l = try NWListener(using: params)
                let once = HGOnce()
                l.stateUpdateHandler = { [weak self, weak l] st in
                    guard let self else { return }
                    switch st {
                    case .ready:
                        self.port = l?.port?.rawValue ?? 0
                        HGTrace.log("cast server 监听 :\(self.port)")
                        if once.take() { c.resume(returning: self.port) }
                    case .failed(let e):
                        HGTrace.log("cast server 失败 \(e)")
                        self.listener = nil; self.port = 0
                        if once.take() { c.resume(returning: nil) }
                    default: break
                    }
                }
                l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
                listener = l
                l.start(queue: queue)
            } catch {
                HGTrace.log("cast server 建不起来 \(error)")
                c.resume(returning: nil)
            }
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, err in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if done || err != nil || buf.count > 64 * 1024 { conn.cancel() } else { self.readRequest(conn, buffer: buf) }
                return
            }
            let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
            self.respond(conn, head: head)
        }
    }

    private func respond(_ conn: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let reqPath = parts.count > 1 ? String(parts[1]) : ""
        var range: String?
        for l in lines.dropFirst() where l.lowercased().hasPrefix("range:") {
            range = l.dropFirst(6).trimmingCharacters(in: .whitespaces)
        }
        let (f, p) = lock.withLock { (file, path) }
        guard let f, !p.isEmpty, reqPath == p, method == "GET" || method == "HEAD",
              let attrs = try? FileManager.default.attributesOfItem(atPath: f.path),
              let total = (attrs[.size] as? NSNumber)?.intValue, total > 0 else {
            send(conn, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", body: nil, close: true)
            return
        }
        var start = 0, end = total - 1, partial = false
        if let r = range, r.hasPrefix("bytes=") {
            let spec = r.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
            let se = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            if se.count == 2 {
                if se[0].isEmpty, let n = Int(se[1]) { start = max(0, total - n) }
                else { start = Int(se[0]) ?? 0; if let e = Int(se[1]) { end = min(e, total - 1) } }
                partial = true
            }
        }
        guard start <= end, start < total else {
            send(conn, "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(total)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", body: nil, close: true)
            return
        }
        let len = end - start + 1
        let hits = lock.withLock { self.hits += 1; return self.hits }
        if hits <= 3 || hits % 20 == 0 { HGTrace.log("cast server \(method) #\(hits) \(partial ? "bytes \(start)-\(end)" : "全片") / \(total)") }
        var h = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        h += "Content-Type: video/mp4\r\nAccept-Ranges: bytes\r\nContent-Length: \(len)\r\n"
        if partial { h += "Content-Range: bytes \(start)-\(end)/\(total)\r\n" }
        // DLNA 电视要这个头才肯放
        h += "transferMode.dlna.org: Streaming\r\ncontentFeatures.dlna.org: DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000\r\n"
        h += "Connection: close\r\n\r\n"
        // HEAD：头发完再关（直接 cancel 会把还没发出去的头一起丢掉）
        guard method == "GET", let fh = try? FileHandle(forReadingFrom: f) else { send(conn, h, body: nil, close: true); return }
        send(conn, h, body: nil, close: false)
        try? fh.seek(toOffset: UInt64(start))
        pump(conn, fh, remaining: len)
    }

    /// 一块一块发（每块 256KB，发完一块再读下一块，不把整集读进内存）
    private func pump(_ conn: NWConnection, _ fh: FileHandle, remaining: Int) {
        guard remaining > 0, let chunk = try? fh.read(upToCount: min(256 * 1024, remaining)), !chunk.isEmpty else {
            try? fh.close(); conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in conn.cancel() }); return
        }
        conn.send(content: chunk, completion: .contentProcessed { [weak self] err in
            if err != nil { try? fh.close(); conn.cancel(); return }
            self?.pump(conn, fh, remaining: remaining - chunk.count)
        })
    }

    private func send(_ conn: NWConnection, _ head: String, body: Data?, close: Bool) {
        var d = Data(head.utf8); if let body { d.append(body) }
        conn.send(content: d, completion: .contentProcessed { _ in if close { conn.cancel() } })
    }

    /// Wi-Fi（en0）IPv4
    static func wifiIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cur {
            defer { cur = p.pointee.ifa_next }
            guard let a = p.pointee.ifa_addr, a.pointee.sa_family == sa_family_t(AF_INET),
                  String(cString: p.pointee.ifa_name) == "en0" else { continue }
            var sin = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            let s = String(cString: buf)
            if !s.hasPrefix("169.254") { return s }
        }
        return nil
    }
}

/// 只放行第一次（监听状态回调可能多次进来，continuation 只能 resume 一次）
final class HGOnce: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func take() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

// MARK: - 发现

@MainActor @Observable final class HGCastBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var found: [HGCastTarget] = []
    var scanning = false
    private var browser: NetServiceBrowser?
    private var resolving: [NetService] = []
    private var sweep: Task<Void, Never>?
    /// DLNA 常见端口：小米 49152（实测）；海信 / TCL 多在 49152~49154；乐播 9958；三星 7676；索尼 52323；部分国产盒子 38400
    nonisolated static let dlnaPorts: [UInt16] = [49152, 49153, 49154, 9958, 7676, 52323, 38400]

    func start() {
        stop()
        found = []
        scanning = true
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: "_airplay._tcp.", inDomain: "local.")
        browser = b
        let token = ObjectIdentifier(b)
        sweep = Task { [weak self] in
            let hosts = HGTVScanner.subnetHosts()
            let list = await Self.findDLNA(hosts)
            await MainActor.run {
                guard let self, let cur = self.browser, ObjectIdentifier(cur) == token else { return }
                for t in list { self.add(t) }
                self.scanning = false
                HGTrace.log("cast 发现结束 共 \(self.found.count) 台：\(self.found.map { "\($0.kind.rawValue) \($0.host)" })")
            }
        }
    }

    func stop() {
        browser?.stop(); browser = nil
        resolving.forEach { $0.stop() }; resolving = []
        sweep?.cancel(); sweep = nil
        scanning = false
    }

    private func add(_ t: HGCastTarget) {
        // 同一台电视两种协议都有：两项都列（AirPlay 在前），用户看名字后面的协议标
        if let i = found.firstIndex(where: { $0.id == t.id }) { found[i] = t } else { found.append(t) }
        found.sort { ($0.kind == .airplay ? 0 : 1, $0.name) < ($1.kind == .airplay ? 0 : 1, $1.name) }
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
            var features: UInt64 = 0, model = ""
            if let txt = sender.txtRecordData() {
                let d = NetService.dictionary(fromTXTRecord: txt)
                if let v = d["features"].flatMap({ String(data: $0, encoding: .utf8) }) {
                    let lo = v.split(separator: ",").first.map(String.init) ?? v
                    features = UInt64(lo.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
                }
                model = d["model"].flatMap { String(data: $0, encoding: .utf8) } ?? ""
            }
            // 只要能收视频网址的（features bit0 = Video）；Mac / HomePod / 音箱没有这一位
            guard features & 1 == 1, !model.hasPrefix("AudioAccessory"), !model.hasPrefix("Mac") else { return }
            // 本机名里的「(IP)」后缀去掉，名字更干净
            let name = sender.name.replacingOccurrences(of: #"\s*\(\d+\.\d+\.\d+\.\d+\)$"#, with: "", options: .regularExpression)
            add(HGCastTarget(kind: .airplay, name: name, host: ip, port: sender.port))
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        MainActor.assumeIsolated { resolving.removeAll { $0 === sender } }
    }

    /// 并行扫 /24 × 常见端口：先 TCP 探活，通的再读 description.xml
    nonisolated static func findDLNA(_ hosts: [String]) async -> [HGCastTarget] {
        let pairs = hosts.flatMap { h in dlnaPorts.map { (h, $0) } }
        let candidates = await HGCastProbe.openMany(pairs, timeout: 0.8)
        return await withTaskGroup(of: HGCastTarget?.self) { g in
            for (h, p) in candidates { g.addTask { await describe(h, p) } }
            var out: [HGCastTarget] = []
            for await r in g { if let r, !out.contains(where: { $0.id == r.id }) { out.append(r) } }
            return out
        }
    }

    nonisolated static func describe(_ host: String, _ port: UInt16) async -> HGCastTarget? {
        for path in ["/description.xml", "/dmr/description.xml", "/rootDesc.xml", "/DeviceDescription.xml"] {
            guard let u = URL(string: "http://\(host):\(port)\(path)") else { continue }
            var r = URLRequest(url: u, timeoutInterval: 2.5)
            r.setValue("GuoDuo/1.0 UPnP/1.0", forHTTPHeaderField: "User-Agent")
            guard let (d, resp) = try? await URLSession.shared.data(for: r),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let xml = String(decoding: d, as: UTF8.self)
            guard xml.contains("MediaRenderer"), let ctl = HGDLNA.avTransportControl(xml, base: u) else { continue }
            let name = HGDLNA.tag("friendlyName", in: xml) ?? "电视"
            return HGCastTarget(kind: .dlna, name: name, host: host, port: Int(port), control: ctl)
        }
        return nil
    }
}

enum HGCastProbe {
    /// 一批地址同时探：每批 200 个非阻塞 connect，一次 poll 等齐（254 台 × 7 端口约 7 秒）
    static func openMany(_ pairs: [(String, UInt16)], timeout: Double) async -> [(String, UInt16)] {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                var hits: [(String, UInt16)] = []
                var i = 0
                while i < pairs.count {
                    let batch = Array(pairs[i..<min(i + 200, pairs.count)]); i += batch.count
                    var fds: [Int32] = [], idx: [Int] = []
                    for (k, (h, p)) in batch.enumerated() {
                        let fd = socket(AF_INET, SOCK_STREAM, 0)
                        guard fd >= 0 else { continue }
                        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                        var on: Int32 = 1
                        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                        var a = sockaddr_in()
                        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
                        a.sin_port = p.bigEndian; inet_pton(AF_INET, h, &a.sin_addr)
                        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                        if r == 0 { hits.append((h, p)); close(fd); continue }
                        guard errno == EINPROGRESS else { close(fd); continue }
                        fds.append(fd); idx.append(k)
                    }
                    var pfds = fds.map { pollfd(fd: $0, events: Int16(POLLOUT), revents: 0) }
                    let deadline = Date().addingTimeInterval(timeout)
                    var pending = Set(pfds.indices)
                    while !pending.isEmpty {
                        let left = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
                        if left <= 0 { break }
                        guard poll(&pfds, nfds_t(pfds.count), left) > 0 else { break }
                        for j in pending where pfds[j].revents != 0 {
                            pending.remove(j)
                            var err: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
                            getsockopt(pfds[j].fd, SOL_SOCKET, SO_ERROR, &err, &len)
                            if err == 0 { hits.append(batch[idx[j]]) }
                            pfds[j].events = 0; pfds[j].fd = -1      // 不再等这个
                        }
                    }
                    fds.forEach { close($0) }
                }
                c.resume(returning: hits)
            }
        }
    }

    static func open(_ host: String, port: UInt16, timeout: Double) async -> Bool {
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
}

// MARK: - DLNA

enum HGDLNA {
    static func tag(_ name: String, in xml: String) -> String? {
        guard let r = xml.range(of: "<\(name)>"), let e = xml.range(of: "</\(name)>", range: r.upperBound..<xml.endIndex) else { return nil }
        return String(xml[r.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// description.xml 里 AVTransport 服务的 controlURL（相对地址按 URLBase / 描述文件地址补全）
    static func avTransportControl(_ xml: String, base: URL) -> URL? {
        var rest = xml[...]
        while let s = rest.range(of: "<service>") {
            guard let e = rest.range(of: "</service>", range: s.upperBound..<rest.endIndex) else { break }
            let block = String(rest[s.upperBound..<e.lowerBound])
            rest = rest[e.upperBound...]
            guard (tag("serviceType", in: block) ?? "").contains("AVTransport"), let c = tag("controlURL", in: block) else { continue }
            let root = tag("URLBase", in: xml).flatMap(URL.init(string:)) ?? base
            return URL(string: c, relativeTo: root)?.absoluteURL
        }
        return nil
    }

    static func soap(_ ctl: URL, action: String, args: String) async throws { _ = try await soapResult(ctl, action: action, args: args) }

    static func soapResult(_ ctl: URL, action: String, args: String) async throws -> String {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:\(action) xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID>\(args)</u:\(action)></s:Body>
        </s:Envelope>
        """
        var r = URLRequest(url: ctl, timeoutInterval: 8)
        r.httpMethod = "POST"
        r.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        r.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        r.httpBody = Data(body.utf8)
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if action != "GetPositionInfo" { HGTrace.log("cast dlna \(action) HTTP \(code)") }
        guard code == 200 else {
            let msg = tag("errorDescription", in: String(decoding: d, as: UTF8.self)) ?? "HTTP \(code)"
            throw HGError.message("电视拒绝了（\(action)：\(msg)）")
        }
        return String(decoding: d, as: UTF8.self)
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func time(_ t: Double) -> String {
        let s = max(0, Int(t)); return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

// MARK: - AirPlay（URL 推送，老协议，Apple TV 3 / 仿 Apple TV 的电视都认）

final class HGAirPlayVideo: @unchecked Sendable {
    private let queue = DispatchQueue(label: "hg.cast.airplay")
    private var conn: NWConnection?
    private let session = UUID().uuidString.uppercased()
    private var host = ""
    private var port = 0
    private var waiter: CheckedContinuation<(Int, Data), Error>?
    private var buf = Data()
    private var token: UUID?

    func play(_ url: URL, from: Double, on t: HGCastTarget) async throws {
        host = t.host; port = t.port
        let c = NWConnection(host: NWEndpoint.Host(t.host), port: NWEndpoint.Port(rawValue: UInt16(t.port))!, using: .tcp)
        conn = c
        c.start(queue: queue)
        let body = try PropertyListSerialization.data(fromPropertyList: ["Content-Location": url.absoluteString, "Start-Position": 0.0],
                                                      format: .binary, options: 0)
        let (code, _) = try await request("POST", "/play", body: body, type: "application/x-apple-binary-plist")
        HGTrace.log("cast airplay play HTTP \(code)")
        guard code == 200 else { throw HGError.message("电视拒绝了（HTTP \(code)）") }
        if from > 1 {
            // 等电视读到时长再跳，太早跳会被忽略
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(500))
                if let info = try? await playbackInfo(), (info["duration"] as? Double ?? 0) > 0 { break }
            }
            let (sc, _) = try await request("POST", "/scrub?position=\(String(format: "%.1f", from))")
            HGTrace.log("cast airplay scrub \(Int(from))s HTTP \(sc)")
        }
    }

    func playbackInfo() async throws -> [String: Any] {
        let (_, d) = try await request("GET", "/playback-info")
        return (try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any]) ?? [:]
    }

    func setRate(_ r: Double) async { _ = try? await request("POST", "/rate?value=\(r)") }

    func stop() async {
        _ = try? await request("POST", "/stop")
        conn?.cancel(); conn = nil
    }

    private func request(_ method: String, _ path: String, body: Data = Data(), type: String? = nil) async throws -> (Int, Data) {
        guard let c = conn else { throw HGError.message("没连上电视") }
        var h = "\(method) \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nUser-Agent: AirPlay/320.20\r\nX-Apple-Session-ID: \(session)\r\nContent-Length: \(body.count)\r\n"
        if let type { h += "Content-Type: \(type)\r\n" }
        var d = Data((h + "\r\n").utf8); d.append(body)
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<(Int, Data), Error>) in
            queue.async {
                self.finish(.failure(HGError.message("上一个请求被打断")))   // 不会叠两个在等
                self.waiter = k; self.buf = Data()
                let token = UUID(); self.token = token
                c.send(content: d, completion: .contentProcessed { err in
                    self.queue.async {
                        guard self.token == token else { return }
                        if let err { self.finish(.failure(err)) } else { self.receive(c, token) }
                    }
                })
                self.queue.asyncAfter(deadline: .now() + 8) {
                    if self.token == token { self.finish(.failure(HGError.message("电视没响应"))) }
                }
            }
        }
    }

    private func receive(_ c: NWConnection, _ token: UUID) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, err in
            guard let self, self.token == token else { return }
            if let data { self.buf.append(data) }
            if let end = self.buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: self.buf[..<end.lowerBound], as: UTF8.self)
                let code = Int(head.split(separator: " ").dropFirst().first ?? "") ?? 0
                let len = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
                let bodyStart = end.upperBound
                if self.buf.count - bodyStart >= len {
                    self.finish(.success((code, Data(self.buf[bodyStart..<(bodyStart + len)])))); return
                }
            }
            if done || err != nil { self.finish(.failure(err ?? HGError.message("电视断开了"))); return }
            self.receive(c, token)
        }
    }

    private func finish(_ r: Result<(Int, Data), Error>) {
        guard let w = waiter else { return }
        waiter = nil; token = nil
        w.resume(with: r)
    }
}

// MARK: - 投屏会话

@MainActor @Observable final class HGCastSession {
    static let shared = HGCastSession()
    private(set) var target: HGCastTarget?
    private(set) var title = ""
    /// 电视上放的那集（手机可能已经划到别的视频了）
    private(set) var vid: String?
    var note: String?
    private var airplay: HGAirPlayVideo?

    var active: Bool { target != nil }

    /// 投这一集：等整集解密落地（已缓存就是现成的）→ 发布 → 推给电视
    func cast(vid: String, title: String, from: Double, to t: HGCastTarget) async throws {
        await stop()
        HGTrace.log("cast 开始 \(t.kind.rawValue) \(t.name) \(t.host):\(t.port) vid=\(vid) from=\(Int(from))")
        note = "正在准备视频…"
        let file = try await HGMediaCache.shared.file(for: vid)
        await HGMediaCache.shared.setCastPin(vid)
        guard let url = await HGCastServer.shared.publish(file) else { throw HGError.message("手机没连 Wi-Fi，电视找不到手机") }
        HGTrace.log("cast 片源 \(url.absoluteString)")
        note = "正在连接电视…"
        switch t.kind {
        case .airplay:
            let a = HGAirPlayVideo()
            try await a.play(url, from: from, on: t)
            airplay = a
        case .dlna:
            guard let ctl = t.control else { throw HGError.message("电视没有播放服务") }
            let meta = """
            <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="0" parentID="-1" restricted="1"><dc:title>\(HGDLNA.esc(title))</dc:title><upnp:class>object.item.videoItem</upnp:class><res protocolInfo="http-get:*:video/mp4:DLNA.ORG_OP=01;DLNA.ORG_CI=0">\(HGDLNA.esc(url.absoluteString))</res></item></DIDL-Lite>
            """
            try await HGDLNA.soap(ctl, action: "SetAVTransportURI",
                                  args: "<CurrentURI>\(HGDLNA.esc(url.absoluteString))</CurrentURI><CurrentURIMetaData>\(HGDLNA.esc(meta))</CurrentURIMetaData>")
            try await HGDLNA.soap(ctl, action: "Play", args: "<Speed>1</Speed>")
            if from > 1 {
                try? await Task.sleep(for: .seconds(2))
                try? await HGDLNA.soap(ctl, action: "Seek", args: "<Unit>REL_TIME</Unit><Target>\(HGDLNA.time(from))</Target>")
            }
        }
        target = t; self.title = title; self.vid = vid; note = nil
        HGScreenAwake.set("cast", true)
        HGTrace.log("cast 已推送 \(t.kind.rawValue) \(t.name)")
    }

    func stop() async {
        guard let t = target else { airplay = nil; return }
        HGTrace.log("cast 停止 \(t.kind.rawValue) \(t.name)")
        switch t.kind {
        case .airplay: await airplay?.stop(); airplay = nil
        case .dlna: if let c = t.control { try? await HGDLNA.soap(c, action: "Stop", args: "") }
        }
        HGCastServer.shared.unpublish()
        HGScreenAwake.set("cast", false)
        target = nil; vid = nil; note = nil
        await HGMediaCache.shared.setCastPin(nil)
    }

    /// 电视当前进度（秒）：停止投屏回手机时接着放
    func position() async -> Double? {
        guard let t = target else { return nil }
        switch t.kind {
        case .airplay: return (try? await airplay?.playbackInfo())?["position"] as? Double
        case .dlna:
            guard let c = t.control, let xml = try? await HGDLNA.soapResult(c, action: "GetPositionInfo", args: ""),
                  let rel = HGDLNA.tag("RelTime", in: xml) else { return nil }
            let parts = rel.split(separator: ":").compactMap { Double($0) }
            return parts.count == 3 ? parts[0] * 3600 + parts[1] * 60 + parts[2] : nil
        }
    }
}
