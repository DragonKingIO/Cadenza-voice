import Foundation

/// Fixed sentences, scratch folders only: no real packs file of the person's, no network.
enum VocabularyFixtures {
    static func run(_ check: (String, Bool) -> Void) {
        func c(_ name: String, _ ok: Bool) { check("Vocabulary " + name, ok) }
        func pack(_ terms: [VocabEntry]) -> [VocabTerm] { terms.map { VocabTerm(term: $0.term, aliases: $0.aliases, fromUser: false) } }
        func user(_ terms: [VocabEntry]) -> [VocabTerm] { terms.map { VocabTerm(term: $0.term, aliases: $0.aliases, fromUser: true) } }
        func fix(_ text: String, _ terms: [VocabTerm]) -> String { VocabularyMatcher.apply(text, terms: terms) }
        let gh = VocabEntry(term: "GitHub", aliases: ["吉特哈勃", "git hub"])
        let dev = pack([gh, VocabEntry(term: "Node.js"), VocabEntry(term: "OpenAI"), VocabEntry(term: "API"), VocabEntry(term: "React"), VocabEntry(term: "VS Code"), VocabEntry(term: "iOS"), VocabEntry(term: "糖尿病")])

        // Aliases
        c("alias: Chinese mishearing of an English name", fix("把代码提交到吉特哈勃上", dev) == "把代码提交到GitHub上")
        c("alias: spaced English", fix("push it to git hub now", dev) == "push it to GitHub now" && fix("Git Hub is down", dev) == "GitHub is down")
        c("alias: only whole words", fix("digit hubs and gitHubby", dev) == "digit hubs and gitHubby")

        // English terms: apart, joined, in the wrong case
        c("english: written apart or joined", fix("node js and open ai", dev) == "Node.js and OpenAI" && fix("the open-ai team", dev) == "the OpenAI team" && fix("vs code and vscode", dev) == "VS Code and VS Code")
        c("english: wrong case of a name with a capital inside or a digit", fix("use github and ios", dev) == "use GitHub and iOS" && fix("call the api", dev) == "call the API")
        c("english: a plain word is not re-cased from a pack", fix("how did they react", dev) == "how did they react")
        c("english: but is when the person added it", fix("how did they react", user([VocabEntry(term: "React")])) == "how did they React")
        c("english: names inside addresses are left alone", fix("open github.com/apple and mail me@github.io or /usr/github/x", dev) == "open github.com/apple and mail me@github.io or /usr/github/x")
        c("english: a window needs a single space or hyphen between words", fix("open, ai", dev) == "open, ai" && fix("node  js", dev) == "node  js")
        c("english: already right stays", fix("GitHub, Node.js and OpenAI", dev) == "GitHub, Node.js and OpenAI")

        // Chinese homophones
        c("homophone: a pack term of three or more characters", fix("他得了糖尿饼", dev) == "他得了糖尿病" && fix("糖尿病", dev) == "糖尿病")
        c("homophone: not for a two-character pack term, but for the person's own", fix("岁言真好", pack([VocabEntry(term: "随言")])) == "岁言真好" && fix("岁言真好", user([VocabEntry(term: "随言")])) == "随言真好")
        c("homophone: different sound is not replaced", fix("糖尿饼和高血压", pack([VocabEntry(term: "糖尿病")])) == "糖尿病和高血压" && fix("糖尿的", pack([VocabEntry(term: "糖尿病")])) == "糖尿的")
        c("pinyin reads tones off", VocabularyMatcher.pinyinKey("糖尿病") == "tang niao bing" && VocabularyMatcher.pinyinKey("岁言") == "sui yan" && VocabularyMatcher.pinyinKey("ab") == nil)

        // Protected text and overlaps
        c("protected: code and links are not touched", fix("run `git hub` and see https://example.com/吉特哈勃", dev) == "run `git hub` and see https://example.com/吉特哈勃")
        c("overlap: the longer match wins", fix("吉特哈勃 Actions", pack([VocabEntry(term: "GitHub", aliases: ["吉特哈勃"]), VocabEntry(term: "GitHub Actions", aliases: ["吉特哈勃 Actions"])])) == "GitHub Actions")
        c("nothing to do", fix("今天天气很好", dev) == "今天天气很好" && fix("", dev) == "" && fix("abc", []) == "abc")

        // Validation
        func problem(_ id: String = "my-pack", license: String = "CC0-1.0", entries: [VocabEntry] = [VocabEntry(term: "A1")]) -> String? { var p = VocabPack(id: id, name: ["en": "X"], license: license, entries: entries); p.schema = 1; return VocabularyRules.problem(p) }
        c("rules: a good pack", problem() == nil)
        c("rules: id, license and size", problem("My Pack") != nil && problem("-x") != nil && problem(license: "proprietary") != nil && problem(entries: []) != nil)
        c("rules: terms and aliases", problem(entries: [VocabEntry(term: "")]) != nil && problem(entries: [VocabEntry(term: "a`b")]) != nil && problem(entries: [VocabEntry(term: "A", aliases: ["a"])]) != nil
          && problem(entries: [VocabEntry(term: "A"), VocabEntry(term: "a")]) != nil && problem(entries: [VocabEntry(term: "A", aliases: Array(repeating: "x", count: 2))]) != nil
          && problem(entries: [VocabEntry(term: String(repeating: "长", count: 61))]) != nil && problem(entries: [VocabEntry(term: "A", aliases: (0..<13).map { "alias\($0)" })]) != nil)

        // Shared packs shipped with the app
        let shipped = VocabularyStore.shared.packs
        c("packs: the shipped packs are found and valid", shipped.count >= 5 && shipped.allSatisfy { VocabularyRules.problem($0) == nil })
        c("packs: ids are unique and the useful ones are on by default", Set(shipped.map(\.id)).count == shipped.count && shipped.first { $0.id == "developer" }?.enabledByDefault == true && shipped.first { $0.id == "medical-zh" }?.enabledByDefault == false)
        var owners: [String: String] = [:], clash = false
        for p in shipped { for e in p.entries { for a in e.aliases { let k = a.lowercased(); if let o = owners[k], o != e.term { clash = true }; owners[k] = e.term } } }
        c("packs: no alias points at two different terms", !clash)
        let everyTerm = shipped.flatMap(\.entries)
        c("packs: the shipped terms do their job", fix("把代码提交到吉特哈勃上", pack(everyTerm)) == "把代码提交到GitHub上" && fix("装一个多克和库伯内特斯", pack(everyTerm)) == "装一个Docker和Kubernetes" && fix("我用派森写杰森", pack(everyTerm)) == "我用Python写JSON")
        c("packs: ordinary sentences are not changed by any pack", ["今天下午三点开会，请提前十分钟到。", "我想只用本地识别，不想用云端。", "Please send the file to the product manager.", "We meet tomorrow at three thirty in the conference room.", "明天我要去北京见李明和王芳。", "Open the settings and turn on local recognition."].allSatisfy { fix($0, pack(everyTerm)) == $0 })

        // Speed: every shipped pack on a long dictation must not delay the insertion noticeably
        let long = String(repeating: "今天下午三点开会，请提前十分钟到，我们要讨论 the plan for the next release 和预算的问题。", count: 12)
        let started = ProcessInfo.processInfo.systemUptime
        let everything = pack(everyTerm)
        let result = fix(long, everything)
        let seconds = ProcessInfo.processInfo.systemUptime - started
        print("[selftest] vocabulary speed: \(everything.count) terms on \(long.count) characters took \(String(format: "%.3f", seconds)) s")
        c("speed: all shipped packs on a long text take well under a second", result == long && seconds < 1.0)

        // Settings
        var settings = VocabularySettings()
        let developer = VocabPack(id: "developer", name: ["en": "D"], entries: [VocabEntry(term: "X")]), medical = VocabPack(id: "m", name: ["en": "M"], entries: [VocabEntry(term: "Y")])
        var onByDefault = developer; onByDefault.enabledByDefault = true
        c("settings: default on or off per pack, overridden by the person", settings.isOn(onByDefault) && !settings.isOn(medical) && { settings.packOverrides["m"] = true; settings.packOverrides["developer"] = false; return settings.isOn(medical) && !settings.isOn(onByDefault) }())
        c("settings: broken data falls back", { let s = try? JSONDecoder().decode(VocabularySettings.self, from: Data(#"{"enabled":"x","packOverrides":3}"#.utf8)); return s == VocabularySettings() }())
        c("config without the key gets the default", { guard let data = try? JSONEncoder().encode(BridgeConfig.default()), var o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
            o.removeValue(forKey: "vocabulary"); guard let stripped = try? JSONSerialization.data(withJSONObject: o), let cfg = try? JSONDecoder().decode(BridgeConfig.self, from: stripped) else { return false }
            return cfg.vocabulary == VocabularySettings() }())

        // Store: scratch folder, own file
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cadenza-vocab-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let packs = dir.appendingPathComponent("packs", isDirectory: true)
        try? FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
        var shippedPack = VocabPack(id: "dev", name: ["en": "Dev"], entries: [VocabEntry(term: "GitHub", aliases: ["吉特哈勃"]), VocabEntry(term: "Kubernetes")]); shippedPack.enabledByDefault = true
        try? JSONEncoder().encode(shippedPack).write(to: packs.appendingPathComponent("dev.json"))
        try? Data("not json".utf8).write(to: packs.appendingPathComponent("broken.json"))
        var badPack = shippedPack; badPack.id = "Bad Id"
        try? JSONEncoder().encode(badPack).write(to: packs.appendingPathComponent("bad.json"))
        let store = VocabularyStore()
        store.packDirectories = [packs]; store.userFile = dir.appendingPathComponent("vocabulary.json"); store.reload()
        c("store: valid packs load, broken and invalid ones are skipped", store.packs.map(\.id) == ["dev"] && store.user.isEmpty)
        c("store: a pack's terms apply", store.apply("用吉特哈勃", VocabularySettings()) == "用GitHub")
        c("store: switched off, nothing applies", { var s = VocabularySettings(); s.enabled = false; return store.apply("用吉特哈勃", s) == "用吉特哈勃" }())
        c("store: a pack the person switched off does nothing", { var s = VocabularySettings(); s.packOverrides["dev"] = false; return store.apply("用吉特哈勃", s) == "用吉特哈勃" }())
        c("store: the person's terms are saved and survive a reload", store.setUser([VocabEntry(term: "随言", aliases: ["岁言"]), VocabEntry(term: "GitHub", aliases: ["哈勃"])]) && { store.reload(); return store.user.count == 2 }())
        c("store: the person's term and the pack's join: both aliases work", store.apply("用哈勃和吉特哈勃", VocabularySettings()) == "用GitHub和GitHub")
        c("store: invalid or repeated terms are refused and nothing changes", !store.setUser([VocabEntry(term: "a"), VocabEntry(term: "A")]) && !store.setUser([VocabEntry(term: "")]) && store.user.count == 2)
        c("store: the glossary has the person's terms and the pack terms that occur", { let g = store.glossary(for: "we use GitHub and Kubernetes today", VocabularySettings()); return g.contains("随言") && g.contains("GitHub") && g.contains("Kubernetes") }()
          && !store.glossary(for: "nothing here", VocabularySettings()).contains("Kubernetes"))
        try? FileManager.default.removeItem(at: dir)

        // Import and export
        c("import: a pack file", VocabularyImport.parse(try! JSONEncoder().encode(shippedPack))?.count == 2)
        c("import: a JSON list", VocabularyImport.parse(Data(#"[{"term":"Foo","aliases":["fu"]},{"term":"Bar"}]"#.utf8))?.map(\.term) == ["Foo", "Bar"])
        c("import: plain lines with aliases and comments", VocabularyImport.parse(Data("# my terms\nGitHub | 吉特哈勃，git hub\n\nKubernetes\n".utf8)) == [VocabEntry(term: "GitHub", aliases: ["吉特哈勃", "git hub"]), VocabEntry(term: "Kubernetes")])
        c("import: nothing usable is nil", VocabularyImport.parse(Data("   \n#only a comment".utf8)) == nil && VocabularyImport.parse(Data()) == nil)
        c("import: bad lines are dropped, good ones kept", VocabularyImport.parse(Data("Good\nbad`line\n".utf8))?.map(\.term) == ["Good"])
        c("import: an alias equal to the term is dropped, not fatal", VocabularyImport.parse(Data("GitHub | github, 吉特哈勃".utf8)) == [VocabEntry(term: "GitHub", aliases: ["吉特哈勃"])])
        c("import: merging joins aliases of a term already there", VocabularyImport.merge([VocabEntry(term: "GitHub", aliases: ["a"])], [VocabEntry(term: "github", aliases: ["b"]), VocabEntry(term: "New")]) == [VocabEntry(term: "GitHub", aliases: ["a", "b"]), VocabEntry(term: "New")])
        c("export: a valid pack that reads back", { guard let data = VocabularyImport.exportData([VocabEntry(term: "GitHub", aliases: ["吉特哈勃"])]), let back = try? JSONDecoder().decode(VocabPack.self, from: data) else { return false }
            return VocabularyRules.problem(back) == nil && back.entries == [VocabEntry(term: "GitHub", aliases: ["吉特哈勃"])] }())
    }
}
