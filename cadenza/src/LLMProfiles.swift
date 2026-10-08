import Foundation

// "My AI models": any number of chat-completions services the person adds (a service, an address, a model, a key), each
// kept under its own name. AI polish and voice translation each pick the one they use, so translation can use a different
// model than polish, or a model added only for it.

struct LLMProfile: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// A `LLMPreset.id`, or "custom".
    var preset: String
    var baseURL: String
    var model: String
    /// Permission to send text to this service when it is not on this Mac.
    var consent: Bool
    /// The Keychain account holding this profile's API key.
    var keyName: String

    init(id: String, name: String, preset: String, baseURL: String, model: String, consent: Bool = false, keyName: String? = nil) {
        self.id = id; self.name = name; self.preset = preset; self.baseURL = baseURL; self.model = model; self.consent = consent
        self.keyName = keyName ?? Self.keyName(for: id)
    }
    static func keyName(for id: String) -> String { "llm.profile." + id }

    enum CodingKeys: String, CodingKey { case id, name, preset, baseURL, model, consent, keyName }
    init(from decoder: Decoder) throws {
        let d = try decoder.container(keyedBy: CodingKeys.self)
        id = try d.decode(String.self, forKey: .id)
        name = (try? d.decodeIfPresent(String.self, forKey: .name)) ?? id
        preset = (try? d.decodeIfPresent(String.self, forKey: .preset)) ?? "custom"
        baseURL = (try? d.decodeIfPresent(String.self, forKey: .baseURL)) ?? ""
        model = (try? d.decodeIfPresent(String.self, forKey: .model)) ?? ""
        consent = (try? d.decodeIfPresent(Bool.self, forKey: .consent)) ?? false
        keyName = (try? d.decodeIfPresent(String.self, forKey: .keyName)) ?? Self.keyName(for: id)
    }

    /// A new profile for a preset service, with the address and the suggested model filled in.
    static func make(preset presetID: String, existing: [LLMProfile]) -> LLMProfile {
        var id: String
        repeat { id = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)) } while existing.contains { $0.id == id }
        let p = LLMPresets.preset(presetID)
        let base = p?.name ?? L10n.tr("refine.custom")
        var name = base, n = 2
        while existing.contains(where: { $0.name == name }) { name = base + " " + String(n); n += 1 }
        return LLMProfile(id: id, name: name, preset: p?.id ?? "custom", baseURL: p?.baseURL ?? "", model: p?.model ?? "")
    }

    var isLocal: Bool { LLMEndpoint.isLoopback(baseURL) }
    var usable: Bool { LLMEndpoint.url(baseURL) != nil && !model.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Problem with this profile's own fields, or nil.
    var problem: String? {
        guard id.range(of: "^[a-z0-9]{1,16}$", options: .regularExpression) != nil else { return "id" }
        guard !name.isEmpty, name.count <= 60, !name.contains(where: \.isNewline) else { return "name" }
        guard preset == "custom" || LLMPresets.preset(preset) != nil else { return "preset" }
        guard baseURL.isEmpty || LLMEndpoint.url(baseURL) != nil, model.count <= 200, !model.contains(where: \.isNewline) else { return "address" }
        guard keyName.range(of: "^llm\\.[A-Za-z0-9._-]{1,60}$", options: .regularExpression) != nil else { return "key" }
        return nil
    }
}

enum LLMUse { case polish, translate }

enum LLMProfiles {
    static let maxProfiles = 20
    /// The id of the profile made from a configuration written before profiles existed.
    static let migratedID = "main"

    static func problem(_ profiles: [LLMProfile]) -> String? {
        guard profiles.count <= maxProfiles, Set(profiles.map(\.id)).count == profiles.count, Set(profiles.map(\.keyName)).count == profiles.count else { return "list" }
        return profiles.compactMap(\.problem).first
    }
}

extension BridgeConfig {
    func llmProfile(_ id: String) -> LLMProfile? { llmProfiles.first { $0.id == id } }
    var polishProfileID: String { refine.profileID }
    var translateProfileID: String { translate.profileID }

    /// The service settings AI polish or translation should use: the chosen profile's address, model, consent and key, with the
    /// switch, style and time-out that belong to the use. A configuration without profiles keeps working through the fields it
    /// always had. A profile that was deleted leaves the use without a service, so it asks to be set up again.
    func llmService(_ use: LLMUse) -> TextRefineSettings {
        var s = refine
        let id = use == .polish ? refine.profileID : translate.profileID
        guard !id.isEmpty else { return s }
        guard let p = llmProfile(id) else { s.baseURL = ""; s.model = ""; return s }
        s.preset = p.preset; s.baseURL = p.baseURL; s.model = p.model; s.consent = p.consent; s.keyAccount = p.keyName
        return s
    }

    /// Makes a profile from the single service of an older configuration, once.
    mutating func migrateLLMProfiles() {
        guard llmProfiles.isEmpty, !refine.baseURL.isEmpty, refine.profileID.isEmpty, translate.profileID.isEmpty else { return }
        let name = LLMPresets.preset(refine.preset)?.name ?? L10n.tr("refine.custom")
        llmProfiles = [LLMProfile(id: LLMProfiles.migratedID, name: name, preset: refine.preset, baseURL: refine.baseURL, model: refine.model, consent: refine.consent, keyName: "llm." + refine.preset)]
        refine.profileID = LLMProfiles.migratedID
        translate.profileID = LLMProfiles.migratedID
    }
}
