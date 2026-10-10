import Foundation
import AVFoundation
import Speech

/// The outcome of recognizing one recorded clip.
enum ClipResult: Equatable {
    case text(String)
    /// The clip could not be recognized at all (no network, rejected credentials, timeout). Not the same as "heard nothing".
    case failed(String)
}

/// One way of recognizing speech that "compare with my voice" can include.
struct CompareCandidate: Identifiable {
    enum Kind: Equatable {
        /// A model installed in the app. Runs on this Mac.
        case local
        /// A cloud service that has saved credentials and upload consent. The recording leaves this Mac.
        case cloud
        /// The Mac's built-in recognition, only when it can run on the device.
        case system
    }
    let id: String
    let name: String
    let kind: Kind
    var entry: LocalModelEntry? = nil
    var engine: ASREngine? = nil
    var uploadsAudio: Bool { kind == .cloud }

    static func local(_ entry: LocalModelEntry) -> CompareCandidate { CompareCandidate(id: entry.id, name: entry.name(), kind: .local, entry: entry) }
    static func cloud(_ engine: ASREngine) -> CompareCandidate { CompareCandidate(id: "cloud:" + engine.rawValue, name: engine.title, kind: .cloud, engine: engine) }
    static let systemID = "system:apple"
    static func system() -> CompareCandidate { CompareCandidate(id: systemID, name: ASREngine.apple.title, kind: .system, engine: .apple) }
}

typealias ClipRecognizer = ([Float]) -> ClipResult

/// Which recognition ways exist on this Mac right now. Only things that are actually usable appear: a model that was
/// never downloaded or a service without saved credentials and upload consent is not listed.
enum CompareCandidates {
    static func available(config: BridgeConfig, locale: String,
                          localEntries: (String) -> [LocalModelEntry] = { VoiceCompare.localCandidates(locale: $0) },
                          cloudReady: (ASREngine, BridgeConfig) -> Bool = CompareCandidates.cloudReady,
                          systemReady: (String) -> Bool = CompareCandidates.systemReady) -> [CompareCandidate] {
        var list = localEntries(locale).map(CompareCandidate.local)
        // "Only on this Mac" locks every audio upload, including a comparison.
        if !LocalOnlyMode.enabled {
            for engine in ASREngine.allCases where engine != .apple && engine != .local && cloudReady(engine, config) { list.append(.cloud(engine)) }
        }
        if systemReady(locale) { list.append(.system()) }
        return list
    }

    static func cloudReady(_ engine: ASREngine, _ config: BridgeConfig) -> Bool {
        let options = config.options(engine)
        return engine.configured && options.consent && ASROptionPolicy.validate(engine, options) == nil
    }

    /// The built-in recognizer is offered only when the person allowed it and it can run on the device, so a comparison
    /// never hands audio to Apple's servers.
    static func systemReady(_ locale: String) -> Bool {
        HoldNativeEngine.speechAuthorized() && SFSpeechRecognizer(locale: Locale(identifier: locale))?.supportsOnDeviceRecognition == true
    }
}

/// Recognizes a finished recording with a cloud service through the app's own recorder, so authentication, options and
/// error handling are exactly what a real dictation uses.
enum CloudClipTranscriber {
    /// Blocks until the service answers or `timeout` passes: call it from a background thread.
    /// The audio is fed at `speed` times real time; the recorder buffers about 8 s, so a faster feed would be refused.
    static func transcribe(_ samples: [Float], provider: ASREngine, options: CloudASROptions, credentials: [String: String], language: String,
                           speed: Double? = nil, timeout: TimeInterval = 30,
                           makeRecorder: ((CloudPCMCapturing) -> HoldRecordingSession)? = nil) -> ClipResult {
        let source = ExternalPCMSource()
        let recorder = makeRecorder?(source) ?? CloudASRRecorder(provider: provider, options: options, credentials: credentials, language: language, capture: source)
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: String?, finished = false
        recorder.onFinal = { text in lock.lock(); result = text; finished = true; lock.unlock(); done.signal() }
        guard recorder.begin() else { return .failed(recorder.lastError ?? "") }
        var pcm = Data(capacity: samples.count * 2)
        for s in samples { var v = Int16(max(-1, min(1, s)) * 32767).littleEndian; withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) } }
        // A streaming service is fed at real time, as a microphone would: it buffers only about 8 s, so a faster feed fails
        // on any recording longer than that. A service that takes the whole recording at once just buffers it.
        let rate = speed ?? (provider.uploadsWholeRecording ? 8 : 1)
        let chunk = 3200, pause = Double(chunk) / 32000 / max(0.5, rate)
        var offset = 0
        while offset < pcm.count {
            source.push(pcm.subdata(in: offset..<min(offset + chunk, pcm.count)))
            offset += chunk
            Thread.sleep(forTimeInterval: pause)
        }
        recorder.end()
        let waited = done.wait(timeout: .now() + timeout)
        recorder.abort()
        lock.lock(); defer { lock.unlock() }
        if waited == .timedOut && !finished { return .failed(L10n.tr("compare.err.timeout")) }
        if let text = result { return .text(text) }
        if let error = recorder.lastError, !error.isEmpty { return .failed(error) }
        return .text("")
    }
}

/// The Mac's built-in recognizer on a recording, on the device only.
enum SystemClipTranscriber {
    static func transcribe(_ samples: [Float], locale: String, timeout: TimeInterval = 30) -> ClipResult {
        guard HoldNativeEngine.speechAuthorized() else { return .failed(L10n.tr("ui.60916822baf4")) }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.supportsOnDeviceRecognition else {
            return .failed(L10n.tr("ui.af99029c7185"))
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return .failed("") }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.append(buffer); request.endAudio()
        recognizer.queue = OperationQueue()
        let done = DispatchSemaphore(value: 0), lock = NSLock()
        var text: String?, failure: String?, signalled = false
        let task = recognizer.recognitionTask(with: request) { result, error in
            lock.lock(); defer { lock.unlock() }
            guard !signalled else { return }
            if let result, result.isFinal { text = result.bestTranscription.formattedString; signalled = true; done.signal() }
            else if let error {
                // "No speech detected" is the system's way of saying it heard nothing, which is an empty result, not a failure.
                if (error as NSError).code == 1110 { text = "" } else { failure = error.localizedDescription }
                signalled = true; done.signal()
            }
        }
        let waited = done.wait(timeout: .now() + timeout)
        task.cancel()
        lock.lock(); defer { lock.unlock() }
        if waited == .timedOut && !signalled { return .failed(L10n.tr("compare.err.timeout")) }
        // The system recognizer reports "no speech detected" as an error when it heard nothing; that is an empty result.
        if let text { return .text(text) }
        return .failed(failure ?? "")
    }
}

/// Builds the recognizer function for a candidate. Local models are loaded once per comparison.
enum VoiceCompareRecognizer {
    static func make(config: BridgeConfig, locale: String) -> (CompareCandidate) -> ClipRecognizer? {
        let options = config.localModel.recognition.resolved(forLanguages: [locale])
        let language = IflytekRecorder.resolveLanguage(config.iflytekLanguage, forSourceID: nil)
        return { candidate in
            switch candidate.kind {
            case .local:
                guard let entry = candidate.entry, let dir = LocalModelCenter.shared.modelDir(entry.id),
                      let t = try? LocalTranscriberLoader.load(dir: dir, entry: entry, options: options) else { return nil }
                return { .text(LocalDecoder.transcribe($0, with: t)) }
            case .cloud:
                guard let engine = candidate.engine, let credentials = engine.credentials() else { return nil }
                let recording = config.recordingOptions(engine)
                return { CloudClipTranscriber.transcribe($0, provider: engine, options: recording, credentials: credentials, language: language) }
            case .system:
                return { SystemClipTranscriber.transcribe($0, locale: locale) }
            }
        }
    }
}
