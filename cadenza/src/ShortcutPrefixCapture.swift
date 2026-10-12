import Foundation

/// A local microphone buffer for the shared modifier's decision window. No
/// recognizer, UI or network consumer exists until the shortcut is confirmed.
final class ShortcutPrefixCapture: CloudPCMCapturing {
    private let inner: CloudPCMCapturing
    private let lock = NSLock()
    private let limit: Int
    private var pending = Data(), level: Float?
    private var prepared = false, live = false, stopping = false, stopped = false, overflow = false
    private var uid = ""
    private var pcmHandler: ((Data) -> Void)?, levelHandler: ((Float) -> Void)?
    let requestedUptime: TimeInterval
    var onPCM: ((Data) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return pcmHandler }
        set { lock.lock(); pcmHandler = newValue; lock.unlock() }
    }
    var onLevel: ((Float) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return levelHandler }
        set { lock.lock(); levelHandler = newValue; lock.unlock() }
    }
    var hasSignal: Bool { inner.hasSignal }
    var startedUptime: TimeInterval? { inner.startedUptime }
    var lastError: String? { inner.lastError }
    var bufferedBytes: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    init(inner: CloudPCMCapturing = CloudPCMCapture(), limit: Int = 64_000,
         requestedUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.inner = inner; self.limit = max(0, limit); self.requestedUptime = requestedUptime
    }
    func prepare(uid: String) -> Bool {
        lock.lock()
        guard !prepared, !stopped else { lock.unlock(); return false }
        prepared = true; self.uid = uid; lock.unlock()
        inner.onPCM = { [weak self] data in self?.receive(data) }
        inner.onLevel = { [weak self] level in self?.receive(level) }
        guard inner.start(uid: uid) else { stop(); return false }
        return true
    }
    private func receive(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard prepared, !stopped else { return }
        if live { pcmHandler?(data) }
        else if pending.count + data.count <= limit { pending.append(data) }
        else { overflow = true; pending.removeAll() }
    }
    private func receive(_ value: Float) {
        lock.lock(); defer { lock.unlock() }
        guard prepared, !stopped else { return }
        level = value
        if live { levelHandler?(value) }
    }
    func start(uid: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard prepared, !live, !stopped, !stopping, !overflow, self.uid == uid else { return false }
        live = true
        // Keep the lock through the handoff, so a newer microphone frame cannot
        // overtake the buffered beginning of the sentence.
        let buffered = pending; pending.removeAll()
        if let level { levelHandler?(level) }
        if !buffered.isEmpty { pcmHandler?(buffered) }
        return true
    }
    func stop() {
        lock.lock()
        guard !stopped, !stopping else { lock.unlock(); return }
        stopping = true
        let started = prepared
        if !live { stopped = true; pending.removeAll() }
        lock.unlock()
        // A committed recording still receives the converter's final frame.
        // A cancelled candidate has no downstream and discards that frame.
        if started { inner.stop() }
        lock.lock(); stopped = true; pending.removeAll(); pcmHandler = nil; levelHandler = nil; lock.unlock()
        inner.onPCM = nil; inner.onLevel = nil
    }
    deinit { stop() }
}

extension VoicePipeline {
    func prepareShortcutPrefix(at time: TimeInterval) {
        discardShortcutPrefix()
        let config = configStore.config
        // This repair covers the current local-dictation path. Cloud/Apple
        // connections retain their existing consent and startup behavior.
        guard config.enabled, !config.triggerCoordinatorEnabled, config.engine == "local",
              !inputSuspendedForDiagnostic, session == nil, HoldNativeEngine.micAuthorized() else { return }
        let capture = ShortcutPrefixCapture(requestedUptime: time)
        if capture.prepare(uid: config.microphoneUID) { shortcutPrefixCapture = capture }
    }
    func discardShortcutPrefix() {
        shortcutPrefixCapture?.stop(); shortcutPrefixCapture = nil
    }
}
