import Foundation
import Carbon.HIToolbox

enum ShortcutPrefixFixtures {
    final class Capture: CloudPCMCapturing {
        var onPCM: ((Data) -> Void)?, onLevel: ((Float) -> Void)?
        var hasSignal = true, startedUptime: TimeInterval?, lastError: String?
        var starts = 0, stops = 0, tail = Data(), succeeds = true
        func start(uid: String) -> Bool { starts += 1; startedUptime = 10.05; return succeeds }
        func stop() { stops += 1; if !tail.isEmpty { onPCM?(tail) }; onLevel?(0.1) }
        func emit(_ data: Data) { onLevel?(0.5); onPCM?(data) }
    }
    static func run(_ check: (String, Bool) -> Void) {
        func c(_ name: String, _ ok: Bool) { check("ShortcutPrefix " + name, ok) }
        let source = Capture(), buffered = ShortcutPrefixCapture(inner: source, requestedUptime: 10)
        var delivered = Data(), levels = 0
        buffered.onPCM = { delivered.append($0) }; buffered.onLevel = { _ in levels += 1 }
        c("microphone starts immediately before the decision point", buffered.prepare(uid: "mic") && source.starts == 1)
        let beginning = Data(repeating: 1, count: 6_400), later = Data(repeating: 2, count: 16_000)
        source.emit(beginning)
        c("candidate buffers the beginning without a recognition callback", delivered.isEmpty && levels == 0 && buffered.bufferedBytes == beginning.count)
        c("confirmation reuses one microphone and flushes the entire beginning", buffered.start(uid: "mic") && delivered == beginning && source.starts == 1)
        source.emit(later); source.tail = Data([3, 3]); buffered.stop(); buffered.stop()
        c("new frames follow the beginning and the converter tail survives release", delivered == beginning + later + Data([3, 3]) && source.stops == 1)
        c("timestamps include the original key press and actual microphone start", buffered.requestedUptime == 10 && buffered.startedUptime == 10.05)
        source.emit(Data([4, 4]))
        c("late frames after stop cannot enter the recognition", delivered == beginning + later + Data([3, 3]))

        for reason in ["translation chord", "other key", "short tap", "escape", "sleep", "listener stop"] {
            let source = Capture(), candidate = ShortcutPrefixCapture(inner: source)
            var packets = 0
            candidate.onPCM = { _ in packets += 1 }
            _ = candidate.prepare(uid: ""); source.emit(beginning); candidate.stop()
            c(reason + " discards the whole local buffer", packets == 0 && candidate.bufferedBytes == 0 && source.stops == 1 && !candidate.start(uid: ""))
        }
        let boundedSource = Capture(), bounded = ShortcutPrefixCapture(inner: boundedSource, limit: 4)
        _ = bounded.prepare(uid: ""); boundedSource.emit(Data([1, 1, 1, 1])); boundedSource.emit(Data([2, 2]))
        c("overflow refuses confirmation instead of handing off truncated audio", bounded.bufferedBytes <= 4 && !bounded.start(uid: "")); bounded.stop()
        let different = Capture(), selection = ShortcutPrefixCapture(inner: different)
        _ = selection.prepare(uid: "a")
        c("a microphone configuration change cannot reuse the wrong capture", !selection.start(uid: "b")); selection.stop()
        let broken = Capture(); broken.succeeds = false
        let failed = ShortcutPrefixCapture(inner: broken)
        c("a start failure cleans the microphone once and cannot be confirmed", !failed.prepare(uid: "") && broken.stops == 1 && !failed.start(uid: ""))

        let opt = UInt32(optionKey)
        var cycle = VoiceShortcutCycle(hold: HotkeySpec(keyCode: 58, modifiers: opt), toggle: nil,
                                       translation: HotkeySpec(keyCode: 3, modifiers: opt))
        _ = cycle.event(type: .flagsChanged, code: 58, modifiers: opt, down: [58], time: 10)
        c("the listener can prepare audio at the actual modifier down", cycle.pendingPrefixAt == 10)
        c("the decision still delays recognition and UI", cycle.poll([58], time: 10.2).isEmpty && cycle.pendingPrefixAt == 10)
        c("the confirmed shortcut consumes its candidate exactly once", cycle.poll([58], time: 10.31) == [.holdStart] && cycle.pendingPrefixAt == nil)
        var grace = ShortcutPollGrace()
        grace.event(type:.keyDown,code:3,modifiers:opt,down:[58,3])
        c("one transient missing modifier table entry does not cancel a held chord",grace.poll([3],time:11)==[58,3])
        c("persistently lost releases still cancel within the bounded grace",grace.poll([],time:11.13).isEmpty)
        grace.event(type:.keyDown,code:3,modifiers:opt,down:[58,3])
        _=grace.poll([],time:12)
        grace.event(type:.keyUp,code:3,modifiers:opt,down:[58])
        c("a real key-up clears the consumed key without waiting",!grace.poll([58],time:12.01).contains(3))
        grace.event(type:.flagsChanged,code:58,modifiers:0,down:[58])
        c("generic modifier release clears a stale table side entry",grace.poll([],time:12.02).isEmpty)
        grace.event(type:.flagsChanged,code:58,modifiers:opt,down:[58])
        c("physical keys absent from the event stream remain visible",grace.poll([58,8],time:13)==[58,8])
        grace=ShortcutPollGrace()
        c("listener reset never keeps a synthetic or previous-session key",grace.poll([],time:14).isEmpty)
        grace.event(type:.flagsChanged,code:58,modifiers:opt,down:[58])
        let leftFlags=CGEventFlags(rawValue:CGEventFlags.maskAlternate.rawValue | 0x20)
        c("current session flags corroborate a held Option omitted from the key table",grace.confirmedPhysical([],flags:leftFlags) == [58])
        c("confirmation never revives a released modifier from stale tables",grace.confirmedPhysical([58],flags:[]).isEmpty)
        c("right Option cannot corroborate a released left Option",grace.confirmedPhysical([61],flags:CGEventFlags(rawValue:CGEventFlags.maskAlternate.rawValue | 0x40)) == [61])
        c("side flags remove a stale left Option even while right Option stays held",grace.confirmedPhysical([58,61],flags:CGEventFlags(rawValue:CGEventFlags.maskAlternate.rawValue | 0x40)) == [61])
        c("current flags keep unrelated normal keys visible for chord cancellation",grace.confirmedPhysical([8],flags:leftFlags) == [58,8])
        c("generic-only platform flags can corroborate an observed side",grace.confirmedPhysical([],flags:.maskAlternate) == [58])

        // Reproduce release-time HID/session lag through the listener's exact
        // normalizer, then exercise the production routing state machine.
        for key:UInt32 in [58,61,56,60,55,54,59,62] {
            let flag=ListenTrigger.modifierKeyFlags[key]!
            var hold=VoiceShortcutCycle(hold:HotkeySpec(keyCode:key,modifiers:flag),toggle:nil,translation:nil)
            _=hold.event(type:.flagsChanged,code:key,modifiers:flag,down:[key],time:20)
            let up=ListenTrigger.eventDownKeys(type:.flagsChanged,code:key,mods:0,down:[key])
            let ended=hold.event(type:.flagsChanged,code:key,modifiers:0,down:up,time:21)
            c("modifier \(key) release ends instead of cancelling despite a stale physical table",ended == [.holdEnd] && hold.poll([],time:21.02).isEmpty)
        }
        var shared=VoiceShortcutCycle(hold:HotkeySpec(keyCode:58,modifiers:opt),toggle:nil,translation:HotkeySpec(keyCode:3,modifiers:opt))
        _=shared.event(type:.flagsChanged,code:58,modifiers:opt,down:[58],time:30)
        _=shared.poll([58],time:30.31)
        let released=ListenTrigger.eventDownKeys(type:.flagsChanged,code:58,mods:0,down:[58])
        c("confirmed shared Option ends recognition normally on a stale-table release",shared.event(type:.flagsChanged,code:58,modifiers:0,down:released,time:31) == [.holdEnd])
        var tap=VoiceShortcutCycle(hold:HotkeySpec(keyCode:58,modifiers:opt),toggle:nil,translation:HotkeySpec(keyCode:3,modifiers:opt))
        _=tap.event(type:.flagsChanged,code:58,modifiers:opt,down:[58],time:32)
        c("short shared Option release cannot confirm or upload a pending candidate",tap.event(type:.flagsChanged,code:58,modifiers:0,down:released,time:32.1).isEmpty && tap.poll([],time:32.5).isEmpty && tap.pendingPrefixAt == nil)
        c("release flags remove only released modifier families",ListenTrigger.eventDownKeys(type:.flagsChanged,code:58,mods:UInt32(cmdKey),down:[58,55,8]) == [55,8])
        c("a modifier chord still cancels rather than completing dictation",cycle.event(type:.keyDown,code:8,modifiers:opt,down:ListenTrigger.eventDownKeys(type:.keyDown,code:8,mods:opt,down:[58]),time:33) == [.cancel])
    }

}
