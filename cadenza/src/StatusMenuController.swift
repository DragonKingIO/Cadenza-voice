import AppKit

/// A snapshot avoids credential reads, recording and configuration writes in menu construction.
struct StatusMenuSnapshot {
    enum Phase:Equatable {
        case idle,recording(Int),recognizing,paused,issue(SettingsReadiness),previousError
        /// Recording is already shown by the system microphone indicator and the capsule; a past failed attempt is
        /// explained by the menu header. Neither replaces the app icon.
        var keepsAppIcon:Bool {switch self {case .idle,.previousError,.recording,.recognizing:return true;default:return false}}
    }
    struct Entry {let title:String,value:String,available:Bool;var header=false}
    var phase:Phase = .idle
    var shortcut:String = ""
    var engine:String = "",mode:String = "hold",microphone:String = ""
    var engines:[Entry] = [],microphones:[Entry] = [],translations:[Entry] = []
    /// The language dictation is translated into; empty = translation is off.
    var translateTarget = ""
    var toggleAvailable=false,hasResult=false,busy=false
    /// The display text of the tap shortcut when it is on; `shortcut` is the hold shortcut when it is on.
    var toggleShortcut=""
    /// 截图快捷键的显示文字；空 = 未设置
    var screenshotShortcut="",ocrShortcut=""
    var pinCount=0,pinsHidden=false,pinsClickThrough=false
    /// A newer release the app has found and the person has not skipped; the menu offers to open its page.
    var update:UpdateInfo? = UpdateChecker.shared.available
    var canRecord:Bool {switch phase {case .idle,.previousError,.recording:return true;default:return false}}
    var recording:Bool {if case .recording=phase{return true};return false}
    var header:String {
        switch phase {
        case .idle:
            if !shortcut.isEmpty && !toggleShortcut.isEmpty {return L10n.format("menu.ready.both",shortcut,toggleShortcut)}
            if !toggleShortcut.isEmpty {return L10n.format("menu.ready.toggle",toggleShortcut)}
            return shortcut.isEmpty ? L10n.tr("menu.ready.manual"):L10n.format("menu.ready.hold",shortcut)
        case .recording:return L10n.tr("menu.recording")
        case .recognizing:return L10n.tr("menu.recognizing")
        case .paused:return L10n.tr("menu.paused")
        case .previousError:return L10n.tr("menu.previousError")
        case .issue(let reason):return reason == .credentials ? L10n.format("menu.issue.credentials",engines.first{$0.value==engine}?.title ?? engine):L10n.tr("menu.issue."+reason.rawValue)
        }
    }
    var symbol:String {switch phase {case .recording:return "waveform";case .recognizing:return "ellipsis";case .paused:return "mic.slash";case .issue,.previousError:return "exclamationmark.circle";case .idle:return "mic"}}
    var color:NSColor {switch phase {case .recording:return .systemRed;case .paused:return .secondaryLabelColor;case .issue,.previousError:return .systemOrange;case .recognizing:return .labelColor;case .idle:return NSColor(name:nil){appearance in appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? NSColor(srgbRed:0.45,green:0.85,blue:0.65,alpha:1):NSColor(srgbRed:0.05,green:0.40,blue:0.22,alpha:1)}}}
    var template:Bool {switch phase {case .idle,.paused,.recognizing:return true;default:return false}}
}

/// Uses native items, subtitles and keyboard navigation, without custom menu views.
enum StatusMenuController {
    static func image(_ s:StatusMenuSnapshot)->NSImage? {
        let config=NSImage.SymbolConfiguration(pointSize:17,weight:.semibold).applying(.init(paletteColors:[s.color]))
        let image=NSImage(systemSymbolName:s.symbol,accessibilityDescription:s.header)?.withSymbolConfiguration(config)
        image?.isTemplate=s.template
        return image
    }
    static func rebuild(_ menu:NSMenu,s:StatusMenuSnapshot,target:AnyObject) {
        menu.removeAllItems();menu.autoenablesItems=false
        func item(_ id:String,_ title:String,_ selector:String?=nil,enabled:Bool=true,key:String="")->NSMenuItem {
            let i=NSMenuItem(title:title,action:selector.map{NSSelectorFromString($0)},keyEquivalent:key)
            i.identifier=NSUserInterfaceItemIdentifier(id);i.target=target;i.isEnabled=enabled
            if !key.isEmpty {i.keyEquivalentModifierMask = .command}
            return i
        }
        let actionable:Bool
        switch s.phase {case .issue,.previousError:actionable=true;default:actionable=false}
        let header=item("status",s.header,actionable ? "resolveMenuIssue":nil,enabled:actionable)
        header.attributedTitle=NSAttributedString(string:s.header,attributes:[.foregroundColor:s.color,.font:NSFont.systemFont(ofSize:13,weight:.medium)])
        header.image=image(s);menu.addItem(header);menu.addItem(.separator())
        if let update=s.update {
            let i=NSMenuItem(title:L10n.format("menu.update",update.version),action:#selector(UpdateMenuAction.open(_:)),keyEquivalent:"")
            i.identifier=NSUserInterfaceItemIdentifier("update");i.target=UpdateMenuAction.shared;i.representedObject=update.pageURL
            i.image=NSImage(systemSymbolName:"arrow.down.circle.fill",accessibilityDescription:nil)
            menu.addItem(i);menu.addItem(.separator())
        }
        let recordingTitle:String
        if case .recording(let seconds)=s.phase {recordingTitle=L10n.format("menu.stop",String(format:"%02d:%02d",max(0,seconds)/60,max(0,seconds)%60))}
        else {recordingTitle=L10n.tr("menu.start")}
        menu.addItem(item("record",recordingTitle,"menuRecording",enabled:s.canRecord))
        menu.addItem(item("pause",L10n.tr(s.phase == .paused ? "menu.resume":"menu.pause"),"toggleEnabled",enabled:!s.busy))
        menu.addItem(.separator())
        func submenu(_ id:String,_ title:String,_ entries:[StatusMenuSnapshot.Entry],_ selected:String,_ selector:String)->NSMenu {
            let top=item(id,title),sub=NSMenu();sub.autoenablesItems=false
            top.setSubtitle(entries.first{$0.value==selected}?.title ?? L10n.tr("menu.unavailable"))
            for entry in entries {
                if entry.header {sub.addItem(NSMenuItem.sectionHeader(title:entry.title));continue}
                let label=entry.title+(entry.available ? "":L10n.tr(id == "engine" ? "menu.notConfigured":"menu.unavailableSuffix"))
                let child=item(id+"."+entry.value,label,selector,enabled:!s.busy && entry.available)
                child.representedObject=entry.value;child.state=entry.value==selected ? .on:.off;sub.addItem(child)
            }
            top.submenu=sub;menu.addItem(top);return sub
        }
        let engines=submenu("engine",L10n.tr("ui.8545bbfc5af9"),s.engines,s.engine,"selectEngine:")
        engines.addItem(.separator());engines.addItem(item("manage",L10n.tr("menu.manageEngines"),"showEngineSettings"))
        _=submenu("mic",L10n.tr("ui.714cac30e2ff"),s.microphones,s.microphone,"selectMicrophone:")
        if !s.translations.isEmpty {
            let translate=submenu("translate",L10n.tr("menu.translate"),s.translations,s.translateTarget,"selectTranslate:")
            translate.addItem(.separator());translate.addItem(item("translate.manage",L10n.tr("menu.translate.manage"),"showTranslateSettings"))
        }
        menu.addItem(.separator())
        menu.addItem(item("copy",L10n.tr("menu.copyLast"),"copyLastRecognition",enabled:s.hasResult && !s.busy))
        let shot=item("screenshot",L10n.tr("menu.screenshot"),"startScreenshot",enabled:!s.busy)
        if !s.screenshotShortcut.isEmpty {shot.setSubtitle(s.screenshotShortcut)}
        menu.addItem(shot)
        // 更多截图方式：全屏、延时、重复上次区域、直接识字
        let more=item("screenshot.more",L10n.tr("menu.screenshot.more")),moreMenu=NSMenu();moreMenu.autoenablesItems=false
        moreMenu.addItem(item("screenshot.full",L10n.tr("menu.screenshot.full"),"startFullScreenshot",enabled:!s.busy))
        let delayTop=item("screenshot.delay",L10n.tr("menu.screenshot.delay")),delayMenu=NSMenu();delayMenu.autoenablesItems=false
        for seconds in [3,5,10] {let d=item("screenshot.delay.\(seconds)",L10n.format("menu.screenshot.delaySeconds",seconds),"startDelayedScreenshot:",enabled:!s.busy);d.tag=seconds;delayMenu.addItem(d)}
        delayTop.submenu=delayMenu;moreMenu.addItem(delayTop)
        moreMenu.addItem(item("screenshot.repeat",L10n.tr("menu.screenshot.repeat"),"repeatScreenshot",enabled:!s.busy))
        moreMenu.addItem(.separator())
        let direct=item("screenshot.ocr",L10n.tr("menu.screenshot.ocr"),"startDirectOCR",enabled:!s.busy)
        if !s.ocrShortcut.isEmpty {direct.setSubtitle(s.ocrShortcut)}
        moreMenu.addItem(direct)
        more.submenu=moreMenu;menu.addItem(more)
        if s.pinCount>0 {
            let pins=item("pins",L10n.format("menu.pins",s.pinCount)),pinMenu=NSMenu();pinMenu.autoenablesItems=false
            pinMenu.addItem(item("pins.hide",L10n.tr(s.pinsHidden ? "menu.pins.show":"menu.pins.hide"),"togglePinsHidden"))
            if s.pinsClickThrough {pinMenu.addItem(item("pins.interact",L10n.tr("menu.pins.interact"),"restorePinInteraction"))}
            pinMenu.addItem(item("pins.close",L10n.tr("menu.pins.close"),"closeAllPins"))
            pins.submenu=pinMenu;menu.addItem(pins)
        }
        menu.addItem(.separator())
        menu.addItem(item("settings",L10n.tr("menu.settings"),"showSettings",key:","))
        menu.addItem(item("about",L10n.format("ui.0bf588b9906c",String(describing:Brand.name)),"showAbout"))
        let quit=item("quit",L10n.format("ui.86a56484fcd8",Brand.name),"terminate:",key:"q");quit.target=NSApplication.shared;menu.addItem(quit)
    }
}

extension NSMenuItem {
    /// `NSMenuItem.subtitle` exists from macOS 14.4; touching it earlier would crash. Before that the text is appended to the title.
    func setSubtitle(_ text:String) {
        if #available(macOS 14.4, *) { subtitle=text } else { title=title+" · "+text }
    }
    var subtitleText:String? {
        if #available(macOS 14.4, *) { return subtitle }
        return nil
    }
}
