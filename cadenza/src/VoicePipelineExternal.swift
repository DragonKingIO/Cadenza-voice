import Foundation

// Recognition for audio that does not come from the Mac's microphone (the local interface's audio sessions).
// Kept apart from the recording path: no capsule, no focus tracking of its own, no clipboard.

extension VoicePipeline {
    /// A recognizer fed by `capture`. Mirrors the engine rules of a normal recording, minus the microphone permission.
    func makeExternalRecorder(capture: CloudPCMCapturing) -> Result<HoldRecordingSession, LocalAPIFailure> {
        func fail(_ status: Int, _ code: String, _ message: String) -> Result<HoldRecordingSession, LocalAPIFailure> { .failure(LocalAPIFailure(status: status, code: code, message: message)) }
        let config = configStore.config
        guard config.enabled else { return fail(503, "unavailable", "Voice input is turned off in the app.") }
        guard !inputSuspendedForDiagnostic else { return fail(503, "unavailable", "Voice input is paused.") }
        let engine = ASREngine(rawValue: config.engine) ?? .apple
        if LocalOnlyMode.enabled && engine != .local { return fail(403, "local_only", "The app is locked to recognizing on this Mac, and the selected engine is not local.") }
        switch engine {
        case .apple:
            return fail(422, "unsupported_engine", "The Mac's built-in recognition cannot take submitted audio. Choose a local model or a cloud service.")
        case .local:
            guard LocalTranscriberLoader.supported else { return fail(503, "unavailable", "This build has no local recognition library.") }
            let ready = LocalModelCenter.shared.installedEntries.filter { LocalModelCatalog.usable($0) }
            guard let model = FallbackPolicy.resolvePrimary(settings: config.localModel, ready: ready, recognitionLocale: config.recognitionLocale) else {
                return fail(503, "unavailable", "No local model is installed.")
            }
            return .success(LocalASRRecorder(modelID: model.id, capture: capture, options: config.localModel.recognition.resolved(forLanguages: [config.recognitionLocale])))
        default:
            guard config.options(engine).consent else { return fail(403, "consent_required", "Upload consent for this service is off in Settings.") }
            guard let credentials = engine.credentials() else { return fail(503, "unavailable", "This service has no saved credentials.") }
            let language = IflytekRecorder.resolveLanguage(config.iflytekLanguage, forSourceID: nil)
            return .success(CloudASRRecorder(provider: engine, options: config.recordingOptions(engine), credentials: credentials, language: language, capture: capture))
        }
    }

    /// Whether audio submission would work right now, without starting anything. `reason` is English and secret-free.
    func externalAudioStatus() -> (available: Bool, reason: String?) {
        let probe = ExternalPCMSource()
        switch makeExternalRecorder(capture: probe) {
        case .success(let recorder): recorder.abort(); return (true, nil)
        case .failure(let failure): return (false, failure.message)
        }
    }

    /// The front app and window a typing session will aim at. Nil when nothing safe can be targeted.
    func externalDeliveryTarget() -> FocusIdentity? {
        guard let focus = snapshotFocus(), !focus.protectedInput, focus.identityAvailable || focus.windowBoundAvailable else { return nil }
        return focus
    }

    /// Types `text` only if the front app and window are still the ones captured at the start.
    /// Same rules as a normal recording: identified editor first, otherwise window-bound events, never the clipboard.
    @discardableResult
    func deliverExternal(_ text: String, to target: FocusIdentity) -> Bool {
        guard !text.isEmpty, let current = snapshotFocus(), !current.protectedInput else { return false }
        if target.identityAvailable {
            guard current.automaticInputAvailable, FocusProbe.classify(previous: target, current: current) == .unchanged else { return false }
            return insertText(text, current)
        }
        guard target.windowBoundAvailable, current.windowBoundAvailable, current.sameWindow(as: target) else { return false }
        return current.identityAvailable ? insertText(text, current) : insertIntoWindow(text, target)
    }
}

final class PipelineAudioBackend: LocalAPIAudioBackend {
    private let pipeline: VoicePipeline
    private let settings: () -> LocalAPISettings
    init(pipeline: VoicePipeline, settings: @escaping () -> LocalAPISettings) { self.pipeline = pipeline; self.settings = settings }

    func audioCapabilities() -> [String: Any] {
        let status = pipeline.externalAudioStatus()
        var audio: [String: Any] = ["available": status.available, "endpoint": "/v1/audio", "format": "pcm_s16le", "sample_rate": 16000, "channels": 1,
                                    "max_seconds": LocalAPILimits.maxSeconds, "max_frame_bytes": LocalAPILimits.maxWebSocketPayload]
        if let reason = status.reason { audio["unavailable_reason"] = reason }
        return ["audio": audio, "audio_submit": status.available, "desktop_insert": settings().allowInsert]
    }
    func makeRecorder(capture: CloudPCMCapturing) -> Result<HoldRecordingSession, LocalAPIFailure> { pipeline.makeExternalRecorder(capture: capture) }
    var insertionAllowed: Bool { settings().allowInsert }
    func captureDeliveryTarget() -> FocusIdentity? { pipeline.externalDeliveryTarget() }
    func deliver(_ text: String, to target: FocusIdentity) -> Bool { pipeline.deliverExternal(text, to: target) }
}
