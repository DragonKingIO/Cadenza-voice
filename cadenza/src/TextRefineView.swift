import SwiftUI

/// Settings for AI polishing. Off by default; the text (never the audio) goes to the chosen service only after the person
/// turned this on, and, for a service that is not on this Mac, allowed it.
struct TextRefineSection: View {
    @Bindable var model: SettingsModel
    @State private var keyDraft = ""
    @State private var keySaved = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var models: [String] = []
    @State private var fetchingModels = false
    @State private var modelNote: String?

    private var settings: TextRefineSettings { model.refine }
    private var preset: LLMPreset? { LLMPresets.preset(settings.preset) }
    private var needsKey: Bool { !settings.isLocal && (preset?.needsKey ?? true) }

    private func presetBinding() -> Binding<String> {
        Binding(get: { settings.preset }, set: { id in
            model.persist { c in
                c.refine.preset = id
                if let p = LLMPresets.preset(id) { c.refine.baseURL = p.baseURL; c.refine.model = p.model }
            }
            keyDraft = ""; testResult = nil; models = []; modelNote = nil; refreshKeyState()
        })
    }
    private func refreshKeyState() { keySaved = KeychainStore.get(settings.keyName)?.isEmpty == false }

    var body: some View {
        Section {
            Toggle(L10n.tr("refine.enable"), isOn: Binding(get: { settings.enabled }, set: { value in model.persist { $0.refine.enabled = value } }))
            if settings.enabled {
                Picker(L10n.tr("refine.service"), selection: presetBinding()) {
                    ForEach(LLMPreset.Group.allCases, id: \.self) { group in
                        Section(L10n.tr("refine.group.\(group.rawValue)")) {
                            ForEach(LLMPresets.presets(in: group)) { p in Text(p.name).tag(p.id) }
                        }
                    }
                    Section(L10n.tr("refine.group.other")) { Text(L10n.tr("refine.custom")).tag("custom") }
                }
                if let key = preset?.noteKey {
                    Label(L10n.tr(key), systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                TextField(L10n.tr("refine.address"), text: Binding(get: { settings.baseURL }, set: { v in model.persist { $0.refine.baseURL = v } }), prompt: Text(verbatim: "https://api.example.com/v1"))
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                if !settings.baseURL.isEmpty && LLMEndpoint.url(settings.baseURL) == nil {
                    Label(L10n.tr("refine.address.invalid"), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                HStack {
                    TextField(L10n.tr("refine.model"), text: Binding(get: { settings.model }, set: { v in model.persist { $0.refine.model = v } }))
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    if !models.isEmpty {
                        Menu(L10n.tr("refine.models.pick")) {
                            ForEach(models, id: \.self) { name in Button(name) { model.persist { $0.refine.model = name } } }
                        }.fixedSize()
                    }
                    Button(L10n.tr("refine.models.fetch")) { fetchModels() }.disabled(fetchingModels || LLMEndpoint.modelsURL(settings.baseURL) == nil)
                    if fetchingModels { ProgressView().controlSize(.small) }
                }
                if settings.model.trimmingCharacters(in: .whitespaces).isEmpty && modelNote == nil {
                    Label(L10n.tr("refine.model.hint"), systemImage: "arrow.up.right.circle").font(.callout).foregroundStyle(.secondary)
                }
                if let note = modelNote {
                    Label(note, systemImage: models.isEmpty ? "exclamationmark.triangle" : "checkmark.circle").font(.callout)
                        .foregroundStyle(models.isEmpty ? Color.orange : Color.secondary)
                }
                if needsKey {
                    HStack {
                        SecureField(L10n.tr("refine.key"), text: $keyDraft, prompt: Text(L10n.tr(keySaved ? "refine.key.saved" : "refine.key.prompt"))).textFieldStyle(.roundedBorder)
                        Button(L10n.tr("refine.key.save")) {
                            let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !key.isEmpty, KeychainStore.set(key, for: settings.keyName) else { return }
                            keyDraft = ""; refreshKeyState(); testResult = nil
                        }.disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        if keySaved {
                            Button(L10n.tr("refine.key.delete")) { _ = KeychainStore.delete(settings.keyName); refreshKeyState(); testResult = nil }
                        }
                    }
                }
                Picker(L10n.tr("refine.style"), selection: Binding(get: { settings.style }, set: { v in model.persist { $0.refine.style = v } })) {
                    Text(L10n.tr("refine.style.clean")).tag(RefineStyle.clean)
                    Text(L10n.tr("refine.style.formal")).tag(RefineStyle.formal)
                }.pickerStyle(.segmented)
                if !settings.isLocal {
                    Toggle(L10n.tr("refine.consent"), isOn: Binding(get: { settings.consent }, set: { v in model.persist { $0.refine.consent = v } }))
                }
                HStack {
                    Button(L10n.tr("refine.test")) { runTest() }.disabled(testing || !settings.configured)
                    if testing { ProgressView().controlSize(.small) }
                    if let result = testResult {
                        Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(result.ok ? Color.green : Color.orange).lineLimit(3).textSelection(.enabled)
                    }
                }
            }
        } header: { Text(L10n.tr("refine.header")) } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("refine.hint"))
                if settings.enabled, settings.isLocal { Text(L10n.tr("refine.hint.local")) }
                else if settings.enabled { Text(L10n.tr("refine.hint.cloud")) }
            }.font(.callout).foregroundStyle(.primary)
        }
        .onAppear { refreshKeyState() }
    }

    private func fetchModels() {
        let current = settings, key = KeychainStore.get(current.keyName)
        fetchingModels = true; modelNote = nil
        Task {
            let result = await LLMClient.listModels(settings: current, apiKey: key)
            await MainActor.run {
                fetchingModels = false
                switch result {
                case .success(let names): models = names; modelNote = L10n.format("refine.models.found", String(names.count))
                case .failure(let failure): models = []; modelNote = LLMClient.describe(failure)
                }
            }
        }
    }

    private func runTest() {
        let sample = L10n.tr("refine.testSample")
        let current = settings, key = KeychainStore.get(current.keyName)
        testing = true; testResult = nil
        Task {
            let result = await LLMClient.refine(sample, settings: current, apiKey: key)
            await MainActor.run {
                testing = false
                switch result {
                case .success(let text): testResult = (true, text)
                case .failure(let failure): testResult = (false, LLMClient.describe(failure))
                }
            }
        }
    }
}
