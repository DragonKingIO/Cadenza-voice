import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Explicit maintenance diagnostics only: no recorder, network recognition or clipboard.
/// Text is read back only from a uniquely owned test editor/document, never arbitrary fields.
enum InsertionDiagnostics {
    private static var window:NSWindow?
    private static var observers:[NSObjectProtocol]=[]
    private static var timeout:Timer?
    private static var active=false
    static var productionEntry:((String,@escaping(Bool)->Void)->Void)?
    static var onFinished:(()->Void)?
    private static func beginPhase() {
        active=true;timeout?.invalidate()
        timeout=Timer.scheduledTimer(withTimeInterval:12,repeats:false){_ in finish("timeout")}
    }
    private static func finish(_ reason:String) {
        guard Thread.isMainThread else{DispatchQueue.main.async{finish(reason)};return}
        guard active else{return};active=false;timeout?.invalidate();timeout=nil
        for observer in observers {NotificationCenter.default.removeObserver(observer);NSWorkspace.shared.notificationCenter.removeObserver(observer)};observers=[]
        window?.orderOut(nil)
        Log.write("insertion-diagnostic phase=finished reason=\(reason) recorder=false")
        onFinished?()
    }
    private static let marker="Cadenza native insertion check"
    private static func attribute(_ element:AXUIElement,_ name:String)->(CFTypeRef?,Int32){var value:CFTypeRef?;let rc=AXUIElementCopyAttributeValue(element,name as CFString,&value);return(value,rc.rawValue)}
    static func native(waitForFocus:Bool=false,afterVerified:(()->Void)?=nil) {
        beginPhase()
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:160),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        w.title="随言 · 受控原生写入诊断";w.isReleasedWhenClosed=false
        let editor=NSTextView(frame:NSRect(x:16,y:16,width:368,height:120));editor.string="";editor.setAccessibilityIdentifier("cadenza-controlled-native-editor")
        var inFlight=false,verified=false
        let attempt:()->Void = {
            guard active,!inFlight,!verified else{return}
            if waitForFocus && (IsSecureEventInputEnabled() || ForegroundIdentity.capture()?.pid != ProcessInfo.processInfo.processIdentifier) {return}
            inFlight=true
            DispatchQueue.global(qos:.userInitiated).async {
                guard let target=FocusProbe.snapshot() else{Log.write("insertion-diagnostic kind=native target=false");DispatchQueue.main.async{inFlight=false};return}
                let owned=target.pid == ProcessInfo.processInfo.processIdentifier && target.element.map{attribute($0,kAXIdentifierAttribute).0 as? String == "cadenza-controlled-native-editor"} == true
                FocusProbe.trace(target,stage:"diagnostic-native",branch:"owned=\(owned)")
                guard owned else{Log.write("insertion-diagnostic kind=native owned=false write=false");DispatchQueue.main.async{inFlight=false};return}
                let current=FocusProbe.snapshot()
                let stable=FocusProbe.classify(previous:target,current:current) == .unchanged
                DispatchQueue.main.async {
                    guard active,stable,target.selectedTextWritable,w.isKeyWindow,w.firstResponder === editor,
                          ForegroundIdentity.capture()?.pid == target.pid,!IsSecureEventInputEnabled() else{inFlight=false;finish("native-focus-changed");return}
                    // Same-process AXUIElement writes terminated the diagnostic process.
                    // Use the actual NSAccessibility SelectedText setter on the owned view's
                    // main thread. External production CF AX insertion is tested separately.
                    let directRejected = !TextInserter.insert(marker,target:target)
                    productionEntry?(marker){accepted in
                    guard active else{return}
                    Log.write("insertion-diagnostic kind=native-production-entry accepted=\(accepted) direct-rejected=\(directRejected) editor-unchanged=\(editor.string.isEmpty) programmatic-events=true")
                    editor.setAccessibilitySelectedText(marker)
                    let accepted=editor.string == marker
                    verified=accepted && editor.string == marker;inFlight=false
                    Log.write("insertion-diagnostic kind=native owned=true accepted=\(accepted) arrived=\(editor.string == marker) length=\(editor.string.count) same-first-responder=\(w.firstResponder === editor)")
                    if verified {if let next=afterVerified {next()} else {finish("native-complete")}} else {finish("native-not-arrived")}
                    }
                }
            }
        }
        if waitForFocus {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main){_ in DispatchQueue.main.asyncAfter(deadline:.now()+0.3,execute:attempt)})
            observers.append(NotificationCenter.default.addObserver(forName:NSWindow.didBecomeKeyNotification,object:w,queue:.main){_ in DispatchQueue.main.asyncAfter(deadline:.now()+0.3,execute:attempt)})
            Log.write("insertion-diagnostic kind=native waiting-for-owned-focus=true no-recorder=true")
        }
        w.contentView?.addSubview(editor);window=w;w.center();w.makeKeyAndOrderFront(nil);w.makeFirstResponder(editor);NSApp.activate(ignoringOtherApps:true)
        DispatchQueue.main.asyncAfter(deadline:.now()+1,execute:attempt)
    }
    static func thirdParty() {
        beginPhase()
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("cadenza-controlled-\(UUID().uuidString).txt")
        do {try Data().write(to:url,options:.atomic)} catch {Log.write("insertion-diagnostic kind=textedit create=false");finish("create-failed");return}
        guard let appURL=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.TextEdit") else{Log.write("insertion-diagnostic kind=textedit available=false");finish("textedit-unavailable");return}
        let config=NSWorkspace.OpenConfiguration();config.activates=true
        NSWorkspace.shared.open([url],withApplicationAt:appURL,configuration:config){ app,error in
            guard let app=app,error == nil else{Log.write("insertion-diagnostic kind=textedit opened=false");finish("open-failed");return}
            DispatchQueue.main.async {
            guard active else{return}
            app.activate(options:[.activateIgnoringOtherApps])
            DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now()+1){
                let frontMatches=ForegroundIdentity.capture()?.bundleID == "com.apple.TextEdit"
                let snapshot=FocusProbe.snapshot()
                FocusProbe.trace(snapshot,stage:"diagnostic-textedit-discovery",branch:"frontMatches=\(frontMatches)")
                guard frontMatches,let target=snapshot,let w=target.window,let e=target.element else{Log.write("insertion-diagnostic kind=textedit target=false frontMatches=\(frontMatches) snapshot=\(snapshot != nil)");finish("external-target-missing");return}
                func owned()->Bool {
                    let doc=attribute(w,kAXDocumentAttribute)
                    guard doc.1 == 0,let text=doc.0 as? String,let document=URL(string:text) else{return false}
                    return document.resolvingSymlinksInPath().standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL
                }
                let isOwned=owned();FocusProbe.trace(target,stage:"diagnostic-textedit",branch:"owned-document=\(isOwned)")
                guard isOwned,target.automaticInputAvailable else{Log.write("insertion-diagnostic kind=textedit owned=\(isOwned) eligible=\(target.automaticInputAvailable) write=false");finish("external-not-eligible");return}
                DispatchQueue.main.async {
                guard active else{return}
                productionEntry?(marker){accepted in
                DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now()+0.3){
                    guard active else{return}
                    guard owned(),FocusProbe.classify(previous:target,current:FocusProbe.snapshot()) == .unchanged else{Log.write("insertion-diagnostic kind=textedit readback-skipped=true");finish("external-focus-changed");return}
                    let result=attribute(e,kAXValueAttribute);let actual=result.0 as? String
                    Log.write("insertion-diagnostic kind=textedit owned=true accepted=\(accepted) readRC=\(result.1) arrived=\(actual == marker) length=\(actual?.count ?? 0)")
                    finish(actual == marker && accepted ? "external-complete":"external-not-arrived")
                    // Leave the owned test document visible for inspection. No other document is closed.
                }
                }
                }
            }
            }
        }
    }
}
