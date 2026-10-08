import SwiftUI

// AI polish and voice translation each run on one of "my AI models": services the person adds under a name of their own (an
// address, a model, a key). Text, never audio, goes to a service only after the person turned the use on and, for a service that
// is not on this Mac, allowed it.

/// Which of my AI models a use runs on, with a hint to add the first one.
private struct ProfilePicker: View {
    @Bindable var model: SettingsModel
    let use: LLMUse
    private var selected: String { use == .polish ? model.refine.profileID : model.translate.profileID }

    var body: some View {
        if model.llmProfiles.isEmpty {
            Label(L10n.tr("llm.none"), systemImage: "arrow.down.circle").font(.callout).foregroundStyle(.secondary)
        } else {
            Picker(L10n.tr(use == .polish ? "llm.useForPolish" : "llm.useForTranslate"), selection: Binding(get: { selected }, set: { id in
                model.persist { if use == .polish { $0.refine.profileID = id } else { $0.translate.profileID = id } }
            })) {
                if model.llmProfiles.first(where: { $0.id == selected }) == nil { Text(L10n.tr("llm.choose")).tag(selected) }
                ForEach(model.llmProfiles) { p in Text(p.name + " · " + p.model).tag(p.id) }
            }
        }
    }
}

/// AI polish: on or off, which model, how.
struct TextRefineSection: View {
    @Bindable var model: SettingsModel
    var body: some View {
        Section {
            Toggle(L10n.tr("refine.enable"), isOn: Binding(get: { model.refine.enabled }, set: { value in model.persist { $0.refine.enabled = value } }))
            if model.refine.enabled {
                ProfilePicker(model: model, use: .polish)
                Picker(L10n.tr("refine.style"), selection: Binding(get: { model.refine.style }, set: { v in model.persist { $0.refine.style = v } })) {
                    Text(L10n.tr("refine.style.clean")).tag(RefineStyle.clean)
                    Text(L10n.tr("refine.style.formal")).tag(RefineStyle.formal)
                }.pickerStyle(.segmented)
            }
        } header: { Text(L10n.tr("refine.header")) } footer: {
            Text(L10n.tr("refine.hint")).font(.callout).foregroundStyle(.primary)
        }
    }
}

/// Voice translation: the language, and which model does it.
struct TranslateSection: View {
    @Bindable var model: SettingsModel
    @State private var customMode = false
    private static let otherTag = "\u{1}other"

    /// What the language picker shows: off, one of the listed languages, or "other" while the person types a language of their own.
    private var targetChoice: String {
        let t = model.translate.target
        if customMode { return Self.otherTag }
        if t.isEmpty { return "" }
        return TranslationLanguages.language(t) != nil ? t : Self.otherTag
    }
    private func setTarget(_ choice: String) {
        if choice == Self.otherTag {
            customMode = true
            if TranslationLanguages.language(model.translate.target) != nil { model.persist { $0.translate.target = "" } }
        } else {
            customMode = false
            model.persist { $0.translate.target = choice }
        }
    }

    var body: some View {
        Section {
            Picker(L10n.tr("translate.target"), selection: Binding(get: { targetChoice }, set: { setTarget($0) })) {
                Text(L10n.tr("translate.off")).tag("")
                ForEach(TranslationLanguages.all) { Text($0.display).tag($0.id) }
                Text(L10n.tr("translate.other")).tag(Self.otherTag)
            }
            if targetChoice == Self.otherTag {
                TextField(L10n.tr("translate.custom"), text: Binding(get: { model.translate.target }, set: { v in model.persist { $0.translate.target = TranslationLanguages.valid(v) ? v : $0.translate.target } }),
                          prompt: Text(L10n.tr("translate.custom.prompt"))).textFieldStyle(.roundedBorder).autocorrectionDisabled()
            }
            if model.translate.active { ProfilePicker(model: model, use: .translate) }
        } header: { Text(L10n.tr("translate.header")) } footer: {
            Text(L10n.tr("translate.hint")).font(.callout).foregroundStyle(.primary)
        }
    }
}

/// My AI models: add, edit, test and remove.
struct LLMModelsSection: View {
    @Bindable var model: SettingsModel
    @State private var editing: String?
    @State private var keyDraft = ""
    @State private var keySaved = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var models: [String] = []
    @State private var fetchingModels = false
    @State private var modelNote: String?
    @State private var confirmingDelete = false

    private var profile: LLMProfile? { model.llmProfiles.first { $0.id == editing } }
    private func update(_ id: String, _ change: @escaping (inout LLMProfile) -> Void) {
        model.persist { c in if let i = c.llmProfiles.firstIndex(where: { $0.id == id }) { change(&c.llmProfiles[i]) } }
    }
    private func service(_ p: LLMProfile) -> TextRefineSettings {
        var s = model.refine
        s.preset = p.preset; s.baseURL = p.baseURL; s.model = p.model; s.consent = p.consent; s.keyAccount = p.keyName
        return s
    }
    private func edit(_ id: String?) {
        editing = id; keyDraft = ""; testResult = nil; models = []; modelNote = nil; confirmingDelete = false
        keySaved = model.llmProfiles.first { $0.id == id }.map { KeychainStore.get($0.keyName)?.isEmpty == false } ?? false
    }

    var body: some View {
        Section {
            if model.llmProfiles.isEmpty { Text(L10n.tr("llm.empty")).foregroundStyle(.secondary) }
            ForEach(model.llmProfiles) { p in
                Button { edit(editing == p.id ? nil : p.id) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).foregroundStyle(.primary)
                            Text(subtitle(p)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.refine.profileID == p.id { badge(L10n.tr("llm.badge.polish")) }
                        if model.translate.profileID == p.id { badge(L10n.tr("llm.badge.translate")) }
                        Image(systemName: editing == p.id ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
                if editing == p.id { editor(p) }
            }
            Button { add() } label: { Label(L10n.tr("llm.add"), systemImage: "plus") }.disabled(model.llmProfiles.count >= LLMProfiles.maxProfiles)
        } header: { Text(L10n.tr("llm.header")) } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("llm.hint"))
                Text(L10n.tr("refine.hint.cloud"))
            }.font(.callout).foregroundStyle(.primary)
        }
    }

    private func subtitle(_ p: LLMProfile) -> String {
        var parts: [String] = [LLMPresets.preset(p.preset)?.name ?? L10n.tr("refine.custom")]
        parts.append(p.model.isEmpty ? L10n.tr("llm.noModel") : p.model)
        if p.isLocal { parts.append(L10n.tr("refine.thisMac")) }
        return parts.joined(separator: " · ")
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption).padding(.horizontal, 6).padding(.vertical, 1).background(Color.accentColor.opacity(0.15), in: Capsule()).foregroundStyle(Color.accentColor)
    }

    private func add() {
        let new = LLMProfile.make(preset: "deepseek", existing: model.llmProfiles)
        model.persist { c in
            c.llmProfiles.append(new)
            // The first model is what polish and translation use until the person picks another.
            if c.refine.profileID.isEmpty { c.refine.profileID = new.id }
            if c.translate.profileID.isEmpty { c.translate.profileID = new.id }
        }
        edit(new.id)
    }

    private func remove(_ p: LLMProfile) {
        _ = KeychainStore.delete(p.keyName)
        model.persist { c in
            c.llmProfiles.removeAll { $0.id == p.id }
            let fallback = c.llmProfiles.first?.id ?? ""
            if c.refine.profileID == p.id { c.refine.profileID = fallback }
            if c.translate.profileID == p.id { c.translate.profileID = fallback }
        }
        edit(nil)
    }

    @ViewBuilder private func editor(_ p: LLMProfile) -> some View {
        let needsKey = !p.isLocal && (LLMPresets.preset(p.preset)?.needsKey ?? true)
        VStack(alignment: .leading, spacing: 10) {
            TextField(L10n.tr("llm.name"), text: Binding(get: { p.name }, set: { v in if !v.isEmpty && v.count <= 60 { update(p.id) { $0.name = v } } })).textFieldStyle(.roundedBorder)
            Picker(L10n.tr("refine.service"), selection: Binding(get: { p.preset }, set: { id in
                update(p.id) { if let preset = LLMPresets.preset(id) { $0.preset = id; $0.baseURL = preset.baseURL; $0.model = preset.model } else { $0.preset = "custom" } }
                keyDraft = ""; testResult = nil; models = []; modelNote = nil
            })) {
                ForEach(LLMPreset.Group.allCases, id: \.self) { group in
                    Section(L10n.tr("refine.group.\(group.rawValue)")) { ForEach(LLMPresets.presets(in: group)) { Text($0.name).tag($0.id) } }
                }
                Section(L10n.tr("refine.group.other")) { Text(L10n.tr("refine.custom")).tag("custom") }
            }
            if let key = LLMPresets.preset(p.preset)?.noteKey { Label(L10n.tr(key), systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
            TextField(L10n.tr("refine.address"), text: Binding(get: { p.baseURL }, set: { v in update(p.id) { $0.baseURL = v } }), prompt: Text(verbatim: "https://api.example.com/v1"))
                .textFieldStyle(.roundedBorder).autocorrectionDisabled()
            if !p.baseURL.isEmpty && LLMEndpoint.url(p.baseURL) == nil {
                Label(L10n.tr("refine.address.invalid"), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            HStack {
                TextField(L10n.tr("refine.model"), text: Binding(get: { p.model }, set: { v in update(p.id) { $0.model = v } })).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                if !models.isEmpty {
                    Menu(L10n.tr("refine.models.pick")) { ForEach(models, id: \.self) { name in Button(name) { update(p.id) { $0.model = name } } } }.fixedSize()
                }
                Button(L10n.tr("refine.models.fetch")) { fetchModels(p) }.disabled(fetchingModels || LLMEndpoint.modelsURL(p.baseURL) == nil)
                if fetchingModels { ProgressView().controlSize(.small) }
            }
            if p.model.trimmingCharacters(in: .whitespaces).isEmpty && modelNote == nil {
                Label(L10n.tr("refine.model.hint"), systemImage: "arrow.up.right.circle").font(.callout).foregroundStyle(.secondary)
            }
            if let note = modelNote {
                Label(note, systemImage: models.isEmpty ? "exclamationmark.triangle" : "checkmark.circle").font(.callout).foregroundStyle(models.isEmpty ? Color.orange : Color.secondary)
            }
            if needsKey {
                HStack {
                    SecureField(L10n.tr("refine.key"), text: $keyDraft, prompt: Text(L10n.tr(keySaved ? "refine.key.saved" : "refine.key.prompt"))).textFieldStyle(.roundedBorder)
                    Button(L10n.tr("refine.key.save")) {
                        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !key.isEmpty, KeychainStore.set(key, for: p.keyName) else { return }
                        keyDraft = ""; keySaved = true; testResult = nil
                    }.disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if keySaved { Button(L10n.tr("refine.key.delete")) { _ = KeychainStore.delete(p.keyName); keySaved = false; testResult = nil } }
                }
            }
            if !p.isLocal { Toggle(L10n.tr("refine.consent"), isOn: Binding(get: { p.consent }, set: { v in update(p.id) { $0.consent = v } })) }
            HStack {
                Button(L10n.tr("refine.test")) { runTest(p) }.disabled(testing || !p.usable)
                if testing { ProgressView().controlSize(.small) }
                if let result = testResult {
                    Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").font(.callout)
                        .foregroundStyle(result.ok ? Color.green : Color.orange).lineLimit(3).textSelection(.enabled)
                }
                Spacer()
                if confirmingDelete {
                    Button(L10n.tr("llm.delete.confirm"), role: .destructive) { remove(p) }
                    Button(L10n.tr("llm.delete.cancel")) { confirmingDelete = false }
                } else {
                    Button(L10n.tr("llm.delete"), role: .destructive) { confirmingDelete = true }
                }
            }
        }.padding(.vertical, 6)
    }

    private func fetchModels(_ p: LLMProfile) {
        let current = service(p), key = KeychainStore.get(p.keyName)
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

    private func runTest(_ p: LLMProfile) {
        let sample = L10n.tr("refine.testSample"), current = service(p), key = KeychainStore.get(p.keyName)
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
