import SwiftUI
import AppKit
import AVFoundation
import Speech

// MARK: - 模型

enum MainTab: String, CaseIterable, Identifiable, Hashable {
    case input, engines, ocr, shortcuts, general, privacy, developer, about
    var id: String { rawValue }
    /// The Developer page is for people who ask for it (Settings → General → Advanced).
    static func visible(showDeveloper: Bool) -> [MainTab] { allCases.filter { $0 != .developer || showDeveloper } }
    var title: String { switch self { case .input: L10n.tr("ui.2087c777c06f"); case .engines: L10n.tr("ui.8545bbfc5af9"); case .ocr: L10n.tr("ocr.title"); case .shortcuts: L10n.tr("ui.ee2638183d3e"); case .general: L10n.tr("general.title"); case .privacy: L10n.tr("ui.86651d17a401"); case .developer: L10n.tr("developer.title"); case .about: L10n.tr("ui.52d25a9e30ba") } }
    var icon: String { switch self { case .input: "mic"; case .engines: "cpu"; case .ocr: "text.viewfinder"; case .shortcuts: "keyboard"; case .general: "gearshape"; case .privacy: "checkmark.shield"; case .developer: "curlybraces"; case .about: "info.circle" } }
}

enum EngineScope: String, CaseIterable, Identifiable {
    case system, local, cloud
    var id:String{rawValue}
    var title:String{L10n.tr("engine."+rawValue)}
}

extension ASREngine: Identifiable { public var id: String { rawValue } }

enum TryState { case idle, listening, recognizing, result, error }

@Observable
final class SettingsModel {
    var tab: MainTab = .input
    var scope: EngineScope = .system
    /// Set by the preview renderer to show a specific tab; the page reads it once.
    var requestedEngineTab: EngineTab?
    var compare: VoiceCompare?
    var showingCompare = false
    /// Models that the voice comparison can use (installed, usable, covering the app's language).
    var compareCandidates: [LocalModelEntry] { LocalTranscriberLoader.supported ? VoiceCompare.candidates(locale: store?.config.recognitionLocale ?? "zh-CN") : [] }
    func openCompare() {
        guard !listening, !recognizing else { return }
        let cfg = store?.config
        let locale = cfg?.recognitionLocale ?? "zh-CN"
        let models = compareCandidates
        guard !models.isEmpty else { return }
        compare = VoiceCompare(prompts: VoiceCompare.prompts(forLocale: locale), models: models, microphoneUID: cfg?.microphoneUID ?? "",
                               loader: VoiceCompareLoader.make(options: cfg?.localModel.recognition ?? LocalRecognitionOptions(), locale: locale))
        showingCompare = true
    }
    var engine: ASREngine = .apple
    var languageIndex = 0
    var allowCloud = false
    var consent = false
    var credentialsConfigured = false
    var localSettings = LocalModelSettings()
    var micAuthorized = false
    var axAuthorized = false
    var level: Float = 0
    var listening = false
    var recognizing = false
    var elapsed: TimeInterval = 0
    var resultText = ""
    var hasResult = false
    var lastMessage = ""
    var lastIsError = false
    var testResult = ""
    var copied = false
    var holdBinding = ""
    var toggleBinding = ""
    var inputModeIndex = 0
    let previewReadOnly=CommandLine.arguments.contains(where:{$0.hasPrefix("--preview-brand-page=")})
    var configuring: ASREngine?
    var onSettingsChanged: (() -> Void)?
    var speechAuthorized = false
    var monitorAuthorized = false
    var monitorStale = false
    var screenAuthorized = false
    var screenshotBinding = ""
    var screenshotSettings = ScreenshotSettings()
    var configuringOCR: OCRProvider?
    /// 预览/自检时替换配置草稿
    @ObservationIgnored var ocrDraftFactory: ((OCRProvider) -> OCRProviderDraft)?
    var ocrBinding = ""
    var onStartScreenshot: (() -> Void)?
    /// true = 开始录制新的截图快捷键（暂停旧热键），false = 结束
    var onScreenshotRecording: ((Bool) -> Void)?
    var appearanceMode="system"
    var engineAvailable = true
    var shortcutEnabled = true
    var toggleAvailable = false
    var onOpenEngineSettings: ((ASREngine) -> Void)?
    var onEditShortcut:((String)->Void)?
    var providerDraftFactory:((ASREngine)->ProviderSettingsDraft)?
    weak var store: ConfigStore?
    weak var pipeline: VoicePipeline?
    var localAPI: LocalAPIService?
    /// Bumped when the app language changes so every view re-reads its text.
    var languageRevision = 0
    private var languageObserver: NSObjectProtocol?

    init(store: ConfigStore, pipeline: VoicePipeline) {
        self.store = store; self.pipeline = pipeline
        sync(); scope = engine == .apple ? .system : (engine == .local ? .local : .cloud)
        languageObserver = NotificationCenter.default.addObserver(forName: .appLanguageChanged, object: nil, queue: .main) { [weak self] _ in self?.languageRevision += 1 }
    }

    /// 从真实配置/管线同步
    func sync() {
        guard let store else { return }
        let cfg = store.config
        appearanceMode=cfg.appearanceMode
        engine = ASREngine(rawValue: cfg.engine) ?? .apple
        localOnlyOn = LocalOnlyMode.enabled
        if engine != .apple && engine != .local { UserDefaults.standard.set(engine.rawValue, forKey: Self.lastCloudKey) }
        allowCloud = cfg.allowCloudRecognition
        localSettings = cfg.localModel
        consent = cfg.options(engine).consent
        credentialsConfigured = engine.configured
        languageIndex = cfg.iflytekLanguage == "en_us" ? 1 : (cfg.iflytekLanguage == "auto" ? 2 : 0)
        inputModeIndex = cfg.inputMode == "toggle" ? 1 : 0
        holdBinding = HotkeySpecDisplay.string(cfg.trigger)
        toggleBinding = cfg.toggleTrigger.map { HotkeySpecDisplay.string($0) } ?? L10n.tr("ui.2f5f1d6fbfb0")
        let t = pipeline?.lastTranscript ?? ""
        resultText = t
        hasResult = !t.isEmpty
        lastMessage = pipeline?.lastResult ?? ""
        lastIsError = pipeline?.lastIsError ?? false
        listening = pipeline?.session?.state == .voiceStarted
        recognizing = pipeline?.session?.state == .awaitingConfirm
        micAuthorized = HoldNativeEngine.micAuthorized()
        axAuthorized = FocusProbe.accessibilityTrusted
        speechAuthorized = HoldNativeEngine.speechAuthorized()
        let monitor = PermissionProbe.monitor()
        monitorAuthorized = monitor == .granted
        monitorStale = monitor == .stale
        screenAuthorized = ScreenCapturePermission.granted
        screenshotBinding = cfg.screenshot.trigger.map { HotkeySpecDisplay.string($0) } ?? ""
        screenshotSettings = cfg.screenshot
        ocrBinding = cfg.screenshot.ocrTrigger.map { HotkeySpecDisplay.string($0) } ?? ""
        let recognizer = SFSpeechRecognizer(locale:Locale(identifier:cfg.recognitionLocale))
        engineAvailable = (engine != .apple || (recognizer?.isAvailable == true && (cfg.allowCloudRecognition || recognizer?.supportsOnDeviceRecognition == true))) && (engine != .local || LocalTranscriberLoader.supported)
        shortcutEnabled = cfg.enabled && (cfg.inputMode == "toggle" ? cfg.toggleShortcutEnabled && cfg.toggleTrigger != nil : cfg.holdShortcutEnabled)
        toggleAvailable = cfg.toggleTrigger != nil
    }

    func tick() {
        if listening, let s = pipeline?.session { elapsed = ProcessInfo.processInfo.systemUptime - s.startedUptime }
    }

    var pageState: TryState {
        if listening { return .listening }
        if recognizing { return .recognizing }
        if hasResult { return .result }
        if lastIsError { return .error }
        return .idle
    }

    func persist(_ change:(inout BridgeConfig)->Void) {
        guard !previewReadOnly,let store,pipeline?.hasActiveSession != true else{return}
        let original=store.config
        guard store.mutate(change),store.save() else{_=store.mutate{$0=original};lastMessage=L10n.tr("ui.bcd8e5694934");lastIsError=true;return}
        onSettingsChanged?();sync()
    }
    /// The lock for people who never want audio to leave this Mac.
    func setLocalOnly(_ on: Bool) {
        guard !listening, !recognizing else { return }
        if on {
            let ready = LocalModelCenter.shared.installedEntries.filter { LocalModelCatalog.usable($0) }
            let pick = FallbackPolicy.resolvePrimary(settings: localSettings, ready: ready, recognitionLocale: store?.config.recognitionLocale ?? "en-US") ?? ready.first
            guard LocalTranscriberLoader.supported, let pick else { localOnlyMessage = L10n.tr("localonly.needModel"); localOnlyOn = false; return }
            LocalOnlyMode.enabled = true; localOnlyOn = true; localOnlyMessage = ""
            persist { $0.engine = ASREngine.local.rawValue; $0.localModel.primaryModelID = pick.id; $0.allowCloudRecognition = false }
            scope = .local
        } else {
            LocalOnlyMode.enabled = false; localOnlyOn = false; localOnlyMessage = ""
        }
    }
    func selectEngine(_ e: ASREngine) {
        if LocalOnlyMode.enabled && e != .local { return }
        guard e.configured else{openEngineSettings(e);return}
        guard e != engine else{return}
        persist{$0.engine=e.rawValue}
    }
    var engineScope: EngineScope { engine == .apple ? .system : (engine == .local ? .local : .cloud) }
    /// One sentence that says where audio goes and what happens if recognition fails.
    var recognitionSummary: String {
        switch engine {
        case .apple: return L10n.tr("mode.system")
        case .local:
            let ready = LocalModelCenter.shared.installedEntries.filter { LocalModelCatalog.usable($0) }
            let selected = FallbackPolicy.resolvePrimary(settings: localSettings, ready: ready, recognitionLocale: store?.config.recognitionLocale ?? "en-US")
            return L10n.format("mode.local", selected?.name() ?? L10n.tr("local.primary.unavailable"))
        default:
            let hasModel = LocalModelCenter.shared.installedEntries.contains { LocalModelCatalog.usable($0) }
            return L10n.format(localSettings.enabled && hasModel ? "mode.cloud.fallback" : "mode.cloud", engine.title)
        }
    }
    var primaryModelName: String {
        guard engine == .local else { return engine.title }
        let ready = LocalModelCenter.shared.installedEntries.filter { LocalModelCatalog.usable($0) }
        let selected = FallbackPolicy.resolvePrimary(settings: localSettings, ready: ready, recognitionLocale: store?.config.recognitionLocale ?? "en-US")
        return L10n.format("local.primary.name", selected?.name() ?? L10n.tr("local.primary.unavailable"))
    }
    func selectLocalModel(_ id: String, ready: [LocalModelEntry]) {
        guard !listening, !recognizing, LocalTranscriberLoader.supported,
              ready.contains(where: { $0.id == id && LocalModelCatalog.usable($0) }) else { return }
        persist { $0.engine = ASREngine.local.rawValue; $0.localModel.primaryModelID = id }
    }
    func setScope(_ s: EngineScope) { scope = s }
    /// 选择文字识别引擎；云端引擎必须先配置密钥并允许上传，否则打开配置窗口
    func selectOCREngine(_ id: String, hasCredentials: (OCRProvider) -> Bool = OCRCredentialStore.has) {
        if let provider = OCRProvider(rawValue: id), !(hasCredentials(provider) && screenshotSettings.ocrConsent[id] == true) { configuringOCR = provider; return }
        persist { $0.screenshot.ocrEngine = id }
    }
    func ocrDraft(_ provider: OCRProvider) -> OCRProviderDraft {
        if let factory = ocrDraftFactory { return factory(provider) }
        return OCRProviderDraft(provider: provider, settings: screenshotSettings, persist: { [weak self] p, consent, accurate, region in
            guard let self, let store = self.store, !self.previewReadOnly else { return false }
            let original = store.config
            guard store.mutate({ $0.screenshot.ocrConsent[p.rawValue] = consent; $0.screenshot.ocrAccurate[p.rawValue] = accurate; if p == .tencent { $0.screenshot.ocrTencentRegion = region } }), store.save() else { _ = store.mutate { $0 = original }; return false }
            self.onSettingsChanged?(); self.sync(); return true
        })
    }
    /// The recognition method picker: choosing a method switches the engine when it can (a configured provider,
    /// an installed local model). Otherwise the page shows what is needed, and local recognition turns on by itself
    /// once the model the user asked for is installed.
    var pendingLocalActivation = false
    var localOnlyOn = LocalOnlyMode.enabled
    var showDeveloper = DeveloperPageVisibility.current
    func setShowDeveloper(_ on: Bool) {
        DeveloperPageVisibility.set(on); showDeveloper = on
        if !on && tab == .developer { tab = .general }
    }
    var localOnlyMessage = ""
    private static let lastCloudKey = "lastCloudEngine"
    var lastCloudEngine: ASREngine? {
        UserDefaults.standard.string(forKey: Self.lastCloudKey).flatMap(ASREngine.init(rawValue:)).flatMap { $0 != .apple && $0 != .local ? $0 : nil }
    }
    func chooseScope(_ s: EngineScope) {
        if LocalOnlyMode.enabled && s != .local { return } // locked to local recognition
        scope = s
        guard !listening, !recognizing else { return }
        pendingLocalActivation = false
        switch s {
        case .system:
            if engine != .apple { persist { $0.engine = ASREngine.apple.rawValue } }
        case .cloud:
            guard engineScope != .cloud else { return }
            let target = lastCloudEngine.flatMap { $0.configured ? $0 : nil } ?? ASREngine.allCases.first { $0 != .apple && $0 != .local && $0.configured }
            if let target { persist { $0.engine = target.rawValue } }
        case .local:
            guard engine != .local else { return }
            let ready = LocalModelCenter.shared.installedEntries.filter { LocalModelCatalog.usable($0) }
            let pick = FallbackPolicy.resolvePrimary(settings: localSettings, ready: ready, recognitionLocale: store?.config.recognitionLocale ?? "en-US") ?? ready.first
            if LocalTranscriberLoader.supported, let pick { selectLocalModel(pick.id, ready: ready) }
            else if LocalTranscriberLoader.supported { pendingLocalActivation = true }
        }
    }
    func activatePendingLocal(ready: [LocalModelEntry]) {
        guard pendingLocalActivation, scope == .local, engine != .local, let first = ready.first else { return }
        pendingLocalActivation = false
        selectLocalModel(first.id, ready: ready)
    }
    func setLanguage(_ i: Int) {
        _ = store?.mutate { c in
            c.iflytekLanguage = ["zh_cn", "en_us", "auto"][max(0, min(2, i))]
            if i < 2 { c.recognitionLocale = i == 0 ? "zh-CN" : "en-US" }
        }; store?.save(); sync()
    }
    func setAllowCloud(_ on: Bool) { _ = store?.mutate { $0.allowCloudRecognition = on }; store?.save(); sync() }
    func setInputMode(_ i: Int) {
        guard i == 0 || toggleAvailable else{sync();return}
        persist{$0.inputMode = i == 1 ? "toggle":"hold";$0.holdShortcutEnabled = i == 0;$0.toggleShortcutEnabled = i == 1}
    }
    func copy() {
        guard !previewReadOnly,let t = pipeline?.lastTranscript, !t.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.copied = false }
    }
    func clear() {guard !previewReadOnly else{return};pipeline?.clearTranscript();sync()}
    func cancelTry() {
        if pipeline?.session?.state == .voiceStarted { pipeline?.holdChord(reason: L10n.tr("ui.517daccd5094")) }
        else { pipeline?.forceEnd(reason: L10n.tr("ui.517daccd5094")) }
        sync()
    }
    func holdStart() {guard !previewReadOnly else{return};pipeline?.holdStarted(source:.button)}
    func holdEnd() { pipeline?.holdEnded() }
    func openEngineSettings(_ engine: ASREngine? = nil) { configuring = engine ?? self.engine }
    func providerDraft(_ engine:ASREngine)->ProviderSettingsDraft? {
        if let factory=providerDraftFactory{return factory(engine)}
        guard let store else{return nil}
        return ProviderSettingsDraft(store:store,engine:engine,busy:{[weak self] in self?.pipeline?.hasActiveSession == true},changed:{[weak self] in self?.onSettingsChanged?();self?.sync()})
    }


}

// MARK: - 公共组件

struct StatusBadge: View {
    enum Status { case active, configured, missing, attention }
    let status: Status
    var body: some View {
        switch status {
        case .active:
            Text(L10n.tr("ui.fa48e8938940")).font(.caption.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Color(nsColor: DesignTokens.jade), in: .capsule)
                .foregroundStyle(.white)
        case .configured:
            Label(L10n.tr("ui.de8184da1ef8"), systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
        case .missing:
            Text(L10n.tr("ui.80a57e03f071")).font(.callout).foregroundStyle(.secondary)
        case .attention:
            Label(L10n.tr("ui.b7e3e715f18b"), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        }
    }
}

struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(.callout, design: .rounded, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.quaternary, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }
}

struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Form { content }
            .formStyle(.grouped)

            .focusEffectDisabled()
    }
}

struct ProviderRow: View {
    let name: String
    let status: StatusBadge.Status
    let isSelected: Bool
    var showsConfigure: Bool = true
    var isConfigured:Bool {if case .missing=status{return false};return true}
    var onConfigure: () -> Void = {}
    var onSelect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment:.leading,spacing:4){
                Text(name).font(.body)
                Text(L10n.tr(isConfigured ? "ui.de8184da1ef8":"ui.80a57e03f071")).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if showsConfigure {
                Button(L10n.tr(isConfigured ? "ui.41eacd289721":"engine.configure"), action:onConfigure).buttonStyle(.bordered)
            }
            Button { onSelect() } label: {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
            }
            .buttonStyle(.plain).disabled(!isConfigured)
            .accessibilityLabel(L10n.format("engine.select",name)).accessibilityValue(isSelected ? L10n.tr("ui.fa48e8938940"):L10n.tr("engine.notSelected"))
            .help(L10n.tr("ui.9bbf329aa127"))
        }
        .frame(minHeight: 32)
    }
}

// MARK: - 主视图（NavigationSplitView 左侧栏）

struct MainSettingsView: View {
    @Bindable var model: SettingsModel
    @State private var parentHeight:CGFloat=560

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<MainTab?>(get: { model.tab }, set: { if let tab = $0 { model.tab = tab } })) {
                ForEach(MainTab.visible(showDeveloper: model.showDeveloper)) { tab in
                    // A dot inside the label, not .badge(): a badge on these rows stopped the sidebar from selecting anything when clicked.
                    Label {
                        HStack { Text(tab.title); if tab == .about && UpdateChecker.shared.available != nil { Spacer(); Text("●").foregroundStyle(.tint).accessibilityLabel(L10n.format("update.available",UpdateChecker.shared.available?.version ?? "")) } }
                    } icon: { Image(systemName: tab.icon) }.tag(tab)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            detailPage
                .navigationTitle(model.tab.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .sheet(isPresented: $model.showingCompare, onDismiss: { model.compare?.clear(); model.compare = nil }) {
            if let compare = model.compare { VoiceCompareView(compare: compare, model: model, close: { model.showingCompare = false }) }
        }
        .sheet(item: $model.configuring) { engine in
            if let draft=model.providerDraft(engine) {
                ProviderConfigSheet(draft:draft,availableHeight:ProviderSheetLayout.height(parentHeight:parentHeight,screenHeight:NSScreen.main?.visibleFrame.height ?? 900))
            }
        }
        .onGeometryChange(for:CGFloat.self){$0.size.height} action:{parentHeight=$0}
        .tint(Color(nsColor:.controlAccentColor))
        .preferredColorScheme(model.appearanceMode == "dark" ? .dark:model.appearanceMode == "light" ? .light:nil)
        .id(model.languageRevision)
    }

    @ViewBuilder private var detailPage: some View {
        switch model.tab {
        case .input: VoiceInputPage(model: model)
        case .engines: EngineSettingsView(model: model)
        case .ocr: OCRSettingsView(model: model)
        case .shortcuts: ShortcutsView(model: model)
        case .general: GeneralView(model: model)
        case .privacy: PrivacyView(model: model)
        case .developer: DeveloperView(model: model)
        case .about: AboutView()
        }
    }
}

// MARK: - 语音输入页（试说卡片 + 设置）

struct VoiceInputPage: View {
    @Bindable var model: SettingsModel
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsPage {
            Section { ReadinessBanner(model:model) }
            Section {
                TryCard(model:model)
            }
            Section {
                SummaryRow(title:L10n.tr("ui.8545bbfc5af9"),value:model.primaryModelName){model.scope = model.engineScope;model.tab = .engines}
                SummaryRow(title:L10n.tr("ui.3c7b79b73494"),value:model.inputModeIndex == 1 ? L10n.tr("ui.c3c686d13dc5"):L10n.tr("ui.e4947a64758a")){model.tab = .shortcuts}
                SummaryRow(title:L10n.tr("ui.ee2638183d3e"),value:model.inputModeIndex == 1 ? model.toggleBinding:model.holdBinding){model.tab = .shortcuts}
            } header:{Text(L10n.tr("settings.current"))}
        }
        .onExitCommand {if model.listening{model.cancelTry()}}
        .onReceive(timer){_ in model.tick();model.sync()}
    }
}
struct SummaryRow:View {
    let title:String,value:String
    var action:()->Void
    var body:some View {
        Button(action:action){HStack{Text(title);Spacer();Text(value).foregroundStyle(.secondary);Image(systemName:"chevron.right").font(.caption)}}.buttonStyle(.plain)
    }
}
struct ReadinessBanner:View {
    var model:SettingsModel
    var issue:SettingsReadiness {
        SettingsReadiness.evaluate(microphone:model.micAuthorized,speech:model.speechAuthorized,accessibility:model.axAuthorized,monitoring:model.monitorAuthorized,configured:model.credentialsConfigured,consent:model.engine == .apple || model.engine == .local || model.consent,engineAvailable:model.engineAvailable,shortcutEnabled:model.shortcutEnabled,systemEngine:model.engine == .apple)
    }
    var body:some View {
        HStack(alignment:.top,spacing:12){
            Image(systemName:issue == .ready ? "checkmark.circle.fill":"exclamationmark.triangle.fill").foregroundStyle(issue == .ready ? Color(nsColor:DesignTokens.accent):.orange)
            Text(issue == .ready ? L10n.format(model.inputModeIndex == 1 ? "ready.toggle":"ready.hold",model.inputModeIndex == 1 ? model.toggleBinding:model.holdBinding):L10n.tr("ready."+issue.rawValue)).frame(maxWidth:.infinity,alignment:.leading)
            if issue != .ready {Button(L10n.tr("ready.action")){model.tab=issue == .credentials || issue == .consent || issue == .unavailable ? .engines:issue == .shortcut ? .shortcuts:.privacy}.buttonStyle(.bordered)}
        }
        .accessibilityElement(children:.combine)
    }
}

struct TryCard: View {
    @Bindable var model: SettingsModel
    @State private var confirmingClear=false

    var modeName: String { model.inputModeIndex == 1 ? L10n.tr("ui.c3c686d13dc5") : L10n.tr("ui.e4947a64758a") }

    @ViewBuilder var resultArea: some View {
        switch model.pageState {
        case .listening:
            VStack(spacing: 6) {
                LiveRecordingIndicator(level: model.level)
                Text(L10n.format("ui.25c7831d1e7d", String(describing: Int(model.elapsed)))).font(.caption).foregroundStyle(.secondary)
            }
        case .recognizing:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L10n.tr("ui.09f0210af5ea")).foregroundStyle(.secondary) }
        case .result:
            ScrollView { Text(model.resultText).font(.title3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        case .error:
            Text(model.lastMessage).font(.system(size: 12)).foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .idle:
            Text(L10n.tr("trial.empty.result")).foregroundStyle(.secondary)
        }
    }

    var hint: some View {
        HStack(spacing: 6) {
            Text(L10n.format(model.inputModeIndex == 1 ? "trial.empty.toggle":"trial.empty.hold",model.inputModeIndex == 1 ? model.toggleBinding:model.holdBinding)).foregroundStyle(.secondary).font(.callout)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(L10n.tr("ui.2124b718a9a1")).font(.headline)
                Spacer()
                Text("\(model.primaryModelName) · \(modeName)").font(.caption).foregroundStyle(.secondary)
                if model.hasResult {
                    Button { model.copy() } label: { Label(L10n.tr("ui.63d90d977348"), systemImage: model.copied ? "checkmark" : "doc.on.doc") }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).help(model.copied ? L10n.tr("ui.8f6f8d979c98") : L10n.tr("ui.b93a1c638ab1"))
                    Button { confirmingClear=true } label: { Label(L10n.tr("ui.1ef3de06b32e"), systemImage: "trash") }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).help(L10n.tr("ui.dcb16807cb57"))
                }
            }
            Group { resultArea }
                .frame(height: model.hasResult ? 96 : 64).frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
            if model.hasResult && model.lastIsError {
                Text(model.lastMessage).font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                HoldToTalkButton(model: model)
                hint
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 8)
        .confirmationDialog(L10n.tr("clear.confirm"),isPresented:$confirmingClear){Button(L10n.tr("ui.bce2377283c2"),role:.destructive){model.clear()}}
    }
}

struct HoldToTalkButton: View {
    @Bindable var model: SettingsModel
    @State private var pressed = false

    var isActive: Bool { model.listening }
    var isRecognizing: Bool { model.recognizing }

    var body: some View {
        // The level meter above the button already shows the voice, so the button itself stays a plain microphone.
        Image(systemName: "mic.fill").font(.system(size: 22, weight: .medium))
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isActive)
        .foregroundStyle(isActive ? .white : .primary)
        .frame(width: 44, height: 44)
        .glassEffect(
            isActive ? .regular.tint(Color(nsColor: NSColor.controlAccentColor)).interactive() : .regular.interactive(),
            in: .circle
        )
        .opacity(isRecognizing ? 0.4 : 1)
        .help(isActive ? L10n.tr("ui.8832416c4895") : L10n.tr("ui.e4947a64758a"))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed, !isRecognizing, !model.listening else { return }
                    pressed = true; model.holdStart()
                }
                .onEnded { _ in
                    guard pressed else { return }
                    pressed = false; model.holdEnd()
                }
        )
    }
}

struct VoiceLevelBar: View {
    var level: Float
    var color: Color = Color(nsColor: .controlAccentColor)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<7, id: \.self) { i in
                let amp: CGFloat = 22 + CGFloat(i % 3) * 7
                let h = 4 + CGFloat(WaveformAppearance.displayLevel(level)) * amp
                Capsule().fill(color)
                    .frame(width: 4, height: h)
            }
        }
        .animation(reduceMotion ? nil:.easeOut(duration: 0.18), value: level)
    }
}

// MARK: - 语音识别页

/// Cloud service or Mac built-in engine as one row of the engine list.
private struct EngineRow: View {
    let title: String
    let subtitle: String
    let active: Bool
    let actionTitle: String
    let canAct: Bool // kept for callers; the button looks the same either way
    let action: () -> Void
    var onConfigure: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if active { Text(L10n.tr("engine.card.inuse")).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 2).background(Color.accentColor.opacity(0.15), in: Capsule()).foregroundStyle(Color.accentColor) }
            else { Button(actionTitle, action: action).buttonStyle(.bordered) }
            if let onConfigure { Button { onConfigure() } label: { Image(systemName: "gearshape") }.buttonStyle(.borderless).help(L10n.tr("engine.configure")) }
        }
        .padding(.vertical, 4)
    }
}

/// One list of everything that can recognize speech. Pick a row's button to use it; nothing switches by itself.
enum EngineTab: String, CaseIterable, Identifiable {
    case local, cloud, system, tuning
    var id: String { rawValue }
    var title: String { L10n.tr("engine.tab." + rawValue) }
    init(scope: EngineScope) { switch scope { case .local: self = .local; case .cloud: self = .cloud; case .system: self = .system } }
}

struct EngineSettingsView: View {
    @Bindable var model:SettingsModel
    let center = LocalModelCenter.shared
    @State private var deleting: LocalModelEntry?
    /// Only chooses what is shown. Choosing a tab never changes the engine in use.
    @State private var tab: EngineTab = .local

    private var localEntries: [LocalModelEntry] {
        func rank(_ e: LocalModelEntry) -> Int { e.id == LocalModelCatalog.recommendedID ? 0 : e.kind == "fire-red-ctc" ? 1 : 2 }
        return center.entries.sorted { rank($0) < rank($1) }
    }
    private var cloudEngines: [ASREngine] { ASREngine.allCases.filter { $0 != .apple && $0 != .local } }
    private var visibleTabs: [EngineTab] { model.localOnlyOn ? [.local, .tuning] : EngineTab.allCases }
    private var readyEntries: [LocalModelEntry] { center.installedEntries.filter { LocalModelCatalog.usable($0) } }

    var body:some View {
        SettingsPage {
            Section {
                LabeledContent(L10n.tr("engine.current")) { Text(model.primaryModelName).foregroundStyle(.secondary) }
                Toggle(L10n.tr("localonly.toggle"), isOn: Binding(get: { model.localOnlyOn }, set: { model.setLocalOnly($0); model.onSettingsChanged?() }))
                if !model.localOnlyMessage.isEmpty { Label(model.localOnlyMessage, systemImage: "info.circle").font(.callout).foregroundStyle(.orange) }
            } footer: { Text(L10n.tr("localonly.footer")).font(.callout).foregroundStyle(.secondary) }

            Section {
                Picker("", selection: $tab) { ForEach(visibleTabs) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity)
            }

            switch tab {
            case .local:
                Section {
                    ForEach(localEntries) { entry in
                        LocalModelRow(entry: entry, center: center, model: model, askDelete: { deleting = entry }, compact: true)
                    }
                    if !LocalTranscriberLoader.supported { Label(L10n.tr("local.err.unsupportedBuild"), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
                    if model.pendingLocalActivation && model.engine != .local {
                        Label(L10n.tr("local.pending"), systemImage: "arrow.down.circle").font(.callout).foregroundStyle(.secondary)
                    }
                } header: { Text(L10n.tr("engine.section.local")) } footer: { Text(L10n.tr("local.models.advice")).font(.callout).foregroundStyle(.secondary) }
                if !model.compareCandidates.isEmpty {
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.tr("compare.entry.title"))
                                Text(L10n.tr(model.compareCandidates.count > 1 ? "compare.entry.sub" : "compare.entry.subOne")).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(L10n.tr("compare.entry.button")) { model.openCompare() }.buttonStyle(.bordered).disabled(model.listening || model.recognizing)
                        }
                    }
                }
            case .cloud:
                Section {
                    ForEach(cloudEngines, id: \.self) { engine in
                        EngineRow(title: engine.title, subtitle: L10n.tr(engine.configured ? "engine.configured" : "engine.notConfigured"), active: model.engine == engine,
                                  actionTitle: L10n.tr(engine.configured ? "engine.use" : "engine.configure"), canAct: engine.configured,
                                  action: { model.selectEngine(engine) }, onConfigure: { model.openEngineSettings(engine) })
                    }
                } header: { Text(L10n.tr("engine.section.cloud")) }
                LocalFallbackSection(model: model)
            case .system:
                Section {
                    EngineRow(title: L10n.tr("engine.system.title"), subtitle: L10n.tr("engine.system.sub"), active: model.engine == .apple,
                              actionTitle: L10n.tr("engine.use"), canAct: true, action: { model.chooseScope(.system); model.onSettingsChanged?() })
                    if model.engine == .apple {
                        Toggle(L10n.tr("engine.appleCloud"), isOn: Binding(get: { model.allowCloud }, set: { value in model.persist { $0.allowCloudRecognition = value } })).font(.callout)
                    }
                } header: { Text(L10n.tr("engine.section.system")) }
            case .tuning:
                LocalTuningSections(model: model)
            }
        }
        .onAppear { tab = model.requestedEngineTab ?? EngineTab(scope: model.scope); model.requestedEngineTab = nil; if !visibleTabs.contains(tab) { tab = .local } }
        .onChange(of: model.scope) { _, scope in tab = EngineTab(scope: scope) }
        .onChange(of: model.requestedEngineTab) { _, requested in if let requested { tab = requested; model.requestedEngineTab = nil } }
        .onChange(of: model.localOnlyOn) { _, _ in if !visibleTabs.contains(tab) { tab = .local } }
        .onChange(of: readyEntries.map(\.id)) { _, _ in model.activatePendingLocal(ready: readyEntries) }
        .confirmationDialog(L10n.format("local.delete.title", deleting?.name() ?? ""), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(L10n.tr("local.delete"), role: .destructive) { if let e = deleting { center.delete(e.id) }; deleting = nil }
        } message: { Text(L10n.tr("local.delete.detail")) }
    }
}

struct ShortcutsView:View {
    @Bindable var model:SettingsModel
    var body:some View {
        SettingsPage {
            Section {
                Toggle(L10n.tr("shortcut.enabled"),isOn:Binding(get:{model.shortcutEnabled},set:{value in model.persist{$0.enabled=value;$0.holdShortcutEnabled=value && $0.inputMode == "hold";$0.toggleShortcutEnabled=value && $0.inputMode == "toggle"}}))
                Picker(L10n.tr("ui.3c7b79b73494"),selection:Binding(get:{model.inputModeIndex},set:{model.setInputMode($0)})){
                    Text(L10n.tr("ui.e4947a64758a")).tag(0)
                    Text(L10n.tr("ui.c3c686d13dc5")).tag(1).disabled(!model.toggleAvailable)
                }.pickerStyle(.segmented)
            } footer:{Text(L10n.tr("shortcut.explain")).font(.callout).foregroundStyle(.primary)}
            Section {
                LabeledContent(L10n.tr("ui.e4947a64758a")){HStack{Text(model.holdBinding);Button(L10n.tr("shortcut.change")){model.onEditShortcut?("hold")}.buttonStyle(.bordered).disabled(model.listening || model.recognizing)}}
                LabeledContent(L10n.tr("ui.c3c686d13dc5")){HStack{if model.toggleAvailable {Text(model.toggleBinding)};Button(L10n.tr(model.toggleAvailable ? "shortcut.change":"shortcut.set")){model.onEditShortcut?("toggle")}.buttonStyle(.bordered).disabled(model.listening || model.recognizing)}}
            } header:{Text(L10n.tr("ui.ee2638183d3e"))} footer:{Text(L10n.tr("shortcut.optionAdvice")).font(.callout).foregroundStyle(.primary)}
            ScreenshotShortcutSection(model:model)
        }
    }
}

// MARK: - 隐私页（三组）

struct PrivacyView: View {
    var model: SettingsModel
    @State private var confirmingClear=false

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 文字识别：用本机，或会把所选区域上传到哪个服务
    var ocrUploadText: String {
        let s = model.screenshotSettings
        if let provider = OCRProvider(rawValue: s.ocrEngine), s.ocrConsent[provider.rawValue] == true, OCRCredentialStore.has(provider) { return L10n.format("ocr.privacy.row.cloud", provider.title) }
        return L10n.tr("ocr.privacy.row.local")
    }

    var uploadText: String {
        if model.engine == .local { return L10n.tr("local.privacy.upload") }
        if model.engine == ASREngine.apple { return model.allowCloud ? L10n.tr("ui.35661afcc289") : L10n.tr("ui.e8fef1bc2353") }
        return model.consent ? L10n.format("ui.65792caed982", String(describing: model.engine.title)) : L10n.tr("ui.a380aa93a947")
    }

    var body: some View {
        SettingsPage {
            PrivacyPromiseSection()
            Section {
                LabeledContent(L10n.tr("ui.714cac30e2ff")) {
                    HStack {
                        PermissionStatus(granted:model.micAuthorized)
                        if !model.micAuthorized {Button(L10n.tr("permission.grant")) { if AVCaptureDevice.authorizationStatus(for:.audio) == .notDetermined {AVCaptureDevice.requestAccess(for:.audio){_ in DispatchQueue.main.async{model.sync()}}}else{openPrivacyPane("Privacy_Microphone")} }.buttonStyle(.borderless)}
                    }
                }
                LabeledContent(L10n.tr("ui.b8f88aeead15")) {
                    HStack {
                        PermissionStatus(granted:model.axAuthorized)
                        if !model.axAuthorized {Button(L10n.tr("permission.grant")) { openPrivacyPane("Privacy_Accessibility") }.buttonStyle(.borderless)}
                    }
                }
                if model.engine == .apple {
                    LabeledContent(L10n.tr("permission.speech")) {
                        HStack {PermissionStatus(granted:model.speechAuthorized);if !model.speechAuthorized {Button(L10n.tr("permission.grant")){if SFSpeechRecognizer.authorizationStatus() == .notDetermined {SFSpeechRecognizer.requestAuthorization{_ in DispatchQueue.main.async{model.sync()}}}else{openPrivacyPane("Privacy_SpeechRecognition")}}.buttonStyle(.borderless)}}
                    }
                }
                LabeledContent(L10n.tr("permission.screen")) {
                    HStack {PermissionStatus(granted:model.screenAuthorized);if !model.screenAuthorized {Button(L10n.tr("permission.grant")){ScreenCapturePermission.request();openPrivacyPane("Privacy_ScreenCapture");DispatchQueue.main.asyncAfter(deadline:.now()+1){model.sync()}}.buttonStyle(.borderless)}}
                }
                LabeledContent(L10n.tr("permission.monitoring")) {
                    HStack {PermissionStatus(granted:model.monitorAuthorized,stale:model.monitorStale);if !model.monitorAuthorized {Button(L10n.tr(model.monitorStale ? "permission.open":"permission.grant")){openPrivacyPane("Privacy_ListenEvent")}.buttonStyle(.borderless)}}
                }

            } header: {
                Text(L10n.tr("ui.3930c4e121a8"))
            } footer: {
                Text(L10n.tr("ui.e523232f1cde")).font(.callout).foregroundStyle(.primary)
            }
            Section {
                LabeledContent(L10n.tr("ui.46cbcb7c5a65")) { Text(model.primaryModelName) }
                LabeledContent(L10n.tr("ui.846a4b104dc0")) { Text(uploadText).foregroundStyle(.secondary) }
                LabeledContent(L10n.tr("ocr.title")) { Text(ocrUploadText).foregroundStyle(.secondary) }
                LabeledContent(L10n.tr("ui.2dfe17d754dd")) { Text(model.engine == ASREngine.apple || model.engine == .local ? L10n.tr("ui.601ded550b76") : (model.credentialsConfigured ? L10n.tr("ui.e7f43a33e34f") : L10n.tr("ui.80a57e03f071"))).foregroundStyle(.secondary) }
            } header: {
                Text(L10n.tr("ui.cdced850e983"))
            } footer: {
                VStack(alignment:.leading){Text(L10n.tr("ui.4dc583b8a798")).font(.callout).foregroundStyle(.primary);Button(L10n.tr("privacy.engines")){model.tab = .engines}.buttonStyle(.link)}
            }
            Section {
                LabeledContent(L10n.tr("ui.0968d01e0ba5")) { Button(L10n.tr("ui.bce2377283c2"),role:.destructive) { confirmingClear=true }.buttonStyle(.borderless) }
                LabeledContent(L10n.tr("ui.7dbac1c20f23")) { Button(L10n.tr("ui.fcf8b4bff0df")) { NSWorkspace.shared.open(AppPaths.supportDir) }.buttonStyle(.borderless) }
            } header: {
                Text(L10n.tr("ui.cb6c4f771fa9"))
            } footer: {
                Text(L10n.tr("ui.8161bf42ed84")).font(.callout).foregroundStyle(.primary)
            }
            PrivacyControlsSection()
        }
        .confirmationDialog(L10n.tr("clear.confirm"),isPresented:$confirmingClear){Button(L10n.tr("ui.bce2377283c2"),role:.destructive){model.clear()}}
    }
}

// MARK: - 关于页（唯一不用 Form）

struct AboutView: View {
    @State private var showingLicense=false
    @State private var copiedFeedback=false
    private var versionLine: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return L10n.format("about.version", short, build)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(nsImage: Bundle.main.url(forResource: "cadenza-logo", withExtension: "svg").flatMap(NSImage.init(contentsOf:)) ?? NSImage())
                    .resizable().frame(width: 80, height: 80)
                Text(Brand.name).font(.system(size: 22, weight: .semibold))
                Text(Brand.tagline).foregroundStyle(.secondary)
                Text(L10n.tr("app.description")).font(.callout)
                Divider()
                Text(versionLine).font(.system(size: 12)).foregroundStyle(.secondary)
                UpdateSection()
                Text(L10n.format("about.license", "MIT"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Button(L10n.tr("about.openLicense")){showingLicense=true}
                    Button(L10n.tr(copiedFeedback ? "ui.8f6f8d979c98":"about.copyFeedback")){
                        NSPasteboard.general.clearContents();NSPasteboard.general.setString(Brand.name+"\n"+versionLine+"\nmacOS "+ProcessInfo.processInfo.operatingSystemVersionString,forType:.string);copiedFeedback=true
                    }
                }.buttonStyle(.bordered)
                Text(L10n.format("about.disclaimer", Brand.name))
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 28)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .sheet(isPresented:$showingLicense){LicenseView()}
    }
}
struct LicenseView:View {
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading){Text(L10n.tr("about.openLicense")).font(.headline);ScrollView{Text(Bundle.main.url(forResource:"LICENSE",withExtension:nil).flatMap{try? String(contentsOf:$0,encoding:.utf8)} ?? "MIT License").textSelection(.enabled)};Button(L10n.tr("action.done")){dismiss()}.keyboardShortcut(.cancelAction)}.padding(24).frame(width:560,height:440)
    }
}


// MARK: - 窗口控制器桥接

extension SettingsWindowController {
    /// Replaces the hosted root view so every page re-reads its text, whatever the observation state.
    func refreshLanguage() {
        guard hostingInstalled, let model = settingsModel, let hosting = window?.contentViewController as? NSHostingController<MainSettingsView> else {
            Log.write("language-refresh settings-window-hosted=false")
            return
        }
        Log.write("language-refresh settings-window-hosted=true selected=\(L10n.language)")
        model.languageRevision += 1
        hosting.rootView = MainSettingsView(model: model)
    }
    func showSwift(_ tab: MainTab? = nil) {
        guard let store = configStore, let pl = pipeline else { return }
        if window == nil { build() } // 仅创建窗口外壳；旧 AppKit 页面代码保留供自检夹具
        AppearanceController.apply(store.config.appearanceMode)
        window?.backgroundColor = DesignTokens.settingsBackground
        window?.titlebarAppearsTransparent = true
        window?.toolbarStyle = .unified
        if !hostingInstalled {
            let model = SettingsModel(store: store, pipeline: pl)
            model.onSettingsChanged = { [weak self] in self?.onConfigurationChanged?() }
            model.onEditShortcut = { [weak self] mode in self?.editShortcut(mode:mode) }
            model.onStartScreenshot = { (NSApp.delegate as? AppDelegate)?.startScreenshot() }
            model.onScreenshotRecording = { (NSApp.delegate as? AppDelegate)?.setScreenshotHotkeyPaused($0) }
            model.localAPI = (NSApp.delegate as? AppDelegate)?.localAPI
            settingsModel = model
            // NSHostingController（非裸 NSHostingView）：自动处理标题栏安全区，内容不被工具栏遮挡
            let hosting = NSHostingController(rootView: MainSettingsView(model:model))
            window?.contentViewController = hosting
            window?.setContentSize(NSSize(width: 760, height: 560))
            window?.contentMinSize = NSSize(width: 720, height: 520)
            hostingInstalled = true
            Log.write("main-window swiftui-hosting installed (760x560 split view, controller)")
        }
        if let tab { settingsModel?.tab = tab }
        settingsModel?.sync()
        let opening=window?.isVisible != true
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if opening {
            window?.initialFirstResponder=nil;window?.makeFirstResponder(nil)
            // Remove automatic toolbar focus, while retaining focus rings after keyboard navigation.
            DispatchQueue.main.async { [weak self] in
                guard let window=self?.window,window.firstResponder is NSButton else{return}
                window.makeFirstResponder(nil)
            }
        }
    }

}

struct PermissionStatus:View {
    let granted:Bool
    var stale=false
    var body:some View {
        if stale {Label(L10n.tr("permission.stale"),systemImage:"exclamationmark.triangle.fill").foregroundStyle(Color.orange)}
        else {Label(L10n.tr(granted ? "permission.granted":"permission.denied"),systemImage:granted ? "checkmark.circle.fill":"exclamationmark.triangle").foregroundStyle(granted ? Color.green:.orange)}
    }
}
