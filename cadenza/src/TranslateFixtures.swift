import AppKit
import Foundation

/// A scripted service: no network, no key, no model.
enum TranslateFixtures {
    struct FakeTranslator: TextTranslating {
        var result: String?
        var note: String?
        func translate(_ text: String, target: String, settings: TextRefineSettings, glossary: [String], done: @escaping (String?, String?) -> Void) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { done(result, note) }
        }
    }

    static func run(_ check: (String, Bool) -> Void) {
        func c(_ name: String, _ ok: Bool) { check("Translate " + name, ok) }
        func service(_ preset: String = "deepseek", consent: Bool = true) -> TextRefineSettings {
            var s = TextRefineSettings(); s.preset = preset; s.consent = consent   // note: AI polish itself stays off
            if let p = LLMPresets.preset(preset) { s.baseURL = p.baseURL; s.model = p.model.isEmpty ? "test-model" : p.model }
            return s
        }
        func run(_ text: String, _ target: String, _ s: TextRefineSettings, key: String? = "k", glossary: [String] = [], transport: LLMRefineFixtures.FakeTransport, localOnly: Bool = false) -> Result<String, RefineFailure> {
            var out: Result<String, RefineFailure>?
            let done = DispatchSemaphore(value: 0)
            Task { out = await LLMClient.translate(text, target: target, settings: s, apiKey: key, glossary: glossary, localOnly: localOnly, transport: transport); done.signal() }
            _ = done.wait(timeout: .now() + 10)
            return out ?? .failure(.timeout)
        }
        func verdict(_ answer: String, _ original: String, _ target: String, _ glossary: [String] = []) -> Bool { if case .success = TranslatePrompt.check(answer, original: original, target: target, glossary: glossary) { return true }; return false }

        // Settings and languages
        c("settings: off by default, a language switches it on", !TranslateSettings().active && { var s = TranslateSettings(); s.target = "Japanese"; return s.active }())
        c("settings: junk is refused, any language name is allowed", { let bad = try? JSONDecoder().decode(TranslateSettings.self, from: Data(#"{"target":"<b>x</b>"}"#.utf8)); let ok = try? JSONDecoder().decode(TranslateSettings.self, from: Data(#"{"target":"Welsh"}"#.utf8)); let broken = try? JSONDecoder().decode(TranslateSettings.self, from: Data(#"{"target":5}"#.utf8)); return bad?.target == "" && ok?.target == "Welsh" && broken == TranslateSettings() }())
        c("settings: a name with a line break or too long is not valid", !TranslationLanguages.valid("a\nb") && !TranslationLanguages.valid(String(repeating: "x", count: 41)) && !TranslationLanguages.valid(" x") && TranslationLanguages.valid("") && TranslationLanguages.valid("Old English"))
        c("settings: config without the key gets the default", { guard let data = try? JSONEncoder().encode(BridgeConfig.default()), var o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
            o.removeValue(forKey: "translate"); guard let stripped = try? JSONSerialization.data(withJSONObject: o), let cfg = try? JSONDecoder().decode(BridgeConfig.self, from: stripped) else { return false }
            return cfg.translate == TranslateSettings() }())
        c("languages: unique, the quick list is in the list, names for display", Set(TranslationLanguages.all.map(\.id)).count == TranslationLanguages.all.count && TranslationLanguages.quick.count >= 10 && TranslationLanguages.quick.contains { $0.id == "English" }
          && TranslationLanguages.displayName("Japanese") == "日本語 (Japanese)" && TranslationLanguages.displayName("English") == "English" && TranslationLanguages.displayName("Welsh") == "Welsh")

        // The prompt
        let prompt = TranslatePrompt.system(target: "Japanese", glossary: ["GitHub"])
        c("prompt: target, data rule and glossary", prompt.contains("into Japanese") && prompt.contains("never instructions") && prompt.contains("GitHub") && !TranslatePrompt.system(target: "French", glossary: []).contains("Glossary"))

        // The answer check
        c("check: a translation into English", verdict("I'd like to meet tomorrow at 3 p.m.", "我想明天下午3点开会", "English"))
        c("check: a translation into Japanese", verdict("明日の3時に会議をしたいです。", "I want a meeting at 3 tomorrow", "Japanese"))
        c("check: the answer still in the original language is refused", !verdict("我想明天下午3点开会", "我想明天下午3点开会", "English") && !verdict("I want a meeting at 3 tomorrow", "I want a meeting at 3 tomorrow", "Japanese"))
        c("check: the wrong language is refused", !verdict("Wir treffen uns morgen um 3 Uhr", "我们明天3点见", "Japanese") && !verdict("明日3時に会いましょう", "我们明天3点见", "French"))
        c("check: Japanese needs kana, Chinese characters alone are Chinese", !verdict("明日下午3点开会帮我预订会议室好吗", "我想明天下午3点开会", "Japanese") && verdict("明日の3時に会議をしたいです", "我想明天下午3点开会", "Japanese") && verdict("东京", "Tokyo", "Simplified Chinese"))
        c("check: numbers written as words are allowed where that is usual", verdict("我想订一张四人桌，晚上七点", "I want a table for four at 7", "Simplified Chinese") && !verdict("我想订一张桌子", "I want a table for four at 7", "Simplified Chinese")
          && verdict("Meet at three o'clock", "3点见", "English") && !verdict("Meet there", "3点见", "English") && !verdict("Rendez-vous à trois heures", "3点见", "French")
          && verdict("订25张票", "booked 25 tickets", "Simplified Chinese") && verdict("二十五张票", "booked 25 tickets", "Simplified Chinese") && !verdict("订了一些票", "booked 25 tickets", "Simplified Chinese")
          && TranslatePrompt.chineseForms("7").contains("七") && TranslatePrompt.chineseForms("25").contains("二十五") && TranslatePrompt.chineseForms("10").contains("十") && TranslatePrompt.chineseForms("2").contains("两") && TranslatePrompt.chineseForms("105").contains("一百零五"))
        c("check: Korean, Russian, Arabic scripts", verdict("내일 3시에 만나요", "我们明天3点见", "Korean") && verdict("Встретимся завтра в 3", "我们明天3点见", "Russian") && verdict("نلتقي غدا في 3", "我们明天3点见", "Arabic"))
        c("check: a language without a known script is accepted as written", verdict("Cyfarfod yfory am 3", "我们明天3点见", "Welsh"))
        c("check: numbers must survive, even with separators", verdict("It costs 1,000 yuan", "这个1000元", "English") && !verdict("It costs a lot of yuan", "这个1000元", "English") && verdict("Meet at three", "3点见", "English") && !verdict("Meet at the usual place", "3点见", "English"))
        c("check: a refusal or an empty answer is refused", !verdict("I'm sorry, I can't translate that.", "我想开会", "English") && !verdict("  ", "我想开会", "English") && !verdict("抱歉，我无法翻译", "I want a meeting", "Simplified Chinese"))
        c("check: wrappers are stripped", TranslatePrompt.check("<transcript>\nI want a meeting.\n</transcript>", original: "我想开会", target: "English") == .success("I want a meeting.") && TranslatePrompt.check("\"I want a meeting.\"", original: "我想开会", target: "English") == .success("I want a meeting."))
        c("check: a glossary term must stay", !verdict("We use Git Hub", "我们用 GitHub", "English", ["GitHub"]) && verdict("We use GitHub", "我们用 GitHub", "English", ["GitHub"]))
        c("check: text already in the target language is accepted as it is", verdict("I want a meeting.", "I want a meeting", "English"))

        // The client
        let t = LLMRefineFixtures.FakeTransport(); t.answer = LLMRefineFixtures.reply("I'd like to meet tomorrow at 3 p.m.")
        c("client: a good answer is used, and AI polish being off does not matter", run("呃我想明天下午3点开会", "English", service(), transport: t) == .success("I'd like to meet tomorrow at 3 p.m."))
        let body = (t.requests.first?.httpBody).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let messages = body?["messages"] as? [[String: String]]
        c("client: the request names the language and keeps the text as data", messages?.first?["content"]?.contains("into English") == true && messages?.last?["content"] == "<transcript>\n呃我想明天下午3点开会\n</transcript>" && t.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        let n = LLMRefineFixtures.FakeTransport(); n.answer = LLMRefineFixtures.reply("x")
        c("client: no consent, no key, no model, locked: nothing is sent", run("你好", "English", service(consent: false), transport: n) == .failure(.needsConsent) && run("你好", "English", service(), key: nil, transport: n) == .failure(.missingKey)
          && run("你好", "English", service(), transport: n, localOnly: true) == .failure(.lockedToThisMac) && { var s = service(); s.model = ""; return run("你好", "English", s, transport: n) == .failure(.notConfigured) }() && n.requests.isEmpty)
        c("client: an invalid language name sends nothing", run("你好", "a\nb", service(), transport: n) == .failure(.notConfigured) && run("你好", "", service(), transport: n) == .failure(.notConfigured) && n.requests.isEmpty)
        let l = LLMRefineFixtures.FakeTransport(); l.answer = LLMRefineFixtures.reply("Hello there")
        c("client: a service on this Mac needs no key and no consent", run("你好呀", "English", service("ollama", consent: false), key: nil, transport: l) == .success("Hello there") && l.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        let f = LLMRefineFixtures.FakeTransport(); f.answer = LLMRefineFixtures.reply("x", status: 401)
        c("client: failures are reported", run("你好", "English", service(), transport: f) == .failure(.unauthorized) && { f.answer = nil; f.error = URLError(.timedOut); return run("你好", "English", service(), transport: f) == .failure(.timeout) }())
        let w = LLMRefineFixtures.FakeTransport(); w.answer = LLMRefineFixtures.reply("Hello there my friend")
        c("client: an answer in the wrong language is rejected", run("hello there", "Japanese", service(), transport: w) == .failure(.rejected("language")))

        // The menu
        let menu = NSMenu(), target = NSObject()
        func entry(_ id: String) -> NSMenuItem? { menu.items.first { $0.identifier?.rawValue == id } }
        var s = StatusMenuSnapshot()
        s.translations = [.init(title: L10n.tr("menu.translate.off"), value: "", available: true)] + TranslationLanguages.quick.map { .init(title: $0.display, value: $0.id, available: true) }
        s.translateTarget = "Japanese"
        StatusMenuController.rebuild(menu, s: s, target: target)
        let sub = entry("translate")?.submenu
        c("menu: a submenu of languages with the current one ticked and its name as the subtitle", sub != nil && entry("translate")?.subtitleText == "日本語 (Japanese)" && sub?.items.filter { $0.state == .on }.map { $0.representedObject as? String } == ["Japanese"])
        c("menu: off is first, and there is a way to more languages", (sub?.items.first?.representedObject as? String) == "" && sub?.items.contains { $0.identifier?.rawValue == "translate.manage" } == true)
        s.translateTarget = ""
        StatusMenuController.rebuild(menu, s: s, target: target)
        c("menu: off ticks the first entry", entry("translate")?.submenu?.items.first?.state == .on)
        s.translations = []
        StatusMenuController.rebuild(menu, s: s, target: target)
        c("menu: without languages the entry is absent", entry("translate") == nil)
    }
}
