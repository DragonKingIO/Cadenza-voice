import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox

enum SessionState: Equatable {
    /// 录音中（hold：按住 Start / 窗口按钮）
    case voiceStarted
    /// 已停止采集，等待识别最终结果（recognizing）
    case awaitingConfirm
}

enum ResultAction { case retry, result, privacy, targetHelp }

enum HoldSource { case hotkey, button, menu, toggle }

final class VoiceSession {
    /// 唯一会话 ID：超时、取消与旧识别回调不得影响下一次会话
    let id = UUID()
    let originalID: String
    let mode: String
    var source: HoldSource
    let focus: FocusIdentity
    /// No editor could be identified, but the original process and window are known. Text is
    /// sent to that process only while its front window is unchanged.
    var windowBound=false
    let localOnly: Bool
    var state: SessionState = .voiceStarted
    var baselineWindows: Set<String> = []
    var lastPanelDelta: Set<String> = []
    var retentionReason: String?
    var didTracePostPresentation = false
    var sawValueChange = false
    /// 会话内观测到的峰值电平（rms×10）：静音防幻觉依据，仅内存
    var peakLevel: Float = 0
    var levelSamples = 0
    let startedAt: Date
    var startedUptime=ProcessInfo.processInfo.systemUptime

    init(originalID: String, mode: String, focus: FocusIdentity, source: HoldSource = .hotkey, localOnly: Bool = false, startedAt: Date = Date()) {
        self.originalID = originalID
        self.mode = mode
        self.focus = focus
        self.source = source
        self.localOnly = localOnly || source == .button
        self.startedAt = startedAt
    }
}

/// 会话模型（本轮重构）：
/// - 进入会话前必须成功保存原输入源、焦点身份通过适合性检查；
/// - 窗口信号只作证据记录，不驱动状态（对应关系未验证）；
/// - 用户手动切换输入源 → 结束会话且绝不恢复旧源；
/// - 焦点身份变化 → 中止会话，不盲发停止键（停止语义未验证）；
/// - 恢复只能由人工触发（菜单/退出停用确认路径），不自动伪报完成。
final class VoicePipeline {
    let configStore: ConfigStore
    let input: InputSourceController
    var selfTestMode = false
    var inputSuspendedForDiagnostic=false
    var recorderFactory: (() -> HoldRecordingSession)?
    var insertText: (String,FocusIdentity) -> Bool = TextInserter.insert
    var insertIntoWindow: (String,FocusIdentity) -> Bool = {TextInserter.sendUnicode($0,target:$1,windowBound:true)}
    var now: () -> Date = Date.init
    var snapshotFocus: () -> FocusIdentity? = FocusProbe.snapshot
    /// True when the system says Accessibility is off or the grant no longer answers. Test and preview runs ask no questions
    /// (see `TCC`), so they are never "lost".
    /// Polishes text with a language model when the person turned that on. Replaced in tests.
    var textRefiner: TextRefining = LLMTextRefiner()
    /// True while the polished text is awaited; the recognition time-out must not fire then.
    private(set) var refining = false
    /// Why the text was inserted without polishing, shown after the result.
    private(set) var refineNote: String?
    /// Everything done to recognized text before it is inserted, without a network: stray marks, the tidy step, the vocabulary and
    /// the person's own replacements. The log gets what the tidy step did as counts, so each engine's need for it can be read off
    /// real use without ever recording what was said.
    private func tidyAndCorrect(_ raw: String) -> String {
        let cleaned = ASRPunctuationCleanup.apply(raw)
        let tidied = TextPolish.applyReporting(cleaned, config.polish)
        let r = tidied.report
        let engine = config.engine == "local" ? "local/" + config.localModel.primaryModelID : config.engine
        Log.write("polish engine=\(engine) level=\(config.polish.level.rawValue) hesitations=\(r.hesitations) repeats=\(r.repeats) connectors=\(r.connectors) paragraphs=\(r.paragraphs) changed=\(r.changed) chars=\(raw.count)->\(tidied.text.count)")
        return LocalASRCorrection.apply(vocabulary(tidied.text), maps: config.localASRMappings)
    }

    /// Fixes mis-recognized terms from the vocabulary (the person's own and the packs they switched on).
    private func vocabulary(_ text: String) -> String { VocabularyStore.shared.apply(text, config.vocabulary) }
    var accessibilityLost: () -> Bool = { !TCC.isolated && !FocusProbe.accessibilityTrusted }
    var onStateChange: (() -> Void)?
    /// Fired on the main thread after any session has been torn down (used by the local developer API).
    var onSessionFinished: (() -> Void)?
    var coordinatedSession=false
    private(set) var coordinatedCopied=false
    var coordinatedStop:(()->Bool)?
    var coordinatedCancel:(()->Bool)?
    var coordinatedFinal:((String?)->Void)?
    private var recordingAccessibility:RecordingAccessibilityLease?
    var copyToClipboard:(String)->Void={text in NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)}

    private(set) var session: VoiceSession?
    private(set) var diagnosticTarget:WechatDiagnosticTarget?
    private(set) var lastResult = "—"
    /// UI state is independent of the wording of a message.
    private(set) var lastIsError = false
    private(set) var lastInputAccepted = false
    private(set) var resultAction: ResultAction = .retry
    /// 最近一次识别文本：仅内存保留，显示在设置窗口"最近识别结果"，用户可复制/清空
    private(set) var lastTranscript: String?
    private var lastPartial = ""   // 识别中途的部分文本（超时兜底提交用）
    private var recognizingSince: Date?
    var hasActiveSession: Bool { session != nil }

    /// 实时音量（录音时），界面电平条消费
    var onLevel: ((Float) -> Void)?

    /// 供 UI 层写入"上次"提示行
    func note(_ text: String, isError: Bool = false) { lastResult = text; lastIsError = isError; lastInputAccepted = false }

    /// 用户主动清空最近识别结果
    func clearTranscript() { lastTranscript = nil;diagnosticTarget=nil;lastResult="—";lastIsError=false;lastInputAccepted=false;resultAction = .retry;notifyUI() }

    private var recorder: HoldRecordingSession?
    private var pollTimer: Timer?
    private var config: BridgeConfig { configStore.config }

    init(configStore: ConfigStore, input: InputSourceController) {
        self.configStore = configStore
        self.input = input
        // 老管线观察器已随 minimal/auto 模式删除
    }

    var statusText: String {
        if !config.enabled { return L10n.tr("ui.a8c3698b5b8c") }
        guard let s = session else { return L10n.tr("ui.dae661d17c2d") }
        switch s.state {
        case .voiceStarted: if s.source == .toggle { return L10n.tr("ui.1d31e139f993") };return s.source == .menu ? L10n.tr("ui.0608e02d93ed") : s.source == .button ? L10n.tr("ui.2e0418bca583") : L10n.format("ui.3b9d6592907d", String(describing: HotkeySpecDisplay.string(configStore.config.trigger)))
        case .awaitingConfirm: return L10n.tr("ui.f3e72eb38719")
        }
    }

    // MARK: - 触发

    func triggerFired() {
        // hold 模式：按键生命周期由 onHoldStart/onHoldEnd 驱动，触发回调仅记录
        Log.write("trigger-ignored mode=hold")
        notifyUI()
    }

    // MARK: - 独立语音路线（hold 模式）：全程不调用 TIS，苹果输入源保持不变

    /// 左 Option 单独按下（或窗口按钮按下）→ 立即开始录音
    func holdStarted(source: HoldSource = .hotkey, target: FocusIdentity? = nil, localOnly: Bool = false) {
        Log.write("hold-start-invoked source=\(String(describing:source)) sessionActive=\(session != nil) mode=\(config.mode) enabled=\(config.enabled)")
        guard !inputSuspendedForDiagnostic else{Log.write("hold-refused diagnostic-only=true no-recorder=true");return}
        guard config.enabled, config.mode == SessionMode.hold.rawValue else { return }
        if session?.state == .awaitingConfirm {
            forceEnd(reason: L10n.tr("ui.7900a992fafc"))
        }
        if session?.state == .voiceStarted, session?.source == .toggle { holdEnded();return }
        guard session == nil else { return }
        lastIsError=false;lastInputAccepted=false;resultAction = .retry
        coordinatedCopied=false
        if !configStore.validationErrors.isEmpty {
            lastResult = L10n.tr("ui.e0b290cbbb73");lastIsError=true
            Log.write("HOLD-refused invalid-config")
            notifyUI()
            return
        }
        // "Only recognize on this Mac": refuse every method that could send audio anywhere, whatever the saved engine is.
        if LocalOnlyMode.enabled, recorderFactory == nil, ASREngine(rawValue: config.engine) != .local {
            lastResult = L10n.tr("localonly.blocked");lastIsError = true;resultAction = .retry
            Log.write("HOLD-refused local-only-mode engine-blocked=true")
            notifyUI();return
        }
        var startFocus = target ?? snapshotFocus()
        var pendingAccessibility:RecordingAccessibilityLease?
        defer {_ = pendingAccessibility?.restore()}
        if source != .button, !localOnly,startFocus?.identityAvailable != true,
           let original=WechatDiagnosticTarget.capture(startFocus),
           let adapter=NativeWechatEnhancedAdapter(pid:original.pid,cursorConfirmed:true,expectedTarget:original),
           let lease=RecordingAccessibilityLease.begin(adapter) {
            let refreshed=snapshotFocus()
            if let refreshed=refreshed,refreshed.identityAvailable,refreshed.pid == original.pid,
               refreshed.window.map({CFEqual($0,original.window)}) == true,original.validate() == .same {
                pendingAccessibility=lease;startFocus=refreshed
                Log.write("recording-accessibility focused-editor-confirmed=true scoped=true")
            } else {_ = lease.restore();Log.write("recording-accessibility focused-editor-confirmed=false scoped=true")}
        }
        diagnosticTarget=localOnly ? nil:WechatDiagnosticTarget.capture(startFocus)
        FocusProbe.trace(startFocus,stage:"start-before-capsule",branch:startFocus?.protectedInput == true ? "protected-reject" : startFocus?.automaticInputAvailable == true ? "trusted-target" : "retain-only")
        resultAction = .retry
        if startFocus?.protectedInput == true {
            lastResult = L10n.tr("ui.3e9d64dee474");lastIsError=true
            resultAction = .targetHelp
            notifyUI();return
        }
        // 引擎选择：apple = 本机识别；iflytek = 官方听写 API（凭据在钥匙串）
        let sessionRecorder: HoldRecordingSession
        if let factory = recorderFactory {
            sessionRecorder = factory()
        } else if ASREngine(rawValue:config.engine) == .local {
            guard HoldNativeEngine.micAuthorized() else{lastResult=L10n.format("ui.3f8508000a35", String(describing: Brand.name));lastIsError=true;resultAction = .privacy
                if TCC.micStatus() == .notDetermined {TCC.requestMic{_ in DispatchQueue.main.async{self.notifyUI()}}};notifyUI();return}
            guard LocalTranscriberLoader.supported else{lastResult=L10n.tr("local.err.unsupportedBuild");lastIsError=true;notifyUI();return}
            let ready=LocalModelCenter.shared.installedEntries.filter{LocalModelCatalog.usable($0)}
            guard let model=FallbackPolicy.resolvePrimary(settings:config.localModel,ready:ready,recognitionLocale:config.recognitionLocale) else{lastResult=L10n.tr(ready.isEmpty ? "local.err.notInstalled":"local.err.noLanguageModel");lastIsError=true;notifyUI();return}
            sessionRecorder=LocalASRRecorder(modelID:model.id,options:config.localModel.recognition.resolved(forLanguages:[config.recognitionLocale]))
        } else if let provider=ASREngine(rawValue:config.engine),provider != .apple {
            guard config.options(provider).consent else{lastResult=L10n.tr("ui.eadd4394cde5");lastIsError=true;notifyUI();return}
            guard let credentials=provider.credentials() else{lastResult=L10n.tr("ui.af6ae89316e3");lastIsError=true;notifyUI();return}
            guard HoldNativeEngine.micAuthorized() else{lastResult=L10n.format("ui.3f8508000a35", String(describing: Brand.name));lastIsError=true;resultAction = .privacy
                if TCC.micStatus() == .notDetermined {TCC.requestMic{_ in DispatchQueue.main.async{self.notifyUI()}}};notifyUI();return}
            let options=config.recordingOptions(provider),language=IflytekRecorder.resolveLanguage(config.iflytekLanguage,forSourceID:input.currentID())
            let makeCloud:(CloudPCMCapturing)->HoldRecordingSession={CloudASRRecorder(provider:provider,options:options,credentials:credentials,language:language,capture:$0)}
            // 回退：云端失败或没网时改用本地模型；没有可用本地模型或未启用则保持原行为
            let fallbackLanguages=FallbackPolicy.languages(provider:provider,options:options,iflytekLanguage:config.iflytekLanguage,recognitionLocale:config.recognitionLocale)
            let ready=LocalModelCenter.shared.installedEntries.filter{LocalModelCatalog.usable($0) && LocalModelCatalog.covers($0,languages:fallbackLanguages)}
            var localOptions=config.localModel.recognition;localOptions.language="auto";localOptions=localOptions.resolved(forLanguages:fallbackLanguages)
            switch FallbackPolicy.plan(settings:config.localModel,online:NetworkReachability.shared.isOnline,ready:ready,languages:fallbackLanguages) {
            case .cloudOnly: sessionRecorder=makeCloud(CloudPCMCapture())
            case .cloudWithFallback(let id): sessionRecorder=FallbackRecordingSession(modelID:id,options:localOptions,makePrimary:makeCloud)
            case .localDirect(let id):
                let local=LocalASRRecorder(modelID:id,options:localOptions);local.fallbackNotice=L10n.tr("local.fallback.notice.offline");sessionRecorder=local
                Log.write("fallback offline-direct=true provider=\(provider.rawValue)")
            }
        } else {
            sessionRecorder = HoldNativeEngine(locale: config.recognitionLocale,
                                               allowCloud: config.allowCloudRecognition)
        }
        if let native = sessionRecorder as? HoldNativeEngine { native.microphoneUID = config.microphoneUID }
        if let cloud = sessionRecorder as? CloudASRRecorder { cloud.microphoneUID = config.microphoneUID }
        if let fallback = sessionRecorder as? FallbackRecordingSession { fallback.microphoneUID = config.microphoneUID }
        if let local = sessionRecorder as? LocalASRRecorder { local.microphoneUID = config.microphoneUID }
        let s = VoiceSession(originalID: input.currentID() ?? "unknown",
                             mode: SessionMode.hold.rawValue,
                             focus: startFocus ?? FocusIdentity(pid: 0, appName: "?", element: nil, window: nil, role: nil, readable: false, selectedTextWritable: false, value: nil),
                             source: source, localOnly:localOnly, startedAt:now())
        if !s.localOnly && (startFocus?.identityAvailable != true || startFocus?.pid == ProcessInfo.processInfo.processIdentifier) {
            s.retentionReason = L10n.tr("ui.445cf889c2e0")
        }
        if !s.localOnly,s.retentionReason != nil,startFocus?.identityAvailable != true,startFocus?.windowBoundAvailable == true {
            s.windowBound=true;s.retentionReason=nil
            Log.write("HOLD-TARGET window-bound=true editor-identified=false")
        }
        let sid = s.id
        lastPartial = ""
        lastTranscript = nil
        recognizingSince = nil
        recordingAccessibility=pendingAccessibility;pendingAccessibility=nil
        session = s
        recorder = sessionRecorder
        recorder?.onLevel = { [weak self] v in
            DispatchQueue.main.async {
                guard let self = self, self.session?.id == sid, self.session?.state == .voiceStarted else { return }
                self.session?.peakLevel = max(self.session?.peakLevel ?? 0, v)
                self.session?.levelSamples += 1
                self.onLevel?(v)
            }
        }
        recorder?.onPartial = { [weak self] full in
            DispatchQueue.main.async {
                guard let self = self, self.session?.id == sid else { return }
                guard self.recorder?.capturedAudioHasSignal != false else{return}
                self.lastPartial = full      // 超时兜底提交用
                self.lastTranscript = full   // 流式部分结果实时显示
                self.notifyUI()
            }
        }
        recorder?.onFinal = { [weak self] text in
            DispatchQueue.main.async {
                guard let self = self, self.session?.id == sid else { return } // 旧会话回调不影响下一次会话
                if self.coordinatedSession,self.session?.state == .voiceStarted {
                    _ = self.coordinatedCancel?();self.note(L10n.tr("ui.cc54a5947876"),isError:true);self.onStateChange?();return
                }
                let coordinated=self.coordinatedSession
                let corrected=text.map{self.tidyAndCorrect($0)}
                let finish:(String?)->Void={[weak self] final in self?.holdFinalized(text:final);if coordinated {self?.coordinatedFinal?(self?.lastTranscript)}}
                // Optional AI polishing: only text goes out, only when the person turned it on, and any failure keeps the text as it is.
                let refine=self.config.refine
                if let text=corrected,refine.enabled,refine.configured,self.recorder?.capturedAudioHasSignal != false,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                    self.refining=true;self.refineNote=nil;self.notifyUI()
                    self.textRefiner.refine(text,settings:refine,glossary:VocabularyStore.shared.glossary(for:text,self.config.vocabulary)){[weak self] refined,note in
                        DispatchQueue.main.async {
                            guard let self=self,self.session?.id == sid else{return}
                            self.refining=false;self.refineNote=note
                            finish(refined ?? text)
                        }
                    }
                    return
                }
                finish(corrected)
            }
        }
        let ok = recorder?.begin() ?? false
        if !ok {
            let error = recorder?.lastError ?? L10n.tr("ui.13a46616e16f")
            lastResult = L10n.tr("ui.5cc1b714183d") + ASRUserMessage.describe(error);lastIsError=true
            if !HoldNativeEngine.micAuthorized() || config.engine == "apple" && !HoldNativeEngine.speechAuthorized() { resultAction = .privacy }
            finishSession()
            Log.write("HOLD-start-failed")
            notifyUI()
            return
        }
        s.startedUptime=recorder?.captureStartedUptime ?? ProcessInfo.processInfo.systemUptime
        Log.write("HOLD-START id=\(sid.uuidString.prefix(8)) source=\(String(describing:source)) sourceAtStart=\(s.originalID)（全程不切换输入源）")
        lastResult = source == .toggle ? (config.toggleShortcutEnabled ? L10n.tr("ui.b3a96dd3c626"):L10n.tr("ui.7ed2b7b58229")) : source == .menu ? L10n.tr("ui.044ccf22ebb6") : source == .hotkey ? L10n.format("ui.05210b069225", String(describing: HotkeySpecDisplay.string(configStore.config.trigger))) : L10n.tr("ui.807a638c1bbc")
        if let reason=s.retentionReason { lastResult += "；" + reason }
        startTimer()
        notifyUI()
    }

    func togglePressed(localOnly:Bool=false) {
        if session?.state == .voiceStarted {holdEnded();return}
        holdStarted(source:.toggle,localOnly:localOnly)
    }
    /// 干净松开 → 停止录音，等待最终识别结果
    func holdEnded() {
        if coordinatedStop?() == true{return}
        guard let s = session, s.mode == SessionMode.hold.rawValue, s.state == .voiceStarted else { return }
        Log.write("HOLD-END")
        s.state = .awaitingConfirm
        recognizingSince = now()
        recorder?.end()
        notifyUI()
    }

    /// 按住期间构成组合键（Option+C 等）或焦点变化 → 取消录音并丢弃，不提交文字
    func holdChord(reason: String) {
        if coordinatedCancel?() == true{return}
        guard let s = session, s.mode == SessionMode.hold.rawValue, s.state == .voiceStarted else { return }
        Log.write("HOLD-CANCEL \(reason)（录音丢弃，不提交文字）")
        recorder?.abort()
        lastResult = L10n.tr("ui.2f7355427150");lastIsError=false;lastInputAccepted=false
        lastTranscript=nil
        finishSession()
    }

    private func holdFinalized(text: String?) {
        guard let s = session, s.mode == SessionMode.hold.rawValue else { return }
        // 录音中强制收尾（连接中断/超时）时先停引擎
        if s.state == .voiceStarted {
            recorder?.onFinal = nil
            recorder?.abort()
        }
        guard s.state == .voiceStarted || s.state == .awaitingConfirm else { return }
        s.state = .awaitingConfirm
        if recorder?.lastError?.isEmpty == false {s.retentionReason=L10n.tr("ui.278eee6d958e")}
        let silent=recorder?.capturedAudioHasSignal == false
        if silent {Log.write("HOLD-RESULT rejected=digital-silence-or-no-audio finalPresent=\(text?.isEmpty == false) partialPresent=\(!lastPartial.isEmpty)")}
        // New trigger path never substitutes partial text for an empty final result.
        if (coordinatedSession || recorder is LocalASRRecorder || recorder is FallbackRecordingSession), text?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty != false {lastPartial=""}
        if text == nil && !lastPartial.isEmpty {s.retentionReason=L10n.tr("ui.4d9d889ebd78")}
        let transcript = (silent ? "" : (text ?? lastPartial)).trimmingCharacters(in: .whitespacesAndNewlines)
        lastTranscript = transcript.isEmpty ? nil : transcript
        lastIsError=false;lastInputAccepted=false
        // 静音防幻觉：整段录音能量极低（仅环境噪声）→ 丢弃，防止云端把噪声误识成句子
        if !(recorder is LocalASRRecorder || (recorder as? FallbackRecordingSession)?.usedFallback == true), !transcript.isEmpty, s.levelSamples > 0, s.peakLevel < 0.22,
           now().timeIntervalSince(s.startedAt) >= 0.35 {
            lastTranscript = nil
            lastResult = L10n.tr("ui.e0f1304f638a");lastIsError=true
            Log.write("HOLD-DROP silence peak=\(s.peakLevel) samples=\(s.levelSamples) len=\(transcript.count)")
            finishSession()
            return
        }
        if transcript.isEmpty {
            if let hint = recorder?.lastError, !hint.isEmpty {
                lastResult = ASRUserMessage.describe(hint)
            } else {
                lastResult = L10n.tr("ui.79250fdff1f6")
            }
            lastIsError=true
            Log.write("HOLD-RESULT len=0 source=\(input.currentID() ?? "?") unchanged=\(input.currentID() == s.originalID) hintPresent=\(recorder?.lastError?.isEmpty == false)")
        } else {
            if s.localOnly {
                lastResult = L10n.tr("ui.37ec31b97ac0") + (recorder?.fallbackNotice.map { "；" + $0 } ?? "")
                finishSession()
                return
            }
            // Both the original and final target must be trusted; missing value alone is not an identity failure.
            let current = snapshotFocus()
            let change = FocusProbe.classify(previous:s.focus,current:current)
            FocusProbe.trace(current,stage:"final",branch:"\(change)")
            if s.windowBound,s.retentionReason == nil,let current=current,current.windowBoundAvailable,current.sameWindow(as:s.focus) {
                // Prefer an identified editor if one appeared; otherwise send to the unchanged original window.
                let delivered=current.identityAvailable ? insertText(transcript,current):insertIntoWindow(transcript,s.focus)
                Log.write("HOLD-INSERT window-bound editor=\(current.identityAvailable) delivered=\(delivered) len=\(transcript.count)")
                if delivered {lastResult = L10n.tr("ui.4979007279f2");lastInputAccepted=true}
                else {retainWithoutClipboard(transcript)}
            } else if s.retentionReason != nil || current?.identityAvailable != true || change != .unchanged {
                retainWithoutClipboard(transcript)
                Log.write("HOLD-INSERT retained reason=unverified-target focus=\(change) len=\(transcript.count)")
            } else if let current=current,insertText(transcript,current) {
                lastResult = L10n.tr("ui.4979007279f2");lastInputAccepted=true
                Log.write("HOLD-INSERT delivered focus=\(change) len=\(transcript.count)")
            } else {
                retainWithoutClipboard(transcript)
                Log.write("HOLD-INSERT retained reason=write-not-verified len=\(transcript.count)")
            }
            if let notice=recorder?.fallbackNotice {lastResult += "；" + notice}
            if let note=refineNote {lastResult += "；" + L10n.format("refine.kept",note)}
        }
        finishSession()
    }

    private func retainWithoutClipboard(_ text: String) {
        guard !text.isEmpty else { return }
        coordinatedCopied=false
        // Without a working Accessibility grant no target can be verified, so say that instead of a generic failure.
        if accessibilityLost() {lastResult=L10n.format("retained.noAccessibility",String(describing:Brand.name));lastIsError=true;resultAction = .privacy;return}
        lastResult=L10n.tr("ui.input.retained-no-clipboard");lastIsError=true;resultAction = .result
    }

    /// hold 模式轮询：录音期间监视焦点（变化即取消丢弃）与超时
    private func holdTick() {
        guard let s = session else { stopTimer(); return }
        switch s.state {
        case .voiceStarted:
            if !coordinatedSession && now().timeIntervalSince(s.startedAt) > min(600,config.recordingTimeoutSec) {
                Log.write("HOLD-TIMEOUT auto-stop")
                lastResult=L10n.tr("ui.6225c75da614")
                holdEnded()
                return
            }
            // 焦点核对仅对实体键来源；窗口按钮来源不向外部输入，焦点变化无影响
            guard !s.localOnly else { return }
            let cur = snapshotFocus()
            if !s.didTracePostPresentation {s.didTracePostPresentation=true;FocusProbe.trace(cur,stage:"first-tick-after-capsule",branch:s.retentionReason == nil ? "auto-input-candidate":"retain-only")}
            if cur?.protectedInput == true { FocusProbe.trace(cur,stage:"recording",branch:"protected-cancel");holdChord(reason:L10n.tr("ui.074408b2fc38"));return }
            if s.retentionReason == nil {
                let change=FocusProbe.classify(previous:s.focus,current:cur)
                let pidMoved=cur?.pid != nil && cur?.pid != s.focus.pid
                let lost=s.windowBound ? !(cur.map{$0.windowBoundAvailable && $0.sameWindow(as:s.focus)} ?? false)
                                       : ([.appChanged,.windowChanged,.elementChanged].contains(change) || pidMoved || change == .unknown)
                if lost {
                    s.retentionReason=L10n.tr("ui.e6cea6420943")
                    lastResult=L10n.tr("ui.9a02ff477cd0") + s.retentionReason!
                    FocusProbe.trace(cur,stage:"recording-after-capsule",branch:"retain-only-\(change)")
                    notifyUI()
                }
            }
        case .awaitingConfirm:
            // 云端保留原等待上限；本地按录音时长给予固定且有界的最终解码时间。
            let localWork=recorder is LocalASRRecorder || recorder is FallbackRecordingSession
            let waitLimit=localWork ? min(180,max(30,(recognizingSince ?? s.startedAt).timeIntervalSince(s.startedAt)*0.4+15)):12
            if !coordinatedSession, !refining, let since = recognizingSince, now().timeIntervalSince(since) > waitLimit {
                Log.write("HOLD recognize-timeout → finalize with partial")
                s.retentionReason=L10n.tr("ui.29fa51a01a10")
                holdFinalized(text: localWork || lastPartial.isEmpty ? nil : lastPartial)
            }
        }
    }

    private func finishSession() {
        refining = false;refineNote = nil
        session = nil // Invalidate callbacks before cancelling the underlying request.
        recorder?.onFinal = nil
        recorder?.onPartial = nil
        recorder?.onLevel = nil
        recorder?.abort()
        recorder = nil
        _ = recordingAccessibility?.restore();recordingAccessibility=nil
        lastPartial = ""
        recognizingSince = nil
        stopTimer()
        onLevel?(0)
        notifyUI()
        onSessionFinished?()
    }

    var resourcesIdle:Bool {session == nil && recorder == nil && pollTimer == nil && recognizingSince == nil && lastPartial.isEmpty}

    // MARK: - 轮询（窗口信号仅证据记录；auto 模式附加焦点检测与超时）

    private func startTimer() {
        guard pollTimer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: Double(config.focusPollMs) / 1000.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func stopTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func tick() {
        guard session != nil else { stopTimer(); return }
        holdTick()
    }

    // MARK: - 用户主动结束

    /// 菜单停用/退出应用时调用：丢弃当前会话（不提交文字），引擎就地停止
    func forceEnd(reason: String) {
        if coordinatedCancel?() == true{return}
        guard session != nil else { return }
        recorder?.abort()
        Log.write("HOLD-FORCE-END \(reason)")
        lastResult=L10n.tr("ui.2f7355427150");lastIsError=false;lastInputAccepted=false;lastTranscript=nil;diagnosticTarget=nil;resultAction = .retry
        finishSession()
    }

    private func notifyUI() { onStateChange?() }
}
