import AVFoundation
import Speech

// MARK: - Apple Speech 引擎（本机识别，免费无账号；不支持本机时按配置拒绝）

final class HoldNativeEngine: NSObject, HoldRecordingSession {
    private let audioEngine = AVAudioEngine()
    private let audioEvidence=AudioSignalEvidence()
    var capturedAudioHasSignal:Bool? {audioEvidence.hasSignal}
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finalHandler: ((String?) -> Void)?
    private(set) var active = false
    private(set) var captureStartedUptime:TimeInterval?
    private(set) var lastError: String?
    private var startedAt = Date.distantPast

    var locale = "zh-CN"
    var allowCloud = false
    var onLevel: ((Float) -> Void)?
    var onPartial: ((String) -> Void)?
    var onFinal: ((String?) -> Void)?

    init(locale: String, allowCloud: Bool) {
        self.locale = locale
        self.allowCloud = allowCloud
    }

    static func micAuthorized() -> Bool {
        TCC.micStatus() == .authorized
    }

    static func speechAuthorized() -> Bool {
        TCC.speechStatus() == .authorized
    }

    static func requestAll(_ done: @escaping (Bool) -> Void) {
        TCC.requestMic { micOK in
            TCC.requestSpeech { status in
                DispatchQueue.main.async { done(micOK && status == .authorized) }
            }
        }
    }

    static func requestRequired(engine: String, _ done: @escaping (Bool) -> Void) {
        func speech(_ micOK: Bool) {
            guard engine == "apple" else { DispatchQueue.main.async { done(micOK) }; return }
            guard TCC.speechStatus() == .notDetermined else { DispatchQueue.main.async { done(micOK && speechAuthorized()) }; return }
            TCC.requestSpeech { status in DispatchQueue.main.async { done(micOK && status == .authorized) } }
        }
        if TCC.micStatus() == .notDetermined { TCC.requestMic(speech) }
        else { speech(micAuthorized()) }
    }

    static var defaultMicName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? L10n.tr("ui.8ca01a9ba438")
    }

    var microphoneUID = ""

    func begin() -> Bool {
        deliveredOnce=false
        audioEvidence.reset()
        if let error = Microphones.configure(audioEngine, uid: microphoneUID) {
            lastError = error
            return false
        }
        guard HoldNativeEngine.micAuthorized(), HoldNativeEngine.speechAuthorized() else {
            lastError = L10n.tr("ui.60916822baf4")
            return false
        }
        guard !active else { return false }
        lastError = nil
        finalHandler = onFinal
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
            lastError = L10n.tr("ui.53ee2b5a6dd0")
            Log.write("hold-rec start-failed unsupported-locale \(locale)")
            return false
        }
        guard rec.supportsOnDeviceRecognition || allowCloud else {
            lastError = L10n.tr("ui.af99029c7185")
            Log.write("hold-rec start-failed on-device-unsupported cloud-not-consented")
            return false
        }
        let node = audioEngine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            lastError = L10n.tr("ui.9275ca79cfc9")
            Log.write("hold-rec start-failed no-input-format")
            return false
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        } else if !allowCloud {
            // 隐私兜底：设备不支持该语言的本机识别且未允许联网 → 拒绝启动，绝不静默把音频交给 Apple
            lastError = L10n.tr("ui.46eb900e83ea")
            Log.write("hold-rec start-failed on-device-unavailable cloud-not-allowed locale=\(locale)")
            return false
        }
        Log.write("hold-rec recognizer onDevice=\(rec.supportsOnDeviceRecognition) cloudAllowed=\(allowCloud) locale=\(locale)")
        request = req
        var tapCount = 0
        node.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self, weak req] buffer, _ in
            guard let self = self else { return }
            self.audioEvidence.observe(buffer)
            req?.append(buffer)
            tapCount += 1
            if tapCount % 2 == 0, let cb = self.onLevel, let ch = buffer.floatChannelData?[0] {
                let n = Int(buffer.frameLength)
                guard n > 0 else { return }
                var sum: Float = 0
                for i in stride(from: 0, to: n, by: 4) { sum += ch[i] * ch[i] }
                let rms = sqrt(sum / Float(n / 4 + 1))
                let level = min(1, rms * 10)
                DispatchQueue.main.async { cb(level) }
            }
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
            captureStartedUptime=ProcessInfo.processInfo.systemUptime
        } catch {
            node.removeTap(onBus: 0)
            lastError = L10n.tr("ui.f2b1d7b63254")
            Log.write("hold-rec start-failed engine-error \(error.localizedDescription)")
            return false
        }
        active = true
        startedAt = Date()
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    Log.write("hold-rec final len=\(text.count)")
                    self.deliverFinal(text)
                } else if !text.isEmpty {
                    self.onPartial?(text)
                }
            }
            if let error = error {
                let code = (error as NSError).code
                if self.finalHandler != nil {
                    Log.write("hold-rec task-error code=\(code)")
                    self.deliverFinal(nil)
                } else {
                    Log.write("hold-rec task-error-after-deliver code=\(code) ignored")
                }
            }
        }
        Log.write("hold-rec started")
        return true
    }

    /// 松开：停止采集，等待最终识别结果（3s 超时空结果）。
    /// 超时只针对本次请求，避免上一轮定时器误杀下一轮回调。
    func end() {
        guard active else { return }
        active = false
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        let req = request
        req?.endAudio()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self, weak req] in
            guard let self = self else { return }
            guard self.request != nil, self.request === req, self.finalHandler != nil else { return }
            Log.write("hold-rec final-timeout")
            self.deliverFinal(nil)
        }
    }

    /// 取消：停止采集并丢弃一切结果，不回调
    func abort() {
        if active {
            active = false
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        deliveredOnce = true
        onFinal = nil
        onPartial = nil
        task?.cancel()
        task = nil
        request = nil
        finalHandler = nil
        Log.write("hold-rec cancelled discarded")
    }

    private func deliverFinal(_ text: String?) {
        guard !deliveredOnce else { return }
        deliveredOnce = true
        let cb = finalHandler
        finalHandler = nil
        task = nil
        request = nil
        cb?(text)
    }

    private var deliveredOnce = false
}

// MARK: - 写入原聚焦编辑器的 AXSelectedText（不切换输入源）

enum TextInserter {
    /// Read-back verification uses only the focused editor, in memory; no text is logged.
    static func expectedValue(before: String, selection: CFRange, inserted: String) -> String? {
        let value=before as NSString
        guard selection.location >= 0, selection.length >= 0,
              selection.location <= value.length, selection.length <= value.length-selection.location else { return nil }
        return value.replacingCharacters(in:NSRange(location:selection.location,length:selection.length),with:inserted)
    }

    static func verify(expected: String, write: () -> Int32, read: () -> String?) -> Bool {
        write() == AXError.success.rawValue && read() == expected
    }

    static func insert(_ text: String, target:FocusIdentity) -> Bool {
        guard !text.isEmpty, target.pid>0,target.pid != ProcessInfo.processInfo.processIdentifier,
              target.identityAvailable, let editor=target.element else {return false}
        func value() -> String? {
            var output:CFTypeRef?
            guard AXUIElementCopyAttributeValue(editor,kAXValueAttribute as CFString,&output) == .success else{return nil}
            return output as? String
        }
        var rangeValue:CFTypeRef?, selection=CFRange(location:0,length:0)
        let before=value()
        var expected:String?
        if let before=before, AXUIElementCopyAttributeValue(editor,kAXSelectedTextRangeAttribute as CFString,&rangeValue) == .success,
           let rangeValue=rangeValue,CFGetTypeID(rangeValue)==AXValueGetTypeID(),AXValueGetValue(rangeValue as! AXValue,.cfRange,&selection) {
            expected=expectedValue(before:before,selection:selection,inserted:text)
        }
        if !target.selectedTextWritable || expected == nil {
            return sendUnicode(text,target:target)
        }
        let current=FocusProbe.snapshot()
        guard current?.automaticInputAvailable == true,
              FocusProbe.classify(previous:target,current:current) == .unchanged else {return false}
        var status=AXError.failure.rawValue
        let verified=verify(expected:expected!,write:{
            status=AXUIElementSetAttributeValue(editor,kAXSelectedTextAttribute as CFString,text as CFString).rawValue
            return status
        },read:value)
        Log.write("insertion-ax status=\(status) readbackVerified=\(verified) len=\(text.count)")
        if verified {return true}
        // Retry only when a readable value proves the AX operation made no change.
        if let before=before, expected != before, value() == before {return sendUnicode(text,target:target)}
        return false
    }

    /// Native Unicode events go to the original PID, never to a global event tap.
    /// Recheck the exact editor/window before every chunk. No clipboard or Return.
    static func sendUnicode(_ text:String,target:FocusIdentity,current:()->FocusIdentity?=FocusProbe.snapshot,
                            windowBound:Bool=false,emit:(([UInt16],pid_t)->Bool)?=nil)->Bool {
        guard !text.isEmpty,target.identityAvailable || (windowBound && target.windowBoundAvailable),target.pid != ProcessInfo.processInfo.processIdentifier else{return false}
        let characters=Array(text)
        for start in stride(from:0,to:characters.count,by:20) {
            guard let focus=current(),!focus.protectedInput else{return false}
            if windowBound && !target.identityAvailable {
                guard focus.windowBoundAvailable,focus.sameWindow(as:target) else{return false}
            } else {
                guard focus.identityAvailable,FocusProbe.classify(previous:target,current:focus) == .unchanged else{return false}
            }
            let units=Array(String(characters[start..<min(start+20,characters.count)]).utf16)
            if let emit=emit {if !emit(units,target.pid){return false}}
            else {
                guard let down=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true),
                      let up=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:false) else{return false}
                down.flags=[];up.flags=[]
                down.keyboardSetUnicodeString(stringLength:units.count,unicodeString:units)
                up.keyboardSetUnicodeString(stringLength:units.count,unicodeString:units)
                down.postToPid(target.pid);up.postToPid(target.pid)
            }
        }
        Log.write("insertion-unicode dispatched=true pid-bound=true len=\(text.count) clipboard=false")
        return true // Delivery requested; actual app acceptance requires observed read-back.
    }
}
