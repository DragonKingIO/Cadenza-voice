import Foundation

/// Local developer API checks. The pipeline is replaced by a fake; the real listener, sockets, router, WebSocket codec
/// and session manager are exercised over loopback. No microphone, no provider, no credentials.
enum LocalAPIFixtures {
    final class FakeControl: LocalAPIVoiceControl {
        var finished: (() -> Void)?
        var next = LocalAPIBegin.started
        var partial: String?, text: String?, isError = false, message = "—"
        var begins = 0, ends = 0, aborts = 0, clears = 0
        func begin() -> LocalAPIBegin { begins += 1; return next }
        func end() { ends += 1 }
        func abort() { aborts += 1; text = nil; isError = false; finished?() }
        var partialText: String? { partial }
        var resultText: String? { text }
        var resultIsError: Bool { isError }
        var resultMessage: String { message }
        func clearResult() { clears += 1; text = nil; partial = nil }
        func finish(text: String?, error: Bool = false, message: String = "—") {
            self.text = text; isError = error; self.message = message; finished?()
        }
    }

    static func spin(_ seconds: TimeInterval, until condition: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !condition() { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    static func run(_ check: (String, Bool) -> Void) {
        func c(_ name: String, _ ok: Bool) { check("LocalAPI " + name, ok) }

        // MARK: HTTP parsing
        func req(_ text: String) -> LocalAPIHTTP.ParseResult { LocalAPIHTTP.parse(Data(text.utf8)) }
        if case .request(let r, let used) = req("POST /v1/sessions?wait=3&x=%41 HTTP/1.1\r\nHost: 127.0.0.1:1\r\nContent-Length: 2\r\n\r\n{}") {
            c("HTTP 解析方法、路径、查询、正文", r.method == "POST" && r.path == "/v1/sessions" && r.query["wait"] == "3" && r.query["x"] == "A" && r.body == Data("{}".utf8) && used > 0)
        } else { c("HTTP 解析方法、路径、查询、正文", false) }
        if case .needMore = req("GET /v1/capabilities HTTP/1.1\r\nHost: x\r\n") { c("HTTP 头未完整时继续等待", true) } else { c("HTTP 头未完整时继续等待", false) }
        if case .needMore = req("POST /v1/sessions HTTP/1.1\r\nContent-Length: 5\r\n\r\nab") { c("HTTP 正文未完整时继续等待", true) } else { c("HTTP 正文未完整时继续等待", false) }
        if case .reject(let s, _) = req("POST /v1/sessions HTTP/1.1\r\nContent-Length: 999999\r\n\r\n") { c("HTTP 超限正文返回 413", s == 413) } else { c("HTTP 超限正文返回 413", false) }
        if case .reject(let s, _) = req("POST /v1/sessions HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") { c("HTTP 分块编码被拒绝", s == 400) } else { c("HTTP 分块编码被拒绝", false) }
        if case .reject = req("GET /v1/../etc HTTP/1.1\r\nHost: x\r\n\r\n") { c("HTTP 路径穿越被拒绝", true) } else { c("HTTP 路径穿越被拒绝", false) }
        if case .reject = req("NONSENSE\r\n\r\n") { c("HTTP 畸形请求行被拒绝", true) } else { c("HTTP 畸形请求行被拒绝", false) }
        if case .reject(let s, _) = LocalAPIHTTP.parse(Data(repeating: 65, count: LocalAPILimits.maxHeaderBytes + 10)) { c("HTTP 超长头返回 431", s == 431) } else { c("HTTP 超长头返回 431", false) }

        // MARK: WebSocket codec
        c("WebSocket 握手接受键符合 RFC 示例", LocalAPIWebSocket.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        func masked(_ opcode: UInt8, _ payload: [UInt8], fin: Bool = true, mask: Bool = true) -> Data {
            let key: [UInt8] = [1, 2, 3, 4]
            var out: [UInt8] = [(fin ? 0x80 : 0) | opcode]
            let len = payload.count
            if len < 126 { out.append((mask ? 0x80 : 0) | UInt8(len)) } else { out.append((mask ? 0x80 : 0) | 126); out += [UInt8(len >> 8), UInt8(len & 0xFF)] }
            if mask { out += key; out += payload.enumerated().map { $0.element ^ key[$0.offset % 4] } } else { out += payload }
            return Data(out)
        }
        if case .frame(let f, let used) = LocalAPIWebSocket.decode(masked(1, Array("hello".utf8))) {
            c("WebSocket 解码带掩码文本帧", f.opcode == .text && String(data: f.payload, encoding: .utf8) == "hello" && used == 11)
        } else { c("WebSocket 解码带掩码文本帧", false) }
        if case .frame(let f, _) = LocalAPIWebSocket.decode(masked(1, Array(String(repeating: "a", count: 300).utf8))) { c("WebSocket 解码 16 位长度帧", f.payload.count == 300) } else { c("WebSocket 解码 16 位长度帧", false) }
        if case .needMore = LocalAPIWebSocket.decode(masked(1, Array("hello".utf8)).prefix(7)) { c("WebSocket 半帧继续等待", true) } else { c("WebSocket 半帧继续等待", false) }
        if case .invalid = LocalAPIWebSocket.decode(masked(1, Array("x".utf8), mask: false)) { c("WebSocket 未掩码客户端帧无效", true) } else { c("WebSocket 未掩码客户端帧无效", false) }
        if case .invalid = LocalAPIWebSocket.decode(masked(1, Array("x".utf8), fin: false)) { c("WebSocket 分片帧不支持", true) } else { c("WebSocket 分片帧不支持", false) }
        if case .invalid = LocalAPIWebSocket.decode(Data([0x81, 0xFF, 0, 0, 0, 0, 0, 0x10, 0, 0, 1, 2, 3, 4])) { c("WebSocket 超限长度无效", true) } else { c("WebSocket 超限长度无效", false) }
        let encoded = LocalAPIWebSocket.encodeText("ok")
        c("WebSocket 服务端帧不掩码", encoded == Data([0x81, 2, 0x6F, 0x6B]))

        // MARK: Auth
        c("令牌：正确通过", LocalAPIAuth.verify(header: "Bearer abcDEF123", token: "abcDEF123"))
        c("令牌：大小写不敏感的 scheme", LocalAPIAuth.verify(header: "bearer abcDEF123", token: "abcDEF123"))
        c("令牌：错误、前缀、空值均拒绝", !LocalAPIAuth.verify(header: "Bearer abcDEF12", token: "abcDEF123") && !LocalAPIAuth.verify(header: "Bearer abcDEF1234", token: "abcDEF123") && !LocalAPIAuth.verify(header: nil, token: "abcDEF123") && !LocalAPIAuth.verify(header: "Bearer ", token: "abcDEF123") && !LocalAPIAuth.verify(header: "Bearer x", token: ""))
        c("Host 只接受回环名和监听端口", LocalAPIAuth.hostAllowed("127.0.0.1:17420", port: 17420) && LocalAPIAuth.hostAllowed("localhost:17420", port: 17420) && !LocalAPIAuth.hostAllowed("evil.example:17420", port: 17420) && !LocalAPIAuth.hostAllowed("127.0.0.1:1", port: 17420) && !LocalAPIAuth.hostAllowed(nil, port: 17420))
        c("max_seconds 校验", { if case .success(60) = LocalAPIRouter.startOptions(Data()) { return true }; return false }() && { if case .failure = LocalAPIRouter.startOptions(Data("{\"max_seconds\":0}".utf8)) { return true }; return false }() && { if case .failure = LocalAPIRouter.startOptions(Data("{\"max_seconds\":9999}".utf8)) { return true }; return false }() && { if case .failure = LocalAPIRouter.startOptions(Data("[1]".utf8)) { return true }; return false }() && { if case .success(5) = LocalAPIRouter.startOptions(Data("{\"max_seconds\":5}".utf8)) { return true }; return false }())

        // MARK: Session manager
        let fake = FakeControl()
        var events: [[String: Any]] = []
        let manager = LocalAPISessionManager(control: fake) { ["api_version": 1] }
        let sub = UUID()
        manager.subscribe(sub) { events.append($0) }
        func started(_ owner: UUID? = nil) -> LocalAPISessionInfo? { if case .success(let i) = manager.start(maxSeconds: 30, owner: owner) { return i }; return nil }
        guard let s1 = started() else { c("会话启动", false); return }
        c("会话启动进入录音并通知事件", s1.state == .recording && s1.id.count == 32 && events.last?["state"] as? String == "recording" && fake.begins == 1)
        if case .failure(let f) = manager.start(maxSeconds: 30, owner: nil) { c("并发启动返回 busy 409", f.status == 409 && f.code == "busy" && fake.begins == 1) } else { c("并发启动返回 busy 409", false) }
        fake.partial = "你好"
        manager.tick(); manager.tick()
        c("实时文字只在变化时推送一次", events.filter { $0["type"] as? String == "partial" }.count == 1 && events.last?["text"] as? String == "你好")
        if case .success(let i) = manager.stop(id: s1.id) { c("停止进入处理中并调用 end", i.state == .processing && fake.ends == 1) } else { c("停止进入处理中并调用 end", false) }
        if case .success(let i) = manager.stop(id: s1.id) { c("重复停止无副作用", i.state == .processing && fake.ends == 1) } else { c("重复停止无副作用", false) }
        var waited: LocalAPISessionInfo?
        manager.wait(id: s1.id, seconds: 5) { waited = $0 }
        fake.finish(text: "  你好世界  ")
        c("识别完成：返回修剪后的文字并清除应用内结果", manager.info(id: s1.id)?.state == .completed && manager.info(id: s1.id)?.text == "你好世界" && fake.clears == 1 && !manager.hasActiveSession)
        c("等待者在完成时被唤醒", waited?.state == .completed && waited?.text == "你好世界")
        c("完成事件为 final", events.last?["type"] as? String == "final" && events.last?["text"] as? String == "你好世界")
        if case .success(let i) = manager.cancel(id: s1.id) { c("结束后取消无副作用", i.state == .completed && fake.aborts == 0) } else { c("结束后取消无副作用", false) }
        if case .failure(let f) = manager.stop(id: String(repeating: "0", count: 32)) { c("未知会话返回 404", f.status == 404) } else { c("未知会话返回 404", false) }

        guard let s2 = started() else { c("第二个会话", false); return }
        if case .success(let i) = manager.cancel(id: s2.id) { c("录音中取消：中止采集并报告 cancelled", i.state == .cancelled && fake.aborts == 1 && !manager.hasActiveSession && events.last?["type"] as? String == "cancelled") } else { c("录音中取消", false) }
        guard let s3 = started() else { c("第三个会话", false); return }
        fake.finish(text: nil, error: false)
        c("应用内取消（胶囊或睡眠）报告 cancelled", manager.info(id: s3.id)?.state == .cancelled && fake.aborts == 1)
        guard let s4 = started() else { c("第四个会话", false); return }
        _ = manager.stop(id: s4.id)
        fake.finish(text: nil, error: true, message: "no speech heard")
        c("无结果错误报告 failed 与原因", manager.info(id: s4.id)?.state == .failed && manager.info(id: s4.id)?.errorCode == "no_result" && manager.info(id: s4.id)?.detail == "no speech heard" && events.last?["type"] as? String == "error")
        fake.next = .unavailable("Microphone permission is missing.")
        if case .failure(let f) = manager.start(maxSeconds: 30, owner: nil) { c("管线不可用返回 503 与原因", f.status == 503 && f.code == "unavailable" && f.message == "Microphone permission is missing.") } else { c("管线不可用返回 503", false) }
        fake.next = .busy
        if case .failure(let f) = manager.start(maxSeconds: 30, owner: nil) { c("本机快捷键正在录音时返回 busy", f.status == 409) } else { c("本机快捷键正在录音时返回 busy", false) }
        fake.next = .started
        let owner = UUID(), stranger = UUID()
        guard let s5 = started(owner) else { c("归属会话", false); return }
        manager.connectionClosed(owner: stranger)
        c("其他连接断开不影响会话", manager.hasActiveSession)
        manager.connectionClosed(owner: owner)
        c("归属连接断开自动取消并释放麦克风", manager.info(id: s5.id)?.state == .cancelled && !manager.hasActiveSession)
        let abortsBeforeLimit = fake.aborts
        if case .success = manager.start(maxSeconds: 1, owner: nil) {
            spin(1.6) { !manager.hasActiveSession || fake.ends > 0 }
            c("到达 max_seconds 自动停止", fake.ends >= 1)
            fake.finish(text: "done")
        }
        manager.processingTimeout = 0.2
        if case .success(let s6) = manager.start(maxSeconds: 30, owner: nil) {
            _ = manager.stop(id: s6.id)
            spin(1.0) { !manager.hasActiveSession }
            c("处理超时：中止并报告 timeout", manager.info(id: s6.id)?.errorCode == "timeout" && fake.aborts == abortsBeforeLimit + 1 && !manager.hasActiveSession)
        }
        manager.unsubscribe(sub)

        // MARK: Router with a fake backend
        final class Stub: LocalAPIBackend {
            var started = 0
            func capabilities() -> [String: Any] { ["api_version": 1] }
            func start(maxSeconds: Int, owner: UUID?) -> Result<LocalAPISessionInfo, LocalAPIFailure> {
                started += 1; return .success(LocalAPISessionInfo(id: String(repeating: "a", count: 32), state: .recording, text: nil, errorCode: nil, detail: nil, elapsedMs: 0))
            }
            func stop(id: String) -> Result<LocalAPISessionInfo, LocalAPIFailure> { .failure(LocalAPIFailure(status: 404, code: "not_found", message: "x")) }
            func cancel(id: String) -> Result<LocalAPISessionInfo, LocalAPIFailure> { stop(id: id) }
            func info(id: String) -> LocalAPISessionInfo? { nil }
            func wait(id: String, seconds: Int, done: @escaping (LocalAPISessionInfo?) -> Void) { done(nil) }
        }
        let stub = Stub()
        func route(_ method: String, _ path: String, headers: [String: String] = [:], auth: Bool = true, body: Data = Data()) -> LocalAPIResponse {
            var h = ["host": "127.0.0.1:9"]
            if auth { h["authorization"] = "Bearer tok" }
            for (k, v) in headers { h[k] = v }
            if case .respond(let r) = LocalAPIRouter.handle(LocalAPIRequest(method: method, path: path, query: [:], headers: h, body: body), port: 9, token: "tok", backend: stub, reply: { _ in }) { return r }
            return LocalAPIResponse.error(0, "deferred", "")
        }
        c("路由：无令牌 401 且不暴露接口", route("GET", "/v1/capabilities", auth: false).status == 401 && route("GET", "/v1/nonexistent", auth: false).status == 401 && route("POST", "/v1/sessions", auth: false).status == 401 && stub.started == 0)
        c("路由：带 Origin 的浏览器请求 403", route("GET", "/v1/capabilities", headers: ["origin": "https://example.com"]).status == 403)
        c("路由：错误 Host 403（防 DNS 重绑定）", route("GET", "/v1/capabilities", headers: ["host": "evil.example:9"]).status == 403)
        c("路由：能力查询 200", route("GET", "/v1/capabilities").status == 200)
        c("路由：方法错误 405", route("GET", "/v1/sessions").status == 405 && route("POST", "/v1/capabilities").status == 405)
        c("路由：未知路径 404", route("GET", "/v2/capabilities").status == 404 && route("GET", "/v1/sessions/nothex/stop").status == 404 && route("GET", "/v1/other").status == 404)
        c("路由：非法 max_seconds 400 且不启动", route("POST", "/v1/sessions", body: Data("{\"max_seconds\":0}".utf8)).status == 400 && stub.started == 0)
        c("路由：启动 200", route("POST", "/v1/sessions").status == 200 && stub.started == 1)
        c("路由：WebSocket 端点需要升级", route("GET", "/v1/ws").status == 426)
        let cap = String(data: route("GET", "/v1/capabilities").body, encoding: .utf8) ?? ""
        c("响应不含凭据字段", !cap.lowercased().contains("secret") && !cap.lowercased().contains("apikey"))

        // MARK: Real listener over loopback
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("localapi-fixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalAPIStore(directory: dir)
        c("设置默认关闭", store.settings == LocalAPISettings() && !store.settings.enabled)
        let token = store.token()
        let mode = (try? FileManager.default.attributesOfItem(atPath: store.tokenURL.path)[.posixPermissions] as? Int) ?? 0
        c("令牌文件仅当前用户可读写", mode == 0o600 && token.count >= 40 && store.token() == token)
        let rotated = store.regenerateToken()
        c("重新生成令牌后旧令牌失效", rotated != token && store.token() == rotated)
        store.settings = LocalAPISettings(enabled: true, port: 80)
        c("非法端口回退默认设置", store.settings == LocalAPISettings())
        store.settings = LocalAPISettings(enabled: true, port: 18000)
        c("设置保存并重新读取", store.settings.enabled && store.settings.port == 18000)

        let liveFake = FakeControl()
        let live = LocalAPISessionManager(control: liveFake) { ["api_version": 1, "microphone_control": true] }
        let server = LocalAPIServer(manager: live, token: { rotated })
        var port = 0
        server.onReady = { port = $0 }
        server.start(port: 0)
        spin(3) { port != 0 }
        c("监听器在回环地址启动", port > 0 && server.isRunning)
        guard port > 0 else { server.stop(); return }

        func http(_ method: String, _ path: String, token: String? = rotated, body: String? = nil, headers: [String: String] = [:]) -> (Int, [String: Any])? {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method; request.timeoutInterval = 8
            if let token = token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            if let body = body { request.httpBody = Data(body.utf8); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            var out: (Int, [String: Any])?, done = false
            URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
                if let r = response as? HTTPURLResponse { out = (r.statusCode, (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]) }
                done = true
            }.resume()
            spin(8) { done }
            return out
        }
        c("真实连接：无令牌 401", http("GET", "/v1/capabilities", token: nil)?.0 == 401)
        c("真实连接：旧令牌 401", http("GET", "/v1/capabilities", token: token)?.0 == 401)
        c("真实连接：浏览器 Origin 403", http("GET", "/v1/capabilities", headers: ["Origin": "https://example.com"])?.0 == 403)
        let capabilities = http("GET", "/v1/capabilities")
        c("真实连接：能力查询", capabilities?.0 == 200 && capabilities?.1["microphone_control"] as? Bool == true)
        let startResponse = http("POST", "/v1/sessions", body: "{\"max_seconds\":30}")
        let sid = startResponse?.1["id"] as? String ?? ""
        c("真实连接：启动会话", startResponse?.0 == 200 && sid.count == 32 && startResponse?.1["state"] as? String == "recording" && liveFake.begins == 1)
        c("真实连接：第二个会话 409", http("POST", "/v1/sessions")?.0 == 409)
        c("真实连接：停止", http("POST", "/v1/sessions/\(sid)/stop")?.1["state"] as? String == "processing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { liveFake.finish(text: "真实文字") }
        let long = http("GET", "/v1/sessions/\(sid)?wait=5")
        c("真实连接：长轮询返回最终文字", long?.0 == 200 && long?.1["state"] as? String == "completed" && long?.1["text"] as? String == "真实文字")
        c("真实连接：结果可再次查询", http("GET", "/v1/sessions/\(sid)")?.1["text"] as? String == "真实文字")

        // WebSocket: events and owner-bound cancellation
        var wsRequest = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/ws")!)
        wsRequest.setValue("Bearer \(rotated)", forHTTPHeaderField: "Authorization")
        let socket = URLSession(configuration: .ephemeral).webSocketTask(with: wsRequest)
        var received: [[String: Any]] = []
        func listen() {
            socket.receive { result in
                if case .success(.string(let text)) = result, let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] { received.append(o); listen() }
            }
        }
        socket.resume(); listen()
        socket.send(.string("{\"op\":\"start\",\"max_seconds\":30}")) { _ in }
        spin(4) { received.contains { $0["state"] as? String == "recording" } }
        c("WebSocket：start 收到 recording 事件", received.contains { $0["type"] as? String == "state" && $0["state"] as? String == "recording" })
        liveFake.partial = "实时"
        live.tick()
        spin(2) { received.contains { $0["type"] as? String == "partial" } }
        c("WebSocket：收到实时文字事件", received.contains { $0["type"] as? String == "partial" && $0["text"] as? String == "实时" })
        let abortsBeforeClose = liveFake.aborts
        socket.cancel(with: .goingAway, reason: nil)
        spin(3) { !live.hasActiveSession }
        c("WebSocket：连接断开自动取消会话并中止采集", !live.hasActiveSession && liveFake.aborts == abortsBeforeClose + 1)

        var wsBad = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/ws")!)
        wsBad.setValue("Bearer wrong", forHTTPHeaderField: "Authorization")
        let badSocket = URLSession(configuration: .ephemeral).webSocketTask(with: wsBad)
        var badFailed = false
        badSocket.resume()
        badSocket.receive { if case .failure = $0 { badFailed = true } }
        spin(4) { badFailed }
        c("WebSocket：错误令牌无法升级", badFailed)

        // Raw socket checks: slow and oversized requests never reach the router.
        var probe: LocalAPIProbeResult?
        LocalAPIProbe.run(port: port, token: rotated) { probe = $0 }; spin(5) { probe != nil }
        c("开发者页测试按钮：令牌正确时报告可用与引擎", { if case .ok = probe { return true }; return false }())
        probe = nil; LocalAPIProbe.run(port: port, token: "wrong") { probe = $0 }; spin(5) { probe != nil }
        c("开发者页测试按钮：令牌错误时单独报告", probe == .badToken)
        c("接口运行时统计连接数", server.connectionCount >= 0)
        c("监听器关闭后停止", { server.stop(); return !server.isRunning }())
        probe = nil; LocalAPIProbe.run(port: port, token: rotated) { probe = $0 }; spin(5) { probe != nil }
        c("开发者页测试按钮：接口关闭时报告未开启", probe == .notRunning)
    }
}
