import AppKit
import Carbon.HIToolbox

/// Consume configured chords, including repeats after a modifier was released.
/// Ordinary typing, modifier-only keys and Esc remain untouched.
struct ShortcutKeyConsumption {
    let bindings: [HotkeySpec]
    private var claimed: Set<UInt32> = []
    init(bindings: [HotkeySpec]) { self.bindings = bindings }
    mutating func consumes(type: NSEvent.EventType, code: UInt32, modifiers: UInt32, down: Set<UInt32>, repeated: Bool = false) -> Bool {
        guard code != 53, ListenTrigger.modifierKeyFlags[code] == nil else { return false }
        if type == .keyUp { return claimed.remove(code) != nil }
        guard type == .keyDown else { return false }
        if claimed.contains(code), repeated { return true }
        // A fresh press clears a stale claim if the previous key-up was lost.
        claimed.remove(code)
        let sides = Set(down.filter { ListenTrigger.modifierKeyFlags[$0] != nil })
        guard bindings.contains(where: {
            $0.keyCode == code && $0.modifiers == modifiers &&
            ($0.modifierKeyCodes == nil || Set($0.modifierKeyCodes!) == sides)
        }) else { return false }
        claimed.insert(code); return true
    }
}

/// The event stream owns consumed keys until their release. Polling only OS
/// tables would prematurely cancel a keyDown removed from those tables.
struct CapturedShortcutKeys {
    let bindings:[HotkeySpec]
    private(set) var down:Set<UInt32>=[]
    init(bindings:[HotkeySpec]) {self.bindings=bindings}
    mutating func event(type:NSEvent.EventType,code:UInt32,modifiers:UInt32,consumed:Bool) {
        switch type {
        case .keyDown:if consumed {down.insert(code)} else {down.remove(code)}
        case .keyUp:down.remove(code)
        case .flagsChanged:
            down=down.filter {code in bindings.contains {$0.keyCode==code && $0.modifiers & modifiers == $0.modifiers}}
        default:break
        }
    }
    func augment(_ raw:Set<UInt32>)->Set<UInt32> {raw.union(down)}
}

/// OS key tables can briefly lead the queued event stream at release, or omit a
/// consumed modifier for one tick. Give real key-up events time to end normally;
/// a persistently missing release still cancels after the bounded grace window.
struct ShortcutPollGrace {
    var grace: Double = 0.12
    private var observed: Set<UInt32> = []
    private var missingSince: Double?
    /// Current session flags corroborate a modifier seen in the event stream.
    /// Key-state tables alone intermittently omit held modifiers. Device bits
    /// distinguish sides when available (NX_DEVICE* masks from IOLLEvent.h).
    func confirmedPhysical(_ physical:Set<UInt32>,flags:CGEventFlags)->Set<UInt32> {
        let mods=ShortcutPolicy.carbon(NSEvent.ModifierFlags(rawValue:UInt(flags.rawValue)))
        let device:[UInt32:UInt64]=[59:0x1,56:0x2,60:0x4,55:0x8,54:0x10,58:0x20,61:0x40,62:0x2000]
        func modifierHeld(_ key:UInt32)->Bool {
            guard let flag=ListenTrigger.modifierKeyFlags[key],mods & flag != 0 else{return false}
            let familyMask=device.reduce(UInt64(0)) {value,pair in
                ListenTrigger.modifierKeyFlags[pair.key] == flag ? value | pair.value:value
            }
            return flags.rawValue & familyMask == 0 || flags.rawValue & (device[key] ?? 0) != 0
        }
        var down=physical.filter {ListenTrigger.modifierKeyFlags[$0] == nil || modifierHeld($0)}
        for key in observed where ListenTrigger.modifierKeyFlags[key] != nil && modifierHeld(key) {down.insert(key)}
        return down
    }
    mutating func event(type: NSEvent.EventType, code: UInt32, modifiers: UInt32, down: Set<UInt32>) {
        observed = down.filter { key in
            guard let flag = ListenTrigger.modifierKeyFlags[key] else { return true }
            return modifiers & flag != 0
        }
        if type == .keyUp { observed.remove(code) }
        if type == .keyDown { observed.insert(code) }
        missingSince = nil
    }
    mutating func poll(_ physical: Set<UInt32>, time: Double) -> Set<UInt32> {
        guard !observed.isSubset(of: physical) else { missingSince = nil; return physical }
        if missingSince == nil { missingSince = time }
        return time - missingSince! < grace ? physical.union(observed) : physical
    }
}

/// Installed while combo bindings are enabled. Callback only snapshots keyboard
/// state and queues routing; audio, network and UI work never run inside the tap.
/// Failure stops listening instead of falling back to leaking shortcut characters.
final class ShortcutEventTap {
    typealias Handler = (NSEvent.EventType, UInt32, UInt32, Set<UInt32>, Bool, Double, Bool) -> Void
    private var tap: CFMachPort?
    private var loop: CFRunLoop?
    private var worker: Thread?
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
    private var installed = false
    private var observed: Set<UInt32> = []
    private var consumption: ShortcutKeyConsumption
    private var timeoutRetries = 0, running = false, failureQueued = false
    private let eventHandler: Handler
    private let failed: () -> Void
    init(bindings: [HotkeySpec], event: @escaping Handler, failed: @escaping () -> Void) {
        consumption = ShortcutKeyConsumption(bindings: bindings); eventHandler = event; self.failed = failed
    }
    func start() -> Bool {
        guard TCC.axTrusted(), !TCC.isolated else { return false }
        lock.lock();running=true;lock.unlock()
        let thread=Thread { [self] in installAndRun() }
        thread.name="Cadenza shortcut events";worker=thread;thread.start()
        guard ready.wait(timeout:.now()+2) == .success else {stop();return false}
        lock.lock();let ok=installed;lock.unlock()
        if !ok {stop()}
        return ok
    }
    private func installAndRun() {
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue))
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<ShortcutEventTap>.fromOpaque(context).takeUnretainedValue()
                return owner.receive(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let loopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {ready.signal();finished.signal();return}
        let runLoop=CFRunLoopGetCurrent()!
        tap=port
        CFRunLoopAddSource(runLoop,loopSource,.commonModes);CGEvent.tapEnable(tap:port,enable:true)
        lock.lock();loop=runLoop;installed=true;let shouldRun=running;lock.unlock()
        ready.signal()
        if shouldRun {CFRunLoopRun()}
        CGEvent.tapEnable(tap:port,enable:false);CFMachPortInvalidate(port)
        CFRunLoopRemoveSource(runLoop,loopSource,.commonModes);tap=nil
        lock.lock();loop=nil;installed=false;lock.unlock()
        finished.signal()
    }
    private var acceptsEvents: Bool {
        lock.lock();defer{lock.unlock()};return running && !failureQueued
    }
    private func receive(type: CGEventType, event: CGEvent) -> Bool {
        guard acceptsEvents else { return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if type == .tapDisabledByTimeout, timeoutRetries < 1, let tap {
                timeoutRetries += 1; CGEvent.tapEnable(tap: tap, enable: true)
            } else {
                lock.lock();failureQueued=true;lock.unlock()
                DispatchQueue.main.async { [weak self] in
                    guard let self else{return}
                    self.lock.lock();let active=self.running;self.lock.unlock()
                    if active {self.failed()}
                }
            }
            return false
        }
        let kind: NSEvent.EventType
        switch type { case .keyDown: kind = .keyDown; case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged; default: return false }
        let code = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let mods = ShortcutPolicy.carbon(NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)))
        let repeated = kind == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if kind == .keyDown { observed.insert(code) }
        if kind == .keyUp { observed.remove(code) }
        let raw=ListenTrigger.rawDownKeys()
        observed.formIntersection(raw)
        var down=ListenTrigger.visibleDown(raw:raw,observed:observed)
        if kind == .keyDown { down.insert(code) }; if kind == .keyUp { down.remove(code) }
        let time = ProcessInfo.processInfo.systemUptime
        let consume = consumption.consumes(type: kind, code: code, modifiers: mods, down: down, repeated: repeated)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.acceptsEvents else { return }
            if kind == .keyDown {ListenTrigger.observedDown.insert(code)}
            if kind == .keyUp {ListenTrigger.observedDown.remove(code)}
            self.eventHandler(kind, code, mods, down, repeated, time, consume)
        }
        return consume
    }
    func stop() {
        lock.lock();running=false;let runLoop=loop;lock.unlock()
        if let runLoop {CFRunLoopStop(runLoop);CFRunLoopWakeUp(runLoop)}
        if worker != nil {_=finished.wait(timeout:.now()+2);worker=nil}
    }
    deinit { stop() }
}
