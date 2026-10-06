import Foundation
import Security

enum LegacyMigrationFixtures {
    static func run(_ c: (String, Bool) -> Void) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("legacy-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        func write(_ url: URL, _ text: String) { try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try? text.write(to: url, atomically: true, encoding: .utf8) }
        func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

        // 文件夹：全部搬走，不覆盖已有，相同的文件直接丢掉旧副本
        let old = root.appendingPathComponent("Yansui"), new = root.appendingPathComponent("Cadenza")
        write(old.appendingPathComponent("config.json"), "{\"a\":1}")
        write(old.appendingPathComponent("models/m1/model.onnx"), "weights")
        write(old.appendingPathComponent("test-field.html"), "same")
        write(old.appendingPathComponent("log.txt"), "old log")
        write(old.appendingPathComponent(".DS_Store"), "x")
        write(new.appendingPathComponent("test-field.html"), "same")
        write(new.appendingPathComponent("log.txt"), "new log")
        write(new.appendingPathComponent("DevelopmentArchives/keep.txt"), "archive")
        let report = LegacyMigration.moveSupportFolder(from: old, to: new)
        c("迁移文件夹：配置和模型整体搬到新位置", text(new.appendingPathComponent("config.json")) == "{\"a\":1}" && text(new.appendingPathComponent("models/m1/model.onnx")) == "weights")
        c("迁移文件夹：目标已有的文件不会被覆盖，旧的留在原处并如实报告", text(new.appendingPathComponent("log.txt")) == "new log" && text(old.appendingPathComponent("log.txt")) == "old log" && report.skipped == ["log.txt"])
        c("迁移文件夹：内容相同的文件只丢掉旧副本", !fm.fileExists(atPath: old.appendingPathComponent("test-field.html").path) && text(new.appendingPathComponent("test-field.html")) == "same")
        c("迁移文件夹：新文件夹里原有的内容不受影响", text(new.appendingPathComponent("DevelopmentArchives/keep.txt")) == "archive")
        c("迁移文件夹：还有没搬完的东西时不删除旧文件夹", fm.fileExists(atPath: old.path) && !report.removedOldDir)
        try? fm.removeItem(at: old.appendingPathComponent("log.txt"))
        let second = LegacyMigration.moveSupportFolder(from: old, to: new)
        c("迁移文件夹：再运行一次，旧文件夹只剩 .DS_Store 时一并清掉，且不报错", second.removedOldDir && !fm.fileExists(atPath: old.path))
        c("迁移文件夹：旧文件夹不存在时什么都不做", LegacyMigration.moveSupportFolder(from: old, to: new) == LegacyMigration.FilesReport())

        // 两边都有同名文件夹（例如新位置提前建了空的 models）：逐项合并，不丢模型
        let old2 = root.appendingPathComponent("Yansui2"), new2 = root.appendingPathComponent("Cadenza2")
        write(old2.appendingPathComponent("models/a/model.onnx"), "A")
        write(old2.appendingPathComponent("models/installed.json"), "{\"old\":1}")
        write(old2.appendingPathComponent("models/b/model.onnx"), "B-old")
        try? fm.createDirectory(at: new2.appendingPathComponent("models"), withIntermediateDirectories: true)
        write(new2.appendingPathComponent("models/b/model.onnx"), "B-new")
        let merged = LegacyMigration.moveSupportFolder(from: old2, to: new2)
        c("迁移文件夹：新位置有同名的空文件夹时，里面的内容合并过去", text(new2.appendingPathComponent("models/a/model.onnx")) == "A" && text(new2.appendingPathComponent("models/installed.json")) == "{\"old\":1}")
        c("迁移文件夹：合并时同名且不同的文件不覆盖，并如实报告", text(new2.appendingPathComponent("models/b/model.onnx")) == "B-new" && text(old2.appendingPathComponent("models/b/model.onnx")) == "B-old" && merged.skipped == ["models/b/model.onnx"])

        // 偏好设置：只复制一次，不覆盖，旧域被清掉
        let legacy = "test.legacy.\(UUID().uuidString)", target = "test.new.\(UUID().uuidString)"
        UserDefaults.standard.setPersistentDomain(["appLanguage": "en", "keepMe": "old", "n": 3], forName: legacy)
        let defaults = UserDefaults(suiteName: target)!
        defaults.set("new", forKey: "keepMe")
        let copied = LegacyMigration.migrateDefaults(from: legacy, into: defaults, flagKey: "migrated")
        c("迁移偏好：旧设置复制到新域，已有的值不被覆盖", copied == 2 && defaults.string(forKey: "appLanguage") == "en" && defaults.integer(forKey: "n") == 3 && defaults.string(forKey: "keepMe") == "new")
        c("迁移偏好：旧域被移除", UserDefaults.standard.persistentDomain(forName: legacy)?.isEmpty ?? true)
        UserDefaults.standard.setPersistentDomain(["late": 1], forName: legacy)
        c("迁移偏好：只做一次，之后不再复制", LegacyMigration.migrateDefaults(from: legacy, into: defaults, flagKey: "migrated") == 0 && defaults.object(forKey: "late") == nil)
        UserDefaults.standard.removePersistentDomain(forName: legacy); UserDefaults.standard.removePersistentDomain(forName: target)

        // 钥匙串：用测试专用的服务名，只动自己创建的项目
        let oldService = "Cadenza.test.old.\(UUID().uuidString)", newService = "Cadenza.test.new.\(UUID().uuidString)"
        func add(_ service: String, _ account: String, _ value: String) {
            SecItemAdd([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8)] as CFDictionary, nil)
        }
        func get(_ service: String, _ account: String) -> String? {
            var out: CFTypeRef?
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
            return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? (out as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        }
        func remove(_ service: String) { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary) }
        defer { remove(oldService); remove(newService) }
        add(oldService, "iflytek.apiKey", "secret-1"); add(oldService, "baidu.secret", "secret-2"); add(oldService, "same", "equal")
        add(newService, "baidu.secret", "different-new"); add(newService, "same", "equal")
        let result = LegacyMigration.migrateKeychain(from: oldService, to: newService, label: "测试")
        c("迁移钥匙串：密钥复制到新服务，读回一致后才删除旧的", get(newService, "iflytek.apiKey") == "secret-1" && get(oldService, "iflytek.apiKey") == nil)
        c("迁移钥匙串：新服务里已有不同的值时，不覆盖也不删除旧的", get(newService, "baidu.secret") == "different-new" && get(oldService, "baidu.secret") == "secret-2")
        c("迁移钥匙串：新旧相同时旧的被清掉", get(oldService, "same") == nil && get(newService, "same") == "equal")
        c("迁移钥匙串：统计如实（搬走 2 个，保留 1 个）", result.moved == 2 && result.kept == 1)
        c("迁移钥匙串：旧服务不存在时什么都不做", LegacyMigration.migrateKeychain(from: "Cadenza.test.none.\(UUID().uuidString)", to: newService, label: "x") == (0, 0))

        // 新标识
        c("新标识：钥匙串服务与支持文件夹都使用当前名称", KeychainStore.service == "Cadenza" && AppPaths.supportDir.lastPathComponent == "Cadenza")
    }
}
