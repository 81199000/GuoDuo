// 极简 ADB 客户端：手机直连电视的 adbd（TCP 5555 老模式），推 APK 安装。不依赖电脑 / adb server。
// 协议：CNXN → AUTH（RSA 签名 token，首次要电视上点「允许」）→ OPEN 流（exec:cmd package install / sync: 推文件）。
// Android 11+ 的「无线调试」（TLS + 配对码）不在这里，后续单独做。
import Foundation
import Network
import Security

enum HGAdbError: LocalizedError {
    case timeout, closed, authRejected
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .timeout: "连接超时，请确认手机和电视在同一个 Wi‑Fi"
        case .closed: "电视断开了连接"
        case .authRejected: "电视拒绝了这台手机的授权，请在电视上选「允许」后重试"
        case .failed(let m): m
        }
    }
}

// MARK: - 密钥

/// 手机端的 ADB 身份：2048 位 RSA，私钥存钥匙串；公钥按 Android 的格式（RSAPublicKey 结构）发给电视。
enum HGAdbKey {
    private static let keychainName = "adb.rsa.private.v1"

    static func privateKey() throws -> SecKey {
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        if let b64 = HGKeychain.get(keychainName), let der = Data(base64Encoded: b64),
           let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil) { return key }
        var err: Unmanaged<CFError>?
        let gen: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        guard let key = SecKeyCreateRandomKey(gen as CFDictionary, &err),
              let der = SecKeyCopyExternalRepresentation(key, &err) as Data? else {
            throw HGAdbError.failed("生成授权密钥失败：\(err?.takeRetainedValue().localizedDescription ?? "未知错误")")
        }
        HGKeychain.set(keychainName, der.base64EncodedString())
        return key
    }

    /// 对电视给的 20 字节 token 签名（adbd 把 token 当作已哈希的 SHA‑1 摘要，PKCS#1 v1.5）。
    static func sign(token: Data) throws -> Data {
        var err: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(try privateKey(), .rsaSignatureDigestPKCS1v15SHA1, token as CFData, &err) as Data? else {
            throw HGAdbError.failed("签名失败：\(err?.takeRetainedValue().localizedDescription ?? "未知错误")")
        }
        return sig
    }

    /// 发给电视 AUTH(RSAPUBLICKEY) 的内容：base64(Android RSAPublicKey 结构) + " 名字\0"
    static func publicKeyPayload() throws -> Data {
        guard let pub = SecKeyCopyPublicKey(try privateKey()),
              let der = SecKeyCopyExternalRepresentation(pub, nil) as Data? else { throw HGAdbError.failed("读取公钥失败") }
        let (n, e) = try parsePKCS1(der)
        var blob = Data()
        let words = 64
        blob.appendLE(UInt32(words))
        let nw = toWords(n, count: words)
        blob.appendLE(montInv(nw[0]))
        nw.forEach { blob.appendLE($0) }
        rrWords(n: nw).forEach { blob.appendLE($0) }
        blob.appendLE(e.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        var out = Data(blob.base64EncodedString().utf8)
        out.append(contentsOf: Array(" guoduo@ios\u{0}".utf8))
        return out
    }

    // PKCS#1 RSAPublicKey = SEQUENCE { INTEGER n, INTEGER e }
    private static func parsePKCS1(_ der: Data) throws -> (n: [UInt8], e: [UInt8]) {
        let b = [UInt8](der)
        var i = 0
        func len() throws -> Int {
            guard i < b.count else { throw HGAdbError.failed("公钥格式错误") }
            let f = Int(b[i]); i += 1
            if f < 0x80 { return f }
            let k = f & 0x7f
            guard k > 0, k <= 4, i + k <= b.count else { throw HGAdbError.failed("公钥格式错误") }
            var v = 0; for _ in 0..<k { v = (v << 8) | Int(b[i]); i += 1 }
            return v
        }
        func integer() throws -> [UInt8] {
            guard i < b.count, b[i] == 0x02 else { throw HGAdbError.failed("公钥格式错误") }
            i += 1
            let l = try len()
            guard i + l <= b.count else { throw HGAdbError.failed("公钥格式错误") }
            var v = Array(b[i..<(i + l)]); i += l
            while v.count > 1, v[0] == 0 { v.removeFirst() }
            return v
        }
        guard !b.isEmpty, b[0] == 0x30 else { throw HGAdbError.failed("公钥格式错误") }
        i = 1; _ = try len()
        let n = try integer(), e = try integer()
        guard n.count == 256 else { throw HGAdbError.failed("公钥长度不是 2048 位") }
        return (n, e)
    }

    /// 大端字节 → 小端 32 位字数组（低位字在前）
    private static func toWords(_ be: [UInt8], count: Int) -> [UInt32] {
        var padded = [UInt8](repeating: 0, count: max(0, count * 4 - be.count)) + be
        padded = Array(padded.suffix(count * 4))
        return (0..<count).map { w in
            let o = padded.count - 4 * (w + 1)
            return (UInt32(padded[o]) << 24) | (UInt32(padded[o + 1]) << 16) | (UInt32(padded[o + 2]) << 8) | UInt32(padded[o + 3])
        }
    }

    /// n0inv = -(n[0]^-1) mod 2^32（牛顿迭代求逆）
    static func montInv(_ n0: UInt32) -> UInt32 {
        var x = n0
        for _ in 0..<5 { x = x &* (2 &- n0 &* x) }
        return 0 &- x
    }

    /// rr = 2^(2·2048) mod n：从 1 开始左移 4096 次，每次超过 n 就减 n。
    static func rrWords(n: [UInt32]) -> [UInt32] {
        let m = n + [0]
        var r = [UInt32](repeating: 0, count: m.count); r[0] = 1
        for _ in 0..<(n.count * 32 * 2) {
            var carry: UInt32 = 0
            for k in 0..<r.count { let nc = r[k] >> 31; r[k] = (r[k] << 1) | carry; carry = nc }
            var ge = true
            for k in stride(from: r.count - 1, through: 0, by: -1) where r[k] != m[k] { ge = r[k] > m[k]; break }
            if ge {
                var borrow: UInt64 = 0
                for k in 0..<r.count {
                    let d = UInt64(r[k]) &- UInt64(m[k]) &- borrow
                    r[k] = UInt32(truncatingIfNeeded: d); borrow = (d >> 63) & 1
                }
            }
        }
        return Array(r.prefix(n.count))
    }
}

// MARK: - 传输

private extension Data {
    mutating func appendLE(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    func le32(_ o: Int) -> UInt32 {
        let s = startIndex + o
        return UInt32(self[s]) | (UInt32(self[s + 1]) << 8) | (UInt32(self[s + 2]) << 16) | (UInt32(self[s + 3]) << 24)
    }
}

final class HGAdbTransport: @unchecked Sendable {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "me.rrmm.hongguo.adb")
    private var pending = Data()
    private var timedOut = false
    private var deadline: DispatchWorkItem?
    let host: String

    init(host: String, port: UInt16) {
        self.host = host
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 6
        let p = NWParameters(tls: nil, tcp: tcp)
        if let ip = p.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 5555, using: p)
    }

    /// 连接状态在 queue（串行）上读写，盒子只是让闭包能共享它
    private final class ConnectState: @unchecked Sendable { var done = false; var grace: DispatchWorkItem? }

    func connect() async throws {
        let st = ConnectState()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            @Sendable func finish(_ r: Result<Void, Error>) {
                guard !st.done else { return }
                st.done = true; st.grace?.cancel()
                c.resume(with: r)
            }
            conn.stateUpdateHandler = { [weak self] state in
                guard let self, !st.done else { return }
                switch state {
                case .ready: finish(.success(()))
                case .failed: finish(.failure(HGAdbError.failed("连不上 \(self.host)，请确认电视已开启 ADB 调试且在同一个 Wi‑Fi")))
                case .waiting:
                    // 端口拒绝 / 没有本地网络权限都会停在 waiting 反复重试；给 4 秒宽限（首次授权弹窗），不行就报错
                    if st.grace == nil {
                        let w = DispatchWorkItem { [weak self] in
                            guard let self, !st.done else { return }
                            self.conn.cancel()
                            finish(.failure(HGAdbError.failed("连不上 \(self.host)：电视没开 ADB 调试，或手机没有「本地网络」权限")))
                        }
                        st.grace = w; self.queue.asyncAfter(deadline: .now() + 4, execute: w)
                    }
                case .cancelled: finish(.failure(HGAdbError.closed))
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }

    /// 超时后直接掐断连接，正在等的读写会立刻报错（映射成 .timeout）
    func arm(_ seconds: Double) {
        disarm()
        let w = DispatchWorkItem { [weak self] in self?.timedOut = true; self?.conn.cancel() }
        deadline = w
        queue.asyncAfter(deadline: .now() + seconds, execute: w)
    }
    func disarm() { deadline?.cancel(); deadline = nil }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { [weak self] e in
                if e != nil { c.resume(throwing: self?.timedOut == true ? HGAdbError.timeout : HGAdbError.closed) } else { c.resume() }
            })
        }
    }

    func receive(exactly n: Int) async throws -> Data {
        while pending.count < n {
            let chunk: Data = try await withCheckedThrowingContinuation { c in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, _, error in
                    if error == nil, let data, !data.isEmpty { c.resume(returning: data) }
                    else { c.resume(throwing: self?.timedOut == true ? HGAdbError.timeout : HGAdbError.closed) }
                }
            }
            pending.append(chunk)
        }
        let out = Data(pending.prefix(n))
        pending.removeFirst(n)
        return out
    }

    func close() { disarm(); conn.cancel() }
}

// MARK: - 会话

struct HGAdbDeviceInfo {
    var model = "", name = "", features = Set<String>()
    var title: String { model.isEmpty ? (name.isEmpty ? "安卓设备" : name) : model.replacingOccurrences(of: "_", with: " ") }
}

final class HGAdbStream {
    let local: UInt32, remote: UInt32
    var closed = false
    var inbox = Data()
    init(local: UInt32, remote: UInt32) { self.local = local; self.remote = remote }
}

final class HGAdbSession {
    private enum C {
        static let CNXN: UInt32 = 0x4e584e43, AUTH: UInt32 = 0x48545541, OPEN: UInt32 = 0x4e45504f
        static let OKAY: UInt32 = 0x59414b4f, CLSE: UInt32 = 0x45534c43, WRTE: UInt32 = 0x45545257
    }
    private struct Msg { var cmd: UInt32, a0: UInt32, a1: UInt32, data: Data }

    private let t: HGAdbTransport
    private var maxData = 4096
    private var nextLocal: UInt32 = 1
    private(set) var info = HGAdbDeviceInfo()

    init(host: String, port: UInt16 = 5555) { t = HGAdbTransport(host: host, port: port) }
    func close() { t.close() }

    // 报文 -----------------------------------------------------------------
    private func send(_ cmd: UInt32, _ a0: UInt32, _ a1: UInt32, _ data: Data = Data()) async throws {
        var m = Data(capacity: 24 + data.count)
        let sum = data.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        for v in [cmd, a0, a1, UInt32(data.count), sum, cmd ^ 0xFFFF_FFFF] { m.appendLE(v) }
        m.append(data)
        try await t.send(m)
    }

    private func read() async throws -> Msg {
        let h = try await t.receive(exactly: 24)
        let cmd = h.le32(0), a0 = h.le32(4), a1 = h.le32(8), len = Int(h.le32(12))
        guard h.le32(20) == cmd ^ 0xFFFF_FFFF, len <= 16 << 20 else { throw HGAdbError.failed("电视返回了无法识别的数据，可能不是 ADB 端口") }
        return Msg(cmd: cmd, a0: a0, a1: a1, data: len > 0 ? try await t.receive(exactly: len) : Data())
    }

    // 握手 + 授权 ------------------------------------------------------------
    /// `onApproval`：首次连接，电视正在弹「允许 USB 调试」，等用户点。
    func connect(onApproval: @escaping @Sendable () -> Void) async throws {
        t.arm(8)
        defer { t.disarm() }
        try await t.connect()
        try await send(C.CNXN, 0x0100_0001, 256 * 1024, Data("host::\u{0}".utf8))
        var signed = false, keySent = false
        while true {
            let m = try await read()
            switch m.cmd {
            case C.CNXN:
                maxData = max(4096, min(Int(m.a1), 1 << 20))
                parseBanner(String(decoding: m.data, as: UTF8.self))
                return
            case C.AUTH where m.a0 == 1:
                if !signed {
                    signed = true
                    try await send(C.AUTH, 2, 0, try HGAdbKey.sign(token: m.data))
                } else if !keySent {
                    keySent = true
                    try await send(C.AUTH, 3, 0, try HGAdbKey.publicKeyPayload())
                    onApproval()
                    t.arm(90)   // 等用户在电视上点允许
                } else {
                    throw HGAdbError.authRejected
                }
            case C.CLSE: throw HGAdbError.closed
            default: continue
            }
        }
    }

    private func parseBanner(_ s: String) {
        // device::ro.product.name=x;ro.product.model=y;ro.product.device=z;features=a,b,c
        let body = s.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).last.map(String.init) ?? s
        for part in body.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .controlCharacters) }
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "ro.product.model": info.model = kv[1]
            case "ro.product.name": info.name = kv[1]
            case "features": info.features = Set(kv[1].split(separator: ",").map(String.init))
            default: break
            }
        }
    }

    // 流 -------------------------------------------------------------------
    private func open(_ service: String) async throws -> HGAdbStream {
        let local = nextLocal; nextLocal += 1
        try await send(C.OPEN, local, 0, Data((service + "\u{0}").utf8))
        while true {
            let m = try await read()
            if m.cmd == C.OKAY, m.a1 == local { return HGAdbStream(local: local, remote: m.a0) }
            if m.cmd == C.CLSE, m.a1 == local { throw HGAdbError.failed("电视拒绝了这个操作（\(service.prefix(24))）") }
        }
    }

    /// 处理一条来自电视的报文；返回 true 表示收到了 OKAY。
    private func pump(_ s: HGAdbStream) async throws -> Bool {
        let m = try await read()
        guard m.a1 == s.local else { return false }
        switch m.cmd {
        case C.OKAY: return true
        case C.WRTE:
            s.inbox.append(m.data)
            try await send(C.OKAY, s.local, s.remote)
        case C.CLSE: s.closed = true
        default: break
        }
        return false
    }

    private func write(_ s: HGAdbStream, _ data: Data) async throws {
        var off = 0
        while off < data.count {
            let end = min(off + maxData, data.count)
            try await send(C.WRTE, s.local, s.remote, data.subdata(in: off..<end))
            while true {
                if try await pump(s) { break }
                if s.closed { throw HGAdbError.closed }
            }
            off = end
        }
    }

    private func readToClose(_ s: HGAdbStream) async throws -> String {
        while !s.closed { _ = try await pump(s) }
        return String(decoding: s.inbox, as: UTF8.self)
    }

    private func readExactly(_ s: HGAdbStream, _ n: Int) async throws -> Data {
        while s.inbox.count < n {
            if s.closed { throw HGAdbError.closed }
            _ = try await pump(s)
        }
        let out = Data(s.inbox.prefix(n)); s.inbox.removeFirst(n)
        return out
    }

    func shell(_ cmd: String, timeout: Double = 20) async throws -> String {
        t.arm(timeout); defer { t.disarm() }
        return try await readToClose(try await open("shell:\(cmd)"))
    }

    // 安装 ------------------------------------------------------------------
    /// 推 APK 安装。`progress` 0…1 是推送进度。电视有 `cmd` 就直接流式灌给 `cmd package install`，没有（老电视）先推到 /data/local/tmp 再 pm install。
    func install(apk: Data, progress: @escaping @Sendable (Double) -> Void) async throws {
        t.arm(180); defer { t.disarm() }
        if info.features.contains("cmd") {
            let out = try await installViaCmd(apk, progress)
            if out.contains("Success") { return }
            if !out.contains("not found") && !out.contains("Can't find service") { throw HGAdbError.failed(Self.friendly(out)) }
        }
        let out = try await installViaPush(apk, progress)
        if !out.contains("Success") { throw HGAdbError.failed(Self.friendly(out)) }
    }

    private func installViaCmd(_ apk: Data, _ progress: @Sendable (Double) -> Void) async throws -> String {
        let s = try await open("exec:cmd package install -r -S \(apk.count)")
        let chunk = min(maxData, 64 * 1024)
        var off = 0
        do {
            while off < apk.count {
                let end = min(off + chunk, apk.count)
                try await write(s, apk.subdata(in: off..<end))
                off = end
                progress(Double(off) / Double(apk.count))
            }
        } catch HGAdbError.closed where s.closed {
            // 电视中途关流 = 安装提前失败，报错文字在 inbox 里
            return String(decoding: s.inbox, as: UTF8.self)
        }
        return try await readToClose(s)
    }

    private func installViaPush(_ apk: Data, _ progress: @Sendable (Double) -> Void) async throws -> String {
        let path = "/data/local/tmp/guoduo-tv.apk"
        let s = try await open("sync:")
        var head = Data("SEND".utf8)
        let spec = Data("\(path),33206".utf8)
        head.appendLE(UInt32(spec.count)); head.append(spec)
        try await write(s, head)
        var off = 0
        while off < apk.count {
            let end = min(off + 64 * 1024, apk.count)
            var f = Data("DATA".utf8); f.appendLE(UInt32(end - off)); f.append(apk.subdata(in: off..<end))
            try await write(s, f)
            off = end
            progress(Double(off) / Double(apk.count))
        }
        var done = Data("DONE".utf8); done.appendLE(UInt32(Date().timeIntervalSince1970)); try await write(s, done)
        let r = try await readExactly(s, 8)
        if String(decoding: r.prefix(4), as: UTF8.self) != "OKAY" { throw HGAdbError.failed("把安装包推到电视失败（电视存储空间不足或没有写入权限）") }
        var quit = Data("QUIT".utf8); quit.appendLE(0); try? await write(s, quit)
        let out = try await shell("pm install -r \(path); rm -f \(path)", timeout: 120)
        return out
    }

    /// `pm` 的英文报错翻成人话
    static func friendly(_ out: String) -> String {
        let o = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if o.contains("UPDATE_INCOMPATIBLE") || o.contains("SIGNATURE") { return "电视上已装的 GuoDuo TV 签名不同，请先在电视上卸载旧版再安装" }
        if o.contains("INSUFFICIENT_STORAGE") { return "电视存储空间不足" }
        if o.contains("VERSION_DOWNGRADE") { return "电视上已经是更新的版本" }
        if o.contains("NO_MATCHING_ABIS") { return "这个安装包不支持你的电视 CPU" }
        if o.contains("OLDER_SDK") { return "电视系统太老，装不了这个版本" }
        return o.isEmpty ? "安装没有返回结果" : "安装失败：\(o.prefix(160))"
    }
}
