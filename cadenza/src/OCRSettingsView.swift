import SwiftUI
import AppKit

// MARK: - 设置 → 文字识别：独立的 OCR 引擎页
// 本机 Apple Vision 是默认引擎；云端（百度、腾讯、Google）必须先填密钥并明确允许上传图片才会被使用。
// 云端失败、没网或没同意时自动改用本机识别（可关闭）。

/// 云端服务商的配置草稿：输入的密钥只在点“保存”时写入钥匙串，界面上永远不回显已保存的密钥。
@Observable
final class OCRProviderDraft {
    let provider: OCRProvider
    var values: [String: String] = [:]          // 本次输入的新密钥
    private(set) var saved: Set<String> = []     // 钥匙串里已有的字段
    /// Fields served by the key saved for speech recognition (see `SharedCredentials`), not by one of their own.
    private(set) var shared: Set<String> = []
    var consent: Bool
    var accurate: Bool
    var region: String
    var feedback = ""
    var isError = false
    var testing = false

    private let has: (String) -> Bool
    private let own: (String) -> String?
    private let write: (String, String) -> Bool
    private let delete: (String) -> Bool
    private let read: (String) -> String?
    private let persist: (OCRProvider, Bool, Bool, String) -> Bool
    private let transport: OCRTransport

    init(provider: OCRProvider, settings: ScreenshotSettings,
         has: @escaping (String) -> Bool = { SharedCredentials.has($0) },
         read: @escaping (String) -> String? = { SharedCredentials.get($0) },
         own: @escaping (String) -> String? = { KeychainStore.get($0) },
         write: @escaping (String, String) -> Bool = { KeychainStore.set($0, for: $1) },
         delete: @escaping (String) -> Bool = { KeychainStore.delete($0) },
         persist: @escaping (OCRProvider, Bool, Bool, String) -> Bool,
         transport: OCRTransport = NativeOCRTransport()) {
        self.provider = provider; self.has = has; self.own = own; self.read = read; self.write = write; self.delete = delete; self.persist = persist; self.transport = transport
        consent = settings.ocrConsent[provider.rawValue] == true
        accurate = settings.ocrAccurate[provider.rawValue] == true
        region = settings.ocrTencentRegion
        refreshSaved()
    }

    /// Which fields have a key, and which of those are served by the speech recognition key rather than one of their own.
    private func refreshSaved() {
        saved = Set(provider.credentialFields.compactMap { has(OCRProvider.keychainKey(provider, $0.0)) ? $0.0 : nil })
        shared = Set(saved.filter { (own(OCRProvider.keychainKey(provider, $0)) ?? "").isEmpty })
    }

    /// 每个字段要么已保存、要么刚输入了新值
    var complete: Bool { provider.credentialFields.allSatisfy { saved.contains($0.0) || !(values[$0.0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty } }

    private func fail(_ key: String) { feedback = L10n.tr(key); isError = true }

    @discardableResult
    func save() -> Bool {
        guard !testing else { return false }
        if consent && !complete { fail("ocr.sheet.needKeys"); return false }
        var failed = false
        for (field, _) in provider.credentialFields {
            guard let value = values[field]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
            if write(value, OCRProvider.keychainKey(provider, field)) { saved.insert(field); shared.remove(field); values[field] = "" } else { failed = true }
        }
        if failed { fail("ocr.sheet.keychainFailed"); return false }
        let cleanRegion = region.trimmingCharacters(in: .whitespaces)
        guard persist(provider, consent, accurate, cleanRegion.isEmpty ? "ap-guangzhou" : cleanRegion) else { fail("ui.bcd8e5694934"); return false }
        feedback = L10n.tr("ocr.sheet.saved"); isError = false
        return true
    }

    /// 自检专用：只保存选项（不涉及钥匙串）
    func persistOptionsForTest() -> Bool { persist(provider, consent, accurate, region) }

    func clearCredentials() {
        for (field, _) in provider.credentialFields where !shared.contains(field) { _ = delete(OCRProvider.keychainKey(provider, field)) }
        values.removeAll(); consent = false; refreshSaved()
        _ = persist(provider, false, accurate, region)
        feedback = L10n.tr("ocr.sheet.cleared"); isError = false
    }

    /// 只在用户点击“测试连接”时执行：发送一张小图，消耗 1 次识别额度
    func test() async {
        guard !testing else { return }
        guard consent else { fail("ocr.sheet.testConsent"); return }
        guard complete else { fail("ocr.sheet.needKeys"); return }
        var creds: [String: String] = [:]
        for (field, _) in provider.credentialFields {
            guard let v = (values[field].flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }) ?? read(OCRProvider.keychainKey(provider, field)), !v.isEmpty else { fail("ocr.sheet.needKeys"); return }
            creds[field] = v
        }
        guard let image = OCRTestImage.make() else { fail("ocr.sheet.testFailed"); return }
        testing = true; feedback = L10n.tr("ocr.sheet.testing"); isError = false
        defer { testing = false }
        var s = ScreenshotSettings(); s.ocrAccurate[provider.rawValue] = accurate; s.ocrTencentRegion = region
        let router = OCRRouter(settings: s, credentials: { _ in creds }, online: { true }, transport: transport)
        do {
            guard let engine = router.cloudEngine(for: provider) else { fail("ocr.sheet.testFailed"); return }
            let result = try await engine.recognize(image)
            let text = result.text.uppercased()
            if text.contains("OCR") || text.contains("123") || text.contains("TEST") { feedback = L10n.format("ocr.sheet.testOK", result.text.replacingOccurrences(of: "\n", with: " ")); isError = false }
            else { feedback = L10n.tr("ocr.sheet.testEmpty"); isError = true }
        } catch {
            feedback = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; isError = true
        }
    }
}

struct OCRSettingsView: View {
    @Bindable var model: SettingsModel
    private let center = LocalModelCenter.shared
    @State private var deleting: LocalModelEntry?
    private var localModels: [LocalModelEntry] { center.entries.filter(LocalModelCatalog.isOCR) }

    private var settings: ScreenshotSettings { model.screenshotSettings }

    var body: some View {
        SettingsPage {
            Section {
                EngineRow(title: L10n.tr("ocr.engine.vision"), detail: L10n.tr("ocr.engine.vision.detail"), badge: L10n.tr("ocr.engine.builtin"), selected: settings.ocrEngine == "vision", configurable: false,
                          onSelect: { model.selectOCREngine("vision") }, onConfigure: {})
                ForEach(OCRProvider.allCases) { provider in
                    EngineRow(title: provider.title, detail: detail(for: provider), badge: nil, selected: settings.ocrEngine == provider.rawValue, configurable: true,
                              onSelect: { model.selectOCREngine(provider.rawValue) }, onConfigure: { model.configuringOCR = provider })
                }
            } header: { Text(L10n.tr("ocr.engines.header")) } footer: { Text(L10n.tr("ocr.engines.footer")).font(.callout).foregroundStyle(.primary) }

            if !localModels.isEmpty {
                Section {
                    ForEach(localModels) { entry in OCRLocalModelRow(entry: entry, center: center, model: model, askDelete: { deleting = entry }) }
                } header: { Text(L10n.tr("ocr.local.header")) } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.tr(PaddleOCREngine.isAvailable ? "ocr.local.footer" : "ppocr.err.runtime")).font(.callout).foregroundStyle(.primary)
                        if localModels.contains(where: { $0.profile != nil }) { Text(L10n.tr("local.profile.footnote")).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }

            Section {
                Toggle(L10n.tr("ocr.fallback"), isOn: Binding(get: { settings.ocrFallback }, set: { v in model.persist { $0.screenshot.ocrFallback = v } }))
            } header: { Text(L10n.tr("ocr.fallback.header")) } footer: { Text(L10n.tr("ocr.fallback.footer")).font(.callout).foregroundStyle(.primary) }

            Section {
                LabeledContent(L10n.tr("ocr.privacy.local")) { Text(L10n.tr("ocr.privacy.localValue")).foregroundStyle(.secondary) }
                LabeledContent(L10n.tr("ocr.privacy.cloud")) { Text(cloudSummary).foregroundStyle(.secondary) }
            } header: { Text(L10n.tr("ocr.privacy.header")) } footer: { Text(L10n.tr("ocr.privacy.footer")).font(.callout).foregroundStyle(.primary) }
        }
        .sheet(item: $model.configuringOCR) { provider in
            OCRProviderSheet(draft: model.ocrDraft(provider)) { model.configuringOCR = nil; model.sync() }
        }
        .confirmationDialog(L10n.format("local.delete.title", deleting?.name() ?? ""), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(L10n.tr("local.delete"), role: .destructive) { if let e = deleting { center.delete(e.id) }; deleting = nil }
        } message: { Text(L10n.tr("local.delete.detail")) }
    }

    private func detail(for p: OCRProvider) -> String {
        let configured = OCRCredentialStore.has(p), allowed = settings.ocrConsent[p.rawValue] == true
        if !configured { return L10n.tr("ocr.status.notConfigured") }
        return allowed ? L10n.tr("ocr.status.ready") : L10n.tr("ocr.status.notAllowed")
    }

    private var cloudSummary: String {
        let allowed = OCRProvider.allCases.filter { settings.ocrConsent[$0.rawValue] == true && OCRCredentialStore.has($0) }
        return allowed.isEmpty ? L10n.tr("ocr.privacy.noneAllowed") : allowed.map(\.title).joined(separator: "、")
    }
}

/// One on-device recognition model: download, pause, use and delete, like the speech models.
private struct OCRLocalModelRow: View {
    let entry: LocalModelEntry
    let center: LocalModelCenter
    @Bindable var model: SettingsModel
    let askDelete: () -> Void

    private var selected: Bool { model.screenshotSettings.ocrEngine == PaddleOCREngine.engineID && model.screenshotSettings.ocrLocalModel == entry.id }
    private var usable: Bool { LocalModelCatalog.usableOCR(entry) }
    private static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    var body: some View {
        let state = center.state(entry.id)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name())
                Text(entry.detail()).font(.callout).foregroundStyle(.secondary)
                if let profile = entry.profile { Text(profile.summary()).font(.caption).foregroundStyle(.secondary) }
                stateLine(state)
            }
            Spacer()
            trailing(state)
        }
        .frame(minHeight: 36)
    }

    @ViewBuilder private func stateLine(_ state: LocalModelState) -> some View {
        switch state {
        case .installed(let version): Text(L10n.format("local.installed", version)).font(.caption).foregroundStyle(.secondary)
        case .downloading(let done, let total): Text(L10n.format("local.progress", Self.size(done), Self.size(total))).font(.caption).foregroundStyle(.secondary)
        case .paused(let done, let total): Text(L10n.format("local.paused", Self.size(done), Self.size(total))).font(.caption).foregroundStyle(.secondary)
        case .failed(let message): Text(message).font(.caption).foregroundStyle(.orange)
        case .verifying: Text(L10n.tr("local.verifying")).font(.caption).foregroundStyle(.secondary)
        case .installing: Text(L10n.tr("local.installing")).font(.caption).foregroundStyle(.secondary)
        case .notInstalled: EmptyView()
        }
    }

    @ViewBuilder private func trailing(_ state: LocalModelState) -> some View {
        switch state {
        case .notInstalled:
            Button(L10n.format("local.download", Self.size(entry.downloadSize))) { center.download(entry) }.buttonStyle(.bordered).disabled(!usable)
        case .downloading(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 110)
            Button(L10n.tr("local.pause")) { center.pause(entry.id) }.buttonStyle(.bordered)
            Button(L10n.tr("local.cancel")) { center.cancel(entry.id) }.buttonStyle(.borderless)
        case .paused:
            Button(L10n.tr("local.resume")) { center.resume(entry.id) }.buttonStyle(.bordered)
            Button(L10n.tr("local.cancel")) { center.cancel(entry.id) }.buttonStyle(.borderless)
        case .verifying, .installing:
            ProgressView().controlSize(.small)
        case .failed:
            Button(L10n.tr("local.retry")) { center.clearFailure(entry.id); center.download(entry) }.buttonStyle(.bordered).disabled(!usable)
        case .installed:
            Menu {
                Button(L10n.tr("local.delete"), role: .destructive) { askDelete() }
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
            Button { model.selectLocalOCRModel(entry.id) } label: { Image(systemName: selected ? "largecircle.fill.circle" : "circle") }
                .buttonStyle(.plain).disabled(!usable).accessibilityLabel(entry.name())
                .accessibilityValue(selected ? L10n.tr("ui.fa48e8938940") : L10n.tr("engine.notSelected"))
        }
    }
}

private struct EngineRow: View {
    let title: String, detail: String
    let badge: String?
    let selected: Bool, configurable: Bool
    let onSelect: () -> Void, onConfigure: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) { Text(title); if let badge { Text(badge).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: Capsule()) } }
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if configurable { Button(L10n.tr("engine.configure"), action: onConfigure).buttonStyle(.bordered) }
            Button(action: onSelect) { Image(systemName: selected ? "largecircle.fill.circle" : "circle") }
                .buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(selected ? L10n.tr("ui.fa48e8938940") : L10n.tr("engine.notSelected"))
        }
        .frame(minHeight: 36)
    }
}

struct OCRProviderSheet: View {
    @Bindable var draft: OCRProviderDraft
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.provider.title).font(.title3.weight(.semibold))
            Form {
                Section {
                    ForEach(draft.provider.credentialFields, id: \.0) { field, labelKey in
                        LabeledContent(L10n.tr(labelKey)) {
                            SecureField("", text: Binding(get: { draft.values[field] ?? "" }, set: { draft.values[field] = $0 }), prompt: Text(L10n.tr(draft.shared.contains(field) ? "ocr.sheet.shared.placeholder" : draft.saved.contains(field) ? "ocr.sheet.saved.placeholder" : "ocr.sheet.enter")))
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                        }
                    }
                    if draft.provider == .tencent {
                        LabeledContent(L10n.tr("ocr.field.region")) { TextField("", text: $draft.region, prompt: Text("ap-guangzhou")).textFieldStyle(.roundedBorder).frame(maxWidth: 260) }
                    }
                    if !draft.shared.isEmpty { Text(L10n.tr("ocr.sheet.shared")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    if draft.provider.supportsAccurate { Toggle(L10n.tr("ocr.sheet.accurate"), isOn: $draft.accurate) }
                }
                Section {
                    Toggle(L10n.format("ocr.sheet.consent", draft.provider.title), isOn: $draft.consent)
                } footer: { Text(L10n.tr("ocr.sheet.consent.detail")).font(.callout).foregroundStyle(.primary) }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            if !draft.feedback.isEmpty {
                Text(draft.feedback).font(.callout).foregroundStyle(draft.isError ? Color.orange : Color.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L10n.tr("ocr.sheet.console")) { if let url = URL(string: draft.provider.consoleURL) { NSWorkspace.shared.open(url) } }.buttonStyle(.borderless)
                Link(destination: ProviderHelp.credentialGuideURL(ocrProvider: draft.provider, language: L10n.language)) {
                    Label(L10n.tr("provider.credentialGuide"), systemImage: "book")
                }.buttonStyle(.borderless)
                if !draft.saved.subtracting(draft.shared).isEmpty { Button(L10n.tr("ocr.sheet.clear"), role: .destructive) { draft.clearCredentials() }.buttonStyle(.borderless) }
                Spacer()
                if draft.testing { ProgressView().controlSize(.small) }
                Button(L10n.tr("ocr.sheet.test")) { Task { await draft.test() } }.disabled(draft.testing)
                Button(L10n.tr("action.cancel"), action: close).keyboardShortcut(.cancelAction)
                Button(L10n.tr("screenshot.shortcut.save")) { if draft.save() { close() } }.buttonStyle(.borderedProminent).disabled(draft.testing)
            }
        }
        .padding(20).frame(width: 520)
    }
}
