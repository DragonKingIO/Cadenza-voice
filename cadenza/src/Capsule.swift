import AppKit
import QuartzCore
import AVFoundation
import Speech
import Security

// MARK: - 设计令牌（随言 Suiyan 设计令牌）

enum DesignTokens {
    static let jade = NSColor(srgbRed: 0x18 / 255.0, green: 0x5C / 255.0, blue: 0x53 / 255.0, alpha: 1)          // 玉绿
    static let ink = NSColor(srgbRed: 0x20 / 255.0, green: 0x27 / 255.0, blue: 0x24 / 255.0, alpha: 1)           // 墨黑
    static let warmWhite = NSColor(srgbRed: 0xF5 / 255.0, green: 0xF1 / 255.0, blue: 0xE8 / 255.0, alpha: 1)     // 暖白
    static let deepJade = NSColor(srgbRed: 0x17 / 255.0, green: 0x2A / 255.0, blue: 0x25 / 255.0, alpha: 1)      // 深墨绿（胶囊底）
    static let capsuleText = NSColor(srgbRed: 0xF5 / 255.0, green: 0xF7 / 255.0, blue: 0xF6 / 255.0, alpha: 1)
    static let waveform = NSColor(srgbRed: 0x8B / 255.0, green: 0xE0 / 255.0, blue: 0xC1 / 255.0, alpha: 1)      // 浅绿波形
    static let cinnabar = NSColor(srgbRed: 0xD4 / 255.0, green: 0x5B / 255.0, blue: 0x50 / 255.0, alpha: 1)      // 朱红录音点
    static let amber = NSColor(srgbRed: 0xD8 / 255.0, green: 0xA2 / 255.0, blue: 0x4A / 255.0, alpha: 1)         // 琥珀警告
    static let capsuleSize = NSSize(width: 320, height: 56)
    static let accent=adaptive((161,215,186),jade)
    static let hudBackground=adaptive((32,36,35),.white)
    /// Tint for the glass bar. Dark mode keeps a dark tint; light mode only a light white one, so the glass stays see-through
    /// instead of turning into a grey or white slab.
    static let hudBackgroundDark=NSColor(srgbRed:32/255,green:36/255,blue:35/255,alpha:1)
    static let hudGlassTintDark=hudBackgroundDark
    static let hudGlassTintLight=NSColor.white.withAlphaComponent(0.45)
    static let hudGlassTint=adaptive((32,36,35),NSColor.white.withAlphaComponent(0.45))
    static let outline=NSColor(name:nil){appearance in
        let dark=appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua
        if AppearanceController.highContrast {return dark ? NSColor(srgbRed:0.55,green:0.60,blue:0.56,alpha:1):NSColor(srgbRed:0.40,green:0.44,blue:0.41,alpha:1)}
        return dark ? NSColor(srgbRed:57/255,green:66/255,blue:61/255,alpha:1):NSColor(srgbRed:0.86,green:0.85,blue:0.81,alpha:1)
    }
    // 兼容别名（设置窗口使用）
    static let primary = jade
    static let warning = amber
    static func adaptive(_ dark:(CGFloat,CGFloat,CGFloat),_ light:NSColor)->NSColor {
        NSColor(name:nil){appearance in
            return appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? NSColor(srgbRed:dark.0/255,green:dark.1/255,blue:dark.2/255,alpha:1):light
        }
    }
    static let sidebarBackground=adaptive((20,24,23),NSColor(srgbRed:0.95,green:0.94,blue:0.92,alpha:1))
    static let groupBackground=adaptive((33,38,35),NSColor(srgbRed:1,green:0.996,blue:0.986,alpha:1))
    static let settingsBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed:27/255,green:31/255,blue:29/255,alpha:1)
            : NSColor(srgbRed: 250/255, green: 248/255, blue: 243/255, alpha: 1)
    }
}

// MARK: - 钥匙串存储（凭据不入配置文件/日志）

enum KeychainStore {
    /// Saved credentials live under this Keychain service. Items saved before the rename are moved by `LegacyMigration`.
    static let service = "Cadenza"
    private(set) static var lastStatus: OSStatus = errSecSuccess

    /// Self-tests and previews never touch the real Keychain: a read of an item made by another build can stop on a system
    /// prompt that nobody sees, and a write would change the person's saved credentials. They get a private in-memory store.
    private static let memoryLock = NSLock()
    private static var memory: [String: String] = [:]

    /// The name macOS shows when it asks to open a saved credential. If the text cannot be found (a build or a process without
    /// the language files), the raw lookup key would end up in the item and in the system prompt; use a plain name instead.
    static var itemLabel: String {
        let text = L10n.format("ui.5b50196b3cb3", String(describing: Brand.name))
        return isRawKey(text) ? String(describing: Brand.name) + " · Credentials" : text
    }
    /// A lookup key shown as if it were text ("ui.5b50196b3cb3").
    static func isRawKey(_ s: String) -> Bool { s.range(of: "^ui\\.[0-9a-f]{6,16}$", options: .regularExpression) != nil }

    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        if TCC.isolated { memoryLock.lock(); memory[key] = value; memoryLock.unlock(); lastStatus = errSecSuccess; return true }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let update = SecItemUpdate(query as CFDictionary,
                                  [kSecValueData as String: Data(value.utf8), kSecAttrLabel as String: KeychainStore.itemLabel] as CFDictionary)
        lastStatus = update
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var attrs = query
        attrs[kSecAttrLabel as String] = KeychainStore.itemLabel
        attrs[kSecValueData as String] = Data(value.utf8)
        lastStatus = SecItemAdd(attrs as CFDictionary, nil)
        return lastStatus == errSecSuccess
    }

    static func get(_ key: String) -> String? {
        read(key)
    }

    /// Removes one stored item. A missing item counts as removed.
    @discardableResult
    static func delete(_ key: String) -> Bool {
        if TCC.isolated { memoryLock.lock(); memory[key] = nil; memoryLock.unlock(); lastStatus = errSecSuccess; return true }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        lastStatus = SecItemDelete(query as CFDictionary)
        return lastStatus == errSecSuccess || lastStatus == errSecItemNotFound
    }

    private static func read(_ key: String) -> String? {
        if TCC.isolated { memoryLock.lock(); defer { memoryLock.unlock() }; return memory[key] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var out: AnyObject?
        lastStatus = SecItemCopyMatching(query as CFDictionary, &out)
        guard lastStatus == errSecSuccess, let d = out as? Data else { return nil }
        migrateLegacyLabel(for: key)
        return String(data: d, encoding: .utf8)
    }

    /// Attribute-only migration. Never change secrets, ACLs or prompt for authentication.
    @discardableResult
    static func migrateLegacyLabels() -> (renamed: Int, pending: Int) {
        if TCC.isolated { return (0, 0) }
        var renamed=0, pending=0
        for engine in ASREngine.allCases {
            for field in engine.credentialFields {
                let result=migrateLegacyLabel(for: engine.rawValue + "." + field.0)
                if result == 1 { renamed += 1 }; if result == -1 { pending += 1 }
            }
        }
        return (renamed,pending)
    }

    @discardableResult
    private static func migrateLegacyLabel(for key: String) -> Int {
        if TCC.isolated { return 0 }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var lookup = query
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let lookupStatus=SecItemCopyMatching(lookup as CFDictionary, &result)
        if lookupStatus == errSecItemNotFound { return 0 }
        guard lookupStatus == errSecSuccess else { return -1 }
        guard let attributes = result as? [String: Any],
              let label = attributes[kSecAttrLabel as String] as? String,
              ["言随","随言","VoiceBridge","Cadenza"].contains(where:{label.hasPrefix($0)}) || isRawKey(label),
              label != KeychainStore.itemLabel else { return 0 }
        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecAttrLabel as String: KeychainStore.itemLabel] as CFDictionary)
        Log.write("keychain-label-migration status=\(status) attributes-only=true")
        return status == errSecSuccess ? 1 : -1
    }

    /// Legacy login-keychain prompts use ACL descriptions, not kSecAttrLabel.
    /// Only human-readable descriptions change; trusted apps, authorizations,
    /// partition entries and prompt flags are preserved exactly.
    static func migrateAccessDescriptions() -> (renamed:Int,pending:Int) {
        if TCC.isolated { return (0, 0) }
        var allowed:DarwinBoolean=false
        guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess else{return(0,1)}
        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else{return(0,1)}
        defer {_ = SecKeychainSetUserInteractionAllowed(allowed.boolValue)}
        var renamed=0,pending=0
        let name=KeychainStore.itemLabel
        for engine in ASREngine.allCases {for field in engine.credentialFields {
            let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:engine.rawValue+"."+field.0,kSecReturnRef as String:true,kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail]
            var result:CFTypeRef?
            let lookup=SecItemCopyMatching(q as CFDictionary,&result)
            if lookup == errSecItemNotFound {continue}
            guard lookup == 0,let result=result,CFGetTypeID(result)==SecKeychainItemGetTypeID() else{pending+=1;continue}
            let item=result as! SecKeychainItem
            var access:SecAccess?,list:CFArray?
            guard SecKeychainItemCopyAccess(item,&access)==0,let access=access,
                  SecAccessCopyACLList(access,&list)==0,let acls=list as? [SecACL] else{pending+=1;continue}
            var changed=false,failed=false
            for acl in acls {
                var apps:CFArray?,description:CFString?,selector=SecKeychainPromptSelector(rawValue:0)
                guard SecACLCopyContents(acl,&apps,&description,&selector)==0 else{failed=true;break}
                guard let old=description as String?, Self.legacyAccessDescription(old,current:name) else{continue}
                // Use the very same application array and selector. Never create a
                // replacement access list or change authorizations/partition strings.
                guard SecACLSetContents(acl,apps,name as CFString,selector)==0 else{failed=true;break}
                changed=true
            }
            if failed{pending+=1;continue}
            if changed {
                let status=SecKeychainItemSetAccess(item,access)
                Log.write("keychain-prompt-name-migration status=\(status) description-only=true interaction-disabled=true")
                if status == 0 {renamed+=1}else{pending+=1}
            }
        }}
        return(renamed,pending)
    }
    static func legacyAccessDescription(_ description:String,current:String)->Bool {
        description != current && (["言随 ·","随言 ·","VoiceBridge","Cadenza ·"].contains(where:{description.hasPrefix($0)}) || isRawKey(description))
    }

    static func has(_ key: String) -> Bool {
        if TCC.isolated { memoryLock.lock(); defer { memoryLock.unlock() }; return memory[key] != nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }


}

// MARK: - 波形视图（浅绿声波条）

/// Display-only soft noise floor; capture and recognition keep the original audio.
enum WaveformAppearance {
    static func displayLevel(_ level: Float) -> Float {
        guard level.isFinite else { return 0 }
        let clamped = max(0, min(1, level))
        return clamped <= 0.08 ? 0 : (clamped - 0.08) / 0.92
    }
}

final class WaveformView: NSView {
    var levels: [CGFloat] = Array(repeating: 0, count: 21) { didSet { needsDisplay = true } }
    var barColor = DesignTokens.accent

    func push(_ v: CGFloat) {
        levels.removeFirst()
        levels.append(max(0, min(1, v)))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let n = levels.count
        let slot = bounds.width / CGFloat(n)
        let barW = max(2.4, slot * 0.5)
        let centre = CGFloat(n - 1) / 2
        // Decided from the app's appearance, like the bar behind it, so the wave is never light-on-light or dark-on-dark.
        let accent = NSApp.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? NSColor(srgbRed:161/255,green:215/255,blue:186/255,alpha:1):DesignTokens.jade
        for (i, v) in levels.enumerated() {
            // Bars fade toward both ends, so the wave looks like it rises out of the glass instead of ending abruptly.
            let fade = 1 - 0.35 * abs(CGFloat(i) - centre) / centre
            ctx.setFillColor(accent.withAlphaComponent(fade).cgColor)
            let h = max(barW, CGFloat(v) * bounds.height * 0.92)
            let rect = NSRect(x: CGFloat(i) * slot + (slot - barW) / 2, y: bounds.midY - h / 2, width: barW, height: h)
            NSBezierPath(roundedRect: rect, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
    }
}

// MARK: - 按住说话按钮（mouseDown 开始 / mouseUp 结束；AXPress = 1.5 秒演示）

final class HoldButton: NSButton {
    var onPressStart: (() -> Void)?
    var onPressEnd: (() -> Void)?
    private var pressed = false

    override func draw(_ dirtyRect: NSRect) {
        DesignTokens.jade.withAlphaComponent(isEnabled ? 1 : 0.5).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        super.draw(dirtyRect)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        onPressStart?()
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { break }
        }
        pressed = false
        onPressEnd?()
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        onPressEnd?()
    }

    override func accessibilityPerformPress() -> Bool {
        doHold()
        return true
    }

    override func performClick(_ sender: Any?) {
        doHold()
    }

    private func doHold() {
        onPressStart?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.onPressEnd?()
        }
    }
}

// MARK: - 轻量内存诊断环（仅状态/错误/时间，不含音频、识别文本、凭据）

enum Diagnostics {
    private static var ring: [String] = []
    private static let lock = NSLock()

    static func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        ring.append(line)
        if ring.count > 30 { ring.removeFirst(ring.count - 30) }
    }

    static func recent(_ n: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return ring.suffix(n)
    }
}

// MARK: - Only live waveform; accessible hover actions and separate failure feedback.
private final class CapsuleContentView:NSView {
    var onHover:((Bool)->Void)?
    private var tracking:NSTrackingArea?
    override var wantsUpdateLayer:Bool {true}
    /// The glass behind this view. Its tint is set here from the app's appearance: a dynamic colour handed over once can
    /// stay on the value it had when the bar was built, which left a light tint (and an invisible wave) after switching to dark.
    weak var glassHost:NSView?
    static let glassSupported:Bool = { if #available(macOS 26.0, *) { return true }; return false }()
    override func updateLayer(){effectiveAppearance.performAsCurrentDrawingAppearance {
        if Self.glassSupported && !AppearanceController.highContrast {
            // The glass carries the background. In light mode a hairline white highlight gives it a defined, glassy edge.
            let dark=NSApp.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua
            if #available(macOS 26.0, *), let glass=glassHost as? NSGlassEffectView { glass.tintColor=dark ? DesignTokens.hudGlassTintDark:DesignTokens.hudGlassTintLight }
            // Dark mode matches the preview in Settings: a dark bar with a mint wave. The glass alone turned bright over a light
            // desktop and hid the wave. Light mode stays see-through glass with a hairline highlight.
            layer?.backgroundColor=dark ? DesignTokens.hudBackgroundDark.withAlphaComponent(0.92).cgColor:NSColor.clear.cgColor
            layer?.borderColor=NSColor.white.withAlphaComponent(dark ? 0.12:0.6).cgColor;layer?.borderWidth=dark ? 1:0.5
        }
        else { layer?.backgroundColor=DesignTokens.hudBackground.cgColor;layer?.borderColor=DesignTokens.outline.cgColor;layer?.borderWidth=AppearanceController.highContrast ? 1.5:1 }
    }}
    override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();needsDisplay=true}
    override func updateTrackingAreas(){super.updateTrackingAreas();if let tracking=tracking{removeTrackingArea(tracking)};let next=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil);addTrackingArea(next);tracking=next}
    override func mouseEntered(with event:NSEvent){onHover?(true)}
    override func mouseExited(with event:NSEvent){onHover?(false)}
}

/// Transparent root of the panel: owns hover tracking, the glass/pill chrome and the optional character above it.
private final class CapsuleRootView:NSView {
    var onHover:((Bool)->Void)?
    private var tracking:NSTrackingArea?
    override func updateTrackingAreas(){super.updateTrackingAreas();if let tracking=tracking{removeTrackingArea(tracking)};let next=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil);addTrackingArea(next);tracking=next}
    override func mouseEntered(with event:NSEvent){onHover?(true)}
    override func mouseExited(with event:NSEvent){onHover?(false)}
}

enum RecordingHUDPlacement {
    static func origin(size:NSSize,frame:NSRect,visible:NSRect)->NSPoint {
        let x=min(max(frame.midX-size.width/2,visible.minX+12),visible.maxX-size.width-12)
        let y=min(max(frame.minY+80,visible.minY+24),visible.maxY-size.height-12)
        return NSPoint(x:x,y:y)
    }
}

final class CapsuleWindowController:NSObject {
    var onCancel:(()->Void)?,onStop:(()->Void)?,onRetry:(()->Void)?,onOpenResult:(()->Void)?,onPrivacy:(()->Void)?,onTargetHelp:(()->Void)?
    private enum Mode {case hidden,record,recognize,error}
    private var mode:Mode = .hidden
    private var panel:NSPanel?,content:CapsuleContentView?,waveform:WaveformView?,character:CharacterView?,chrome:NSView?
    private var anchorScreen:NSScreen?
    private var characterControls:NSView?
    private var statusCaption:NSTextField?,captionBackground:NSVisualEffectView?
    private var stopButton:NSButton?,cancelButton:NSButton?,reasonLabel:NSTextField?,errorIcon:NSImageView?
    private var action:ResultAction = .retry
    private var hovered=false
    private var manualStop=false
    private var levelTimer:Timer?,hideTimer:Timer?
    private var latest:Float=0,smooth:Float=0
    private var lastInput=ProcessInfo.processInfo.systemUptime,lastTick=ProcessInfo.processInfo.systemUptime
    private var hideAt=Date.distantPast
    private let waveSize=NSSize(width:180,height:40)
    private var reduceMotion:Bool {AppearanceController.reduceMotion}

    func showRecord(elapsed:TimeInterval?,manual:Bool=false,shortcut:String?=nil,retentionHint:String?=nil,toggled:Bool=false) {
        let changed=prepare(.record)
        manualStop=manual
        let instruction=toggled ? L10n.tr("ui.21757b6df4d1"):manual ? L10n.tr("ui.e2feb8788c64"):shortcut.map{L10n.format("ui.d7a22f0e0119", String(describing: $0))} ?? L10n.tr("ui.fd76904dc4b3")
        content?.toolTip=instruction+(retentionHint.map{"；"+$0} ?? "")
        content?.setAccessibilityLabel(L10n.tr("ui.9a02ff477cd0")+instruction)
        content?.setAccessibilityCustomActions([NSAccessibilityCustomAction(name:L10n.tr("ui.84e3135a0e30"),handler:{[weak self] in self?.onStop?();return true}),NSAccessibilityCustomAction(name:L10n.tr("ui.dd9db147a322"),handler:{[weak self] in self?.onCancel?();return true})])
        layoutWave();present()
        if changed {startLevels()}
    }
    func tick(elapsed:TimeInterval?,level:Float){guard mode == .record else{return};latest=level.isFinite ? max(0,min(1,level)):0;lastInput=ProcessInfo.processInfo.systemUptime}
    private func startLevels(){levelTimer?.invalidate();latest=0;smooth=0;lastTick=ProcessInfo.processInfo.systemUptime;lastInput=lastTick
        let timer=Timer(timeInterval:reduceMotion ? 0.08:0.04,repeats:true){[weak self] _ in
            guard let self=self,self.mode == .record else{return}
            let now=ProcessInfo.processInfo.systemUptime,dt=now-self.lastTick;self.lastTick=now
            if now-self.lastInput>0.45 {self.latest=0}
            let displayed=WaveformAppearance.displayLevel(self.latest)
            if self.reduceMotion {self.smooth=displayed} else {self.smooth += Float(1-exp(-dt/(displayed>self.smooth ? 0.07:0.18)))*(displayed-self.smooth)}
            if self.reduceMotion {self.waveform?.levels=Array(repeating:CGFloat(self.smooth),count:21)} else {self.waveform?.push(CGFloat(self.smooth))}
        };levelTimer=timer;RunLoop.main.add(timer,forMode:.common)
    }
    func showRecognize(){let changed=prepare(.recognize);content?.setAccessibilityLabel(L10n.tr("ui.72780546b970"));content?.toolTip=L10n.tr("ui.c92c7ce4d76a");content?.setAccessibilityCustomActions([NSAccessibilityCustomAction(name:L10n.tr("ui.3eec34007c80"),handler:{[weak self] in self?.onCancel?();return true})]);layoutWave();present()
        if changed && !reduceMotion {let fade=CABasicAnimation(keyPath:"opacity");fade.fromValue=0.35;fade.toValue=0.7;fade.duration=1.2;fade.autoreverses=true;fade.repeatCount = .infinity;waveform?.layer?.add(fade,forKey:"waiting-opacity")}
    }
    private func layoutWave(){guard mode == .record || mode == .recognize else{return};let showManualStop=mode == .record && manualStop && !hovered
        let useCharacter=CharacterAssets.active
        // Character style: while speaking or recognizing only the character is shown, with no pill, border or shadow.
        // Character controls use a compact solid surface, without the glass pill or its shadow.
        let bare=useCharacter && !hovered && !showManualStop
        let pillWidth:CGFloat=showManualStop ? 256:144
        let size=useCharacter ? NSSize(width:128,height:112):NSSize(width:pillWidth,height:40)
        panel?.setContentSize(size);panel?.hasShadow = !useCharacter;content?.layer?.cornerRadius=20
        chrome?.isHidden=useCharacter;chrome?.frame=NSRect(x:0,y:useCharacter ? 4:0,width:size.width,height:40)
        waveform?.frame=NSRect(x:24,y:9,width:96,height:22);waveform?.isHidden=hovered || useCharacter
        character?.frame=NSRect(x:(size.width-CharacterAssets.displaySize)/2,y:36,width:CharacterAssets.displaySize,height:CharacterAssets.displaySize);character?.isHidden = !useCharacter
        statusCaption?.stringValue=L10n.tr(mode == .record ? "indicator.state.recording":"indicator.state.recognizing")
        captionBackground?.frame=NSRect(x:8,y:4,width:112,height:24)
        captionBackground?.isHidden = !bare
        if useCharacter {character?.play(mode == .record ? .write:.think)} else {character?.stop()}
        stopButton?.isHidden = (!hovered && !showManualStop) || mode == .recognize;cancelButton?.isHidden = !hovered || (useCharacter && mode == .record)
        stopButton?.title=L10n.tr("ui.ca4d973c0b00");stopButton?.frame=NSRect(x:showManualStop ? 174:8,y:4,width:showManualStop ? 70:58,height:32)
        cancelButton?.title=L10n.tr("ui.2cd0f3be8738");cancelButton?.frame=NSRect(x:mode == .record ? 76:32,y:4,width:mode == .record ? 58:80,height:32)
        characterControls?.isHidden = !useCharacter || bare
        if let controls=characterControls,let content=content {
            let parent:NSView=useCharacter ? controls:content
            for button in [stopButton,cancelButton].compactMap({$0}) {
                if button.superview !== parent {button.removeFromSuperview();parent.addSubview(button)}
                button.font = .systemFont(ofSize:useCharacter ? 12:13,weight:useCharacter ? .semibold:.regular)
            }
            cancelButton?.contentTintColor=useCharacter ? .secondaryLabelColor:DesignTokens.accent
            if useCharacter {
                controls.frame=NSRect(x:(size.width-88)/2,y:4,width:88,height:30)
                controls.effectiveAppearance.performAsCurrentDrawingAppearance {
                    controls.layer?.backgroundColor=DesignTokens.adaptive((23,42,37),NSColor(srgbRed:0.97,green:0.995,blue:0.98,alpha:1)).cgColor
                    controls.layer?.borderColor=DesignTokens.accent.withAlphaComponent(AppearanceController.highContrast ? 0.75:0.20).cgColor
                }
                stopButton?.frame=NSRect(x:12,y:1,width:64,height:28)
                cancelButton?.frame=NSRect(x:12,y:1,width:64,height:28)
            }
        }
        reasonLabel?.isHidden=true;errorIcon?.isHidden=true;position()
    }
    func accessibilityChanged(){content?.needsDisplay=true
        if reduceMotion {waveform?.layer?.removeAllAnimations();content?.layer?.removeAllAnimations()}
        if mode == .record {let input=latest;startLevels();latest=input}
        Log.write("wave-accessibility-refresh reduced-motion=\(reduceMotion) high-contrast=\(AppearanceController.highContrast) mode-record=\(mode == .record)")
    }
    func inspectRecordingHover(){hovered=true;layoutWave()}
    func inspectWave(_ stage:String){
        if stage == "record" {showRecord(elapsed:0);waveform?.levels=[0,0.03,0.15,0.35,0.8,0.55,0.22,0.1,0.05,0.15,0.3,0.6,1,0.7,0.35,0.2,0.08,0.05,0.02,0,0]}
        else if stage == "silence" {showRecord(elapsed:0);latest=0;smooth=0;waveform?.levels=Array(repeating:0,count:21)}
        else if stage == "recognize" {showRecognize()}
        else if stage == "error" {showError(L10n.format("ui.f70272ab7eab", String(describing: Brand.name)),action:.result)}
        else {hide()}
        Log.write("wave-ui-check stage=\(stage) synthetic=true timer-active=\(levelTimer != nil) no-time-label=true reduce-motion=\(reduceMotion) visible=\(mode != .hidden)")
    }
    private var inspectionTimer:Timer?
    func inspectSequence(_ done:@escaping()->Void){
        let started=ProcessInfo.processInfo.systemUptime;var stage=""
        showRecord(elapsed:0)
        let timer=Timer(timeInterval:0.04,repeats:true){[weak self] timer in
            guard let self=self else{timer.invalidate();return};let t=ProcessInfo.processInfo.systemUptime-started
            let next=t<3 ? "signal":t<5 ? "silence":t<7 ? "recognize":t<8 ? "success-hidden":t<9.5 ? "restart":t<10.5 ? "cancel-hidden":t<12 ? "error":"complete"
            if next != stage {stage=next
                switch stage {case "recognize":self.showRecognize();case "success-hidden","cancel-hidden":self.hide();case "restart":self.showRecord(elapsed:0);case "error":self.showError(L10n.format("ui.4fa68fee49b2", String(describing: Brand.name)),action:.result);case "complete":self.hide();timer.invalidate();self.inspectionTimer=nil;done();default:break}
                Log.write("wave-sequence stage=\(stage) synthetic-audio=true level-timer=\(self.levelTimer != nil) waiting-opacity=\(self.waveform?.layer?.animation(forKey:"waiting-opacity") != nil) reduced-motion=\(self.reduceMotion) panel-visible=\(self.panel?.isVisible == true)")
            }
            if stage == "signal" || stage == "restart" {self.tick(elapsed:nil,level:Float(0.3+0.6*abs(sin(t*6))))} else if stage == "silence" {self.tick(elapsed:nil,level:0)}
        };inspectionTimer=timer;RunLoop.main.add(timer,forMode:.common)
    }
    func showError(_ reason:String,action:ResultAction?=nil){if mode == .error,reasonLabel?.toolTip==reason {return};_=prepare(.error);self.action=action ?? (reason.contains(L10n.tr("ui.9820e855a6c6")) ? .result:.retry)
        let message=self.action == .result ? L10n.tr("ui.a193c59bb0c6"):reason
        reasonLabel?.stringValue=message
        let natural=ceil(reasonLabel?.cell?.cellSize(forBounds:NSRect(x:0,y:0,width:2000,height:30)).width ?? 200)
        errorWidth=min(560,max(360,(CharacterAssets.active ? 54:42)+natural+12+86+14+4))
        panel?.setContentSize(NSSize(width:errorWidth,height:Self.errorHeight));panel?.hasShadow=true;chrome?.isHidden=false;chrome?.frame=NSRect(x:0,y:0,width:errorWidth,height:Self.errorHeight);content?.layer?.cornerRadius=16;waveform?.isHidden=true;reasonLabel?.isHidden=false
        captionBackground?.isHidden=true
        characterControls?.isHidden=true
        if let content=content {
            for button in [stopButton,cancelButton].compactMap({$0}) {
                if button.superview !== content {button.removeFromSuperview();content.addSubview(button)}
                button.font = .systemFont(ofSize:13)
                button.contentTintColor=DesignTokens.accent
            }
        }
        let useCharacter=CharacterAssets.active
        errorIcon?.isHidden=useCharacter;character?.isHidden = !useCharacter;character?.frame=NSRect(x:10,y:8,width:36,height:36)
        if useCharacter {character?.play(self.action == .retry ? .error:.alert)} else {character?.stop()}
        reasonLabel?.stringValue=self.action == .result ? L10n.tr("ui.a193c59bb0c6"):reason;reasonLabel?.toolTip=reason;layoutErrorRow(useCharacter:useCharacter)
        content?.setAccessibilityLabel(reason);content?.setAccessibilityCustomActions(nil);stopButton?.isHidden=false;cancelButton?.isHidden=true
        stopButton?.title=self.action == .result ? L10n.tr("ui.db8db0530432"):self.action == .privacy ? L10n.tr("ui.63f31192ff46"):self.action == .targetHelp ? L10n.tr("ui.527af7c279ac"):L10n.tr("ui.b8784c8dd563");stopButton?.frame=NSRect(x:errorWidth-14-86,y:(Self.errorHeight-32)/2,width:86,height:32)
        present();hideAt=Date().addingTimeInterval(6);hideTimer=Timer.scheduledTimer(withTimeInterval:6.2,repeats:false){[weak self] _ in self?.hideIfExpired()}
    }
    static let errorHeight:CGFloat=52
    /// Sized to the message (within limits) so it is not cut off while the button stays at the right edge.
    private var errorWidth:CGFloat=400
    /// Icon (or character), message and button share one vertical centre. The message height is measured, not guessed,
    /// because a fixed frame taller than the text makes the text ride high against the button.
    private func layoutErrorRow(useCharacter:Bool) {
        let h=Self.errorHeight,x:CGFloat=useCharacter ? 54:42,width=errorWidth-14-86-12-x
        errorIcon?.frame=NSRect(x:14,y:(h-18)/2,width:18,height:18)
        character?.frame=NSRect(x:10,y:(h-36)/2,width:36,height:36)
        guard let label=reasonLabel else{return}
        let text=ceil(label.cell?.cellSize(forBounds:NSRect(x:0,y:0,width:width,height:200)).height ?? 16)
        label.frame=NSRect(x:x,y:((h-text)/2).rounded(),width:width,height:text)
    }
    /// Vertical centres of the error row, for the layout checks.
    func inspectErrorRow()->(panel:CGFloat,icon:CGFloat,character:CGFloat,label:CGFloat,button:CGFloat,labelMaxX:CGFloat,buttonMinX:CGFloat,labelHeight:CGFloat,textHeight:CGFloat)? {
        guard let panel=panel,let label=reasonLabel,let button=stopButton,let icon=errorIcon,let character=character else{return nil}
        let text=ceil(label.cell?.cellSize(forBounds:NSRect(x:0,y:0,width:label.frame.width,height:200)).height ?? 0)
        return(panel.contentView?.bounds.midY ?? 0,icon.frame.midY,character.frame.midY,label.frame.midY,button.frame.midY,label.frame.maxX,button.frame.minX,label.frame.height,text)
    }
    var inspectionContentView:NSView? {panel?.contentView}
    var suppressPresentation=false
    func hideIfExpired(){if mode == .error,Date()>=hideAt {hide()}}
    func hide(){character?.stop();levelTimer?.invalidate();levelTimer=nil;hideTimer?.invalidate();hideTimer=nil;latest=0;smooth=0;waveform?.levels=Array(repeating:0,count:21);waveform?.layer?.removeAllAnimations();content?.layer?.removeAllAnimations();mode = .hidden;anchorScreen=nil;panel?.orderOut(nil)}
    @discardableResult private func prepare(_ next:Mode)->Bool {if panel == nil {build()};let changed=mode != next
        if changed {hideTimer?.invalidate();hideTimer=nil;waveform?.layer?.removeAllAnimations();hovered=false;waveform?.levels=Array(repeating:0,count:21);content?.setAccessibilityCustomActions(nil)}
        if next != .record {levelTimer?.invalidate();levelTimer=nil;latest=0;smooth=0}
        if mode == .hidden {
            anchorScreen=NSScreen.screens.first(where:{$0.frame.contains(NSEvent.mouseLocation)}) ?? NSScreen.main
        }
        mode=next;return changed
    }
    private func present(){guard !suppressPresentation,let panel=panel else{return};content?.needsDisplay=true;position();panel.alphaValue=1;panel.orderFrontRegardless()}
    private func position(){guard let panel=panel,let screen=anchorScreen ?? NSScreen.main else{return};panel.setFrameOrigin(RecordingHUDPlacement.origin(size:panel.frame.size,frame:screen.frame,visible:screen.visibleFrame))}
    @objc private func performAction(){if mode == .record {onStop?()} else if mode == .recognize {onCancel?()} else if mode == .error {switch action {case .retry:onRetry?();case .result:onOpenResult?();case .privacy:onPrivacy?();case .targetHelp:onTargetHelp?()}}}
    @objc private func cancel(){onCancel?()}
    private func build(){let p=NSPanel(contentRect:NSRect(origin:.zero,size:waveSize),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false);p.isOpaque=false;p.backgroundColor = .clear;p.level = .floating;p.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];p.becomesKeyOnlyIfNeeded=true
        let c=CapsuleContentView(frame:NSRect(origin:.zero,size:waveSize));c.wantsLayer=true;c.layer?.cornerRadius=20;c.onHover={[weak self] hover in self?.hovered=hover;self?.layoutWave()};c.setAccessibilityElement(true);c.setAccessibilityRole(.group)
        let wf=WaveformView(frame:NSRect(x:24,y:9,width:96,height:22));wf.wantsLayer=true;wf.setAccessibilityElement(false);c.addSubview(wf);waveform=wf
        let stop=NSButton(title:L10n.tr("ui.ca4d973c0b00"),target:self,action:#selector(performAction));stop.isBordered=false;stop.contentTintColor=DesignTokens.accent;stop.isHidden=true;c.addSubview(stop);stopButton=stop
        let cancel=NSButton(title:L10n.tr("ui.2cd0f3be8738"),target:self,action:#selector(cancel));cancel.isBordered=false;cancel.contentTintColor=DesignTokens.accent;cancel.isHidden=true;c.addSubview(cancel);cancelButton=cancel
        let label=NSTextField(labelWithString:"");label.font = .systemFont(ofSize:12);label.lineBreakMode = .byTruncatingTail;label.isHidden=true;c.addSubview(label);reasonLabel=label
        let icon=NSImageView(frame:NSRect(x:14,y:16,width:18,height:18));icon.image=NSImage(systemSymbolName:"exclamationmark.circle",accessibilityDescription:L10n.tr("ui.f56c6c82203b"));icon.contentTintColor=DesignTokens.amber;icon.isHidden=true;c.addSubview(icon);errorIcon=icon
        let root=CapsuleRootView(frame:NSRect(origin:.zero,size:waveSize));root.onHover={[weak self] hover in self?.hovered=hover;self?.layoutWave()}
        var pill:NSView=c
        if #available(macOS 26.0, *), !AppearanceController.highContrast {
            let glass=NSGlassEffectView(frame:NSRect(origin:.zero,size:waveSize));glass.cornerRadius=20;glass.tintColor=DesignTokens.hudGlassTint;glass.contentView=c;c.glassHost=glass
            pill=glass
        }
        pill.frame=root.bounds;pill.autoresizingMask=[];root.addSubview(pill);chrome=pill
        let controls=NSView(frame:.zero);controls.wantsLayer=true
        controls.layer?.cornerRadius=11;controls.layer?.borderWidth=1;controls.isHidden=true
        root.addSubview(controls);characterControls=controls
        let ch=CharacterView(frame:.zero);ch.isHidden=true;root.addSubview(ch);character=ch
        let caption=NSVisualEffectView(frame:NSRect(x:8,y:4,width:112,height:24))
        caption.material = .hudWindow;caption.blendingMode = .behindWindow;caption.state = .active
        caption.wantsLayer=true;caption.layer?.cornerRadius=12;caption.layer?.masksToBounds=true;caption.isHidden=true
        let status=NSTextField(labelWithString:"");status.font = .systemFont(ofSize:12,weight:.semibold)
        status.textColor = .labelColor;status.alignment = .center;status.frame=NSRect(x:4,y:4,width:104,height:16)
        caption.addSubview(status);root.addSubview(caption);statusCaption=status;captionBackground=caption
        p.contentView=root
        content=c;panel=p
    }
}
