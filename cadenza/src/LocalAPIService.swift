import Foundation
import Security

/// Developer API settings live in their own files so the main configuration and its hashes are untouched.
struct LocalAPISettings: Codable, Equatable {
    var enabled = false
    var port = 17420
    /// The global switch for devices that ask to type into the front app. Off by default.
    var allowInsert = false
    static func validPort(_ p: Int) -> Bool { (1024...65535).contains(p) }

    enum CodingKeys: String, CodingKey { case enabled, port, allowInsert }
    init(enabled: Bool = false, port: Int = 17420, allowInsert: Bool = false) { self.enabled = enabled; self.port = port; self.allowInsert = allowInsert }
    init(from decoder: Decoder) throws {
        let d = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try d.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        port = try d.decodeIfPresent(Int.self, forKey: .port) ?? 17420
        allowInsert = try d.decodeIfPresent(Bool.self, forKey: .allowInsert) ?? false
    }
}

final class LocalAPIStore {
    static let standard = LocalAPIStore(directory: AppPaths.supportDir)
    let settingsURL: URL, tokenURL: URL
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
        settingsURL = directory.appendingPathComponent("local-api.json")
        tokenURL = directory.appendingPathComponent("local-api-token")
    }

    var settings: LocalAPISettings {
        get {
            guard let data = try? Data(contentsOf: settingsURL), let s = try? JSONDecoder().decode(LocalAPISettings.self, from: data),
                  LocalAPISettings.validPort(s.port) else { return LocalAPISettings() }
            return s
        }
        set {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(newValue) { try? data.write(to: settingsURL, options: .atomic) }
        }
    }

    /// Created on first use, readable only by the current user.
    func token() -> String {
        if let existing = try? String(contentsOf: tokenURL, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 32 { return trimmed }
        }
        return regenerateToken()
    }

    @discardableResult func regenerateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tokenURL.path, contents: Data((token + "\n").utf8), attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        return token
    }
}

/// Connects the API to the real voice pipeline. API recordings are "local only": the pipeline never types into any
/// application for them, and the recognized text is returned to the caller and then dropped from the app.
final class PipelineVoiceControl: LocalAPIVoiceControl {
    private let pipeline: VoicePipeline
    var finished: (() -> Void)? { didSet { pipeline.onSessionFinished = finished } }
    init(pipeline: VoicePipeline) { self.pipeline = pipeline }

    func begin() -> LocalAPIBegin {
        let config = pipeline.configStore.config
        if pipeline.hasActiveSession || pipeline.inputSuspendedForDiagnostic { return .busy }
        guard config.enabled else { return .unavailable("Voice input is turned off in the app.") }
        guard config.mode == SessionMode.hold.rawValue else { return .unavailable("The app is not in hold mode; switch it to hold mode to use the API.") }
        pipeline.holdStarted(source: .menu, target: nil, localOnly: true)
        return pipeline.hasActiveSession ? .started : .unavailable(pipeline.lastResult)
    }
    func end() { pipeline.holdEnded() }
    func abort() { pipeline.forceEnd(reason: "api-cancel") }
    var partialText: String? { pipeline.lastTranscript }
    var resultText: String? { pipeline.lastTranscript }
    var resultIsError: Bool { pipeline.lastIsError }
    var resultMessage: String { pipeline.lastResult }
    func clearResult() { pipeline.clearTranscript() }
}

final class LocalAPIService {
    enum Status: Equatable { case stopped, running(Int), failed }
    let store: LocalAPIStore
    let manager: LocalAPISessionManager
    private let server: LocalAPIServer
    let devices: LocalAPIDeviceStore
    let audio: LocalAPIAudioManager
    private(set) var status = Status.stopped
    var connectionCount: Int { server.connectionCount }
    var onChange: (() -> Void)?

    init(pipeline: VoicePipeline, store: LocalAPIStore = .standard, devices: LocalAPIDeviceStore = .standard) {
        self.store = store
        self.devices = devices
        let control = PipelineVoiceControl(pipeline: pipeline)
        let audioBackend = PipelineAudioBackend(pipeline: pipeline, settings: { store.settings })
        let manager = LocalAPISessionManager(control: control) {
            let engine = pipeline.configStore.config.engine
            var caps: [String: Any] = [
                "api_version": LocalAPILimits.apiVersion,
                "microphone_control": true,
                "engine": ["id": engine, "title": ASREngine(rawValue: engine)?.title ?? engine],
                "uploads_audio": !["apple", "local"].contains(engine),
                "limits": ["default_seconds": LocalAPILimits.defaultSeconds, "max_seconds": LocalAPILimits.maxSeconds,
                           "max_body_bytes": LocalAPILimits.maxBodyBytes, "concurrent_sessions": 1],
                "events": ["state", "partial", "final", "cancelled", "error"],
            ]
            for (key, value) in audioBackend.audioCapabilities() { caps[key] = value }
            return caps
        }
        let audio = LocalAPIAudioManager(backend: audioBackend, isMicBusy: { manager.hasActiveSession || pipeline.hasActiveSession })
        manager.isOtherSessionActive = { audio.hasActiveSession }
        self.manager = manager
        self.audio = audio
        server = LocalAPIServer(manager: manager, authority: LocalAPITokenAuthority(ownerToken: { store.token() }, devices: devices), audio: audio)
        server.onReady = { [weak self] port in self?.status = .running(port); self?.onChange?() }
        server.onFailure = { [weak self] _ in self?.status = .failed; self?.onChange?() }
    }

    /// Starts or stops the listener to match the saved settings. Disabled by default.
    func apply() {
        let settings = store.settings
        if settings.enabled {
            if case .running(let port) = status, port == settings.port { return }
            _ = store.token()
            server.start(port: settings.port)
        } else {
            server.stop()
            if let active = manager.activeSessionID { _ = manager.cancel(id: active) }
            status = .stopped; onChange?()
        }
    }

    func setEnabled(_ enabled: Bool) {
        var settings = store.settings
        settings.enabled = enabled
        store.settings = settings
        apply()
    }

    func shutdown() {
        server.stop()
        if let active = manager.activeSessionID { _ = manager.cancel(id: active) }
        status = .stopped
    }

    /// Removes a device and closes everything it has open.
    @discardableResult func revokeDevice(id: String) -> Bool {
        let removed = devices.revoke(id: id)
        if removed { server.closeConnections(forDevice: id) }
        return removed
    }

    func regenerateToken() {
        store.regenerateToken() // existing connections keep working only until their next request
    }
}
