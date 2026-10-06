import SwiftUI
import AppKit
import AVFoundation
import Speech

// First-run wizard: language, privacy and terms, permissions, recognition method, a short trial.
// Existing users who have not accepted the current privacy notice and terms see only the privacy step.

enum OnboardingStep: Int, CaseIterable { case welcome, privacy, permissions, method, ready }

@Observable
final class OnboardingModel {
    let store: ConfigStore
    weak var pipeline: VoicePipeline?
    let settings: SettingsModel
    let steps: [OnboardingStep]
    var step: OnboardingStep
    var termsChecked = TermsAcceptance.accepted
    var mic = false
    var speech = false
    var accessibility = false
    var monitoring = false
    var languageRevision = 0
    var trialActive = false
    var trialSessionID: UUID?
    var trialText = ""
    var holdTitle = ""
    var bindingText = ""
    var engineReady = false
    var busy = false
    var onSettings: () -> Void = {}
    var onDone: () -> Void = {}
    var onConfigurationChanged: () -> Void = {}
    private var languageObserver: NSObjectProtocol?

    init(store: ConfigStore, pipeline: VoicePipeline, termsOnly: Bool) {
        self.store = store; self.pipeline = pipeline
        settings = SettingsModel(store: store, pipeline: pipeline)
        steps = termsOnly ? [.privacy] : OnboardingStep.allCases
        step = steps[0]
        languageObserver = NotificationCenter.default.addObserver(forName: .appLanguageChanged, object: nil, queue: .main) { [weak self] _ in self?.languageRevision += 1; self?.refresh() }
        refresh()
    }

    var index: Int { steps.firstIndex(of: step) ?? 0 }
    var isLast: Bool { index == steps.count - 1 }
    var engine: ASREngine { ASREngine(rawValue: store.config.engine) ?? .apple }

    /// Whether the current step lets the user move on.
    var canContinue: Bool {
        if busy { return false }
        switch step {
        case .welcome: return true
        case .privacy: return termsChecked
        case .permissions: return mic && (engine != .apple || speech)
        case .method: return engineReady
        case .ready: return true
        }
    }

    func refresh() {
        guard let pipeline = pipeline else { return }
        let c = store.config
        settings.sync()
        mic = HoldNativeEngine.micAuthorized(); speech = HoldNativeEngine.speechAuthorized()
        accessibility = FocusProbe.accessibilityTrusted; monitoring = PermissionProbe.monitorGranted
        let deviceReady = SFSpeechRecognizer(locale: Locale(identifier: c.recognitionLocale))?.supportsOnDeviceRecognition == true || c.allowCloudRecognition
        let current = ASREngine(rawValue: c.engine) ?? .apple
        engineReady = EngineReadiness.ready(engine: c.engine, mic: mic, speech: speech, local: deviceReady, cloud: c.allowCloudRecognition, credentials: current.configured, consent: c.options(current).consent)
        busy = pipeline.hasActiveSession && pipeline.session?.id != trialSessionID
        bindingText = L10n.tr("ui.16f89c29238b") + HotkeySpecDisplay.string(c.trigger) + L10n.tr("ui.127c959d39e5") + (c.toggleTrigger.map(HotkeySpecDisplay.string) ?? L10n.tr("ui.2f5f1d6fbfb0"))
        holdTitle = c.inputMode == "toggle" ? (pipeline.session?.state == .voiceStarted ? L10n.tr("ui.7c28416dc186") : L10n.tr("ui.830bde5107c5")) : L10n.tr("ui.1ac211466803")
        let placeholder = L10n.tr("ui.1b7d4a33e2fa")
        trialText = trialActive ? (pipeline.lastTranscript ?? (pipeline.lastResult == "—" ? placeholder : pipeline.lastResult)) : placeholder
    }

    func next() {
        guard canContinue, pipeline?.hasActiveSession != true else { return }
        if step == .privacy { TermsAcceptance.accept() }
        if isLast { finish(); return }
        step = steps[index + 1]; refresh()
    }
    func back() {
        guard index > 0, pipeline?.hasActiveSession != true else { return }
        step = steps[index - 1]; refresh()
    }
    func finish() { onDone() }

    // Permissions
    func requestPermissions() { HoldNativeEngine.requestRequired(engine: store.config.engine) { [weak self] _ in self?.refresh() } }
    func openPrivacyPane(_ suffix: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + suffix) { NSWorkspace.shared.open(url) }
    }
    func grantMic() { AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined ? requestPermissions() : openPrivacyPane("Privacy_Microphone") }
    func grantSpeech() { SFSpeechRecognizer.authorizationStatus() == .notDetermined ? requestPermissions() : openPrivacyPane("Privacy_SpeechRecognition") }
    func grantAccessibility() { openPrivacyPane("Privacy_Accessibility") }
    func grantMonitoring() { openPrivacyPane("Privacy_ListenEvent") }

    // Trial recording (window button only; text stays in this window)
    func markTrialStarted() { trialActive = true; trialSessionID = nil; pipeline?.clearTranscript() }
    func captureTrialSession() { trialSessionID = pipeline?.session?.id }
    func pressStart() {
        guard store.config.inputMode != "toggle" else { return }
        markTrialStarted(); pipeline?.holdStarted(source: .button); captureTrialSession()
    }
    func pressEnd() {
        if store.config.inputMode == "toggle" {
            if pipeline?.hasActiveSession != true { markTrialStarted() }
            pipeline?.togglePressed(localOnly: true); captureTrialSession()
        } else { pipeline?.holdEnded() }
    }
    func cancelTrial() {
        if let id = trialSessionID, pipeline?.session?.id == id { pipeline?.forceEnd(reason: L10n.tr("ui.590d325d934e")) }
        trialActive = false; trialSessionID = nil; refresh()
    }
    var trialRunning: Bool { pipeline?.session?.id == trialSessionID && pipeline?.hasActiveSession == true }
    var canTry: Bool { engineReady && (pipeline?.hasActiveSession != true || trialRunning) }
}

// MARK: - Views

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    @State private var shown: LegalDocument?
    @State private var language = AppLanguage.current

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView { content.padding(.horizontal, 32).padding(.vertical, 24).frame(maxWidth: .infinity, alignment: .leading) }
            Divider()
            footer
        }
        .frame(width: 600, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $shown) { doc in LegalDocumentSheet(document: doc) { shown = nil } }
        .id(model.languageRevision)
        .onAppear { language = AppLanguage.current }
    }

    private var header: some View {
        HStack {
            if model.steps.count > 1 {
                Text(L10n.format("onboard.step", model.index + 1, model.steps.count)).font(.callout).foregroundStyle(.secondary)
                Spacer()
                ProgressView(value: Double(model.index + 1), total: Double(model.steps.count)).frame(width: 160)
            } else { Spacer() }
        }.padding(.horizontal, 24).padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            if model.index > 0 && model.steps.count > 1 { Button(L10n.tr("onboard.back")) { model.back() }.disabled(model.busy) }
            Spacer()
            if model.step == .privacy {
                Button(L10n.tr(model.steps.count == 1 ? "onboard.agree.done" : "onboard.agree")) { model.next() }
                    .keyboardShortcut(.defaultAction).disabled(!model.canContinue)
            } else {
                Button(L10n.tr(model.isLast ? "onboard.finish" : model.step == .welcome ? "onboard.start" : "onboard.continue")) { model.next() }
                    .keyboardShortcut(.defaultAction).disabled(!model.canContinue)
            }
        }.padding(.horizontal, 24).padding(.vertical, 14)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome: welcome
        case .privacy: privacy
        case .permissions: permissions
        case .method: method
        case .ready: ready
        }
    }

    private func title(_ text: String) -> some View { Text(text).font(.title.bold()).fixedSize(horizontal: false, vertical: true) }
    private func card<C: View>(@ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10, content: body)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    // 1. Welcome and language
    private var welcome: some View {
        VStack(spacing: 14) {
            if let url = Bundle.main.url(forResource: "cadenza-icon-128", withExtension: "png"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().frame(width: 84, height: 84)
            }
            Text(L10n.format("onboard.welcome", String(describing: Brand.name))).font(.largeTitle.bold()).multilineTextAlignment(.center)
            Text(Brand.tagline).font(.title3).foregroundStyle(.secondary)
            Text(L10n.tr("onboard.welcome.body")).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            card {
                Text(L10n.tr("general.language")).font(.headline)
                Picker("", selection: Binding(get: { language }, set: { language = $0; AppLanguage.current = $0 })) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                Text(L10n.tr("onboard.language.hint")).font(.callout).foregroundStyle(.secondary)
            }.padding(.top, 10)
        }.frame(maxWidth: .infinity)
    }

    // 2. Privacy and terms
    private var privacy: some View {
        VStack(alignment: .leading, spacing: 14) {
            title(L10n.tr("onboard.privacy.title"))
            Text(L10n.tr("onboard.privacy.lead")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            card {
                ForEach(["privacy.promise.collect", "privacy.promise.voice", "privacy.promise.keep", "privacy.promise.keys"], id: \.self) { key in
                    Label { Text(key == "privacy.promise.collect" ? L10n.format(key, String(describing: Brand.name)) : L10n.tr(key)).fixedSize(horizontal: false, vertical: true) }
                        icon: { Image(systemName: "lock.shield").foregroundStyle(.tint) }
                }
            }
            HStack(spacing: 16) {
                ForEach(LegalDocument.allCases, id: \.self) { doc in Button(doc.title) { shown = doc }.buttonStyle(.link) }
            }
            Toggle(L10n.tr("onboard.privacy.agree"), isOn: $model.termsChecked).toggleStyle(.checkbox).padding(.top, 4)
            Text(L10n.tr("onboard.privacy.separate")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // 3. Permissions
    private func permissionRow(_ name: String, _ detail: String, granted: Bool, required: Bool = true, undetermined: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) { Text(name).font(.headline); Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer()
            Text(L10n.tr(!required ? "ui.c6ca814dc1e4" : granted ? "ui.521e65ffc7d0" : "ui.94bc3d40defe")).foregroundStyle(!required || granted ? Color.green : Color.orange)
            Button(L10n.tr(undetermined ? "ui.5a91c6690b18" : "ui.37aa6ad6a36d"), action: action).disabled(!required || model.busy).frame(minWidth: 90)
        }
    }
    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            title(L10n.tr("onboard.permissions.title"))
            Text(L10n.tr("onboard.permissions.lead")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            card {
                permissionRow(L10n.tr("ui.714cac30e2ff"), L10n.tr("ui.e0d4c05278a5"), granted: model.mic, undetermined: AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined, action: model.grantMic)
                Divider()
                permissionRow(L10n.tr("ui.654a661d7492"), L10n.tr("ui.8dafd7521162"), granted: model.speech, required: model.engine == .apple, undetermined: SFSpeechRecognizer.authorizationStatus() == .notDetermined, action: model.grantSpeech)
                Divider()
                permissionRow(L10n.tr("ui.b8f88aeead15"), L10n.tr("onboard.permissions.accessibility"), granted: model.accessibility, action: model.grantAccessibility)
                Divider()
                permissionRow(L10n.tr("ui.fc22bc8bea45"), L10n.tr("onboard.permissions.monitoring"), granted: model.monitoring, action: model.grantMonitoring)
            }
            Text(L10n.tr("onboard.permissions.note")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.canContinue { Label(L10n.tr("onboard.permissions.needed"), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
        }
    }

    // 4. Recognition method
    private func methodCard(_ scope: EngineScope, _ name: String, _ detail: String) -> some View {
        Button { model.settings.chooseScope(scope); model.onConfigurationChanged(); model.refresh() } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.settings.scope == scope ? "largecircle.fill.circle" : "circle").foregroundStyle(model.settings.scope == scope ? Color.accentColor : .secondary).font(.title3)
                VStack(alignment: .leading, spacing: 4) { Text(name).font(.headline); Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Spacer()
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(model.settings.scope == scope ? 0.9 : 0.4), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).disabled(model.busy)
    }
    private var method: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(L10n.tr("onboard.method.title"))
            Text(L10n.tr("onboard.method.lead")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            methodCard(.system, L10n.tr("onboard.method.system"), L10n.tr("onboard.method.system.detail"))
            methodCard(.local, L10n.tr("onboard.method.local"), L10n.tr("onboard.method.local.detail"))
            methodCard(.cloud, L10n.tr("onboard.method.cloud"), L10n.tr("onboard.method.cloud.detail"))
            Text(model.settings.recognitionSummary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.engineReady {
                HStack {
                    Label(L10n.tr(model.settings.scope == .local ? "onboard.method.needLocal" : model.settings.scope == .cloud ? "onboard.method.needCloud" : "onboard.method.needSystem"), systemImage: "info.circle").font(.callout).foregroundStyle(.orange)
                    Spacer()
                    if model.settings.scope == .system { Button(L10n.tr("onboard.method.back")) { model.back() } }
                    else { Button(L10n.tr("onboard.method.open")) { model.onSettings() } }
                }
            }
            Text(L10n.tr("onboard.method.later")).font(.callout).foregroundStyle(.secondary)
        }
    }

    // 5. Try it
    private var ready: some View {
        VStack(alignment: .leading, spacing: 14) {
            title(L10n.tr("ui.2124b718a9a1"))
            Text(L10n.tr("onboard.ready.lead")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            card { Text(model.bindingText).font(.title3) }
            card { Text(model.trialText).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading).textSelection(.enabled) }
            TrialHoldButton(model: model).frame(height: 44)
            Button(L10n.tr("ui.076918e4bf6c")) { model.cancelTrial() }.disabled(!model.trialRunning)
            Label(L10n.format("onboard.ready.privacy", String(describing: Brand.name)), systemImage: "lock").font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// The existing hold-to-talk control, so the trial keeps the exact press, release and accessibility behaviour.
struct TrialHoldButton: NSViewRepresentable {
    var model: OnboardingModel
    func makeNSView(context: Context) -> HoldButton {
        let button = HoldButton(title: "", target: nil, action: nil)
        button.isBordered = false
        button.onPressStart = { [weak model] in model?.pressStart() }
        button.onPressEnd = { [weak model] in model?.pressEnd() }
        return button
    }
    func updateNSView(_ button: HoldButton, context: Context) {
        button.isEnabled = model.canTry
        button.attributedTitle = NSAttributedString(string: model.holdTitle, attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 15, weight: .semibold)])
    }
}

// MARK: - Window

final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let model: OnboardingModel
    private let configStore: ConfigStore
    private weak var pipeline: VoicePipeline?

    var ownsInputFocus: Bool { TrialFocusOwnership.matches(appActive: NSApp.isActive, frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier, ownPID: ProcessInfo.processInfo.processIdentifier, windowKey: window?.isKeyWindow == true, windowVisible: window?.isVisible == true) }
    func markTrialStarted() { model.markTrialStarted() }
    func captureTrialSession() { model.captureTrialSession() }

    init(configStore: ConfigStore, pipeline: VoicePipeline, termsOnly: Bool = false, onSettings: @escaping () -> Void, onConfigurationChanged: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.configStore = configStore; self.pipeline = pipeline
        model = OnboardingModel(store: configStore, pipeline: pipeline, termsOnly: termsOnly)
        model.onSettings = onSettings; model.onConfigurationChanged = onConfigurationChanged
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 680), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: w)
        w.title = L10n.format("ui.74320d268800", String(describing: Brand.name)); w.isReleasedWhenClosed = false; w.delegate = self
        w.contentViewController = NSHostingController(rootView: OnboardingView(model: model))
        w.center()
        model.onDone = { [weak self] in onDone(); self?.close() }
    }
    required init?(coder: NSCoder) { fatalError("unsupported") }

    /// Screenshot and inspection entry: jump to a step (0 = first).
    func inspectStep(_ requested: Int) {
        guard requested > 0 else { return }
        model.step = model.steps[min(requested, model.steps.count - 1)]; model.refresh()
    }
    func refresh() { model.refresh() }
    func windowWillClose(_ notification: Notification) { if model.trialActive { model.cancelTrial() } }
    func windowDidBecomeKey(_ notification: Notification) { model.refresh() }
}
