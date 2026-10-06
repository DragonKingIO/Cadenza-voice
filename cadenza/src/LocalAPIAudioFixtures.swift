import AppKit
import Foundation

/// Device credentials, permissions and audio sessions for the local interface. A fake recognizer and fake typing backend
/// are used for the rules; the real listener carries binary audio over loopback; the installed local model (when present)
/// recognizes synthesized speech sent through the interface. No microphone, no provider, no third-party app.
enum LocalAPIAudioFixtures {
    final class FakeRecorder: HoldRecordingSession {
        var onLevel: ((Float) -> Void)?, onPartial: ((String) -> Void)?, onFinal: ((String?) -> Void)?
        var lastError: String?
        var received = Data(), begun = false, ended = false, aborted = false
        var finalText: String? = "识别结果", autoFinal = true
        let capture: CloudPCMCapturing
        init(capture: CloudPCMCapturing) { self.capture = capture }
        func begin() -> Bool { begun = true; capture.onPCM = { [weak self] in self?.received.append($0) }; return capture.start(uid: "") }
        func end() { ended = true; if autoFinal { DispatchQueue.main.async { [weak self] in self?.onFinal?(self?.finalText) } } }
        func abort() { aborted = true; capture.stop() }
    }

    final class FakeBackend: LocalAPIAudioBackend {
        var recorder: FakeRecorder?
        var makeCount = 0
        var failure: LocalAPIFailure?
        var finalText: String? = "识别结果"
        var autoFinal = true
        var insertionAllowed = false
        var target: FocusIdentity?
        var deliverResult = true
        var delivered: [String] = []
        func audioCapabilities() -> [String: Any] { ["audio_submit": true] }
        func makeRecorder(capture: CloudPCMCapturing) -> Result<HoldRecordingSession, LocalAPIFailure> {
            makeCount += 1
            if let failure = failure { return .failure(failure) }
            let r = FakeRecorder(capture: capture); r.finalText = finalText; r.autoFinal = autoFinal; recorder = r
            return .success(r)
        }
        func captureDeliveryTarget() -> FocusIdentity? { target }
        func deliver(_ text: String, to target: FocusIdentity) -> Bool { delivered.append(text); return deliverResult }
    }

    private static func frames(_ count: Int, bytes: Int = 3200) -> [Data] { (0..<count).map { _ in Data(repeating: 1, count: bytes) } }

    static func run(_ check: (String, Bool) -> Void) {
        func c(_ name: String, _ ok: Bool) { check("LocalAPIAudio " + name, ok) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("api-audio-fixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }

        // MARK: Device store
        let store = LocalAPIDeviceStore(directory: dir)
        func addError(_ r: Result<(device: LocalAPIDevice, token: String), LocalAPIDeviceError>) -> LocalAPIDeviceError? { if case .failure(let e) = r { return e }; return nil }
        guard case .success(let added) = store.add(name: "  Pendant  ", permissions: [.audio]) else { c("添加设备", false); return }
        c("设备令牌以 cdz_ 开头且足够长，名称去掉首尾空白", added.token.hasPrefix("cdz_") && added.token.count >= 40 && added.device.name == "Pendant")
        let file = (try? String(contentsOf: dir.appendingPathComponent("local-api-devices.json"), encoding: .utf8)) ?? ""
        c("设备文件不含令牌明文，只含哈希", !file.contains(added.token) && file.contains(LocalAPIDeviceStore.hash(added.token)))
        let mode = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("local-api-devices.json").path)[.posixPermissions] as? Int) ?? 0
        c("设备文件仅当前用户可读写", mode == 0o600)
        c("按令牌找到设备，错误令牌找不到", store.device(forToken: added.token)?.id == added.device.id && store.device(forToken: added.token + "x") == nil && store.device(forToken: "") == nil)
        c("设备在重新加载后仍在", LocalAPIDeviceStore(directory: dir).device(forToken: added.token)?.permissionSet == [.audio])
        c("无效名称被拒绝", addError(store.add(name: "", permissions: [.mic])) == .invalidName && addError(store.add(name: String(repeating: "a", count: 41), permissions: [.mic])) == .invalidName && addError(store.add(name: "a\nb", permissions: [.mic])) == .invalidName)
        c("没有任何权限被拒绝", addError(store.add(name: "x", permissions: [])) == .noPermissions)
        c("撤销后令牌立即失效", store.revoke(id: added.device.id) && store.device(forToken: added.token) == nil && !store.revoke(id: added.device.id))
        var many = 0
        for i in 0..<LocalAPIDeviceStore.maxDevices { if case .success = store.add(name: "d\(i)", permissions: [.mic]) { many += 1 } }
        c("设备数量有上限", many == LocalAPIDeviceStore.maxDevices && addError(store.add(name: "extra", permissions: [.mic])) == .tooMany)
        for d in store.devices { store.revoke(id: d.id) }

        // MARK: Authority and router permissions
        guard case .success(let micDevice) = store.add(name: "Button", permissions: [.mic]), case .success(let audioDevice) = store.add(name: "Mic", permissions: [.audio]),
              case .success(let typeDevice) = store.add(name: "Typist", permissions: [.audio, .insert]) else { c("准备设备", false); return }
        let authority = LocalAPITokenAuthority(ownerToken: { "owner-token-0123456789" }, devices: store)
        c("主令牌拥有录音与音频权限但没有输入权限", authority.principal(authorization: "Bearer owner-token-0123456789") == .owner && !LocalAPIPrincipal.owner.allows(.insert))
        c("设备令牌只拥有各自的权限", authority.principal(authorization: "Bearer " + micDevice.token)?.permissions == [.mic] && authority.principal(authorization: "Bearer " + typeDevice.token)?.permissions == [.audio, .insert])
        c("乱码、缺失、空令牌无法通过", authority.principal(authorization: "Bearer nope") == nil && authority.principal(authorization: nil) == nil && authority.principal(authorization: "Bearer ") == nil && authority.principal(authorization: "Basic abc") == nil)

        final class Stub: LocalAPIBackend {
            func capabilities() -> [String: Any] { ["api_version": 1] }
            func start(maxSeconds: Int, owner: UUID?) -> Result<LocalAPISessionInfo, LocalAPIFailure> { .success(LocalAPISessionInfo(id: String(repeating: "a", count: 32), state: .recording, text: nil, errorCode: nil, detail: nil, elapsedMs: 0)) }
            func stop(id: String) -> Result<LocalAPISessionInfo, LocalAPIFailure> { .failure(LocalAPIFailure(status: 404, code: "not_found", message: "x")) }
            func cancel(id: String) -> Result<LocalAPISessionInfo, LocalAPIFailure> { stop(id: id) }
            func info(id: String) -> LocalAPISessionInfo? { nil }
            func wait(id: String, seconds: Int, done: @escaping (LocalAPISessionInfo?) -> Void) { done(nil) }
        }
        func route(_ method: String, _ path: String, token: String?, upgrade: Bool = false) -> LocalAPIRouter.Outcome {
            var headers = ["host": "127.0.0.1:9"]
            if let token = token { headers["authorization"] = "Bearer " + token }
            if upgrade { headers["upgrade"] = "websocket"; headers["connection"] = "Upgrade"; headers["sec-websocket-key"] = Data(repeating: 7, count: 16).base64EncodedString() }
            return LocalAPIRouter.handle(LocalAPIRequest(method: method, path: path, query: [:], headers: headers, body: Data()), port: 9, authority: authority, backend: Stub(), reply: { _ in })
        }
        func status(_ o: LocalAPIRouter.Outcome) -> Int? { if case .respond(let r) = o { return r.status }; return nil }
        func isUpgrade(_ o: LocalAPIRouter.Outcome, _ kind: LocalAPIRouter.Upgrade) -> Bool { if case .upgrade(let k, _) = o { return k == kind }; return false }
        c("只有 audio 权限的设备不能控制麦克风，只有 mic 的设备不能提交音频", status(route("POST", "/v1/sessions", token: audioDevice.token)) == 403 && status(route("GET", "/v1/audio", token: micDevice.token, upgrade: true)) == 403 && status(route("GET", "/v1/ws", token: audioDevice.token, upgrade: true)) == 403)
        c("权限足够时通过", status(route("POST", "/v1/sessions", token: micDevice.token)) == 200 && isUpgrade(route("GET", "/v1/audio", token: audioDevice.token, upgrade: true), .audio) && isUpgrade(route("GET", "/v1/ws", token: micDevice.token, upgrade: true), .events))
        c("任何有效令牌都可查询能力，无令牌 401", status(route("GET", "/v1/capabilities", token: micDevice.token)) == 200 && status(route("GET", "/v1/capabilities", token: audioDevice.token)) == 200 && status(route("GET", "/v1/capabilities", token: nil)) == 401 && status(route("GET", "/v1/audio", token: nil, upgrade: true)) == 401)
        c("音频端点需要 WebSocket 升级", status(route("GET", "/v1/audio", token: audioDevice.token)) == 426 && status(route("POST", "/v1/audio", token: audioDevice.token)) == 405)
        c("会话查询路径同样需要 mic 权限", status(route("GET", "/v1/sessions/" + String(repeating: "a", count: 32), token: audioDevice.token)) == 403)

        // MARK: Parameters
        func params(_ o: [String: Any]) -> LocalAPIAudioParams? { if case .success(let p) = LocalAPIAudioParams.parse(o) { return p }; return nil }
        c("参数默认值与上限", params([:]) == LocalAPIAudioParams() && params([:])?.maxBytes == 60 * 32000 && params(["max_seconds": 120])?.maxBytes == 120 * 32000)
        c("参数：只接受 16k 单声道 pcm_s16le", params(["sample_rate": 16000, "channels": 1, "format": "pcm_s16le"]) != nil && params(["sample_rate": 8000]) == nil && params(["sample_rate": 48000]) == nil && params(["channels": 2]) == nil && params(["format": "pcm_f32le"]) == nil && params(["format": "mp3"]) == nil)
        c("参数：max_seconds 与 deliver 校验", params(["max_seconds": 0]) == nil && params(["max_seconds": 121]) == nil && params(["max_seconds": "5"]) == nil && params(["deliver": "weird"]) == nil && params(["deliver": 1]) == nil && params(["deliver": "insert"])?.deliver == .insert)

        // MARK: Audio sessions with a fake recognizer
        let backend = FakeBackend()
        var micBusy = false
        let manager = LocalAPIAudioManager(backend: backend, isMicBusy: { micBusy })
        let conn = UUID(), other = UUID()
        var events: [[String: Any]] = []
        func types() -> [String] { events.compactMap { $0["type"] as? String } }
        func begin(_ principal: LocalAPIPrincipal = .owner, _ object: [String: Any] = [:], owner: UUID? = nil) -> Result<String, LocalAPIFailure> {
            manager.begin(principal: principal, owner: owner ?? conn, object: object) { events.append($0) }
        }
        let micOnly = LocalAPIPrincipal(id: micDevice.device.id, name: "Button", permissions: [.mic])
        if case .failure(let f) = begin(micOnly) { c("没有 audio 权限时拒绝", f.status == 403 && f.code == "permission_denied" && backend.makeCount == 0) } else { c("没有 audio 权限时拒绝", false) }
        for (name, bad) in [("采样率", ["sample_rate": 8000]), ("声道", ["channels": 2]), ("格式", ["format": "pcm_f32le"]), ("时长", ["max_seconds": 0]), ("交付方式", ["deliver": "x"])] as [(String, [String: Any])] {
            if case .failure(let f) = begin(.owner, bad) { c("参数错误被拒绝：\(name)", f.status == 400 && backend.makeCount == 0 && !manager.hasActiveSession) } else { c("参数错误被拒绝：\(name)", false) }
        }
        guard case .success(let sid) = begin() else { c("开始音频会话", false); return }
        c("开始：返回 ready 并给出字节上限", manager.hasActiveSession && backend.recorder?.begun == true && events.last?["type"] as? String == "ready" && events.last?["session"] as? String == sid && events.last?["max_bytes"] as? Int == 60 * 32000)
        if case .failure(let f) = begin(owner: other) { c("同时只有一个会话", f.status == 409 && f.code == "busy") } else { c("同时只有一个会话", false) }
        c("音频帧到达识别器且内容一致", frames(5).allSatisfy { manager.receive(owner: conn, data: $0) == nil } && backend.recorder?.received.count == 5 * 3200)
        c("其他连接不能给别人的会话送音频", manager.receive(owner: other, data: Data(count: 2))?.code == "no_session")
        backend.recorder?.onPartial?("你好")
        backend.recorder?.onPartial?("你好")
        backend.recorder?.onPartial?("你好世界")
        LocalAPIFixtures.spin(0.3)
        c("实时文字只在变化时推送", events.filter { $0["type"] as? String == "partial" }.map { $0["text"] as? String ?? "" } == ["你好", "你好世界"])
        manager.end(owner: other)
        c("其他连接不能结束别人的会话", manager.hasActiveSession && backend.recorder?.ended == false)
        manager.end(owner: conn)
        LocalAPIFixtures.spin(2) { !manager.hasActiveSession }
        c("结束后得到最终文字并释放会话", events.last?["type"] as? String == "final" && events.last?["text"] as? String == "识别结果" && events.last?["state"] as? String == "completed" && !manager.hasActiveSession && backend.recorder?.ended == true)
        c("结束后不再接受音频", manager.receive(owner: conn, data: Data(count: 2))?.code == "no_session")

        // odd frame, limits, no audio
        events = []
        _ = begin()
        if let f = manager.receive(owner: conn, data: Data(count: 3201)) { c("奇数字节的帧使会话失败并中止识别器", f.code == "bad_frame" && backend.recorder?.aborted == true && !manager.hasActiveSession && types().last == "error") } else { c("奇数字节的帧使会话失败", false) }
        events = []
        _ = begin(.owner, ["max_seconds": 1])
        let first = manager.receive(owner: conn, data: Data(count: 20000)), second = manager.receive(owner: conn, data: Data(count: 20000))
        c("超过 max_seconds 对应字节数即失败", first == nil && second?.code == "limit_exceeded" && backend.recorder?.aborted == true && !manager.hasActiveSession)
        events = []
        _ = begin(); manager.end(owner: conn)
        c("没发音频就结束报告 no_audio", events.last?["error"] as? [String: Any] != nil && ((events.last?["error"] as? [String: Any])?["code"] as? String) == "no_audio" && !manager.hasActiveSession)
        events = []
        backend.finalText = "   "; _ = begin(); manager.receive(owner: conn, data: Data(count: 3200)); manager.end(owner: conn); LocalAPIFixtures.spin(2) { !manager.hasActiveSession }
        c("识别为空报告 no_result", ((events.last?["error"] as? [String: Any])?["code"] as? String) == "no_result")
        backend.finalText = "识别结果"

        // cancel, disconnect, idle, result timeout, busy with the microphone
        events = []
        _ = begin(); manager.cancel(owner: conn)
        c("取消：中止识别器并报告 cancelled", backend.recorder?.aborted == true && events.last?["type"] as? String == "cancelled" && !manager.hasActiveSession)
        events = []
        _ = begin(); manager.connectionClosed(owner: conn)
        c("连接断开自动取消", backend.recorder?.aborted == true && events.last?["type"] as? String == "cancelled" && !manager.hasActiveSession)
        events = []
        manager.idleTimeout = 0.25
        _ = begin()
        LocalAPIFixtures.spin(1.5) { !manager.hasActiveSession }
        c("长时间没有音频自动结束", ((events.last?["error"] as? [String: Any])?["code"] as? String) == "idle_timeout" && backend.recorder?.aborted == true)
        events = []
        _ = begin(); for _ in 0..<3 { LocalAPIFixtures.spin(0.15); manager.receive(owner: conn, data: Data(count: 3200)) }
        c("持续有音频时不触发空闲超时", manager.hasActiveSession)
        manager.idleTimeout = 10; manager.cancel(owner: conn)
        events = []
        backend.autoFinal = false; manager.resultTimeout = 0.25
        _ = begin(); manager.receive(owner: conn, data: Data(count: 3200)); manager.end(owner: conn)
        LocalAPIFixtures.spin(1.5) { !manager.hasActiveSession }
        c("识别迟迟不出结果报告 timeout", ((events.last?["error"] as? [String: Any])?["code"] as? String) == "timeout" && backend.recorder?.aborted == true)
        backend.autoFinal = true; manager.resultTimeout = 30
        micBusy = true
        if case .failure(let f) = begin() { c("本机麦克风正在录音时拒绝", f.code == "busy") } else { c("本机麦克风正在录音时拒绝", false) }
        micBusy = false
        backend.failure = LocalAPIFailure(status: 422, code: "unsupported_engine", message: "no")
        if case .failure(let f) = begin() { c("引擎不支持外部音频时原样报告且不留会话", f.code == "unsupported_engine" && !manager.hasActiveSession) } else { c("引擎不支持外部音频时原样报告", false) }
        backend.failure = nil
        events = []
        _ = begin(typeDevicePrincipal(typeDevice.device))
        _ = manager.receive(owner: conn, data: Data(count: 3200))
        manager.cancelSessions(ofDevice: typeDevice.device.id)
        c("撤销设备时取消它的会话", events.last?["type"] as? String == "cancelled" && !manager.hasActiveSession)

        // MARK: Typing into the front app
        let typist = typeDevicePrincipal(typeDevice.device), audioOnly = LocalAPIPrincipal(id: audioDevice.device.id, name: "Mic", permissions: [.audio])
        let target = FocusIdentity(pid: 99_999, appName: "fixture.app", element: nil, window: AXUIElementCreateSystemWide(), role: nil, readable: false, selectedTextWritable: false, value: nil)
        backend.target = target; backend.insertionAllowed = true
        if case .failure(let f) = begin(audioOnly, ["deliver": "insert"]) { c("没有 insert 权限不能请求输入", f.code == "permission_denied" && !manager.hasActiveSession) } else { c("没有 insert 权限不能请求输入", false) }
        backend.insertionAllowed = false
        if case .failure(let f) = begin(typist, ["deliver": "insert"]) { c("总开关关闭时不能请求输入", f.code == "permission_denied" && !manager.hasActiveSession) } else { c("总开关关闭时不能请求输入", false) }
        backend.insertionAllowed = true; backend.target = nil
        if case .failure(let f) = begin(typist, ["deliver": "insert"]) { c("没有可输入的前台窗口时报告 no_target", f.code == "no_target" && !manager.hasActiveSession) } else { c("没有可输入的前台窗口时报告 no_target", false) }
        backend.target = target; events = []
        _ = begin(typist, ["deliver": "insert"]); manager.receive(owner: conn, data: Data(count: 3200)); manager.end(owner: conn)
        LocalAPIFixtures.spin(2) { !manager.hasActiveSession }
        c("三道门都开时输入并报告 delivered=true", backend.delivered == ["识别结果"] && events.last?["delivered"] as? Bool == true)
        backend.deliverResult = false; events = []
        _ = begin(typist, ["deliver": "insert"]); manager.receive(owner: conn, data: Data(count: 3200)); manager.end(owner: conn)
        LocalAPIFixtures.spin(2) { !manager.hasActiveSession }
        c("目标变化导致输入失败时报告 delivered=false 且仍返回文字", events.last?["delivered"] as? Bool == false && events.last?["text"] as? String == "识别结果")
        backend.deliverResult = true; events = []; backend.delivered = []
        _ = begin(typist); manager.receive(owner: conn, data: Data(count: 3200)); manager.end(owner: conn)
        LocalAPIFixtures.spin(2) { !manager.hasActiveSession }
        c("没要求输入时绝不输入", backend.delivered.isEmpty && events.last?["delivered"] == nil)

        realListener(c, store: store, authority: authority, audioDevice: audioDevice, micDevice: micDevice)
        realModel(c)
    }

    private static func typeDevicePrincipal(_ d: LocalAPIDevice) -> LocalAPIPrincipal { LocalAPIPrincipal(id: d.id, name: d.name, permissions: d.permissionSet) }

    // MARK: Binary audio over a real loopback listener
    private static func realListener(_ c: (String, Bool) -> Void, store: LocalAPIDeviceStore, authority: LocalAPIAuthority, audioDevice: (device: LocalAPIDevice, token: String), micDevice: (device: LocalAPIDevice, token: String)) {
        let backend = FakeBackend()
        let audio = LocalAPIAudioManager(backend: backend, isMicBusy: { false })
        let control = LocalAPIFixtures.FakeControl()
        let mic = LocalAPISessionManager(control: control) { ["api_version": 1] }
        mic.isOtherSessionActive = { audio.hasActiveSession }
        let server = LocalAPIServer(manager: mic, authority: authority, audio: audio)
        var port = 0
        server.onReady = { port = $0 }
        server.start(port: 0)
        LocalAPIFixtures.spin(3) { port != 0 }
        guard port > 0 else { c("音频监听器启动", false); return }
        defer { server.stop() }

        func open(_ token: String) -> URLSessionWebSocketTask {
            var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/audio")!)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let task = URLSession(configuration: .ephemeral).webSocketTask(with: request)
            task.resume()
            return task
        }
        var received: [[String: Any]] = []
        func listen(_ task: URLSessionWebSocketTask) {
            task.receive { result in
                if case .success(.string(let text)) = result, let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] { received.append(o); listen(task) }
            }
        }
        let task = open(audioDevice.token); listen(task)
        task.send(.string("{\"op\":\"start\",\"sample_rate\":16000,\"channels\":1,\"format\":\"pcm_s16le\",\"max_seconds\":30}")) { _ in }
        LocalAPIFixtures.spin(4) { received.contains { $0["type"] as? String == "ready" } }
        c("真实连接：设备令牌开始音频会话得到 ready", received.contains { $0["type"] as? String == "ready" })
        for frame in frames(10) { task.send(.data(frame)) { _ in } }
        LocalAPIFixtures.spin(1.5) { backend.recorder?.received.count == 32_000 }
        c("真实连接：二进制帧完整到达识别器", backend.recorder?.received.count == 32_000)
        task.send(.string("{\"op\":\"end\"}")) { _ in }
        LocalAPIFixtures.spin(4) { received.contains { $0["type"] as? String == "final" } }
        c("真实连接：结束后收到最终文字", received.last?["type"] as? String == "final" && received.last?["text"] as? String == "识别结果")
        task.cancel(with: .goingAway, reason: nil)
        LocalAPIFixtures.spin(1) { !audio.hasActiveSession }

        // text before start, bad frame, mic conflict
        received = []
        let second = open(audioDevice.token); listen(second)
        second.send(.data(Data(count: 100))) { _ in }
        LocalAPIFixtures.spin(3) { !received.isEmpty }
        c("真实连接：没有 start 就发音频得到 no_session", ((received.last?["error"] as? [String: Any])?["code"] as? String) == "no_session")
        second.send(.string("{\"op\":\"start\"}")) { _ in }
        LocalAPIFixtures.spin(3) { received.contains { $0["type"] as? String == "ready" } }
        control.next = .started
        var micStatus: Int?
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/sessions")!); request.httpMethod = "POST"; request.setValue("Bearer " + micDevice.token, forHTTPHeaderField: "Authorization")
        URLSession(configuration: .ephemeral).dataTask(with: request) { _, response, _ in micStatus = (response as? HTTPURLResponse)?.statusCode }.resume()
        LocalAPIFixtures.spin(4) { micStatus != nil }
        c("真实连接：设备音频会话进行中，本机麦克风会话被拒绝 409", micStatus == 409)
        // revoke closes the connection and cancels the session
        let activeBefore = audio.hasActiveSession
        server.closeConnections(forDevice: audioDevice.device.id)
        LocalAPIFixtures.spin(3) { !audio.hasActiveSession }
        c("撤销设备关闭它的连接并取消会话", activeBefore && !audio.hasActiveSession)

        // a token without the permission cannot even connect
        let denied = open(micDevice.token)
        var failed = false
        denied.receive { if case .failure = $0 { failed = true } }
        LocalAPIFixtures.spin(4) { failed }
        c("真实连接：只有 mic 权限的令牌不能连接音频端点", failed)
    }

    // MARK: Real recognition with the installed model
    private static func realModel(_ c: (String, Bool) -> Void) {
        guard LocalTranscriberLoader.supported, let entry = LocalModelCatalog.builtin.first(where: { $0.id == LocalModelCatalog.recommendedID }),
              LocalModelCenter.shared.installedEntries.contains(where: { $0.id == entry.id }) else { return }
        final class RealBackend: LocalAPIAudioBackend {
            let id: String
            init(id: String) { self.id = id }
            func audioCapabilities() -> [String: Any] { [:] }
            func makeRecorder(capture: CloudPCMCapturing) -> Result<HoldRecordingSession, LocalAPIFailure> { .success(LocalASRRecorder(modelID: id, capture: capture)) }
            var insertionAllowed: Bool { false }
            func captureDeliveryTarget() -> FocusIdentity? { nil }
            func deliver(_ text: String, to target: FocusIdentity) -> Bool { false }
        }
        let sentence = "为什么还有本地模型这个选项？"
        guard let samples = LocalModelFixtures.synthesize(sentence, voice: "Tingting") else { return }
        let backend = RealBackend(id: entry.id)
        let manager = LocalAPIAudioManager(backend: backend, isMicBusy: { false })
        manager.resultTimeout = 60
        let conn = UUID()
        var events: [[String: Any]] = []
        guard case .success = manager.begin(principal: .owner, owner: conn, object: [:], emit: { events.append($0) }) else { c("真实模型：开始会话", false); return }
        var pcm = Data()
        pcm.reserveCapacity(samples.count * 2)
        for s in samples { var v = Int16(max(-1, min(1, s)) * 32767).littleEndian; withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) } }
        var offset = 0
        while offset < pcm.count { let n = min(3200, pcm.count - offset); manager.receive(owner: conn, data: pcm.subdata(in: offset..<(offset + n))); offset += n }
        manager.end(owner: conn)
        LocalAPIFixtures.spin(60) { !manager.hasActiveSession }
        let text = events.last?["text"] as? String ?? ""
        c("真实模型：通过接口送入合成语音，识别出“本地模型”", events.last?["type"] as? String == "final" && text.contains("本地") && text.contains("模型"))
    }
}
