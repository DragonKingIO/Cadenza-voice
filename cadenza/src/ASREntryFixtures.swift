import AppKit
import ApplicationServices

// Complete production main-page entry -> production settings window, with fake dependencies.
// Mouse posting is a separate optional live check guarded by a fresh, owned onscreen window.
enum ASREntryFixtures {
    static func view(_ root:NSView?,_ id:String)->NSView? {
        guard let root=root else{return nil};if root.identifier?.rawValue==id{return root}
        for child in root.subviews{if let result=view(child,id){return result}};return nil
    }
    static func action(_ control:NSControl)->Bool {guard let selector=control.action else{return false};return NSApp.sendAction(selector,to:control.target,from:control)}
    static func pump(_ seconds:TimeInterval){let end=Date(timeIntervalSinceNow:seconds);repeat{if let event=NSApp.nextEvent(matching:.any,until:Date(timeIntervalSinceNow:0.02),inMode:.default,dequeue:true){NSApp.sendEvent(event)};RunLoop.main.run(until:Date(timeIntervalSinceNow:0.005))}while Date()<end}
    static func buttonReveal(_ button:NSButton){button.scrollToVisible(button.bounds);button.window?.contentView?.layoutSubtreeIfNeeded()}
    static func mouseClick(_ button:NSButton)->String {
        guard let window=button.window,window.isVisible,window.isKeyWindow,NSApp.isActive else{return "blocked-window-not-visible-key-active"}
        let pid=ProcessInfo.processInfo.processIdentifier
        guard ForegroundIdentity.capture()?.pid==pid else{return "blocked-foreground-not-confirmed"}
        guard CGPreflightPostEventAccess() else{return "blocked-post-event-permission"}
        let list=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        guard let info=list.first(where:{($0[kCGWindowOwnerPID as String] as? Int32)==pid && ($0[kCGWindowNumber as String] as? Int)==window.windowNumber}),let dict=info[kCGWindowBounds as String] as? [String:CGFloat],let x=dict["X"],let y=dict["Y"],let width=dict["Width"],let height=dict["Height"] else{return "blocked-no-owned-onscreen-window"}
        let point=window.convertPoint(toScreen:button.convert(NSPoint(x:button.bounds.midX,y:button.bounds.midY),to:nil))
        let quartz=CGPoint(x:point.x,y:(NSScreen.screens.first?.frame.maxY ?? 0)-point.y)
        guard CGRect(x:x,y:y,width:width,height:height).contains(quartz),button.visibleRect.contains(NSPoint(x:button.bounds.midX,y:button.bounds.midY)),button.isEnabled,!button.isHidden else{return "blocked-button-bounds"}
        guard let source=CGEventSource(stateID:.combinedSessionState),let down=CGEvent(mouseEventSource:source,mouseType:.leftMouseDown,mouseCursorPosition:quartz,mouseButton:.left),let up=CGEvent(mouseEventSource:source,mouseType:.leftMouseUp,mouseCursorPosition:quartz,mouseButton:.left) else{return "blocked-event-construction"}
        down.post(tap:.cghidEventTap);up.post(tap:.cghidEventTap);pump(0.25)
        return "posted-owned-button-coordinate"
    }
    static func run(_ check:(String,Bool)->Void,live:Bool=false){
        let app=NSApplication.shared;app.setActivationPolicy(live ? .regular:.prohibited);if live{app.finishLaunching()}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("cadenza-entry-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=ConfigStore(fileURL:root.appendingPathComponent("config.json")),fake=ASRSettingsFixtures.Credentials()
        let main=SettingsWindowController();main.configStore=store;main.asrCredentialWriter=fake
        var busy=false;main.asrBusyProvider={busy}
        main.show(page:1)
        defer{main.asrSettings?.close();main.window?.close()}
        guard let rootView=main.window?.contentView,let entry=view(rootView,"asr.entry.configure") as? NSButton,let hint=view(rootView,"asr.entry.feedback") as? NSTextField,let language=view(rootView,"asr.entry.language") as? NSTextField else{check("ASR entry production controls built",false);return}
        check("ASR entry Apple hides cloud configuration entry",entry.isHidden && hint.isHidden && language.isHidden)
        check("ASR entry local model section exists with honest disabled import download",view(rootView,"asr.local.section") != nil && (view(rootView,"asr.local.import") as? NSButton)?.isEnabled==false && (view(rootView,"asr.local.download") as? NSButton)?.isEnabled==false)
        let selector=main.enginePopup()
        for engine in ASREngine.legacyListed where engine != .apple {
            selector.selectItem(at:ASREngine.legacyListed.firstIndex(of:engine)!);_=action(selector)
            main.show(page:1)
            check("ASR entry \(engine.rawValue) dynamic visible entry matches provider",!entry.isHidden && entry.isEnabled && entry.title.contains(L10n.tr(engine == .iflytek ? "ui.daf29ef7cb93":engine == .volcengine ? "ui.746f101ac011":engine == .tencent ? "ui.42ad801d45fd":engine == .aliyun ? "ui.7c0e5b76f059":engine == .deepgram ? "engine.deepgram":engine == .openai ? "engine.openai":engine == .groq ? "engine.groq":engine == .google ? "engine.google":engine == .assemblyai ? "engine.assemblyai":engine == .elevenlabs ? "engine.elevenlabs":"ui.a33d5a21ef34")))
            check("ASR entry \(engine.rawValue) language reflects real provider",engine == .iflytek ? language.isHidden:!language.isHidden && !language.stringValue.isEmpty && !language.stringValue.contains("中文（普通话）"))
            if live {
                buttonReveal(entry)
                pump(0.2)
                let previous=main.asrSettings
                let result=mouseClick(entry)
                let received=main.asrSettings !== previous && main.asrEntryWasMouseTriggered
                print("[entry-live] provider=\(engine.rawValue) mouse=\(result) action-from-mouse=\(received) opened=\(main.asrSettings?.window?.isVisible == true)")
            }
            if main.asrSettings?.window?.isVisible != true{_=action(entry)}
            guard let controller=main.asrSettings,let window=controller.window,let key=engine.credentialFields.first?.0,let field=view(window.contentView,"asr.credential."+key) as? NSSecureTextField else{check("ASR entry \(engine.rawValue) opens production settings",false);continue}
            check("ASR entry \(engine.rawValue) action opens correct editable form",window.title==engine.title+L10n.tr("ui.df3d58c7d84b") && window.isVisible && field.isEnabled && field.isEditable)
            check("ASR entry \(engine.rawValue) first credential obtains native field editor",window.initialFirstResponder === field && field.currentEditor() != nil && window.firstResponder === field.currentEditor())
            if let editor=field.currentEditor() as? NSTextView {
                editor.insertText("entry-fixture-only",replacementRange:NSRange(location:0,length:0));_=window.makeFirstResponder(nil)
            }
            check("ASR entry \(engine.rawValue) native focused editor accepts fake text",field.stringValue=="entry-fixture-only")
            if let save=view(window.contentView,"asr.save") as? NSButton{_=action(save)}
            check("ASR entry \(engine.rawValue) saving uses fake credentials only",fake.values[engine.rawValue+"."+key]=="entry-fixture-only" && field.stringValue.isEmpty)
            print("[entry-evidence] provider=\(engine.rawValue) programmatic=true visible=\(window.isVisible) key=\(window.isKeyWindow) app-active=\(app.isActive) editor-edit-verified=\(fake.values[engine.rawValue+"."+key]=="entry-fixture-only")")
            controller.close();_=action(entry)
            check("ASR entry \(engine.rawValue) closes reopens with blank credentials",main.asrSettings !== controller && main.asrSettings?.window?.isVisible==true && (view(main.asrSettings?.window?.contentView,"asr.credential."+key) as? NSTextField)?.stringValue.isEmpty==true)
            main.asrSettings?.close()
        }
        busy=true;main.refresh()
        check("ASR entry busy disables button and explains why",!entry.isEnabled && hint.stringValue.contains(L10n.tr("ui.8bb0abbe4a88")))
        let before=main.asrSettings;_=action(entry)
        check("ASR entry busy action independently refuses opening",main.asrSettings === before && main.asrSettings?.window?.isVisible==false && hint.stringValue.contains(L10n.tr("ui.8bb0abbe4a88")))
        busy=false;main.refresh()
        check("ASR entry end recording restores enabled entry",entry.isEnabled && !hint.stringValue.contains(L10n.tr("ui.8bb0abbe4a88")))
    }
}
