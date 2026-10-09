import Foundation

/// One account on a platform, entered once. Speech recognition and text recognition from the same company sign in with the same
/// secret, so a key saved for one is used by the other until the person saves a separate one. Nothing is copied: a key that is
/// replaced or removed in one place changes for both, and the Keychain keeps a single item.
///
/// Only secrets that really are the same thing are listed. Tencent Cloud keys belong to the account. Baidu keys belong to an
/// application in the console: sharing works when text recognition is also switched on for that application, and the message
/// from the service says so when it is not.
enum SharedCredentials {
    /// Keychain accounts that hold the same secret under another feature.
    static let alternates: [String: [String]] = {
        let pairs: [(String, String)] = [
            ("tencent.secretid", "ocr.tencent.secretid"), ("tencent.secretkey", "ocr.tencent.secretkey"),
            ("baidu.apikey", "ocr.baidu.apikey"), ("baidu.secretkey", "ocr.baidu.secretkey"), ("google.apikey", "ocr.google.apikey"), ("azure.apikey", "ocr.azure.apikey"),
        ]
        var map: [String: [String]] = [:]
        for (a, b) in pairs { map[a, default: []].append(b); map[b, default: []].append(a) }
        return map
    }()

    /// Keys that an entry of "My AI models" for the same company also serves: the speech or text recognition account, then the
    /// preset of the AI model. One OpenAI key does speech to text, chat and reading pictures.
    static let aiModelServices: [String: String] = ["openai.apikey": "openai", "groq.apikey": "groq", "ocr.mistral.apikey": "mistral"]
    /// The AI models the person added (preset and the Keychain account of each key); the app sets this when it starts.
    static var aiModels: () -> [(preset: String, keyName: String)] = { [] }

    /// The secret saved under `key`, or else under an account that holds the same secret, or else the key of an AI model of that company.
    static func get(_ key: String, read: (String) -> String? = { KeychainStore.get($0) }) -> String? {
        for candidate in [key] + (alternates[key] ?? []) { if let v = read(candidate), !v.isEmpty { return v } }
        if let preset = aiModelServices[key] {
            for model in aiModels() where model.preset == preset { if let v = read(model.keyName), !v.isEmpty { return v } }
        }
        return nil
    }

    /// The key an AI model of this company can borrow from the speech or text recognition entry of the same company.
    static func forAIModel(preset: String, read: (String) -> String? = { KeychainStore.get($0) }) -> String? {
        guard let account = aiModelServices.first(where: { $0.value == preset })?.key, let v = read(account), !v.isEmpty else { return nil }
        return v
    }
    /// The key of an AI model: its own, or else the one borrowed from speech or text recognition.
    static func aiModelKey(keyName: String, preset: String, read: (String) -> String? = { KeychainStore.get($0) }) -> String? {
        if let own = read(keyName), !own.isEmpty { return own }
        return forAIModel(preset: preset, read: read)
    }
    static func has(_ key: String, read: (String) -> String? = { KeychainStore.get($0) }) -> Bool { get(key, read: read) != nil }

    /// True when `key` has no secret of its own and is served by another feature's.
    static func isShared(_ key: String, read: (String) -> String? = { KeychainStore.get($0) }) -> Bool {
        (read(key) ?? "").isEmpty && has(key, read: read)
    }
}
