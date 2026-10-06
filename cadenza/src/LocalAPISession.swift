import Foundation
import Security

/// What the API needs from the voice pipeline. The adapter lives next to the app wiring; tests use a fake.
enum LocalAPIBegin { case started, busy, unavailable(String) }

protocol LocalAPIVoiceControl: AnyObject {
    /// Called on the main thread whenever the pipeline's session ends for any reason.
    var finished: (() -> Void)? { get set }
    func begin() -> LocalAPIBegin
    func end()
    func abort()
    var partialText: String? { get }
    var resultText: String? { get }
    var resultIsError: Bool { get }
    var resultMessage: String { get }
    /// The text was handed to the API caller; it is not kept in the app's recent-result area.
    func clearResult()
}

/// One API recording at a time, always on the main thread. A session started over a WebSocket is owned by that
/// connection and is cancelled when the connection closes; HTTP-started sessions are bounded by `max_seconds`.
final class LocalAPISessionManager: LocalAPIBackend {
    private final class Session {
        let id: String, started: Date, owner: UUID?
        var state = LocalAPISessionState.recording
        var text: String?, errorCode: String?, detail: String?
        var aborted = false, timedOut = false, lastPartial = ""
        var limit: Timer?, deadline: Timer?
        var waiters: [(UUID, (LocalAPISessionInfo?) -> Void, Timer)] = []
        init(id: String, started: Date, owner: UUID?) { self.id = id; self.started = started; self.owner = owner }
        var terminal: Bool { state != .recording && state != .processing }
    }

    private let control: LocalAPIVoiceControl
    private let now: () -> Date
    private let capabilityProvider: () -> [String: Any]
    private var current: Session?
    private var finishedSessions: [String: Session] = [:], finishedOrder: [String] = []
    private var partialTimer: Timer?
    var processingTimeout: TimeInterval = 20
    /// True while an audio session from a device is active (one API session at a time).
    var isOtherSessionActive: () -> Bool = { false }
    /// Delivered to every subscribed (authenticated) WebSocket connection.
    private var subscribers: [UUID: ([String: Any]) -> Void] = [:]

    init(control: LocalAPIVoiceControl, now: @escaping () -> Date = Date.init, capabilities: @escaping () -> [String: Any]) {
        self.control = control; self.now = now; self.capabilityProvider = capabilities
        control.finished = { [weak self] in self?.pipelineFinished() }
    }

    var hasActiveSession: Bool { current != nil }
    var activeSessionID: String? { current?.id }

    func subscribe(_ id: UUID, _ handler: @escaping ([String: Any]) -> Void) { subscribers[id] = handler }
    func unsubscribe(_ id: UUID) { subscribers[id] = nil; connectionClosed(owner: id) }
    func connectionClosed(owner: UUID) {
        if let s = current, s.owner == owner, !s.terminal { _ = cancel(id: s.id) }
    }

    // MARK: LocalAPIBackend

    func capabilities() -> [String: Any] { capabilityProvider() }

    func start(maxSeconds: Int, owner: UUID?) -> Result<LocalAPISessionInfo, LocalAPIFailure> {
        guard current == nil, !isOtherSessionActive() else { return .failure(LocalAPIFailure(status: 409, code: "busy", message: "A session is already active.")) }
        switch control.begin() {
        case .busy: return .failure(LocalAPIFailure(status: 409, code: "busy", message: "The microphone is in use by another recording."))
        case .unavailable(let detail): return .failure(LocalAPIFailure(status: 503, code: "unavailable", message: detail))
        case .started: break
        }
        let session = Session(id: Self.randomID(), started: now(), owner: owner)
        current = session
        session.limit = Timer.scheduledTimer(withTimeInterval: TimeInterval(maxSeconds), repeats: false) { [weak self] _ in
            Log.write("local-api session-limit reached")
            _ = self?.stop(id: session.id)
        }
        partialTimer?.invalidate()
        partialTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        emit(["type": "state", "session": session.id, "state": "recording"])
        return .success(info(session))
    }

    func stop(id: String) -> Result<LocalAPISessionInfo, LocalAPIFailure> {
        guard let s = find(id) else { return .failure(LocalAPIFailure(status: 404, code: "not_found", message: "Unknown session.")) }
        guard s.state == .recording, s === current else { return .success(info(s)) } // repeated stop is harmless
        s.limit?.invalidate(); s.limit = nil
        s.state = .processing
        s.deadline = Timer.scheduledTimer(withTimeInterval: processingTimeout, repeats: false) { [weak self] _ in
            guard let self = self, s === self.current, !s.terminal else { return }
            s.aborted = true; s.timedOut = true; self.control.abort()
            if s === self.current { self.finalize(s, state: .failed, text: nil, code: "timeout", detail: "Recognition did not finish in time.") }
        }
        emit(["type": "state", "session": s.id, "state": "processing"])
        control.end()
        return .success(info(s))
    }

    func cancel(id: String) -> Result<LocalAPISessionInfo, LocalAPIFailure> {
        guard let s = find(id) else { return .failure(LocalAPIFailure(status: 404, code: "not_found", message: "Unknown session.")) }
        guard !s.terminal, s === current else { return .success(info(s)) }
        s.aborted = true
        control.abort()
        if s === current { finalize(s, state: .cancelled, text: nil, code: nil, detail: nil) } // pipeline did not report an end
        return .success(info(s))
    }

    func info(id: String) -> LocalAPISessionInfo? { find(id).map(info) }

    func wait(id: String, seconds: Int, done: @escaping (LocalAPISessionInfo?) -> Void) {
        guard let s = find(id) else { done(nil); return }
        guard !s.terminal else { done(info(s)); return }
        let key = UUID()
        let timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { [weak self, weak s] _ in
            guard let self = self, let s = s, let i = s.waiters.firstIndex(where: { $0.0 == key }) else { return }
            let waiter = s.waiters.remove(at: i); waiter.1(self.info(s))
        }
        s.waiters.append((key, done, timer))
    }

    // MARK: Internals

    func tick() {
        guard let s = current, s.state == .recording, let text = control.partialText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text != s.lastPartial else { return }
        s.lastPartial = text
        emit(["type": "partial", "session": s.id, "text": text])
    }

    private func pipelineFinished() {
        guard let s = current, !s.terminal else { return }
        if s.timedOut { finalize(s, state: .failed, text: nil, code: "timeout", detail: "Recognition did not finish in time."); return }
        if s.aborted { finalize(s, state: .cancelled, text: nil, code: nil, detail: nil); return }
        let text = control.resultText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { finalize(s, state: .completed, text: text, code: nil, detail: nil) }
        else if control.resultIsError { finalize(s, state: .failed, text: nil, code: "no_result", detail: control.resultMessage) }
        else { finalize(s, state: .cancelled, text: nil, code: nil, detail: nil) } // ended from the app itself
    }

    private func finalize(_ s: Session, state: LocalAPISessionState, text: String?, code: String?, detail: String?) {
        guard !s.terminal else { return }
        s.state = state; s.text = text; s.errorCode = code; s.detail = detail
        s.limit?.invalidate(); s.deadline?.invalidate(); s.limit = nil; s.deadline = nil
        partialTimer?.invalidate(); partialTimer = nil
        if current === s { current = nil }
        control.clearResult()
        finishedSessions[s.id] = s; finishedOrder.append(s.id)
        while finishedOrder.count > 16 { finishedSessions[finishedOrder.removeFirst()] = nil }
        var event: [String: Any] = ["session": s.id, "state": state.rawValue]
        switch state {
        case .completed: event["type"] = "final"; event["text"] = text ?? ""
        case .failed: event["type"] = "error"; event["error"] = ["code": code ?? "failed", "message": detail ?? ""]
        default: event["type"] = "cancelled"
        }
        emit(event)
        let waiters = s.waiters; s.waiters = []
        for w in waiters { w.2.invalidate(); w.1(info(s)) }
    }

    private func find(_ id: String) -> Session? { current?.id == id ? current : finishedSessions[id] }
    private func info(_ s: Session) -> LocalAPISessionInfo {
        LocalAPISessionInfo(id: s.id, state: s.state, text: s.text, errorCode: s.errorCode, detail: s.detail,
                            elapsedMs: Int(now().timeIntervalSince(s.started) * 1000))
    }
    private func emit(_ event: [String: Any]) { for handler in subscribers.values { handler(event) } }
    private static func randomID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
