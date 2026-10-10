import AppKit
import QuartzCore
import AVFoundation
import Speech
import Carbon.HIToolbox

private final class PageDocument: NSView { override var isFlipped: Bool { true } }

private final class PrimaryButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        DesignTokens.jade.withAlphaComponent(isEnabled ? 1 : 0.45).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let title = NSAttributedString(string: self.title, attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 14, weight: .semibold)])
        let size = title.size(); title.draw(at: NSPoint(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2))
    }
}

private final class BrandSegmentedControl: NSSegmentedControl {
    override func draw(_ dirtyRect: NSRect) {
        let width = bounds.width / CGFloat(max(1, segmentCount))
        for i in 0..<segmentCount {
            let rect = NSRect(x: CGFloat(i) * width, y: 0, width: width, height: bounds.height)
            if i == selectedSegment { DesignTokens.jade.withAlphaComponent(isEnabled ? 1 : 0.45).setFill(); NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill() }
            let color: NSColor = i == selectedSegment ? .white : isEnabled(forSegment: i) ? .labelColor : .secondaryLabelColor
            let title = NSAttributedString(string: label(forSegment: i) ?? "", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: color]); let size = title.size()
            title.draw(at: NSPoint(x: rect.midX-size.width/2, y: rect.midY-size.height/2))
        }
    }
}

private final class BrandSwitch: NSButton {
    override func accessibilityRole()->NSAccessibility.Role? {.checkBox}
    override func accessibilityValue()->Any? {NSNumber(value:state.rawValue)}
    override func accessibilityPerformPress()->Bool {guard isEnabled else{return false};performClick(nil);return true}

    override func draw(_ dirtyRect:NSRect) {
        let track=NSRect(x:bounds.midX-18,y:bounds.midY-10,width:36,height:20)
        let alpha:CGFloat=(state == .on ? 1:0.25)*(isEnabled ? 1:0.45)
        (state == .on ? DesignTokens.jade:NSColor.secondaryLabelColor).withAlphaComponent(alpha).setFill();NSBezierPath(roundedRect:track,xRadius:10,yRadius:10).fill()
        NSColor.white.withAlphaComponent(isEnabled ? 1:0.6).setFill();NSBezierPath(ovalIn:NSRect(x:state == .on ? track.maxX-18:track.minX+2,y:track.minY+2,width:16,height:16)).fill()
    }
}
final class BrandCheckbox: NSButton {
    override func draw(_ dirtyRect:NSRect) {
        let square=NSRect(x:1,y:bounds.midY-7,width:14,height:14)
        (state == .on ? DesignTokens.jade:NSColor.controlBackgroundColor).withAlphaComponent(isEnabled ? 1:0.45).setFill();NSBezierPath(roundedRect:square,xRadius:4,yRadius:4).fill()
        if state == .on {NSColor.white.setStroke();let tick=NSBezierPath();tick.lineWidth=1.6;tick.move(to:NSPoint(x:4,y:square.midY));tick.line(to:NSPoint(x:7,y:square.maxY-4));tick.line(to:NSPoint(x:12,y:square.minY+4));tick.stroke()} else {NSColor.separatorColor.setStroke();NSBezierPath(roundedRect:square,xRadius:4,yRadius:4).stroke()}
        let label=NSAttributedString(string:title,attributes:[.font:NSFont.systemFont(ofSize:13),.foregroundColor:isEnabled ? NSColor.labelColor:NSColor.disabledControlTextColor]);label.draw(at:NSPoint(x:22,y:bounds.midY-label.size().height/2))
    }
}

private final class ThemeBackground: NSView {
    var sidebar=false
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = (sidebar ? DesignTokens.sidebarBackground:DesignTokens.settingsBackground).cgColor }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

private final class SidebarButton: NSButton {
    var symbol: NSImage?
    override func draw(_ dirtyRect: NSRect) {
        if state == .on {
            DesignTokens.jade.withAlphaComponent(0.13).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        }
        let iconRect = NSRect(x: 16, y: (bounds.height - 18) / 2, width: 18, height: 18)
        symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [contentTintColor ?? .labelColor]))?.draw(in: iconRect)
        let size = attributedTitle.size()
        attributedTitle.draw(in: NSRect(x: 48, y: (bounds.height - size.height) / 2, width: bounds.width - 54, height: size.height))
    }
}

private final class GlassTabButton: NSButton {
    var symbol: NSImage?
    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        // 选中底色由所在 NSGlassEffectView 的 tintColor 承担（官方液态玻璃模式），此处只画内容；
        // 选中内容颜色随外观自适应：浅色玻璃上用深玉绿，深色玻璃上用白
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let selectedContent = dark ? NSColor.white : DesignTokens.jade
        let title: NSAttributedString = selected
            ? NSAttributedString(string: self.title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: selectedContent])
            : attributedTitle
        let titleSize = title.size()
        let iconW: CGFloat = symbol == nil ? 0 : 18
        let gap: CGFloat = symbol == nil ? 0 : 6
        let originX = (bounds.width - iconW - gap - titleSize.width) / 2
        if let symbol = symbol {
            let tint = selected ? selectedContent : (contentTintColor ?? .labelColor)
            symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint]))?.draw(in: NSRect(x: originX, y: (bounds.height - 18) / 2, width: 18, height: 18))
        }
        title.draw(in: NSRect(x: originX + iconW + gap, y: (bounds.height - titleSize.height) / 2, width: titleSize.width + 2, height: titleSize.height))
    }
}

private final class CardView: NSView {
    var usesGlass = false
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        guard !usesGlass else { layer?.backgroundColor = NSColor.clear.cgColor; return } // 玻璃材质承担背景
        layer?.cornerRadius = 10
        layer?.borderWidth = AppearanceController.highContrast ? 1.5:0.8
        layer?.borderColor = DesignTokens.outline.cgColor
        layer?.backgroundColor = DesignTokens.groupBackground.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private var pages: [NSView] = []
    private var pageScrolls: [NSScrollView] = []
    private var engineTabs: NSSegmentedControl?
    private var engineCategory: NSSegmentedControl?
    private var engineListButtons: [NSButton] = []
    private var engineRowViews: [NSView] = []
    private var tabGlassItems: [NSView] = [] // NSGlassEffectView（macOS 26+，按可用性填充）
    private var engineStatusLabels: [NSTextField] = []
    private var engineListCard: NSView?
    private var localSectionView: NSView?
    private var cloudDetailViews: [NSView] = []
    private var apiPanel: NSView?
    private var appleCloud: NSButton?
    private var engineConsent: NSButton?
    private var copyButton: NSButton?, clearButton: NSButton?
    private var navigation: [NSButton] = []
    private var engines: [NSPopUpButton] = []
    private var microphones: [NSPopUpButton] = []
    private var guardedControls: [NSControl] = []
    private var language: NSPopUpButton?
    private var consent: NSButton?
    private var cloud: NSButton?
    private var appID: NSSecureTextField?
    private var apiKey: NSSecureTextField?
    private var secret: NSSecureTextField?
    private var emptyIllustration:TechnicalEmptyStateView?
    private var emptyState:NSView?,resultScroll:NSScrollView?
    private var appearancePopup:NSPopUpButton?
    private var holdSummary:NSTextField?,toggleSummary:NSTextField?
    private var result: NSTextView?
    private var message: NSTextField?
    private var serviceState: NSTextField?
    private var credentialFeedback: NSTextField?
    private var shortcutState: NSTextField?
    private var permissionState: NSTextField?
    private var permissionValues: [NSTextField] = []
    private var permissionActions: [NSButton] = []
    private var externalAccess: NSTextField?
    private var level: NSLevelIndicator?
    private var holdButton: HoldButton?
    private var activationObserver:NSObjectProtocol?
    private var retentionView:NSView?,retentionDetail:NSButton?,appleRow:NSView?
    private var asrConfigureButton:NSButton?,asrEntryFeedback:NSTextField?,providerLanguage:NSTextField?
    var asrCredentialWriter:ASRCredentialWriting=KeychainASRCredentialWriter()
    // Injectable only for isolated UI fixtures; production uses its existing pipeline busy state.
    var asrBusyProvider:(()->Bool)?
    private var asrBusy:Bool {asrBusyProvider?() ?? (pipeline?.hasActiveSession == true)}
    private var switchInspectionWindow:NSWindow?
    private var shortcutSheet:NSWindow?,sheetCap:NSTextField?,sheetFeedback:NSTextField?
    weak var pipeline: VoicePipeline?
    weak var listenTrigger: ListenTrigger?
    var configStore: ConfigStore?
    var onRequestPermissions: (() -> Void)?
    var onShowOnboarding: (() -> Void)?
    var onWechatDiagnostic:(()->Void)?
    private var wechatDiagnosticButton:NSButton?
    var onConfigurationChanged: (() -> Void)?
    var onBeginShortcutRecording: (() -> Void)?
    var onEndShortcutRecording: (() -> Void)?
    var onSaveShortcut: ((HotkeySpec) -> String?)?
    var onSaveModeShortcut: ((String,HotkeySpec?,Bool?) -> String?)?
    private var editingMode=0
    private var modeCaps:[NSTextField]=[],modeFeedback:[NSTextField]=[]
    private var modeRecord:[NSButton]=[],modeSave:[NSButton]=[],modeCancel:[NSButton]=[],modeEnable:[NSButton]=[]
    private var inputModeControl:NSPopUpButton?
    private var keyHint: NSTextField?, keycap: NSTextField?, shortcutFeedback: NSTextField?
    private var shortcutRecord: NSButton?, shortcutSave: NSButton?, shortcutCancel: NSButton?, cancelButton: NSButton?
    private var shortcutMonitor: Any?, shortcutSleepObserver: NSObjectProtocol?
    private var shortcutRecording = false
    private var candidate: HotkeySpec?
    private var shortcutError: String?


    deinit {
        if let observer=activationObserver {NSWorkspace.shared.notificationCenter.removeObserver(observer)}
        if let observer=shortcutSleepObserver {NSWorkspace.shared.notificationCenter.removeObserver(observer)}
        if let monitor=shortcutMonitor {NSEvent.removeMonitor(monitor)}
    }
    var isVisible: Bool { window?.isVisible == true }
    var ownsInputFocus: Bool { TrialFocusOwnership.matches(appActive: NSApp.isActive, frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier, ownPID: ProcessInfo.processInfo.processIdentifier, windowKey: window?.isKeyWindow == true, windowVisible: window?.isVisible == true) }

    var settingsModel: SettingsModel?
    var hostingInstalled = false

    func show(page: Int = 0) {
        if window == nil { build() }
        AppearanceController.apply(configStore?.config.appearanceMode ?? "system")
        selectPage(page)
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func inspectPage(_ page: Int) {
        show()
        guard navigation.indices.contains(page) else { return }
        navigation[page].performClick(nil)
    }
    func inspectIflytekSelection(){show(page:1);engineTabs?.selectedSegment=1;if let tabs=engineTabs,let action=tabs.action{NSApp.sendAction(action,to:tabs.target,from:tabs)};refresh()}
    func inspectSwitchStates() {
        show(page:3)
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:430,height:190),styleMask:[.titled,.closable],backing:.buffered,defer:false);w.title=L10n.tr("ui.6a20207c4a8f");w.isReleasedWhenClosed=false;w.appearance=window?.appearance
        let rows=stack([]);rows.translatesAutoresizingMaskIntoConstraints=false
        for (i,name) in [L10n.tr("ui.3fd47edce45b"),L10n.tr("ui.8da97ddda990"),L10n.tr("ui.329afb3ac4e6"),L10n.tr("ui.d09d7a449f2b")].enumerated(){
            let control=BrandSwitch(title:name,target:nil,action:nil);control.setButtonType(.switch);control.isBordered=false;control.state=i % 2 == 0 ? .off:.on;control.isEnabled=i < 2;control.widthAnchor.constraint(equalToConstant:44).isActive=true;control.heightAnchor.constraint(equalToConstant:26).isActive=true
            control.setAccessibilityLabel(name)
            Log.write("native-switch-semantics index=\(i) role=\(control.accessibilityRole()?.rawValue ?? "none") enabledMatches=\(control.isAccessibilityEnabled() == control.isEnabled) labelMatches=\(control.accessibilityLabel() == name) valueMatches=\((control.accessibilityValue() as? NSNumber)?.intValue == control.state.rawValue) state=\(control.state.rawValue)")
            if !control.isEnabled {Log.write("native-switch-disabled-press rejected=\(!control.accessibilityPerformPress())") }
            let line=stack([text(name),control],horizontal:true);rows.addArrangedSubview(line)
        }
        if let v=w.contentView {v.addSubview(rows);NSLayoutConstraint.activate([rows.leadingAnchor.constraint(equalTo:v.leadingAnchor,constant:20),rows.topAnchor.constraint(equalTo:v.topAnchor,constant:12)])}
        switchInspectionWindow=w;w.center();w.makeKeyAndOrderFront(nil)
        Log.write("native-switch-states count=4 enabled=2 disabled=2 control=NSButton role=checkbox fixture-only=true")
    }
    func inspectShortcutRecording() { show(page: 2); shortcutRecord?.performClick(nil) }
    func inspectShortcutCancellation() { shortcutCancel?.performClick(nil) }
    func inspectShortcutSaveFailure() {
        show(page: 2); beginShortcut()
        // Candidate injection isolates the real save/permission rollback, not physical recording.
        candidate = HotkeySpec(keyCode: 5, modifiers: UInt32(controlKey | shiftKey), modifierKeyCodes: [56,59])
        shortcutError = candidate.flatMap { ShortcutPolicy.reason($0) }; refresh()
        shortcutSave?.performClick(nil)
    }
    func inspectCloudSynchronization() -> Bool {
        guard let store = configStore, let cloud = cloud, let consent = consent else { return false }
        let original = store.config
        defer { _ = store.mutate { $0 = original }; store.save(); onConfigurationChanged?(); refresh() }
        cloud.performClick(nil)
        let appleSent = store.config.allowCloudRecognition != original.allowCloudRecognition
        let appleMatches = appleCloud?.state == cloud.state && store.config.allowCloudRecognition == (cloud.state == .on)
        consent.performClick(nil)
        let uploadSent = store.config.iflytekConsent != original.iflytekConsent
        let uploadMatches = engineConsent?.state == consent.state && store.config.iflytekConsent == (consent.state == .on)
        return appleSent && appleMatches && uploadSent && uploadMatches
    }
    func inspectSaveBinding(mode:Int,spec:HotkeySpec) {
        show(page:2);modeRecord[mode].performClick(nil)
        candidate=spec;shortcutError=ShortcutPolicy.reason(spec);refresh();modeSave[mode].performClick(nil)
    }
    func inspectEnableBinding(mode:Int) {modeEnable[mode].state = .on;NSApp.sendAction(modeEnable[mode].action!,to:modeEnable[mode].target,from:modeEnable[mode])}
    func bindingControlsMatchConfiguration()->Bool {
        guard let c=configStore?.config,modeCaps.count == 2 else{return false}
        return modeCaps[0].stringValue == HotkeySpecDisplay.string(c.trigger) && modeCaps[1].stringValue == (c.toggleTrigger.map(HotkeySpecDisplay.string) ?? L10n.tr("ui.2f5f1d6fbfb0")) && (modeEnable[0].state == .on) == c.holdShortcutEnabled && (modeEnable[1].state == .on) == c.toggleShortcutEnabled
    }
    func inspectOnboardingButton() { onShowOnboarding?() }

    func controlsMatchConfiguration() -> Bool {
        guard let c = configStore?.config else { return false }
        return engines.allSatisfy { $0.indexOfSelectedItem == (ASREngine.legacyListed.firstIndex(where:{$0.rawValue==c.engine}) ?? 0) }
            && engineTabs?.selectedSegment == (ASREngine.legacyListed.firstIndex(where:{$0.rawValue==c.engine}) ?? 0)
            && inputModeControl?.indexOfSelectedItem == (c.inputMode == "toggle" ? 1:0)
            && microphones.allSatisfy { ($0.selectedItem?.representedObject as? String ?? "") == c.microphoneUID }
    }

    func accessibilityChanged(){ if hostingInstalled { return }
        func redraw(_ v:NSView){v.needsDisplay=true;v.subviews.forEach(redraw)};if let v=window?.contentView{redraw(v)};refresh()}
    func inspectSize(_ minimum:Bool){window?.setContentSize(minimum ? NSSize(width:920,height:700):NSSize(width:1120,height:820));refresh();Log.write("native-resize "+layoutEvidence())}
    func layoutEvidence()->String {
        window?.contentView?.layoutSubtreeIfNeeded()
        return "window=\(window?.contentView?.bounds.size ?? .zero) pages="+pageScrolls.enumerated().map{ i,s in "\(i):visible=\(!s.isHidden),document=\(s.documentView?.frame.size ?? .zero),fit=\(pages[i].fittingSize),ambiguous=\(pages[i].hasAmbiguousLayout)"}.joined(separator:";")+" sheet=\(shortcutSheet != nil) candidate=\(candidate?.keyCode.description ?? "none") invalid=\(shortcutError != nil) saveEnabled=\(shortcutSave?.isEnabled ?? false) level=\(level?.doubleValue ?? -1)"
    }
    func pushLevel(_ value: Float) {
        settingsModel?.level = value
        level?.doubleValue = Double(value)
        emptyIllustration?.setRecording(pipeline?.session?.state == .voiceStarted)
        emptyIllustration?.pushLevel(value)
    }
    func inspectIllustrationLevel(_ value:Float){emptyIllustration?.pushLevel(value)}
    func inspectIllustration(_ stage:String) {
        guard let illustration=emptyIllustration else{return}
        illustration.setRecording(stage == "signal" || stage == "silence")
        if stage == "signal" {for i in 0..<11 {illustration.pushLevel(Float(i+1)/12)}}
        if stage == "silence" {for _ in 0..<60 {illustration.pushLevel(0)}}
        Log.write("try-illustration-inspect stage=\(stage) synthetic=true "+illustration.evidence)
    }

    private func text(_ value: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = .systemFont(ofSize: size, weight: weight)
        return label
    }
    private func stack(_ views: [NSView], horizontal: Bool = false) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = horizontal ? .horizontal : .vertical
        s.alignment = horizontal ? .centerY : .leading
        s.spacing = 12
        return s
    }
    private func primary(_ title: String, _ action: Selector) -> NSButton {
        let b = PrimaryButton(title: title, target: self, action: action); b.isBordered = false
        b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        return b
    }
    private func subtitle(_ value: String) -> NSTextField { let label = text(value,size:12); label.textColor = .secondaryLabelColor; return label }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }
    func enginePopup(width: CGFloat = 310) -> NSPopUpButton {
        let p = NSPopUpButton()
        p.addItems(withTitles: ASREngine.legacyListed.map{$0.title})
        p.autoenablesItems = false
        
        p.target = self; p.action = #selector(engineChanged(_:))
        engines.append(p); guardedControls.append(p)
        p.widthAnchor.constraint(equalToConstant: width).isActive = true
        return p
    }
    private func micPopup(width:CGFloat=310) -> NSPopUpButton {
        let p = NSPopUpButton()
        p.target = self; p.action = #selector(microphoneChanged(_:))
        microphones.append(p); guardedControls.append(p)
        p.widthAnchor.constraint(equalToConstant: width).isActive = true
        return p
    }
    func inspectAppearancePreferences(){
        guard let store=configStore,let popup=appearancePopup else{return};let original=store.config
        defer{_=store.mutate{$0=original};store.save();AppearanceController.apply(original.appearanceMode);refresh()}
        for (index,name) in ["system","light","dark"].enumerated(){popup.selectItem(at:index);if let action=popup.action{NSApp.sendAction(action,to:popup.target,from:popup)}
            let persisted=(try? Data(contentsOf:AppPaths.configFile)).flatMap{try? JSONDecoder().decode(BridgeConfig.self,from:$0)}?.appearanceMode == name
            let actual=name == "system" ? NSApp.appearance == nil:NSApp.appearance?.name == (name == "light" ? .aqua:.darkAqua)
            Log.write("native-appearance-choice mode=\(name) persisted=\(persisted) applied=\(actual) no-voice=\(pipeline?.hasActiveSession == false)")
        }
    }
    func build() {
        let w = NSWindow(contentRect: NSRect(x:0,y:0,width:980,height:740),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        w.title=Brand.name;w.isReleasedWhenClosed=false;w.delegate=self;w.contentMinSize=NSSize(width:920,height:700)
        let background=ThemeBackground();background.wantsLayer=true;w.contentView=background;window=w;w.center()
        let logo=NSImageView();logo.image=Bundle.main.url(forResource:"cadenza-logo",withExtension:"svg").flatMap(NSImage.init(contentsOf:));logo.widthAnchor.constraint(equalToConstant:40).isActive=true;logo.heightAnchor.constraint(equalToConstant:40).isActive=true
        let brandNames=stack([text(Brand.name,size:20,weight:.semibold),subtitle(Brand.tagline)]);brandNames.spacing=3
        let brand=stack([logo,brandNames],horizontal:true);brand.spacing=10;brand.translatesAutoresizingMaskIntoConstraints=false;background.addSubview(brand)
        NSLayoutConstraint.activate([brand.leadingAnchor.constraint(equalTo:background.leadingAnchor,constant:28),brand.topAnchor.constraint(equalTo:background.topAnchor,constant:20)])
        let host=NSView();host.translatesAutoresizingMaskIntoConstraints=false;background.addSubview(host)
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo:background.leadingAnchor,constant:28),host.trailingAnchor.constraint(equalTo:background.trailingAnchor,constant:-28),host.topAnchor.constraint(equalTo:background.topAnchor,constant:88),host.bottomAnchor.constraint(equalTo:background.bottomAnchor,constant:-98)])
        // 底部液态玻璃切换条：每项独立 NSGlassEffectView，外层 NSGlassEffectContainerView 就近合并；
        // 选中项 tintColor=玉绿（系统渲染选中底色），未选中为透明玻璃
        let tabBarStack=stack([]);tabBarStack.orientation = .horizontal;tabBarStack.spacing=2;tabBarStack.translatesAutoresizingMaskIntoConstraints=false
        var tabGlassItems:[NSView]=[]
        for (i,title) in [L10n.tr("ui.2087c777c06f"),L10n.tr("ui.8545bbfc5af9"),L10n.tr("ui.ee2638183d3e"),L10n.tr("ui.86651d17a401"),L10n.tr("ui.52d25a9e30ba")].enumerated(){
            let b=GlassTabButton(title:title,target:self,action:#selector(navigate(_:)));b.isBordered=false;b.tag=i;b.focusRingType = .none
            b.symbol=NSImage(systemSymbolName:["mic","cpu","keyboard","checkmark.shield","info.circle"][i],accessibilityDescription:title)
            b.translatesAutoresizingMaskIntoConstraints=false
            if #available(macOS 26.0, *) {
                let item=NSGlassEffectView();item.cornerRadius=23;item.translatesAutoresizingMaskIntoConstraints=false;item.contentView=b
                if let cv=item.contentView {
                    NSLayoutConstraint.activate([b.leadingAnchor.constraint(equalTo:cv.leadingAnchor),b.trailingAnchor.constraint(equalTo:cv.trailingAnchor),b.topAnchor.constraint(equalTo:cv.topAnchor),b.bottomAnchor.constraint(equalTo:cv.bottomAnchor)])
                }
                item.widthAnchor.constraint(equalToConstant:96).isActive=true
                item.heightAnchor.constraint(equalToConstant:46).isActive=true
                tabBarStack.addArrangedSubview(item);tabGlassItems.append(item)
            } else {
                b.widthAnchor.constraint(equalToConstant:96).isActive=true
                b.heightAnchor.constraint(equalToConstant:44).isActive=true
                tabBarStack.addArrangedSubview(b)
            }
            navigation.append(b)
        }
        let navBar:NSView
        if #available(macOS 26.0, *), !AppearanceController.highContrast {
            let container=NSGlassEffectContainerView();container.spacing=2;container.translatesAutoresizingMaskIntoConstraints=false;container.contentView=tabBarStack
            if let cv=container.contentView {
                NSLayoutConstraint.activate([tabBarStack.leadingAnchor.constraint(equalTo:cv.leadingAnchor),tabBarStack.trailingAnchor.constraint(equalTo:cv.trailingAnchor),tabBarStack.topAnchor.constraint(equalTo:cv.topAnchor),tabBarStack.bottomAnchor.constraint(equalTo:cv.bottomAnchor)])
            }
            navBar=container
        } else {
            navBar=card(tabBarStack,inset:8,vertical:5)
        }
        background.addSubview(navBar)
        NSLayoutConstraint.activate([navBar.centerXAnchor.constraint(equalTo:background.centerXAnchor),navBar.bottomAnchor.constraint(equalTo:background.bottomAnchor,constant:-20),navBar.heightAnchor.constraint(equalToConstant:46)])
        func addPage(_ views:[NSView]){
            let p=stack(views);p.spacing=14;p.translatesAutoresizingMaskIntoConstraints=false
            let doc=PageDocument(frame:NSRect(x:0,y:0,width:658,height:1));doc.addSubview(p);doc.autoresizingMask=[.width]
            NSLayoutConstraint.activate([p.leadingAnchor.constraint(equalTo:doc.leadingAnchor),p.topAnchor.constraint(equalTo:doc.topAnchor),p.widthAnchor.constraint(equalTo:doc.widthAnchor)])
            for v in views {v.widthAnchor.constraint(equalTo:p.widthAnchor).isActive=true}
            let s=NSScrollView();s.drawsBackground=false;s.hasVerticalScroller=true;s.autohidesScrollers=true;s.documentView=doc;s.translatesAutoresizingMaskIntoConstraints=false;host.addSubview(s)
            NSLayoutConstraint.activate([s.leadingAnchor.constraint(equalTo:host.leadingAnchor),s.trailingAnchor.constraint(equalTo:host.trailingAnchor),s.topAnchor.constraint(equalTo:host.topAnchor),s.bottomAnchor.constraint(equalTo:host.bottomAnchor),doc.widthAnchor.constraint(equalTo:s.contentView.widthAnchor)])
            pages.append(p);pageScrolls.append(s)
        }
        func heading(_ title:String,_ detail:String)->NSView {let s=stack([text(title,size:26,weight:.semibold),subtitle(detail)]);s.spacing=5;return s}
        func row(_ name:String,_ detail:String="",_ trailing:[NSView],height:CGFloat=54)->NSView {
            let names=stack(detail.isEmpty ? [text(name)]:[text(name),subtitle(detail)]);names.spacing=3;names.setContentHuggingPriority(.defaultLow,for:.horizontal)
            let r=NSView(),tail=stack(trailing,horizontal:true);tail.spacing=10
            names.translatesAutoresizingMaskIntoConstraints=false;tail.translatesAutoresizingMaskIntoConstraints=false;r.addSubview(names);r.addSubview(tail)
            NSLayoutConstraint.activate([r.heightAnchor.constraint(equalToConstant:height),names.leadingAnchor.constraint(equalTo:r.leadingAnchor),names.centerYAnchor.constraint(equalTo:r.centerYAnchor),names.trailingAnchor.constraint(lessThanOrEqualTo:tail.leadingAnchor,constant:-12),tail.trailingAnchor.constraint(equalTo:r.trailingAnchor),tail.centerYAnchor.constraint(equalTo:r.centerYAnchor)])
            return r
        }
        func group(_ rows:[NSView])->NSView {
            let content=stack([]);content.spacing=0
            for (i,r) in rows.enumerated(){content.addArrangedSubview(r);r.widthAnchor.constraint(equalTo:content.widthAnchor).isActive=true;if i < rows.count-1 {let line=NSBox();line.boxType = .separator;content.addArrangedSubview(line);line.widthAnchor.constraint(equalTo:content.widthAnchor).isActive=true}}
            return card(content,inset:14,vertical:0)
        }
        let viewport=NSView();viewport.heightAnchor.constraint(equalToConstant:252).isActive=true
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.drawsBackground=false;scroll.translatesAutoresizingMaskIntoConstraints=false;viewport.addSubview(scroll);resultScroll=scroll
        let tv=NSTextView(frame:NSRect(x:0,y:0,width:660,height:252));tv.isEditable=false;tv.font = .systemFont(ofSize:16);tv.drawsBackground=false;tv.textContainerInset=NSSize(width:10,height:12);tv.isHorizontallyResizable=false;tv.autoresizingMask = [.width];tv.textContainer?.widthTracksTextView=true;scroll.documentView=tv;result=tv
        let illustration=TechnicalEmptyStateView(frame:.zero);emptyIllustration=illustration;illustration.heightAnchor.constraint(equalToConstant:190).isActive=true
        let empty=stack([illustration,text(L10n.tr("ui.316989eb1907"),size:17,weight:.medium),subtitle(L10n.tr("ui.a449c770b225"))]);empty.alignment = .centerX;empty.spacing=8;empty.translatesAutoresizingMaskIntoConstraints=false;viewport.addSubview(empty);emptyState=empty
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo:viewport.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:viewport.trailingAnchor),scroll.topAnchor.constraint(equalTo:viewport.topAnchor),scroll.bottomAnchor.constraint(equalTo:viewport.bottomAnchor),empty.leadingAnchor.constraint(equalTo:viewport.leadingAnchor),empty.trailingAnchor.constraint(equalTo:viewport.trailingAnchor),empty.centerYAnchor.constraint(equalTo:viewport.centerYAnchor),illustration.widthAnchor.constraint(equalTo:empty.widthAnchor)])
        let copy=button(L10n.tr("ui.63d90d977348"),#selector(copyResult)),clear=button(L10n.tr("ui.1ef3de06b32e"),#selector(clearResult));copyButton=copy;clearButton=clear
        copy.imagePosition = .imageLeading;clear.imagePosition = .imageLeading
        copy.image=NSImage(systemSymbolName:"doc.on.doc",accessibilityDescription:nil);clear.image=NSImage(systemSymbolName:"trash",accessibilityDescription:nil)
        let resultHeader=row(L10n.tr("ui.2124b718a9a1"),"",[copy,clear],height:30)
        let hint=text("",size:12);message=hint
        let detail=button(L10n.tr("ui.8627c8bea4d7"),#selector(showResultReason));retentionDetail=detail
        let diagnostic=button(L10n.tr("ui.01b5ae843e00"),#selector(showWechatDiagnostic));diagnostic.identifier=NSUserInterfaceItemIdentifier("wechat.diagnostic.entry");wechatDiagnosticButton=diagnostic
        let callout=stack([hint,detail,diagnostic]);callout.spacing=4;retentionView=callout
        let record=HoldButton(title:L10n.tr("ui.1ac211466803"),target:nil,action:nil);record.isBordered=false;record.widthAnchor.constraint(equalToConstant:130).isActive=true;record.heightAnchor.constraint(equalToConstant:38).isActive=true;holdButton=record
        record.onPressStart={[weak self] in if self?.configStore?.config.inputMode != "toggle" {self?.pipeline?.holdStarted(source:.button)}}
        record.onPressEnd={[weak self] in if self?.configStore?.config.inputMode == "toggle" {self?.pipeline?.togglePressed(localOnly:true)} else {self?.pipeline?.holdEnded()}}
        let mode=NSPopUpButton();mode.addItems(withTitles:[L10n.tr("ui.e4947a64758a"),L10n.tr("ui.c2fd4bff347b")]);mode.target=self;mode.action=#selector(inputModeChanged(_:));inputModeControl=mode;guardedControls.append(mode);mode.widthAnchor.constraint(equalToConstant:110).isActive=true
        let mic=micPopup(width:215)
        let cancel=button(L10n.tr("ui.2cd0f3be8738"),#selector(SettingsWindowController.cancel));cancel.keyEquivalent="\u{1b}";cancelButton=cancel
        let flex=NSView();flex.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let trial=stack([mic,mode,flex,record,cancel],horizontal:true);trial.spacing=10;trial.heightAnchor.constraint(equalToConstant:48).isActive=true
        let line=NSBox();line.boxType = .separator
        let resultStack=stack([resultHeader,viewport,line,trial]);resultStack.spacing=10
        for v in resultStack.arrangedSubviews {v.widthAnchor.constraint(equalTo:resultStack.widthAnchor).isActive=true}
        let holdCap=text("",size:12,weight:.medium),toggleCap=text("",size:12,weight:.medium);holdSummary=holdCap;toggleSummary=toggleCap
        let configRows=group([row(L10n.tr("ui.8545bbfc5af9"),"",[enginePopup(width:250)],height:48),row(L10n.tr("ui.e4947a64758a"),"",[holdCap,button(L10n.tr("ui.37090f456516"),#selector(showShortcutPage))],height:48),row(L10n.tr("ui.f4dfe64726ba"),"",[toggleCap,button(L10n.tr("ui.df3d58c7d84b"),#selector(showShortcutPage))],height:48)])
        let keys=text("",size:11);keyHint=keys
        addPage([heading(L10n.tr("ui.2fdc91e671fd"),L10n.tr("ui.e715637a4f3a")),card(resultStack),callout,configRows,keys,button(L10n.tr("ui.1be2eaee0d68"),#selector(showPrivacy))])
        let tabs=BrandSegmentedControl(labels:ASREngine.legacyListed.map{$0.title},trackingMode:.selectOne,target:self,action:#selector(engineTabChanged(_:)));tabs.segmentDistribution = .fillEqually;tabs.heightAnchor.constraint(equalToConstant:30).isActive=true;engineTabs=tabs;guardedControls.append(tabs)
        tabs.isHidden=true // 引擎选择改由左侧列表承载；原页签保留用于状态同步与检查
        let category=BrandSegmentedControl(labels:[L10n.tr("ui.f020ba25edd4"),L10n.tr("ui.44ac539067ed")],trackingMode:.selectOne,target:self,action:#selector(engineCategoryChanged(_:)));category.segmentDistribution = .fillEqually;category.heightAnchor.constraint(equalToConstant:30).isActive=true;category.selectedSegment=0;engineCategory=category;guardedControls.append(category);category.identifier=NSUserInterfaceItemIdentifier("asr.category")
        let listStack=NSStackView();listStack.orientation = .vertical;listStack.alignment = .leading;listStack.spacing=0
        var listButtons:[NSButton]=[];var listRows:[NSView]=[];var listStatus:[NSTextField]=[]
        for (index,engine) in ASREngine.legacyListed.enumerated() {
            let rowView=NSView();rowView.translatesAutoresizingMaskIntoConstraints=false;rowView.wantsLayer=true;rowView.layer?.cornerRadius=6
            let b=NSButton(title:engine.title,target:self,action:#selector(engineListSelected(_:)))
            b.isBordered=false;b.tag=index;b.focusRingType = .none
            b.font = .systemFont(ofSize:13,weight:.medium);b.alignment = .left
            b.identifier=NSUserInterfaceItemIdentifier("asr.engine.list."+engine.rawValue)
            let status=NSTextField(labelWithString:"");status.font = .systemFont(ofSize:10);status.textColor = .tertiaryLabelColor
            status.identifier=NSUserInterfaceItemIdentifier("asr.engine.status."+engine.rawValue)
            b.translatesAutoresizingMaskIntoConstraints=false;status.translatesAutoresizingMaskIntoConstraints=false
            rowView.addSubview(b);rowView.addSubview(status)
            NSLayoutConstraint.activate([
                rowView.heightAnchor.constraint(equalToConstant:36),
                b.leadingAnchor.constraint(equalTo:rowView.leadingAnchor,constant:4),b.centerYAnchor.constraint(equalTo:rowView.centerYAnchor),
                status.trailingAnchor.constraint(equalTo:rowView.trailingAnchor,constant:-4),status.centerYAnchor.constraint(equalTo:rowView.centerYAnchor),
                b.trailingAnchor.constraint(lessThanOrEqualTo:status.leadingAnchor,constant:-4),
            ])
            listStack.addArrangedSubview(rowView)
            listButtons.append(b);listRows.append(rowView);listStatus.append(status)
        }
        let addProvider=NSButton(title:L10n.tr("ui.33a6b1449400"),target:nil,action:nil)
        addProvider.isBordered=false;addProvider.isEnabled=false;addProvider.font = .systemFont(ofSize:11);addProvider.identifier=NSUserInterfaceItemIdentifier("asr.provider.add")
        addProvider.translatesAutoresizingMaskIntoConstraints=false
        let addRow=NSView();addRow.translatesAutoresizingMaskIntoConstraints=false;addRow.addSubview(addProvider)
        NSLayoutConstraint.activate([addRow.heightAnchor.constraint(equalToConstant:30),addProvider.leadingAnchor.constraint(equalTo:addRow.leadingAnchor,constant:4),addProvider.centerYAnchor.constraint(equalTo:addRow.centerYAnchor)])
        listStack.addArrangedSubview(addRow)
        listStack.widthAnchor.constraint(equalToConstant:186).isActive=true
        let listCard=card(listStack,inset:10,vertical:8);listCard.identifier=NSUserInterfaceItemIdentifier("asr.engine.list")
        engineListButtons=listButtons;engineListCard=listCard;engineRowViews=listRows;engineStatusLabels=listStatus
        let lang=NSPopUpButton();lang.addItems(withTitles:[L10n.tr("ui.a55562525e1d"),"English",L10n.tr("ui.22bda8a8d973")]);lang.target=self;lang.action=#selector(languageChanged(_:));language=lang;guardedControls.append(lang)
        let service=text("",size:12);serviceState=service
        let apple=BrandCheckbox(checkboxWithTitle:L10n.tr("ui.e55df3a76ea6"),target:self,action:#selector(cloudChanged(_:)));appleCloud=apple;guardedControls.append(apple)
        let appleSettings=row("Apple Speech",L10n.tr("ui.d058f166a5bd"),[apple],height:50);appleRow=appleSettings
        let configure=button(L10n.tr("ui.877098676f99"),#selector(showASRSettings));configure.identifier=NSUserInterfaceItemIdentifier("asr.entry.configure");asrConfigureButton=configure
        let entryFeedback=subtitle("");entryFeedback.identifier=NSUserInterfaceItemIdentifier("asr.entry.feedback");asrEntryFeedback=entryFeedback
        let configFooter=row("","",[configure],height:46)
        let providerLang=text("",size:12);providerLanguage=providerLang;providerLang.identifier=NSUserInterfaceItemIdentifier("asr.entry.language")
        let base=group([row(L10n.tr("ui.b8f42764ae46"),"",[lang,providerLang]),row(L10n.tr("ui.cd9e6cca965a"),"",[service],height:50),appleSettings,configFooter])
        func credential(_ label:String)->NSSecureTextField {let f=NSSecureTextField();f.placeholderString=L10n.tr("ui.36ae26409394");f.widthAnchor.constraint(equalToConstant:360).isActive=true;guardedControls.append(f);return f}
        appID=credential("App ID");apiKey=credential("API Key");secret=credential("API Secret")
        let upload=BrandCheckbox(checkboxWithTitle:L10n.tr("ui.3c5663caa39f"),target:self,action:#selector(consentChanged(_:)));engineConsent=upload;guardedControls.append(upload)
        let save=button(L10n.tr("ui.34c545bc7c49"),#selector(saveCredentials));guardedControls.append(save)
        let feedback=text("",size:11);credentialFeedback=feedback
        let api=group([row("App ID","",[appID!],height:44),row("API Key","",[apiKey!],height:44),row("API Secret","",[secret!],height:44),row(L10n.tr("ui.9a5f23670e42"),L10n.tr("ui.06c7509b504a"),[upload],height:48),row(L10n.tr("ui.dcdbce82d68b"),"",[save],height:44)]);apiPanel=api
        let localState=text(L10n.tr("ui.c94acb3a655f"),size:12)
        let localInfo=NSTextField(wrappingLabelWithString:L10n.tr("ui.290824ac5690"));localInfo.font = .systemFont(ofSize:12);localInfo.textColor = .secondaryLabelColor
        let importModel=NSButton(title:L10n.tr("ui.1d2a35e438d7"),target:nil,action:nil);importModel.bezelStyle = .rounded;importModel.isEnabled=false;importModel.identifier=NSUserInterfaceItemIdentifier("asr.local.import")
        let downloadModel=NSButton(title:L10n.tr("ui.13ca07042aa2"),target:nil,action:nil);downloadModel.bezelStyle = .rounded;downloadModel.isEnabled=false;downloadModel.identifier=NSUserInterfaceItemIdentifier("asr.local.download")
        let localModels=group([row(L10n.tr("ui.44ac539067ed"),L10n.tr("ui.85147b7cf388"),[localState],height:62),localInfo,stack([importModel,downloadModel],horizontal:true)]);localModels.identifier=NSUserInterfaceItemIdentifier("asr.local.section")
        let engineDetail=stack([base,entryFeedback,api,feedback]);engineDetail.spacing=10
        cloudDetailViews=[base,api,feedback,configure,entryFeedback]
        base.widthAnchor.constraint(equalTo:engineDetail.widthAnchor).isActive=true
        api.widthAnchor.constraint(equalTo:engineDetail.widthAnchor).isActive=true
        let contentHost=stack([listCard,engineDetail],horizontal:true);contentHost.alignment = .top;contentHost.spacing=12
        listCard.heightAnchor.constraint(equalTo:contentHost.heightAnchor).isActive=true
        engineDetail.heightAnchor.constraint(equalTo:contentHost.heightAnchor).isActive=true
        contentHost.heightAnchor.constraint(greaterThanOrEqualToConstant:460).isActive=true
        engineDetail.distribution = .fill
        base.setContentHuggingPriority(.defaultLow, for: .vertical) // 详情首卡吸收剩余高度，页面不留大片空白
        localSectionView=localModels
        addPage([heading(L10n.tr("ui.8545bbfc5af9"),L10n.tr("ui.e5afb74738ee")),category,contentHost,subtitle(L10n.tr("ui.40af62979628")),localModels])
        category.widthAnchor.constraint(equalTo:contentHost.widthAnchor).isActive=true
        var bindings:[NSView]=[]
        for i in 0..<2 {
            let cap=text("",size:12,weight:.medium);modeCaps.append(cap)
            let feedback=text("",size:11);modeFeedback.append(feedback)
            let enabled=BrandCheckbox(checkboxWithTitle:L10n.tr("ui.f4f0ead1116b"),target:self,action:#selector(shortcutEnabled(_:)));enabled.tag=i;modeEnable.append(enabled)
            let change=button(L10n.tr("ui.6b01fce4dbea"),i == 0 ? #selector(beginHoldShortcut):#selector(beginToggleShortcut));modeRecord.append(change)
            // Sheet-only buttons keep transaction inspection on the same native actions.
            let save=button(L10n.tr("ui.a3030bf8f16d"),#selector(saveShortcut)),cancel=button(L10n.tr("ui.2cd0f3be8738"),#selector(cancelShortcut));modeSave.append(save);modeCancel.append(cancel)
            if i == 0 {shortcutRecord=change;shortcutSave=save;shortcutCancel=cancel}
            bindings.append(row(i == 0 ? L10n.tr("ui.e4947a64758a"):L10n.tr("ui.f4dfe64726ba"),i == 0 ? L10n.tr("ui.fa3894134288"):L10n.tr("ui.53ed8a97e3d6"),[cap,change,enabled],height:62))
        }
        // The translation shortcut is edited in the same sheet but has no row on this old page.
        let translateSave=button(L10n.tr("ui.a3030bf8f16d"),#selector(saveShortcut)),translateCancel=button(L10n.tr("ui.2cd0f3be8738"),#selector(cancelShortcut));modeSave.append(translateSave);modeCancel.append(translateCancel)
        let listener=text("",size:12);shortcutState=listener
        addPage([heading(L10n.tr("ui.ee2638183d3e"),L10n.tr("ui.54b45a728b00")),group(bindings),group([row(L10n.tr("ui.0649096192cc"),"",[button(L10n.tr("ui.bb6d995724f4"),#selector(openListen))]),listener]),button(L10n.tr("ui.9a22a6fb40f1"),#selector(showShortcutProtection))])
        let permissionHint=text("",size:11);permissionState=permissionHint
        func permission(_ title:String,_ help:String,_ action:Selector)->NSView {
            let state=text("",size:12);state.widthAnchor.constraint(equalToConstant:65).isActive=true;permissionValues.append(state)
            let b=button(L10n.tr("ui.bb6d995724f4"),action);b.widthAnchor.constraint(equalToConstant:88).isActive=true;permissionActions.append(b);return row(title,help,[state,b],height:57)
        }
        let cloudSwitch=BrandSwitch(title:L10n.tr("ui.a61628bf03de"),target:self,action:#selector(cloudSwitchChanged(_:)));cloudSwitch.setButtonType(.switch);cloudSwitch.isBordered=false;cloudSwitch.widthAnchor.constraint(equalToConstant:44).isActive=true;cloudSwitch.heightAnchor.constraint(equalToConstant:26).isActive=true;cloud=cloudSwitch;guardedControls.append(cloudSwitch)
        let consentSwitch=BrandSwitch(title:L10n.tr("ui.dff74b3a6939"),target:self,action:#selector(consentSwitchChanged(_:)));consentSwitch.setButtonType(.switch);consentSwitch.isBordered=false;consentSwitch.widthAnchor.constraint(equalToConstant:44).isActive=true;consentSwitch.heightAnchor.constraint(equalToConstant:26).isActive=true;consent=consentSwitch;guardedControls.append(consentSwitch)
        addPage([heading(L10n.tr("ui.9852782472a4"),L10n.tr("ui.dcfd87525713")),group([permission(L10n.tr("ui.714cac30e2ff"),L10n.tr("ui.e0d4c05278a5"),#selector(micPermissionAction)),permission(L10n.tr("ui.654a661d7492"),L10n.tr("ui.8dafd7521162"),#selector(speechPermissionAction)),permission(L10n.tr("ui.b8f88aeead15"),L10n.tr("ui.c715b6030690"),#selector(openAX)),permission(L10n.tr("ui.fc22bc8bea45"),L10n.tr("ui.1c8fbab1400c"),#selector(openListen))]),permissionHint,group([row(L10n.tr("ui.a61628bf03de"),L10n.tr("ui.7fc99418efe6"),[cloudSwitch],height:54),row(L10n.tr("ui.9a5f23670e42"),L10n.tr("ui.75064f2341b2"),[consentSwitch],height:54)]),button(L10n.tr("ui.dd52ab814fc2"),#selector(showPrivacy))])
        let aboutLogo=NSImageView();aboutLogo.image=logo.image;aboutLogo.widthAnchor.constraint(equalToConstant:70).isActive=true;aboutLogo.heightAnchor.constraint(equalToConstant:70).isActive=true
        let intro=stack([aboutLogo,text(Brand.name,size:22,weight:.semibold),subtitle(Brand.name+" · "+(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? L10n.tr("ui.0d1c116274f9"))),text(Brand.tagline,size:14)]);intro.alignment = .centerX;intro.spacing=10
        let appearance=NSPopUpButton();appearance.addItems(withTitles:[L10n.tr("ui.217cfe7db1e3"),L10n.tr("ui.aa0819dfc4d8"),L10n.tr("ui.a6b75d068032")]);appearance.target=self;appearance.action=#selector(appearanceChanged(_:));appearancePopup=appearance;guardedControls.append(appearance)
        let links=group([row(L10n.tr("ui.86a63f23a076"),"",[appearance],height:48),row(L10n.tr("ui.df01e14ded47"),"",[button(L10n.tr("ui.c771248e511f"),#selector(showHelp))],height:44),row(L10n.tr("ui.9d06d61ee41f"),"",[button(L10n.tr("ui.db8db0530432"),#selector(showPrivacy))],height:44),row(L10n.tr("ui.31882138222f"),"",[button(L10n.tr("ui.c771248e511f"),#selector(showFeedback))],height:44),row(L10n.tr("ui.a6360eb15f7f"),"",[button(L10n.tr("ui.9f24062367f0"),#selector(reopenOnboarding))],height:44)])
        addPage([intro,links])
        activationObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main){[weak self] _ in guard let self=self,self.isVisible else{return};if self.shortcutRecording,NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {self.cancelShortcut()};self.refresh()}
    }
    private func card(_ content:NSView,inset:CGFloat=14,vertical:CGFloat=12)->NSView {
        let box=CardView();box.wantsLayer=true;content.translatesAutoresizingMaskIntoConstraints=false
        let enableCardGlass=false // TODO: 玻璃 contentView 与固定宽度文档链冲突，需专门一轮布局适配
        if enableCardGlass, #available(macOS 26.0, *), !AppearanceController.highContrast {
            box.usesGlass=true // 液态玻璃材质（macOS 26+）；高对比与旧系统回退纯色卡片
            let glass=NSGlassEffectView();glass.cornerRadius=10;glass.tintColor=DesignTokens.groupBackground
            glass.translatesAutoresizingMaskIntoConstraints=false
            box.addSubview(glass);glass.contentView=content
            let glassHost=glass.contentView!
            NSLayoutConstraint.activate([glass.leadingAnchor.constraint(equalTo:box.leadingAnchor),glass.trailingAnchor.constraint(equalTo:box.trailingAnchor),glass.topAnchor.constraint(equalTo:box.topAnchor),glass.bottomAnchor.constraint(equalTo:box.bottomAnchor),glassHost.leadingAnchor.constraint(equalTo:glass.leadingAnchor),glassHost.trailingAnchor.constraint(equalTo:glass.trailingAnchor),glassHost.topAnchor.constraint(equalTo:glass.topAnchor),glassHost.bottomAnchor.constraint(equalTo:glass.bottomAnchor),content.leadingAnchor.constraint(equalTo:glassHost.leadingAnchor,constant:inset),content.trailingAnchor.constraint(equalTo:glassHost.trailingAnchor,constant:-inset),content.topAnchor.constraint(equalTo:glassHost.topAnchor,constant:vertical),content.bottomAnchor.constraint(equalTo:glassHost.bottomAnchor,constant:-vertical)])
            return box
        }
        box.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo:box.leadingAnchor,constant:inset),content.trailingAnchor.constraint(equalTo:box.trailingAnchor,constant:-inset),content.topAnchor.constraint(equalTo:box.topAnchor,constant:vertical),content.bottomAnchor.constraint(equalTo:box.bottomAnchor,constant:-vertical)])
        return box
    }
    func showRetainedResultReason(){showResultReason()}
    @objc private func showResultReason(){
        guard let window=window else{return}
        let alert=NSAlert();alert.messageText=L10n.tr("ui.21ba8d4eda94");alert.informativeText=pipeline?.lastResult ?? L10n.tr("ui.dc568bcb3a17")
        alert.addButton(withTitle:L10n.tr("ui.3fd47edce45b"))
        if pipeline?.diagnosticTarget != nil {alert.addButton(withTitle:L10n.tr("ui.01b5ae843e00"))}
        alert.beginSheetModal(for:window){[weak self] response in if response == .alertSecondButtonReturn{self?.onWechatDiagnostic?()}}
    }
    @objc private func showWechatDiagnostic(){onWechatDiagnostic?()}
    @objc private func showShortcutProtection(){showInformation(L10n.tr("ui.34faa2067632"),L10n.tr("ui.c692ca69d9f4"))}
    private func selectPage(_ page: Int) {
        for (i,p) in pageScrolls.enumerated() {
            let entering=i == page && p.isHidden;p.isHidden=i != page
            if entering {p.wantsLayer=true;p.layer?.removeAllAnimations();let fade=CABasicAnimation(keyPath:"opacity");fade.fromValue=0;fade.toValue=1;fade.duration=0.15;if !AppearanceController.reduceMotion {p.layer?.add(fade,forKey:"page-fade")}}
        }
        let accent = window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(srgbRed: 0.55, green: 0.83, blue: 0.76, alpha: 1) : DesignTokens.jade
        for (i, b) in navigation.enumerated() { b.contentTintColor = i == page ? accent : .labelColor; b.state = i == page ? .on : .off; b.attributedTitle = NSAttributedString(string: b.title, attributes: [.foregroundColor: i == page ? accent : NSColor.labelColor, .font: NSFont.systemFont(ofSize: 14, weight: i == page ? .semibold : .regular)]); b.needsDisplay = true }
        if #available(macOS 26.0, *) {
            for (i, g) in tabGlassItems.enumerated() { (g as? NSGlassEffectView)?.tintColor = i == page ? DesignTokens.jade : nil }
        }
    }
    @objc private func navigate(_ sender: NSButton) { if sender.tag != 2 { cancelShortcut() }; selectPage(sender.tag);refresh() }
    private func change(_ update: (inout BridgeConfig) -> Void) {
        guard pipeline?.hasActiveSession != true else { return }
        guard let store = configStore else { return }; let original = store.config
        if !store.mutate(update) || !store.save() {
            _ = store.mutate { $0 = original }; pipeline?.note(L10n.tr("ui.f96db3eea433"))
        }
        onConfigurationChanged?(); refresh()
    }
    @objc private func appearanceChanged(_ sender:NSPopUpButton){change{$0.appearanceMode=["system","light","dark"][sender.indexOfSelectedItem]};AppearanceController.apply(configStore?.config.appearanceMode ?? "system");window?.contentView?.needsDisplay=true}
    @objc private func showShortcutPage() { selectPage(2) }
    @objc private func engineTabChanged(_ sender: NSSegmentedControl) { change { $0.engine = ASREngine.legacyListed[sender.selectedSegment].rawValue } }
    @objc private func engineListSelected(_ sender: NSButton) {
        guard ASREngine.legacyListed.indices.contains(sender.tag) else { return }
        change { $0.engine = ASREngine.legacyListed[sender.tag].rawValue }
    }
    @objc private func engineCategoryChanged(_ sender: NSSegmentedControl) {
        let cloud = sender.selectedSegment == 0
        cloudDetailViews.forEach { $0.isHidden = !cloud }
        engineListCard?.isHidden = !cloud
        localSectionView?.isHidden = !cloud
        Log.write("engine-category=\(cloud ? "cloud" : "local")")
    }
    @objc private func engineChanged(_ sender: NSPopUpButton) { change { $0.engine = ASREngine.legacyListed[sender.indexOfSelectedItem].rawValue } }
    @objc private func microphoneChanged(_ sender: NSPopUpButton) { change { $0.microphoneUID = sender.selectedItem?.representedObject as? String ?? "" } }
    @objc private func languageChanged(_ sender: NSPopUpButton) {
        change { c in c.iflytekLanguage = ["zh_cn", "en_us", "auto"][sender.indexOfSelectedItem]; if sender.indexOfSelectedItem < 2 { c.recognitionLocale = sender.indexOfSelectedItem == 0 ? "zh-CN" : "en-US" } }
    }
    @objc private func cloudSwitchChanged(_ sender: NSButton) { change { $0.allowCloudRecognition = sender.state == .on } }
    @objc private func consentSwitchChanged(_ sender: NSButton) { change { $0.iflytekConsent = sender.state == .on } }
    @objc private func micPermissionAction() {
        if TCC.micStatus() == .notDetermined { TCC.requestMic { [weak self] _ in DispatchQueue.main.async { self?.refresh() } } } else { openMic() }
    }
    @objc private func speechPermissionAction() {
        if TCC.speechStatus() == .notDetermined { TCC.requestSpeech { [weak self] _ in DispatchQueue.main.async { self?.refresh() } } } else { openSpeech() }
    }
    @objc private func consentChanged(_ sender: NSButton) { change { $0.iflytekConsent = sender.state == .on } }
    @objc private func cloudChanged(_ sender: NSButton) { change { $0.allowCloudRecognition = sender.state == .on } }
    @objc private func inputModeChanged(_ sender:NSPopUpButton) { change {$0.inputMode=sender.indexOfSelectedItem == 1 ? "toggle":"hold"} }
    @objc private func shortcutEnabled(_ sender:NSButton) {
        guard let c=configStore?.config,pipeline?.hasActiveSession != true else{return}
        editingMode=sender.tag
        shortcutError=onSaveModeShortcut?(editingMode == 1 ? "toggle":"hold",editingMode == 1 ? c.toggleTrigger:c.trigger,sender.state == .on)
        refresh()
    }
    @objc private func resetShortcut(_ sender:NSButton) {
        guard pipeline?.hasActiveSession != true else{return};editingMode=sender.tag;endShortcut(resume:false)
        shortcutError=onSaveModeShortcut?(modeName(editingMode),editingMode == 0 ? BridgeConfig.default().trigger:nil,editingMode == 0 ? nil:false)
        onEndShortcutRecording?();refresh()
    }
    /// The reason a combination cannot be used, with a few combinations that can, so a refusal always has a way forward.
    private func candidateReason(_ spec:HotkeySpec)->String? {
        guard let reason=candidateReasonOnly(spec) else{return nil}
        let c=ShortcutPolicy.suggestions(limit:3){self.candidateReasonOnly($0) == nil}
        return c.isEmpty ? reason:reason+"\n"+L10n.format("shortcut.try",c.map{HotkeySpecDisplay.string($0)}.joined(separator:"   "))
    }
    private func candidateReasonOnly(_ spec:HotkeySpec)->String? {
        if let reason=ShortcutPolicy.reason(spec){return reason}
        guard let c=configStore?.config else{return L10n.tr("ui.6534bf83b03f")}
        var peers:[HotkeySpec]=[]
        // A shortcut that is switched off cannot clash with anything.
        if editingMode != 0,c.holdShortcutEnabled {peers.append(c.trigger)}
        if editingMode != 1,c.toggleActive,let toggle=c.toggleTrigger {peers.append(toggle)}
        if editingMode != 2,let translate=c.translate.trigger {peers.append(translate)}
        if peers.contains(where:{$0.keyCode == spec.keyCode && $0.modifiers == spec.modifiers}) {return L10n.tr("ui.2e02adb592a9")}
        if editingMode == 2,peers.contains(where:{ShortcutPolicy.overlaps(spec,$0)}) {return L10n.tr("translate.shortcut.conflict")}
        if editingMode != 2,let translate=c.translate.trigger,ShortcutPolicy.overlaps(spec,translate) {return L10n.tr("translate.shortcut.conflict")}
        return nil
    }
    private func showShortcutSheet() {
        guard let parent=window else{return}
        let sheet=NSWindow(contentRect:NSRect(x:0,y:0,width:510,height:244),styleMask:[.titled],backing:.buffered,defer:false)
        sheet.delegate=self;sheet.title=editingMode == 0 ? L10n.tr("ui.3308d08e80c2"):editingMode == 2 ? L10n.tr("translate.shortcut"):L10n.tr("ui.87dc7fbdde52");sheet.appearance=parent.appearance
        let cap=text(L10n.tr("ui.32c3cad8e171"),size:20,weight:.semibold);cap.alignment = .center;sheetCap=cap
        let feedback=text(L10n.tr("ui.3c07efc857f1"),size:13);sheetFeedback=feedback
        let reset=button(L10n.tr("ui.ba2e93e73037"),#selector(resetShortcut(_:)));reset.tag=editingMode
        let buttons=stack([reset,modeCancel[editingMode],modeSave[editingMode]],horizontal:true)
        let body=stack([text(sheet.title,size:18,weight:.semibold),cap,feedback,buttons]);body.spacing=20;body.translatesAutoresizingMaskIntoConstraints=false;sheet.contentView?.addSubview(body)
        if let v=sheet.contentView {NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo:v.leadingAnchor,constant:24),body.trailingAnchor.constraint(equalTo:v.trailingAnchor,constant:-24),body.topAnchor.constraint(equalTo:v.topAnchor,constant:24)]);cap.widthAnchor.constraint(equalTo:body.widthAnchor).isActive=true;cap.heightAnchor.constraint(equalToConstant:46).isActive=true}
        shortcutSheet=sheet;parent.beginSheet(sheet);shortcutSave=modeSave[editingMode];shortcutCancel=modeCancel[editingMode]
    }
    func inspectActiveShortcutCandidate(_ spec:HotkeySpec) {
        guard shortcutRecording else{return}
        if let monitor=shortcutMonitor {NSEvent.removeMonitor(monitor);shortcutMonitor=nil}
        candidate=spec;shortcutError=candidateReason(spec);refresh()
    }
    var shortcutEditorCanSave:Bool {shortcutSave?.isEnabled == true && shortcutSheet != nil}
    var shortcutEditorText:String {sheetCap?.stringValue ?? ""}
    var shortcutEditorHasError:Bool {shortcutError != nil}
    func inspectSaveActiveShortcut(){shortcutSave?.performClick(nil)}
    func editShortcut(mode:String) {
        guard ["hold","toggle","translate"].contains(mode),pipeline?.hasActiveSession != true,window?.attachedSheet == nil else{return}
        editingMode=mode == "translate" ? 2:mode == "toggle" ? 1:0;beginShortcut()
    }
    private func modeName(_ index:Int)->String {index == 2 ? "translate":index == 1 ? "toggle":"hold"}
    @objc private func beginHoldShortcut(){editingMode=0;beginShortcut()}
    @objc private func beginToggleShortcut(){editingMode=1;beginShortcut()}
    @objc private func beginShortcut() {
        guard pipeline?.hasActiveSession != true, !shortcutRecording else { return }
        candidate = nil; shortcutError = nil; shortcutRecording = true; onBeginShortcutRecording?()
        showShortcutSheet()
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
            guard let self = self, self.shortcutRecording else { return e }
            if e.type == .keyDown && e.keyCode == 53 { self.cancelShortcut(); return nil }
            if e.type == .keyDown && !e.isARepeat || e.type == .flagsChanged && (ListenTrigger.modifierKeyFlags[UInt32(e.keyCode)] != nil || e.keyCode == 63) && CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(e.keyCode)) {
                let sides = ListenTrigger.downKeys().filter { ListenTrigger.modifierKeyFlags[$0] != nil }.sorted()
                let mods = ShortcutPolicy.carbon(e.modifierFlags)
                let alone = ListenTrigger.modifierKeyFlags[UInt32(e.keyCode)] == mods
                let spec = HotkeySpec(keyCode: UInt32(e.keyCode), modifiers: mods, modifierKeyCodes: alone ? nil : sides)
                self.candidate = spec
                self.shortcutError = self.candidateReason(spec)
                if CGEventSource.keyState(.combinedSessionState, key: 63) { self.shortcutError = L10n.tr("ui.823af38d5dff") }
                self.refresh()
            }
            return nil
        }
        shortcutSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.cancelShortcut() }
        refresh()
    }
    func inspectShortcutConflict() {
        show(page: 2); beginShortcut()
        // Native sheet + real policy validation; this candidate is programmatic,
        // and is never presented as physical keyboard or speech acceptance.
        if let monitor=shortcutMonitor {NSEvent.removeMonitor(monitor);shortcutMonitor=nil} // Freeze programmatic candidate; no physical-key claim.
        candidate=HotkeySpec(keyCode:49,modifiers:UInt32(cmdKey))
        shortcutError=candidate.flatMap{candidateReason($0)};refresh()
        Log.write("native-conflict-evidence "+layoutEvidence())
        DispatchQueue.main.asyncAfter(deadline:.now()+1.4){[weak self] in self?.refresh();Log.write("native-conflict-after-refresh "+(self?.layoutEvidence() ?? "closed"))}
    }
    private func endShortcut(resume: Bool = true) {
        let wasRecording = shortcutRecording
        shortcutRecording = false
        if let monitor = shortcutMonitor { NSEvent.removeMonitor(monitor) }; shortcutMonitor = nil
        if let observer = shortcutSleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; shortcutSleepObserver = nil
        candidate = nil
        if let sheet=shortcutSheet {window?.endSheet(sheet);sheet.orderOut(nil)};shortcutSheet=nil;sheetCap=nil;sheetFeedback=nil
        if resume && wasRecording { onEndShortcutRecording?() }
    }
    @objc private func cancelShortcut() { endShortcut(); shortcutError = nil; refresh() }
    @objc private func saveShortcut() {
        guard let spec = candidate, shortcutError == nil, pipeline?.hasActiveSession != true else { return }
        guard !ListenTrigger.downKeys().contains(spec.keyCode), ListenTrigger.downKeys().intersection(Set(spec.modifierKeyCodes ?? [])).isEmpty else { shortcutError = L10n.tr("ui.0817f92e1983"); refresh(); return }
        endShortcut(resume: false)
        shortcutError = onSaveModeShortcut?(modeName(editingMode),spec,nil) ?? (onSaveModeShortcut == nil ? onSaveShortcut?(spec):nil)
        onEndShortcutRecording?(); refresh()
        if let error=shortcutError {showInformation(L10n.tr("ui.76ef2625f5ea"),error)}
    }
    func windowDidResignKey(_ notification: Notification) { if shortcutRecording && (shortcutSheet == nil || notification.object as? NSWindow === shortcutSheet) { cancelShortcut() } }
    func windowDidBecomeKey(_ notification:Notification){refresh()}
    func windowDidResize(_ notification:Notification){refresh()}

    private(set) var asrSettings:ASRSettingsController?
    private(set) var asrEntryWasMouseTriggered=false
    func openASRSettings(_ engine:ASREngine) {
        showSwift(.engines)
        settingsModel?.configuring=engine
    }

    func inspectASRSettings(_ engine:ASREngine){guard let store=configStore else{return};show(page:1);asrSettings=ASRSettingsController(store:store,engine:engine,busy:{true},changed:{});asrSettings?.showWindow(nil);DispatchQueue.main.asyncAfter(deadline:.now()+0.5){[weak self] in self?.asrSettings?.renderEvidence(theme:CommandLine.arguments.contains("--inspect-dark") ? "dark":"light")};Log.write("asr-settings-preview provider=\(engine.rawValue) saved-config-unchanged=true no-network=true")}
    @objc private func showASRSettings(){
        guard let store=configStore,let engine=ASREngine(rawValue:store.config.engine),engine != .apple else{return}
        guard !asrBusy else{asrEntryFeedback?.stringValue=L10n.tr("ui.8bb0abbe4a88");return}
        asrEntryWasMouseTriggered=NSApp.currentEvent?.type == .leftMouseUp
        asrSettings?.close()
        asrSettings=ASRSettingsController(store:store,engine:engine,busy:{[weak self] in self?.asrBusy ?? true},changed:{[weak self] in self?.onConfigurationChanged?();self?.refresh()},credentialWriter:asrCredentialWriter)
        asrSettings?.showForEditing()
        Log.write("asr-entry-open provider=\(engine.rawValue) mouse-event=\(NSApp.currentEvent?.type == .leftMouseUp) visible=\(asrSettings?.window?.isVisible == true) key=\(asrSettings?.window?.isKeyWindow == true)")
    }
    private func refreshASREntry(_ config:BridgeConfig,busy:Bool){
        let engine=ASREngine(rawValue:config.engine) ?? .apple
        let genericLanguage=engine == .apple || engine == .iflytek
        language?.isHidden = !genericLanguage;providerLanguage?.isHidden=genericLanguage
        switch engine {
        case .deepgram:providerLanguage?.stringValue=config.options(.deepgram).language == "multi" ? L10n.tr("deepgram.multilingual") : (Locale(identifier:L10n.language).localizedString(forIdentifier:config.options(.deepgram).language) ?? config.options(.deepgram).language)
        case .openai,.groq,.compat,.google,.azure,.assemblyai,.elevenlabs:providerLanguage?.stringValue=config.options(engine).language == "multi" ? L10n.tr("batch.language.auto") : (Locale(identifier:L10n.language).localizedString(forIdentifier:config.options(engine).language) ?? config.options(engine).language)
        case .baidu:providerLanguage?.stringValue=L10n.tr("ui.7076f095aa51")
        case .tencent:providerLanguage?.stringValue=L10n.tr("ui.dbc948a3638d")
        case .aliyun:providerLanguage?.stringValue=L10n.tr("ui.38b2c8f51026")
        case .volcengine:providerLanguage?.stringValue=L10n.tr("ui.53fe95756463")
        default:providerLanguage?.stringValue=""
        }
        let names:[ASREngine:String]=[.iflytek:L10n.tr("ui.daf29ef7cb93"),.volcengine:L10n.tr("ui.746f101ac011"),.tencent:L10n.tr("ui.42ad801d45fd"),.aliyun:L10n.tr("ui.7c0e5b76f059"),.baidu:L10n.tr("ui.a33d5a21ef34"),.deepgram:ASREngine.deepgram.title,.openai:ASREngine.openai.title,.groq:ASREngine.groq.title,.compat:ASREngine.compat.title,.assemblyai:ASREngine.assemblyai.title,.elevenlabs:ASREngine.elevenlabs.title,.google:ASREngine.google.title,.azure:ASREngine.azure.title]
        asrConfigureButton?.title=L10n.tr("ui.148d195e21b0")+(names[engine] ?? L10n.tr("ui.45596e805ebd"))
        asrConfigureButton?.isHidden=engine == .apple;asrConfigureButton?.isEnabled = !busy && engine != .apple
        asrEntryFeedback?.isHidden=engine == .apple
        asrEntryFeedback?.stringValue=busy ? L10n.tr("ui.8bb0abbe4a88"):L10n.tr("ui.01c63d78b80f")
        engineTabs?.selectedSegment=ASREngine.legacyListed.firstIndex(of:engine) ?? 0
        apiPanel?.isHidden=engine != .iflytek;credentialFeedback?.isHidden=engine != .iflytek
        appleCloud?.isHidden=engine != .apple;appleRow?.isHidden=engine != .apple
    }
    @objc private func saveCredentials() {
        guard let a = appID?.stringValue, let k = apiKey?.stringValue, let s = secret?.stringValue, !a.isEmpty, !k.isEmpty, !s.isEmpty else { pipeline?.note(L10n.tr("ui.9b73b661d25c")); refresh(); return }
        let ok = KeychainStore.set(a, for: "iflytek.appid") && KeychainStore.set(k, for: "iflytek.apikey") && KeychainStore.set(s, for: "iflytek.apisecret")
        if ok { appID?.stringValue = ""; apiKey?.stringValue = ""; secret?.stringValue = "" }
        credentialFeedback?.stringValue = ok ? L10n.tr("ui.c63fea59e07d") : L10n.tr("ui.1221d1ad41a9")
        credentialFeedback?.textColor = ok ? .secondaryLabelColor : .systemRed
        onConfigurationChanged?()
        pipeline?.note(ok ? L10n.tr("ui.b9f5b73a31e4") : L10n.tr("ui.4c401c58e346")); refresh()
    }
    @objc private func cancel() { pipeline?.forceEnd(reason: L10n.tr("ui.d8ccc062b1d5")) }
    @objc private func copyResult() {
        guard let value = pipeline?.lastTranscript, !value.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
    }
    @objc private func clearResult() { pipeline?.clearTranscript(); refresh() }
    @objc private func requestPermissions() { onRequestPermissions?() }
    @objc private func reopenOnboarding() { onShowOnboarding?() }
    private func showInformation(_ title: String, _ body: String) { guard let window = window else { return }; let alert = NSAlert(); alert.messageText = title; alert.informativeText = body; alert.addButton(withTitle: L10n.tr("ui.3fd47edce45b")); alert.beginSheetModal(for: window) }
    @objc private func showHelp() { showInformation(L10n.tr("ui.df01e14ded47"), L10n.format("ui.4008cc226057", String(describing: Brand.name), String(describing: HotkeySpecDisplay.string(configStore?.config.trigger ?? BridgeConfig.default().trigger)))) }
    @objc private func showPrivacy() { showInformation(L10n.tr("ui.9d06d61ee41f"), L10n.tr("ui.d44d88981483")) }
    @objc private func showFeedback() {
        guard let window = window else { return }
        let info = L10n.format("ui.992c69be18d8", String(describing: Brand.name)) + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.tr("ui.0d1c116274f9")) + "\nmacOS " + ProcessInfo.processInfo.operatingSystemVersionString + L10n.tr("ui.46a469f64904") + (configStore?.config.engine ?? L10n.tr("ui.4d8c1c5b4283")) + L10n.tr("ui.0707e7e430f5") + (TCC.listenAllowed() ? L10n.tr("ui.521e65ffc7d0") : L10n.tr("ui.94bc3d40defe"))
        let alert = NSAlert(); alert.messageText = L10n.tr("ui.9397bd8233f0"); alert.informativeText = info + L10n.tr("ui.0ef87c15708a"); alert.addButton(withTitle: L10n.tr("ui.045e09f57e10")); alert.addButton(withTitle: L10n.tr("ui.2cd0f3be8738"))
        alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(info, forType: .string) } }
    }
    @objc private func openMic() { if TCC.micStatus() == .notDetermined { requestPermissions() } else { openPrivacy("Privacy_Microphone") } }
    @objc private func openSpeech() { if configStore?.config.engine == "apple" && TCC.speechStatus() == .notDetermined { requestPermissions() } else { openPrivacy("Privacy_SpeechRecognition") } }
    @objc private func openAX() { openPrivacy("Privacy_Accessibility") }
    @objc private func openListen() { openPrivacy("Privacy_ListenEvent") }
    private func openPrivacy(_ page: String) { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + page) { NSWorkspace.shared.open(url) } }
    func windowWillClose(_ notification: Notification) { cancelShortcut(); if pipeline?.session?.localOnly == true { pipeline?.forceEnd(reason: L10n.tr("ui.baea97f310f0")) } }
    private func layoutPages(){
        window?.contentView?.layoutSubtreeIfNeeded()
        for (index,scroll) in pageScrolls.enumerated(){if let doc=scroll.documentView{doc.setFrameSize(NSSize(width:scroll.contentSize.width,height:max(scroll.contentSize.height,pages[index].fittingSize.height)))}}
        if let page=pageScrolls.firstIndex(where:{!$0.isHidden}){selectPage(page)}
    }
    private func refreshShortcutControls(config:BridgeConfig,busy:Bool) {
        for i in 0..<modeCaps.count {
            let current:HotkeySpec?=i == 0 ? config.trigger:config.toggleTrigger
            modeCaps[i].stringValue=current.map(HotkeySpecDisplay.string) ?? L10n.tr("ui.2f5f1d6fbfb0")
            let own=editingMode == i
            modeFeedback[i].stringValue=own && shortcutError != nil ? shortcutError! : shortcutRecording && own ? (candidate == nil ? L10n.tr("ui.12a3d1685589"):L10n.tr("ui.d4e256affc6c")) : current == nil ? L10n.tr("ui.3e507c330920"):L10n.tr("ui.9315a5a6ae9c")
            modeFeedback[i].textColor=own && shortcutError != nil ? .systemRed:.secondaryLabelColor
            modeRecord[i].isEnabled = !busy && !shortcutRecording
            modeSave[i].isEnabled = !busy && shortcutRecording && own && candidate != nil && shortcutError == nil
            modeCancel[i].isEnabled=shortcutRecording && own
            modeEnable[i].state=(i == 0 ? config.holdShortcutEnabled:config.toggleShortcutEnabled) ? .on:.off
            modeEnable[i].isEnabled = !busy && !shortcutRecording && current != nil
        }
        if modeSave.count > 2 {
            modeSave[2].isEnabled = !busy && shortcutRecording && editingMode == 2 && candidate != nil && shortcutError == nil
            modeCancel[2].isEnabled = shortcutRecording && editingMode == 2
        }
        sheetCap?.stringValue=candidate.map(HotkeySpecDisplay.string) ?? L10n.tr("ui.32c3cad8e171")
        sheetFeedback?.stringValue=shortcutError ?? (candidate == nil ? L10n.tr("ui.3c07efc857f1"):L10n.tr("ui.d4e256affc6c"))
        sheetFeedback?.textColor=shortcutError == nil ? .secondaryLabelColor:.systemRed
    }
    func refresh() {
        if hostingInstalled {if let config=configStore?.config {refreshShortcutControls(config:config,busy:pipeline?.hasActiveSession == true)};settingsModel?.sync(); return }
        guard let config=configStore?.config else{return}
        refreshASREntry(config,busy:asrBusy)
        guard let pipeline=pipeline else{layoutPages();return}
        let busy = pipeline.hasActiveSession
        let holdName=HotkeySpecDisplay.string(config.trigger),toggleName=config.toggleTrigger.map(HotkeySpecDisplay.string) ?? L10n.tr("ui.2f5f1d6fbfb0")
        keyHint?.stringValue=L10n.tr("ui.16f89c29238b")+holdName+(config.holdShortcutEnabled ? "":L10n.tr("ui.34fe7ae0c287"))+L10n.tr("ui.cc7d58f74453")+toggleName+(config.toggleShortcutEnabled ? "":L10n.tr("ui.34fe7ae0c287"))
        inputModeControl?.selectItem(at:config.inputMode == "toggle" ? 1:0)
        holdButton?.title=config.inputMode == "toggle" ? (pipeline.session?.state == .voiceStarted ? L10n.tr("ui.7c28416dc186"):L10n.tr("ui.830bde5107c5")):L10n.tr("ui.1ac211466803")
        refreshShortcutControls(config:config,busy:busy)
        cancelButton?.isEnabled = busy
        guardedControls.forEach { $0.isEnabled = !busy }
        engineTabs?.selectedSegment = ASREngine.legacyListed.firstIndex(where:{$0.rawValue==config.engine}) ?? 0
        engineTabs?.needsDisplay = true
        let activeEngineIndex = ASREngine.legacyListed.firstIndex(where:{$0.rawValue==config.engine}) ?? 0
        for (i,b) in engineListButtons.enumerated() {
            let selected = i == activeEngineIndex
            if i < engineRowViews.count {
                let row = engineRowViews[i];row.wantsLayer = true;row.layer?.cornerRadius = 6
                row.layer?.backgroundColor = selected ? DesignTokens.jade.cgColor : NSColor.clear.cgColor
            }
            b.attributedTitle = NSAttributedString(string: ASREngine.legacyListed.indices.contains(b.tag) ? ASREngine.legacyListed[b.tag].title : b.title,
                attributes:[.font: NSFont.systemFont(ofSize:13,weight: selected ? .semibold : .regular),
                            .foregroundColor: selected ? NSColor.white : NSColor.labelColor])
            if i < engineStatusLabels.count {
                let s = engineStatusLabels[i]
                s.stringValue = i == 0 ? L10n.tr("ui.8f001d4b5b54") : (selected ? L10n.tr("ui.fa48e8938940") : L10n.tr("ui.80a57e03f071"))
                s.textColor = selected ? NSColor.white.withAlphaComponent(0.85) : NSColor.tertiaryLabelColor
            }
        }
        let cloudVisible = engineCategory?.selectedSegment != 1
        cloudDetailViews.forEach { $0.isHidden = !cloudVisible }
        engineListCard?.isHidden = !cloudVisible
        if let local = localSectionView { local.isHidden = cloudVisible }
        apiPanel?.isHidden = config.engine != "iflytek"
        appleCloud?.isHidden = config.engine != "apple"
        appleRow?.isHidden = config.engine != "apple"
        appleCloud?.state = config.allowCloudRecognition ? .on : .off
        engineConsent?.state = config.iflytekConsent ? .on : .off
        let hasResult = !(pipeline.lastTranscript ?? "").isEmpty
        copyButton?.isEnabled = hasResult; clearButton?.isEnabled = hasResult
        for p in engines { p.selectItem(at: ASREngine.legacyListed.firstIndex(where:{$0.rawValue==config.engine}) ?? 0) }
        let devices = Microphones.devices()
        for p in microphones {
            let titles = [L10n.tr("ui.04b77083689b")] + devices.map { $0.name }
            if p.itemTitles != titles {
                p.removeAllItems(); p.addItems(withTitles: titles); p.item(at: 0)?.representedObject = ""
                for (i, device) in devices.enumerated() { p.item(at: i + 1)?.representedObject = device.uid }
            }
            var index = devices.firstIndex { $0.uid == config.microphoneUID }.map { $0 + 1 } ?? 0
            if !config.microphoneUID.isEmpty, index == 0 {
                p.addItem(withTitle: L10n.tr("ui.cdf98ce0bcf2"))
                p.lastItem?.representedObject = config.microphoneUID
                p.lastItem?.isEnabled = false
                index = p.numberOfItems - 1
            }
            p.selectItem(at: index)
        }
        emptyIllustration?.setRecording(pipeline.session?.state == .voiceStarted)
        if pipeline.session?.state != .voiceStarted {pushLevel(0)}
        emptyIllustration?.updateImage()
        emptyState?.isHidden=hasResult;resultScroll?.isHidden = !hasResult
        appearancePopup?.selectItem(at:["system","light","dark"].firstIndex(of:config.appearanceMode) ?? 0)
        holdSummary?.stringValue=HotkeySpecDisplay.string(config.trigger)+(config.holdShortcutEnabled ? "":L10n.tr("ui.55c21d34de25"))
        toggleSummary?.stringValue=config.toggleTrigger.map(HotkeySpecDisplay.string) ?? L10n.tr("ui.2f5f1d6fbfb0")
        result?.textColor = .labelColor
        let output=pipeline.lastTranscript ?? ""
        if result?.string != output {result?.string=output}
        let status = pipeline.lastResult == "—" && pipeline.hasActiveSession ? pipeline.statusText : pipeline.lastResult
        let retained=pipeline.resultAction == .result && hasResult && !busy
        message?.stringValue = retained ? pipeline.lastResult: status == "—" ? "":status
        retentionView?.isHidden=status.isEmpty || status == "—"
        retentionDetail?.isHidden = !retained
        wechatDiagnosticButton?.isHidden=pipeline.diagnosticTarget == nil || !retained
        wechatDiagnosticButton?.isEnabled = !busy
        if let b=holdButton {b.attributedTitle=NSAttributedString(string:b.title,attributes:[.foregroundColor:NSColor.white,.font:NSFont.systemFont(ofSize:13,weight:.semibold)])}
        holdButton?.isEnabled = !shortcutRecording && (!busy || pipeline.session?.localOnly == true)
        consent?.state = config.iflytekConsent ? .on : .off; cloud?.state = config.allowCloudRecognition ? .on : .off
        language?.selectItem(at: config.engine == "iflytek" ? (config.iflytekLanguage == "en_us" ? 1 : config.iflytekLanguage == "auto" ? 2 : 0) : (config.recognitionLocale.hasPrefix("en") ? 1 : 0))
        language?.isEnabled = !busy && ["apple","iflytek"].contains(config.engine)
        language?.autoenablesItems = false
        language?.item(at: 2)?.isEnabled = config.engine == "iflytek"
        let onDevice = SFSpeechRecognizer(locale: Locale(identifier: config.recognitionLocale))?.supportsOnDeviceRecognition == true
        let selectedProvider=ASREngine(rawValue:config.engine) ?? .apple
        let configured=selectedProvider.configured
        serviceState?.stringValue = config.engine == "apple" ? L10n.format("ui.dfe5c06155e3", String(describing: onDevice ? L10n.tr("ui.f022f0fa4d2c") : L10n.tr("ui.36e0073276c0")), String(describing: config.allowCloudRecognition ? L10n.tr("ui.ce7ef28b670a") : L10n.tr("ui.3fd47edce45b"))) : L10n.format("ui.abf0e33fb40f", String(describing: configured ? L10n.tr("ui.00fda884d042") : L10n.tr("ui.ed2185cbc0b3")), String(describing: config.options(selectedProvider).consent ? L10n.tr("ui.5961a7938f91") : L10n.tr("ui.ee5b633708e3")))
        shortcutState?.stringValue = L10n.format("ui.c9a943964f80", String(describing: listenTrigger?.status ?? L10n.tr("ui.e6fc5eb8c3b8")), String(describing: listenTrigger?.lastMatchAt == nil ? L10n.tr("ui.d59ad39938f9") : L10n.tr("ui.fd5604fb98da")))
        layoutPages()
        let permissions = [HoldNativeEngine.micAuthorized(), HoldNativeEngine.speechAuthorized(), FocusProbe.accessibilityTrusted, PermissionProbe.monitorGranted]
        for (i, value) in permissionValues.enumerated() {
            value.stringValue = permissions[i] ? L10n.tr("ui.521e65ffc7d0") : L10n.tr("ui.94bc3d40defe")
            value.textColor = permissions[i] ? (window?.effectiveAppearance.bestMatch(from: [.aqua,.darkAqua]) == .darkAqua ? NSColor(srgbRed:161/255,green:215/255,blue:186/255,alpha:1) : DesignTokens.jade) : .systemOrange
            permissionActions[i].isEnabled = !busy
        }
        if permissionActions.count == 4 {
            permissionActions[0].title = TCC.micStatus() == .notDetermined ? L10n.tr("ui.436a02934223") : L10n.tr("ui.37aa6ad6a36d")
            permissionActions[1].title = TCC.speechStatus() == .notDetermined ? L10n.tr("ui.436a02934223") : L10n.tr("ui.37aa6ad6a36d")
        }
        permissionState?.stringValue = !permissions[3] ? L10n.tr("ui.83b50db4a9a1") : !permissions[2] ? L10n.tr("ui.68c4f35b477f") : L10n.tr("ui.51764548701e")

    }
}
