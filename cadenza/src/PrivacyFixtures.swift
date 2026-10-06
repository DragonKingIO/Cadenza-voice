import AppKit
import Foundation

/// Language switch and privacy controls. Keychain and preferences are restored; no UI is shown.
enum PrivacyFixtures {
    static func run(_ check: (String, Bool) -> Void) {
        func c(_ name: String, _ ok: Bool) { check("Privacy " + name, ok) }
        func hasChinese(_ s: String) -> Bool { s.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF } }

        // MARK: Language
        let defaults = UserDefaults.standard
        let savedLanguage = defaults.object(forKey: "appLanguage")
        var notifications = 0
        let token = NotificationCenter.default.addObserver(forName: .appLanguageChanged, object: nil, queue: nil) { _ in notifications += 1 }
        defer {
            NotificationCenter.default.removeObserver(token)
            if let savedLanguage = savedLanguage { defaults.set(savedLanguage, forKey: "appLanguage") } else { defaults.removeObject(forKey: "appLanguage") }
        }
        AppLanguage.current = .en
        c("选择 English 后界面语言与品牌名为英文", L10n.language == "en" && Brand.name == "Cadenza")
        AppLanguage.current = .zhHans
        c("选择简体中文后界面语言与品牌名为中文", L10n.language == "zh-Hans" && Brand.name == "随言")
        c("模型卡片的语言名跟随所选界面语言（中文）", LocalModelRow.languageList(["zh", "en"]).contains("中文") && !LocalModelRow.languageList(["zh", "en"]).contains("Chinese"))
        AppLanguage.current = .en
        c("模型卡片的语言名跟随所选界面语言，而不是系统语言（英文）", LocalModelRow.languageList(["zh", "en"]).contains("Chinese") && !LocalModelRow.languageList(["zh", "en"]).contains("中文"))
        AppLanguage.current = .zhHans
        let before = notifications
        AppLanguage.current = .zhHans
        c("重复选择同一语言不重复通知", notifications == before)
        AppLanguage.current = .system
        c("跟随系统时清除偏好", defaults.string(forKey: "appLanguage") == nil && AppLanguage.current == .system)
        c("语言切换会发出通知", notifications >= 3)
        AppLanguage.current = .en
        c("英文界面下语言选项不含中文", AppLanguage.allCases.allSatisfy { !hasChinese($0.title) })
        c("英文界面下隐私与条款标题不含中文", LegalDocument.allCases.allSatisfy { !hasChinese($0.title) })
        AppLanguage.current = .zhHans
        c("中文界面的语言选项", AppLanguage.zhHans.title == "简体中文" && AppLanguage.en.title == "English")
        AppLanguage.current = .system

        // MARK: Diagnostic log
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-fixture-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("log.txt")
        let lines = (0..<40_000).map { String(format: "12:00:00 line %06d", $0) }.joined(separator: "\n") + "\n"
        try? lines.write(to: log, atomically: true, encoding: .utf8)
        c("测试日志超过上限", (try? Data(contentsOf: log).count) ?? 0 > LogFile.maxBytes)
        c("超过上限时裁剪", LogFile.trimIfNeeded(log))
        let trimmed = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        c("裁剪后不超过保留大小", trimmed.utf8.count <= LogFile.keepBytes)
        c("裁剪后保留最新的行", trimmed.hasSuffix("line 039999\n"))
        c("裁剪在整行处开始", trimmed.hasPrefix("12:00:00 line "))
        c("未超过上限时不改动", !LogFile.trimIfNeeded(log) && ((try? String(contentsOf: log, encoding: .utf8)) ?? "") == trimmed)
        c("清除日志文件", LogFile.clear(log) && !FileManager.default.fileExists(atPath: log.path))
        c("清除不存在的日志视为成功", LogFile.clear(log))
        let savedLogging = defaults.object(forKey: "diagnosticLoggingEnabled")
        defaults.removeObject(forKey: "diagnosticLoggingEnabled")
        c("诊断日志默认开启", DiagnosticLogging.enabled)
        DiagnosticLogging.enabled = false
        c("诊断日志可关闭", !DiagnosticLogging.enabled)
        if let savedLogging = savedLogging { defaults.set(savedLogging, forKey: "diagnosticLoggingEnabled") } else { defaults.removeObject(forKey: "diagnosticLoggingEnabled") }

        // MARK: Credentials
        let keys = PrivacyControls.credentialKeys
        c("凭据键覆盖各服务商且不重复", keys.contains("iflytek.appid") && keys.contains("deepgram.apikey") && keys.contains("tencent.secretkey") && Set(keys).count == keys.count)
        var existing = Set(["iflytek.appid", "iflytek.apikey", "baidu.apikey"]), attempted: [String] = []
        let result = PrivacyControls.deleteAllCredentials(has: { existing.contains($0) }, delete: { attempted.append($0); existing.remove($0); return true })
        c("只删除确实存在的凭据", result.removed == 3 && result.failed == 0 && Set(attempted) == ["iflytek.appid", "iflytek.apikey", "baidu.apikey"])
        let failing = PrivacyControls.deleteAllCredentials(has: { $0 == "iflytek.appid" }, delete: { _ in false })
        c("删除失败时如实报告", failing.removed == 0 && failing.failed == 1)
        c("没有凭据时不做任何删除", PrivacyControls.deleteAllCredentials(has: { _ in false }, delete: { _ in false }) == (0, 0))

        // MARK: Notices and terms
        c("文档文件名按语言区分", LegalDocument.privacy.fileName(language: "en") == "PRIVACY.md" && LegalDocument.terms.fileName(language: "zh-Hans") == "TERMS.zh-CN.md")
        if let legal = Bundle.main.resourceURL?.appendingPathComponent("legal"), FileManager.default.fileExists(atPath: legal.path) {
            for doc in LegalDocument.allCases {
                let en = doc.text(language: "en"), zh = doc.text(language: "zh-Hans")
                c("已打包 \(doc.rawValue) 中英文", en != nil && zh != nil)
                c("\(doc.rawValue) 英文版除语言链接外不含中文", !hasChinese((en ?? "").replacingOccurrences(of: "[简体中文]", with: "")))
            }
            c("面向用户的隐私说明与条款不出现旧名称", LegalDocument.allCases.allSatisfy { doc in ["en", "zh-Hans"].allSatisfy { !(doc.text(language: $0) ?? "").lowercased().contains("yansui") } })
            let terms = LegalDocument.terms.text(language: "en") ?? "", privacy = LegalDocument.privacy.text(language: "en") ?? ""
            c("使用条款版本与代码一致", terms.contains(LegalDocument.version) && (LegalDocument.terms.text(language: "zh-Hans") ?? "").contains(LegalDocument.version))
            c("隐私说明明确不收集数据且本地识别不上传", privacy.contains("We collect nothing") && privacy.contains("never uploads audio on its own"))
            c("隐私说明中英文的服务商列表一致", ["iFlytek", "Volcengine", "Tencent", "Alibaba", "Baidu", "Deepgram"].allSatisfy { privacy.contains($0) } && ["讯飞", "火山引擎", "腾讯云", "阿里云", "百度", "Deepgram"].allSatisfy { (LegalDocument.privacy.text(language: "zh-Hans") ?? "").contains($0) })
        }
        c("开发者页示例命令不暴露内部文件夹名", !DeveloperView.exampleCommand(address: "http://127.0.0.1:17420").lowercased().contains("yansui") && DeveloperView.exampleCommand(address: "http://127.0.0.1:17420").contains("<token>"))
        // MARK: App update check
        c("版本比较：补零与多位数", AppVersion("1.0")! == AppVersion("1.0.0")! || !(AppVersion("1.0")! < AppVersion("1.0.0")! || AppVersion("1.0.0")! < AppVersion("1.0")!))
        c("版本比较：1.9 < 1.10", AppVersion("1.9")! < AppVersion("1.10")! && AppVersion("1.0.9")! < AppVersion("1.0.10")!)
        c("版本比较：v 前缀与预发布", AppVersion("v2.0.0")! > AppVersion("1.9.9")! && AppVersion("1.0.0-beta.1")! < AppVersion("1.0.0")! && AppVersion("1.0.0-beta.1")!.isPrerelease)
        c("版本无效时返回空", AppVersion("") == nil && AppVersion("abc") == nil && AppVersion("1.2.3.4.5") == nil && AppVersion("1..2") == nil && AppVersion("-1.0") == nil)
        c("更新地址：仓库名校验", AppUpdate.releasesURL(repository: "owner/repo")?.absoluteString == "https://api.github.com/repos/owner/repo/releases/latest" && AppUpdate.releasesURL(repository: "") == nil && AppUpdate.releasesURL(repository: "a/b/c") == nil && AppUpdate.releasesURL(repository: "bad name/repo") == nil && AppUpdate.releasesURL(repository: "owner/") == nil)
        c("当前没有配置更新来源，不会发出请求", AppUpdate.repository.isEmpty)
        let current = AppVersion("1.0.0")!
        func release(_ tag: String, page: String = "https://github.com/owner/repo/releases/tag/x", pre: Bool = false, draft: Bool = false) -> Data {
            try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "html_url": page, "prerelease": pre, "draft": draft])
        }
        if case .available(let info) = AppUpdate.evaluate(release("v1.2.0"), current: current) { c("发现新版本并去掉 v 前缀", info.version == "1.2.0" && info.pageURL.host == "github.com") } else { c("发现新版本并去掉 v 前缀", false) }
        c("相同版本为最新", AppUpdate.evaluate(release("v1.0.0"), current: current) == .upToDate("1.0.0"))
        c("更旧版本为最新", AppUpdate.evaluate(release("v0.9.0"), current: current) == .upToDate("1.0.0"))
        c("预发布与草稿被忽略", AppUpdate.evaluate(release("v2.0.0", pre: true), current: current) == .upToDate("1.0.0") && AppUpdate.evaluate(release("v2.0.0", draft: true), current: current) == .upToDate("1.0.0") && AppUpdate.evaluate(release("v2.0.0-beta.1"), current: current) == .upToDate("1.0.0"))
        c("发布页链接必须是 github.com 的 https", AppUpdate.evaluate(release("v2.0.0", page: "https://evil.example/x"), current: current) == .failed && AppUpdate.evaluate(release("v2.0.0", page: "http://github.com/x"), current: current) == .failed && AppUpdate.evaluate(release("v2.0.0", page: "https://github.com.evil.example/x"), current: current) == .failed)
        c("响应格式错误或过大时失败", AppUpdate.evaluate(Data("not json".utf8), current: current) == .failed && AppUpdate.evaluate(Data("{}".utf8), current: current) == .failed && AppUpdate.evaluate(Data(repeating: 32, count: AppUpdate.maxResponseBytes + 1), current: current) == .failed)
        c("测试源只允许本机回环地址", AppUpdate.loopbackOverride("http://127.0.0.1:8765/latest.json") != nil && AppUpdate.loopbackOverride("http://localhost:8765/x") != nil && AppUpdate.loopbackOverride("https://127.0.0.1:8765/x") == nil && AppUpdate.loopbackOverride("http://evil.example:8765/x") == nil && AppUpdate.loopbackOverride("http://127.0.0.1/x") == nil && AppUpdate.loopbackOverride("http://127.0.0.1.evil.example:8765/x") == nil && AppUpdate.loopbackOverride(nil) == nil && AppUpdate.loopbackOverride("") == nil)
        c("测试源优先于仓库地址，无测试源且无仓库时为空", AppUpdate.feedURL(repository: "owner/repo", override: URL(string: "http://127.0.0.1:8765/latest.json")!)?.host == "127.0.0.1" && AppUpdate.feedURL(repository: "owner/repo", override: nil)?.host == "api.github.com" && AppUpdate.feedURL(repository: "", override: nil) == nil)
        c("普通启动没有测试源", AppUpdate.launchOverride == nil)
        let week: TimeInterval = 7 * 24 * 3600, now = Date()
        c("检查间隔：从未检查、不足一周、满一周、时间倒退", AppUpdate.due(last: nil, now: now) && !AppUpdate.due(last: now.addingTimeInterval(-6 * 24 * 3600), now: now) && AppUpdate.due(last: now.addingTimeInterval(-week - 1), now: now) && AppUpdate.due(last: now.addingTimeInterval(3600), now: now))
        let savedAuto = defaults.object(forKey: "autoCheckAppUpdates"), savedLast = defaults.object(forKey: "lastAppUpdateCheck")
        defer {
            if let savedAuto = savedAuto { defaults.set(savedAuto, forKey: "autoCheckAppUpdates") } else { defaults.removeObject(forKey: "autoCheckAppUpdates") }
            if let savedLast = savedLast { defaults.set(savedLast, forKey: "lastAppUpdateCheck") } else { defaults.removeObject(forKey: "lastAppUpdateCheck") }
        }
        defaults.removeObject(forKey: "autoCheckAppUpdates"); defaults.removeObject(forKey: "lastAppUpdateCheck")
        c("自动检查默认关闭", !UpdateChecker.autoCheck)
        let checker = UpdateChecker()
        var requested: [URL] = []
        checker.currentVersion = current
        checker.fetch = { url, done in requested.append(url); done(.success(release("v1.3.0"))) }
        checker.check()
        c("未配置来源时报告未配置且不请求", checker.status == .notConfigured && requested.isEmpty)
        checker.repository = "owner/repo"
        checker.check()
        LocalAPIFixtures.spin(2) { if case .available = checker.status { return true }; return false }
        c("配置后检查得到新版本并只请求一次发布地址", requested.count == 1 && requested[0].host == "api.github.com" && { if case .available = checker.status { return true }; return false }())
        c("成功检查后记录时间", checker.lastChecked != nil)
        requested = []; defaults.removeObject(forKey: "lastAppUpdateCheck")
        let off = UpdateChecker(); off.repository = "owner/repo"; off.currentVersion = current; off.fetch = { url, done in requested.append(url); done(.success(release("v1.3.0"))) }
        off.checkOnLaunchIfDue()
        c("自动检查关闭时启动不请求", requested.isEmpty && off.status == .idle)
        UpdateChecker.autoCheck = true
        off.checkOnLaunchIfDue()
        LocalAPIFixtures.spin(2) { requested.count == 1 && off.status != .checking }
        c("自动检查开启且到期时启动请求一次", requested.count == 1)
        requested = []
        off.checkOnLaunchIfDue()
        c("一周内不重复自动检查", requested.isEmpty)
        let offline = UpdateChecker(); offline.repository = "owner/repo"; offline.currentVersion = current
        offline.fetch = { (_: URL, done: @escaping (Result<Data, Error>) -> Void) in done(.failure(URLError(.notConnectedToInternet))) }
        let lastBefore = offline.lastChecked
        offline.check()
        LocalAPIFixtures.spin(2) { offline.status == .failed }
        c("网络失败如实报告且不更新检查时间", offline.status == .failed && offline.lastChecked == lastBefore)
        c("隐私说明列出检查应用更新", (LegalDocument.privacy.text(language: "en") ?? "").contains("Checking for app updates") || Bundle.main.resourceURL?.appendingPathComponent("legal").path.isEmpty != false)

        // MARK: Menu bar engine list
        let menuStore = ConfigStore(fileURL: dir.appendingPathComponent("menu-config.json"))
        let sample = LocalModelCatalog.builtin[0]
        var menuConfig = menuStore.config
        menuConfig.engine = ASREngine.local.rawValue; menuConfig.localModel.primaryModelID = sample.id
        let (localEntries, localSelected) = AppDelegate.engineMenuEntries(config: menuConfig, localOnly: false, installed: [sample])
        c("菜单：本地分组在最前并列出已安装模型", localEntries.first?.header == true && localEntries.dropFirst().first?.value == "local:" + sample.id)
        c("菜单：当前选中键为 local:模型", localSelected == "local:" + sample.id)
        c("菜单：Mac 自带识别可选且有名称", localEntries.contains { $0.value == ASREngine.apple.rawValue && $0.title == L10n.tr("engine.system.title") && $0.available })
        c("菜单：未配置的云端服务不出现", localEntries.filter { !$0.header && ASREngine(rawValue: $0.value).map { $0 != .apple && $0 != .local && !$0.configured } == true }.isEmpty)
        let (lockedEntries, _) = AppDelegate.engineMenuEntries(config: menuConfig, localOnly: true, installed: [sample])
        c("菜单：锁定为仅本地时只剩本地模型", lockedEntries.allSatisfy { $0.header || $0.value.hasPrefix("local:") } && !lockedEntries.contains { $0.value == ASREngine.apple.rawValue })
        let (emptyEntries, _) = AppDelegate.engineMenuEntries(config: menuConfig, localOnly: true, installed: [])
        c("菜单：没有模型时给出不可选提示", emptyEntries.contains { $0.value == "local:none" && !$0.available })
        var cloudConfig = menuConfig; cloudConfig.engine = "iflytek"
        c("菜单：选中云端时键为服务商名", AppDelegate.engineMenuEntries(config: cloudConfig, localOnly: false, installed: [sample]).1 == "iflytek")
        let menuRoot = NSMenu(), menuState = StatusMenuSnapshot()
        var snapshot = menuState; snapshot.engines = localEntries; snapshot.engine = localSelected
        StatusMenuController.rebuild(menuRoot, s: snapshot, target: NSObject())
        let engineItem = menuRoot.items.first { $0.identifier?.rawValue == "engine" }
        c("菜单：识别引擎副标题显示模型名而不是“本地”", engineItem?.subtitle == sample.name())
        c("菜单：分组标题是不可点的区段标题", engineItem?.submenu?.items.first?.isSectionHeader == true)
        c("菜单：有关于项", menuRoot.items.contains { $0.identifier?.rawValue == "about" })

        // MARK: Developer page
        c("侧边栏：开发者页默认隐藏，打开选项后出现", !MainTab.visible(showDeveloper: false).contains(.developer) && MainTab.visible(showDeveloper: true).contains(.developer) && MainTab.visible(showDeveloper: false).count == MainTab.allCases.count - 1)
        c("开发者页可见性：用户明确选择优先，否则用过接口的人默认可见", DeveloperPageVisibility.resolve(stored: false, hasUsedInterface: true) == false && DeveloperPageVisibility.resolve(stored: true, hasUsedInterface: false) && DeveloperPageVisibility.resolve(stored: nil, hasUsedInterface: true) && !DeveloperPageVisibility.resolve(stored: nil, hasUsedInterface: false))
        c("示例命令端口与令牌占位", DeveloperView.exampleCommand(address: "http://127.0.0.1:17420") == "curl -H \"Authorization: Bearer <token>\" http://127.0.0.1:17420/v1/capabilities")
        if let legal = Bundle.main.resourceURL?.appendingPathComponent("legal"), FileManager.default.fileExists(atPath: legal.path) {
            let api = DeveloperDocument.text() ?? ""
            c("接口文档已打包并包含端点说明", api.contains("/v1/sessions") && api.contains("Bearer"))
        }
        c("接口文档缺失时返回空", DeveloperDocument.text(directory: dir.appendingPathComponent("none")) == nil)
        let missingDir = dir.appendingPathComponent("none")
        c("文档缺失时返回空", LegalDocument.privacy.text(language: "en", directory: missingDir) == nil)
        let blocks = LegalBlock.parse("# Title\n\nIntro text\n- one\n- two\n| A | B |\n|---|---|\n| x | y |\n## Sub")
        c("文档解析标题、段落、列表和表格", blocks == [.heading(1, "Title"), .paragraph("Intro text"), .bullet("one"), .bullet("two"), .row(["A", "B"]), .row(["x", "y"]), .heading(2, "Sub")])

        let savedAcceptance = defaults.object(forKey: "acceptedLegalVersion")
        defer { if let savedAcceptance = savedAcceptance { defaults.set(savedAcceptance, forKey: "acceptedLegalVersion") } else { defaults.removeObject(forKey: "acceptedLegalVersion") } }
        TermsAcceptance.revoke()
        c("未同意时状态为未同意", !TermsAcceptance.accepted && TermsAcceptance.acceptedVersion == nil)
        TermsAcceptance.accept()
        c("同意后记录当前版本", TermsAcceptance.accepted && TermsAcceptance.acceptedVersion == LegalDocument.version)
        defaults.set("1999-01-01", forKey: "acceptedLegalVersion")
        c("旧版本同意不算数，需要重新确认", !TermsAcceptance.accepted)

        // 幻影按键：系统一直报告某个普通键按下但从未收到 keyDown 时，不能挡住单键触发
        let phantom = ListenTrigger.visibleDown(raw: [58, 0], observed: [])
        c("幻影普通键（没有收到过 keyDown）被忽略，修饰键保留", phantom == [58])
        c("真的按下的普通键仍然算按下", ListenTrigger.visibleDown(raw: [58, 0], observed: [0]) == [58, 0])
        c("松开后的普通键不再算按下", ListenTrigger.visibleDown(raw: [58], observed: [0]) == [58])
        var lone = ShortcutCycle(spec: HotkeySpec(keyCode: 58, modifiers: 2048))
        c("幻影键存在时左 Option 单独按下能开始", lone.event(type: .flagsChanged, code: 58, modifiers: 2048, downKeys: ListenTrigger.visibleDown(raw: [58, 0], observed: [])) == .start)
        var blocked = ShortcutCycle(spec: HotkeySpec(keyCode: 58, modifiers: 2048))
        c("真的按着字母键时仍不开始（保持原行为）", blocked.event(type: .flagsChanged, code: 58, modifiers: 2048, downKeys: ListenTrigger.visibleDown(raw: [58, 0], observed: [0])) == .none)

        // 权限实时探测：系统缓存说“允许”但进程收不到按键时要显示“未生效”，而不是“已授权”
        let savedPreflight = PermissionProbe.preflight, savedTap = PermissionProbe.tapProbe
        defer { PermissionProbe.preflight = savedPreflight; PermissionProbe.tapProbe = savedTap; PermissionProbe.forget() }
        var tapCalls = 0
        func probe(preflight: Bool, tap: Bool) -> MonitorPermission {
            PermissionProbe.forget(); PermissionProbe.preflight = { preflight }; PermissionProbe.tapProbe = { tapCalls += 1; return tap }
            return PermissionProbe.monitor()
        }
        c("输入监控：系统允许且能建立监听为已授权", probe(preflight: true, tap: true) == .granted)
        c("输入监控：系统不允许为未授权，且不会尝试建立监听（避免弹窗）", { tapCalls = 0; let r = probe(preflight: false, tap: true); return r == .denied && tapCalls == 0 }())
        c("输入监控：系统允许但建立监听失败为未生效", probe(preflight: true, tap: false) == .stale)
        c("输入监控：只有已授权才算可用", { _ = probe(preflight: true, tap: false); return !PermissionProbe.monitorGranted }())
        PermissionProbe.forget(); PermissionProbe.preflight = { true }; PermissionProbe.tapProbe = { true }
        let watcher = PermissionWatcher()
        var perms = PermissionWatcher.Snapshot(mic: true, accessibility: true, monitor: .granted)
        watcher.snapshot = { perms }
        watcher.poll()
        var posted = 0
        let permToken = NotificationCenter.default.addObserver(forName: .permissionsChanged, object: nil, queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(permToken) }
        watcher.poll()
        c("权限没变化时不通知", posted == 0)
        perms.monitor = .stale; watcher.poll()
        c("权限变化时通知重建快捷键监听", posted == 1)
        watcher.poll()
        c("同一状态不重复通知", posted == 1)
        watcher.poll(force: true)
        c("唤醒或解锁后强制通知一次", posted == 2)
    }
}
