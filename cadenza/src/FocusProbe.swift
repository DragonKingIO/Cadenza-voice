import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin

/// 焦点身份快照：保存 AX 元素与窗口的引用身份（用于同应用换窗口/换文本框检测），
/// 文本值仅作为"内容变化"证据之一，不单独作为提交结论。
struct FocusIdentity {
    let pid: pid_t
    let appName: String
    let element: AXUIElement?
    let window: AXUIElement?
    let role: String?
    let readable: Bool
    var selectedTextWritable: Bool
    let value: String?   // 仅用于比较，绝不写入日志或文件

    var valueWritable=false // Diagnostic metadata; never used as the insertion interface.
    var protectedInput = false
    var axTrusted = true
    var identityValid = true
    var securityConfirmed = true
    var diagnostics = "injected"
    var retentionReason: String {
        if protectedInput { return L10n.tr("ui.3e9d64dee474") }
        if !axTrusted { return L10n.format("ui.4598b2b407ee", String(describing: Brand.name)) }
        if !securityConfirmed { return L10n.tr("ui.48bdc697edb2") }
        if pid<=0 { return L10n.tr("ui.f0be61553a51") }
        if pid == ProcessInfo.processInfo.processIdentifier { return L10n.tr("ui.598445b1f5be") }
        if element == nil && appName == "com.tencent.xinWeChat" { return L10n.tr("ui.97c15df38a4f") }
        if element == nil { return L10n.tr("ui.e74e72482a7d") }
        if window == nil { return L10n.tr("ui.d3658dde614c") }
        if identityAvailable && !insertionAvailable { return L10n.tr("ui.4d87d65a1451") }
        return L10n.tr("ui.eab37b8b2096")
    }
    var identityAvailable: Bool {pid>0 && axTrusted && identityValid && securityConfirmed && suitable && element != nil && window != nil}
    /// Original process and window are known and not protected, even when no editor can be identified
    /// (for example Chromium-based apps that expose no accessibility tree).
    var windowBoundAvailable: Bool {
        pid>0 && axTrusted && securityConfirmed && !protectedInput && window != nil && pid != ProcessInfo.processInfo.processIdentifier
    }
    func sameWindow(as other:FocusIdentity)->Bool {
        guard pid == other.pid,let a=window,let b=other.window else{return false};return CFEqual(a,b)
    }
    var insertionAvailable:Bool {selectedTextWritable}
    var automaticInputAvailable: Bool {identityAvailable && insertionAvailable}
    static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]

    var suitable: Bool {
        !protectedInput && (role.map { FocusIdentity.textRoles.contains($0) } ?? false)
    }
}

enum FocusChange: Equatable {
    case unchanged
    case valueChanged     // 仅证据之一，不等于"讯飞已提交"
    case elementChanged   // 同窗口换了文本框
    case windowChanged    // 同应用换了窗口
    case appChanged
    case unknown
}

/// AX focused-application PID + kernel executable path + Workspace front bundle.
/// Never enumerate processes by name or create an AX application for PID <= 0.
enum ForegroundIdentity {
    struct Snapshot {let pid:pid_t;let bundleID:String;let workspacePID:pid_t}
    struct Resolution {let snapshot:Snapshot?;let failure:String}

    // Missing AXFocusedApplication is not itself a permission failure. A focused
    // element owner or a positive Workspace front PID can identify the application,
    // but each still needs kernel-path and stable-front checks below.
    static func candidate(applicationPID:pid_t?,elementPID:pid_t?,workspacePID:pid_t)->(pid_t,String)? {
        if let p=applicationPID,p>0 {
            guard workspacePID<=0 || workspacePID==p else{return nil}
            return(p,"system-application")
        }
        if let p=elementPID,p>0 {
            guard workspacePID<=0 || workspacePID==p else{return nil}
            return(p,"system-focused-element")
        }
        if workspacePID>0 {return(workspacePID,"workspace-front")}
        return nil
    }
    static func capture()->Snapshot? {resolve().snapshot}
    static func resolve(skipApplicationForDiagnostic:Bool=false)->Resolution {
        func failure(_ reason:String)->Resolution {Resolution(snapshot:nil,failure:reason)}
        guard AXIsProcessTrusted() else{return failure("ax-untrusted")}
        guard !IsSecureEventInputEnabled() else{return failure("secure-input")}
        guard let front=NSWorkspace.shared.frontmostApplication,
              let bundleURL=front.bundleURL,let expected=Bundle(url:bundleURL)?.executableURL else{return failure("workspace-front-unavailable")}
        let workspacePID=front.processIdentifier
        let system=AXUIElementCreateSystemWide();AXUIElementSetMessagingTimeout(system,0.05)
        func owner(_ key:CFString)->(pid_t?,Int32) {
            var value:CFTypeRef?
            var rc=AXUIElementCopyAttributeValue(system,key,&value)
            // Retry a messaging failure once within the same bounded call. No
            // delayed reacquisition after a missing original target or focus change.
            if rc == .cannotComplete {rc=AXUIElementCopyAttributeValue(system,key,&value)}
            guard rc == .success,let value=value,CFGetTypeID(value)==AXUIElementGetTypeID() else{return(nil,rc.rawValue)}
            var pid:pid_t=0
            guard AXUIElementGetPid(value as! AXUIElement,&pid) == .success,pid>0 else{return(nil,rc.rawValue)}
            return(pid,rc.rawValue)
        }
        let (applicationPID,appRC)=skipApplicationForDiagnostic ? (nil,Int32(AXError.noValue.rawValue)):owner(kAXFocusedApplicationAttribute as CFString)
        let (elementPID,elementRC)=applicationPID == nil ? owner(kAXFocusedUIElementAttribute as CFString):(nil,Int32(-1))
        guard let (pid,source)=candidate(applicationPID:applicationPID,elementPID:elementPID,workspacePID:workspacePID) else {
            Log.write("foreground-identity rejected=no-consistent-pid appRC=\(appRC) elementRC=\(elementRC) workspacePositive=\(workspacePID>0)")
            return failure("ax-front-unavailable appRC=\(appRC) elementRC=\(elementRC)")
        }
        var buffer=[CChar](repeating:0,count:4096)
        let count=proc_pidpath(pid,&buffer,UInt32(buffer.count))
        let pathMatches=count>0 && URL(fileURLWithPath:String(cString:buffer)).resolvingSymlinksInPath().standardizedFileURL == expected.resolvingSymlinksInPath().standardizedFileURL
        let again=NSWorkspace.shared.frontmostApplication
        let stableFront=again?.bundleURL==bundleURL && (again?.processIdentifier ?? 0)==workspacePID
        guard pathMatches,stableFront,!IsSecureEventInputEnabled() else {
            Log.write("foreground-identity rejected=signals-disagree pathMatches=\(pathMatches) stableFront=\(stableFront)")
            return failure("front-signals-disagree")
        }
        if source != "system-application" || workspacePID<=0 {
            Log.write("foreground-identity resolved-pid=\(pid) source=\(source) appRC=\(appRC) elementRC=\(elementRC) workspacePositive=\(workspacePID>0) diagnosticPrimaryOmitted=\(skipApplicationForDiagnostic) kernelPathAgree=true stableFront=true main-thread=\(Thread.isMainThread)")
        }
        return Resolution(snapshot:Snapshot(pid:pid,bundleID:front.bundleIdentifier ?? "",workspacePID:workspacePID),failure:"")
    }
}

/// A retained key window in an inactive app does not own the physical shortcut.
enum TrialFocusOwnership {
    static func matches(appActive: Bool, frontPID: pid_t?, ownPID: pid_t, windowKey: Bool, windowVisible: Bool) -> Bool {
        appActive && frontPID == ownPID && windowKey && windowVisible
    }
}

enum FocusProbe {
    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func protectedTarget(role: String?, subrole: String?, secureInput: Bool) -> Bool {
        secureInput || role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }
    static func snapshot() -> FocusIdentity? {
        let trusted=accessibilityTrusted
        let resolution=ForegroundIdentity.resolve()
        guard let identity=resolution.snapshot else {
            return FocusIdentity(pid:0,appName:"?",element:nil,window:nil,role:nil,readable:false,selectedTextWritable:false,value:nil,protectedInput:IsSecureEventInputEnabled(),axTrusted:trusted,identityValid:false,diagnostics:"identity-error=\(resolution.failure) no-application-ax=true")
        }
        let pid=identity.pid
        let appAX=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(appAX,0.05)
        func attribute(_ e:AXUIElement,_ key:String)->(CFTypeRef?,Int32) {
            var v:CFTypeRef?;let rc=AXUIElementCopyAttributeValue(e,key as CFString,&v);return(v,rc.rawValue)
        }
        func element(_ v:CFTypeRef?)->AXUIElement? { guard let v=v,CFGetTypeID(v)==AXUIElementGetTypeID() else{return nil};return (v as! AXUIElement) }
        let (el,elRC)=attribute(appAX,kAXFocusedUIElementAttribute);let (win,winRC)=attribute(appAX,kAXFocusedWindowAttribute)
        var e=element(el);let w=element(win)
        // Direct focused attributes may be absent on the application root. Only accept
        // a genuinely focused editor belonging to the original PID and window.
        var source="app",visited=0
        func belongs(_ node:AXUIElement)->Bool {
            guard let w=w else{return false};var owner:pid_t=0
            guard AXUIElementGetPid(node,&owner) == .success,owner == pid else{return false}
            if let ownWindow=element(attribute(node,kAXWindowAttribute).0),CFEqual(ownWindow,w){return true}
            var parent:AXUIElement?=node
            for _ in 0..<6 {guard let n=parent else{break};AXUIElementSetMessagingTimeout(n,0.01);if CFEqual(n,w){return true};parent=element(attribute(n,kAXParentAttribute).0)}
            return false
        }
        func focusedEditor(_ node:AXUIElement)->Bool {
            AXUIElementSetMessagingTimeout(node,0.015)
            guard attribute(node,kAXFocusedAttribute).0 as? Bool == true,
                  let role=attribute(node,kAXRoleAttribute).0 as? String,FocusIdentity.textRoles.contains(role),belongs(node) else{return false}
            let sub=attribute(node,kAXSubroleAttribute)
            guard !protectedTarget(role:role,subrole:sub.0 as? String,secureInput:IsSecureEventInputEnabled()),role != "AXTextField" || (sub.1 == 0 && sub.0 as? String != nil) else{return false}
            return true // Focus/identity discovery is separate from insertion capability.
        }
        if trusted,!IsSecureEventInputEnabled(),let w=w,
           e == nil || (attribute(e!,kAXRoleAttribute).0 as? String).map({!FocusIdentity.textRoles.contains($0)}) == true {
            let system=AXUIElementCreateSystemWide();AXUIElementSetMessagingTimeout(system,0.015)
            for (root,label) in [(system,"system"),(w,"window")] {
                if let candidate=element(attribute(root,kAXFocusedUIElementAttribute).0),focusedEditor(candidate){e=candidate;source=label;break}
            }
            if source == "app" {
                let deadline=ProcessInfo.processInfo.systemUptime+0.12
                var queue:[(AXUIElement,Int)]=[(w,0)],matches:[AXUIElement]=[],seen=Set<CFHashCode>()
                while !queue.isEmpty,visited < 100,ProcessInfo.processInfo.systemUptime < deadline {
                    let (node,depth)=queue.removeFirst();guard seen.insert(CFHash(node)).inserted else{continue};visited+=1;AXUIElementSetMessagingTimeout(node,0.01)
                    let role=attribute(node,kAXRoleAttribute).0 as? String
                    if protectedTarget(role:role,subrole:attribute(node,kAXSubroleAttribute).0 as? String,secureInput:false){continue}
                    if focusedEditor(node){matches.append(node);if matches.count > 1 {break}}
                    if depth < 6 {
                        for key in [kAXChildrenAttribute,kAXContentsAttribute] {
                            if let children=attribute(node,key).0 as? [AXUIElement] {queue.append(contentsOf:children.prefix(100-visited).map{($0,depth+1)})}
                        }
                    }
                }
                // Incomplete or ambiguous searches never choose the first editable child.
                if queue.isEmpty,matches.count == 1 {e=matches[0];source="focused-descendant"}
            }
        }
        var role:String?,subrole:String?,windowRole:String?
        let value:String?=nil
        var roleRC:Int32 = -1,subRC:Int32 = -1,writeRC:Int32 = -1,windowRoleRC:Int32 = -1
        let valueRC:Int32 = -1
        let readable=false
        var selectedWritable=false,valueWritable=false
        var selectedWriteRC:Int32 = -1
        if let e=e { AXUIElementSetMessagingTimeout(e,0.05);let r=attribute(e,kAXRoleAttribute);role=r.0 as? String;roleRC=r.1;let sub=attribute(e,kAXSubroleAttribute);subrole=sub.0 as? String;subRC=sub.1 }
        if let w=w { AXUIElementSetMessagingTimeout(w,0.05);let r=attribute(w,kAXRoleAttribute);windowRole=r.0 as? String;windowRoleRC=r.1 }
        let protected=protectedTarget(role:role,subrole:subrole,secureInput:IsSecureEventInputEnabled())
        let securityKnown=role != "AXTextField" || (subRC == 0 && subrole != nil)
        // Live focus probing never reads text values. Value writability is metadata only.
        if !protected && securityKnown,let e=e,role.map({FocusIdentity.textRoles.contains($0)}) == true {
            var flag:DarwinBoolean=false;writeRC=AXUIElementIsAttributeSettable(e,kAXValueAttribute as CFString,&flag).rawValue;valueWritable=writeRC == 0 && flag.boolValue
            flag=false;selectedWriteRC=AXUIElementIsAttributeSettable(e,kAXSelectedTextAttribute as CFString,&flag).rawValue;selectedWritable=selectedWriteRC == 0 && flag.boolValue
        }
        let valid=(e.map{belongs($0)} ?? false) && ForegroundIdentity.capture()?.pid == pid && e != nil && w != nil && e.map{!CFEqual($0,appAX)} == true && w.map{!CFEqual($0,appAX)} == true && ["AXWindow","AXSheet"].contains(windowRole ?? "")
        func safeRole(_ s:String?)->String {guard let s=s,s.count<80,s.hasPrefix("AX"),s.allSatisfy({$0.isASCII && ($0.isLetter || $0.isNumber)}) else{return "unknown"};return s}
        let metadata="source=\(source) visited=\(visited) trust=\(trusted) pid=\(pid) role=\(safeRole(role)) windowRole=\(safeRole(windowRole)) elRC=\(elRC) winRC=\(winRC) roleRC=\(roleRC) subRC=\(subRC) windowRoleRC=\(windowRoleRC) valueRC=\(valueRC) valueWritableRC=\(writeRC) selectedWritableRC=\(selectedWriteRC) valueWritable=\(valueWritable) selectedTextWritable=\(selectedWritable) missingElement=\(e == nil) missingWindow=\(w == nil) identityValid=\(valid) securityConfirmed=\(securityKnown) elementHash=\(e.map{String(CFHash($0))} ?? "none") windowHash=\(w.map{String(CFHash($0))} ?? "none") secure=\(protected)"
        return FocusIdentity(pid:pid,appName:identity.bundleID,element:e,window:w,role:role,readable:readable,selectedTextWritable:selectedWritable,value:value,valueWritable:valueWritable,protectedInput:protected,axTrusted:trusted,identityValid:valid,securityConfirmed:securityKnown,diagnostics:metadata)
    }
    static func trace(_ focus:FocusIdentity?,stage:String,branch:String) {
        Log.write("focus-probe stage=\(stage) branch=\(branch) \(focus?.diagnostics ?? "trust=\(accessibilityTrusted) pid=none missingElement=true missingWindow=true")")
    }

    static func classify(previous: FocusIdentity, current: FocusIdentity?) -> FocusChange {
        guard let cur = current else { return .unknown }
        if cur.pid != previous.pid { return .appChanged }
        guard previous.identityAvailable, cur.identityAvailable else { return .unknown }
        if let pw = previous.window, let cw = cur.window, !CFEqual(pw, cw) { return .windowChanged }
        if let pe = previous.element, let ce = cur.element, !CFEqual(pe, ce) { return .elementChanged }
        if previous.readable, cur.readable, let ov = previous.value, let nv = cur.value {
            return nv != ov ? .valueChanged : .unchanged
        }
        return previous.identityAvailable && cur.identityAvailable ? .unchanged : .unknown
    }
}

/// CGWindowList 观察讯飞进程窗口集合（仅讯飞自身窗口的 pid/layer/onscreen/bounds，
/// 不读窗口名，不涉及其他应用，无需屏幕录制权限）。
/// 注意：窗口集合变化与录音状态的对应关系【未验证】，只作证据记录，不驱动状态机。
enum PanelObserver {
    static func iflytekWindows() -> Set<String> {
        var keys = Set<String>()
        let pidSet = Set(NSWorkspace.shared.runningApplications.compactMap { app -> Int32? in
            let p = (app.bundleURL?.path ?? app.executableURL?.path ?? "").lowercased()
            let n = (app.localizedName ?? "").lowercased()
            if p.contains("iflytek") || n.contains("iflytek") || p.contains(L10n.tr("ui.8fef46910cb0")) || n.contains(L10n.tr("ui.8fef46910cb0")) {
                return app.processIdentifier
            }
            return nil
        })
        guard !pidSet.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return keys
        }
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? Int, pidSet.contains(pid_t(pid)) else { continue }
            let layer = w[kCGWindowLayer as String] as? Int ?? -999
            let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
            let bounds: String
            if let b = w[kCGWindowBounds as String] as? [String: Any] {
                bounds = "\(b["X"] ?? 0),\(b["Y"] ?? 0),\(b["Width"] ?? 0),\(b["Height"] ?? 0)"
            } else {
                bounds = "?"
            }
            keys.insert("\(pid)|\(layer)|\(bounds)|\(onscreen)")
        }
        return keys
    }
}
