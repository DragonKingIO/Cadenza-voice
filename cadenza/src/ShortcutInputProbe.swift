import AppKit
import Carbon.HIToolbox

/// Installed-binary diagnostic only: native text input plus synthetic keys. No
/// pipeline, recorder, config store, credentials, transcript, clipboard or network.
enum ShortcutInputProbe {
    static func run() -> Int32 {
        // A development copy must never query permissions for the installed app.
        guard Bundle.main.bundleURL.resolvingSymlinksInPath().path=="/Applications/随言.app" else {
            print("[shortcut-input] requires-installed-binary=true");return 2
        }
        let app=NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:420,height:160),styleMask:[.titled],backing:.buffered,defer:false)
        window.title=Brand.name
        let field=NSTextView(frame:NSRect(x:12,y:12,width:396,height:130))
        field.isRichText=false;window.contentView?.addSubview(field)
        window.center();window.makeKeyAndOrderFront(nil);window.makeFirstResponder(field)
        app.activate(ignoringOtherApps:true)
        let listener=ListenTrigger()
        defer {listener.stop();window.orderOut(nil)}
        var starts=0,ends=0,dictation=0,dictationEnds=0,cancels=0
        listener.onTranslateStart={starts+=1};listener.onTranslateEnd={ends+=1};listener.onHoldStart={dictation+=1}
        listener.onHoldEnd={dictationEnds+=1}
        listener.onHoldChord={cancels+=1;print("[shortcut-input-event] cancel=true")}
        guard listener.startBindings(hold:HotkeySpec(keyCode:58,modifiers:UInt32(optionKey)),toggle:nil,translation:HotkeySpec(keyCode:3,modifiers:UInt32(optionKey))) else {
            print("[shortcut-input] unavailable: \(listener.status)");return 2
        }
        func pump(_ seconds:Double) {
            let until=Date().addingTimeInterval(seconds)
            while Date()<until {
                if let event=app.nextEvent(matching:.any,until:Date().addingTimeInterval(0.01),inMode:.default,dequeue:true) {app.sendEvent(event)}
                RunLoop.main.run(until:Date().addingTimeInterval(0.002))
            }
        }
        var postedKeys:Set<CGKeyCode>=[]
        guard let source=CGEventSource(stateID:.hidSystemState) else{return 3}
        defer {
            // Even if the user changes focus during the check, never leave a
            // synthetic modifier/key held. Releases contain no text.
            for code in postedKeys {
                if let event=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:false) {
                    event.flags=[];if code==58 {event.type = .flagsChanged};event.post(tap:.cghidEventTap)
                }
            }
            if !postedKeys.isEmpty {pump(0.1)}
        }
        func post(_ code:CGKeyCode,_ down:Bool,flags:CGEventFlags,text:String?=nil,repeated:Bool=false,modifier:Bool=false)->Bool {
            guard window.isKeyWindow,NSWorkspace.shared.frontmostApplication?.processIdentifier==getpid(),
                  let event=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:down) else{return false}
            // Reproduce Left Option's device flag as well as its generic flag.
            event.flags=CGEventFlags(rawValue:flags.rawValue | (flags.contains(.maskAlternate) ? 0x20:0))
            if modifier {event.type = .flagsChanged}
            if repeated {event.setIntegerValueField(.keyboardEventAutorepeat,value:1)}
            // Use virtual-key events, like a keyboard. Unicode injection takes a
            // different text-input path and is not a physical shortcut test.
            if down {postedKeys.insert(code)} else {postedKeys.remove(code)}
            event.post(tap:.cghidEventTap);pump(0.025);return true
        }
        pump(0.25)
        guard post(58,true,flags:.maskAlternate,modifier:true),post(3,true,flags:.maskAlternate,text:"ƒ") else{return 3}
        for _ in 0..<20 {guard post(3,true,flags:.maskAlternate,text:"ƒ",repeated:true) else{return 3}}
        guard post(3,false,flags:.maskAlternate),post(58,false,flags:[],modifier:true) else{return 3}
        pump(0.15)
        let noLeak=field.string.isEmpty,route=starts==1 && ends==1 && dictation==0
        guard post(3,true,flags:[],text:"f"),post(3,false,flags:[]) else{return 3}
        pump(0.1)
        let ordinary=field.string=="f"
        print("[shortcut-input] no-shortcut-characters=\(noLeak) translation-starts=\(starts) translation-ends=\(ends) dictation-starts=\(dictation) ordinary-f=\(ordinary) cancellations=\(cancels)")
        // Translation-only tests missed the separate modifier release route.
        // Exercise it on the installed binary without recording or recognizing.
        for duration in [0.45,1.0,2.0] {
            guard post(58,true,flags:.maskAlternate,modifier:true) else{return 3}
            pump(duration)
            guard post(58,false,flags:[],modifier:true) else{return 3}
            pump(0.2)
        }
        let held = dictation == 3 && dictationEnds == 3 && cancels == 0 && field.string == "f"
        print("[shortcut-hold-input] starts=\(dictation) ends=\(dictationEnds) cancellations=\(cancels) ordinary-text-unchanged=\(field.string == "f")")
        return noLeak && route && ordinary && held ? 0:1
    }
}
