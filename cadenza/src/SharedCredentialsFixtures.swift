import Foundation

enum SharedCredentialsFixtures {
    static func run(_ check: (String, Bool) -> Void) {
        func c(_ name: String, _ ok: Bool) { check("SharedCredentials " + name, ok) }
        var items: [String: String] = [:]
        let read: (String) -> String? = { items[$0] }

        // The lookup
        c("table: every entry points back at the key it came from", SharedCredentials.alternates.allSatisfy { key, others in others.allSatisfy { SharedCredentials.alternates[$0]?.contains(key) == true } })
        c("table: Tencent, Baidu, Google and Azure keys are shared, nothing else is",
          SharedCredentials.alternates["tencent.secretid"] == ["ocr.tencent.secretid"] && SharedCredentials.alternates["ocr.baidu.apikey"] == ["baidu.apikey"]
          && SharedCredentials.alternates["tencent.appid"] == nil && SharedCredentials.alternates["ocr.google.apikey"] == ["google.apikey"] && SharedCredentials.alternates["deepgram.apikey"] == nil && SharedCredentials.alternates["azure.apikey"] == ["ocr.azure.apikey"])
        c("get: nothing saved gives nothing", SharedCredentials.get("ocr.tencent.secretid", read: read) == nil && !SharedCredentials.has("ocr.tencent.secretid", read: read))
        items["tencent.secretid"] = "ID-1"
        c("get: a key saved for speech recognition serves text recognition", SharedCredentials.get("ocr.tencent.secretid", read: read) == "ID-1" && SharedCredentials.isShared("ocr.tencent.secretid", read: read))
        items["ocr.tencent.secretid"] = "ID-2"
        c("get: a key of its own wins and is not shared", SharedCredentials.get("ocr.tencent.secretid", read: read) == "ID-2" && !SharedCredentials.isShared("ocr.tencent.secretid", read: read) && SharedCredentials.get("tencent.secretid", read: read) == "ID-1")
        items["ocr.tencent.secretid"] = ""
        c("get: an empty key counts as not saved", SharedCredentials.get("ocr.tencent.secretid", read: read) == "ID-1")
        items = ["ocr.baidu.apikey": "B-1"]
        c("get: the other direction works too", SharedCredentials.get("baidu.apikey", read: read) == "B-1")
        c("get: a key with no counterpart is only itself", { items = ["tencent.appid": "A"]; return SharedCredentials.get("ocr.tencent.appid", read: read) == nil && SharedCredentials.get("tencent.appid", read: read) == "A" }())

        // AI models of the same company
        let savedModels = SharedCredentials.aiModels
        defer { SharedCredentials.aiModels = savedModels }
        SharedCredentials.aiModels = { [("openai", "llm.profile.aaa"), ("deepseek", "llm.profile.bbb")] }
        items = ["llm.profile.aaa": "sk-chat", "llm.profile.bbb": "ds-key"]
        c("ai models: the key of an OpenAI entry serves OpenAI speech recognition", SharedCredentials.get("openai.apikey", read: read) == "sk-chat" && SharedCredentials.isShared("openai.apikey", read: read))
        c("ai models: a company with no entry, or an entry of another company, gives nothing", SharedCredentials.get("groq.apikey", read: read) == nil && SharedCredentials.get("ocr.mistral.apikey", read: read) == nil && SharedCredentials.get("deepgram.apikey", read: read) == nil)
        items["openai.apikey"] = "sk-speech"
        c("ai models: a key saved for speech wins over the entry's", SharedCredentials.get("openai.apikey", read: read) == "sk-speech" && !SharedCredentials.isShared("openai.apikey", read: read))
        items = ["groq.apikey": "gsk-speech", "ocr.mistral.apikey": "mi-ocr"]
        c("ai models: an AI model of that company borrows the speech or text recognition key, other companies do not",
          SharedCredentials.forAIModel(preset: "groq", read: read) == "gsk-speech" && SharedCredentials.forAIModel(preset: "mistral", read: read) == "mi-ocr" && SharedCredentials.forAIModel(preset: "openai", read: read) == nil && SharedCredentials.forAIModel(preset: "ollama", read: read) == nil)
        items["llm.profile.own"] = "own-key"
        c("ai models: the model's own key wins, and a missing one falls back to the borrowed key", SharedCredentials.aiModelKey(keyName: "llm.profile.own", preset: "groq", read: read) == "own-key" && SharedCredentials.aiModelKey(keyName: "llm.profile.none", preset: "groq", read: read) == "gsk-speech" && SharedCredentials.aiModelKey(keyName: "llm.profile.none", preset: "deepseek", read: read) == nil)
        SharedCredentials.aiModels = savedModels

        // Through the real stores (in memory while testing)
        let names = ["tencent.secretid", "tencent.secretkey", "tencent.appid", "ocr.tencent.secretid", "ocr.tencent.secretkey"]
        names.forEach { _ = KeychainStore.delete($0) }
        defer { names.forEach { _ = KeychainStore.delete($0) } }
        c("stores: nothing saved, nothing configured", !OCRCredentialStore.has(.tencent) && !ASREngine.tencent.configured)
        _ = KeychainStore.set("ID", for: "tencent.secretid"); _ = KeychainStore.set("KEY", for: "tencent.secretkey"); _ = KeychainStore.set("1250000000", for: "tencent.appid")
        c("stores: text recognition runs on the speech recognition keys", OCRCredentialStore.has(.tencent) && OCRCredentialStore.values(.tencent) == ["secretid": "ID", "secretkey": "KEY"])
        _ = KeychainStore.delete("tencent.secretid"); _ = KeychainStore.delete("tencent.secretkey")
        _ = KeychainStore.set("OID", for: "ocr.tencent.secretid"); _ = KeychainStore.set("OKEY", for: "ocr.tencent.secretkey")
        c("stores: speech recognition needs only the account ID once text recognition has the keys",
          ASREngine.tencent.configured && ASREngine.tencent.credentials() == ["appid": "1250000000", "secretid": "OID", "secretkey": "OKEY"])
        _ = KeychainStore.delete("tencent.appid")
        c("stores: the account ID is never borrowed", !ASREngine.tencent.configured && ASREngine.tencent.credentials() == nil)

        // The text recognition sheet
        var kc: [String: String] = ["tencent.secretid": "ID", "tencent.secretkey": "KEY"]
        func draft() -> OCRProviderDraft {
            OCRProviderDraft(provider: .tencent, settings: ScreenshotSettings(), has: { SharedCredentials.has($0, read: { kc[$0] }) }, read: { SharedCredentials.get($0, read: { kc[$0] }) }, own: { kc[$0] },
                             write: { v, k in kc[k] = v; return true }, delete: { kc[$0] = nil; return true }, persist: { _, _, _, _ in true })
        }
        let d = draft()
        c("sheet: shared keys count as saved, so nothing has to be entered", d.complete && d.saved == ["secretid", "secretkey"] && d.shared == ["secretid", "secretkey"])
        d.consent = true
        c("sheet: saving only the options writes no key", d.save() && kc == ["tencent.secretid": "ID", "tencent.secretkey": "KEY"])
        d.values["secretkey"] = "OWN-KEY"
        c("sheet: typing a key saves a separate one and leaves the speech recognition key alone", d.save() && kc["ocr.tencent.secretkey"] == "OWN-KEY" && kc["tencent.secretkey"] == "KEY" && d.shared == ["secretid"])
        d.clearCredentials()
        c("sheet: removing only removes what this sheet saved", kc["ocr.tencent.secretkey"] == nil && kc["tencent.secretid"] == "ID" && kc["tencent.secretkey"] == "KEY" && d.shared == ["secretid", "secretkey"] && d.saved == ["secretid", "secretkey"] && !d.consent)
    }
}
