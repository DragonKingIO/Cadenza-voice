import AppKit
import ApplicationServices

/// Installed only for a live recording. Callback never waits for audio, UI or a lock.
final class RecordingEscapeTap {
    private var tap:CFMachPort?,source:CFRunLoopSource?
    private var cancel:(()->Void)?,fallback:Any?
    private var retries=0,recording=false
    private(set) var consumesEscape=false
    @discardableResult func start(cancel:@escaping()->Void)->Bool {
        stop();self.cancel=cancel;recording=true
        if AXIsProcessTrusted(),install(options:.defaultTap){consumesEscape=true;return true}
        if CGPreflightListenEventAccess(),install(options:.listenOnly){return false}
        fallback=NSEvent.addGlobalMonitorForEvents(matching:.keyDown){[weak self] e in if e.keyCode==53{self?.cancel?()}}
        return false
    }
    private func install(options:CGEventTapOptions)->Bool {
        let context=Unmanaged.passUnretained(self).toOpaque()
        guard let tap=CGEvent.tapCreate(tap:.cgSessionEventTap,place:.headInsertEventTap,options:options,
            eventsOfInterest:CGEventMask(1 << CGEventType.keyDown.rawValue),callback:{_,type,event,info in
                guard let info=info else{return Unmanaged.passUnretained(event)}
                let owner=Unmanaged<RecordingEscapeTap>.fromOpaque(info).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if type == .tapDisabledByTimeout,owner.recording,owner.retries<1,let tap=owner.tap {
                        owner.retries += 1;CGEvent.tapEnable(tap:tap,enable:true)
                    } else {DispatchQueue.main.async{[weak owner] in owner?.degrade()}}
                    return Unmanaged.passUnretained(event)
                }
                guard owner.recording,type == .keyDown,event.getIntegerValueField(.keyboardEventKeycode)==53 else{return Unmanaged.passUnretained(event)}
                let consume=owner.consumesEscape
                DispatchQueue.main.async{[weak owner] in guard owner?.recording == true else{return};owner?.cancel?()}
                return consume ? nil:Unmanaged.passUnretained(event)
            },userInfo:context) else{return false}
        self.tap=tap;let source=CFMachPortCreateRunLoopSource(kCFAllocatorDefault,tap,0)!;self.source=source
        CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes);CGEvent.tapEnable(tap:tap,enable:true);return true
    }
    private func removeTap(){if let tap=tap{CGEvent.tapEnable(tap:tap,enable:false);CFMachPortInvalidate(tap)};if let source=source{CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes)};tap=nil;source=nil;consumesEscape=false}
    private func degrade(){guard recording else{return};removeTap();if fallback == nil {fallback=NSEvent.addGlobalMonitorForEvents(matching:.keyDown){[weak self] e in if e.keyCode==53{self?.cancel?()}}};Log.write("trigger-esc tap-disabled=true consumes=false")}
    func stop(){recording=false;removeTap();if let fallback=fallback{NSEvent.removeMonitor(fallback)};fallback=nil;cancel=nil;retries=0}
    deinit{stop()}
}
