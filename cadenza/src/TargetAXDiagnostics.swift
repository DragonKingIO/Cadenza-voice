import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin

/// Bounded metadata only. Does not activate a window, read text or write attributes.
enum TargetAXDiagnostics {
    static func wechat(pid:pid_t) {
        guard pid>0,AXIsProcessTrusted(),!IsSecureEventInputEnabled() else{Log.write("wechat-ax-diagnostic refused=trust-or-secure");return}
        var path=[CChar](repeating:0,count:4096)
        guard proc_pidpath(pid,&path,UInt32(path.count))>0,
              URL(fileURLWithPath:String(cString:path)).resolvingSymlinksInPath() == URL(fileURLWithPath:"/Applications/微信.app/Contents/MacOS/WeChat").resolvingSymlinksInPath() else{Log.write("wechat-ax-diagnostic refused=kernel-path");return}
        let app=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(app,0.1)
        func attr(_ node:AXUIElement,_ key:String)->(CFTypeRef?,Int32) {var v:CFTypeRef?;let rc=AXUIElementCopyAttributeValue(node,key as CFString,&v);return(v,rc.rawValue)}
        func element(_ v:CFTypeRef?)->AXUIElement? {guard let v=v,CFGetTypeID(v)==AXUIElementGetTypeID() else{return nil};return(v as! AXUIElement)}
        func safe(_ value:String?)->String {guard let value=value,value.count<90,value.hasPrefix("AX"),value.allSatisfy({$0.isASCII && ($0.isLetter || $0.isNumber)}) else{return "unknown"};return value}
        let front=ForegroundIdentity.capture()
        Log.write("wechat-ax-diagnostic begin pid=\(pid) frontMatches=\(front?.pid == pid) no-text-read=true no-write=true")
        for key in ["AXManualAccessibility","AXEnhancedUserInterface"] {
            let result=attr(app,key);var flag:DarwinBoolean=false
            let setRC=AXUIElementIsAttributeSettable(app,key as CFString,&flag)
            Log.write("wechat-ax-capability attribute=\(key) readRC=\(result.1) boolValue=\(result.0 as? Bool == true) boolean=\(result.0 is Bool) settableRC=\(setRC.rawValue) settable=\(flag.boolValue)")
        }
        for key in [kAXFocusedUIElementAttribute,kAXFocusedWindowAttribute,kAXMainWindowAttribute] {
            let result=attr(app,key);Log.write("wechat-ax-root attribute=\(key) rc=\(result.1) element=\(element(result.0) != nil)")
        }
        let window=element(attr(app,kAXFocusedWindowAttribute).0)
        guard let window=window else{Log.write("wechat-ax-diagnostic end missingWindow=true");return}
        let deadline=ProcessInfo.processInfo.systemUptime+1.2
        var queue:[(AXUIElement,Int)]=[(window,0)],seen=Set<CFHashCode>(),visited=0
        while !queue.isEmpty,visited<150,ProcessInfo.processInfo.systemUptime<deadline {
            let (node,depth)=queue.removeFirst();guard seen.insert(CFHash(node)).inserted else{continue};visited+=1
            AXUIElementSetMessagingTimeout(node,0.03)
            var owner:pid_t=0;guard AXUIElementGetPid(node,&owner) == .success,owner==pid else{continue}
            let r=attr(node,kAXRoleAttribute),sub=attr(node,kAXSubroleAttribute),focused=attr(node,kAXFocusedAttribute)
            let protected=FocusProbe.protectedTarget(role:r.0 as? String,subrole:sub.0 as? String,secureInput:false)
            var flag:DarwinBoolean=false
            let writableRC=protected ? Int32(-1):AXUIElementIsAttributeSettable(node,kAXSelectedTextAttribute as CFString,&flag).rawValue
            var names:CFArray?;let namesRC=AXUIElementCopyAttributeNames(node,&names)
            let known=(names as? [String] ?? []).filter{[kAXChildrenAttribute,kAXContentsAttribute,kAXFocusedUIElementAttribute,kAXFocusedAttribute,kAXSelectedTextAttribute,kAXSelectedTextRangeAttribute,kAXWindowAttribute].contains($0)}.sorted().joined(separator:",")
            Log.write("wechat-ax-node depth=\(depth) role=\(safe(r.0 as? String)) roleRC=\(r.1) subrole=\(safe(sub.0 as? String)) subRC=\(sub.1) focused=\(focused.0 as? Bool == true) focusedRC=\(focused.1) selectedWritableRC=\(writableRC) selectedWritable=\(flag.boolValue) namesRC=\(namesRC.rawValue) attributes=\(known) protected=\(protected)")
            guard !protected,depth<8 else{continue}
            for key in [kAXChildrenAttribute,kAXContentsAttribute] {
                let result=attr(node,key)
                if let children=result.0 as? [AXUIElement] {queue.append(contentsOf:children.prefix(150-visited).map{($0,depth+1)})}
            }
        }
        Log.write("wechat-ax-diagnostic end visited=\(visited) exhausted=\(queue.isEmpty) frontMatches=\(ForegroundIdentity.capture()?.pid == pid)")
    }
}
