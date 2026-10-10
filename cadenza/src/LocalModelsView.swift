import SwiftUI
import AppKit

// MARK: - 设置 → 语音识别 → 本地：模型列表、回退、更新

/// Recognition options for local models, laid out as plain labelled groups instead of one crowded disclosure.
struct LocalTuningSections: View {
    @Bindable var model: SettingsModel
    private var settings: LocalModelSettings { model.localSettings }
    private var sensitivity: Binding<Double> {
        Binding(get: { Double(1 - settings.recognition.vadThreshold) }, set: { v in model.persist { $0.localModel.recognition.vadThreshold = 1 - Float(v) } })
    }

    var body: some View {
        Section {
            Picker(L10n.tr("local.recognition.language"), selection: Binding(get: { settings.recognition.language }, set: { v in model.persist { $0.localModel.recognition.language = v } })) {
                ForEach(LocalRecognitionOptions.languages, id: \.self) { code in
                    Text(code == "auto" ? L10n.tr("local.language.auto") : Locale(identifier: L10n.language).localizedString(forLanguageCode: code) ?? code).tag(code)
                }
            }
            Toggle(isOn: Binding(get: { settings.recognition.useITN }, set: { v in model.persist { $0.localModel.recognition.useITN = v } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("local.recognition.itn"))
                    Text(L10n.tr("local.recognition.itn.detail")).font(.callout).foregroundStyle(.secondary)
                }
            }
        } header: { Text(L10n.tr("local.tuning.text")) } footer: { Text(L10n.tr("local.tuning.only")).font(.callout).foregroundStyle(.secondary) }

        Section {
            HStack(spacing: 12) {
                Text(L10n.tr("local.recognition.vad.low")).font(.callout).foregroundStyle(.secondary).fixedSize()
                Slider(value: sensitivity, in: 0.2...0.7, step: 0.05) { EmptyView() }.labelsHidden()
                Text(L10n.tr("local.recognition.vad.high")).font(.callout).foregroundStyle(.secondary).fixedSize()
            }
        } header: { Text(L10n.tr("local.recognition.vad")) } footer: { Text(L10n.tr("local.recognition.vad.detail")).font(.callout).foregroundStyle(.secondary) }

        Section {
            Picker(L10n.tr("local.recognition.performance"), selection: Binding(get: { settings.recognition.threads }, set: { v in model.persist { $0.localModel.recognition.threads = v } })) {
                Text(L10n.tr("local.recognition.lowPower")).tag(1)
                Text(L10n.tr("local.recognition.balanced")).tag(2)
                Text(L10n.tr("local.recognition.faster")).tag(4)
            }.pickerStyle(.segmented).labelsHidden()
        } header: { Text(L10n.tr("local.recognition.performance")) } footer: { Text(L10n.tr("local.recognition.performance.detail")).font(.callout).foregroundStyle(.secondary) }

        Section {
            LabeledContent(L10n.tr("local.update.source")) {
                TextField("", text: Binding(get: { settings.manifestURL }, set: { v in model.persist { $0.localModel.manifestURL = v.trimmingCharacters(in: .whitespacesAndNewlines) } }),
                          prompt: Text(L10n.tr("local.update.sourceHint")))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 340)
            }
            LocalModelImportControls()
        } header: { Text(L10n.tr("local.tuning.models")) } footer: { Text(L10n.tr("local.update.footer")).font(.callout).foregroundStyle(.secondary) }
    }
}

/// Import files downloaded elsewhere (offline machines, own mirrors). Every file still has to match the list's SHA-256.
struct LocalModelImportControls: View {
    let center = LocalModelCenter.shared
    @State private var message = ""
    var body: some View {
        HStack {
            Button(L10n.tr("local.import")) { LocalModelImport.pick(center) { message = $0 } }.buttonStyle(.bordered)
            Button(L10n.tr("local.dev.openFolder")) { NSWorkspace.shared.open(center.root) }.buttonStyle(.bordered)
        }
        if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary) }
        Text(L10n.tr("local.dev.footer")).font(.callout).foregroundStyle(.secondary)
    }
}

enum LocalModelUpdates {
    static func manifestURLs(_ s: LocalModelSettings) -> [String] {
        (s.manifestURL.isEmpty ? [] : [s.manifestURL]) + LocalModelCatalog.defaultManifestURLs
    }
}

struct LocalModelRow: View {
    let entry: LocalModelEntry
    let center: LocalModelCenter
    @Bindable var model: SettingsModel
    let askDelete: () -> Void
    /// One-line row for the engine list: name, one short line, one action on the right.
    var compact = false
    @State private var copiedLinks = false
    @State private var importMessage = ""
    @State private var testing=false
    @State private var testMessage=""

    private var usable: Bool { LocalModelCatalog.usable(entry) }
    private var inUse: Bool { model.engine == .local && (FallbackPolicy.resolvePrimary(settings:model.localSettings,ready:center.installedEntries.filter{LocalModelCatalog.usable($0)},recognitionLocale:model.store?.config.recognitionLocale ?? "en-US")?.id == entry.id) }
    private static func mb(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    private var canUse: Bool { usable && LocalTranscriberLoader.supported && !model.listening && !model.recognizing }

    @ViewBuilder private func compactTrailing(_ state: LocalModelState) -> some View {
        switch state {
        case .installed:
            if inUse { Text(L10n.tr("engine.card.inuse")).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 2).background(Color.accentColor.opacity(0.15), in: Capsule()).foregroundStyle(Color.accentColor) }
            else { Button(L10n.tr("engine.use")) { model.selectLocalModel(entry.id, ready: center.installedEntries) }.buttonStyle(.bordered).disabled(!canUse) }
            Menu {
                Button(L10n.tr("local.test")) { testModel() }.disabled(testing || model.listening || model.recognizing)
                Button(L10n.tr("local.license")) { openLicense() }
                if let update = center.updates[entry.id] { Button(L10n.format("local.update.to", update.version)) { center.download(update) } }
                Divider()
                Button(L10n.tr("local.delete"), role: .destructive) { askDelete() }
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
        case .notInstalled:
            Button(L10n.tr("local.download.short")) { center.download(entry) }.buttonStyle(.bordered).disabled(!usable || !LocalTranscriberLoader.supported)
        case .downloading(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 110)
            Button { center.pause(entry.id) } label: { Image(systemName: "pause.circle") }.buttonStyle(.borderless).help(L10n.tr("local.pause"))
            Button { center.cancel(entry.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help(L10n.tr("local.cancel"))
        case .paused:
            Button(L10n.tr("local.resume")) { center.resume(entry.id) }.buttonStyle(.borderedProminent)
            Button { center.cancel(entry.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help(L10n.tr("local.cancel"))
        case .verifying: ProgressView().controlSize(.small); Text(L10n.tr("local.verifying")).font(.caption).foregroundStyle(.secondary)
        case .installing: ProgressView().controlSize(.small); Text(L10n.tr("local.installing")).font(.caption).foregroundStyle(.secondary)
        case .failed:
            Button(L10n.tr("local.retry")) { center.clearFailure(entry.id); center.download(entry) }.buttonStyle(.bordered).disabled(!usable)
        }
    }

    private var compactBody: some View {
        let state = center.state(entry.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.name()).font(.headline)
                        if entry.id == LocalModelCatalog.recommendedID { Text(L10n.tr("local.recommended")).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 1).background(Color.green.opacity(0.18), in: Capsule()).foregroundStyle(Color.green) }
                    }
                    Text(Self.languageList(entry.languages) + " · " + Self.mb(entry.downloadSize)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    if let profile = entry.profile { Text(profile.summary()).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
                    if let rank = LocalModelRanking.lines(for: entry.id) { Text(rank.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 8)
                compactTrailing(state)
            }
            if case .failed = state { content(state) }
            if case .downloading(let done, let total) = state { Text(L10n.format("local.progress", Self.mb(done), Self.mb(total))).font(.caption).foregroundStyle(.secondary) }
            if !usable { Text(L10n.tr("local.needsAppUpdate")).font(.callout).foregroundStyle(.orange) }
            if !testMessage.isEmpty { Text(testMessage).font(.callout).foregroundStyle(.primary) }
        }
        .padding(.vertical, 4)
    }

    var body: some View {
        if compact { compactBody } else { fullBody }
    }

    private var fullBody: some View {
        let state = center.state(entry.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.name()).font(.body)
                if entry.id == LocalModelCatalog.recommendedID { Text(L10n.tr("local.recommended")).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 1).background(Color.green.opacity(0.18), in: Capsule()).foregroundStyle(Color.green) }
                Spacer()
                if case .installed(let v) = state {
                    if inUse { Label(L10n.tr("local.primary.current"), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.tint) } else { Label(L10n.format("local.installed", v), systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Text(entry.detail()).font(.callout).foregroundStyle(.secondary)
            Text(L10n.format("local.meta", Self.languageList(entry.languages), Self.mb(entry.downloadSize), Self.mb(entry.installedSize))).font(.caption).foregroundStyle(.tertiary)
            if let profile = entry.profile { Text(profile.summary()).font(.caption).foregroundStyle(.secondary) }
            if let rank = LocalModelRanking.lines(for: entry.id) { Text(rank.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
            if !usable { Text(L10n.tr("local.needsAppUpdate")).font(.callout).foregroundStyle(.orange) }
            content(state)
            if !testMessage.isEmpty {Text(testMessage).font(.callout).foregroundStyle(.primary)}
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func content(_ state: LocalModelState) -> some View {
        switch state {
        case .notInstalled:
            HStack {
                Button(L10n.format("local.download", Self.mb(entry.downloadSize))) { center.download(entry) }.buttonStyle(.borderedProminent).disabled(!usable || !LocalTranscriberLoader.supported)
            }
        case .downloading(let done, let total):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                HStack {
                    Text(L10n.format("local.progress", Self.mb(done), Self.mb(total))).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.tr("local.pause")) { center.pause(entry.id) }.buttonStyle(.bordered)
                    Button(L10n.tr("local.cancel")) { center.cancel(entry.id) }.buttonStyle(.bordered)
                }
            }
        case .paused(let done, let total):
            HStack {
                Text(L10n.format("local.paused", Self.mb(done), Self.mb(total))).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("local.resume")) { center.resume(entry.id) }.buttonStyle(.borderedProminent)
                Button(L10n.tr("local.cancel")) { center.cancel(entry.id) }.buttonStyle(.bordered)
            }
        case .verifying:
            HStack { ProgressView().controlSize(.small); Text(L10n.tr("local.verifying")).font(.caption).foregroundStyle(.secondary) }
        case .installing:
            HStack { ProgressView().controlSize(.small); Text(L10n.tr("local.installing")).font(.caption).foregroundStyle(.secondary) }
        case .installed:
            HStack {
                if !inUse { Button(L10n.tr("local.use")) { model.selectLocalModel(entry.id, ready: center.installedEntries) }.buttonStyle(.borderedProminent).disabled(!usable || !LocalTranscriberLoader.supported || model.listening || model.recognizing) }
                if let update = center.updates[entry.id] { Button(L10n.format("local.update.to", update.version)) { center.download(update) }.buttonStyle(.bordered) }
                Button(L10n.tr("local.test")) {testModel()}.buttonStyle(.bordered).disabled(testing || model.listening || model.recognizing)
                if testing {ProgressView().controlSize(.small)}
                Button(L10n.tr("local.license")) { openLicense() }.buttonStyle(.borderless)
                Spacer()
                Button(L10n.tr("local.delete"), role: .destructive) { askDelete() }.buttonStyle(.borderless)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                HStack {
                    Button(L10n.tr("local.retry")) { center.clearFailure(entry.id); center.download(entry) }.buttonStyle(.bordered).disabled(!usable)
                    Button(L10n.tr("local.dismiss")) { center.clearFailure(entry.id) }.buttonStyle(.borderless)
                }
                Text(L10n.tr("local.manual.hint")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L10n.tr(copiedLinks ? "local.manual.copied" : "local.manual.copy")) { LocalModelImport.copyLinks(entry); copiedLinks = true }.buttonStyle(.borderless)
                    Button(L10n.tr("local.import")) { LocalModelImport.pick(center) { importMessage = $0 } }.buttonStyle(.borderless)
                }
                if !importMessage.isEmpty { Text(importMessage).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func testModel() {
        guard !testing,let dir=center.modelDir(entry.id) else{return}
        testing=true;testMessage=L10n.tr("local.test.running")
        var options=model.localSettings.recognition;options.language="auto"
        DispatchQueue.global(qos:.userInitiated).async {
            let message:String
            do {let result=try LocalModelHealthCheck.run(dir:dir,entry:entry,options:options);message=L10n.tr(result.failures==0 ? "local.test.passed":"local.test.failed")}
            catch {message=L10n.tr("local.test.failed")}
            DispatchQueue.main.async {testing=false;testMessage=message}
        }
    }

    private func openLicense() {
        guard let dir = center.modelDir(entry.id) else { return }
        let f = dir.appendingPathComponent("LICENSE")
        if FileManager.default.fileExists(atPath: f.path) { NSWorkspace.shared.open(f) } else { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
    }

    static func languageList(_ codes: [String]) -> String {
        func name(_ c: String) -> String { c == "*" ? L10n.tr("local.allLanguages") : (Locale(identifier: L10n.language).localizedString(forLanguageCode: c) ?? c) }
        guard codes.count > 8 else { return codes.map(name).joined(separator: " · ") }
        return codes.prefix(4).map(name).joined(separator: " · ") + " " + L10n.format("local.languagesMore", codes.count)
    }
}

/// 手动导入：只在下载失败时作为后备出现，另外放在“开发者”页。导入的文件与在线下载走同一套 SHA-256 校验。
enum LocalModelImport {
    static func pick(_ center: LocalModelCenter, report: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.message = L10n.tr("local.import.message")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        report(L10n.tr("local.import.checking"))
        center.importFiles(panel.urls) { result in
            switch result {
            case .success(let e): report(L10n.format("local.import.ok", e.name()))
            case .failure(let error): report((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
    static func copyLinks(_ entry: LocalModelEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.files.compactMap { $0.urls.first }.joined(separator: "\n"), forType: .string)
    }
}

struct LocalFallbackSection: View {
    @Bindable var model: SettingsModel
    let center = LocalModelCenter.shared
    private var settings: LocalModelSettings { model.localSettings }
    private var readyEntries: [LocalModelEntry] { center.installedEntries.filter { LocalModelCatalog.usable($0) } }

    var body: some View {
        Section {
            Toggle(L10n.tr("local.fallback.enable"), isOn: Binding(get: { settings.enabled }, set: { v in model.persist { $0.localModel.enabled = v } }))
            Picker(L10n.tr("local.fallback.model"), selection: Binding(get: { settings.modelID }, set: { v in model.persist { $0.localModel.modelID = v } })) {
                Text(L10n.tr("local.fallback.auto")).tag("")
                ForEach(readyEntries) { Text($0.name()).tag($0.id) }
            }.disabled(!settings.enabled || model.listening || model.recognizing)
            Toggle(L10n.tr("local.fallback.offline"), isOn: Binding(get: { settings.offlineDirect }, set: { v in model.persist { $0.localModel.offlineDirect = v } })).disabled(!settings.enabled)
            if settings.enabled && readyEntries.isEmpty {
                HStack {
                    Label(L10n.tr("local.fallback.noModel"), systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.tr("local.fallback.download")) { model.scope = .local }.buttonStyle(.bordered)
                }
            }
        } header: { Text(L10n.tr("local.fallback.header")) } footer: {
            Text(L10n.tr(model.engine == .local ? "local.primary.localOnly" : (model.engine == .apple ? "local.fallback.systemInactive" : "local.fallback.footer"))).font(.callout).foregroundStyle(.primary)
        }
        .disabled(model.engine == .local || model.engine == .apple || model.listening || model.recognizing)

    }
}

extension LocalModelCatalog {
    /// The model most people should pick: the first built-in one (Chinese, English, Japanese, Korean, Cantonese).
    static var recommendedID: String { builtin.first?.id ?? "" }
}
