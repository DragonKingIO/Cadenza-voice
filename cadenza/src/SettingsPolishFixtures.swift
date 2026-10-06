import AppKit

enum SettingsPolishFixtures {
    static func run(_ check:(String,Bool)->Void) {
        for parent:CGFloat in [520,560,820] {
            for screen:CGFloat in [700,900,1200] {
                let height=ProviderSheetLayout.height(parentHeight:parent,screenHeight:screen)
                check("sheet fits parent \(Int(parent)) and screen \(Int(screen))",height<=parent-24 && height<=screen-120 && height<=700 && height>=240)
            }
        }
        check("invalid geometry keeps a finite usable sheet",ProviderSheetLayout.height(parentHeight:.nan,screenHeight:.infinity).isFinite)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("polish-fixture-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=ConfigStore(fileURL:root.appendingPathComponent("config.json"));_=store.save()
        let pipeline=VoicePipeline(configStore:store,input:InputSourceController());pipeline.selfTestMode=true
        _=NSApplication.shared
        let controller=SettingsWindowController();controller.configStore=store;controller.pipeline=pipeline
        var begins=0,ends=0,saves=0
        controller.onBeginShortcutRecording={begins+=1};controller.onEndShortcutRecording={ends+=1}
        controller.onSaveModeShortcut={mode,spec,_ in
            saves+=1
            guard let spec else{return "fixture missing"}
            _=store.mutate{if mode == "toggle" {$0.toggleTrigger=spec}else{$0.trigger=spec}}
            return store.save() ? nil:"fixture disk failure"
        }
        controller.showSwift(.shortcuts)
        controller.window?.ignoresMouseEvents=true
        let before=try? Data(contentsOf:root.appendingPathComponent("config.json"))
        controller.settingsModel?.onEditShortcut?("hold")
        controller.window?.attachedSheet?.ignoresMouseEvents=true
        check("SwiftUI Change opens existing native recorder and suspends listening callback",begins==1 && controller.window?.attachedSheet != nil)
        check("Save starts disabled without a candidate",!controller.shortcutEditorCanSave)
        controller.inspectActiveShortcutCandidate(store.config.trigger)
        check("candidate updates sheet text under SwiftUI hosting",controller.shortcutEditorText==HotkeySpecDisplay.string(store.config.trigger) && controller.shortcutEditorCanSave)
        controller.inspectShortcutCancellation()
        check("cancel restores listener callback without writing configuration",ends==1 && saves==0 && (try? Data(contentsOf:root.appendingPathComponent("config.json")))==before)
        controller.settingsModel?.onEditShortcut?("toggle")
        controller.inspectActiveShortcutCandidate(store.config.trigger)
        check("duplicate binding visibly disables Save",controller.shortcutEditorHasError && !controller.shortcutEditorCanSave)
        let key=HotkeySpec(keyCode:106,modifiers:0)
        controller.inspectActiveShortcutCandidate(key)
        check("valid independent toggle binding enables Save",!controller.shortcutEditorHasError && controller.shortcutEditorCanSave)
        controller.inspectSaveActiveShortcut()
        check("save uses existing transaction callback and refreshes SwiftUI",saves==1 && ends==2 && store.config.toggleTrigger==key && controller.settingsModel?.toggleAvailable==true && controller.window?.attachedSheet == nil)
        check("UI shortcut changes do not enable the new trigger path",!store.config.triggerCoordinatorEnabled && !pipeline.hasActiveSession)
        controller.window?.close()
    }
}
