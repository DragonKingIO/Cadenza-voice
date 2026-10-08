import AppKit
import SwiftUI

/// Read-only rendering, with temporary config, no shortcut listeners, no recording or network.
enum BrandPreview {
    static func render(page:String,output:String)->Int32 {
        if page.hasPrefix("onboarding-"),let step=Int(page.dropFirst(11)) {return renderOnboarding(step:step,output:output)}
        if page.hasPrefix("capsule-") {return renderCapsule(stage:String(page.dropFirst(8)),output:output)}
        let provider=page.hasPrefix("provider-") ? ASREngine(rawValue:String(page.dropFirst(9))):nil
        guard let tab=MainTab(rawValue:page) ?? (provider != nil || page == "engines-local" ? .engines:page == "ocr-sheet" ? .ocr:page == "shortcut-editor" ? .shortcuts:nil) else{return 2}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("brand-preview-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        let store=ConfigStore(fileURL:root.appendingPathComponent("config.json"))
        _=store.mutate{$0.engine="apple";$0.hasSeenOnboarding=true;$0.triggerCoordinatorEnabled=false;$0.appearanceMode=CommandLine.arguments.contains("--preview-brand-theme=dark") ? "dark":"light"}
        let pipeline=VoicePipeline(configStore:store,input:InputSourceController());pipeline.selfTestMode=true
        let controller=SettingsWindowController();controller.configStore=store;controller.pipeline=pipeline
        if page == "engines-local" {
            // 演示数据：只改显示状态，不下载、不写盘
            let id=LocalModelCatalog.builtin[0].id
            switch CommandLine.arguments.first(where:{$0.hasPrefix("--preview-local-state=")})?.split(separator:"=").last.map(String.init) {
            case "downloading": LocalModelCenter.shared.previewStates=[id:.downloading(done:71_300_000,total:163_646_737)]
            case "installed": LocalModelCenter.shared.previewStates=[id:.installed(version:"1.0.0")];_=store.mutate{$0.engine="local";$0.localModel.primaryModelID=id}
            case "failed": LocalModelCenter.shared.previewStates=[id:.failed(LocalModelError.checksumMismatch("model.tar.bz2").localizedDescription)]
            case "paused": LocalModelCenter.shared.previewStates=[id:.paused(done:71_300_000,total:163_646_737)]
            default: break
            }
        }
        if page == "ocr", let state = CommandLine.arguments.first(where:{$0.hasPrefix("--preview-local-ocr=")})?.split(separator:"=").last.map(String.init),
           let entry = LocalModelCatalog.builtin.first(where: LocalModelCatalog.isOCR) {
            // Demo state only: nothing is downloaded or written.
            switch state {
            case "downloading": LocalModelCenter.shared.previewStates=[entry.id:.downloading(done:6_200_000,total:entry.downloadSize)]
            case "installed": LocalModelCenter.shared.previewStates=[entry.id:.installed(version:entry.version)];_=store.mutate{$0.screenshot.ocrEngine=PaddleOCREngine.engineID;$0.screenshot.ocrLocalModel=entry.id}
            case "failed": LocalModelCenter.shared.previewStates=[entry.id:.failed(LocalModelError.checksumMismatch("rec.onnx").localizedDescription)]
            default: break
            }
        }
        controller.showSwift(tab)
        if page == "about" {
            switch CommandLine.arguments.first(where:{$0.hasPrefix("--preview-update-state=")})?.split(separator:"=").last.map(String.init) {
            case "available": UpdateChecker.shared.status = .available(UpdateInfo(version:"9.9.9",pageURL:URL(string:"https://github.com/")!,notes:["Faster local models","A clearer About page","Fixes for the menu bar icon"],published:"2026-10-06"))
            case "noRelease": UpdateChecker.shared.status = .noRelease
            case "locked": UpdateChecker.shared.status = .locked
            case "upToDate": UpdateChecker.shared.status = .upToDate("1.0.0")
            case "failed": UpdateChecker.shared.status = .failed
            case "notConfigured": UpdateChecker.shared.status = .notConfigured
            case "checking": UpdateChecker.shared.status = .checking
            case "real": UpdateChecker.shared.check() // uses --update-feed-override, loopback only
            default: break
            }
        }
        // Inspection: change the app language while the page is on screen, to prove the page redraws. Restored afterwards.
        if let flag=CommandLine.arguments.first(where:{$0.hasPrefix("--preview-switch-language=")}),let target=AppLanguage(rawValue:String(flag.dropFirst("--preview-switch-language=".count))) {
            let saved=UserDefaults.standard.object(forKey:"appLanguage")
            if CommandLine.arguments.contains("--preview-click-segment") {
                // Drive the real segmented control the way a click does, instead of calling the setter directly.
                DispatchQueue.main.asyncAfter(deadline:.now()+0.5){
                    func controls(_ view:NSView)->[NSSegmentedControl]{(view as? NSSegmentedControl).map{[$0]} ?? view.subviews.flatMap(controls)}
                    let list=controls(controller.window?.contentView ?? NSView())
                    let labels:[String]=list.first.map{c in (0..<c.segmentCount).map{c.label(forSegment:$0) ?? "?"}} ?? []
                    print("segmented-controls=\(list.map{$0.segmentCount}) labels=\(labels)")
                    if let c=list.first,let index=(0..<c.segmentCount).first(where:{c.label(forSegment:$0) == L10n.tr(target == .en ? "language.en":target == .zhHans ? "language.zh":"language.system")}) {
                        c.selectedSegment=index;_=c.sendAction(c.action,to:c.target);print("clicked-segment=\(index) language-now=\(L10n.language)")
                    } else {print("language-control-not-found")}
                    fflush(stdout)
                }
            } else {DispatchQueue.main.asyncAfter(deadline:.now()+0.5){AppLanguage.current=target}}
            defer{if let saved=saved{UserDefaults.standard.set(saved,forKey:"appLanguage")}else{UserDefaults.standard.removeObject(forKey:"appLanguage")}}
            return renderAfterSwitch(controller:controller,app:app,output:output,store:store)
        }
        if page == "engines-local" {controller.settingsModel?.scope = .local}
        if page == "ocr-sheet" {controller.settingsModel?.ocrDraftFactory={p in OCRProviderDraft(provider:p,settings:ScreenshotSettings(),has:{_ in false},read:{_ in nil},write:{_,_ in true},delete:{_ in true},persist:{_,_,_,_ in true})};controller.settingsModel?.configuringOCR = .baidu}
        if let name=CommandLine.arguments.first(where:{$0.hasPrefix("--preview-engine-tab=")}).map({String($0.dropFirst("--preview-engine-tab=".count))}),let tab=EngineTab(rawValue:name) {controller.settingsModel?.requestedEngineTab=tab}
        if let window=controller.window {window.ignoresMouseEvents=true}
        if let height=CommandLine.arguments.first(where:{$0.hasPrefix("--preview-brand-height=")}).flatMap({Double($0.dropFirst("--preview-brand-height=".count))}) {controller.window?.setContentSize(NSSize(width:CommandLine.arguments.first(where:{$0.hasPrefix("--preview-brand-width=")}).flatMap({Double($0.dropFirst("--preview-brand-width=".count))}) ?? 720,height:height))}
        if let provider {
            controller.settingsModel?.providerDraftFactory={engine in ProviderSettingsDraft(store:store,engine:engine,busy:{false},changed:{},writer:SettingsUIFixtures.Writer(),read:{_ in nil},has:{_ in true})}
            controller.settingsModel?.configuring=provider
        }
        if CommandLine.arguments.contains("--preview-refine") {
            // Synthetic setting only: no key, no network.
            var refine=TextRefineSettings();refine.enabled=true;refine.preset="deepseek"
            if let p=LLMPresets.preset("deepseek"){refine.baseURL=p.baseURL;refine.model=p.model}
            if CommandLine.arguments.contains("--preview-refine-local"),let p=LLMPresets.preset("ollama"){refine.preset=p.id;refine.baseURL=p.baseURL;refine.model=p.model}
            _=store.mutate{$0.refine=refine}
            controller.settingsModel?.sync()
        }
        if CommandLine.arguments.contains("--preview-compare"),let model=controller.settingsModel {
            // Synthetic data only: scripted recognizers, no microphone, no models, no network, no credentials.
            let entries=Array(LocalModelCatalog.builtin.prefix(2)),prompts=VoiceCompare.prompts(forLocale:"zh-CN")
            let candidates=[CompareCandidate.local(entries[0]),.local(entries[1]),.cloud(.tencent),.cloud(.deepgram),.system()]
            let compare=VoiceCompare(prompts:prompts,candidates:candidates,recognizer:{candidate in
                {samples in let i=max(0,min(prompts.count-1,Int((Double(samples.count)/16000).rounded())-2));let t=prompts[i]
                    switch candidate.id {
                    case entries[0].id: return .text(i == 2 ? "把这段代码提交到 get hub 上。":t)
                    case entries[1].id: return .text(i == 0 ? "今天下午三点开会，请提前十分。":i == 3 ? "明天我要去北京见李明和王方。":t)
                    case CompareCandidate.cloud(.tencent).id: return .text(t)
                    case CompareCandidate.cloud(.deepgram).id: return .failed(L10n.tr("compare.err.timeout"))
                    default: return .text(i == 1 ? "我想只用本地识别不想用云端":t)
                    }}
            })
            for i in 0..<prompts.count{compare.setClip(i,[Float](repeating:0.2,count:16000*(i+2)))}
            compare.analyze()
            model.compare=compare;model.showingCompare=true
        }
        if page == "shortcut-editor" {
            controller.editShortcut(mode:"hold")
            controller.inspectActiveShortcutCandidate(HotkeySpec(keyCode:106,modifiers:0))
        }
        func scrollBottom(_ node:NSView){
            if let scroll=node as? NSScrollView,let document=scroll.documentView,document.bounds.height>scroll.contentView.bounds.height {scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,document.bounds.height-scroll.contentView.bounds.height)));scroll.reflectScrolledClipView(scroll.contentView)}
            for child in node.subviews{scrollBottom(child)}
        }
        if CommandLine.arguments.contains("--preview-brand-native") {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.8){
                controller.window?.attachedSheet?.ignoresMouseEvents=true
                if CommandLine.arguments.contains("--preview-brand-scroll=bottom"),let view=controller.window?.attachedSheet?.contentView {scrollBottom(view);view.layoutSubtreeIfNeeded()}
                if let parent=controller.window,let sheet=parent.attachedSheet {print("preview-sheet-height=\(sheet.frame.height) parent-content-height=\(parent.contentLayoutRect.height) contained=\(parent.frame.contains(sheet.frame))")}
                print("preview-window=\((controller.window?.attachedSheet ?? controller.window)?.windowNumber ?? 0)");fflush(stdout)
            }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+(CommandLine.arguments.contains("--preview-brand-native") ? 8:1.5)){
            guard let view=(controller.window?.attachedSheet ?? controller.window)?.contentView else{app.stop(nil);return}
            if CommandLine.arguments.contains("--preview-brand-scroll=bottom") {
                scrollBottom(view)
            }
            view.layoutSubtreeIfNeeded()
            if let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds){
                (controller.window?.attachedSheet ?? controller.window)?.effectiveAppearance.performAsCurrentDrawingAppearance{view.cacheDisplay(in:view.bounds,to:bitmap)}
                if let bytes=bitmap.representation(using:.png,properties:[:]){try? bytes.write(to:URL(fileURLWithPath:output))}
            }
            controller.window?.orderOut(nil);app.stop(nil)
            // Wake the native event loop so stop() returns even with no physical key events.
            if let event=NSEvent.otherEvent(with:.applicationDefined,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,subtype:0,data1:0,data2:0){app.postEvent(event,atStart:true)}
        }
        app.run()
        return FileManager.default.fileExists(atPath:output) ? 0:3
    }

    /// Renders one first-run wizard page with a temporary config. No listeners, no recording, no network.
    static func renderOnboarding(step:Int,output:String)->Int32 {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("brand-preview-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        let dark=CommandLine.arguments.contains("--preview-brand-theme=dark")
        AppearanceController.apply(dark ? "dark":"light")
        let store=ConfigStore(fileURL:root.appendingPathComponent("config.json"))
        _=store.mutate{$0.engine="apple";$0.triggerCoordinatorEnabled=false}
        let pipeline=VoicePipeline(configStore:store,input:InputSourceController());pipeline.selfTestMode=true
        let controller=OnboardingWindowController(configStore:store,pipeline:pipeline,termsOnly:CommandLine.arguments.contains("--preview-terms-only"),onSettings:{},onConfigurationChanged:{},onDone:{})
        controller.showWindow(nil);controller.window?.ignoresMouseEvents=true;controller.inspectStep(step)
        DispatchQueue.main.asyncAfter(deadline:.now()+2.0){
            if let view=controller.window?.contentView {
                view.layoutSubtreeIfNeeded()
                if let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds){
                    // The window background is not part of the view, so paint it first or dark mode renders on white.
                    let appearance=controller.window?.effectiveAppearance ?? NSApp.effectiveAppearance
                    appearance.performAsCurrentDrawingAppearance{view.cacheDisplay(in:view.bounds,to:bitmap)}
                    let image=NSImage(size:view.bounds.size)
                    image.lockFocus()
                    appearance.performAsCurrentDrawingAppearance{NSColor.windowBackgroundColor.setFill();NSRect(origin:.zero,size:view.bounds.size).fill()}
                    bitmap.draw(in:NSRect(origin:.zero,size:view.bounds.size))
                    image.unlockFocus()
                    if let tiff=image.tiffRepresentation,let rep=NSBitmapImageRep(data:tiff),let bytes=rep.representation(using:.png,properties:[:]){try? bytes.write(to:URL(fileURLWithPath:output))}
                }
            }
            controller.window?.orderOut(nil);app.stop(nil)
            if let event=NSEvent.otherEvent(with:.applicationDefined,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,subtype:0,data1:0,data2:0){app.postEvent(event,atStart:true)}
        }
        app.run()
        return FileManager.default.fileExists(atPath:output) ? 0:3
    }

    private static func renderAfterSwitch(controller:SettingsWindowController,app:NSApplication,output:String,store:ConfigStore)->Int32 {
        DispatchQueue.main.asyncAfter(deadline:.now()+2.0){
            if let view=controller.window?.contentView {
                view.layoutSubtreeIfNeeded()
                if let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds){
                    controller.window?.effectiveAppearance.performAsCurrentDrawingAppearance{view.cacheDisplay(in:view.bounds,to:bitmap)}
                    if let bytes=bitmap.representation(using:.png,properties:[:]){try? bytes.write(to:URL(fileURLWithPath:output))}
                }
            }
            print("language-after-switch=\(L10n.language) name=\(Brand.name)");fflush(stdout)
            controller.window?.orderOut(nil);app.stop(nil)
            if let event=NSEvent.otherEvent(with:.applicationDefined,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,subtype:0,data1:0,data2:0){app.postEvent(event,atStart:true)}
        }
        app.run()
        return FileManager.default.fileExists(atPath:output) ? 0:3
    }

    /// Renders the recording bar in one state. `--preview-character` temporarily switches to the character style.
    static func renderCapsule(stage:String,output:String)->Int32 {
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        AppearanceController.apply(CommandLine.arguments.contains("--preview-brand-theme=dark") ? "dark":"light")
        let savedStyle=UserDefaults.standard.object(forKey:"recordingIndicatorStyle")
        defer{if let savedStyle=savedStyle{UserDefaults.standard.set(savedStyle,forKey:"recordingIndicatorStyle")}else{UserDefaults.standard.removeObject(forKey:"recordingIndicatorStyle")}}
        if CommandLine.arguments.contains("--preview-character") {
            UserDefaults.standard.set("character",forKey:"recordingIndicatorStyle");CharacterAssets.prewarm()
            let end=Date().addingTimeInterval(10);while !CharacterAssets.ready && Date()<end {RunLoop.current.run(until:Date().addingTimeInterval(0.05))}
        } else {UserDefaults.standard.set("waveform",forKey:"recordingIndicatorStyle")}
        let capsule=CapsuleWindowController()
        switch stage {
        case "error": capsule.showError(L10n.tr("ui.79250fdff1f6"),action:.retry)
        case "retained": capsule.showError(L10n.tr("ui.a193c59bb0c6"),action:.result)
        case "record": capsule.showRecord(elapsed:0);capsule.inspectWave("record")
        case "recognize": capsule.showRecognize()
        default: return 2
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+1.2){
            if let row=capsule.inspectErrorRow() {print("error-row panel=\(row.panel) icon=\(row.icon) character=\(row.character) label=\(row.label) button=\(row.button) labelH=\(row.labelHeight) textH=\(row.textHeight) labelMaxX=\(row.labelMaxX) buttonMinX=\(row.buttonMinX)")}
            if let view=capsule.inspectionContentView {
                view.layoutSubtreeIfNeeded()
                if let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds){
                    view.cacheDisplay(in:view.bounds,to:bitmap)
                    let image=NSImage(size:view.bounds.size)
                    image.lockFocus();NSColor(calibratedWhite:0.55,alpha:1).setFill();NSRect(origin:.zero,size:view.bounds.size).fill();bitmap.draw(in:NSRect(origin:.zero,size:view.bounds.size));image.unlockFocus()
                    if let tiff=image.tiffRepresentation,let rep=NSBitmapImageRep(data:tiff),let bytes=rep.representation(using:.png,properties:[:]){try? bytes.write(to:URL(fileURLWithPath:output))}
                }
            }
            fflush(stdout);capsule.hide();app.stop(nil)
            if let event=NSEvent.otherEvent(with:.applicationDefined,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,subtype:0,data1:0,data2:0){app.postEvent(event,atStart:true)}
        }
        app.run()
        return FileManager.default.fileExists(atPath:output) ? 0:3
    }
}
