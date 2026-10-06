import Foundation
import Network

// MARK: - 回退策略（纯逻辑，便于验证）

struct LocalModelSettings: Codable, Equatable {
    /// 云端失败或没网时自动改用本地模型
    var enabled = true
    /// 空 = 自动（按识别语言在已安装的模型里选）
    var modelID = ""
    /// 检测到没网时不再尝试连接云端，直接用本地模型
    var offlineDirect = true
    /// 启动时静默检查模型更新（只下载小清单）
    var autoCheckUpdates = true
    /// 远端清单地址；空 = 用内置默认
    var manifestURL = ""
    /// 本地作为主引擎时使用的模型；空 = 自动
    var primaryModelID = ""
    var recognition = LocalRecognitionOptions()

    enum CodingKeys: String, CodingKey { case enabled, modelID, offlineDirect, autoCheckUpdates, manifestURL, primaryModelID, recognition }
    init() {}
    init(from decoder: Decoder) throws {
        let d = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try d.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        modelID = try d.decodeIfPresent(String.self, forKey: .modelID) ?? ""
        offlineDirect = try d.decodeIfPresent(Bool.self, forKey: .offlineDirect) ?? true
        autoCheckUpdates = try d.decodeIfPresent(Bool.self, forKey: .autoCheckUpdates) ?? true
        manifestURL = try d.decodeIfPresent(String.self, forKey: .manifestURL) ?? ""
        primaryModelID = try d.decodeIfPresent(String.self, forKey: .primaryModelID) ?? ""
        recognition = try d.decodeIfPresent(LocalRecognitionOptions.self,forKey:.recognition) ?? LocalRecognitionOptions()
    }
}

enum FallbackPlan: Equatable {
    case cloudOnly                       // 未启用回退，或没有可用的本地模型
    case cloudWithFallback(String)       // 先走云端，失败时用该本地模型
    case localDirect(String)             // 没网：直接本地
}

enum FallbackPolicy {
    /// 回退使用哪个已安装的模型：用户指定且可用 → 用它；否则（含“自动”）按语言挑选
    static func resolveModel(settings: LocalModelSettings, ready: [LocalModelEntry], languages: [String]) -> LocalModelEntry? {
        let compatible=ready.filter{LocalModelCatalog.covers($0,languages:languages)}
        if !settings.modelID.isEmpty, let e = compatible.first(where: { $0.id == settings.modelID }) { return e }
        return LocalModelCatalog.pick(forLanguages: languages, installed: compatible)
    }

    static func resolvePrimary(settings:LocalModelSettings,ready:[LocalModelEntry],recognitionLocale:String)->LocalModelEntry? {
        if let selected=ready.first(where:{$0.id==settings.primaryModelID}) {return selected}
        var automatic=settings;automatic.modelID=""
        return resolveModel(settings:automatic,ready:ready,languages:settings.recognition.language == "auto" ? [recognitionLocale]:[settings.recognition.language])
    }

    /// online == nil 表示尚未得到网络状态：按有网处理，失败时再回退
    static func plan(settings: LocalModelSettings, online: Bool?, ready: [LocalModelEntry], languages: [String], supported: Bool = LocalTranscriberLoader.supported) -> FallbackPlan {
        guard supported, settings.enabled, let model = resolveModel(settings: settings, ready: ready, languages: languages) else { return .cloudOnly }
        if online == false, settings.offlineDirect { return .localDirect(model.id) }
        return .cloudWithFallback(model.id)
    }

    /// 识别语言偏好 → 语言代码列表（用于选模型）
    static func languages(iflytekLanguage: String, recognitionLocale: String) -> [String] {
        switch iflytekLanguage {
        case "en_us": return ["en"]
        case "zh_cn": return ["zh"]
        default: return [recognitionLocale]
        }
    }
    static func languages(provider:ASREngine,options:CloudASROptions,iflytekLanguage:String,recognitionLocale:String)->[String] {
        switch provider {
        case .deepgram:return DeepgramAPI.fallbackLanguages(options)
        case .iflytek:return iflytekLanguage == "auto" ? ["zh","en"]:languages(iflytekLanguage:iflytekLanguage,recognitionLocale:recognitionLocale)
        case .tencent:return options.model == "16k_en" ? ["en"]:options.model == "16k_zh_en" ? ["zh","en"]:["zh"]
        case .baidu:return options.model == "1737" ? ["en"]:options.model == "1637" ? ["yue"]:["zh"]
        default:return [recognitionLocale]
        }
    }

}

// MARK: - 网络状态

final class NetworkReachability {
    static let shared = NetworkReachability()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var state: Bool?
    /// nil = 还没收到系统的首次回报
    var isOnline: Bool? { lock.lock(); defer { lock.unlock() }; return state }
    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock(); self.state = path.status == .satisfied; self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "cadenza.network.path"))
    }
}

// MARK: - 云端 + 本地回退会话
// 云端识别器照常工作，同时把同一份 PCM 缓冲在内存里（最长 120 秒，会话结束即丢弃）。
// 云端失败（连接/鉴权/超时/服务错误）时，不让用户重说：用缓冲音频交给本地模型。
// 录音过程中云端中途失败，则继续录音，松开后再用本地模型识别整段。

final class FallbackRecordingSession: HoldRecordingSession {
    private let callbackLock = NSLock()
    private var levelCB: ((Float) -> Void)?, partialCB: ((String) -> Void)?, finalCB: ((String?) -> Void)?
    var onLevel: ((Float) -> Void)? { get { callbackLock.lock(); defer { callbackLock.unlock() }; return levelCB } set { callbackLock.lock(); levelCB = newValue; callbackLock.unlock() } }
    var onPartial: ((String) -> Void)? { get { callbackLock.lock(); defer { callbackLock.unlock() }; return partialCB } set { callbackLock.lock(); partialCB = newValue; callbackLock.unlock() } }
    var onFinal: ((String?) -> Void)? { get { callbackLock.lock(); defer { callbackLock.unlock() }; return finalCB } set { callbackLock.lock(); finalCB = newValue; callbackLock.unlock() } }
    private(set) var lastError: String?
    private(set) var fallbackNotice: String?
    var captureStartedUptime: TimeInterval? { real.startedUptime }
    var capturedAudioHasSignal: Bool? { real.hasSignal }
    var microphoneUID = ""
    var usedFallback: Bool { fallbackNotice != nil }

    static let bufferLimitBytes = 120 * 16000 * 2
    /// 松开后云端迟迟没有最终结果时，等这么久就改用本地识别（云端自己的超时是 10 秒，太长）
    var graceSeconds: TimeInterval = 6

    private let real: CloudPCMCapturing
    private let makePrimary: (CloudPCMCapturing) -> HoldRecordingSession
    private let decode: ([Float]) throws -> String
    private let queue = DispatchQueue(label: "cadenza.fallback.session")
    private let proxy = PrimaryCaptureProxy()
    private var primary: HoldRecordingSession?
    private let bufferLock = NSLock()
    private var buffer = Data(), overflow = false
    private var degraded = false, userEnded = false, cancelled = false, delivered = false, began = false
    private var primaryError: String?

    /// - Parameters:
    ///   - makePrimary: 用给定的采集器创建云端识别器
    ///   - decode: 16 kHz float 样本 → 文字（默认走本地识别器缓存）
    init(modelID: String, capture: CloudPCMCapturing = CloudPCMCapture(),
         center: LocalModelCenter = .shared, cache: LocalTranscriberCache = .shared,
         options:LocalRecognitionOptions = LocalRecognitionOptions(),
         decode: (([Float]) throws -> String)? = nil,
         makePrimary: @escaping (CloudPCMCapturing) -> HoldRecordingSession) {
        real = capture; self.makePrimary = makePrimary
        self.decode = decode ?? { samples in try LocalDecoder.transcribe(samples, with: cache.transcriber(for: modelID, center: center, options:options)) }
        proxy.owner = self
    }

    func begin() -> Bool {
        guard !began else { return false }
        began = true
        let p = makePrimary(proxy); primary = p
        p.onPartial = { [weak self] t in self?.onPartial?(t) }
        p.onFinal = { [weak self] t in self?.queue.async { self?.primaryFinished(t) } }
        guard p.begin() else {
            lastError = p.lastError
            // 云端无法开始，但麦克风已在工作：继续录音，松开后交给本地
            if real.startedUptime != nil { queue.async { self.degrade(reason: p.lastError) }; return true }
            return false
        }
        return true
    }

    fileprivate var realLastError: String? { real.lastError }

    fileprivate func startReal(uid: String) -> Bool {
        real.onLevel = { [weak self] v in self?.onLevel?(v); self?.proxy.level?(v) }
        real.onPCM = { [weak self] data in
            guard let self else { return }
            self.bufferLock.lock()
            if self.buffer.count + data.count <= Self.bufferLimitBytes { self.buffer.append(data) } else { self.overflow = true }
            self.bufferLock.unlock()
            self.proxy.pcm?(data)
        }
        let ok = real.start(uid: microphoneUID.isEmpty ? uid : microphoneUID)
        if !ok { lastError = real.lastError }
        return ok
    }

    private func degrade(reason: String?) {
        degraded = true; primaryError = reason
        proxy.detach()
        onPartial?("")
    }

    private func primaryFinished(_ text: String?) {
        guard !cancelled, !delivered else { return }
        let failed = (primary?.lastError?.isEmpty == false) && text == nil
        if !failed { deliver(text); return }
        let reason = primary?.lastError
        bufferLock.lock(); let usable = !overflow && !buffer.isEmpty; bufferLock.unlock()
        guard usable else { lastError = reason; deliver(nil); return }
        if userEnded { runLocal(reason: reason) } else { degrade(reason: reason) }   // 仍在录音：继续录，松开后再识别
    }

    func end() {
        real.stop()      // 先冲刷采集尾音，再通知云端结束
        queue.async { [self] in
            guard !cancelled, !userEnded else { return }
            userEnded = true
            if degraded { runLocal(reason: primaryError) } else {
                primary?.end()
                queue.asyncAfter(deadline: .now() + graceSeconds) { [self] in
                    guard !cancelled, !delivered else { return }
                    Log.write("fallback grace-expired seconds=\(graceSeconds)")
                    let reason = L10n.tr("local.fallback.timeout")
                    bufferLock.lock(); let usable = !overflow && !buffer.isEmpty; bufferLock.unlock()
                    guard usable else { return }   // 无法回退：保持原来的等待与云端自己的超时
                    primary?.abort()
                    runLocal(reason: reason)
                }
            }
        }
    }

    private func runLocal(reason: String?) {
        bufferLock.lock(); let pcm = buffer; bufferLock.unlock()
        let hasSignal = real.hasSignal
        let samples = LocalDecoder.samples(fromPCM16: pcm)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var text = ""
            var failure: String?
            do { text = try decode(samples) } catch { failure = L10n.tr("local.err.load") }
            queue.async { [self] in
                guard !cancelled, !delivered else { return }
                if let failure, text.isEmpty { lastError = (reason ?? "") + (reason == nil ? "" : "；") + failure; deliver(nil); return }
                fallbackNotice = L10n.tr("local.fallback.notice")
                Log.write("fallback used=true reason=\(reason ?? "offline") len=\(text.count)")
                lastError = nil
                deliver(text.isEmpty || !hasSignal ? nil : text)
            }
        }
    }

    private func deliver(_ text: String?) {
        guard !delivered else { return }
        delivered = true
        real.stop()
        bufferLock.lock();buffer.removeAll();bufferLock.unlock()
        real.onPCM = nil; real.onLevel = nil
        let cb = onFinal; onFinal = nil; onPartial = nil
        cb?(text)
    }

    func abort() {
        real.stop(); real.onPCM = nil; real.onLevel = nil
        queue.sync { cancelled = true }
        primary?.abort()
        bufferLock.lock(); buffer.removeAll(); bufferLock.unlock()
        onFinal = nil; onPartial = nil; onLevel = nil
    }
}

/// 交给云端识别器的“采集器”：真正的麦克风由回退会话持有。
/// 云端识别器调用 stop()（结束或失败）只会断开自己，不会停掉麦克风。
private final class PrimaryCaptureProxy: CloudPCMCapturing {
    weak var owner: FallbackRecordingSession?
    private let lock = NSLock()
    private var pcmCB: ((Data) -> Void)?, levelCB: ((Float) -> Void)?
    var onPCM: ((Data) -> Void)? { get { lock.lock(); defer { lock.unlock() }; return pcmCB } set { lock.lock(); pcmCB = newValue; lock.unlock() } }
    var onLevel: ((Float) -> Void)? { get { lock.lock(); defer { lock.unlock() }; return levelCB } set { lock.lock(); levelCB = newValue; lock.unlock() } }
    var pcm: ((Data) -> Void)? { onPCM }
    var level: ((Float) -> Void)? { onLevel }
    var hasSignal: Bool { owner?.capturedAudioHasSignal == true }
    var startedUptime: TimeInterval? { owner?.captureStartedUptime }
    var lastError: String? { owner?.realLastError }
    func start(uid: String) -> Bool { owner?.startReal(uid: uid) ?? false }
    func stop() { detach() }
    func detach() { lock.lock(); pcmCB = nil; levelCB = nil; lock.unlock() }
}
