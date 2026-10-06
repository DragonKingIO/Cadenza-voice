import AppKit
import Carbon.HIToolbox

struct SystemTriggerClock:TriggerClock {var read:()->Double={ProcessInfo.processInfo.systemUptime};var now:Double{read()}}
typealias AppTriggerMachine=TriggerStateMachine<SystemTriggerClock>

/// Sole gesture/session owner on the gated path. Pipeline still owns safe final insertion.
final class TriggerCoordinator {
    private let store:ConfigStore,pipeline:VoicePipeline
    private var machine:AppTriggerMachine?,recorder:TriggeredRecorder?,timer:Timer?
    private let escape=RecordingEscapeTap()
    private var recognitionDeadline:DispatchWorkItem?
    private var recognitionStarted:Double?
    private var executing=false
    private(set) var active=false
    var clockNow:()->Double={ProcessInfo.processInfo.systemUptime}
    var microphoneAccess:()->Bool=HoldNativeEngine.micAuthorized
    var credentialsReady:(ASREngine)->Bool={$0 == .apple || $0.configured}
    var captureFactory:()->CloudPCMCapturing={CloudPCMCapture()}
    var consumerFactory:((TriggerPCMFeed)->HoldRecordingSession?)?
    var automaticTimers=true
    var automaticEscapeMonitoring=true
    func poll(){if let since=recognitionStarted,clockNow()-since>=12 {recognitionTimedOut();return};if let id=machine?.sessionID{handle(.timerFired(sessionID:id))}}
    var state:AppTriggerMachine.State{machine?.state ?? .idle}
    init(store:ConfigStore,pipeline:VoicePipeline){self.store=store;self.pipeline=pipeline
        pipeline.coordinatedStop={[weak self] in guard let self=self,self.active,!self.executing else{return false};self.handle(.stopRequested);return true}
        pipeline.coordinatedCancel={[weak self] in guard let self=self,self.active,!self.executing else{return false};self.cancel();return true}
        pipeline.coordinatedFinal={[weak self] text in self?.recognized(text)}
    }
    func handle(_ event:AppTriggerMachine.Event) {
        guard store.config.triggerCoordinatorEnabled else{return}
        if machine == nil || (!active && !pipeline.hasActiveSession) {
            let c=store.config,provider=ASREngine(rawValue:c.engine) ?? .apple
            guard let cfg=try? AppTriggerMachine.Configuration(mode:c.inputMode == "hybrid" ? .hybrid:c.inputMode == "toggle" ? .toggle:.hold,
                longPressThreshold:c.triggerThresholdSec,lockedSilenceTimeout:c.triggerNoSpeechSec,speechSilenceTimeout:c.triggerPostSpeechSec,
                submission:provider == .baidu ? .wholeRecording:.streaming,
                engineMaximumDuration:min(c.recordingTimeoutSec,provider == .baidu ? 59:provider == .apple ? 60:600),
                bufferLimitBytes:provider == .baidu ? 60*32000:256000,
                access:provider == .apple ? .local:.cloud(consented:c.options(provider).consent),
                microphoneAllowed:microphoneAccess(),credentialsAvailable:credentialsReady(provider),
                independentToggleEnabled:c.toggleShortcutEnabled) else{return}
            machine=AppTriggerMachine(clock:SystemTriggerClock(read:clockNow),configuration:cfg)
        }
        guard var m=machine else{return};let output=m.handle(event);machine=m
        active=output.state != .idle && output.state != .cancelled && output.state != .error
        if output.state == .locked {pipeline.session?.source = .toggle}
        execute(output.actions)
        if output.state == .cancelled || output.state == .error {stopTimer();escape.stop()}
    }
    private func execute(_ actions:[AppTriggerMachine.Action]) {
        for action in actions {
            switch action {
            case let .startCapture(_,limit):
                let c=store.config,provider=ASREngine(rawValue:c.engine) ?? .apple
                let r=TriggeredRecorder(capture:captureFactory(),limit:limit,uid:c.microphoneUID,allowed:{[weak self,weak store] in
                    guard let store=store,let self=self else{return false};return self.microphoneAccess() && (provider == .apple || store.config.options(provider).consent)
                },makeConsumer:{[weak self,weak store] feed in
                    guard let store=store else{return nil}
                    if let factory=self?.consumerFactory{return factory(feed)}
                    if provider == .apple{return TriggerAppleRecognizer(feed:feed,locale:c.recognitionLocale,allowCloud:c.allowCloudRecognition)}
                    guard store.config.options(provider).consent,let keys=provider.credentials() else{return nil}
                    return CloudASRRecorder(provider:provider,options:c.options(provider),credentials:keys,language:IflytekRecorder.resolveLanguage(c.iflytekLanguage,forSourceID:nil),capture:feed)
                })
                recorder=r;let id=machine!.sessionID
                r.onSamples={[weak self] duration,speech in self?.handle(.audioLevel(sessionID:id,validDuration:duration,speechDetected:speech))}
                r.onOverflow={[weak self] in self?.handle(.bufferOverflow(sessionID:id))}
                let original=pipeline.recorderFactory;pipeline.recorderFactory={r};pipeline.coordinatedSession=true
                let target=pipeline.snapshotFocus()
                pipeline.holdStarted(source:.hotkey,target:target,localOnly:target?.pid == ProcessInfo.processInfo.processIdentifier)
                pipeline.recorderFactory=original
                if !pipeline.hasActiveSession{handle(.captureFailed(sessionID:id));return}
            case .installEscapeMonitor:
                guard automaticEscapeMonitoring else{continue}
                if !escape.start(cancel:{[weak self] in self?.handle(.escape)}){Log.write("trigger-esc degraded=listen-only-or-unavailable")}
            case .removeEscapeMonitor:escape.stop()
            case .scheduleTimers:
                guard automaticTimers else{continue}
                stopTimer();let t=Timer(timeInterval:0.02,repeats:true){[weak self] _ in guard let self=self,let id=self.machine?.sessionID else{return};self.handle(.timerFired(sessionID:id))};timer=t;RunLoop.main.add(t,forMode:.common)
            case .cancelTimers:stopTimer()
            case .startStreaming,.uploadWholeRecording:
                if recorder?.releaseSubmission() != true,let id=machine?.sessionID{handle(.captureFailed(sessionID:id));return}
            case .stopCapture:recorder?.stopCapture()
            case .stopStreaming:break // end() drains tail; abort() immediately drops pending frames.
            case .recognize:
                recognitionStarted=clockNow();recognitionDeadline?.cancel()
                let timeout=DispatchWorkItem{[weak self] in self?.recognitionTimedOut()};recognitionDeadline=timeout
                if automaticTimers {DispatchQueue.main.asyncAfter(deadline:.now()+12,execute:timeout)}
                executing=true;pipeline.holdEnded();executing=false
            case .discardAudio:
                executing=true;pipeline.forceEnd(reason:L10n.tr("ui.add6a0de758c"));executing=false;pipeline.coordinatedSession=false
            case .insertOrCopy:break // original pipeline guards and acknowledges insertion.
            case let .feedback(reason):
                let text:String
                switch reason {case .tooShort:text=L10n.tr("ui.ef5ee760bf9c");case .noSpeech:text=L10n.tr("ui.c4af1ec159eb");case .microphoneDenied:text=L10n.tr("ui.dc711461a951");case .credentialsMissing:text=L10n.tr("ui.2b50fc06ba71");case .uploadConsentRequired:text=L10n.tr("ui.439d4d03de5b");case .chordCancelled,.escaped:text=L10n.tr("ui.2e3f073a2db5");case .copiedToClipboard:text=L10n.tr("ui.4652bb6bdb37");default:text=L10n.tr("ui.d6c64039aa41")}
                pipeline.note(text,isError:reason != .escaped && reason != .chordCancelled && reason != .copiedToClipboard);pipeline.onStateChange?()
            }
        }
    }
    private func recognized(_ text:String?) {
        guard active,let id=machine?.sessionID else{return}
        clearRecognitionDeadline()
        handle(.recognitionResult(sessionID:id,text.map{.text($0)} ?? .noText))
        if state == .inserting {handle(.insertionResult(sessionID:id,pipeline.coordinatedCopied ? .copiedToClipboard:pipeline.lastInputAccepted ? .inserted:.failed))}
        active=false;pipeline.coordinatedSession=false;escape.stop();stopTimer()
    }
    private func clearRecognitionDeadline(){recognitionDeadline?.cancel();recognitionDeadline=nil;recognitionStarted=nil}
    private func recognitionTimedOut(){
        guard state == .recognizing,let id=machine?.sessionID else{return}
        clearRecognitionDeadline();executing=true;pipeline.forceEnd(reason:L10n.tr("ui.488533e2fc5d"));executing=false
        handle(.recognitionResult(sessionID:id,.failed));active=false;pipeline.coordinatedSession=false
    }
    func cancel(){clearRecognitionDeadline();handle(.cancelRequested);if state == .recognizing || state == .inserting {executing=true;pipeline.forceEnd(reason:L10n.tr("ui.494cf1abc929"));executing=false;active=false;pipeline.coordinatedSession=false;machine=nil;stopTimer();escape.stop()}}
    private func stopTimer(){timer?.invalidate();timer=nil}
}

/// Uses ShortcutCycle solely for physical identity/chord protection, never gesture timing.
struct CoordinatedShortcutRouter {
    var primary:ShortcutCycle?,secondary:ShortcutCycle?
    init(primary:HotkeySpec?,secondary:HotkeySpec?){self.primary=primary.map{ShortcutCycle(spec:$0)};self.secondary=secondary.map{ShortcutCycle(spec:$0)}}
    mutating func event(type:NSEvent.EventType,code:UInt32,mods:UInt32,down:Set<UInt32>,repeatKey:Bool)->[AppTriggerMachine.Event] {
        if code == 53 && type == .keyDown{return [.escape]}
        let a=primary?.event(type:type,code:code,modifiers:mods,downKeys:down,repeatKey:repeatKey) ?? .none
        let b=secondary?.event(type:type,code:code,modifiers:mods,downKeys:down,repeatKey:repeatKey) ?? .none
        // A clean second binding can stop locked recording; don't let the first binding's chord cancel win.
        if a == .start{return [.keyDown(binding:.primary,isRepeat:false,standaloneModifier:primary.map{ListenTrigger.classify($0.spec) == .loneModifierTap} ?? false)]}
        if b == .start{return [.keyDown(binding:.independentToggle,isRepeat:false,standaloneModifier:secondary.map{ListenTrigger.classify($0.spec) == .loneModifierTap} ?? false)]}
        if a == .cancel || b == .cancel{return [.otherKeyDown]}
        var events:[AppTriggerMachine.Event]=[]
        if a == .end{events.append(.keyUp(binding:.primary))};if b == .end{events.append(.keyUp(binding:.independentToggle))};return events
    }
    mutating func poll(_ down:Set<UInt32>)->[AppTriggerMachine.Event] {
        let a=primary?.poll(down),b=secondary?.poll(down)
        return a == .cancel || b == .cancel ? [.cancelRequested]:[]
    }
}
