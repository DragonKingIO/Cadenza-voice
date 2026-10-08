import Foundation
import Security

/// One-time move from the identifiers used before the rename (support folder, preferences domain, Keychain service)
/// to the Cadenza ones. It only ever moves or copies first: nothing is deleted before its replacement is verified,
/// and an existing destination is never overwritten.
/// The few preference calls the migration needs, so a test can use memory instead of real preference files.
protocol DefaultsStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func bool(forKey key: String) -> Bool
    func integer(forKey key: String) -> Int
    @discardableResult func synchronize() -> Bool
}
extension UserDefaults: DefaultsStore {}

enum LegacyMigration {
    static let legacySupportName = "Yansui"
    static let legacyDefaultsDomain = "local.yansui.app"
    static let legacyKeychainService = "Yansui"
    static let doneKey = "legacyIdentifiersMigrated"

    static var legacySupportDir: URL {
        AppPaths.supportDir.deletingLastPathComponent().appendingPathComponent(legacySupportName, isDirectory: true)
    }

    /// Runs before anything reads settings. Cheap and synchronous; the Keychain part runs later, in the background.
    static func runFileAndPreferenceMigration() {
        let files = moveSupportFolder(from: legacySupportDir, to: AppPaths.supportDir)
        let prefs = migrateDefaults(from: legacyDefaultsDomain, into: UserDefaults.standard)
        if !files.moved.isEmpty || !files.skipped.isEmpty || prefs > 0 {
            Log.write("legacy-migration files-moved=\(files.moved.count) files-kept=\(files.skipped.count) old-folder-removed=\(files.removedOldDir) preferences-copied=\(prefs)")
        }
    }

    // MARK: Files

    struct FilesReport: Equatable { var moved: [String] = []; var skipped: [String] = []; var removedOldDir = false }

    /// Moves every item of the old folder into the new one. Folders that exist on both sides are merged item by item.
    /// A file that already exists at the destination is never overwritten: an identical one is simply dropped from the old
    /// folder, a different one stays where it is and is reported.
    @discardableResult
    static func moveSupportFolder(from old: URL, to new: URL, fm: FileManager = .default) -> FilesReport {
        var report = FilesReport()
        guard old.standardizedFileURL != new.standardizedFileURL, fm.fileExists(atPath: old.path) else { return report }
        merge(old, into: new, prefix: "", fm: fm, report: &report)
        let rest = (try? fm.contentsOfDirectory(atPath: old.path)) ?? []
        if rest.allSatisfy({ $0 == ".DS_Store" }) {
            try? fm.removeItem(at: old)
            report.removedOldDir = !fm.fileExists(atPath: old.path)
        }
        return report
    }

    private static func merge(_ old: URL, into new: URL, prefix: String, fm: FileManager, report: inout FilesReport) {
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        for child in (try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil, options: [])) ?? [] {
            let name = child.lastPathComponent
            if name == ".DS_Store" { continue }
            let destination = new.appendingPathComponent(name), label = prefix + name
            var childIsDir: ObjCBool = false, destIsDir: ObjCBool = false
            _ = fm.fileExists(atPath: child.path, isDirectory: &childIsDir)
            guard fm.fileExists(atPath: destination.path, isDirectory: &destIsDir) else {
                do { try fm.moveItem(at: child, to: destination); report.moved.append(label) } catch { report.skipped.append(label) }
                continue
            }
            if childIsDir.boolValue, destIsDir.boolValue {
                merge(child, into: destination, prefix: label + "/", fm: fm, report: &report)
                let rest = (try? fm.contentsOfDirectory(atPath: child.path)) ?? []
                if rest.allSatisfy({ $0 == ".DS_Store" }) { try? fm.removeItem(at: child) }
            } else if !childIsDir.boolValue, !destIsDir.boolValue, fm.contentsEqual(atPath: child.path, andPath: destination.path), (try? fm.removeItem(at: child)) != nil {
                report.moved.append(label)
            } else {
                report.skipped.append(label)
            }
        }
    }

    // MARK: Preferences

    /// Copies the old preferences domain into the current one (never over an existing value), once, then removes the old domain.
    @discardableResult
    static func migrateDefaults(from legacy: String, into defaults: DefaultsStore, flagKey: String = doneKey,
                                read: (String) -> [String: Any]? = { UserDefaults.standard.persistentDomain(forName: $0) },
                                remove: (String) -> Void = { UserDefaults.standard.removePersistentDomain(forName: $0) }) -> Int {
        guard !defaults.bool(forKey: flagKey) else { return 0 }
        var copied = 0
        if let old = read(legacy), !old.isEmpty {
            for (key, value) in old where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key); copied += 1 }
        }
        defaults.set(true, forKey: flagKey)
        defaults.synchronize()
        remove(legacy)
        return copied
    }

    // MARK: Keychain

    /// Moves saved credentials from the old Keychain service to the new one. Reading an item the old app created can make
    /// macOS ask once for permission (choose "Always Allow"); if that is refused, the item stays where it is untouched.
    /// An old item is deleted only after the copy has been read back and matches.
    @discardableResult
    static func migrateKeychain(from oldService: String, to newService: String, label: String) -> (moved: Int, kept: Int) {
        let list: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: oldService,
                                   kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
                                   kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var found: CFTypeRef?
        guard SecItemCopyMatching(list as CFDictionary, &found) == errSecSuccess, let items = found as? [[String: Any]] else { return (0, 0) }
        var moved = 0, kept = 0
        func read(_ service: String, _ account: String, allowPrompt: Bool) -> Data? {
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            if !allowPrompt { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
            var out: CFTypeRef?
            return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
        }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String, let data = read(oldService, account, allowPrompt: true) else { kept += 1; continue }
            let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: newService,
                                      kSecAttrAccount as String: account, kSecAttrLabel as String: label, kSecValueData as String: data]
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess || status == errSecDuplicateItem, read(newService, account, allowPrompt: false) == data else { kept += 1; continue }
            let remove: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: oldService, kSecAttrAccount as String: account]
            if SecItemDelete(remove as CFDictionary) == errSecSuccess { moved += 1 } else { kept += 1 }
        }
        return (moved, kept)
    }

    static let keychainAttemptsKey = "legacyKeychainAttempts"
    static let maxKeychainAttempts = 2

    /// macOS may ask for permission to read the old items. If it was refused, ask once more at the next launch and then stop,
    /// so a refusal does not bring the prompt back at every start (the keys can be entered again in Settings).
    static func keychainAttemptAllowed(_ defaults: DefaultsStore = UserDefaults.standard) -> Bool {
        defaults.integer(forKey: keychainAttemptsKey) < maxKeychainAttempts
    }

    /// Background, at launch. Safe to call when there is nothing to migrate.
    static func migrateKeychainInBackground() {
        guard keychainAttemptAllowed() else { return }
        DispatchQueue.global(qos: .utility).async {
            let result = migrateKeychain(from: legacyKeychainService, to: KeychainStore.service, label: KeychainStore.itemLabel)
            if result.moved > 0 || result.kept > 0 { Log.write("legacy-keychain-migration moved=\(result.moved) kept=\(result.kept)") }
            if result.kept > 0 { UserDefaults.standard.set(UserDefaults.standard.integer(forKey: keychainAttemptsKey) + 1, forKey: keychainAttemptsKey) }
        }
    }
}
