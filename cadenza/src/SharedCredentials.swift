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
            ("baidu.apikey", "ocr.baidu.apikey"), ("baidu.secretkey", "ocr.baidu.secretkey"),
        ]
        var map: [String: [String]] = [:]
        for (a, b) in pairs { map[a, default: []].append(b); map[b, default: []].append(a) }
        return map
    }()

    /// The secret saved under `key`, or else under an account that holds the same secret.
    static func get(_ key: String, read: (String) -> String? = { KeychainStore.get($0) }) -> String? {
        for candidate in [key] + (alternates[key] ?? []) { if let v = read(candidate), !v.isEmpty { return v } }
        return nil
    }
    static func has(_ key: String, read: (String) -> String? = { KeychainStore.get($0) }) -> Bool { get(key, read: read) != nil }

    /// True when `key` has no secret of its own and is served by another feature's.
    static func isShared(_ key: String, read: (String) -> String? = { KeychainStore.get($0) }) -> Bool {
        (read(key) ?? "").isEmpty && has(key, read: read)
    }
}
