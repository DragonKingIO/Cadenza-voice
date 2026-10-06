import Foundation

// Privacy controls that are enforced in code, so the documented promises can be tested.

/// Optional on-disk diagnostic log. On by default, local only, size-capped; users can turn it off or clear it.
enum DiagnosticLogging {
    private static let key = "diagnosticLoggingEnabled"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// When on, only local models may recognize speech: cloud services and Apple's recognition are refused in code, and
/// the app makes no automatic network requests. It is a lock, not just a setting the user may later change by accident.
enum LocalOnlyMode {
    private static let key = "localOnlyMode"
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { if newValue { UserDefaults.standard.set(true, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
    }
}

enum LogFile {
    static let maxBytes = 512 * 1024
    static let keepBytes = 128 * 1024
    private static var writesSinceCheck = 0

    static var size: Int { (try? FileManager.default.attributesOfItem(atPath: AppPaths.logFile.path)[.size] as? Int) ?? 0 }

    /// Checks the size every 200 writes so ordinary logging stays cheap.
    static func noteWrite() {
        writesSinceCheck += 1
        guard writesSinceCheck >= 200 else { return }
        writesSinceCheck = 0
        _ = trimIfNeeded(AppPaths.logFile)
    }

    /// Keeps the newest `keepBytes` (cut at a line boundary) once the file passes `maxBytes`.
    @discardableResult
    static func trimIfNeeded(_ url: URL, maxBytes: Int = LogFile.maxBytes, keepBytes: Int = LogFile.keepBytes) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count > maxBytes else { return false }
        var tail = Data(data.suffix(keepBytes))
        if let newline = tail.firstIndex(of: 0x0A) { tail = Data(tail[tail.index(after: newline)...]) }
        return (try? tail.write(to: url, options: .atomic)) != nil
    }

    @discardableResult
    static func clear(_ url: URL = AppPaths.logFile) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }
}

enum PrivacyControls {
    /// Every Keychain account this app can have written for the speech providers.
    static var credentialKeys: [String] {
        ASREngine.allCases.flatMap { engine in engine.credentialFields.map { engine.rawValue + "." + $0.0 } }
    }
    /// Deletes saved provider credentials and returns how many items were actually removed.
    @discardableResult
    static func deleteAllCredentials(has: (String) -> Bool = KeychainStore.has, delete: (String) -> Bool = { KeychainStore.delete($0) }) -> (removed: Int, failed: Int) {
        var removed = 0, failed = 0
        for key in credentialKeys where has(key) { if delete(key) { removed += 1 } else { failed += 1 } }
        return (removed, failed)
    }
}

// MARK: - Privacy notice and terms

enum LegalDocument: String, CaseIterable {
    case privacy = "PRIVACY", terms = "TERMS"
    /// Bumped whenever either document changes in a way users should re-read.
    static let version = "2026-10-03"

    func fileName(language: String) -> String { rawValue + (language == "zh-Hans" ? ".zh-CN" : "") + ".md" }
    func text(language: String = L10n.language, directory: URL? = Bundle.main.resourceURL?.appendingPathComponent("legal", isDirectory: true)) -> String? {
        guard let directory = directory else { return nil }
        return try? String(contentsOf: directory.appendingPathComponent(fileName(language: language)), encoding: .utf8)
    }
    var title: String { L10n.tr(self == .privacy ? "legal.privacy" : "legal.terms") }
}

enum TermsAcceptance {
    private static let key = "acceptedLegalVersion"
    static var acceptedVersion: String? { UserDefaults.standard.string(forKey: key) }
    static var accepted: Bool { acceptedVersion == LegalDocument.version }
    static func accept() { UserDefaults.standard.set(LegalDocument.version, forKey: key) }
    static func revoke() { UserDefaults.standard.removeObject(forKey: key) }
}
