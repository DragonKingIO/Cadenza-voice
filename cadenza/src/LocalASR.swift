import Foundation

// MARK: - 本地识别抽象
// 推理后端（sherpa-onnx）只出现在 SherpaTranscriber 里；没有链接静态库时（未执行 tools/fetch-sherpa-onnx.sh）
// 本文件其余部分照常编译，本地引擎如实报告“当前构建不含本地推理”。

struct LocalRecognitionOptions: Codable, Equatable {
    var language = "auto"
    var useITN = true
    var vadThreshold: Float = 0.5
    var threads = 2
    static let languages = ["auto","zh","en","ja","ko","yue"]
    /// "Automatic" lets SenseVoice guess the language per clip, and short Mandarin clips sometimes come out as Japanese or
    /// Korean (measured: 21% vs 12% character errors on short sentences). When the wanted language is Mandarin, say so.
    /// Mixed Chinese and English is still recognized with "zh".
    func resolved(forLanguages languages: [String]) -> LocalRecognitionOptions {
        guard language == "auto", let first = languages.first?.lowercased() else { return self }
        let mandarin = first == "zh" || ((first.hasPrefix("zh-") || first.hasPrefix("zh_")) && !first.contains("hk") && !first.contains("yue"))
        guard mandarin else { return self }
        var copy = self; copy.language = "zh"; return copy
    }
    var valid: Bool { Self.languages.contains(language) && vadThreshold.isFinite && (0.3...0.8).contains(vadThreshold) && (1...4).contains(threads) }
}

protocol LocalTranscriber: AnyObject {
    var vadAvailable: Bool { get }
    /// 16 kHz 单声道 float。同步且耗时，必须在后台线程调用。
    func transcribe(_ samples: [Float]) -> String
    /// 长录音按语音停顿切段（样本区间）；不可用时返回空数组
    func speechSegments(_ samples: [Float]) -> [Range<Int>]
}

extension LocalTranscriber { var vadAvailable: Bool { false } }

enum LocalTranscriberLoader {
    static var supported: Bool {
        #if LOCAL_SHERPA
        return true
        #else
        return false
        #endif
    }
    static func load(dir: URL, entry: LocalModelEntry) throws -> LocalTranscriber { try load(dir:dir,entry:entry,options:LocalRecognitionOptions()) }
    static func load(dir: URL, entry: LocalModelEntry, options: LocalRecognitionOptions) throws -> LocalTranscriber {
        guard options.valid else { throw LocalModelError.loadFailed }
        #if LOCAL_SHERPA
        let made: SherpaOfflineTranscriber?
        switch entry.kind {
        case "sensevoice": made = SherpaOfflineTranscriber.senseVoice(dir: dir, options: options)
        case "parakeet-tdt": made = SherpaOfflineTranscriber.nemoTransducer(dir: dir, options: options)
        case "fire-red-ctc": made = SherpaOfflineTranscriber.fireRedCtc(dir: dir, options: options)
        case "paraformer": made = SherpaOfflineTranscriber.paraformer(dir: dir, options: options)
        case "qwen3-asr": made = SherpaOfflineTranscriber.qwen3Asr(dir: dir, options: options)
        default: throw LocalModelError.unsupported
        }
        guard let t = made else { throw LocalModelError.loadFailed }
        return t
        #else
        throw LocalModelError.unsupported
        #endif
    }
}

enum LocalDecoder {
    static let sampleRate = 16000
    /// 单次直接解码的上限；更长的录音按停顿切段
    static let directLimit = 25 * 16000
    /// Tuning knobs (defaults are the shipped values; the accuracy benchmark overrides them to compare).
    static var segmentPad = sampleRate * 4 / 5   // measured: 0.2 s cut off soft first syllables; gains level off at 0.8 s
    static var vadMinSpeech: Float = 0.25
    static var vadMinSilence: Float = 0.5

    static func samples(fromPCM16 data: Data) -> [Float] {
        let n = data.count / 2
        var out = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<n { out[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768 }
        }
        return out
    }

    /// Brings quiet recordings up to a level the model was trained on. Only boosts (never attenuates), caps the gain so
    /// background noise is not blown up, and uses a high percentile instead of the single loudest sample so a click
    /// does not stop the boost.
    static func levelled(_ samples: [Float], target: Float = 0.5, maxGain: Float = 30) -> [Float] {
        guard samples.count >= 1600 else { return samples }
        let step = max(1, samples.count / 20000)
        var sampled = [Float](); sampled.reserveCapacity(samples.count / step + 1)
        var i = 0
        while i < samples.count { sampled.append(abs(samples[i])); i += step }
        sampled.sort()
        let loud = sampled[min(sampled.count - 1, Int(Float(sampled.count) * 0.995))]
        guard loud > 0.0005, loud < target else { return samples }
        let gain = min(maxGain, target / loud)
        return samples.map { max(-1, min(1, $0 * gain)) }
    }

    static func transcribe(_ raw: [Float], with t: LocalTranscriber) -> String {
        let samples = levelled(SpeechEnhancer.enhance(raw))
        guard samples.count >= sampleRate / 2, samples.allSatisfy({$0.isFinite}), samples.contains(where:{abs($0)>0.00001}) else { return "" }
        var segments: [Range<Int>]
        if t.vadAvailable {
            segments = t.speechSegments(samples).filter { $0.lowerBound >= 0 && $0.upperBound <= samples.count && !$0.isEmpty }
            guard !segments.isEmpty else { return "" } // VAD-confirmed silence must never become text.
            // Retain quiet initial/final consonants while keeping adjacent segments disjoint.
            segments = segments.sorted { $0.lowerBound < $1.lowerBound }
            var padded: [Range<Int>] = []
            for r in segments {
                let lower=max(padded.last?.upperBound ?? 0,r.lowerBound-segmentPad)
                let upper=min(samples.count,r.upperBound+segmentPad)
                if lower<upper { padded.append(lower..<upper) }
            }
            segments=padded
        } else if samples.count <= directLimit { return t.transcribe(samples).trimmingCharacters(in:.whitespacesAndNewlines) }
        else { segments=t.speechSegments(samples).filter{$0.lowerBound>=0 && $0.upperBound<=samples.count && !$0.isEmpty} }
        if segments.isEmpty {segments=[0..<samples.count]}
        var text = ""
        for segment in segments {
            // Bound every inference call, including an unexpectedly long VAD segment.
            for lower in stride(from:segment.lowerBound,to:segment.upperBound,by:directLimit) {
                let upper=min(segment.upperBound,lower+directLimit)
                let part=t.transcribe(Array(samples[lower..<upper])).trimmingCharacters(in:.whitespacesAndNewlines)
                guard !part.isEmpty else {continue}
                if let l=text.unicodeScalars.last,let f=part.unicodeScalars.first,l.isASCII,f.isASCII,!l.properties.isWhitespace {text += " "}
                text += part
            }
        }
        return text
    }
}

// MARK: - 识别器缓存：加载约 0.5s、常驻约 550MB；空闲一段时间后释放内存

final class LocalTranscriberCache {
    static let shared = LocalTranscriberCache()
    var idleSeconds: TimeInterval = 300
    var loader: (URL, LocalModelEntry, LocalRecognitionOptions) throws -> LocalTranscriber = LocalTranscriberLoader.load
    private let lock = NSLock()
    private var loaded: (key: String, transcriber: LocalTranscriber)?
    private var timer: DispatchSourceTimer?

    /// 取（必要时加载）指定模型的识别器；同步，请在后台线程调用。当前版本加载失败时回滚到上一版再试一次。
    func transcriber(for id: String, center: LocalModelCenter = .shared, options: LocalRecognitionOptions = LocalRecognitionOptions()) throws -> LocalTranscriber {
        for attempt in 0..<2 {
            // 先取条目与目录，再加锁：持锁时不能等主线程（安装完成回调会在主线程卸载缓存，二者会互相等待）
            guard let entry = DispatchQueue.main.syncIfNeeded({ center.installedEntry(id) }), let dir = DispatchQueue.main.syncIfNeeded({ center.modelDir(id) }) else { throw LocalModelError.incomplete(id) }
            let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
            let key=dir.path+"|"+String(decoding:try encoder.encode(options),as:UTF8.self)
            lock.lock()
            if let l = loaded, l.key == key { armIdle(); lock.unlock(); return l.transcriber }
            loaded = nil
            do {
                let t = try loader(dir, entry, options)
                loaded = (key, t); armIdle(); lock.unlock(); return t
            } catch {
                lock.unlock()
                Log.write("local-model load-failed id=\(id) attempt=\(attempt)")
                let rolled = DispatchQueue.main.syncIfNeeded { center.rollback(id) }
                if !rolled || attempt == 1 { throw error }
            }
        }
        throw LocalModelError.loadFailed
    }

    func preload(_ id: String, center: LocalModelCenter = .shared, options: LocalRecognitionOptions = LocalRecognitionOptions()) {
        DispatchQueue.global(qos: .userInitiated).async { _ = try? self.transcriber(for: id, center: center, options:options) }
    }

    func unload() { lock.lock(); loaded = nil; timer?.cancel(); timer = nil; lock.unlock() }
    var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return loaded != nil }

    private func armIdle() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + idleSeconds)
        t.setEventHandler { [weak self] in self?.unload(); Log.write("local-model idle-unload") }
        t.resume(); timer = t
    }
}

extension DispatchQueue {
    /// 在主线程同步取值；已在主线程则直接执行（缓存可能被主线程调用）
    func syncIfNeeded<T>(_ body: () -> T) -> T { Thread.isMainThread ? body() : sync(execute: body) }
}

// MARK: - 本地录音会话（作为主引擎）

final class LocalASRRecorder: HoldRecordingSession {
    private let callbackLock = NSLock()
    private var levelCB: ((Float) -> Void)?, partialCB: ((String) -> Void)?, finalCB: ((String?) -> Void)?
    var onLevel: ((Float) -> Void)? { get { callbackLock.lock(); defer { callbackLock.unlock() }; return levelCB } set { callbackLock.lock(); levelCB = newValue; callbackLock.unlock() } }
    var onPartial: ((String) -> Void)? { get { callbackLock.lock(); defer { callbackLock.unlock() }; return partialCB } set { callbackLock.lock(); partialCB = newValue; callbackLock.unlock() } }
    var onFinal: ((String?) -> Void)? { get { callbackLock.lock(); defer { callbackLock.unlock() }; return finalCB } set { callbackLock.lock(); finalCB = newValue; callbackLock.unlock() } }
    private(set) var lastError: String?
    var captureStartedUptime: TimeInterval? { capture.startedUptime }
    var capturedAudioHasSignal: Bool? { capture.hasSignal }
    var microphoneUID = ""
    var fallbackNotice: String?

    let modelID: String
    private let options: LocalRecognitionOptions
    private let capture: CloudPCMCapturing
    private let center: LocalModelCenter
    private let cache: LocalTranscriberCache
    private let queue = DispatchQueue(label: "cadenza.local.asr", qos: .userInitiated)
    private let dataLock = NSLock()
    private var samples: [Float] = []
    private var timer: DispatchSourceTimer?
    private var busy = false, ended = false, began = false
    private var cancellation = false
    private var cancelled:Bool {dataLock.lock();defer{dataLock.unlock()};return cancellation}
    private var limitReached=false
    var sampleLimit = 15 * 60 * 16000
    private static let maxSamples = 15 * 60 * 16000

    init(modelID: String, center: LocalModelCenter = .shared, cache: LocalTranscriberCache = .shared, capture: CloudPCMCapturing = CloudPCMCapture(), options: LocalRecognitionOptions = LocalRecognitionOptions()) {
        self.options=options;self.modelID = modelID; self.center = center; self.cache = cache; self.capture = capture
    }

    func begin() -> Bool {
        guard !began,options.valid else { return false }
        guard LocalTranscriberLoader.supported else { lastError = L10n.tr("local.err.unsupportedBuild"); return false }
        guard center.isReady(modelID) else { lastError = L10n.tr("local.err.notInstalled"); return false }
        began = true
        capture.onLevel = { [weak self] v in self?.onLevel?(v) }
        capture.onPCM = { [weak self] data in
            guard let self else { return }
            let s = LocalDecoder.samples(fromPCM16: data)
            self.dataLock.lock()
            guard !self.cancellation,!self.limitReached else {self.dataLock.unlock();return}
            let room=max(0,self.sampleLimit-self.samples.count)
            self.samples.append(contentsOf:s.prefix(room))
            let reached=self.samples.count>=self.sampleLimit
            if reached {self.limitReached=true}
            self.dataLock.unlock()
            if reached {self.queue.async{self.end()}}
        }
        guard capture.start(uid: microphoneUID) else { lastError = capture.lastError ?? L10n.tr("ui.13a46616e16f"); capture.onPCM = nil; capture.onLevel = nil; return false }
        cache.preload(modelID, center: center, options:options)   // 与录音并行加载，松开时通常已就绪
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.5)
        t.setEventHandler { [weak self] in self?.partialTick() }
        t.resume(); timer = t
        return true
    }

    private func snapshot(tail: Int? = nil) -> [Float] {
        dataLock.lock(); defer { dataLock.unlock() }
        guard let tail, samples.count > tail else { return samples }
        return Array(samples.suffix(tail))
    }

    private func partialTick() {
        guard !busy, !ended, !cancelled, capture.hasSignal, cache.isLoaded, let t = try? cache.transcriber(for: modelID, center: center, options:options) else { return }
        busy = true; defer { busy = false }
        let text = LocalDecoder.transcribe(snapshot(tail: LocalDecoder.directLimit), with: t)
        guard !text.isEmpty, !ended, !cancelled else { return }
        onPartial?(text)
    }

    func end() {
        capture.stop()
        queue.async { [self] in
            guard !cancelled, !ended else { return }
            ended = true; timer?.cancel(); timer = nil
            let pcm = snapshot()
            let hasSignal = capture.hasSignal
            var text = ""
            do { text = LocalDecoder.transcribe(pcm, with: try cache.transcriber(for: modelID, center: center, options:options)) }
            catch { lastError = L10n.tr("local.err.load") }
            capture.onPCM = nil; capture.onLevel = nil
            dataLock.lock();samples.removeAll();dataLock.unlock()
            guard !cancelled else{return}
            let cb = onFinal; onFinal = nil; onPartial = nil
            cb?(text.isEmpty || !hasSignal ? nil : text)
        }
    }

    func abort() {
        capture.stop(); capture.onPCM = nil; capture.onLevel = nil
        dataLock.lock();cancellation=true;samples.removeAll();dataLock.unlock()
        queue.async { [weak self] in self?.timer?.cancel();self?.timer=nil }
        onFinal = nil; onPartial = nil; onLevel = nil
    }
}

// MARK: - sherpa-onnx（离线识别器：SenseVoice、NeMo Parakeet 等共用同一套 VAD 与解码流程）

#if LOCAL_SHERPA
final class SherpaOfflineTranscriber: LocalTranscriber {
    private let recognizer: OpaquePointer
    private let vadPath: String?
    private let options:LocalRecognitionOptions
    var vadAvailable:Bool {vadPath != nil}
    private let lock = NSLock()

    private init(recognizer: OpaquePointer, vadPath: String?, options:LocalRecognitionOptions) { self.recognizer = recognizer; self.vadPath = vadPath;self.options=options }
    deinit { SherpaOnnxDestroyOfflineRecognizer(recognizer) }

    private static func vad(in dir: URL) -> String? {
        let p = dir.appendingPathComponent("silero_vad.onnx").path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// SenseVoice：中/英/日/韩/粤，自动判断语种，带标点与数字规整
    static func senseVoice(dir: URL, options:LocalRecognitionOptions) -> SherpaOfflineTranscriber? {
        let values: [String] = [dir.appendingPathComponent("model.int8.onnx").path, dir.appendingPathComponent("tokens.txt").path, options.language, "cpu", "greedy_search"]
        let c = values.map { strdup($0)! }
        defer { c.forEach { free($0) } }
        var cfg = SherpaOnnxOfflineRecognizerConfig()
        cfg.feat_config.sample_rate = 16000; cfg.feat_config.feature_dim = 80
        cfg.model_config.sense_voice.model = UnsafePointer(c[0]); cfg.model_config.sense_voice.language = UnsafePointer(c[2]); cfg.model_config.sense_voice.use_itn = options.useITN ? 1:0
        cfg.model_config.tokens = UnsafePointer(c[1]); cfg.model_config.num_threads = Int32(options.threads); cfg.model_config.provider = UnsafePointer(c[3])
        cfg.decoding_method = UnsafePointer(c[4])
        guard let r = SherpaOnnxCreateOfflineRecognizer(&cfg) else { return nil }
        return SherpaOfflineTranscriber(recognizer: r, vadPath: vad(in: dir), options:options)
    }

    /// NVIDIA NeMo Parakeet TDT（transducer）：25 种欧洲语言，自动判断语种
    /// FireRedASR2 (CTC, int8): Mandarin and English. Language, ITN and similar SenseVoice options do not apply.
    static func fireRedCtc(dir: URL, options:LocalRecognitionOptions) -> SherpaOfflineTranscriber? {
        let values: [String] = [dir.appendingPathComponent("model.int8.onnx").path, dir.appendingPathComponent("tokens.txt").path, "cpu", "greedy_search"]
        let c = values.map { strdup($0)! }
        defer { c.forEach { free($0) } }
        var cfg = SherpaOnnxOfflineRecognizerConfig()
        cfg.feat_config.sample_rate = 16000; cfg.feat_config.feature_dim = 80
        cfg.model_config.fire_red_asr_ctc.model = UnsafePointer(c[0])
        cfg.model_config.tokens = UnsafePointer(c[1])
        cfg.model_config.num_threads = Int32(options.threads); cfg.model_config.provider = UnsafePointer(c[2])
        cfg.decoding_method = UnsafePointer(c[3])
        guard let r = SherpaOnnxCreateOfflineRecognizer(&cfg) else { return nil }
        return SherpaOfflineTranscriber(recognizer: r, vadPath: vad(in: dir), options:options)
    }

    /// Paraformer (int8, non-autoregressive): Mandarin with English words. The language and ITN options do not apply.
    static func paraformer(dir: URL, options:LocalRecognitionOptions) -> SherpaOfflineTranscriber? {
        let values: [String] = [dir.appendingPathComponent("model.int8.onnx").path, dir.appendingPathComponent("tokens.txt").path, "cpu", "greedy_search"]
        let c = values.map { strdup($0)! }
        defer { c.forEach { free($0) } }
        var cfg = SherpaOnnxOfflineRecognizerConfig()
        cfg.feat_config.sample_rate = 16000; cfg.feat_config.feature_dim = 80
        cfg.model_config.paraformer.model = UnsafePointer(c[0])
        cfg.model_config.tokens = UnsafePointer(c[1])
        cfg.model_config.num_threads = Int32(options.threads); cfg.model_config.provider = UnsafePointer(c[2])
        cfg.decoding_method = UnsafePointer(c[3])
        guard let r = SherpaOnnxCreateOfflineRecognizer(&cfg) else { return nil }
        return SherpaOfflineTranscriber(recognizer: r, vadPath: vad(in: dir), options:options)
    }

    /// Qwen3-ASR 0.6B (int8): a speech-to-text language model for 27+ languages and many Chinese dialects. It detects the
    /// language itself, so the language option does not apply. Decoding is near-greedy (tiny temperature, fixed seed).
    static func qwen3Asr(dir: URL, options:LocalRecognitionOptions) -> SherpaOfflineTranscriber? {
        let values: [String] = [dir.appendingPathComponent("conv_frontend.onnx").path, dir.appendingPathComponent("encoder.int8.onnx").path,
                                dir.appendingPathComponent("decoder.int8.onnx").path, dir.appendingPathComponent("tokenizer").path, "cpu", "greedy_search"]
        let c = values.map { strdup($0)! }
        defer { c.forEach { free($0) } }
        var cfg = SherpaOnnxOfflineRecognizerConfig()
        cfg.feat_config.sample_rate = 16000; cfg.feat_config.feature_dim = 80
        cfg.model_config.qwen3_asr.conv_frontend = UnsafePointer(c[0]); cfg.model_config.qwen3_asr.encoder = UnsafePointer(c[1])
        cfg.model_config.qwen3_asr.decoder = UnsafePointer(c[2]); cfg.model_config.qwen3_asr.tokenizer = UnsafePointer(c[3])
        cfg.model_config.qwen3_asr.max_total_len = 1024; cfg.model_config.qwen3_asr.max_new_tokens = 512
        cfg.model_config.qwen3_asr.temperature = 1e-6; cfg.model_config.qwen3_asr.top_p = 0.8; cfg.model_config.qwen3_asr.seed = 42
        cfg.model_config.num_threads = Int32(options.threads); cfg.model_config.provider = UnsafePointer(c[4])
        cfg.decoding_method = UnsafePointer(c[5])
        guard let r = SherpaOnnxCreateOfflineRecognizer(&cfg) else { return nil }
        return SherpaOfflineTranscriber(recognizer: r, vadPath: vad(in: dir), options:options)
    }

    static func nemoTransducer(dir: URL, options:LocalRecognitionOptions) -> SherpaOfflineTranscriber? {
        let values: [String] = [dir.appendingPathComponent("encoder.int8.onnx").path, dir.appendingPathComponent("decoder.int8.onnx").path,
                                dir.appendingPathComponent("joiner.int8.onnx").path, dir.appendingPathComponent("tokens.txt").path,
                                "nemo_transducer", "cpu", "greedy_search"]
        let c = values.map { strdup($0)! }
        defer { c.forEach { free($0) } }
        var cfg = SherpaOnnxOfflineRecognizerConfig()
        cfg.feat_config.sample_rate = 16000; cfg.feat_config.feature_dim = 80
        cfg.model_config.transducer.encoder = UnsafePointer(c[0]); cfg.model_config.transducer.decoder = UnsafePointer(c[1]); cfg.model_config.transducer.joiner = UnsafePointer(c[2])
        cfg.model_config.tokens = UnsafePointer(c[3]); cfg.model_config.model_type = UnsafePointer(c[4])
        cfg.model_config.num_threads = Int32(options.threads); cfg.model_config.provider = UnsafePointer(c[5])
        cfg.decoding_method = UnsafePointer(c[6])
        guard let r = SherpaOnnxCreateOfflineRecognizer(&cfg) else { return nil }
        return SherpaOfflineTranscriber(recognizer: r, vadPath: vad(in: dir), options:options)
    }

    func transcribe(_ samples: [Float]) -> String {
        lock.lock(); defer { lock.unlock() }
        guard !samples.isEmpty, let stream = SherpaOnnxCreateOfflineStream(recognizer) else { return "" }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer { SherpaOnnxAcceptWaveformOffline(stream, 16000, $0.baseAddress, Int32(samples.count)) }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let r = SherpaOnnxGetOfflineStreamResult(stream) else { return "" }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(r) }
        return r.pointee.text.map { String(cString: $0) } ?? ""
    }

    func speechSegments(_ samples: [Float]) -> [Range<Int>] {
        guard let vadPath else { return [] }
        lock.lock(); defer { lock.unlock() }
        var cfg = SherpaOnnxVadModelConfig()
        let path = strdup(vadPath)!, provider = strdup("cpu")!
        defer { free(path); free(provider) }
        cfg.silero_vad.model = UnsafePointer(path); cfg.silero_vad.threshold = options.vadThreshold
        cfg.silero_vad.min_silence_duration = LocalDecoder.vadMinSilence; cfg.silero_vad.min_speech_duration = LocalDecoder.vadMinSpeech
        cfg.silero_vad.window_size = 512; cfg.silero_vad.max_speech_duration = 20
        cfg.sample_rate = 16000; cfg.num_threads = 1; cfg.provider = UnsafePointer(provider)
        guard let vad = SherpaOnnxCreateVoiceActivityDetector(&cfg, 60) else { return [] }
        defer { SherpaOnnxDestroyVoiceActivityDetector(vad) }
        var ranges: [Range<Int>] = []
        func drain() {
            while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
                if let seg = SherpaOnnxVoiceActivityDetectorFront(vad) {
                    let start = Int(seg.pointee.start), n = Int(seg.pointee.n)
                    if n > 0 { ranges.append(start..<min(samples.count, start + n)) }
                    SherpaOnnxDestroySpeechSegment(seg)
                }
                SherpaOnnxVoiceActivityDetectorPop(vad)
            }
        }
        samples.withUnsafeBufferPointer { buf in
            var i = 0
            while i < buf.count { let n = min(512, buf.count - i); SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, buf.baseAddress! + i, Int32(n)); i += n; drain() }
        }
        SherpaOnnxVoiceActivityDetectorFlush(vad); drain()
        return ranges
    }
}
#endif
