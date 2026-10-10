import AppKit
import Carbon.HIToolbox

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
        // The two shortcuts are independent; setting one switches it on
        let spec = HotkeySpec(keyCode: 2, modifiers: UInt32(controlKey) | UInt32(optionKey))
        var base = BridgeConfig.default(); base.holdShortcutEnabled = true; base.toggleTrigger = nil; base.toggleShortcutEnabled = false; base.syncInputMode()
        let withTap = base.settingShortcut(mode: "toggle", candidate: spec, enabled: nil)
        check("setting the tap shortcut switches it on and leaves the hold shortcut on", withTap.toggleActive && withTap.holdShortcutEnabled && withTap.toggleTrigger == spec && !withTap.primaryIsToggle && withTap.inputMode == "hold")
        let holdOff = withTap.settingShortcut(mode: "hold", candidate: nil, enabled: false)
        check("switching hold off leaves only the tap shortcut, and the tap wording follows", holdOff.primaryIsToggle && holdOff.inputMode == "toggle" && holdOff.anyShortcutOn && holdOff.toggleActive)
        let removed = holdOff.settingShortcut(mode: "toggle", candidate: nil, enabled: nil)
        check("removing the tap shortcut clears and switches it off", removed.toggleTrigger == nil && !removed.toggleShortcutEnabled && !removed.toggleActive && !removed.anyShortcutOn && BridgeConfig.validate(removed).isEmpty)
        let holdBack = removed.settingShortcut(mode: "hold", candidate: BridgeConfig.default().trigger, enabled: nil)
        check("setting the hold shortcut again switches it back on", holdBack.holdShortcutEnabled && holdBack.anyShortcutOn && holdBack.inputMode == "hold")
        check("a stale tap switch without a key is not active", { var c = base; c.toggleShortcutEnabled = true; return !c.toggleActive && !c.anyShortcutOn == !c.holdShortcutEnabled }())
        // The translation shortcut
        let leftOption = HotkeySpec(keyCode: 58, modifiers: UInt32(optionKey)), rightOption = HotkeySpec(keyCode: 61, modifiers: UInt32(optionKey))
        let optionT = HotkeySpec(keyCode: 17, modifiers: UInt32(optionKey) | UInt32(controlKey) | UInt32(cmdKey) , modifierKeyCodes: [58, 59, 55])
        check("overlap: only the same key with the same modifiers; a combination that contains a lone Option is fine", ShortcutPolicy.overlaps(leftOption, leftOption) && ShortcutPolicy.overlaps(optionT, optionT) && !ShortcutPolicy.overlaps(leftOption, optionT) && !ShortcutPolicy.overlaps(optionT, leftOption) && !ShortcutPolicy.overlaps(leftOption, rightOption) && !ShortcutPolicy.overlaps(rightOption, optionT))
        var withTranslate = BridgeConfig.default(); withTranslate.trigger = leftOption; withTranslate.translate.target = "English"
        let translateSet = withTranslate.settingShortcut(mode: "translate", candidate: rightOption, enabled: nil)
        check("translation shortcut: set leaves hold and tap alone and is valid next to Left Option", translateSet.translate.trigger == rightOption && translateSet.trigger == leftOption && translateSet.holdShortcutEnabled == withTranslate.holdShortcutEnabled && translateSet.toggleTrigger == withTranslate.toggleTrigger && BridgeConfig.validate(translateSet).isEmpty)
        let translateSame = withTranslate.settingShortcut(mode: "translate", candidate: leftOption, enabled: nil)
        check("translation shortcut: the same key as dictation is refused", !BridgeConfig.validate(translateSame).isEmpty)
        check("translation shortcut: removing clears only it", translateSet.settingShortcut(mode: "translate", candidate: nil, enabled: nil).translate.trigger == nil && BridgeConfig.validate(translateSet.settingShortcut(mode: "translate", candidate: nil, enabled: nil)).isEmpty)
        let saved = (try? JSONEncoder().encode(translateSet)).flatMap { try? JSONDecoder().decode(BridgeConfig.self, from: $0) }
        check("translation shortcut: survives saving, and an older file without one loads", saved?.translate.trigger == rightOption && (try? JSONDecoder().decode(TranslateSettings.self, from: Data("{\"target\":\"English\"}".utf8)))?.trigger == nil)
        // Looser, still safe: a shortcut that is switched off cannot clash, VoiceOver's pair only matters with VoiceOver on,
        // and Command with Shift is allowed for keys that are not editing or app commands.
        var holdSwitchedOff = withTranslate; holdSwitchedOff.holdShortcutEnabled = false
        let optionL = HotkeySpec(keyCode: 37, modifiers: UInt32(optionKey) | UInt32(controlKey) | UInt32(cmdKey), modifierKeyCodes: [58, 59, 55])
        check("translation shortcut: a combination with Left Option is valid next to hold-to-talk on Left Option", ShortcutPolicy.basicReason(optionL, standardFunctionKeys: true, voiceOver: false) == nil && BridgeConfig.validate(withTranslate.settingShortcut(mode: "translate", candidate: optionL, enabled: nil)).isEmpty)
        check("translation shortcut: the very same key as a hold-to-talk that is switched off is fine, as one that is on is not", BridgeConfig.validate(holdSwitchedOff.settingShortcut(mode: "translate", candidate: leftOption, enabled: nil)).isEmpty && !BridgeConfig.validate(translateSame).isEmpty)
        let ctrlOpt = HotkeySpec(keyCode: 17, modifiers: UInt32(controlKey) | UInt32(optionKey)), cmdShiftL = HotkeySpec(keyCode: 37, modifiers: UInt32(cmdKey) | UInt32(shiftKey))
        check("shortcut rules: Control+Option is refused only while VoiceOver is on", ShortcutPolicy.basicReason(ctrlOpt, voiceOver: false) == nil && ShortcutPolicy.basicReason(ctrlOpt, voiceOver: true) != nil)
        check("shortcut rules: Command+Shift with a non-editing key is allowed, a bare Command key and the protected commands are not",
              ShortcutPolicy.basicReason(cmdShiftL, voiceOver: false) == nil && ShortcutPolicy.basicReason(HotkeySpec(keyCode: 37, modifiers: UInt32(cmdKey)), voiceOver: false) != nil
              && ShortcutPolicy.basicReason(HotkeySpec(keyCode: 17, modifiers: UInt32(cmdKey) | UInt32(shiftKey)), voiceOver: false) != nil && ShortcutPolicy.basicReason(HotkeySpec(keyCode: 8, modifiers: UInt32(cmdKey) | UInt32(shiftKey)), voiceOver: false) != nil)
        check("shortcut rules: a lone letter or Option+letter is still refused, since it would type", ShortcutPolicy.basicReason(HotkeySpec(keyCode: 17, modifiers: UInt32(optionKey)), voiceOver: false) != nil && ShortcutPolicy.basicReason(HotkeySpec(keyCode: 17, modifiers: UInt32(controlKey)), voiceOver: false) != nil)
        check("shortcut rules: there are always suggestions to offer", ShortcutPolicy.suggestions(limit: 3) { ShortcutPolicy.basicReason($0, standardFunctionKeys: true, voiceOver: false) == nil }.count == 3)
        controller.window?.close()
    }
}
