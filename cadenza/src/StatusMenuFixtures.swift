import AppKit

enum StatusMenuFixtures {
    static func snapshot(_ state:String)->StatusMenuSnapshot {
        var s=StatusMenuSnapshot();s.shortcut="左 Option";s.engine="iflytek";s.mode="hold"
        if L10n.language == "en" {s.shortcut="Left Option"}
        s.engines=[.init(title:L10n.tr("engine.apple"),value:"apple",available:true),.init(title:L10n.tr("engine.iflytek"),value:"iflytek",available:true),.init(title:L10n.tr("engine.volcengine"),value:"volcengine",available:false)]
        s.microphones=[.init(title:L10n.tr("ui.04b77083689b"),value:"",available:true),.init(title:"USB Microphone",value:"fixture-mic",available:true)]
        s.hasResult=true;s.toggleAvailable=true
        switch state {case "recording":s.phase = .recording(65);s.busy=true
        case "recognizing":s.phase = .recognizing;s.busy=true
        case "paused":s.phase = .paused
        case "error":s.phase = .issue(.accessibility)
        default:break}
        return s
    }
    static func run(_ check:(String,Bool)->Void) {
        let target=NSObject(),menu=NSMenu()
        func entry(_ id:String)->NSMenuItem?{menu.items.first{$0.identifier?.rawValue==id}}
        for state in ["idle","recording","recognizing","paused","error"] {
            let s=snapshot(state);StatusMenuController.rebuild(menu,s:s,target:target)
            check("\(state) native manual enablement",!menu.autoenablesItems && entry("record")?.isEnabled==s.canRecord)
            check("\(state) status uses readable colored text",entry("status")?.attributedTitle != nil)
            check("\(state) settings and quit shortcuts",entry("settings")?.keyEquivalent=="," && entry("quit")?.keyEquivalent=="q" && entry("settings")?.keyEquivalentModifierMask == .command)
            check("\(state) copy protects empty or active results",entry("copy")?.isEnabled == !s.busy)
            check("\(state) busy blocks config and pause",entry("mode")?.submenu?.items.first?.isEnabled == !s.busy && entry("pause")?.isEnabled == !s.busy)
            check("\(state) current values are native subtitles",entry("engine")?.subtitleText==L10n.tr("engine.iflytek") && entry("mic")?.subtitleText==L10n.tr("ui.04b77083689b"))
            check("\(state) unconfigured engine disabled",entry("engine")?.submenu?.items[2].isEnabled==false)
            check("\(state) symbol respects template color",StatusMenuController.image(s)?.isTemplate==s.template)
            check("\(state) quit targets the application",entry("quit")?.target === NSApplication.shared)
            check("\(state) only one root settings entry",menu.items.filter{$0.action==NSSelectorFromString("showSettings")}.count==1)
        }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("menu-fixture-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=ConfigStore(fileURL:root.appendingPathComponent("config.json"))
        let pipeline=VoicePipeline(configStore:store,input:InputSourceController());pipeline.selfTestMode=true
        let recorder=TriggerStage2Fixtures.Recorder();pipeline.recorderFactory={recorder}
        pipeline.snapshotFocus={nil};pipeline.insertText={_,_ in assertionFailure("menu fixture must never insert");return false}
        for mode in ["hold","toggle"] {
            _=store.mutate{$0.inputMode=mode}
            pipeline.holdStarted(source:.menu)
            check("menu starts a single latched session in \(mode) mode",recorder.begins==(mode == "hold" ? 1:2) && pipeline.session?.source == .menu && pipeline.session?.state == .voiceStarted)
            pipeline.holdEnded()
            check("menu stop ends collection once in \(mode) mode",recorder.ends==(mode == "hold" ? 1:2) && pipeline.session?.state == .awaitingConfirm)
            recorder.onFinal?("");TriggerStage2Fixtures.drain()
            check("empty menu result never becomes copyable in \(mode) mode",pipeline.lastTranscript==nil && !pipeline.hasActiveSession)
        }
        check("menu tests leave new coordinator disabled",!store.config.triggerCoordinatorEnabled)
        var s=snapshot("idle");s.toggleAvailable=false;s.hasResult=false
        StatusMenuController.rebuild(menu,s:s,target:target)
        check("no toggle binding disables toggle selection",entry("mode")?.submenu?.items[1].isEnabled==false)
        check("empty result disables copy",entry("copy")?.isEnabled==false)
        s.microphone="fixture-mic";s.microphones.removeLast();s.microphones.append(.init(title:L10n.tr("menu.disconnected"),value:"fixture-mic",available:false))
        StatusMenuController.rebuild(menu,s:s,target:target)
        check("hotplug rebuild shows disconnected selected device",entry("mic")?.submenu?.items.last?.state == .on && entry("mic")?.submenu?.items.last?.isEnabled==false)
        s.phase = .recording(65);StatusMenuController.rebuild(menu,s:s,target:target)
        check("recording shows elapsed minutes and seconds",entry("record")?.title.contains("01:05")==true)
        for reason:SettingsReadiness in [.microphone,.speech,.accessibility,.monitoring,.credentials,.consent,.unavailable,.shortcut] {
            s.phase = .issue(reason);StatusMenuController.rebuild(menu,s:s,target:target)
            check("\(reason) actionable prerequisite header",entry("status")?.action==NSSelectorFromString("resolveMenuIssue") && entry("status")?.isEnabled==true && entry("record")?.isEnabled==false && !s.header.hasPrefix("menu."))
        }
    }
    /// Native menu preview exits before AppDelegate, config, credentials or microphone setup.
    static func preview(_ state:String)->Int32 {
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        if state == "manual" {
            let capsule=CapsuleWindowController()
            DispatchQueue.main.asyncAfter(deadline:.now()+0.2){capsule.showRecord(elapsed:0,manual:true);capsule.tick(elapsed:0,level:0.4)}
            DispatchQueue.main.asyncAfter(deadline:.now()+8){capsule.hide();app.stop(nil);if let e=NSEvent.otherEvent(with:.applicationDefined,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,subtype:0,data1:0,data2:0){app.postEvent(e,atStart:true)}}
            app.run();return 0
        }
        let menu=NSMenu();let target=NSObject();StatusMenuController.rebuild(menu,s:snapshot(state),target:target)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
            DispatchQueue.main.asyncAfter(deadline:.now()+8){menu.cancelTracking();app.stop(nil);if let e=NSEvent.otherEvent(with:.applicationDefined,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,subtype:0,data1:0,data2:0){app.postEvent(e,atStart:true)}}
            menu.popUp(positioning:nil,at:NSPoint(x:100,y:(NSScreen.main?.frame.maxY ?? 800)-60),in:nil)
        }
        app.run();return 0
    }
}
