import Foundation
import Network

/// Loopback-only HTTP/1.1 + WebSocket listener. Everything runs on the main queue, which is also where the
/// voice pipeline lives, so no extra synchronisation is needed.
final class LocalAPIServer {
    static let maxConnections = 16
    static let maxWebSockets = 4
    static let headerTimeout: TimeInterval = 10

    private let manager: LocalAPISessionManager
    private let authority: LocalAPIAuthority
    private let audio: LocalAPIAudioManager?
    private var listener: NWListener?
    private var connections: [UUID: LocalAPIConnection] = [:]
    private(set) var port = 0
    var onReady: ((Int) -> Void)?
    var onFailure: ((String) -> Void)?

    init(manager: LocalAPISessionManager, authority: LocalAPIAuthority, audio: LocalAPIAudioManager? = nil) { self.manager = manager; self.authority = authority; self.audio = audio }
    convenience init(manager: LocalAPISessionManager, token: @escaping () -> String) { self.init(manager: manager, authority: LocalAPIOwnerAuthority(token: token)) }

    var isRunning: Bool { listener != nil }
    var connectionCount: Int { connections.count }

    /// `port` 0 asks the system for a free port (tests).
    func start(port requested: Int) {
        stop()
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(requested)) ?? .any)
        guard let listener = try? NWListener(using: parameters) else { onFailure?("listen-failed"); return }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self = self, let listener = listener, self.listener === listener else { return }
            switch state {
            case .ready:
                self.port = Int(listener.port?.rawValue ?? 0)
                Log.write("local-api listening loopback-only port=\(self.port)")
                self.onReady?(self.port)
            case .failed(let error):
                Log.write("local-api listener-failed")
                _ = error
                self.stop(); self.onFailure?("listener-failed")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { connection.cancel(); return }
            guard self.connections.count < Self.maxConnections else { connection.cancel(); return }
            let wrapper = LocalAPIConnection(connection: connection, server: self)
            self.connections[wrapper.id] = wrapper
            wrapper.start()
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.cancel(); listener = nil
        for c in Array(connections.values) { c.close() }
        connections = [:]
        port = 0
    }

    fileprivate func removed(_ id: UUID) { connections[id] = nil }
    fileprivate var webSocketCount: Int { connections.values.filter { $0.isWebSocket }.count }
    fileprivate func route(_ request: LocalAPIRequest, reply: @escaping (LocalAPIResponse) -> Void) -> LocalAPIRouter.Outcome {
        LocalAPIRouter.handle(request, port: port, authority: authority, backend: manager, reply: reply)
    }
    fileprivate var backend: LocalAPISessionManager { manager }
    fileprivate var audioManager: LocalAPIAudioManager? { audio }

    /// Closes every connection that belongs to a revoked device.
    func closeConnections(forDevice id: String) {
        audio?.cancelSessions(ofDevice: id)
        for c in Array(connections.values) where c.principalID == id { c.close() }
    }
}

private final class LocalAPIConnection {
    let id = UUID()
    private let connection: NWConnection
    private unowned let server: LocalAPIServer
    private var buffer = Data()
    private(set) var isWebSocket = false
    private var closed = false
    private var headerTimer: Timer?
    private var lastSession: String?
    private var audioMode = false
    private var principal: LocalAPIPrincipal?
    var principalID: String? { principal?.id }

    init(connection: NWConnection, server: LocalAPIServer) { self.connection = connection; self.server = server }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        headerTimer = Timer.scheduledTimer(withTimeInterval: LocalAPIServer.headerTimeout, repeats: false) { [weak self] _ in self?.close() }
        connection.start(queue: .main)
        receive()
    }

    func close() {
        guard !closed else { return }
        connection.cancel()
        finish()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        headerTimer?.invalidate(); headerTimer = nil
        if isWebSocket { if audioMode { server.audioManager?.connectionClosed(owner: id) } else { server.backend.unsubscribe(id) } } // cancels a session this connection owns
        server.removed(id)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self = self, !self.closed else { return }
            if let data = data, !data.isEmpty { self.buffer.append(data); self.process() }
            if error != nil || complete { self.close(); return }
            if !self.closed { self.receive() }
        }
    }

    private func send(_ data: Data, thenClose: Bool = false) {
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in if thenClose { self?.close() } })
    }

    private func process() {
        if isWebSocket { processFrames(); return }
        switch LocalAPIHTTP.parse(buffer) {
        case .needMore: return
        case .reject(let status, let code):
            send(LocalAPIHTTP.serialize(.error(status, code, "Malformed or oversized request.")), thenClose: true)
            buffer = Data()
        case .request(let request, let consumed):
            buffer = Data(buffer.dropFirst(consumed))
            headerTimer?.invalidate(); headerTimer = nil
            if request.headers["upgrade"] != nil, LocalAPIWebSocket.isUpgrade(request), server.webSocketCount >= LocalAPIServer.maxWebSockets {
                send(LocalAPIHTTP.serialize(.error(503, "unavailable", "Too many WebSocket connections.")), thenClose: true)
                return
            }
            let outcome = server.route(request) { [weak self] response in self?.send(LocalAPIHTTP.serialize(response), thenClose: true) }
            switch outcome {
            case .respond(let response): send(LocalAPIHTTP.serialize(response), thenClose: true)
            case .deferred: break
            case .upgrade(let kind, let who):
                guard let handshake = LocalAPIWebSocket.handshake(request) else { close(); return }
                isWebSocket = true; principal = who; audioMode = kind == .audio
                send(handshake)
                if !audioMode { server.backend.subscribe(id) { [weak self] event in self?.sendEvent(event) } }
                if !buffer.isEmpty { processFrames() }
            }
        }
    }

    private func sendEvent(_ object: [String: Any]) {
        guard !closed, let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        send(LocalAPIWebSocket.encodeText(text))
    }

    private func processFrames() {
        while !buffer.isEmpty, !closed {
            switch LocalAPIWebSocket.decode(buffer) {
            case .needMore: return
            case .invalid:
                send(LocalAPIWebSocket.encode(.close, Data([0x03, 0xEA])), thenClose: true) // 1002 protocol error
                buffer = Data(); return
            case .frame(let frame, let consumed):
                buffer = Data(buffer.dropFirst(consumed))
                switch frame.opcode {
                case .ping: send(LocalAPIWebSocket.encode(.pong, frame.payload))
                case .pong: break
                case .close: send(LocalAPIWebSocket.encode(.close, Data([0x03, 0xE8])), thenClose: true); return
                case .binary:
                    guard audioMode else { send(LocalAPIWebSocket.encode(.close, Data([0x03, 0xEF])), thenClose: true); return } // 1007: text only
                    if let failure = server.audioManager?.receive(owner: id, data: frame.payload), failure.code == "no_session" {
                        sendEvent(["type": "error", "error": ["code": failure.code, "message": failure.message]])
                    }
                case .text: audioMode ? audioCommand(frame.payload) : command(frame.payload)
                }
            }
        }
    }

    private func audioCommand(_ payload: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any], let op = object["op"] as? String, let audio = server.audioManager, let principal = principal else {
            sendEvent(["type": "error", "error": ["code": "bad_request", "message": "Send JSON like {\"op\":\"start\"}."]]); return
        }
        switch op {
        case "start":
            if case .failure(let f) = audio.begin(principal: principal, owner: id, object: object, emit: { [weak self] event in self?.sendEvent(event) }) {
                sendEvent(["type": "error", "error": ["code": f.code, "message": f.message]])
            }
        case "end": audio.end(owner: id)
        case "cancel": audio.cancel(owner: id)
        case "ping": sendEvent(["type": "pong"])
        default: sendEvent(["type": "error", "error": ["code": "bad_request", "message": "Unknown op."]])
        }
    }

    private func command(_ payload: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any], let op = object["op"] as? String else {
            sendEvent(["type": "error", "error": ["code": "bad_request", "message": "Send JSON like {\"op\":\"start\"}."]]); return
        }
        func fail(_ f: LocalAPIFailure) { sendEvent(["type": "error", "error": ["code": f.code, "message": f.message]]) }
        let target = (object["session"] as? String) ?? lastSession
        switch op {
        case "start":
            let body = (try? JSONSerialization.data(withJSONObject: object.filter { $0.key == "max_seconds" })) ?? Data()
            switch LocalAPIRouter.startOptions(body) {
            case .failure(let f): fail(f)
            case .success(let seconds):
                switch server.backend.start(maxSeconds: seconds, owner: id) {
                case .success(let info): lastSession = info.id
                case .failure(let f): fail(f)
                }
            }
        case "stop", "cancel":
            guard let target = target else { fail(LocalAPIFailure(status: 404, code: "not_found", message: "No session to \(op).")); return }
            let result = op == "stop" ? server.backend.stop(id: target) : server.backend.cancel(id: target)
            if case .failure(let f) = result { fail(f) }
        case "ping": sendEvent(["type": "pong"])
        default: fail(LocalAPIFailure(status: 400, code: "bad_request", message: "Unknown op."))
        }
    }
}
