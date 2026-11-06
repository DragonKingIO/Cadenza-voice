import Foundation

enum DataDirectoryFixtures {
    static func run(_ c: (String, Bool) -> Void) {
        func requested(_ arguments: [String]) -> Result<URL?, DataDirectory.Failure> { DataDirectory.requested(arguments: ["Cadenza"] + arguments) }
        func folder(_ arguments: [String]) -> String? { (try? requested(arguments).get())?.path }

        c("数据目录：没有 --data-dir 时用标准目录", requested(["--inspect-page=1"]) == .success(nil) && requested(["--data-directory=/x"]) == .success(nil))
        c("数据目录：不带参数时 supportDir 不变，仍是 ~/Library/Application Support/Cadenza",
          AppPaths.supportDir(customFolder: nil).path == NSHomeDirectory() + "/Library/Application Support/Cadenza")
        c("数据目录：绝对路径原样使用，并去掉 . 和 ..", folder(["--data-dir=/tmp/cadenza dev"]) == "/tmp/cadenza dev" && folder(["--data-dir=/tmp/a/./b/../dev"]) == "/tmp/a/dev")
        c("数据目录：给了多次时以最后一个为准", folder(["--data-dir=/a", "--data-dir=/b"]) == "/b")
        c("数据目录：没有路径时报错", requested(["--data-dir="]) == .failure(.missingPath) && requested(["--data-dir"]) == .failure(.missingPath))
        c("数据目录：相对路径和 ~ 开头的路径报错", requested(["--data-dir=dev"]) == .failure(.notAbsolute("dev")) && requested(["--data-dir=~/dev"]) == .failure(.notAbsolute("~/dev")))

        let fm = FileManager.default
        func mode(_ url: URL) -> Int? { (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int }
        let root = fm.temporaryDirectory.appendingPathComponent("data-dir-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("a/b", isDirectory: true)
        c("创建目录：不存在时连同上级目录以 0700 创建", DataDirectory.prepare(nested) == nil && mode(nested) == 0o700 && mode(root) == 0o700)
        c("创建目录：已有的目录直接使用", DataDirectory.prepare(nested) == nil)
        let file = root.appendingPathComponent("file")
        fm.createFile(atPath: file.path, contents: Data())
        c("创建目录：路径是文件时报错", DataDirectory.prepare(file) == .notAFolder(file.path))
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try? fm.createDirectory(at: locked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o500])
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path); try? fm.removeItem(at: root) }
        c("创建目录：目录不可写时报错", DataDirectory.prepare(locked) == .notWritable(locked.path))
        let blocked = locked.appendingPathComponent("dev", isDirectory: true)
        if case .notCreated(let path, _) = DataDirectory.prepare(blocked) { c("创建目录：创建失败时报错", path == blocked.path) } else { c("创建目录：创建失败时报错", false) }

        c("路径派生：给了 --data-dir 时 supportDir 就是那个目录", AppPaths.supportDir(customFolder: root) == root)
        let files = [AppPaths.configFile, AppPaths.logFile, AppPaths.testField, LocalAPIStore.standard.settingsURL, LocalAPIStore.standard.tokenURL,
                     LocalModelCenter.shared.root, VocabularyStore().userFile]
        c("路径派生：配置、日志、Local API、模型和词库都在本进程的 supportDir 里",
          files.allSatisfy { $0.deletingLastPathComponent().path == AppPaths.supportDir.path })

        c("窗口副标题：标准目录时没有", DataDirectory.displayName(nil) == nil)
        c("窗口副标题：只有目录名的最后一段，不带上级路径", DataDirectory.displayName(URL(fileURLWithPath: "/Users/example/dev-data", isDirectory: true)) == "dev-data")

        c("旧版迁移：只在标准目录下进行", LegacyMigration.applies(customFolder: nil) && !LegacyMigration.applies(customFolder: root))
    }
}
