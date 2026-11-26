import Foundation
import JavaScriptCore

/// 在 JavaScriptCore 里跑上游红果核心（签名 / 设备注册 / 目录 / 搜索 / 取源）。
/// 所有 JS 调用都串行在 `queue` 上；Native.* 桥与安卓版同名同语义。
final class HGCore: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = HGCore()

    private let queue = DispatchQueue(label: "hg.core.js")
    private var context: JSContext!
    private var callSeq = 0
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private var tasks: [Int: URLSessionTask] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    var log: (String) -> Void = { print("[HG]", $0) }

    private override init() {
        super.init()
        queue.sync { self.boot() }
    }

    private func boot() {
        let ctx = JSContext()!
        ctx.exceptionHandler = { [weak self] _, value in self?.log("JS 异常: \(value?.toString() ?? "?")") }
        let native = JSValue(newObjectIn: ctx)!
        func def(_ name: String, _ block: Any) { native.setObject(block, forKeyedSubscript: name as NSString) }
        let b64 = { (s: String) in Data(base64Encoded: s) ?? Data() }

        def("log", { [weak self] (s: String) in
            self?.log(s)
            // 发评论、取源的结果落到真机日志，方便拉回来看（不含 cookie / 密钥 / 地址）
            if s.hasPrefix("comment/") || s.hasPrefix("source ") { HGTrace.log(s) }
        } as @convention(block) (String) -> Void)
        def("timer", { [weak self] (id: Int, ms: Double) in
            self?.queue.asyncAfter(deadline: .now() + ms / 1000) {
                self?.context.objectForKeyedSubscript("__timerFire")?.call(withArguments: [id])
            }
        } as @convention(block) (Int, Double) -> Void)
        def("random", { (n: Int) in HGNativeCrypto.random(n).base64EncodedString() } as @convention(block) (Int) -> String)
        def("digest", { [weak self] (alg: String, data: String) -> String? in
            self?.guarded { try HGNativeCrypto.digest(alg, b64(data)).base64EncodedString() }
        } as @convention(block) (String, String) -> String?)
        def("crypt", { [weak self] (decrypt: Bool, alg: String, key: String, iv: String, padding: Bool, data: String) -> String? in
            self?.guarded { try HGNativeCrypto.crypt(decrypt: decrypt, algorithm: alg, key: b64(key), iv: b64(iv), padding: padding, data: b64(data)).base64EncodedString() }
        } as @convention(block) (Bool, String, String, String, Bool, String) -> String?)
        def("gzip", { [weak self] (data: String) -> String? in
            self?.guarded { try HGNativeCrypto.gzip(b64(data)).base64EncodedString() }
        } as @convention(block) (String) -> String?)
        def("gunzip", { [weak self] (data: String, limit: Int) -> String? in
            self?.guarded { try HGNativeCrypto.gunzip(b64(data), limit: min(limit, 2 * 1024 * 1024)).base64EncodedString() }
        } as @convention(block) (String, Int) -> String?)
        def("request", { [weak self] (id: Int, raw: String) in self?.request(id: id, raw: raw) } as @convention(block) (Int, String) -> Void)
        def("cancel", { [weak self] (id: Int) in self?.tasks.removeValue(forKey: id)?.cancel() } as @convention(block) (Int) -> Void)
        def("kvGet", { (k: String) -> String? in HGKeychain.get(k) } as @convention(block) (String) -> String?)
        def("kvSet", { (k: String, v: String) in HGKeychain.set(k, v) } as @convention(block) (String, String) -> Void)
        def("kvDel", { (k: String) in HGKeychain.delete(k) } as @convention(block) (String) -> Void)
        def("done", { [weak self] (callId: Int, json: String) in self?.finish(callId: callId, json: json) } as @convention(block) (Int, String) -> Void)
        ctx.setObject(native, forKeyedSubscript: "Native" as NSString)

        guard let url = Bundle.main.url(forResource: "hgcore", withExtension: "js") ?? HGCore.overrideScript,
              let script = try? String(contentsOf: url, encoding: .utf8) else { log("找不到 hgcore.js"); return }
        context = ctx
        ctx.evaluateScript(script, withSourceURL: url)
    }

    /// 命令行自测时指定 hgcore.js 路径（App 内走 Bundle）。
    nonisolated(unsafe) static var overrideScript: URL?

    /// Native 原语出错时抛回 JS（JS 侧 try/catch 能接住）。
    private func guarded(_ body: () throws -> String) -> String? {
        do { return try body() } catch {
            context.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: context)
            return nil
        }
    }

    // MARK: - 网络（对应 shims/transport.js）

    private func request(id: Int, raw: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let urlString = obj["url"] as? String, let url = URL(string: urlString), url.scheme == "https" else {
            reply(id, ["error": "请求地址无效", "code": "ERR_NETWORK"]); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = (obj["method"] as? String) ?? "GET"
        req.timeoutInterval = max(0.5, min(30, ((obj["timeout"] as? Double) ?? 15000) / 1000))
        for (k, v) in (obj["headers"] as? [String: Any]) ?? [:] {
            if ["host", "connection", "accept-encoding", "content-length"].contains(k.lowercased()) { continue }
            req.setValue("\(v)", forHTTPHeaderField: k)
        }
        if req.httpMethod == "POST", let body = obj["body"] as? String { req.httpBody = Data(base64Encoded: body) }
        let task = session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                guard self.tasks.removeValue(forKey: id) != nil else { return } // 已取消
                if let error = error as NSError? {
                    let timed = error.code == NSURLErrorTimedOut
                    self.reply(id, ["error": timed ? "网络超时，请重试" : "网络请求失败，请检查网络后重试", "code": timed ? "ETIMEDOUT" : "ERR_NETWORK"])
                    return
                }
                let http = response as? HTTPURLResponse
                var headers: [String: Any] = [:]
                if let loc = http?.value(forHTTPHeaderField: "Location") { headers["location"] = loc }
                // URLSession 把多条 Set-Cookie 合并成一行，按 HTTPCookie 拆开还原成 name=value。
                if let http, let fields = http.allHeaderFields as? [String: String],
                   fields.keys.contains(where: { $0.caseInsensitiveCompare("Set-Cookie") == .orderedSame }) {
                    headers["set-cookie"] = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).map { "\($0.name)=\($0.value)" }
                }
                let status = http?.statusCode ?? 0
                let payload = (200..<300).contains(status) ? (data ?? Data()) : Data()
                let body = obj["binary"] as? Bool == true ? payload.base64EncodedString() : String(decoding: payload, as: UTF8.self)
                self.reply(id, ["status": status, "headers": headers, "data": body])
            }
        }
        tasks[id] = task
        task.resume()
    }

    /// 签名绑定最终 URL：一律不自动跟随跳转，交给 JS 判断。
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    private func reply(_ id: Int, _ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        context.objectForKeyedSubscript("__nativeResponse")?.call(withArguments: [id, String(decoding: data, as: UTF8.self)])
    }

    // MARK: - 调用 JS 导出的 HG.*

    private func finish(callId: Int, json: String) {
        guard let cont = pending.removeValue(forKey: callId) else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            cont.resume(throwing: HGError.message("核心返回无效数据")); return
        }
        if obj["ok"] as? Bool == true { cont.resume(returning: obj["value"] ?? NSNull()) }
        else {
            let e = obj["error"] as? [String: Any]
            cont.resume(throwing: HGError.js((e?["message"] as? String) ?? "未知错误", code: (e?["code"] as? String) ?? ""))
        }
    }

    func call(_ method: String, _ args: [Any]) async throws -> Any {
        let callId: Int = queue.sync { callSeq += 1; return callSeq }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                queue.async {
                    guard let hg = self.context?.objectForKeyedSubscript("HG"), !hg.isUndefined else {
                        cont.resume(throwing: HGError.message("核心未加载")); return
                    }
                    self.pending[callId] = cont
                    hg.invokeMethod(method, withArguments: [callId] + args)
                }
            }
        } onCancel: {
            self.queue.async { self.context?.objectForKeyedSubscript("HG")?.invokeMethod("cancel", withArguments: [callId]) }
        }
    }

    func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
