import Foundation
import Security

// Audio submitted through the local interface (`GET /v1/audio`): the recognizer is fed by the connection instead of the
// microphone. Everything here is main-thread and independent of the UI, so it can be tested with a fake recorder.

/// The pipeline side of audio sessions. A fake implements it in tests.
protocol LocalAPIAudioBackend: AnyObject {
    /// Describes what audio submission can do right now; merged into `capabilities`.
    func audioCapabilities() -> [String: Any]
    /// Builds a recognizer that reads from `capture`. Fails with a reason when the engine cannot take external audio.
    func makeRecorder(capture: CloudPCMCapturing) -> Result<HoldRecordingSession, LocalAPIFailure>
    /// The global "Allow devices to type into the front app" switch.
    var insertionAllowed: Bool { get }
    /// Front app and window when a session that wants to type starts.
    func captureDeliveryTarget() -> FocusIdentity?
    /// Types `text` if the target is still the front app and window.
    func deliver(_ text: String, to target: FocusIdentity) -> Bool
}

/// PCM source fed by the interface in place of the microphone.
final class ExternalPCMSource: CloudPCMCapturing {
    var onPCM: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?
    private(set) var hasSignal = false
    private(set) var startedUptime: TimeInterval?
    var lastError: String? { nil }
    func start(uid: String) -> Bool { startedUptime = ProcessInfo.processInfo.systemUptime; return true }
    func stop() {}

    func push(_ data: Data) {
        var peak: Float = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in stride(from: 0, to: data.count - 1, by: 2) {
                let v = abs(Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: Int16.self))) / 32768)
                if v > peak { peak = v }
            }
        }
        if peak > 0.0005 { hasSignal = true }
        onLevel?(min(1, peak))
        onPCM?(data)
    }
}

struct LocalAPIAudioParams: Equatable {
    enum Deliver: String { case none, insert }
    var maxSeconds = LocalAPILimits.defaultSeconds
    var deliver = Deliver.none
    var maxBytes: Int { maxSeconds * 16000 * 2 }

    static func parse(_ object: [String: Any]) -> Result<LocalAPIAudioParams, LocalAPIFailure> {
        func bad(_ message: String) -> Result<LocalAPIAudioParams, LocalAPIFailure> { .failure(LocalAPIFailure(status: 400, code: "bad_request", message: message)) }
        var params = LocalAPIAudioParams()
        if let v = object["sample_rate"] { guard v as? Int == 16000 else { return bad("sample_rate must be 16000.") } }
        if let v = object["channels"] { guard v as? Int == 1 else { return bad("channels must be 1 (mono).") } }
        if let v = object["format"] { guard v as? String == "pcm_s16le" else { return bad("format must be pcm_s16le.") } }
        if let v = object["max_seconds"] {
            guard let n = v as? Int, (1...LocalAPILimits.maxSeconds).contains(n) else { return bad("max_seconds must be an integer from 1 to \(LocalAPILimits.maxSeconds).") }
            params.maxSeconds = n
        }
        if let v = object["deliver"] {
            guard let text = v as? String, let d = Deliver(rawValue: text) else { return bad("deliver must be \"none\" or \"insert\".") }
            params.deliver = d
        }
        return .success(params)
    }
}

final class LocalAPIAudioManager {
    static let maxFrameBytes = LocalAPILimits.maxWebSocketPayload
    private final class Session {
        enum State { case receiving, processing, done }
        let id: String, owner: UUID, principal: LocalAPIPrincipal, params: LocalAPIAudioParams
        let source = ExternalPCMSource()
        var recorder: HoldRecordingSession?
        var emit: ([String: Any]) -> Void
        var state = State.receiving
        var bytes = 0, lastPartial = ""
        var target: FocusIdentity?
        var idle: Timer?, deadline: Timer?
        init(id: String, owner: UUID, principal: LocalAPIPrincipal, params: LocalAPIAudioParams, emit: @escaping ([String: Any]) -> Void) {
            self.id = id; self.owner = owner; self.principal = principal; self.params = params; self.emit = emit
        }
    }

    private let backend: LocalAPIAudioBackend
    private let isMicBusy: () -> Bool
    private var current: Session?
    var idleTimeout: TimeInterval = 10
    var resultTimeout: TimeInterval = 30

    init(backend: LocalAPIAudioBackend, isMicBusy: @escaping () -> Bool) { self.backend = backend; self.isMicBusy = isMicBusy }

    var hasActiveSession: Bool { current != nil }
    func capabilities() -> [String: Any] { backend.audioCapabilities() }

    /// Starts a session for a connection. `emit` receives this session's events (ready, partial, final, cancelled, error).
    func begin(principal: LocalAPIPrincipal, owner: UUID, object: [String: Any], emit: @escaping ([String: Any]) -> Void) -> Result<String, LocalAPIFailure> {
        guard principal.allows(.audio) else { return .failure(LocalAPIFailure(status: 403, code: "permission_denied", message: "This token does not have the audio permission.")) }
        guard current == nil, !isMicBusy() else { return .failure(LocalAPIFailure(status: 409, code: "busy", message: "A session is already active.")) }
        let params: LocalAPIAudioParams
        switch LocalAPIAudioParams.parse(object) { case .success(let p): params = p; case .failure(let f): return .failure(f) }
        var target: FocusIdentity?
        if params.deliver == .insert {
            guard principal.allows(.insert), backend.insertionAllowed else {
                return .failure(LocalAPIFailure(status: 403, code: "permission_denied", message: "Typing into other apps is not allowed for this token or is turned off in Settings."))
            }
            guard let t = backend.captureDeliveryTarget() else {
                return .failure(LocalAPIFailure(status: 409, code: "no_target", message: "There is no front window to type into."))
            }
            target = t
        }
        let session = Session(id: Self.randomID(), owner: owner, principal: principal, params: params, emit: emit)
        session.target = target
        switch backend.makeRecorder(capture: session.source) { case .success(let r): session.recorder = r; case .failure(let f): return .failure(f) }
        guard let recorder = session.recorder else { return .failure(LocalAPIFailure(status: 503, code: "unavailable", message: "No recognizer is available.")) }
        recorder.onPartial = { [weak self, weak session] text in
            DispatchQueue.main.async {
                guard let self = self, let session = session, self.current === session, session.state != .done else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != session.lastPartial else { return }
                session.lastPartial = trimmed
                session.emit(["type": "partial", "session": session.id, "text": trimmed])
            }
        }
        recorder.onFinal = { [weak self, weak session] text in
            DispatchQueue.main.async { if let self = self, let session = session { self.recognized(session, text: text) } }
        }
        guard recorder.begin() else {
            recorder.onPartial = nil; recorder.onFinal = nil
            return .failure(LocalAPIFailure(status: 503, code: "unavailable", message: "The recognizer could not start."))
        }
        current = session
        armIdle(session)
        Log.write("local-api audio-session started device=\(principal.isOwner ? "owner" : principal.id) deliver=\(params.deliver.rawValue)")
        session.emit(["type": "ready", "session": session.id, "max_bytes": params.maxBytes])
        return .success(session.id)
    }

    /// Feeds one binary frame. Returns a failure when the frame ends the session.
    @discardableResult
    func receive(owner: UUID, data: Data) -> LocalAPIFailure? {
        guard let s = current, s.owner == owner, s.state == .receiving else { return LocalAPIFailure(status: 409, code: "no_session", message: "Send {\"op\":\"start\"} before audio.") }
        if data.count % 2 != 0 { return abort(s, LocalAPIFailure(status: 400, code: "bad_frame", message: "Frames must hold whole 16-bit samples.")) }
        if s.bytes + data.count > s.params.maxBytes { return abort(s, LocalAPIFailure(status: 413, code: "limit_exceeded", message: "The audio is longer than max_seconds.")) }
        s.bytes += data.count
        s.source.push(data)
        armIdle(s)
        return nil
    }

    func end(owner: UUID) {
        guard let s = current, s.owner == owner, s.state == .receiving else { return }
        s.idle?.invalidate(); s.idle = nil
        guard s.bytes > 0 else { _ = fail(s, LocalAPIFailure(status: 422, code: "no_audio", message: "No audio was sent.")); return }
        s.state = .processing
        s.deadline = Timer.scheduledTimer(withTimeInterval: resultTimeout, repeats: false) { [weak self, weak s] _ in
            guard let self = self, let s = s, s.state == .processing else { return }
            s.recorder?.abort()
            _ = self.fail(s, LocalAPIFailure(status: 504, code: "timeout", message: "Recognition did not finish in time."))
        }
        s.recorder?.end()
    }

    func cancel(owner: UUID) {
        guard let s = current, s.owner == owner, s.state != .done else { return }
        s.recorder?.abort()
        finish(s, event: ["type": "cancelled", "session": s.id, "state": "cancelled"])
    }

    func connectionClosed(owner: UUID) { cancel(owner: owner) }

    /// A revoked device loses its session immediately.
    func cancelSessions(ofDevice id: String) {
        if let s = current, s.principal.id == id { cancel(owner: s.owner) }
    }

    // MARK: Internals

    private func armIdle(_ s: Session) {
        s.idle?.invalidate()
        s.idle = Timer.scheduledTimer(withTimeInterval: idleTimeout, repeats: false) { [weak self, weak s] _ in
            guard let self = self, let s = s, s.state == .receiving else { return }
            s.recorder?.abort()
            _ = self.fail(s, LocalAPIFailure(status: 408, code: "idle_timeout", message: "No audio arrived for \(Int(self.idleTimeout)) seconds."))
        }
    }

    private func recognized(_ s: Session, text: String?) {
        guard current === s, s.state == .processing else { return }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { _ = fail(s, LocalAPIFailure(status: 422, code: "no_result", message: "Nothing was recognized.")); return }
        var event: [String: Any] = ["type": "final", "session": s.id, "state": "completed", "text": trimmed]
        if s.params.deliver == .insert { event["delivered"] = s.target.map { backend.deliver(trimmed, to: $0) } ?? false }
        finish(s, event: event)
    }

    @discardableResult
    private func abort(_ s: Session, _ failure: LocalAPIFailure) -> LocalAPIFailure {
        s.recorder?.abort()
        return fail(s, failure)
    }

    @discardableResult
    private func fail(_ s: Session, _ failure: LocalAPIFailure) -> LocalAPIFailure {
        finish(s, event: ["type": "error", "session": s.id, "state": "failed", "error": ["code": failure.code, "message": failure.message]])
        return failure
    }

    private func finish(_ s: Session, event: [String: Any]) {
        guard s.state != .done else { return }
        s.state = .done
        s.idle?.invalidate(); s.deadline?.invalidate(); s.idle = nil; s.deadline = nil
        s.recorder?.onPartial = nil; s.recorder?.onFinal = nil
        if current === s { current = nil }
        Log.write("local-api audio-session ended result=\(event["type"] as? String ?? "?") bytes=\(s.bytes)")
        s.emit(event)
    }

    private static func randomID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
