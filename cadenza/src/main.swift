import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import Speech

QuietWindows.installIfNeeded() // self-tests and previews never show windows on screen

fputs("[cadenza] main-enter\n", stderr)

if CommandLine.arguments.contains("--selftest-settings-polish") {
    var count=0,failed=0
    SettingsPolishFixtures.run{name,ok in count+=1;if !ok{failed+=1};print("[settings-polish] \(ok ? "PASS":"FAIL") \(name)")}
    print("[settings-polish] checks=\(count) failures=\(failed)");exit(failed == 0 ? 0:1)
}
if CommandLine.arguments.contains("--selftest-status-menu") {
    var count=0,failed=0
    StatusMenuFixtures.run{name,ok in count+=1;if !ok{failed+=1};print("[status-menu] \(ok ? "PASS":"FAIL") \(name)")}
    print("[status-menu] checks=\(count) failures=\(failed)");exit(failed == 0 ? 0:1)
}
if let state=CommandLine.arguments.first(where:{$0.hasPrefix("--preview-status-menu=")}) {exit(StatusMenuFixtures.preview(String(state.dropFirst("--preview-status-menu=".count))))}

if CommandLine.arguments.contains("--check-brand-resources") {exit(L10n.verifyResources())}
if let flag=CommandLine.arguments.first(where:{$0.hasPrefix("--preview-brand-page=")}),
   let output=CommandLine.arguments.first(where:{$0.hasPrefix("--preview-brand-output=")}) {
    exit(BrandPreview.render(page:String(flag.dropFirst("--preview-brand-page=".count)),output:String(output.dropFirst("--preview-brand-output=".count))))
}

// Noninteractive metadata maintenance; exits before UI, listeners or recorders exist.
if let index=CommandLine.arguments.firstIndex(of:"--diagnose-trigger-latency"),CommandLine.arguments.count>index+1 {exit(TriggerLatencyProbe.run(mode:CommandLine.arguments[index+1]))}

if CommandLine.arguments.contains("--diagnose-trigger-network") {exit(TriggerNetworkProbe.run())}

if let index=CommandLine.arguments.firstIndex(of:"--calibrate-trigger-sample"),CommandLine.arguments.count>index+2,let seconds=Int(CommandLine.arguments[index+2]) {
    exit(TriggerMicrophoneCalibration.sample(label:CommandLine.arguments[index+1],seconds:seconds))
}

if let index=CommandLine.arguments.firstIndex(of:"--calibrate-trigger-mic"),CommandLine.arguments.count>index+1 {
    exit(TriggerMicrophoneCalibration.run(environment:CommandLine.arguments[index+1]))
}

if CommandLine.arguments.contains("--selftest-appearance") {
    var count = 0, failed = 0
    AppearanceTransitionFixtures.run { name, ok in
        count += 1; if !ok { failed += 1 }
        print("[appearance] \(ok ? "PASS" : "FAIL") \(name)")
    }
    print("[appearance] checks=\(count) failures=\(failed)")
    exit(failed == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--selftest-settings-ui") {
    var count=0,failed=0
    SettingsUIFixtures.run{name,ok in count+=1;if !ok{failed+=1};print("[settings-ui] \(ok ? "PASS":"FAIL") \(name)")}
    print("[settings-ui] checks=\(count) failures=\(failed)");exit(failed == 0 ? 0:1)
}

if CommandLine.arguments.contains("--selftest-sidebar-click") {
    var count=0,failed=0
    SidebarClickFixtures.run{name,ok in count+=1;if !ok{failed+=1};print("[sidebar-click] \(ok ? "PASS":"FAIL") \(name)")}
    print("[sidebar-click] checks=\(count) failures=\(failed)");exit(failed == 0 ? 0:1)
}

if CommandLine.arguments.contains("--selftest-trigger-stage2") {
    var count=0,failed=0
    TriggerStage2Fixtures.run{name,ok in count+=1;if !ok{failed+=1};print("[trigger-stage2] \(ok ? "PASS":"FAIL") \(name)")}
    print("[trigger-stage2] checks=\(count) failures=\(failed)");exit(failed == 0 ? 0:1)
}

if CommandLine.arguments.contains("--migrate-keychain-labels") {
    let prompts=KeychainStore.migrateAccessDescriptions()
    print("keychain-prompt-names renamed=\(prompts.renamed) pending=\(prompts.pending) secrets-read=false")
    let result=KeychainStore.migrateLegacyLabels()
    print("keychain-labels renamed=\(result.renamed) pending=\(result.pending) secrets-read=false")
    exit(0)
}

if CommandLine.arguments.contains("--selftest-wechat-native") {
    var checks=0,failures=0
    WechatDiagnosticFixtures.run {name,passed in checks += 1;if !passed{failures += 1};print("[wechat-native-selftest] \(passed ? "PASS":"FAIL"): \(name)")}
    print("[wechat-native-selftest] done checks=\(checks) failures=\(failures)")
    exit(failures==0 ? 0:1)
}

if CommandLine.arguments.contains("--selftest-asr-entry") {
    var checks=0,failures=0
    ASREntryFixtures.run({ name,passed in checks += 1;if !passed{failures += 1};print("[entry-selftest] \(passed ? "PASS":"FAIL"): \(name)") },live:true)
    print("[entry-selftest] done checks=\(checks) failures=\(failures)")
    exit(failures==0 ? 0:1)
}

if CommandLine.arguments.contains("--selftest-asr-settings") {
    var checks=0,failures=0
    ASRSettingsFixtures.run { name,passed in checks += 1;if !passed{failures += 1};print("[settings-selftest] \(passed ? "PASS":"FAIL"): \(name)") }
    print("[settings-selftest] done checks=\(checks) failures=\(failures)")
    exit(failures==0 ? 0:1)
}

if CommandLine.arguments.contains("--verify-local-models") {exit(LocalModelAcceptance.run(download:CommandLine.arguments.contains("--download-models")))}
if let flag=CommandLine.arguments.first(where:{$0.hasPrefix("--preview-screenshot-textstyles=")}) {
    exit(ScreenshotPreview.renderTextStyles(output:String(flag.dropFirst("--preview-screenshot-textstyles=".count))))
}
if let flag=CommandLine.arguments.first(where:{$0.hasPrefix("--preview-screenshot-icons=")}) {
    exit(ScreenshotPreview.renderIcons(output:String(flag.dropFirst("--preview-screenshot-icons=".count)),dark:CommandLine.arguments.contains("--preview-screenshot-dark")))
}
if let flag=CommandLine.arguments.first(where:{$0.hasPrefix("--preview-screenshot-output=")}) {
    let tool=CommandLine.arguments.first(where:{$0.hasPrefix("--preview-screenshot-tool=")}).flatMap{ScreenshotTool(rawValue:String($0.dropFirst("--preview-screenshot-tool=".count)))}
    exit(ScreenshotPreview.render(output:String(flag.dropFirst("--preview-screenshot-output=".count)),dark:CommandLine.arguments.contains("--preview-screenshot-dark"),tool:tool,recognizing:CommandLine.arguments.contains("--preview-screenshot-recognizing"),recognition:CommandLine.arguments.contains("--preview-screenshot-recognition")))
}
if CommandLine.arguments.contains("--selftest-screenshot") {
    var checks=0,failures=0
    setvbuf(stdout,nil,_IOLBF,0)
    _ = NSApplication.shared
    ScreenshotFixtures.run { name,passed in checks += 1;if !passed{failures += 1};print("[screenshot-selftest] \(passed ? "PASS":"FAIL"): \(name)") }
    print("[screenshot-selftest] done checks=\(checks) failures=\(failures)")
    exit(failures==0 ? 0:1)
}
if CommandLine.arguments.contains("--selftest-local-model-real") {exit(LocalModelFixtures.realModel())}
if CommandLine.arguments.contains("--selftest-local-ocr-real") {_ = NSApplication.shared;exit(OCRLocalFixtures.real())}
if CommandLine.arguments.contains("--selftest-local-ocr-download") {_ = NSApplication.shared;exit(OCRLocalFixtures.realDownload())}
if CommandLine.arguments.contains("--local-accuracy-probe") {exit(LocalModelFixtures.accuracyProbe())}
if CommandLine.arguments.contains("--accuracy-benchmark") {exit(AccuracyBenchmark.run())}
if CommandLine.arguments.contains("--selftest-local-model") {
    var checks=0,failures=0
    LocalModelFixtures.run { name,passed in checks += 1;if !passed{failures += 1};print("[local-model-selftest] \(passed ? "PASS":"FAIL"): \(name)") }
    print("[local-model-selftest] done checks=\(checks) failures=\(failures)")
    exit(failures==0 ? 0:1)
}

if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run())
}

enum LaunchMode {
    static let probe = CommandLine.arguments.contains("--probe") && !enhancedDiagnostic
    static let probeGlobal = CommandLine.arguments.contains("--probe-global") && !enhancedDiagnostic
    static let enhancedDiagnostic = CommandLine.arguments.contains(where:{$0.hasPrefix("--diagnose-wechat-enhanced=")})
    static let targetAXDiagnostic = enhancedDiagnostic || CommandLine.arguments.contains("--diagnose-front-focus") || CommandLine.arguments.contains(where:{$0.hasPrefix("--diagnose-wechat-ax=")})
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let configStore: ConfigStore
    let input: InputSourceController
    let hotkey: HotkeyCenter
    let listenTrigger: ListenTrigger
    let pipeline: VoicePipeline
    /// Local developer API (loopback only, off unless the user turns it on).
    lazy var localAPI = LocalAPIService(pipeline: pipeline)
    /// Screenshot + OCR. The hotkey is optional and unassigned by default; the menu and Settings can always start a capture.
    let screenshot = ScreenshotController()
    let screenshotHotkey = ScreenshotHotkey(id: 1)
    let ocrHotkey = ScreenshotHotkey(id: 2)

    private var statusItem: NSStatusItem?
    private var menu = NSMenu()
    private var diagnoseGlobal: Any?
    private var diagnoseLocal: Any?
    private var captureIsDiagnose = false
    private var diagnoseLines: [String] = []
    private var diagnoseCount = 0
    private var diagnoseLabel: NSTextField?
    private var capturedSpec: HotkeySpec?
    let capsule = CapsuleWindowController()
    private var onboardingWindow: OnboardingWindowController?
    var settingsWindow: SettingsWindowController?
    private var menuTarget: FocusIdentity?
    private var menuTracking = false
    private var sleepObserver:NSObjectProtocol?
    private var permissionObserver:NSObjectProtocol?
    private var languageObserver:NSObjectProtocol?
    private var accessibilityObserver:NSObjectProtocol?
    private var wechatDiagnosticWindow:WechatDiagnosticWindow?
    private let wechatContinueHotkey=WechatContinueHotkey()
    func openWechatDiagnostic(){
        if let existing=wechatDiagnosticWindow,existing.flow.state == .waiting || existing.flow.state == .running || existing.flow.state == .stopped{existing.present();return}
        let target=pipeline.diagnosticTarget
        let flow=WechatDiagnosticFlow(available:target != nil,validate:{target?.validate() ?? .invalid},make:{cancel in guard let target=target else{return nil};return NativeWechatEnhancedAdapter(pid:target.pid,cursorConfirmed:true,expectedTarget:target,stopRequested:{cancel.requested})},pause:{[weak self] paused in guard let self=self else{return};self.pipeline.inputSuspendedForDiagnostic=paused;if paused{self.listenTrigger.stop();self.hotkey.unregister()}else{self.finishEnhancedDiagnostic(true)}})
        let controller=WechatDiagnosticWindow(flow:flow,busy:{[weak self] in self?.pipeline.hasActiveSession ?? true},register:{[weak self] callback in guard let self=self else{return false};self.wechatContinueHotkey.callback=callback;return self.wechatContinueHotkey.register()},unregister:{[weak self] in self?.wechatContinueHotkey.remove()})
        controller.onState={[weak self,weak flow] in guard let self=self,let flow=flow else{return};if flow.state == .running{self.enhancedDiagnosticActive=true};if flow.state == .stopped{self.finishEnhancedDiagnostic(false)}}
        wechatDiagnosticWindow=controller;controller.present()
    }
    var enhancedDiagnosticActive=false,enhancedQuitPending=false
    let enhancedCancellation=EnhancedDiagnosticCancellation()
    func finishEnhancedDiagnostic(_ restored:Bool) {
        enhancedDiagnosticActive=false
        pipeline.inputSuspendedForDiagnostic = !restored
        if !restored {
            pipeline.note(L10n.tr("ui.c1580c347cd8"),isError:true)
            refreshStatus()
            Log.write("wechat-enhanced STOP restoration-unverified listener-remains-disabled=true do-not-retry=true")
        }
        if enhancedQuitPending {
            enhancedQuitPending=false
            if restored {if pipeline.hasActiveSession {pipeline.forceEnd(reason:"app-quit")};listenTrigger.stop();hotkey.unregister()}
            NSApp.reply(toApplicationShouldTerminate:restored)
        } else if restored {resumeAfterDiagnostic()}
    }


    init(configStore: ConfigStore, input: InputSourceController, hotkey: HotkeyCenter,
         listenTrigger: ListenTrigger, pipeline: VoicePipeline) {
        self.configStore = configStore
        self.input = input
        self.hotkey = hotkey
        self.listenTrigger = listenTrigger
        self.pipeline = pipeline
        super.init()
    }

    func startup() {
        AppearanceController.apply(configStore.config.appearanceMode)
        if LaunchMode.probeGlobal {
            probeGlobal = ProbeGlobalRunner(configStore: configStore, input: input)
            probeGlobal?.run()
            return
        }
        if LaunchMode.probe {
            applyHotkey()
            scheduleProbe()
            return
        }
        sleepObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main){[weak self] _ in self?.pipeline.forceEnd(reason:L10n.tr("ui.44a169431a26"))}
        accessibilityObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil,queue:.main){[weak self] _ in self?.capsule.accessibilityChanged();self?.settingsWindow?.accessibilityChanged()}
        KeychainStore.migrateLegacyLabels()
        KeychainStore.migrateAccessDescriptions()
        installApplicationMenu()
        // Permission changes, wake and unlock rebuild the shortcut listener; a stale one stops receiving keys silently.
        permissionObserver = NotificationCenter.default.addObserver(forName: .permissionsChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, !self.pipeline.hasActiveSession else { return }
            self.applyHotkey()
            Log.write("shortcut-listener rebuilt status=\(self.listenTrigger.status)")
        }
        PermissionWatcher.shared.start()
        localAPI.apply()
        UpdateChecker.shared.checkOnLaunchIfDue()
        languageObserver = NotificationCenter.default.addObserver(forName: .appLanguageChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.installApplicationMenu()
            self.settingsWindow?.window?.title = Brand.name
            self.settingsWindow?.refreshLanguage()
            self.onboardingWindow?.window?.title = L10n.format("ui.74320d268800", String(describing: Brand.name))
            self.refreshStatus()
            Log.write("language-changed selected=\(L10n.language)")
        }
        if IndicatorStyle.current == .character { CharacterAssets.prewarm() }
        menu.autoenablesItems = false
        menu.delegate = self
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = menuBarTemplateImage()
        item.button?.imagePosition = .imageOnly
        statusItem = item
        rebuildMenu()
        item.menu = menu
        if !configStore.config.hasSeenOnboarding && !LaunchMode.targetAXDiagnostic {
            showOnboarding()
        } else if !TermsAcceptance.accepted && !LaunchMode.targetAXDiagnostic {
            showOnboarding(termsOnly: true) // existing users review the current privacy notice and terms once
        }
        capsule.onCancel = { [weak self] in self?.pipeline.forceEnd(reason: L10n.tr("ui.434bcfa38480")) }
        capsule.onStop = { [weak self] in self?.pipeline.holdEnded() }
        capsule.onOpenResult = { [weak self] in
            guard let self=self else{return}
            self.capsule.hide()
            self.showSettings()
            DispatchQueue.main.async{[weak self] in self?.settingsWindow?.showRetainedResultReason()}
        }
        capsule.onPrivacy = { [weak self] in self?.showSettings();self?.showSwiftMain(.privacy) }
        capsule.onTargetHelp = { [weak self] in
            guard let self=self else{return};self.showSettings()
            let alert=NSAlert();alert.messageText=L10n.tr("ui.01dec732402b");alert.informativeText=self.pipeline.lastResult;alert.addButton(withTitle:L10n.tr("ui.de32e20193ad"));alert.runModal()
        }
        capsule.onRetry = { [weak self] in self?.pipeline.holdStarted(source: .menu, target: FocusProbe.snapshot()) }
        applyHotkey()
        // Permission requests are user actions in privacy/onboarding and depend on the chosen engine.
        Log.write("startup mode=\(configStore.config.mode) trigger=\(HotkeySpecDisplay.string(configStore.config.trigger)) diagnostic=\(HotkeySpecDisplay.string(configStore.config.diagnosticTrigger)) iflytekHotkey=\(HotkeySpecDisplay.string(configStore.config.iflytekVoiceHotkey)) configErrors=\(configStore.validationErrors.count)")
        Log.write("startup-bindings holdEnabled=\(configStore.config.holdShortcutEnabled) hold=\(HotkeySpecDisplay.string(configStore.config.trigger)) toggleEnabled=\(configStore.config.toggleShortcutEnabled) toggle=\(configStore.config.toggleTrigger.map(HotkeySpecDisplay.string) ?? "unset") listener=\(listenTrigger.status)")
        logBuildIdentity()
        fputs("[cadenza] startup-done, entering runloop\n", stderr)
    }

    private func installApplicationMenu() {
        let root=NSMenu();let appEntry=NSMenuItem();let appMenu=NSMenu(title:Brand.name);appEntry.submenu=appMenu;root.addItem(appEntry)
        @discardableResult func add(_ title:String,_ action:Selector,_ key:String="",target:AnyObject?=nil,to menu:NSMenu) -> NSMenuItem {
            let item=NSMenuItem(title:title,action:action,keyEquivalent:key);item.target=target;menu.addItem(item);return item
        }
        add(L10n.format("ui.0bf588b9906c", String(describing: Brand.name)),#selector(showAbout),target:self,to:appMenu)
        add(L10n.tr("ui.da9fc8ba9497"),#selector(showSettings),",",target:self,to:appMenu)
        appMenu.addItem(.separator())
        add(L10n.format("ui.68f78ab55303", String(describing: Brand.name)),#selector(NSApplication.hide(_:)),"h",target:NSApp,to:appMenu)
        let hideOthers=add(L10n.tr("ui.d32bd5a0edfe"),#selector(NSApplication.hideOtherApplications(_:)),"h",target:NSApp,to:appMenu);hideOthers.keyEquivalentModifierMask=[.command,.option]
        add(L10n.tr("ui.84941ac6e844"),#selector(NSApplication.unhideAllApplications(_:)),target:NSApp,to:appMenu)
        appMenu.addItem(.separator());add(L10n.format("ui.86a56484fcd8", String(describing: Brand.name)),#selector(NSApplication.terminate(_:)),"q",target:NSApp,to:appMenu)
        let editEntry=NSMenuItem(title:L10n.tr("ui.051836569928"),action:nil,keyEquivalent:"");let edit=NSMenu(title:L10n.tr("ui.051836569928"));editEntry.submenu=edit;root.addItem(editEntry)
        add(L10n.tr("ui.926a50b98ece"),Selector(("undo:")),"z",to:edit)
        let redo=add(L10n.tr("ui.03717b6f1070"),Selector(("redo:")),"z",to:edit);redo.keyEquivalentModifierMask=[.command,.shift]
        edit.addItem(.separator());add(L10n.tr("ui.410a8e8a6bf2"),#selector(NSText.cut(_:)),"x",to:edit);add(L10n.tr("ui.63d90d977348"),#selector(NSText.copy(_:)),"c",to:edit);add(L10n.tr("ui.335179267471"),#selector(NSText.paste(_:)),"v",to:edit);add(L10n.tr("ui.3a5040b68abf"),#selector(NSText.selectAll(_:)),"a",to:edit)
        let windowEntry=NSMenuItem(title:L10n.tr("ui.9efe01f647d6"),action:nil,keyEquivalent:"");let windows=NSMenu(title:L10n.tr("ui.9efe01f647d6"));windowEntry.submenu=windows;root.addItem(windowEntry)
        add(L10n.tr("ui.ac29e57a46f4"),#selector(NSWindow.performMiniaturize(_:)),"m",to:windows)
        add(L10n.tr("ui.f6b64b637ba7"),#selector(showSettings),target:self,to:windows)
        NSApp.mainMenu=root;NSApp.windowsMenu=windows
    }
    @objc private func showAbout() { showSwiftMain(.about) }

    private var probeGlobal: ProbeGlobalRunner?

    // --probe 窗口探针模式：panel-probe 工具消费 stdout 的 [probe] 行
    private var probeTimer: Timer?
    private func scheduleProbe() {
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            let wins = PanelObserver.iflytekWindows()
            fputs("[probe] windows=\(wins.count)\n", stdout)
            for w in wins.sorted() { fputs("[probe]   \(w)\n", stdout) }
            fflush(stdout)
        }
        RunLoop.main.add(t, forMode: .common)
        probeTimer = t
    }

    private func micStatusText() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return L10n.tr("ui.f1d6383ba4f6")
        case .denied, .restricted: return L10n.tr("ui.0c3677bcc7b3")
        default: return L10n.tr("ui.f62a6539e33a")
        }
    }

    private func speechStatusText() -> String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return L10n.tr("ui.f1d6383ba4f6")
        case .denied, .restricted: return L10n.tr("ui.0c3677bcc7b3")
        default: return L10n.tr("ui.f62a6539e33a")
        }
    }

    /// Retina-aware template logo, cached with 1x/2x/3x representations.
    private func menuBarTemplateImage() -> NSImage {MenuBarLogo.image}

    /// 构建身份一致性：记录运行中二进制路径、修改时间、bundle id 与两个用途声明的可见性
    private func logBuildIdentity() {
        let path = Bundle.main.executableURL?.path ?? "?"
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        let stamp = mtime.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
        let bid = Bundle.main.bundleIdentifier ?? "?"
        let micDesc = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
        let speechDesc = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
        Log.write("startup-identity pid=\(ProcessInfo.processInfo.processIdentifier) binary=\(path) mtime=\(stamp) bundleId=\(bid) micDesc=\(micDesc) speechDesc=\(speechDesc)")
    }

    func refreshStatus() {
        AppearanceController.apply(configStore.config.appearanceMode)
        guard let button = statusItem?.button else { return }
        let snapshot=menuSnapshot()
        button.image = snapshot.phase.keepsAppIcon ? menuBarTemplateImage():StatusMenuController.image(snapshot)
        button.toolTip=snapshot.header
        button.setAccessibilityLabel(Brand.name+" · "+snapshot.header)
        button.imagePosition = .imageOnly
        // 悬浮状态条一次只出现一条：录音/识别跟随会话；异常 6 秒后自收；成功即收起
        if let s = pipeline.session, s.mode == SessionMode.hold.rawValue {
            switch s.state {
            case .voiceStarted:
                capsule.showRecord(elapsed: ProcessInfo.processInfo.systemUptime-s.startedUptime, manual: s.source == .menu, shortcut: s.source == .hotkey ? HotkeySpecDisplay.string(configStore.config.trigger) : s.source == .toggle && configStore.config.toggleShortcutEnabled ? configStore.config.toggleTrigger.map(HotkeySpecDisplay.string) : nil, retentionHint:s.retentionReason, toggled:s.source == .toggle)
            case .awaitingConfirm:
                capsule.showRecognize()
            }
        } else if pipeline.lastIsError {
            capsule.showError(pipeline.lastResult,action:pipeline.resultAction)
        } else {
            capsule.hide()
        }
        settingsWindow?.refresh()
        onboardingWindow?.refresh()
        if !menuTracking { rebuildMenu() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuTarget = FocusProbe.snapshot()
        menuTracking = true
    }
    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuTracking = false
    }

    func inspectConfigurationActions() {
        let original = configStore.config
        defer { configStore.mutate { $0 = original }; configStore.save(); applyHotkey() }
        func invoke(_ menuTitle: String, _ value: String) -> Bool {
            guard let entry = menu.items.first(where: { $0.title == menuTitle })?.submenu?.items.first(where: { $0.representedObject as? String == value }), entry.isEnabled, let selector = entry.action else { return false }
            return NSApp.sendAction(selector, to: entry.target, from: entry)
        }
        func verify(_ name: String) {
            let saved = (try? Data(contentsOf: AppPaths.configFile)).flatMap { try? JSONDecoder().decode(BridgeConfig.self, from: $0) }
            let c = configStore.config
            let ok = saved?.engine == c.engine && saved?.microphoneUID == c.microphoneUID && saved?.inputMode == c.inputMode && settingsWindow?.controlsMatchConfiguration() == true
            Log.write("ui-config-action \(name) persisted-and-synced=\(ok)")
        }
        _ = invoke(L10n.tr("ui.8545bbfc5af9"), "apple"); verify("apple")
        _ = invoke(L10n.tr("ui.8545bbfc5af9"), "iflytek"); verify("iflytek")
        if let mic = Microphones.devices().first {
            _ = invoke(L10n.tr("ui.714cac30e2ff"), mic.uid); verify("selected-microphone")
        }
        _ = invoke(L10n.tr("ui.714cac30e2ff"), ""); verify("system-microphone")
        _ = invoke(L10n.tr("menu.trigger"), "hold"); verify("hold")
        _=invoke(L10n.tr("menu.trigger"),"toggle");verify("toggle");Log.write("ui-config-action unsupported-disabled=\(!invoke(L10n.tr("ui.8545bbfc5af9"),"local"))")
    }

    func inspectDualSave() {
        guard CGPreflightListenEventAccess() else {Log.write("dual-ui-check blocked listen-permission=false");return}
        showSettings()
        let h=HotkeySpec(keyCode:5,modifiers:UInt32(controlKey)|UInt32(shiftKey),modifierKeyCodes:[56,59])
        let t=HotkeySpec(keyCode:106,modifiers:0)
        settingsWindow?.inspectSaveBinding(mode:0,spec:h)
        Log.write("dual-ui-check hold-saved=\(configStore.config.trigger == h) controls=\(settingsWindow?.bindingControlsMatchConfiguration() == true)")
        settingsWindow?.inspectSaveBinding(mode:1,spec:t);settingsWindow?.inspectEnableBinding(mode:1)
        let saved=(try? Data(contentsOf:AppPaths.configFile)).flatMap{try? JSONDecoder().decode(BridgeConfig.self,from:$0)}
        Log.write("dual-ui-check both-persisted=\(saved?.trigger == h && saved?.toggleTrigger == t && saved?.toggleShortcutEnabled == true) controls=\(settingsWindow?.bindingControlsMatchConfiguration() == true) no-voice=\(!pipeline.hasActiveSession)")
    }
    func inspectPage(_ page: Int) { showSettings(); settingsWindow?.inspectPage(page) }
    func inspectShortcutRecording() { showSettings(); settingsWindow?.inspectShortcutRecording() }
    func inspectOnboarding(_ step: Int = 0) { showOnboarding(); onboardingWindow?.inspectStep(step) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !LaunchMode.probe && !LaunchMode.probeGlobal && !LaunchMode.targetAXDiagnostic { NSApp.activate(ignoringOtherApps: true) }
        startLocalModels()
        startScreenshotSupport()
        LegacyMigration.migrateKeychainInBackground()
    }

    private func startScreenshotSupport() {
        screenshot.settings = { [weak self] in self?.configStore.config.screenshot ?? ScreenshotSettings() }
        screenshot.canStart = { [weak self] in self?.pipeline.hasActiveSession != true }
        screenshot.onColorFormatChange = { [weak self] value in
            guard let self else { return }
            _ = self.configStore.mutate { $0.screenshot.colorFormat = value }; _ = self.configStore.save()
        }
        screenshotHotkey.onPress = { [weak self] in self?.startScreenshot() }
        ocrHotkey.onPress = { [weak self] in self?.startDirectOCR() }
        applyScreenshotHotkey()
    }

    @objc func startScreenshot() { screenshot.start(.interactive) }
    @objc func startFullScreenshot() { screenshot.start(.fullScreen) }
    @objc func startDelayedScreenshot(_ sender: NSMenuItem) { screenshot.start(.interactive, delay: TimeInterval(sender.tag)) }
    @objc func repeatScreenshot() { screenshot.start(.repeatLast) }
    @objc func startDirectOCR() { screenshot.start(.directOCR) }
    @objc func closeAllPins() { PinManager.shared.closeAll(); refreshStatus() }
    @objc func togglePinsHidden() { PinManager.shared.setHidden(!PinManager.shared.hidden); refreshStatus() }
    @objc func restorePinInteraction() { PinManager.shared.restoreInteraction(); refreshStatus() }

    /// 录制新快捷键期间暂停截图热键，避免按下旧组合时直接开始截图
    func setScreenshotHotkeyPaused(_ paused: Bool) {
        if paused { screenshotHotkey.unregister(); ocrHotkey.unregister() } else { applyScreenshotHotkey() }
    }

    func applyScreenshotHotkey() {
        let c = configStore.config
        func apply(_ hotkey: ScreenshotHotkey, _ spec: HotkeySpec?, other: HotkeySpec?) {
            guard let spec else { hotkey.unregister(); return }
            if hotkey.registered == spec { return }
            if spec == c.trigger || spec == c.toggleTrigger || spec == other { hotkey.unregister(); Log.write("screenshot-hotkey-skipped duplicate"); return }
            if !hotkey.register(spec) { pipeline.note(L10n.tr("screenshot.hotkey.failed") + hotkey.status, isError: true) }
        }
        apply(screenshotHotkey, c.screenshot.trigger, other: nil)
        apply(ocrHotkey, c.screenshot.ocrTrigger, other: c.screenshot.trigger)
    }

    /// 本地模型：网络状态、安装前加载自检、安装集合变化后的设置收敛、可选的静默更新检查
    private func startLocalModels() {
        NetworkReachability.shared.start()
        let center = LocalModelCenter.shared
        center.validator = { dir, entry in
            if LocalModelCatalog.isOCR(entry) { return PaddleOCREngine.validate(directory: dir) }       // 文字识别模型：检测、识别、字典必须配套
            return !LocalTranscriberLoader.supported || (try? LocalTranscriberLoader.load(dir: dir, entry: entry)) != nil
        }
        center.onChange = { [weak self] in
            LocalTranscriberCache.shared.unload()
            PaddleOCRCache.unload()
            self?.reconcileLocalModelSettings()
        }
        reconcileLocalModelSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !LocalOnlyMode.enabled, self.configStore.config.localModel.autoCheckUpdates, !center.installedEntries.isEmpty else { return }
            center.checkForUpdates(manifestURLs: LocalModelUpdates.manifestURLs(self.configStore.config.localModel))
        }
    }

    /// 删除/回滚模型后，把指向不存在模型的设置收回：本地引擎没有模型时退回 Apple Speech
    func reconcileLocalModelSettings() {
        let ready = Set(LocalModelCenter.shared.installedEntries.map(\.id))
        let c = configStore.config
        // 选中的本机文字识别模型被删除后，文字识别退回 Apple Vision
        if c.screenshot.ocrEngine == PaddleOCREngine.engineID && !ready.contains(c.screenshot.ocrLocalModel) {
            changeConfig { $0.screenshot.ocrEngine = "vision"; $0.screenshot.ocrLocalModel = "" }
        }
        guard (c.engine == ASREngine.local.rawValue && ready.isEmpty) || (!c.localModel.modelID.isEmpty && !ready.contains(c.localModel.modelID)) || (!c.localModel.primaryModelID.isEmpty && !ready.contains(c.localModel.primaryModelID)) else { refreshStatus(); return }
        changeConfig {
            if $0.engine == ASREngine.local.rawValue && ready.isEmpty { $0.engine = ASREngine.apple.rawValue }
            if !$0.localModel.modelID.isEmpty && !ready.contains($0.localModel.modelID) { $0.localModel.modelID = "" }
            if !$0.localModel.primaryModelID.isEmpty && !ready.contains($0.localModel.primaryModelID) { $0.localModel.primaryModelID = "" }
        }
        refreshStatus()
    }

    func inspectShortcutCancellation() {
        let original = configStore.config.trigger
        inspectShortcutRecording()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.settingsWindow?.inspectShortcutCancellation()
            Log.write("shortcut-ui-check cancelled-old-binding-preserved=\(self.configStore.config.trigger == original) no-voice-session=\(!self.pipeline.hasActiveSession) listener=\(self.listenTrigger.status)")
        }
    }
    func inspectShortcutSaveFailure() {
        let original = configStore.config.trigger
        showSettings(); settingsWindow?.inspectShortcutSaveFailure()
        Log.write("shortcut-ui-check save-attempt listen-permission=\(CGPreflightListenEventAccess()) old-binding-preserved=\(self.configStore.config.trigger == original) no-voice-session=\(!pipeline.hasActiveSession)")
    }
    func inspectCloudSynchronization() { showSettings(); Log.write("ui-check independent-cloud-controls-synced=\(settingsWindow?.inspectCloudSynchronization() == true)") }
    func inspectShortcutConflict() { showSettings(); settingsWindow?.inspectShortcutConflict() }
    func inspectMenu() {
        if let choice = CommandLine.arguments.first(where: { $0.hasPrefix("--inspect-menu=") })?.split(separator: "=").last,
           let title = ["engine":L10n.tr("ui.8545bbfc5af9"), "mode":L10n.tr("ui.47b2d56f0bf9"), "mic":L10n.tr("ui.714cac30e2ff")][String(choice)],
           let entry = menu.items.first(where: { $0.title == title }), let button = statusItem?.button {
            let rect = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
            if let submenu=entry.submenu {
                Log.write("native-menu-evidence choice=\(choice) submenu=true items=\(submenu.items.count)")
                _=submenu.popUp(positioning:submenu.items.first,at:NSPoint(x:rect.minX,y:rect.minY-120),in:nil)
            }
        } else { statusItem?.button?.performClick(nil) }
    }

    func inspectCapsule(_ state: String) {
        // Rendering inspection only; no audio is captured and no recognition result is fabricated.
        if state == "record" || state == "record-hover" { capsule.showRecord(elapsed: 0, shortcut: HotkeySpecDisplay.string(configStore.config.trigger)) }
        else if state == "recognize" { capsule.showRecognize() }
        else { capsule.showError(L10n.tr("ui.4a210beab2b9")) }
        if state == "record-hover" {capsule.inspectRecordingHover()}
    }

    func inspectWaveSequence(){listenTrigger.stop();capsule.inspectSequence{[weak self] in self?.resumeAfterDiagnostic()}}
    func inspectAppearance(){showSettings();settingsWindow?.inspectAppearancePreferences()}
    /// The engine submenu mirrors Settings → Recognition engine: installed local models first, then configured cloud
    /// services, then the Mac's built-in recognition. Nothing that cannot be used is listed, and a locked
    /// "never go online" setting leaves only local models. The selection key is `local:<model id>` for local models.
    static func engineMenuEntries(config c: BridgeConfig, localOnly: Bool = LocalOnlyMode.enabled, installed: [LocalModelEntry] = LocalModelCenter.shared.installedEntries.filter { LocalModelCatalog.usable($0) }) -> ([StatusMenuSnapshot.Entry], String) {
        var entries: [StatusMenuSnapshot.Entry] = [.init(title: L10n.tr("engine.section.local"), value: "", available: false, header: true)]
        for e in installed { entries.append(.init(title: e.name(), value: "local:" + e.id, available: true)) }
        if installed.isEmpty { entries.append(.init(title: L10n.tr("engine.card.local.none"), value: "local:none", available: false)) }
        if !localOnly {
            let cloud = ASREngine.allCases.filter { $0 != .apple && $0 != .local && $0.configured }
            if !cloud.isEmpty {
                entries.append(.init(title: L10n.tr("engine.section.cloud"), value: "", available: false, header: true))
                for e in cloud { entries.append(.init(title: e.title, value: e.rawValue, available: true)) }
            }
            entries.append(.init(title: L10n.tr("engine.section.system"), value: "", available: false, header: true))
            entries.append(.init(title: L10n.tr("engine.system.title"), value: ASREngine.apple.rawValue, available: true))
        }
        var selected = c.engine
        if c.engine == ASREngine.local.rawValue {
            let pick = FallbackPolicy.resolvePrimary(settings: c.localModel, ready: installed, recognitionLocale: c.recognitionLocale)
            selected = "local:" + (pick?.id ?? "none")
        }
        return (entries, selected)
    }
    private func menuSnapshot() -> StatusMenuSnapshot {
        let c=configStore.config,engine=ASREngine(rawValue:configStore.config.engine) ?? .apple
        var s=StatusMenuSnapshot()
        s.engine=c.engine;s.mode=c.inputMode;s.microphone=c.microphoneUID
        s.toggleAvailable=c.toggleTrigger != nil
        s.shortcut=c.inputMode == "toggle" ? (c.toggleShortcutEnabled ? c.toggleTrigger.map(HotkeySpecDisplay.string) ?? "":""):(c.holdShortcutEnabled ? HotkeySpecDisplay.string(c.trigger):"")
        s.hasResult=pipeline.lastTranscript?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == false
        s.busy=pipeline.hasActiveSession || pipeline.inputSuspendedForDiagnostic
        s.screenshotShortcut=c.screenshot.trigger.map(HotkeySpecDisplay.string) ?? ""
        s.ocrShortcut=c.screenshot.ocrTrigger.map(HotkeySpecDisplay.string) ?? ""
        s.pinCount=PinManager.shared.count;s.pinsHidden=PinManager.shared.hidden;s.pinsClickThrough=PinManager.shared.anyClickThrough
        (s.engines,s.engine)=Self.engineMenuEntries(config:c)
        let devices=Microphones.devices()
        s.microphones=[.init(title:L10n.tr("ui.04b77083689b"),value:"",available:true)]+devices.map{.init(title:$0.name,value:$0.uid,available:true)}
        if !c.microphoneUID.isEmpty && !devices.contains(where:{$0.uid==c.microphoneUID}) {s.microphones.append(.init(title:L10n.tr("menu.disconnected"),value:c.microphoneUID,available:false))}
        if let session=pipeline.session {
            s.phase=session.state == .voiceStarted ? .recording(Int(max(0,ProcessInfo.processInfo.systemUptime-session.startedUptime))):.recognizing
        } else if !c.enabled {s.phase = .paused}
        else if pipeline.inputSuspendedForDiagnostic {s.phase = .issue(.unavailable)}
        else {
            let recognizer=SFSpeechRecognizer(locale:Locale(identifier:c.recognitionLocale))
            // A disabled shortcut still permits explicit menu recording.
            let ready=SettingsReadiness.evaluate(microphone:HoldNativeEngine.micAuthorized(),speech:HoldNativeEngine.speechAuthorized(),accessibility:FocusProbe.accessibilityTrusted,monitoring:s.shortcut.isEmpty || PermissionProbe.monitorGranted,configured:engine.configured,consent:engine == .apple || engine == .local || c.options(engine).consent,engineAvailable:configStore.validationErrors.isEmpty && (engine != .local || LocalTranscriberLoader.supported) && (c.microphoneUID.isEmpty || devices.contains{$0.uid==c.microphoneUID}) && (engine != .apple || (recognizer?.isAvailable == true && (c.allowCloudRecognition || recognizer?.supportsOnDeviceRecognition == true))),shortcutEnabled:true,systemEngine:engine == .apple)
            s.phase=ready == .ready ? (pipeline.lastIsError ? .previousError:.idle):.issue(ready)
        }
        return s
    }
    private func rebuildMenu() {
        let snapshot=menuSnapshot()
        StatusMenuController.rebuild(menu,s:snapshot,target:self)
        statusItem?.button?.image=snapshot.phase.keepsAppIcon ? menuBarTemplateImage():StatusMenuController.image(snapshot)
        statusItem?.button?.toolTip=snapshot.header
        statusItem?.button?.setAccessibilityLabel(Brand.name+" · "+snapshot.header)
    }
    func menuNeedsUpdate(_ menu:NSMenu) {if menu === self.menu {rebuildMenu()}}
    @objc private func copyLastRecognition() {
        guard !pipeline.hasActiveSession,let text=pipeline.lastTranscript,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{return}
        NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)
    }
    @objc private func resolveMenuIssue() {
        let s=menuSnapshot()
        guard case .issue(let reason)=s.phase else {showSettings();return}
        switch reason {
        case .microphone: NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        case .speech: NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!)
        case .accessibility: NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        case .monitoring: NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        case .credentials,.consent:showEngineSettings()
        default:showSettings()
        }
    }

    @objc private func menuRecording() {
        if pipeline.session?.state == .voiceStarted { pipeline.holdEnded(); return }
        guard menuSnapshot().canRecord,!pipeline.hasActiveSession else{return}
        let target = menuTarget
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.menuSnapshot().canRecord,!self.pipeline.hasActiveSession else{return}
            self.pipeline.holdStarted(source: .menu, target: target)
        }
    }
    @objc private func cancelRecording() { pipeline.forceEnd(reason: L10n.tr("ui.3144ee77f24d")) }
    private func changeConfig(_ body: (inout BridgeConfig) -> Void) {
        guard !pipeline.hasActiveSession,!pipeline.inputSuspendedForDiagnostic else { return }
        let original=configStore.config
        guard configStore.mutate(body),configStore.save() else {_=configStore.mutate{$0=original};pipeline.note(L10n.tr("ui.68f13dea1bd8"),isError:true);return}
        applyHotkey()
    }
    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        if value.hasPrefix("local:") {
            let id = String(value.dropFirst(6))
            guard LocalTranscriberLoader.supported, LocalModelCenter.shared.installedEntries.contains(where: { $0.id == id && LocalModelCatalog.usable($0) }) else { return }
            changeConfig { $0.engine = ASREngine.local.rawValue; $0.localModel.primaryModelID = id }
        } else if let engine = ASREngine(rawValue: value), engine.configured, !(LocalOnlyMode.enabled && engine != .local) {
            changeConfig { $0.engine = value }
        }
    }
    @objc private func selectInputMode(_ sender: NSMenuItem) { if let value = sender.representedObject as? String,["hold","toggle"].contains(value),value != "toggle" || configStore.config.toggleTrigger != nil { changeConfig { $0.inputMode = value;$0.holdShortcutEnabled=value == "hold";$0.toggleShortcutEnabled=value == "toggle" } } }
    @objc private func selectMicrophone(_ sender: NSMenuItem) { if let value = sender.representedObject as? String { changeConfig { $0.microphoneUID = value } } }
    @objc private func showShortcutSettings() { showSettings(); settingsWindow?.show(page: 2) }
    @objc private func showEngineSettings() { showSettings(); settingsWindow?.show(page: 1) }

    func handleHoldStart() {
        if pipeline.session?.state == .voiceStarted {pipeline.holdEnded();return}
        if onboardingWindow?.ownsInputFocus == true {onboardingWindow?.markTrialStarted()}
        pipeline.holdStarted(source:settingsWindow?.ownsInputFocus == true || onboardingWindow?.ownsInputFocus == true ? .button : .hotkey)
        if onboardingWindow?.ownsInputFocus == true {onboardingWindow?.captureTrialSession()}
    }
    func handleHoldEnd() {
        if pipeline.session?.source == .hotkey || pipeline.session?.source == .button {pipeline.holdEnded()}
    }
    func handleTogglePress() {
        if onboardingWindow?.ownsInputFocus == true && !pipeline.hasActiveSession {onboardingWindow?.markTrialStarted()}
        pipeline.togglePressed(localOnly:settingsWindow?.ownsInputFocus == true || onboardingWindow?.ownsInputFocus == true)
        if onboardingWindow?.ownsInputFocus == true {onboardingWindow?.captureTrialSession()}
    }
    private func activateBindings(_ c:BridgeConfig)->Bool {
        guard !pipeline.inputSuspendedForDiagnostic else{listenTrigger.stop();return false}
        return listenTrigger.startBindings(hold:c.holdShortcutEnabled ? c.trigger : nil,toggle:c.toggleShortcutEnabled ? c.toggleTrigger : nil,coordinated:c.triggerCoordinatorEnabled)
    }
    func resumeAfterDiagnostic() {
        guard !pipeline.inputSuspendedForDiagnostic else{listenTrigger.stop();hotkey.unregister();return}
        applyHotkey()
        Log.write("diagnostic-listening-restored status=\(listenTrigger.status) active-session=\(pipeline.hasActiveSession)")
    }
    private func applyHotkey() {
        applyScreenshotHotkey()
        hotkey.unregister()
        guard !pipeline.inputSuspendedForDiagnostic else{listenTrigger.stop();return}
        guard configStore.validationErrors.isEmpty else {listenTrigger.stop();refreshStatus();return}
        let c=configStore.config
        for binding in [c.holdShortcutEnabled ? c.trigger:nil,c.toggleShortcutEnabled ? c.toggleTrigger:nil].compactMap({$0}) {
            if let reason=ShortcutPolicy.reason(binding) {listenTrigger.stop();pipeline.note(L10n.tr("ui.b956c234bea2")+reason,isError:true);refreshStatus();return}
        }
        _=activateBindings(c)
        if LaunchMode.probe || LaunchMode.probeGlobal {_=hotkey.register(c.diagnosticTrigger,slot:.diagnostic)}
        refreshStatus()
    }
    private func saveShortcut(_ candidate:HotkeySpec)->String? {configureShortcut(mode:"hold",candidate:candidate,enabled:nil)}
    private func configureShortcut(mode:String,candidate:HotkeySpec?,enabled:Bool?)->String? {
        guard !pipeline.hasActiveSession,!pipeline.inputSuspendedForDiagnostic else{return L10n.tr("ui.e1513aa9be4e")}
        if let candidate=candidate {
            if let reason=ShortcutPolicy.reason(candidate){return reason}
            if let reason=ShortcutPolicy.registrationReason(candidate){return reason}
        }
        let original=configStore.config;var proposed=original
        if mode == "toggle" {proposed.toggleTrigger=candidate;if candidate == nil {proposed.toggleShortcutEnabled=false};if let enabled=enabled{proposed.toggleShortcutEnabled=enabled}}
        else {if let candidate=candidate{proposed.trigger=candidate};if let enabled=enabled{proposed.holdShortcutEnabled=enabled};proposed.triggerConsume=false}
        let errors=BridgeConfig.validate(proposed);guard errors.isEmpty else{return errors.joined(separator:"；")}
        var failure=L10n.tr("ui.5e211d63af42")
        let ok=DualBindingTransaction.commit(proposed,old:original,activate:activateBindings,persist:{ c in
            guard self.configStore.mutate({$0=c}),self.configStore.save() else {failure=L10n.tr("ui.68f13dea1bd8");return false};return true
        },restore:{c in _=self.configStore.mutate{$0=c}})
        refreshStatus();return ok ? nil:failure
    }

    private var triggerStatusText: String {
        listenTrigger.status
    }

    // MARK: - 菜单动作

    @objc private func toggleEnabled() {
        changeConfig{$0.enabled.toggle()}
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    @objc func showSettings() { showSettingsLegacy() }
    private func showSwiftMain(_ tab: MainTab?) { settingsWindow?.showSwift(tab) }
    @objc func showSettingsLegacy() {
        if settingsWindow == nil {
            let controller = SettingsWindowController()
            controller.pipeline = pipeline; controller.listenTrigger = listenTrigger; controller.configStore = configStore
            controller.onRequestPermissions = { [weak self, weak controller] in HoldNativeEngine.requestRequired(engine: self?.configStore.config.engine ?? "apple") { _ in controller?.refresh() } }
            controller.onConfigurationChanged = { [weak self] in self?.applyHotkey();self?.refreshStatus() }
            controller.onWechatDiagnostic = { [weak self] in self?.openWechatDiagnostic() }
            controller.onShowOnboarding = { [weak self] in self?.showOnboarding() }
            controller.onBeginShortcutRecording = { [weak self] in self?.hotkey.unregister(); self?.listenTrigger.stop() }
            controller.onEndShortcutRecording = { [weak self] in self?.applyHotkey() }
            controller.onSaveModeShortcut = { [weak self] mode,candidate,enabled in guard let self=self else{return L10n.tr("ui.b0b8f1b0d9b3")};return self.configureShortcut(mode:mode,candidate:candidate,enabled:enabled) }
            controller.onSaveShortcut = { [weak self] candidate in guard let self = self else { return L10n.tr("ui.b0b8f1b0d9b3") }; return self.saveShortcut(candidate) }
            settingsWindow = controller
        }
        settingsWindow?.showSwift(nil)
    }

    private func showOnboarding(termsOnly: Bool = false) {
        if let window = onboardingWindow?.window, window.isVisible { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let wc = OnboardingWindowController(configStore: configStore, pipeline: pipeline, termsOnly: termsOnly, onSettings: { [weak self] in self?.showEngineSettings() }, onConfigurationChanged: { [weak self] in self?.refreshStatus() }, onDone: { [weak self] in
            guard let self = self else { return }
            self.configStore.mutate { $0.hasSeenOnboarding = true }
            self.configStore.save()
            Log.write("onboarding-done")
        })
        onboardingWindow = wc
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showOnboardingAction() {
        showOnboarding()
    }

    @objc private func noop() {}

    @objc private func reloadConfig() {
        let ok = configStore.reload()
        Log.write("config-reload ok=\(ok) errors=\(configStore.validationErrors.joined(separator: ";"))")
        applyHotkey()
    }

    @objc private func editConfig() {
        configStore.save()
        pipeline.note(L10n.tr("ui.2dbb9d0088ae"))
        NSWorkspace.shared.open(AppPaths.configFile)
        refreshStatus()
    }

    @objc private func openTestField() {
        if FileManager.default.fileExists(atPath: AppPaths.testField.path) {
            NSWorkspace.shared.open(AppPaths.testField)
        } else {
            let alert = NSAlert()
            alert.messageText = L10n.format("ui.1de3fd4c69c6", String(describing: AppPaths.testField.path))
            alert.runModal()
        }
    }

    @objc private func openLogDir() {
        NSWorkspace.shared.open(AppPaths.supportDir)
    }

    /// 权限准备独立化：集中申请麦克风/语音识别，不占用按住流程
    @objc private func requestPermissions() {
        Log.write("permission-request manual mic=\(HoldNativeEngine.micAuthorized()) speech=\(HoldNativeEngine.speechAuthorized())")
        HoldNativeEngine.requestRequired(engine: configStore.config.engine) { [weak self] ok in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.pipeline.note(ok ? L10n.tr("ui.5abeec692e22") : L10n.tr("ui.537341b04edc"))
                Log.write("permission-request-result ok=\(ok) process-alive")
                self.refreshStatus()
            }
        }
        refreshStatus()
    }

    // MARK: - 会话收尾（停用/退出路径，如实提示录音状态未知）

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if wechatDiagnosticWindow?.flow.requestTermination() == .refuse{return .terminateCancel}
        if enhancedDiagnosticActive {
            enhancedQuitPending=true;enhancedCancellation.request();wechatDiagnosticWindow?.flow.cancel()
            Log.write("wechat-enhanced quit-deferred=true cleanup-required=true")
            return .terminateLater
        }
        wechatDiagnosticWindow?.flow.cancel();wechatContinueHotkey.remove()
        if pipeline.hasActiveSession { pipeline.forceEnd(reason: "app-quit") }
        localAPI.shutdown()
        listenTrigger.stop(); hotkey.unregister()
        return .terminateNow
    }

}

// MARK: - 程序引导
LegacyMigration.runFileAndPreferenceMigration()   // 必须在读取设置之前：把改名前的文件夹和偏好设置搬过来
let configStore = ConfigStore()
let input = InputSourceController()
let hotkey = HotkeyCenter()
let listenTrigger = ListenTrigger()
let pipeline = VoicePipeline(configStore: configStore, input: input)
let delegate = AppDelegate(configStore: configStore, input: input, hotkey: hotkey, listenTrigger: listenTrigger, pipeline: pipeline)
let triggerCoordinator=TriggerCoordinator(store:configStore,pipeline:pipeline)
listenTrigger.onCoordinatedEvent={triggerCoordinator.handle($0)}
fputs("[cadenza] context-ready\n", stderr)

hotkey.onPress = { pipeline.triggerFired() }
listenTrigger.onPress = { pipeline.triggerFired() }
listenTrigger.onHoldStart = { delegate.handleHoldStart() }
listenTrigger.onHoldEnd = { delegate.handleHoldEnd() }
listenTrigger.onHoldChord = { pipeline.forceEnd(reason: L10n.tr("ui.4460c389c8a2")) }
listenTrigger.onTogglePress = { delegate.handleTogglePress() }
listenTrigger.onSleep = { pipeline.forceEnd(reason:L10n.tr("ui.44a169431a26")) }
listenTrigger.isToggleRecording = {pipeline.session?.source == .toggle && pipeline.session?.state == .voiceStarted}
listenTrigger.onCrossModeStop = {if pipeline.session?.state == .voiceStarted {pipeline.holdEnded()}}
pipeline.onStateChange = { delegate.refreshStatus() }
pipeline.onLevel = { [weak delegate] v in
    delegate?.settingsWindow?.pushLevel(v)
    delegate?.capsule.tick(elapsed:pipeline.session.map{ProcessInfo.processInfo.systemUptime-$0.startedUptime},level:v)
}

let app = NSApplication.shared
fputs("[cadenza] nsapp-ready\n", stderr)
app.delegate = delegate
app.setActivationPolicy(.regular)
fputs("[cadenza] policy-set\n", stderr)
delegate.startup()
if !LaunchMode.probe && !LaunchMode.probeGlobal && !LaunchMode.targetAXDiagnostic && (configStore.config.hasSeenOnboarding || CommandLine.arguments.contains("--show-main")) { delegate.perform(#selector(AppDelegate.showSettings)) }
if LaunchMode.enhancedDiagnostic {
    pipeline.inputSuspendedForDiagnostic=true
    delegate.listenTrigger.stop()
    let confirmed=CommandLine.arguments.contains("--confirmed-wechat-input-cursor")
    if confirmed,let pid=CommandLine.arguments.first(where:{$0.hasPrefix("--diagnose-wechat-enhanced=")})?.split(separator:"=").last.flatMap({Int32($0)}) {
        delegate.enhancedDiagnosticActive=true
        DispatchQueue.global(qos:.userInitiated).async {
            guard let adapter=NativeWechatEnhancedAdapter(pid:pid,cursorConfirmed:confirmed,stopRequested:{delegate.enhancedCancellation.requested}) else {
                Log.write("wechat-enhanced refused=original-target-preflight no-write=true")
                DispatchQueue.main.async{delegate.finishEnhancedDiagnostic(true)};return
            }
            let report=EnhancedAXTransaction.run(adapter,stopRequested:{delegate.enhancedCancellation.requested})
            DispatchQueue.main.async {
                delegate.finishEnhancedDiagnostic(report.restorationVerified)
            }
        }
    } else {
        Log.write("wechat-enhanced refused=explicit-cursor-confirmation-missing no-ax-write=true")
        delegate.finishEnhancedDiagnostic(true)
    }
}
// Enhanced mode is exclusive: inspection/insertion/probe flags cannot run beside it.
if !LaunchMode.enhancedDiagnostic {
if let pid=CommandLine.arguments.first(where:{$0.hasPrefix("--diagnose-wechat-ax=")})?.split(separator:"=").last.flatMap({Int32($0)}) {
    DispatchQueue.main.asyncAfter(deadline:.now()+0.5){TargetAXDiagnostics.wechat(pid:pid)}
}
// Read-only live metadata probe: no activation, audio, title/value reads or writes.
if CommandLine.arguments.contains("--diagnose-front-focus") {
    for i in 0..<5 {
        DispatchQueue.main.asyncAfter(deadline:.now()+Double(i)*0.5+0.5) {
            FocusProbe.trace(FocusProbe.snapshot(),stage:"live-readonly-\(i)",branch:"no-write")
            let fallback=ForegroundIdentity.resolve(skipApplicationForDiagnostic:true)
            Log.write("front-fallback-diagnostic primary-omitted=true no-write=true iteration=\(i) resolved=\(fallback.snapshot != nil) pid=\(fallback.snapshot?.pid ?? 0) failure=\(fallback.failure)")
        }
    }
}
if CommandLine.arguments.contains("--inspect-config-controls") { delegate.inspectConfigurationActions() }
if CommandLine.arguments.contains("--inspect-menu") || CommandLine.arguments.contains(where: { $0.hasPrefix("--inspect-menu=") }) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { delegate.inspectMenu() }
}
if let page = CommandLine.arguments.first(where: { $0.hasPrefix("--inspect-page=") })?.split(separator: "=").last.flatMap({ Int($0) }) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { delegate.inspectPage(page) } }
if CommandLine.arguments.contains("--inspect-dual-save") {DispatchQueue.main.asyncAfter(deadline:.now()+0.6){delegate.inspectDualSave()}}
if CommandLine.arguments.contains("--inspect-shortcut-recording") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { delegate.inspectShortcutRecording() } }
if CommandLine.arguments.contains("--inspect-onboarding") || CommandLine.arguments.contains(where: { $0.hasPrefix("--inspect-onboarding=") }) { let step = CommandLine.arguments.first(where: { $0.hasPrefix("--inspect-onboarding=") })?.split(separator: "=").last.flatMap { Int($0) } ?? 0; DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { delegate.inspectOnboarding(step) } }
if CommandLine.arguments.contains("--inspect-shortcut-cancel") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { delegate.inspectShortcutCancellation() } }
if CommandLine.arguments.contains("--inspect-shortcut-save-failure") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { delegate.inspectShortcutSaveFailure() } }
if CommandLine.arguments.contains("--inspect-cloud-controls") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { delegate.inspectCloudSynchronization() } }
if CommandLine.arguments.contains("--inspect-shortcut-conflict") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { delegate.inspectShortcutConflict() } }
if let state = CommandLine.arguments.first(where: { $0.hasPrefix("--inspect-capsule=") })?.split(separator: "=").last {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { delegate.inspectCapsule(String(state)) }
}
if CommandLine.arguments.contains("--inspect-switch-states") {DispatchQueue.main.asyncAfter(deadline:.now()+0.6){delegate.settingsWindow?.inspectSwitchStates()}}
if let value=CommandLine.arguments.first(where:{$0.hasPrefix("--inspect-asr-provider=")})?.split(separator:"=").last,let engine=ASREngine(rawValue:String(value)){delegate.listenTrigger.stop();delegate.pipeline.inputSuspendedForDiagnostic=true;DispatchQueue.main.asyncAfter(deadline:.now()+0.6){delegate.settingsWindow?.inspectASRSettings(engine)}}
if CommandLine.arguments.contains("--inspect-iflytek") {DispatchQueue.main.asyncAfter(deadline:.now()+0.6){delegate.settingsWindow?.inspectIflytekSelection()}}
if let stage=CommandLine.arguments.first(where:{$0.hasPrefix("--inspect-illustration=")})?.split(separator:"=").last {
    DispatchQueue.main.asyncAfter(deadline:.now()+0.9){delegate.settingsWindow?.inspectIllustration(String(stage))}
}
if CommandLine.arguments.contains("--inspect-illustration-sequence") {
    delegate.listenTrigger.stop()
    // Explicitly synthetic display evidence only; production has no oscillator.
    for start in [1.0,4.0,6.0] {
        for sample in 1..<12 {
            DispatchQueue.main.asyncAfter(deadline:.now()+start+Double(sample)*0.075){
                delegate.settingsWindow?.inspectIllustrationLevel(Float((sample*7)%11)/11)
            }
        }
    }
    for sample in 1..<12 {
        DispatchQueue.main.asyncAfter(deadline:.now()+2+Double(sample)*0.075){delegate.settingsWindow?.inspectIllustrationLevel(0)}
    }
    for (delay,stage) in [(1.0,"signal"),(2.0,"silence"),(3.0,"recognize"),(4.0,"signal"),(5.0,"cancel"),(6.0,"signal"),(7.0,"stop"),(8.0,"complete")] {
        DispatchQueue.main.asyncAfter(deadline:.now()+delay){
            delegate.settingsWindow?.inspectIllustration(stage)
            if stage == "complete" {delegate.refreshStatus();delegate.resumeAfterDiagnostic()}
        }
    }
}
if CommandLine.arguments.contains("--inspect-wave-sequence"){DispatchQueue.main.asyncAfter(deadline:.now()+0.6){delegate.inspectWaveSequence()}}
if CommandLine.arguments.contains("--inspect-appearance-choices"){DispatchQueue.main.asyncAfter(deadline:.now()+0.6){delegate.inspectAppearance()}}
if CommandLine.arguments.contains("--inspect-minimum"){DispatchQueue.main.asyncAfter(deadline:.now()+0.8){delegate.settingsWindow?.inspectSize(true)}}
if CommandLine.arguments.contains("--inspect-expanded"){DispatchQueue.main.asyncAfter(deadline:.now()+0.8){delegate.settingsWindow?.inspectSize(false)}}
if CommandLine.arguments.contains("--inspect-ui-evidence") {
    DispatchQueue.main.asyncAfter(deadline:.now()+1){Log.write("native-ui-evidence "+(delegate.settingsWindow?.layoutEvidence() ?? "no-window"))}
}
InsertionDiagnostics.productionEntry={text,done in
    // Programmatic invocation of the real global-listener callbacks and pipeline.
    // Only the recorder is replaced; focus probing and insertion remain production.
    final class DiagnosticRecorder:HoldRecordingSession {
        var onLevel:((Float)->Void)?;var onPartial:((String)->Void)?;var onFinal:((String?)->Void)?
        var lastError:String?;func begin()->Bool {true};func end(){};func abort(){}
    }
    let original=pipeline.recorderFactory
    let originalInsertion=pipeline.insertText
    if CommandLine.arguments.contains("--diagnose-unicode-insertion") {pipeline.insertText={TextInserter.sendUnicode($0,target:$1)}}
    let recorder=DiagnosticRecorder()
    pipeline.recorderFactory={recorder}
    listenTrigger.onHoldStart?()
    let source=pipeline.session?.source
    listenTrigger.onHoldEnd?()
    recorder.onFinal?(text)
    DispatchQueue.main.asyncAfter(deadline:.now()+0.2){
        let accepted=pipeline.lastInputAccepted
        Log.write("production-entry-check programmatic-events=true source-hotkey=\(source == .hotkey) retained=\(pipeline.resultAction == .result) transcript-length=\(pipeline.lastTranscript?.count ?? 0) resources-idle=\(pipeline.resourcesIdle) accepted=\(accepted)")
        pipeline.recorderFactory=original;pipeline.insertText=originalInsertion
        done(accepted)
    }
}
InsertionDiagnostics.onFinished={delegate.resumeAfterDiagnostic()}
if CommandLine.arguments.contains("--diagnose-insertion-suite") {listenTrigger.stop();DispatchQueue.main.asyncAfter(deadline:.now()+0.5){InsertionDiagnostics.native(waitForFocus:true,afterVerified:{InsertionDiagnostics.thirdParty()})}}
if CommandLine.arguments.contains("--diagnose-native-insertion") {listenTrigger.stop();DispatchQueue.main.asyncAfter(deadline:.now()+0.5){InsertionDiagnostics.native()}}
if CommandLine.arguments.contains("--diagnose-textedit-insertion") || CommandLine.arguments.contains("--diagnose-unicode-insertion") {listenTrigger.stop();DispatchQueue.main.asyncAfter(deadline:.now()+0.5){InsertionDiagnostics.thirdParty()}}
}
app.run()
