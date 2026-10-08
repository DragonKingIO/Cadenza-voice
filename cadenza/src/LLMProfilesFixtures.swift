import Foundation

/// Profiles of "my AI models": the old single service becomes one, uses pick their own, nothing leaks between them.
enum LLMProfilesFixtures {
    static func run(_ check: (String, Bool) -> Void) {
        func c(_ name: String, _ ok: Bool) { check("Profiles " + name, ok) }
        func decode(_ json: String) -> BridgeConfig? { try? JSONDecoder().decode(BridgeConfig.self, from: Data(json.utf8)) }
        func profile(_ id: String, _ model: String, preset: String = "deepseek", consent: Bool = true) -> LLMProfile {
            let p = LLMPresets.preset(preset)
            return LLMProfile(id: id, name: "Model " + id, preset: preset, baseURL: p?.baseURL ?? "https://api.example.com/v1", model: model, consent: consent)
        }

        // Older configuration: the single service becomes the first profile, once
        let old = decode(#"{"refine":{"enabled":true,"preset":"deepseek","baseURL":"https://api.deepseek.com/v1","model":"deepseek-chat","consent":true},"translate":{"target":"English"}}"#)
        c("migration: the single service becomes one profile used by both", old?.llmProfiles.count == 1 && old?.llmProfiles.first?.id == LLMProfiles.migratedID && old?.refine.profileID == LLMProfiles.migratedID && old?.translate.profileID == LLMProfiles.migratedID)
        c("migration: and keeps its key, model and consent", old?.llmProfiles.first?.keyName == "llm.deepseek" && old?.llmProfiles.first?.model == "deepseek-chat" && old?.llmProfiles.first?.consent == true && old?.llmProfiles.first?.name == "DeepSeek")
        c("migration: the resolved service is what it was", { guard let old else { return false }; let p = old.llmService(.polish), t = old.llmService(.translate)
            return p.baseURL == "https://api.deepseek.com/v1" && p.model == "deepseek-chat" && p.consent && p.keyName == "llm.deepseek" && p.enabled && t.keyName == "llm.deepseek" && t.configured }())
        c("migration: no service, no profile", decode("{}")?.llmProfiles.isEmpty == true)
        let again = old.flatMap { try? JSONEncoder().encode($0) }.flatMap { decode(String(data: $0, encoding: .utf8)!) }
        c("migration: saving and reading again changes nothing", again?.llmProfiles == old?.llmProfiles && again?.refine.profileID == LLMProfiles.migratedID)

        // Without profiles the old fields still work (tests and fresh settings)
        var plain = BridgeConfig.default()
        plain.refine.baseURL = "http://localhost:11434/v1"; plain.refine.model = "m"; plain.refine.preset = "ollama"
        c("resolver: no profile chosen means the fields themselves", plain.llmService(.polish).baseURL == "http://localhost:11434/v1" && plain.llmService(.translate).model == "m" && plain.llmService(.polish).keyName == "llm.ollama")

        // Two uses, two models
        var two = BridgeConfig.default()
        two.llmProfiles = [profile("aaa", "polish-model"), profile("bbb", "translate-model", preset: "openai", consent: false)]
        two.refine.profileID = "aaa"; two.translate.profileID = "bbb"; two.refine.enabled = true; two.refine.style = .formal
        let polish = two.llmService(.polish), translate = two.llmService(.translate)
        c("resolver: each use gets its own model, address, key and consent", polish.model == "polish-model" && translate.model == "translate-model" && polish.baseURL != translate.baseURL
          && polish.keyName == "llm.profile.aaa" && translate.keyName == "llm.profile.bbb" && polish.consent && !translate.consent)
        c("resolver: the switch, style and time-out belong to the use, not the model", polish.enabled && polish.style == .formal && translate.style == .formal && translate.timeoutSec == polish.timeoutSec)
        two.llmProfiles.removeAll { $0.id == "bbb" }
        c("resolver: a deleted model leaves the use without a service", !two.llmService(.translate).configured && two.llmService(.polish).configured)
        two.refine.profileID = "zzz"
        c("resolver: an unknown profile is not a service", !two.llmService(.polish).configured)

        // Profiles themselves
        c("profile: a valid one", profile("aaa", "m").problem == nil && profile("aaa", "m", preset: "ollama").isLocal && profile("aaa", "").usable == false && profile("aaa", "m").usable)
        c("profile: ids, names, addresses and key names are checked", { var p = profile("aaa", "m"); p.id = "A b"; let badID = p.problem != nil
            p = profile("aaa", "m"); p.name = ""; let badName = p.problem != nil
            p = profile("aaa", "m"); p.baseURL = "http://api.example.com/v1"; let badURL = p.problem != nil
            p = profile("aaa", "m"); p.keyName = "../x"; let badKey = p.problem != nil
            p = profile("aaa", "m"); p.preset = "nope"; let badPreset = p.problem != nil
            return badID && badName && badURL && badKey && badPreset }())
        c("list: duplicates and too many are refused", LLMProfiles.problem([profile("aaa", "m"), profile("bbb", "m")]) == nil && LLMProfiles.problem([profile("aaa", "m"), profile("aaa", "n")]) != nil
          && LLMProfiles.problem((0..<21).map { profile("p\($0)", "m") }) != nil && LLMProfiles.problem([profile("aaa", "m"), { var p = profile("bbb", "m"); p.keyName = "llm.profile.aaa"; return p }()]) != nil)
        c("list: a configuration with a broken list is refused", { var cfg = BridgeConfig.default(); cfg.llmProfiles = [profile("aaa", "m"), profile("aaa", "n")]; return !BridgeConfig.validate(cfg).isEmpty }() && BridgeConfig.validate(BridgeConfig.default()).isEmpty)
        c("make: new profiles get unique ids, names and key names", { var list: [LLMProfile] = []; for _ in 0..<5 { list.append(LLMProfile.make(preset: "deepseek", existing: list)) }
            return Set(list.map(\.id)).count == 5 && Set(list.map(\.name)).count == 5 && Set(list.map(\.keyName)).count == 5 && LLMProfiles.problem(list) == nil && list[0].baseURL == "https://api.deepseek.com/v1" }())
        c("make: an unknown preset becomes a custom one", LLMProfile.make(preset: "nope", existing: []).preset == "custom" && LLMProfile.make(preset: "nope", existing: []).baseURL.isEmpty)
        c("codec: broken fields fall back", { let p = try? JSONDecoder().decode(LLMProfile.self, from: Data(#"{"id":"abc","baseURL":5,"consent":"x"}"#.utf8)); return p?.id == "abc" && p?.baseURL == "" && p?.consent == false && p?.keyName == "llm.profile.abc" }())
        c("codec: a bad profile id in a use is dropped", { let t = try? JSONDecoder().decode(TranslateSettings.self, from: Data(#"{"target":"English","profileID":"../x"}"#.utf8)); let r = try? JSONDecoder().decode(TextRefineSettings.self, from: Data(#"{"profileID":"A B"}"#.utf8)); return t?.profileID == "" && r?.profileID == "" }())
        c("key name: the profile's account is used, else the preset's", { var s = TextRefineSettings(); s.preset = "openai"; let before = s.keyName; s.keyAccount = "llm.profile.q"; return before == "llm.openai" && s.keyName == "llm.profile.q" }())
    }
}
