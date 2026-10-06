import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin

enum EnhancedTargetState:String {case same,changed,exited,secure,invalid}
struct EnhancedBoolRead {let rc:Int32;let value:Bool?}
struct EnhancedCapability {let rc:Int32;let writable:Bool}
protocol EnhancedAXAdapter {
    func validate(requireFront:Bool) throws -> EnhancedTargetState
    func read() throws -> EnhancedBoolRead
    func capability() throws -> EnhancedCapability
    func set(_ value:Bool) throws -> Int32
    func inspect(deadline:Double) throws
}
enum EnhancedProbeFailure:String,Error {
    case targetChanged,targetExited,secureInput,invalidTarget,invalidBoolean,notWritable
    case cancelled,deadline,enableRejected,enableUnverified,adapterException
}
struct EnhancedProbeReport {
    var reason="complete",restore="not-needed"
    var original:Bool?,writeAttempted=false,restorationVerified=true,inspected=false
}

/// One-shot diagnostic only. Returns no AX editor reference or insertion target.
/// Cleanup is scoped to the original process even if foreground changes.
final class EnhancedDiagnosticCancellation {
    private let lock=NSLock();private var value=false
    func request(){lock.lock();value=true;lock.unlock()}
    var requested:Bool {lock.lock();defer{lock.unlock()};return value}
}

enum EnhancedAXTransaction {
    static func run(_ adapter:EnhancedAXAdapter,now:()->Double={ProcessInfo.processInfo.systemUptime},stopRequested:()->Bool={false},log:(String)->Void=Log.write)->EnhancedProbeReport {
        var report=EnhancedProbeReport();let deadline=now()+2.0
        func requireSame() throws {
            if stopRequested() {throw EnhancedProbeFailure.cancelled}
            guard now()<deadline else{throw EnhancedProbeFailure.deadline}
            let state=try adapter.validate(requireFront:true);log("enhanced-transaction phase=validate state=\(state.rawValue)")
            switch state {case .same:return;case .changed:throw EnhancedProbeFailure.targetChanged;case .exited:throw EnhancedProbeFailure.targetExited;case .secure:throw EnhancedProbeFailure.secureInput;case .invalid:throw EnhancedProbeFailure.invalidTarget}
        }
        func cleanup() {
            guard let original=report.original else{return}
            do {
                let identity=try adapter.validate(requireFront:false)
                guard identity == .same else{report.restore="original-process-unavailable-\(identity.rawValue)";report.restorationVerified=false;return}
                var setRC:Int32?,setException=false
                if report.writeAttempted && !original {
                    do {setRC=try adapter.set(false);log("enhanced-transaction phase=restore-set rc=\(setRC!)")}
                    catch {setException=true;log("enhanced-transaction phase=restore-set exception=true")}
                }
                // Recheck even when restoration setter failed or threw after a
                // possible side effect. Failed acknowledgements still stop use.
                let value:EnhancedBoolRead
                do {value=try adapter.read()}
                catch {report.restore="read-exception";report.restorationVerified=false;return}
                let matches=value.rc==0 && value.value==original
                log("enhanced-transaction phase=restore-read rc=\(value.rc) boolean=\(value.value != nil) matchesOriginal=\(matches)")
                report.restorationVerified=matches && !setException && (setRC == nil || setRC == 0)
                if setException {report.restore="set-exception-readbackMatches-\(matches)"}
                else if let rc=setRC,rc != 0 {report.restore="set-rejected-readbackMatches-\(matches)"}
                else {report.restore=report.restorationVerified ? (report.writeAttempted ? "restored":"untouched-verified"):"readback-unverified"}
            } catch {report.restore="adapter-exception";report.restorationVerified=false}
        }
        func perform() {
            defer {cleanup()}
            do {
                try requireSame()
                let initial=try adapter.read();log("enhanced-transaction phase=original-read rc=\(initial.rc) boolean=\(initial.value != nil) original=\(initial.value.map{String($0)} ?? "unknown")")
                guard initial.rc==0,let original=initial.value else{throw EnhancedProbeFailure.invalidBoolean}
                report.original=original
                try requireSame()
                if !original {
                    let cap=try adapter.capability();log("enhanced-transaction phase=capability rc=\(cap.rc) writable=\(cap.writable)")
                    guard cap.rc==0,cap.writable else{throw EnhancedProbeFailure.notWritable}
                    try requireSame()
                    // Mark BEFORE invoking setter: a throwing adapter or failed
                    // acknowledgement may still have changed the remote value.
                    report.writeAttempted=true
                    let rc=try adapter.set(true);log("enhanced-transaction phase=enable-set rc=\(rc)")
                    guard rc==0 else{throw EnhancedProbeFailure.enableRejected}
                    let enabled=try adapter.read();log("enhanced-transaction phase=enable-read rc=\(enabled.rc) boolean=\(enabled.value != nil) enabled=\(enabled.value == true)")
                    guard enabled.rc==0,enabled.value==true else{throw EnhancedProbeFailure.enableUnverified}
                }
                try requireSame()
                try adapter.inspect(deadline:min(deadline,now()+0.7));report.inspected=true
                try requireSame()
            } catch let error as EnhancedProbeFailure {report.reason=error.rawValue}
            catch {report.reason=EnhancedProbeFailure.adapterException.rawValue}
        }
        perform()
        if !report.restorationVerified && report.reason == "complete" {report.reason="restorationUnverified"}
        log("enhanced-transaction phase=end reason=\(report.reason) attempted=\(report.writeAttempted) inspected=\(report.inspected) restore=\(report.restore) restorationVerified=\(report.restorationVerified) no-text-read-write=true no-clipboard=true")
        return report
    }
}

/// Native adapter never activates WeChat and never reads string content attributes.
final class NativeWechatEnhancedAdapter:EnhancedAXAdapter {
    let pid:pid_t,app:AXUIElement,window:AXUIElement
    let birth:(UInt64,UInt64)
    let stopRequested:()->Bool
    private static func stamp(_ pid:pid_t)->(UInt64,UInt64)? {
        var info=proc_bsdinfo()
        guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size) else{return nil}
        return(info.pbi_start_tvsec,info.pbi_start_tvusec)
    }
    private static func pathMatches(_ pid:pid_t)->Bool {
        var path=[CChar](repeating:0,count:4096)
        return proc_pidpath(pid,&path,UInt32(path.count))>0 && URL(fileURLWithPath:String(cString:path)).resolvingSymlinksInPath() == URL(fileURLWithPath:"/Applications/微信.app/Contents/MacOS/WeChat").resolvingSymlinksInPath()
    }
    private static func element(_ value:CFTypeRef?)->AXUIElement? {
        guard let value=value,CFGetTypeID(value)==AXUIElementGetTypeID() else{return nil};return(value as! AXUIElement)
    }
    init?(pid:pid_t,cursorConfirmed:Bool,expectedTarget:WechatDiagnosticTarget?=nil,stopRequested:@escaping()->Bool={false}) {
        guard cursorConfirmed,pid>0,AXIsProcessTrusted(),!IsSecureEventInputEnabled(),Self.pathMatches(pid),
              let birth=Self.stamp(pid),ForegroundIdentity.capture()?.pid==pid else{return nil}
        let app=AXUIElementCreateApplication(pid);let timeoutRC=AXUIElementSetMessagingTimeout(app,0.05)
        Log.write("wechat-enhanced phase=app-timeout rc=\(timeoutRC.rawValue)")
        guard timeoutRC == .success else{return nil}
        var value:CFTypeRef?;let rc=AXUIElementCopyAttributeValue(app,kAXFocusedWindowAttribute as CFString,&value)
        Log.write("wechat-enhanced phase=original-window rc=\(rc.rawValue)")
        guard rc == .success,let window=Self.element(value) else{return nil}
        var owner:pid_t=0
        guard AXUIElementGetPid(window,&owner) == .success,owner==pid,ForegroundIdentity.capture()?.pid==pid else{return nil}
        let windowTimeout=AXUIElementSetMessagingTimeout(window,0.05)
        Log.write("wechat-enhanced phase=window-timeout rc=\(windowTimeout.rawValue)")
        guard windowTimeout == .success else{return nil}
        var role:CFTypeRef?;let roleRC=AXUIElementCopyAttributeValue(window,kAXRoleAttribute as CFString,&role)
        Log.write("wechat-enhanced phase=original-window-role rc=\(roleRC.rawValue)")
        guard roleRC == .success,["AXWindow","AXSheet"].contains(role as? String ?? "") else{return nil}
        if let expected=expectedTarget {guard expected.pid==pid,expected.birth.0==birth.0,expected.birth.1==birth.1,CFEqual(expected.window,window),expected.validate() == .same else{return nil}}
        self.pid=pid;self.app=app;self.window=window;self.birth=birth;self.stopRequested=stopRequested
    }
    func validate(requireFront:Bool) throws -> EnhancedTargetState {
        guard let stamp=Self.stamp(pid) else{return .exited}
        guard stamp.0==birth.0,stamp.1==birth.1,Self.pathMatches(pid) else{return .invalid}
        // Restoration may proceed on the SAME original process after foreground
        // switch or secure input; it never writes text or targets the new app.
        guard requireFront else{return .same}
        guard AXIsProcessTrusted() else{return .invalid}
        guard !IsSecureEventInputEnabled() else{return .secure}
        guard ForegroundIdentity.capture()?.pid==pid else{return .changed}
        var value:CFTypeRef?
        let rc=AXUIElementCopyAttributeValue(app,kAXFocusedWindowAttribute as CFString,&value)
        Log.write("wechat-enhanced phase=window-recheck rc=\(rc.rawValue)")
        guard rc == .success,let current=Self.element(value),CFEqual(current,window) else{return .changed}
        return .same
    }
    func read() throws -> EnhancedBoolRead {
        guard try validate(requireFront:false) == .same else{return EnhancedBoolRead(rc:AXError.invalidUIElement.rawValue,value:nil)}
        var value:CFTypeRef?;let rc=AXUIElementCopyAttributeValue(app,"AXEnhancedUserInterface" as CFString,&value)
        guard rc == .success,let value=value,CFGetTypeID(value)==CFBooleanGetTypeID() else{return EnhancedBoolRead(rc:rc.rawValue,value:nil)}
        return EnhancedBoolRead(rc:rc.rawValue,value:CFBooleanGetValue(value as! CFBoolean))
    }
    func capability() throws -> EnhancedCapability {
        var flag:DarwinBoolean=false;let rc=AXUIElementIsAttributeSettable(app,"AXEnhancedUserInterface" as CFString,&flag)
        return EnhancedCapability(rc:rc.rawValue,writable:flag.boolValue)
    }
    func set(_ value:Bool) throws -> Int32 {
        guard try validate(requireFront:value) == .same else{return AXError.invalidUIElement.rawValue}
        return AXUIElementSetAttributeValue(app,"AXEnhancedUserInterface" as CFString,value ? kCFBooleanTrue:kCFBooleanFalse).rawValue
    }
    func inspect(deadline:Double) throws {
        var queue:[(AXUIElement,Int)]=[(window,0)],seen=Set<CFHashCode>(),visited=0
        while !queue.isEmpty,visited<150,ProcessInfo.processInfo.systemUptime<deadline {
            if stopRequested() {throw EnhancedProbeFailure.cancelled}
            guard try validate(requireFront:true) == .same else{throw EnhancedProbeFailure.targetChanged}
            let (node,depth)=queue.removeFirst();guard seen.insert(CFHash(node)).inserted else{continue};visited+=1
            let timeoutRC=AXUIElementSetMessagingTimeout(node,0.02)
            guard timeoutRC == .success else{Log.write("wechat-enhanced phase=node-timeout rc=\(timeoutRC.rawValue)");continue}
            var owner:pid_t=0;guard AXUIElementGetPid(node,&owner) == .success,owner==pid else{continue}
            func attr(_ key:String)->(CFTypeRef?,Int32){var v:CFTypeRef?;let rc=AXUIElementCopyAttributeValue(node,key as CFString,&v);return(v,rc.rawValue)}
            func safe(_ value:CFTypeRef?)->String {guard let s=value as? String,s.count<80,s.hasPrefix("AX"),s.allSatisfy({$0.isASCII && ($0.isLetter || $0.isNumber)}) else{return "unknown"};return s}
            let role=attr(kAXRoleAttribute),sub=attr(kAXSubroleAttribute),focus=attr(kAXFocusedAttribute)
            let protected=FocusProbe.protectedTarget(role:role.0 as? String,subrole:sub.0 as? String,secureInput:IsSecureEventInputEnabled())
            let ownerWindow=attr(kAXWindowAttribute)
            let windowMatches=CFEqual(node,window) || Self.element(ownerWindow.0).map{CFEqual($0,window)} == true
            var flag:DarwinBoolean=false;let rc=protected ? Int32(-1):AXUIElementIsAttributeSettable(node,kAXSelectedTextAttribute as CFString,&flag).rawValue
            Log.write("wechat-enhanced-node diagnosticOnly=true depth=\(depth) ownerMatches=true windowMatches=\(windowMatches) windowRC=\(ownerWindow.1) role=\(safe(role.0)) roleRC=\(role.1) subrole=\(safe(sub.0)) subRC=\(sub.1) focused=\(focus.0 as? Bool == true) focusedRC=\(focus.1) selectedWritableRC=\(rc) selectedWritable=\(flag.boolValue) protected=\(protected)")
            guard !protected,depth<8 else{continue}
            for key in [kAXChildrenAttribute,kAXContentsAttribute] {
                if let children=attr(key).0 as? [AXUIElement] {queue.append(contentsOf:children.prefix(150-visited).map{($0,depth+1)})}
            }
        }
        Log.write("wechat-enhanced phase=metadata-end visited=\(visited) exhausted=\(queue.isEmpty)")
    }
}
