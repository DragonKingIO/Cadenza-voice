import AppKit
import Carbon.HIToolbox

/// Conservative protection plus the current system's assignments. App-specific conflicts remain unknown.
enum ShortcutPolicy {
    static let functionKeys: Set<UInt32> = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
    /// Modifier keys that may be the whole shortcut: Left and Right Option. Command, Shift and Control are excluded because
    /// they are pressed all the time as part of other shortcuts, so holding one alone would start recordings by accident.
    static let standaloneModifiers: Set<UInt32> = [58, 61]
    static let navigational: Set<UInt32> = [36,48,49,51,53,71,76,114,115,116,117,119,121,123,124,125,126]
    static func basicReason(_ s: HotkeySpec, standardFunctionKeys: Bool = false) -> String? {
        if s == BridgeConfig.default().trigger { return nil }
        if s.keyCode == 63 { return L10n.tr("ui.be1ca2ee706d") }
        if standaloneModifiers.contains(s.keyCode), HotkeySpecDisplay.isLoneModifierSpec(s), s.modifierKeyCodes == nil || s.modifierKeyCodes == [s.keyCode] { return nil }
        if ListenTrigger.modifierKeyFlags[s.keyCode] != nil { return L10n.tr("shortcut.loneModifier.unsupported") }
        if navigational.contains(s.keyCode) { return L10n.tr("ui.8a35987401bf") }
        if s.keyCode > 126 || !functionKeys.contains(s.keyCode) && !HotkeySpecDisplay.printableKeys.keys.contains(s.keyCode) { return L10n.tr("ui.1e86164926a6") }
        let c=UInt32(controlKey),o=UInt32(optionKey),m=UInt32(cmdKey),h=UInt32(shiftKey)
        if s.modifiers & ~(c|o|m|h) != 0 { return L10n.tr("ui.b21dfa61556d") }
        if let sides=s.modifierKeyCodes {
            let flags=sides.reduce(UInt32(0)) { $0 | (ListenTrigger.modifierKeyFlags[$1] ?? 0) }
            if sides.isEmpty && s.modifiers != 0 || Set(sides).count != sides.count || flags != s.modifiers || sides.contains(where: {ListenTrigger.modifierKeyFlags[$0] == nil}) { return L10n.tr("ui.dc418bb1654e") }
        }
        if s.modifiers & c != 0 && s.modifiers & o != 0 { return L10n.tr("ui.52fb99b1743b") }
        // Protect command editing/lifecycle categories including their modifier variants.
        let essential: [UInt32:String] = [0:L10n.tr("ui.3a5040b68abf"),6:L10n.tr("ui.9fcf5d3b8e12"),7:L10n.tr("ui.410a8e8a6bf2"),8:L10n.tr("ui.63d90d977348"),9:L10n.tr("ui.335179267471"),1:L10n.tr("ui.a3030bf8f16d"),13:L10n.tr("ui.1ae6b0a0f826"),12:L10n.tr("ui.e4446e2ae00c"),3:L10n.tr("ui.7987058c656b"),4:L10n.tr("ui.b2f83ba5aafe"),46:L10n.tr("ui.ac29e57a46f4"),31:L10n.tr("ui.c771248e511f"),35:L10n.tr("ui.d7bfe7b5055c"),17:L10n.tr("ui.a626aad412b7"),43:L10n.tr("ui.df3d58c7d84b"),50:L10n.tr("ui.84d503a9b473"),18:L10n.tr("ui.4e4c695dc2eb"),19:L10n.tr("ui.4e4c695dc2eb"),20:L10n.tr("ui.c95dc99afe57"),21:L10n.tr("ui.c95dc99afe57"),23:L10n.tr("ui.c95dc99afe57")]
        if s.modifiers & m != 0, let reason=essential[s.keyCode] { return L10n.format("ui.e62285193079", String(describing: reason)) }
        if s.modifiers & m != 0 && s.modifiers & (c|o) == 0 { return L10n.tr("ui.0c7684de9de0") }
        if !functionKeys.contains(s.keyCode) {
            guard s.modifiers & (c|m) != 0, s.modifiers.nonzeroBitCount >= 2 else { return L10n.tr("ui.17026fde4d84") }
        } else {
            if [107,113].contains(s.keyCode) { return L10n.tr("ui.238abdb9666a") }
            if [122,120,99,118,96,97,98,100,101,109,103,111].contains(s.keyCode), !standardFunctionKeys { return L10n.tr("ui.a281f8a305c6") }
        }
        return nil
    }
    static func systemAssignments() -> [HotkeySpec]? {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr, let entries=array?.takeRetainedValue() as? [[String:Any]] else { return nil }
        return entries.compactMap { entry in
            guard (entry[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true,
                  let code=entry[kHISymbolicHotKeyCode as String] as? NSNumber,
                  let mods=entry[kHISymbolicHotKeyModifiers as String] as? NSNumber else { return nil }
            return HotkeySpec(keyCode:code.uint32Value, modifiers:mods.uint32Value)
        }
    }
    static func parseMenuEquivalent(_ description: String) -> HotkeySpec? {
        var characters = Array(description), mods: UInt32 = 0
        let prefixes: [Character:UInt32] = ["@":UInt32(cmdKey),"~":UInt32(optionKey),"^":UInt32(controlKey),"$":UInt32(shiftKey)]
        while let first = characters.first, let flag = prefixes[first] { mods |= flag; characters.removeFirst() }
        guard characters.count == 1 else { return nil }
        let character = String(characters[0])
        if character != character.lowercased() { mods |= UInt32(shiftKey) }
        if let key = HotkeySpecDisplay.printableKeys.first(where: { $0.value.lowercased() == character.lowercased() })?.key { return HotkeySpec(keyCode:key,modifiers:mods) }
        let named: [String:UInt32] = [" ":49,"\r":36,"\t":48,"\u{1b}":53,"\u{7f}":51,"\u{f700}":126,"\u{f701}":125,"\u{f702}":123,"\u{f703}":124]
        if let key = named[character] { return HotkeySpec(keyCode:key,modifiers:mods) }
        if let scalar = character.unicodeScalars.first, (0xf704...0xf717).contains(scalar.value) {
            let keys: [UInt32] = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
            return HotkeySpec(keyCode:keys[Int(scalar.value-0xf704)],modifiers:mods)
        }
        return nil
    }
    static func globalMenuAssignments() -> [HotkeySpec]? {
        guard let value = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["NSUserKeyEquivalents"] else { return [] }
        guard let values = value as? [String:String] else { return nil }
        let assignments = values.values.map(parseMenuEquivalent)
        guard assignments.allSatisfy({ $0 != nil }) else { return nil }
        return assignments.compactMap { $0 }
    }
    static func reason(_ s: HotkeySpec, assignments: [HotkeySpec]? = systemAssignments(), standardFunctionKeys: Bool = UserDefaults.standard.bool(forKey:"com.apple.keyboard.fnState"), menuAssignments: [HotkeySpec]? = globalMenuAssignments()) -> String? {
        // Name the most important categories before the broad navigation-key guard.
        if s.keyCode == 49 {
            if s.modifiers & UInt32(controlKey) != 0 { return L10n.tr("ui.1bbbcf9ac556") }
            if s.modifiers & UInt32(cmdKey) != 0 { return L10n.tr("ui.5af955d94f23") }
        }
        if s.keyCode == 48 && s.modifiers & UInt32(cmdKey) != 0 { return L10n.tr("ui.abf03802462a") }
        if s.keyCode == 53 && s.modifiers & UInt32(cmdKey|optionKey) == UInt32(cmdKey|optionKey) { return L10n.tr("ui.74c4fe926f03") }
        if let reason=basicReason(s, standardFunctionKeys:standardFunctionKeys) { return reason }
        if s == BridgeConfig.default().trigger { return nil }
        guard let assignments=assignments else { return L10n.tr("ui.644c282f79e2") }
        guard let menuAssignments = menuAssignments else { return L10n.tr("ui.9fe35a4b0109") }
        if menuAssignments.contains(where: { $0.keyCode == s.keyCode && $0.modifiers == s.modifiers }) { return L10n.tr("ui.2cbbbc5906ec") }
        if assignments.contains(where: {$0.keyCode == s.keyCode && $0.modifiers == s.modifiers}) { return L10n.tr("ui.992a958d0bbe") }
        return nil
    }
    static func registrationReason(_ s: HotkeySpec) -> String? {
        if ListenTrigger.classify(s) == .loneModifierTap { return nil }
        var ref: EventHotKeyRef?
        let result = RegisterEventHotKey(s.keyCode, s.modifiers, EventHotKeyID(signature: OSType(0x59414E53), id: 991), GetApplicationEventTarget(), 0, &ref)
        if let ref = ref { UnregisterEventHotKey(ref) }
        return result == noErr ? nil : L10n.format("ui.8d12e6cd0592", String(describing: result))
    }
    static func carbon(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var r:UInt32=0
        for (flag,bit) in [(NSEvent.ModifierFlags.control,controlKey),(.option,optionKey),(.command,cmdKey),(.shift,shiftKey)] { if f.contains(flag) { r |= UInt32(bit) } }
        return r
    }
}

/// Pure physical-cycle state machine used by both global/local monitors and regression tests.
struct ShortcutCycle {
    enum Action: Equatable { case none, start, end, cancel }
    var spec: HotkeySpec
    private(set) var held = false
    private var blocked = false
    private var requiredSides: Set<UInt32> = []
    init(spec: HotkeySpec) { self.spec = spec }
    mutating func event(type: NSEvent.EventType, code: UInt32, modifiers: UInt32, downKeys: Set<UInt32>, repeatKey: Bool = false) -> Action {
        if code == 53 && type == .keyDown { held=false; blocked=true; return .cancel }
        let lone=ListenTrigger.classify(spec) == .loneModifierTap
        let isTarget = code == spec.keyCode
        let targetDown=downKeys.contains(spec.keyCode)
        let sides=Set(downKeys.filter { ListenTrigger.modifierKeyFlags[$0] != nil })
        if held {
            if type == .keyDown && !isTarget { held=false; blocked=true; return .cancel }
            if type == .flagsChanged {
                if !sides.isSubset(of:requiredSides) { held=false; blocked=true; return .cancel }
                if !requiredSides.isSubset(of:sides) { held=false; blocked=true; return .end }
            }
            if (lone && type == .flagsChanged && isTarget && !targetDown) || (!lone && type == .keyUp && isTarget && !targetDown) { held=false; blocked=false; return .end }
            return .none
        }
        if !targetDown { blocked=false }
        guard !blocked, !repeatKey, isTarget,
            (lone ? type == .flagsChanged && targetDown : type == .keyDown),
            modifiers == spec.modifiers else { return .none }
        if let wanted=spec.modifierKeyCodes, !lone, sides != Set(wanted) { return .none }
        if lone && sides != [spec.keyCode] { return .none }
        // Do not begin while an unrelated normal key is held.
        if downKeys.contains(where: {$0 != spec.keyCode && ListenTrigger.modifierKeyFlags[$0] == nil && $0 != 57}) { return .none }
        held=true; requiredSides=sides; return .start
    }
    mutating func poll(_ downKeys: Set<UInt32>) -> Action {
        let action: Action = held && !physicallyHeld(downKeys) ? cancel() : .none
        if !downKeys.contains(spec.keyCode) { blocked = false }
        return action
    }
    mutating func cancel() -> Action { let active=held; held=false; blocked=true; return active ? .cancel : .none }
    func physicallyHeld(_ downKeys: Set<UInt32>) -> Bool { downKeys.contains(spec.keyCode) && requiredSides.isSubset(of:downKeys) }
}

/// Listener first, durable write second; either failure restores the old listener and leaves the old config.
enum ShortcutTransaction {
    static func commit(_ candidate: HotkeySpec, old: HotkeySpec, activate:(HotkeySpec)->Bool, persist:(HotkeySpec)->Bool) -> Bool {
        guard activate(candidate) else { _=activate(old); return false }
        guard persist(candidate) else { _=activate(old); return false }
        return true
    }
}

// Window tests do not require global-input permissions; the chosen engine's requirements remain mandatory.
enum EngineReadiness {
    static func ready(engine: String, mic: Bool, speech: Bool, local: Bool, cloud: Bool, credentials: Bool, consent: Bool) -> Bool {
        guard mic else { return false }
        switch engine {
        case "apple": return speech && (local || cloud)
        case "local": return LocalTranscriberLoader.supported && LocalModelCenter.shared.installedEntries.contains{LocalModelCatalog.usable($0)}
        case "iflytek", "volcengine", "tencent", "aliyun", "baidu", "deepgram", "openai", "groq", "compat", "google", "azure", "assemblyai", "elevenlabs": return credentials && consent
        default: return false
        }
    }
}

/// Toggle fires only after an observed clean, complete press/release; lost releases cancel the candidate.
struct ToggleShortcutCycle {
    private var cycle:ShortcutCycle
    private var awaitingRelease=false
    private(set) var armed=false
    private var releaseKeys:Set<UInt32>=[]
    init(spec:HotkeySpec){cycle=ShortcutCycle(spec:spec)}
    mutating func event(type:NSEvent.EventType,code:UInt32,modifiers:UInt32,downKeys:Set<UInt32>,repeatKey:Bool=false)->Bool {
        let action=cycle.event(type:type,code:code,modifiers:modifiers,downKeys:downKeys,repeatKey:repeatKey)
        switch action {
        case .start:armed=true;releaseKeys=Set(downKeys.filter{ListenTrigger.modifierKeyFlags[$0] != nil});releaseKeys.insert(cycle.spec.keyCode)
        case .end:awaitingRelease=true
        case .cancel:awaitingRelease=false;armed=false
        case .none:break
        }
        if awaitingRelease && type == .keyDown {awaitingRelease=false;armed=false}
        if awaitingRelease && releaseKeys.isDisjoint(with:downKeys) {awaitingRelease=false;armed=false;return true}
        return false
    }
    mutating func poll(_ down:Set<UInt32>) {
        if cycle.poll(down) == .cancel {awaitingRelease=false;armed=false}
        if awaitingRelease && releaseKeys.isDisjoint(with:down) {awaitingRelease=false;armed=false}
    }
    mutating func cancel(){_=cycle.cancel();awaitingRelease=false;armed=false}
}

/// Shared routing preserves hold chord protection while treating a clean other-mode press as a stop.
struct DualShortcutCycle {
    enum Action:Equatable {case holdStart,holdEnd,cancel,toggle,crossStop}
    private var hold:ShortcutCycle?,toggle:ToggleShortcutCycle?
    private let holdSpec:HotkeySpec?,toggleSpec:HotkeySpec?
    private var deferred=false,crossHold=false,suppressToggle=false
    private var deferredAt:Double=0
    init(hold:HotkeySpec?,toggle:HotkeySpec?){holdSpec=hold;toggleSpec=toggle;self.hold=hold.map{ShortcutCycle(spec:$0)};self.toggle=toggle.map{ToggleShortcutCycle(spec:$0)}}
    private func prefix(_ down:Set<UInt32>,_ mods:UInt32)->Bool {
        guard let t=toggleSpec else{return false}
        let normal=down.filter{ListenTrigger.modifierKeyFlags[$0] == nil && $0 != 57}
        return mods & ~t.modifiers == 0 && normal.allSatisfy{$0 == t.keyCode || $0 == holdSpec?.keyCode}
    }
    mutating func event(type:NSEvent.EventType,code:UInt32,modifiers:UInt32,down:Set<UInt32>,repeatKey:Bool=false,toggleRecording:Bool=false,time:Double=0)->[Action] {
        if code == 53 && type == .keyDown {_=cancel();return [.cancel]}
        let wasHold=hold?.held == true
        var toggleDown=down
        if wasHold || deferred,let h=holdSpec,ListenTrigger.modifierKeyFlags[h.keyCode] == nil {toggleDown.remove(h.keyCode)}
        let toggled=toggle?.event(type:type,code:code,modifiers:modifiers,downKeys:toggleDown,repeatKey:repeatKey) == true
        let action=hold?.event(type:type,code:code,modifiers:modifiers,downKeys:down,repeatKey:repeatKey) ?? .none
        var result:[Action]=[]
        switch action {
        case .start:if toggleRecording {crossHold=true}else{result.append(.holdStart)}
        case .end:if crossHold {result.append(.crossStop);crossHold=false}else{result.append(.holdEnd)}
        case .cancel:
            if crossHold {crossHold=false}
            else if wasHold && prefix(down,modifiers) {deferred=true;deferredAt=time}
            else {result.append(.cancel)}
        case .none:break
        }
        if deferred {
            if toggled {deferred=false;result.append(.crossStop);return result}
            if toggle?.armed == true,let h=holdSpec,!down.contains(h.keyCode) {deferred=false;suppressToggle=true;result.append(.crossStop)}
            else if toggle?.armed != true && !prefix(down,modifiers) {deferred=false;result.append(.cancel)}
        }
        if toggled {if suppressToggle {suppressToggle=false}else{result.append(.toggle)}}
        return result
    }
    mutating func poll(_ down:Set<UInt32>,time:Double)->[Action] {
        toggle?.poll(down)
        let lost=hold?.poll(down) == .cancel
        if lost {if crossHold {crossHold=false}else{return [.cancel]}}
        if deferred && toggle?.armed != true && time-deferredAt > 0.6 {deferred=false;return [.cancel]}
        if suppressToggle && toggle?.armed != true {suppressToggle=false}
        return []
    }
    mutating func cancel()->[Action] {
        let active=hold?.cancel() == .cancel || deferred
        toggle?.cancel();deferred=false;crossHold=false;suppressToggle=false
        return active ? [.cancel]:[]
    }
}

enum DualBindingTransaction {
    static func commit(_ proposed:BridgeConfig,old:BridgeConfig,activate:(BridgeConfig)->Bool,persist:(BridgeConfig)->Bool,restore:(BridgeConfig)->Void)->Bool {
        guard activate(proposed) else {restore(old);_=activate(old);return false}
        guard persist(proposed) else {restore(old);_=activate(old);return false}
        return true
    }
}
