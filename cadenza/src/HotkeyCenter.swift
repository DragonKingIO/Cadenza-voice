import AppKit
import Carbon.HIToolbox

/// 合成键事件发送（需要辅助功能授权；送达情况程序内不可确认，日志标注 delivery-unverified）
enum KeyEventPoster {
    static func post(_ spec: HotkeySpec, label: String) {
        var flags: CGEventFlags = []
        if spec.modifiers & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        if spec.modifiers & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
        if spec.modifiers & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
        if spec.modifiers & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
        if spec.keyCode == 63 { flags.insert(CGEventFlags(rawValue: 1 << 23)) } // kCGEventFlagMaskFunction (Fn)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(spec.keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(spec.keyCode), keyDown: false) else {
            Log.write("\(label) CGEvent-create-failed")
            return
        }
        down.flags = flags
        up.flags = flags
        Log.write("\(label) down keyCode=\(spec.keyCode) flags=0x\(String(flags.rawValue, radix: 16)) delivery-unverified")
        down.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            Log.write("\(label) up keyCode=\(spec.keyCode)")
            up.post(tap: .cghidEventTap)
        }
    }
}

/// Carbon RegisterEventHotKey：无需系统权限注册全局组合键。
/// 支持多槽位（触发键 / 诊断键），回调内通过 EventHotKeyID 识别来源并落日志。
/// 防重复触发：Pressed 置位、Released 复位的物理按键周期；带释放缺失兜底。
final class HotkeyCenter {
    enum Slot: Int { case trigger = 1, diagnostic = 2 }

    var onPress: (() -> Void)?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerInstalled = false
    private var handlerRef: EventHandlerRef?

    deinit {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        if let handlerRef = handlerRef { RemoveEventHandler(handlerRef) }
    }
    private(set) var statusBySlot: [Slot: String] = [.trigger: L10n.tr("ui.7b89c50978de"), .diagnostic: L10n.tr("ui.7b89c50978de")]

    private var pressActive = false
    private var pressDate = Date.distantPast

    /// 主触发键状态（菜单与 ⚠️ 显示用）
    var status: String { statusBySlot[.trigger] ?? L10n.tr("ui.7b89c50978de") }

    @discardableResult
    func register(_ spec: HotkeySpec, slot: Slot) -> Bool {
        unregister(slot)
        let slotID = UInt32(slot.rawValue)
        let hkID = EventHotKeyID(signature: OSType(0x56425247) /* 'VBRG' */, id: slotID)
        var localRef: EventHotKeyRef?
        let st = RegisterEventHotKey(spec.keyCode, spec.modifiers, hkID, GetApplicationEventTarget(), 0, &localRef)
        guard st == noErr else {
            statusBySlot[slot] = L10n.format("ui.17223dc1cc51", String(describing: st))
            Log.write("hotkey-register-FAILED slot=\(String(describing: slot)) status=\(st) \(HotkeySpecDisplay.string(spec))")
            installHandler()
            return false
        }
        refs[slotID] = localRef
        let handlerOk = installHandler()
        statusBySlot[slot] = handlerOk ? L10n.tr("ui.eab7185db6aa") : L10n.tr("ui.7a4035c3efcc")
        Log.write("hotkey-registered slot=\(String(describing: slot)) \(HotkeySpecDisplay.string(spec)) handlerInstalled=\(handlerOk)")
        return handlerOk
    }

    func unregister(_ slot: Slot? = nil) {
        if let slot = slot {
            let slotID = UInt32(slot.rawValue)
            if let r = refs[slotID] {
                UnregisterEventHotKey(r)
                refs[slotID] = nil
            }
            statusBySlot[slot] = L10n.tr("ui.7b89c50978de")
        } else {
            for (_, r) in refs { UnregisterEventHotKey(r) }
            refs.removeAll()
            statusBySlot[.trigger] = L10n.tr("ui.7b89c50978de")
            statusBySlot[.diagnostic] = L10n.tr("ui.7b89c50978de")
        }
    }

    @discardableResult
    private func installHandler() -> Bool {
        guard !handlerInstalled else { return true }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let rc = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let ud = userData, let ev = event else { return noErr }
            var hkID = EventHotKeyID()
            var gotSize: Int = 0
            let st = withUnsafeMutableBytes(of: &hkID) { raw in
                GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, raw.count, &gotSize, raw.baseAddress)
            }
            // 只处理本类注册的热键；别的组件（如截图）的热键交还给它自己的处理器
            if st == noErr, hkID.signature != OSType(0x56425247) { return OSStatus(eventNotHandledErr) }
            let slotName: String
            if st == noErr {
                slotName = hkID.id == 1 ? "trigger" : (hkID.id == 2 ? "diagnostic" : "id=\(hkID.id)")
            } else {
                slotName = "unreadable(status=\(st))"
            }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(ud).takeUnretainedValue()
            center.handle(kind: GetEventKind(ev), slot: slotName)
            return noErr
        }, 2, &specs, userData, &handlerRef)
        guard rc == noErr else {
            Log.write("event-handler-install-FAILED status=\(rc)")
            statusBySlot[.trigger] = L10n.format("ui.e3007ffc10be", String(describing: rc))
            return false
        }
        handlerInstalled = true
        Log.write("event-handler-installed")
        return true
    }

    /// 授权后自动重启监听（最多 5 分钟）；无需用户重启应用
    private func handle(kind: UInt32, slot: String) {
        if kind == UInt32(kEventHotKeyPressed) {
            Log.write("hotkey-cb pressed slot=\(slot) cycle-active=\(pressActive)")
            // 兜底：若 Released 事件缺失（个别键盘/场景），超过 3s 视为上一周期已结束
            if pressActive, Date().timeIntervalSince(pressDate) > 3 {
                Log.write("hotkey pressed-stale-release-assumed")
                pressActive = false
            }
            guard !pressActive else {
                Log.write("hotkey press-ignored cycle-active")
                return
            }
            pressActive = true
            pressDate = Date()
            Log.write("hotkey-dispatch onPress slot=\(slot)")
            DispatchQueue.main.async { [weak self] in self?.onPress?() }
        } else if kind == UInt32(kEventHotKeyReleased) {
            Log.write("hotkey-cb released slot=\(slot)")
            pressActive = false
        } else {
            Log.write("hotkey-cb kind=\(kind) slot=\(slot)")
        }
    }
}

/// Observes key events without consuming the original action. No Carbon fallback for hold semantics.
final class ListenTrigger {
    enum Kind { case loneModifierTap, keyDownCombo }
    static let modifierKeyFlags: [UInt32: UInt32] = [58: UInt32(optionKey),61:UInt32(optionKey),56:UInt32(shiftKey),60:UInt32(shiftKey),55:UInt32(cmdKey),54:UInt32(cmdKey),59:UInt32(controlKey),62:UInt32(controlKey)]
    static func classify(_ s:HotkeySpec) -> Kind { modifierKeyFlags[s.keyCode] == s.modifiers ? .loneModifierTap : .keyDownCombo }
    static func carbonModifiersMatch(_ flags:NSEvent.ModifierFlags,_ s:HotkeySpec)->Bool { ShortcutPolicy.carbon(flags) == s.modifiers }
    var onCoordinatedEvent:((AppTriggerMachine.Event)->Void)?
    var onPress:(()->Void)?
    var onHoldStart:(()->Void)?
    var onHoldEnd:(()->Void)?
    var onHoldChord:(()->Void)?
    var onTogglePress:(()->Void)?
    var onSleep:(()->Void)?
    var onCrossModeStop:(()->Void)?
    var isToggleRecording:(()->Bool)?
    private var globalMon:Any?, localMon:Any?
    private var retryTimer:Timer?, watchdog:Timer?
    private var sleepObserver:NSObjectProtocol?
    private var cycle:DualShortcutCycle?
    private var router:CoordinatedShortcutRouter?
    private var generation=0
    private(set) var spec:HotkeySpec?
    private(set) var kind:Kind = .keyDownCombo
    private(set) var status=L10n.tr("ui.e6fc5eb8c3b8")
    private(set) var lastMatchAt:Date?
    /// Normal keys the listener has actually seen go down. A virtual keyboard or remote-control driver can make the system
    /// report a key as held forever (measured: key code 0), which would block every shortcut that must start "alone".
    static var observedDown:Set<UInt32>=[]
    /// Modifier keys come straight from the system state; a normal key counts only if its key-down was seen and it is still down.
    static func visibleDown(raw:Set<UInt32>,observed:Set<UInt32>)->Set<UInt32> {
        raw.filter { modifierKeyFlags[$0] != nil || $0 == 57 || observed.contains($0) }
    }
    static func downKeys()->Set<UInt32> {
        let raw=Set((0...126).compactMap { CGEventSource.keyState(.combinedSessionState,key:CGKeyCode($0)) ? UInt32($0) : nil })
        observedDown.formIntersection(raw)
        return visibleDown(raw:raw,observed:observedDown)
    }
    @discardableResult
    func start(_ spec:HotkeySpec, retry:Bool=true)->Bool { startBindings(hold:spec,toggle:nil,retry:retry) }
    @discardableResult
    func startBindings(hold:HotkeySpec?,toggle:HotkeySpec?,retry:Bool=false,coordinated:Bool=false)->Bool {
        stop()
        guard hold != nil || toggle != nil else {status=L10n.tr("ui.b80d8b6934e5");return true}
        guard CGPreflightListenEventAccess() else {status=L10n.tr("ui.4a4068c85293");return false}
        self.spec=hold;if let hold=hold {kind=Self.classify(hold)};if coordinated {router=CoordinatedShortcutRouter(primary:hold,secondary:toggle)}else{cycle=DualShortcutCycle(hold:hold,toggle:toggle)}
        let currentGeneration=generation
        let mask:NSEvent.EventTypeMask=[.keyDown,.keyUp,.flagsChanged]
        globalMon=NSEvent.addGlobalMonitorForEvents(matching:mask) { [weak self] e in guard let self=self, self.generation == currentGeneration else { return }; self.handle(e) }
        localMon=NSEvent.addLocalMonitorForEvents(matching:mask) { [weak self] e in if let self=self, self.generation == currentGeneration { self.handle(e) }; return e }
        guard globalMon != nil,localMon != nil else { stop();status=L10n.tr("ui.dee94e2b4b44");return false }
        watchdog=Timer.scheduledTimer(withTimeInterval:coordinated ? 0.02:0.2,repeats:true) { [weak self] _ in
            guard let self=self,self.generation == currentGeneration else{return}
            let down=Self.downKeys();if let events=self.router?.poll(down){events.forEach{self.onCoordinatedEvent?($0)}};if let actions=self.cycle?.poll(down,time:ProcessInfo.processInfo.systemUptime){actions.forEach(self.deliver)}
        }
        RunLoop.main.add(watchdog!,forMode:.common)
        sleepObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in if let self=self, self.generation == currentGeneration { self.cancelCycle();self.onSleep?() } }
        status=L10n.tr("ui.361095049006")
        return true
    }
    private func deliver(_ action:DualShortcutCycle.Action) {
        switch action {
        case .holdStart:lastMatchAt=Date();onHoldStart?()
        case .holdEnd:onHoldEnd?()
        case .cancel:onHoldChord?()
        case .toggle:lastMatchAt=Date();onTogglePress?()
        case .crossStop:onCrossModeStop?()
        }
    }
    private func cancelCycle(){if router != nil{onCoordinatedEvent?(.cancelRequested)};if let actions=cycle?.cancel(){actions.forEach(deliver)}}
    func stop() {
        generation += 1
        cancelCycle()
        retryTimer?.invalidate();retryTimer=nil;watchdog?.invalidate();watchdog=nil
        if let o=sleepObserver {NSWorkspace.shared.notificationCenter.removeObserver(o)};sleepObserver=nil
        if let m=globalMon {NSEvent.removeMonitor(m)};globalMon=nil
        if let m=localMon {NSEvent.removeMonitor(m)};localMon=nil
        spec=nil;cycle=nil;router=nil;status=L10n.tr("ui.e6fc5eb8c3b8")
    }
    private func scheduleRetry(_ s:HotkeySpec) {
        var attempts=0; let retryGeneration=generation
        retryTimer=Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] timer in
            guard let self=self,self.generation == retryGeneration else {timer.invalidate();return}
            attempts+=1
            if attempts>150 {timer.invalidate();self.retryTimer=nil;return}
            if CGPreflightListenEventAccess() {
                if let reason=ShortcutPolicy.reason(s) {timer.invalidate();self.status=reason;return}
                _=self.start(s)
            }
        }
        RunLoop.main.add(retryTimer!,forMode:.common)
    }
    private var lastModifierLog:TimeInterval = 0
    private var modifierEvents = 0
    /// Diagnostic only: counts that the listener receives modifier events at all. Never records which key it was.
    private func noteModifierEvent(_ e:NSEvent) {
        guard e.type == .flagsChanged else{return}
        modifierEvents += 1
        let now=ProcessInfo.processInfo.systemUptime
        guard now-lastModifierLog > 10 else{return}
        lastModifierLog=now
        Log.write("listener-alive modifier-events=\(modifierEvents) generation=\(generation)")
    }
    private func handle(_ e:NSEvent) {
        noteModifierEvent(e)
        if e.type == .keyDown {Self.observedDown.insert(UInt32(e.keyCode))} else if e.type == .keyUp {Self.observedDown.remove(UInt32(e.keyCode))}
        if let events=router?.event(type:e.type,code:UInt32(e.keyCode),mods:ShortcutPolicy.carbon(e.modifierFlags),down:Self.downKeys(),repeatKey:e.type == .keyDown && e.isARepeat){events.forEach{onCoordinatedEvent?($0)};return}
        if let actions=cycle?.event(type:e.type,code:UInt32(e.keyCode),modifiers:ShortcutPolicy.carbon(e.modifierFlags),down:Self.downKeys(),repeatKey:e.type == .keyDown && e.isARepeat,toggleRecording:isToggleRecording?() == true,time:ProcessInfo.processInfo.systemUptime){actions.forEach(deliver)}
    }
}
