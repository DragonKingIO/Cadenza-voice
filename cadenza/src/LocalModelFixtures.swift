import Foundation
import Network
import CryptoKit

// 本地模型自检：全部使用构造数据与本机 127.0.0.1 测试服务器，不联网、不下载真实模型、不用麦克风。
enum LocalModelFixtures {
    // MARK: 工具

    /// 在等待期间继续处理主线程队列（安装流程会回到主线程）
    static func wait(_ timeout: TimeInterval = 15, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    static func tempDir(_ name: String) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("cadenza-local-\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @discardableResult
    static func run(_ launch: String, _ args: [String]) -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: launch); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit(); return p.terminationStatus == 0
    }

    /// 构造一个模型包：最外层目录 + 三个必需文件（内容为随机字节，仅用于校验与解压）
    static func makeArchive(in dir: URL, tag: String, extraSize: Int = 4000) -> (url: URL, sha: String, size: Int64)? {
        let top = dir.appendingPathComponent("pkg-\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: top, withIntermediateDirectories: true)
        for f in ["model.int8.onnx", "tokens.txt"] {
            var data = Data("\(tag):\(f):".utf8); data.append(Data((0..<extraSize).map { _ in UInt8.random(in: 0...255) }))
            try? data.write(to: top.appendingPathComponent(f))
        }
        let archive = dir.appendingPathComponent("pkg-\(tag).tar.bz2")
        guard run("/usr/bin/tar", ["-cjf", archive.path, "-C", dir.path, "pkg-\(tag)"]),
              let sha = try? Hashing.sha256(of: archive),
              let size = (try? FileManager.default.attributesOfItem(atPath: archive.path))?[.size] as? NSNumber else { return nil }
        return (archive, sha, size.int64Value)
    }

    static func entry(id: String = "fixture-model", version: String, archive: (url: URL, sha: String, size: Int64), vad: (url: URL, sha: String, size: Int64), base: String, mirrors: [String] = [], installedSize: Int64 = 20_000) -> LocalModelEntry {
        LocalModelEntry(id: id, version: version, displayName: ["en": "Fixture"], summary: ["en": "test"], kind: "sensevoice", languages: ["zh", "en"],
                        downloadSize: archive.size + vad.size, installedSize: installedSize, minAppVersion: "1.0.0", license: "test", changelog: "",
                        files: [LocalModelFile(name: archive.url.lastPathComponent, urls: [base + "/" + archive.url.lastPathComponent] + mirrors.map { $0 + "/" + archive.url.lastPathComponent }, sha256: archive.sha, size: archive.size, extract: true),
                                LocalModelFile(name: "silero_vad.onnx", urls: [base + "/silero_vad.onnx"], sha256: vad.sha, size: vad.size)],
                        requiredFiles: ["model.int8.onnx", "tokens.txt", "silero_vad.onnx"])
    }

    // MARK: 入口

    static func run(_ check: (String, Bool) -> Void) {
        func c(_ name: String, _ ok: Bool) { check("LocalModel " + name, ok) }
        catalog(c); archives(c); downloader(c); center(c); fallbackPolicy(c); fallbackSession(c); pipeline(c); recorder(c); config(c); LocalModelRobustnessFixtures.run(check)
    }

    // MARK: 清单

    static func catalog(_ c: (String, Bool) -> Void) {
        let b = LocalModelCatalog.builtin[0]
        c("内置清单有效", LocalModelCatalog.builtin.allSatisfy { LocalModelCatalog.validate($0) == nil && LocalModelCatalog.downloadable($0) })
        c("语音识别页只有三个页签：识别设置并进了本地模型页，不再单独成页", EngineTab.allCases == [.local, .cloud, .system] && EngineTab(rawValue: "tuning") == nil && L10n.tr("engine.tab.tuning") == "engine.tab.tuning")
        let speechIDs = ["paraformer-zh-int8", "qwen3-asr-06b-int8"]
        let profiles = LocalModelCatalog.builtin.compactMap(\.profile)
        c("模型资料：每个内置模型都写了速度、内存，语音模型有每秒倍速和标点，文字识别模型有每行毫秒", profiles.count == LocalModelCatalog.builtin.count && LocalModelCatalog.builtin.allSatisfy { e in e.profile.map { $0.memoryMB > 0 && $0.loadSeconds > 0 && (LocalModelCatalog.isOCR(e) ? $0.lineMilliseconds != nil && $0.realTimeFactor == nil : $0.realTimeFactor != nil && $0.punctuation != nil) } == true })
        c("模型资料：速度档位 0.10 以下快、0.20 以下中等，其余较慢", LocalModelProfile(realTimeFactor: 0.058, memoryMB: 1, loadSeconds: 1).speedClass == .fast && LocalModelProfile(realTimeFactor: 0.117, memoryMB: 1, loadSeconds: 1).speedClass == .medium && LocalModelProfile(realTimeFactor: 0.305, memoryMB: 1, loadSeconds: 1).speedClass == .slow && LocalModelProfile(lineMilliseconds: 30, memoryMB: 1, loadSeconds: 1).speedClass == nil)
        c("模型资料：内存显示 MB 或 GB", LocalModelProfile.memoryText(594) == "594 MB" && LocalModelProfile.memoryText(1783) == "1.8 GB")
        c("模型资料：一行摘要包含速度、倍速、内存、标点（语音）或每行毫秒、内存（文字识别）", {
            let speech = LocalModelCatalog.builtin[0].profile?.summary() ?? "", ocr = LocalModelCatalog.builtin.first(where: LocalModelCatalog.isOCR)?.profile?.summary() ?? ""
            return !speech.contains("local.profile") && speech.contains("0.6") && !ocr.contains("local.profile") && ocr.contains("30") && !ocr.contains("0.6")
        }())
        c("模型资料：旧清单没有资料字段时照常读取，写出再读回不丢", {
            guard let e = LocalModelCatalog.builtin.first, var raw = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(e))) as? [String: Any] else { return false }
            let roundTrip = (try? JSONDecoder().decode(LocalModelEntry.self, from: JSONEncoder().encode(e)))?.profile == e.profile
            raw["profile"] = nil
            let old = (try? JSONSerialization.data(withJSONObject: raw)).flatMap { try? JSONDecoder().decode(LocalModelEntry.self, from: $0) }
            return roundTrip && old != nil && old?.profile == nil
        }())
        c("内置清单：新增的两个语音模型存在、可用，推荐默认仍是 SenseVoice", speechIDs.allSatisfy { id in LocalModelCatalog.builtin.first { $0.id == id }.map { LocalModelCatalog.usable($0) && LocalModelCatalog.validate($0) == nil } == true } && LocalModelCatalog.recommendedID == "sensevoice-multilingual-int8")
        c("内置清单：不需要解压的条目，必需文件都能由下载的文件得到", LocalModelCatalog.builtin.filter { e in !e.files.contains { $0.extract } }.allSatisfy { e in Set(e.requiredFiles).isSubset(of: Set(e.files.map(\.name))) })
        if LocalTranscriberLoader.supported {
            let empty = tempDir("empty-model"); defer { try? FileManager.default.removeItem(at: empty) }
            c("新增语音模型：文件缺失时加载失败而不是崩溃", speechIDs.allSatisfy { id in LocalModelCatalog.builtin.first { $0.id == id }.map { (try? LocalTranscriberLoader.load(dir: empty, entry: $0)) == nil } == true })
        }
        c("内置清单：语音模型和文字识别模型各归各的，互不混入", LocalModelCatalog.builtin.filter(LocalModelCatalog.isOCR).allSatisfy { !LocalModelCatalog.usable($0) } && LocalModelCatalog.builtin.filter { !LocalModelCatalog.isOCR($0) }.allSatisfy { LocalModelCatalog.usable($0) } && LocalModelCatalog.builtin.contains(where: LocalModelCatalog.isOCR))
        let parakeet = LocalModelCatalog.builtin.first { $0.kind == "parakeet-tdt" }
        c("内置清单含欧洲语言包，覆盖德语/法语/西语/英语，不含中日韩", parakeet.map { ["de", "fr", "es", "en"].allSatisfy($0.languages.contains) && !$0.languages.contains("zh") && $0.languages.count == 25 } == true)
        c("欧洲包必需文件与官方示例一致", parakeet?.requiredFiles.sorted() == ["decoder.int8.onnx", "encoder.int8.onnx", "joiner.int8.onnx", "silero_vad.onnx", "tokens.txt"])
        let fireRed = LocalModelCatalog.builtin.first { $0.kind == "fire-red-ctc" }
        c("内置清单含 FireRedASR2 中英模型，不含欧洲语言", fireRed.map { $0.languages == ["zh", "en"] && $0.requiredFiles.contains("model.int8.onnx") && $0.files.first?.sha256 == "1da8b737ecc5e29f36759a4460c754863e7c919a4ba325aea187331fbfc83274" && LocalModelCatalog.usable($0) } == true)
        c("自动选择与安装顺序无关：中文优先推荐模型，指定高精度模型时用它", LocalModelCatalog.pick(forLanguages: ["zh-CN"], installed: LocalModelCatalog.builtin)?.id == LocalModelCatalog.recommendedID && LocalModelCatalog.pick(forLanguages: ["zh-CN"], installed: LocalModelCatalog.builtin.reversed())?.id == LocalModelCatalog.recommendedID && LocalModelCatalog.pick(forLanguages: ["zh-CN"], installed: fireRed.map { [$0] } ?? [])?.kind == "fire-red-ctc")
        c("语言选择：德语选欧洲包，中文选东亚包，都装时互不抢", LocalModelCatalog.pick(forLanguages: ["de-DE"], installed: LocalModelCatalog.builtin)?.kind == "parakeet-tdt" && LocalModelCatalog.pick(forLanguages: ["zh-CN"], installed: LocalModelCatalog.builtin.reversed())?.kind == "sensevoice")
        c("内置模型是通用多语种版而非粤语微调版", b.files[0].name.contains("2024-07-17") && !b.files[0].name.contains("2025-09-09"))
        func bad(_ edit: (inout LocalModelEntry) -> Void) -> Bool { var e = b; edit(&e); return LocalModelCatalog.validate(e) != nil }
        c("拒绝 http 地址", bad { $0.files[0].urls = ["http://example.com/a.tar.bz2"] })
        c("拒绝路径穿越文件名", bad { $0.files[0].name = "../evil.tar.bz2" })
        c("拒绝坏的 SHA256", bad { $0.files[0].sha256 = "xyz" })
        c("拒绝必需文件的路径穿越", bad { $0.requiredFiles = ["../../etc/passwd"] })
        c("拒绝重复文件名", bad { $0.files[1].name = $0.files[0].name })
        c("拒绝异常 id", bad { $0.id = "a/b" })
        c("版本比较", LocalModelVersion.isNewer("1.1.0", than: "1.0.9") && !LocalModelVersion.isNewer("1.0", than: "1.0.0") && LocalModelVersion.isNewer("2", than: "1.9.9") && LocalModelVersion.isNewer("1.0.0", than: nil))
        var newer = b; newer.version = "1.2.0"; var other = b; other.id = "other"; var broken = b; broken.id = "../x"
        let merged = LocalModelCatalog.merge(builtin: [b], remote: [newer, other, broken])
        c("合并：同 id 取新版、新增 id 保留、无效条目丢弃", merged.count == 2 && merged[0].version == "1.2.0" && merged[1].id == "other")
        var win = b; win.id = "windows-only"; win.platforms = ["windows"]; var any = b; any.id = "any-platform"; any.platforms = []
        let byPlatform = LocalModelCatalog.merge(builtin: [b], remote: [win, any])
        c("平台字段：只保留适用于本平台的条目，缺省表示所有平台", byPlatform.map(\.id) == [b.id, "any-platform"] && LocalModelCatalog.appliesToCurrentPlatform(b))
        c("平台字段格式非法时拒绝", bad { $0.platforms = ["Mac OS"] } && bad { $0.platforms = Array(repeating: "x", count: 9) })
        var future = b; future.minAppVersion = "99.0.0"; var odd = b; odd.kind = "something-new"
        c("需要更新软件/不支持的家族不可用", !LocalModelCatalog.usable(future) && !LocalModelCatalog.usable(odd))
        // 清单签名
        let key = Curve25519.Signing.PrivateKey(), body = Data("{\"schema\":1,\"models\":[]}".utf8)
        let pub = key.publicKey.rawRepresentation.base64EncodedString(), sig = (try! key.signature(for: body)).base64EncodedString()
        c("无公钥时不要求签名", LocalModelCatalog.verifySignature(manifest: body, signatureBase64: nil, publicKeys: []))
        c("有效签名通过", LocalModelCatalog.verifySignature(manifest: body, signatureBase64: sig, publicKeys: [pub]))
        c("篡改内容拒绝", !LocalModelCatalog.verifySignature(manifest: Data("{\"schema\":1,\"models\":[1]}".utf8), signatureBase64: sig, publicKeys: [pub]))
        c("缺签名拒绝", !LocalModelCatalog.verifySignature(manifest: body, signatureBase64: nil, publicKeys: [pub]))
        c("其他密钥签名拒绝", !LocalModelCatalog.verifySignature(manifest: body, signatureBase64: sig, publicKeys: [Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()]))
        c("清单 schema 不对拒绝", (try? LocalModelCatalog.decode(Data("{\"schema\":2,\"models\":[]}".utf8))) == nil)
        let json = "{\"schema\":1,\"models\":[{\"id\":\"x\",\"version\":\"1.0.0\",\"display_name\":{\"en\":\"X\"},\"summary\":{},\"kind\":\"sensevoice\",\"languages\":[\"zh\"],\"download_size\":10,\"installed_size\":20,\"min_app_version\":\"1.0.0\",\"license\":\"t\",\"changelog\":\"\",\"files\":[{\"name\":\"a.bin\",\"urls\":[\"https://e.com/a.bin\"],\"sha256\":\"\(String(repeating: "a", count: 64))\",\"size\":10}],\"required_files\":[\"a.bin\"]}]}"
        let decoded = try? LocalModelCatalog.decode(Data(json.utf8))
        c("蛇形字段清单可解析且校验通过", decoded?.models.first.map { LocalModelCatalog.validate($0) == nil } == true)
        // The example list: from the cadenza folder (the installer runs there) or from the repository root (CI runs there). It used
        // to be read only from the first, so the check was skipped silently everywhere else.
        let exampleURLs = ["docs/models-manifest.example.json", "cadenza/docs/models-manifest.example.json"].map { URL(fileURLWithPath: $0) }
        let snake = "{\"schema\":1,\"models\":[{\"id\":\"x\",\"version\":\"1.0.0\",\"kind\":\"sensevoice\",\"download_size\":10,\"installed_size\":10,\"files\":[{\"name\":\"a.bin\",\"urls\":[\"https://example.com/a\"],\"sha256\":\"" + String(repeating: "a", count: 64) + "\",\"size\":10}],\"required_files\":[\"a.bin\"],\"profile\":{\"real_time_factor\":0.058,\"memory_mb\":594,\"load_seconds\":0.4,\"punctuation\":true}}]}"
        let withProfile = (try? LocalModelCatalog.decode(Data(snake.utf8)))?.models.first?.profile
        c("清单里的模型资料用下划线写法（memory_mb 等）也能读出来", withProfile?.memoryMB == 594 && withProfile?.realTimeFactor == 0.058 && withProfile?.punctuation == true)
        if let data = exampleURLs.lazy.compactMap({ try? Data(contentsOf: $0) }).first {
            let m = try? LocalModelCatalog.decode(data)
            c("样例清单可解析且全部条目有效", m != nil && m!.models.allSatisfy { LocalModelCatalog.validate($0) == nil })
            c("样例清单与内置清单一致", m?.models == LocalModelCatalog.builtin)
        }
        let e1 = LocalModelEntry(id: "east", version: "1.0.0", displayName: [:], summary: [:], kind: "sensevoice", languages: ["zh", "ja"], downloadSize: 1, installedSize: 1, minAppVersion: "1.0.0", license: "", changelog: "", files: [], requiredFiles: [])
        var e2 = e1; e2.id = "world"; e2.languages = ["*"]
        c("按语言选择：精确优先，通配兜底", LocalModelCatalog.pick(forLanguages: ["ja-JP"], installed: [e2, e1])?.id == "east" && LocalModelCatalog.pick(forLanguages: ["fr"], installed: [e1, e2])?.id == "world" && LocalModelCatalog.pick(forLanguages: ["zh"], installed: []) == nil)
    }

    // MARK: 压缩包

    static func archives(_ c: (String, Bool) -> Void) {
        let dir = tempDir("archive"); defer { try? FileManager.default.removeItem(at: dir) }
        if let a = makeArchive(in: dir, tag: "ok") {
            let out = dir.appendingPathComponent("out")
            c("解压并去掉最外层目录", (try? ArchiveExtractor.extract(a.url, into: out)) != nil && FileManager.default.fileExists(atPath: out.appendingPathComponent("model.int8.onnx").path) && !FileManager.default.fileExists(atPath: out.appendingPathComponent("pkg-ok").path))
            c("SHA256 分块计算与归档一致", (try? Hashing.sha256(of: a.url)) == a.sha)
        } else { c("构造测试压缩包", false) }
        // 含符号链接的包必须被拒绝
        let evil = dir.appendingPathComponent("evil", isDirectory: true); try? FileManager.default.createDirectory(at: evil, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(at: evil.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        let evilTar = dir.appendingPathComponent("evil.tar.bz2")
        c("符号链接的包被拒绝", run("/usr/bin/tar", ["-cjf", evilTar.path, "-C", dir.path, "evil"]) && { do { try ArchiveExtractor.extract(evilTar, into: dir.appendingPathComponent("o2")); return false } catch { return (error as? LocalModelError).map { if case .unsafeArchive = $0 { return true }; return false } ?? false } }())
        // 绝对路径的包必须被拒绝
        let absFile = dir.appendingPathComponent("abs.txt"); try? Data("x".utf8).write(to: absFile)
        let absTar = dir.appendingPathComponent("abs.tar.bz2")
        c("绝对路径的包被拒绝", run("/usr/bin/tar", ["-cjPf", absTar.path, absFile.path]) && (try? ArchiveExtractor.validateEntries(absTar)) == nil)
        c("损坏的包解压失败", { let bad = dir.appendingPathComponent("bad.tar.bz2"); try? Data("not a tar".utf8).write(to: bad); return (try? ArchiveExtractor.extract(bad, into: dir.appendingPathComponent("o3"))) == nil }())
    }

    // MARK: 下载器

    final class Server {
        enum Mode { case normal, dropFirst, ignoreRange, fail }
        let body: Data; var mode: Mode
        private(set) var port: UInt16 = 0
        private var listener: NWListener?
        private let lock = NSLock()
        private var _ranges: [String?] = [], dropArmed = false
        /// 让下一次请求只发送一部分内容就断开连接
        func arm() { lock.lock(); dropArmed = true; lock.unlock() }
        var ranges: [String?] { lock.lock(); defer { lock.unlock() }; return _ranges }
        var base: String { "http://127.0.0.1:\(port)" }
        init(body: Data, mode: Mode = .normal) { self.body = body; self.mode = mode }
        func start() -> Bool {
            guard let l = try? NWListener(using: .tcp, on: .any) else { return false }
            listener = l
            let ready = DispatchSemaphore(value: 0)
            l.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.start(queue: DispatchQueue(label: "fixture.server"))
            guard ready.wait(timeout: .now() + 5) == .success, let p = l.port?.rawValue else { return false }
            port = p; return true
        }
        func stop() { listener?.cancel() }
        /// Sends the bytes, then closes the connection after `closeAfter` seconds. Closing right away made a busy client report
        /// "connection lost" before it had passed on the partial body, so the resume test depended on machine speed; the pause
        /// lets it hand over the bytes first.
        private static func finish(_ conn: NWConnection, _ data: Data, closeAfter: TimeInterval = 0) {
            conn.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                if closeAfter > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + closeAfter) { conn.cancel() } } else { conn.cancel() }
            })
        }
        private func handle(_ conn: NWConnection) {
            conn.start(queue: DispatchQueue(label: "fixture.conn"))
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
                guard let self, let data, let req = String(data: data, encoding: .utf8) else { conn.cancel(); return }
                let range = req.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
                self.lock.lock(); self._ranges.append(range); let drop = self.dropArmed && self.mode == .dropFirst; if drop { self.dropArmed = false }; self.lock.unlock()
                if self.mode == .fail { conn.send(content: Data("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in conn.cancel() }); return }
                var start = 0, status = "200 OK", extra = ""
                if let r = range, self.mode != .ignoreRange, let eq = r.firstIndex(of: "="), let s = Int(r[r.index(after: eq)...].split(separator: "-").first ?? "") {
                    start = s; status = "206 Partial Content"; extra = "Content-Range: bytes \(s)-\(self.body.count - 1)/\(self.body.count)\r\n"
                }
                let payload = self.body.suffix(from: start)
                var out = Data("HTTP/1.1 \(status)\r\nContent-Length: \(payload.count)\r\n\(extra)Connection: close\r\n\r\n".utf8)
                if drop { out.append(payload.prefix(payload.count * 2 / 5)); Self.finish(conn, out, closeAfter: 0.8); return }
                out.append(payload)
                Self.finish(conn, out)
            }
        }
    }

    final class Outcome { var result: Result<Void, Error>?; var progress: Int64 = 0 }

    static func download(_ file: LocalModelFile, to part: URL) -> (Outcome, ResumableDownloader) {
        let o = Outcome(), d = ResumableDownloader(file: file, partURL: part)
        d.start(progress: { o.progress = $0 }, completion: { o.result = $0 })
        return (o, d)
    }

    static func downloader(_ c: (String, Bool) -> Void) {
        let body = Data((0..<600_000).map { _ in UInt8.random(in: 0...255) })
        let sha = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        func file(_ urls: [String]) -> LocalModelFile { LocalModelFile(name: "f.bin", urls: urls, sha256: sha, size: Int64(body.count)) }
        func ok(_ url: URL) -> Bool { (try? Hashing.sha256(of: url)) == sha }
        let dir = tempDir("dl"); defer { try? FileManager.default.removeItem(at: dir) }

        let s1 = Server(body: body); guard s1.start() else { c("本机测试服务器启动", false); return }; defer { s1.stop() }
        var part = dir.appendingPathComponent("a.part")
        var (o, _) = download(file([s1.base + "/f.bin"]), to: part)
        c("完整下载且内容一致", wait { o.result != nil } && (try? o.result?.get()) != nil && ok(part) && o.progress == Int64(body.count))

        s1.mode = .dropFirst; s1.arm(); part = dir.appendingPathComponent("b.part")
        let before = s1.ranges.count
        (o, _) = download(file([s1.base + "/f.bin"]), to: part)
        let resumed = wait { o.result != nil } && (try? o.result?.get()) != nil && ok(part)
        let after = Array(s1.ranges.dropFirst(before))
        // Whether the partial body reaches the downloader before the "connection lost" error depends on the system, so this only
        // requires that the interrupted download is retried and ends with the complete, verified file.
        c("连接中断后重试并得到完整文件", resumed && after.count >= 2 && after[0] == nil)
        // The Range request itself is checked with a half-written .part file, which does not depend on timing.
        part = dir.appendingPathComponent("seeded.part")
        try? body.prefix(240_000).write(to: part)
        let beforeSeeded = s1.ranges.count
        s1.mode = .normal
        (o, _) = download(file([s1.base + "/f.bin"]), to: part)
        let seeded = wait { o.result != nil } && (try? o.result?.get()) != nil && ok(part)
        c("已有部分数据时用 Range 从断点续传并得到完整文件", seeded && s1.ranges.dropFirst(beforeSeeded).first == "bytes=240000-")

        s1.mode = .ignoreRange; part = dir.appendingPathComponent("c.part")
        try? body.prefix(1000).write(to: part)
        (o, _) = download(file([s1.base + "/f.bin"]), to: part)
        c("服务器忽略 Range 时从头重写，结果仍正确", wait { o.result != nil } && (try? o.result?.get()) != nil && ok(part))

        s1.mode = .fail; let s2 = Server(body: body); _ = s2.start(); defer { s2.stop() }
        part = dir.appendingPathComponent("d.part")
        (o, _) = download(file([s1.base + "/f.bin", s2.base + "/f.bin"]), to: part)
        c("主地址失败自动切换镜像", wait(30) { o.result != nil } && (try? o.result?.get()) != nil && ok(part) && s1.ranges.count >= 2)

        part = dir.appendingPathComponent("e.part")
        (o, _) = download(file([s1.base + "/f.bin"]), to: part)
        c("所有地址都失败时报错", wait(30) { o.result != nil } && { if case .failure = o.result! { return true }; return false }())

        // 暂停保留 .part，再次开始续传
        let slow = Server(body: body, mode: .normal); _ = slow.start(); defer { slow.stop() }
        part = dir.appendingPathComponent("f.part")
        try? body.prefix(250_000).write(to: part)
        let (o2, d2) = download(file([slow.base + "/f.bin"]), to: part)
        d2.stop()
        let stopped = wait { o2.result != nil }
        let cancelled: Bool = { if case .failure(let e) = o2.result!, (e as? LocalModelError) == .cancelled { return true }; return false }()
        c("暂停后以取消结束", stopped && (cancelled || ok(part)))
        (o, _) = download(file([slow.base + "/f.bin"]), to: part)
        c("暂停后重新开始可完成", wait { o.result != nil } && (try? o.result?.get()) != nil && ok(part))
    }

    // MARK: 管理器：安装 / 校验失败 / 升级 / 回滚 / 删除 / 取消 / 导入

    static func center(_ c: (String, Bool) -> Void) {
        let work = tempDir("center"); defer { try? FileManager.default.removeItem(at: work) }
        guard let a1 = makeArchive(in: work, tag: "v1"), let a2 = makeArchive(in: work, tag: "v2") else { c("构造测试包", false); return }
        let vadFile = work.appendingPathComponent("silero_vad.onnx"); try? Data((0..<3000).map { _ in UInt8.random(in: 0...255) }).write(to: vadFile)
        let vad = (url: vadFile, sha: (try? Hashing.sha256(of: vadFile)) ?? "", size: Int64(3000))
        // 每个文件起一个服务器，各自提供固定内容
        let sA1 = Server(body: (try? Data(contentsOf: a1.url)) ?? Data()), sA2 = Server(body: (try? Data(contentsOf: a2.url)) ?? Data()), sV = Server(body: (try? Data(contentsOf: vadFile)) ?? Data())
        guard sA1.start(), sA2.start(), sV.start() else { c("测试服务器启动", false); return }
        defer { sA1.stop(); sA2.stop(); sV.stop() }
        func make(_ tag: String, _ version: String, _ a: (url: URL, sha: String, size: Int64), _ server: Server, installedSize: Int64 = 20_000) -> LocalModelEntry {
            var e = entry(version: version, archive: a, vad: vad, base: server.base, installedSize: installedSize)
            e.files[0].urls = [server.base + "/" + a.url.lastPathComponent]; e.files[1].urls = [sV.base + "/silero_vad.onnx"]; return e
        }
        let e1 = make("v1", "1.0.0", a1, sA1), e2 = make("v2", "1.1.0", a2, sA2)
        let root = work.appendingPathComponent("models")
        let center = LocalModelCenter(root: root)
        var changes = 0; center.onChange = { changes += 1 }
        center.validator = { dir, _ in FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.int8.onnx").path) }

        // 测试条目不在内置清单里，注入后管理器才能按 id 找到它
        func inject(_ e: LocalModelEntry) { center.testInject(e) }
        inject(e1)
        c("初始为未安装", center.state(e1.id) == .notInstalled)
        center.download(e1)
        c("下载安装成功并进入已安装状态", wait(30) { if case .installed = center.state(e1.id) { return true }; return false })
        c("安装目录含全部必需文件", center.modelDir(e1.id).map { dir in e1.requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) } } == true)
        c("暂存目录已清理", !FileManager.default.fileExists(atPath: root.appendingPathComponent(".downloads/\(e1.id)-1.0.0").path))
        c("安装集合变化已通知", changes >= 1 && center.isReady(e1.id))
        let reopened = LocalModelCenter(root: root); reopened.testInject(e1)
        c("重启后安装状态保留", reopened.isReady(e1.id) && reopened.installed[e1.id]?.version == "1.0.0")

        // 升级：新版本装在旁边，保留上一版
        inject(e2); center.download(e2)
        c("升级成功且保留上一版", wait(30) { center.installed[e2.id]?.version == "1.1.0" } && center.installed[e2.id]?.previous == "1.0.0" && FileManager.default.fileExists(atPath: root.appendingPathComponent("\(e1.id)-1.0.0").path))
        c("回滚到上一版", center.rollback(e1.id) && center.installed[e1.id]?.version == "1.0.0" && !FileManager.default.fileExists(atPath: root.appendingPathComponent("\(e1.id)-1.1.0").path))
        c("没有上一版时不能回滚", !center.rollback(e1.id))

        // 自检失败：新版本被丢弃，现行版本不受影响
        let before = center.installed[e1.id]?.version
        center.validator = { _, _ in false }
        center.download(e2)
        c("加载自检失败时丢弃新版并保持现行版本", wait(30) { if case .failed = center.state(e2.id) { return true }; return false } && center.installed[e1.id]?.version == before && !FileManager.default.fileExists(atPath: root.appendingPathComponent("\(e1.id)-1.1.0").path))
        center.clearFailure(e1.id); center.validator = nil

        // 删除
        center.delete(e1.id)
        c("删除后目录与记录都移除", center.state(e1.id) == .notInstalled && ((try? FileManager.default.contentsOfDirectory(atPath: root.path))?.contains { $0.hasPrefix(e1.id + "-") } == false))

        // 校验失败：哈希不对的文件被丢弃，不产生安装目录
        var bad = e1; bad.files[0].sha256 = String(repeating: "0", count: 64); center.testInject(bad)
        center.download(bad)
        c("校验失败报错且不留半成品", wait(30) { if case .failed = center.state(bad.id) { return true }; return false } && !FileManager.default.fileExists(atPath: root.appendingPathComponent("\(bad.id)-1.0.0").path) && !FileManager.default.fileExists(atPath: root.appendingPathComponent("\(bad.id)-1.0.0.tmp").path))
        center.clearFailure(bad.id)

        // 磁盘空间不足
        var huge = e1; huge.installedSize = 8_000_000_000_000; huge.downloadSize = 1_000_000_000_000; center.testInject(huge)
        center.download(huge)
        c("磁盘空间不足时直接拒绝", { if case .failed = center.state(huge.id) { return true }; return false }())
        center.clearFailure(huge.id); center.testInject(e1)

        // 不支持的模型家族
        var odd = e1; odd.kind = "future-kind"; center.testInject(odd); center.download(odd)
        c("不支持的家族不下载", { if case .failed = center.state(odd.id) { return true }; return false }())
        center.clearFailure(odd.id); center.testInject(e1)

        // 取消：清除暂存
        center.download(e1); center.cancel(e1.id)
        c("取消后不安装并清理暂存", wait(5) { center.state(e1.id) == .notInstalled && !FileManager.default.fileExists(atPath: root.appendingPathComponent(".downloads/\(e1.id)-1.0.0").path) })

        // A clean-up ordered by a cancel must not remove files imported afterwards (this race made the import check flaky on slow machines)
        let epoch = StagingEpoch()
        var removed = 0
        let mark = epoch.bump("m")
        epoch.performIfCurrent("m", mark: mark) { removed += 1 }
        c("清理：期间没有人动过暂存目录时照常清理", removed == 1)
        let late = epoch.bump("m")
        epoch.bump("m")   // an import (or a restarted download) in between
        epoch.performIfCurrent("m", mark: late) { removed += 1 }
        c("清理：取消之后又导入或重新下载则不再清理", removed == 1)
        epoch.bump("other")
        epoch.performIfCurrent("m", mark: epoch.bump("m")) { removed += 1 }
        c("清理：不同模型互不影响", removed == 2)
        // 导入：用户自己下载的包，按 SHA256 匹配后走同一套安装
        var imported: Result<LocalModelEntry, Error>?
        center.importFile(a1.url) { imported = $0 }
        c("导入匹配的包并完成安装", wait(90) { if case .installed = center.state(e1.id), imported != nil { return true }; return false } && (try? imported?.get().id) == e1.id)
        center.delete(e1.id)
        let hitsBefore = sA1.ranges.count + sV.ranges.count
        var multi: Result<LocalModelEntry, Error>?
        center.importFiles([a1.url, vadFile]) { multi = $0 }
        c("一次导入模型包和 VAD：完成安装且不产生任何网络请求", wait(30) { if case .installed = center.state(e1.id) { return true }; return false } && (try? multi?.get().id) == e1.id && sA1.ranges.count + sV.ranges.count == hitsBefore)
        center.delete(e1.id)
        var mixed: Result<LocalModelEntry, Error>?
        center.importFiles([a1.url, a2.url]) { mixed = $0 }
        c("同时导入属于不同模型版本的文件被拒绝", wait { mixed != nil } && { if case .failure = mixed! { return true }; return false }() && center.state(e1.id) == .notInstalled)
        var rejected: Result<LocalModelEntry, Error>?
        let stranger = work.appendingPathComponent("stranger.bin"); try? Data("nothing".utf8).write(to: stranger)
        center.importFile(stranger) { rejected = $0 }
        c("导入不认识的文件被拒绝", wait { rejected != nil } && { if case .failure = rejected! { return true }; return false }())

        // 暂停后重启：显示为已暂停，可继续
        let half = center.testStaging(e1); try? FileManager.default.createDirectory(at: half, withIntermediateDirectories: true)
        try? Data(count: 100).write(to: half.appendingPathComponent(e1.files[0].name + ".part"))
        let restarted = LocalModelCenter(root: root); restarted.testInject(e1); restarted.reload()
        c("重启后遗留的下载显示为已暂停", { if case .paused = restarted.state(e1.id) { return true }; return false }())
        restarted.cancel(e1.id)
    }

    // MARK: 回退策略

    static func fallbackPolicy(_ c: (String, Bool) -> Void) {
        let e = LocalModelEntry(id: "m1", version: "1.0.0", displayName: [:], summary: [:], kind: "sensevoice", languages: ["zh", "en"], downloadSize: 1, installedSize: 1, minAppVersion: "1.0.0", license: "", changelog: "", files: [], requiredFiles: [])
        var s = LocalModelSettings()
        func plan(_ online: Bool?, ready: [LocalModelEntry]? = nil, supported: Bool = true) -> FallbackPlan { FallbackPolicy.plan(settings: s, online: online, ready: ready ?? [e], languages: ["zh"], supported: supported) }
        c("默认：有网且有模型 → 云端 + 回退", plan(true) == .cloudWithFallback("m1"))
        c("没网且允许直连 → 直接本地", plan(false) == .localDirect("m1"))
        c("网络状态未知按有网处理", plan(nil) == .cloudWithFallback("m1"))
        c("没有已安装模型 → 只用云端", plan(true, ready: []) == .cloudOnly && plan(false, ready: []) == .cloudOnly)
        c("当前构建不含推理库 → 只用云端", plan(true, supported: false) == .cloudOnly)
        s.enabled = false
        c("关闭回退 → 只用云端", plan(true) == .cloudOnly && plan(false) == .cloudOnly)
        s.enabled = true; s.offlineDirect = false
        c("关闭“没网直连” → 仍先试云端并保留回退", plan(false) == .cloudWithFallback("m1"))
        s.modelID = "m2"
        c("指定的模型没装 → 退回自动选择", plan(true) == .cloudWithFallback("m1"))
        var e2 = e; e2.id = "m2"; s.modelID = "m2"
        c("指定模型已装 → 用指定模型", plan(true, ready: [e, e2]) == .cloudWithFallback("m2"))
        c("语言偏好映射", FallbackPolicy.languages(iflytekLanguage: "en_us", recognitionLocale: "zh-CN") == ["en"] && FallbackPolicy.languages(iflytekLanguage: "auto", recognitionLocale: "ja-JP").first == "ja-JP")
    }

    // MARK: 回退会话

    final class FakeCapture: CloudPCMCapturing {
        var onPCM: ((Data) -> Void)?, onLevel: ((Float) -> Void)?
        var hasSignal = true, startedUptime: TimeInterval?, lastError: String?
        var stops = 0, tailOnStop: Data?
        func start(uid: String) -> Bool { startedUptime = 1; return true }
        func stop() { stops += 1; if let t = tailOnStop { onPCM?(t); tailOnStop = nil } }
        func feed(_ samples: Int) { onPCM?(Data(repeating: 1, count: samples * 2)) }
    }

    final class FakePrimary: HoldRecordingSession {
        var onLevel: ((Float) -> Void)?, onPartial: ((String) -> Void)?, onFinal: ((String?) -> Void)?
        var lastError: String?
        let capture: CloudPCMCapturing
        var ended = false, aborted = false
        init(capture: CloudPCMCapturing) { self.capture = capture }
        func begin() -> Bool { capture.onPCM = { _ in }; return capture.start(uid: "") }
        func end() { ended = true; capture.stop() }
        func abort() { aborted = true; capture.stop() }
        func fail(_ message: String) { lastError = message; capture.stop(); let cb = onFinal; cb?(nil) }
        func succeed(_ text: String?) { let cb = onFinal; cb?(text) }
    }

    final class Box<T> { var value: T?; init() {} }

    static func fallbackSession(_ c: (String, Bool) -> Void) {
        func make(decode: @escaping ([Float]) throws -> String, capture: FakeCapture = FakeCapture()) -> (FallbackRecordingSession, FakeCapture, Box<FakePrimary>, Box<String?>, () -> Bool) {
            let primaryBox = Box<FakePrimary>(), result = Box<String?>(); var done = false
            let s = FallbackRecordingSession(modelID: "m", capture: capture, decode: decode, makePrimary: { cap in let p = FakePrimary(capture: cap); primaryBox.value = p; return p })
            s.onFinal = { t in result.value = .some(t); done = true }
            return (s, capture, primaryBox, result, { done })
        }
        struct Boom: Error {}
        var decodedCount = 0

        // 云端成功：不动用本地
        var (s, cap, p, r, done) = make(decode: { _ in decodedCount += 1; return "本地" })
        _ = s.begin(); cap.feed(1600); s.end()
        _ = wait { p.value?.ended == true }; p.value?.succeed("云端文字")
        c("云端成功时直接交付云端结果且不调用本地", wait { done() } && r.value == .some("云端文字") && decodedCount == 0 && !s.usedFallback && s.lastError == nil)
        c("云端成功时先冲刷采集尾音再通知云端结束", cap.stops >= 1)

        // 云端空结果但没有错误：不回退
        (s, cap, p, r, done) = make(decode: { _ in decodedCount += 1; return "本地" })
        _ = s.begin(); cap.feed(1600); s.end(); _ = wait { p.value?.ended == true }; p.value?.succeed(nil)
        c("云端无错误的空结果不触发回退", wait { done() } && r.value == .some(nil) && decodedCount == 0)

        // 松开后云端才失败
        var got: [Float] = []
        (s, cap, p, r, done) = make(decode: { got = $0; return "本地文字" })
        _ = s.begin(); cap.feed(3200); s.end(); _ = wait { p.value?.ended == true }
        p.value?.fail("连接超时")
        c("云端失败后用已缓冲音频交给本地，用户无需重说", wait { done() } && r.value == .some("本地文字") && got.count == 3200)
        c("回退成功后没有残留错误并带有提示", s.lastError == nil && s.fallbackNotice != nil && s.usedFallback)

        // 录音中途云端失败：继续录音，松开后识别整段
        (s, cap, p, r, done) = make(decode: { got = $0; return "整段本地" })
        _ = s.begin(); cap.feed(1600)
        p.value?.fail("连接中断")
        let stopsAfterFail = cap.stops
        cap.feed(1600)
        c("录音中途云端失败时麦克风不停", stopsAfterFail == 0 && !done())
        s.end()
        c("松开后识别包含失败前后的完整音频", wait { done() } && r.value == .some("整段本地") && got.count == 3200 && p.value?.ended == false)

        // 本地也失败：保留云端错误
        (s, cap, p, r, done) = make(decode: { _ in throw Boom() })
        _ = s.begin(); cap.feed(1600); s.end(); _ = wait { p.value?.ended == true }; p.value?.fail("鉴权失败")
        c("本地也失败时报告错误且不输出文字", wait { done() } && r.value == .some(nil) && (s.lastError ?? "").contains("鉴权失败") && !s.usedFallback)

        // 无信号（静音）：不输出幻觉文字
        let silent = FakeCapture(); silent.hasSignal = false
        (s, cap, p, r, done) = make(decode: { _ in "幻觉" }, capture: silent)
        _ = s.begin(); cap.feed(1600); s.end(); _ = wait { p.value?.ended == true }; p.value?.fail("x")
        c("静音录音不输出回退文字", wait { done() } && r.value == .some(nil))

        // 缓冲溢出（超过 120 秒）：无法回退，保留云端失败
        (s, cap, p, r, done) = make(decode: { _ in "不应调用" })
        _ = s.begin(); cap.feed(121 * 16000); s.end(); _ = wait { p.value?.ended == true }; p.value?.fail("超时")
        c("录音超过缓冲上限时不回退并保留原错误", wait { done() } && r.value == .some(nil) && s.lastError != nil && !s.usedFallback)

        // 松开后云端一直不响应：宽限时间到后改用本地，并取消云端
        (s, cap, p, r, done) = make(decode: { got = $0; return "超时后的本地文字" })
        s.graceSeconds = 0.3
        _ = s.begin(); cap.feed(1600); s.end()
        c("云端松开后长时间无响应时按宽限时间改用本地", wait(5) { done() } && r.value == .some("超时后的本地文字") && p.value?.aborted == true && s.usedFallback)

        // 宽限时间内云端正常返回：以云端为准，不再回退
        (s, cap, p, r, done) = make(decode: { _ in decodedCount += 1; return "不应使用" })
        s.graceSeconds = 0.6; decodedCount = 0
        _ = s.begin(); cap.feed(1600); s.end(); _ = wait { p.value?.ended == true }; p.value?.succeed("云端按时返回")
        _ = wait(1.2) { false }
        c("宽限时间内云端返回则不回退", r.value == .some("云端按时返回") && decodedCount == 0 && !s.usedFallback)

        // 取消：无回调、清空缓冲
        (s, cap, p, r, done) = make(decode: { _ in "不应调用" })
        _ = s.begin(); cap.feed(1600); s.abort()
        c("取消不触发任何结果并通知云端取消", p.value?.aborted == true && !done())
        // 云端无法开始（例如凭据缺失）而麦克风没启动：保持原错误
        final class Refusing: HoldRecordingSession { var onLevel: ((Float) -> Void)?; var onPartial: ((String) -> Void)?; var onFinal: ((String?) -> Void)?; var lastError: String? = "凭据缺失"; func begin() -> Bool { false }; func end() {}; func abort() {} }
        let s2 = FallbackRecordingSession(modelID: "m", capture: FakeCapture(), decode: { _ in "x" }, makePrimary: { _ in Refusing() })
        c("云端无法开始且麦克风未启动时按原样失败", !s2.begin() && s2.lastError == "凭据缺失")
    }

    // MARK: 管线集成

    final class NoticeRecorder: HoldRecordingSession {
        var onLevel: ((Float) -> Void)?, onPartial: ((String) -> Void)?, onFinal: ((String?) -> Void)?
        var lastError: String?, fallbackNotice: String?
        func begin() -> Bool { true }
        func end() {}
        func abort() {}
    }

    static func pipeline(_ c: (String, Bool) -> Void) {
        let store = ConfigStore(); let saved = store.config
        defer { store.mutate { $0 = saved } }
        store.mutate { $0.enabled = true; $0.mode = "hold"; $0.engine = "apple" }
        let pipeline = VoicePipeline(configStore: store, input: InputSourceController())
        pipeline.selfTestMode = true; pipeline.snapshotFocus = { nil }
        let rec = NoticeRecorder(); rec.fallbackNotice = "NOTICE-TEXT"
        pipeline.recorderFactory = { rec }
        pipeline.holdStarted(source: .button)
        pipeline.holdEnded()
        rec.onFinal?("回退识别的文字")
        _ = wait(2) { pipeline.session == nil }
        c("回退提示附在结果信息里，识别文字照常展示", (pipeline.lastResult.contains("NOTICE-TEXT")) && pipeline.lastTranscript == "回退识别的文字")

        let plain = NoticeRecorder()
        pipeline.recorderFactory = { plain }
        pipeline.holdStarted(source: .button); pipeline.holdEnded(); plain.onFinal?("普通结果")
        _ = wait(2) { pipeline.session == nil }
        c("没有回退时结果信息不含提示", !pipeline.lastResult.contains("NOTICE-TEXT") && pipeline.lastTranscript == "普通结果")

        // 选了本地引擎但没有可用模型：拒绝开始并给出提示（机器上已装模型时跳过，避免真的开始录音）
        if LocalModelCenter.shared.installedEntries.isEmpty {
            pipeline.recorderFactory = nil
            store.mutate { $0.engine = "local" }
            pipeline.holdStarted(source: .button)
            c("本地引擎没有模型时拒绝开始并提示", pipeline.session == nil && pipeline.lastIsError)
        }
    }

    // MARK: 本地识别会话与识别器缓存

    final class FakeTranscriber: LocalTranscriber {
        let text: String; var seen: [Int] = []
        init(_ t: String) { text = t }
        func transcribe(_ s: [Float]) -> String { seen.append(s.count); return text }
        func speechSegments(_ s: [Float]) -> [Range<Int>] { stride(from: 0, to: s.count, by: 16000).map { $0..<min(s.count, $0 + 16000) } }
    }

    static func recorder(_ c: (String, Bool) -> Void) {
        let work = tempDir("rec"); defer { try? FileManager.default.removeItem(at: work) }
        let e = LocalModelEntry(id: "rec-model", version: "1.0.0", displayName: [:], summary: [:], kind: "sensevoice", languages: ["zh"], downloadSize: 1, installedSize: 1, minAppVersion: "1.0.0", license: "", changelog: "", files: [], requiredFiles: ["model.int8.onnx"])
        let center = LocalModelCenter(root: work); center.testInject(e)
        for v in ["1.0.0", "1.1.0"] {
            let d = work.appendingPathComponent("rec-model-\(v)"); try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try? Data("x\(v)".utf8).write(to: d.appendingPathComponent("model.int8.onnx"))
        }
        center.testSetInstalled(e.id, LocalModelInstalled(version: "1.1.0", previous: "1.0.0", installedAt: Date()))

        // 长录音切段与拼接
        let t = FakeTranscriber("hello")
        let long = [Float](repeating: 0.1, count: 40 * 16000)
        let joined = LocalDecoder.transcribe(long, with: t)
        c("长录音按停顿切段并拼接（英文段之间加空格）", t.seen.count == 40 && joined.hasPrefix("hello hello") && t.seen.allSatisfy { $0 == 16000 })
        let t2 = FakeTranscriber("你好")
        c("中文段之间不加空格", LocalDecoder.transcribe(long, with: t2).hasPrefix("你好你好") && !LocalDecoder.transcribe(long, with: t2).contains(" "))
        c("短于 0.2 秒不识别", LocalDecoder.transcribe([Float](repeating: 0.1, count: 1000), with: t2) == "")
        c("PCM16 转 float", LocalDecoder.samples(fromPCM16: Data([0x00, 0x40, 0x00, 0xC0])) == [0.5, -0.5])

        // 音量归一化：只放大、有上限、不改变长度；整句里的单个爆音不阻止放大
        let quietClip = (0..<16000).map { Float(sin(Double($0) / 20)) * 0.02 }
        let boosted = LocalDecoder.levelled(quietClip)
        c("安静录音被放大到可识别电平", boosted.count == quietClip.count && (boosted.map(abs).max() ?? 0) > 0.4 && (boosted.map(abs).max() ?? 0) <= 1)
        let loudClip = quietClip.map { $0 * 40 }
        c("够响的录音保持不变", LocalDecoder.levelled(loudClip) == loudClip)
        let silent = [Float](repeating: 0, count: 16000)
        c("静音不被放大", LocalDecoder.levelled(silent) == silent)
        let faint = [Float](repeating: 0.0006, count: 16000).enumerated().map { $0.offset.isMultiple(of: 2) ? $0.element : -$0.element }
        c("放大倍数有上限（底噪不被放成语音）", (LocalDecoder.levelled(faint).map(abs).max() ?? 0) <= 0.0006 * 30 + 0.0001)
        var clicked = quietClip; clicked[8000] = 0.9
        c("单个爆音不阻止放大", (LocalDecoder.levelled(clicked).dropFirst(100).prefix(2000).map(abs).max() ?? 0) > 0.2)
        c("很短的片段不处理", LocalDecoder.levelled([0.01, 0.02]) == [0.01, 0.02])
        let seenLoud = FakeTranscriber("x")
        _ = LocalDecoder.transcribe(quietClip, with: seenLoud)
        c("识别前先归一化音量", seenLoud.seen.count == 1)

        // 用我的声音比较模型：录音、识别、打分、清除，全部在内存里
        final class FakeCompareCapture: CloudPCMCapturing {
            var onPCM: ((Data) -> Void)?; var onLevel: ((Float) -> Void)?
            var hasSignal = true; var startedUptime: TimeInterval? = 0; var lastError: String?; var started = false
            var failStart = false
            func start(uid: String) -> Bool { if failStart { lastError = "no mic"; return false }; started = true; return true }
            func stop() { started = false }
            func emit(seconds: Double, amplitude: Float) {
                let n = Int(seconds * 16000)
                var d = Data(capacity: n * 2)
                for i in 0..<n { var v = Int16(Float(sin(Double(i) / 9)) * amplitude * 32767).littleEndian; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
                onPCM?(d)
            }
        }
        func compareEntry(_ id: String) -> LocalModelEntry { LocalModelEntry(id: id, version: "1.0.0", displayName: [:], summary: [:], kind: "sensevoice", languages: ["zh"], downloadSize: 1, installedSize: 1, minAppVersion: "1.0.0", license: "", changelog: "", files: [], requiredFiles: []) }
        let zhPrompts = VoiceCompare.prompts(forLocale: "zh-CN"), enPrompts = VoiceCompare.prompts(forLocale: "en-US")
        c("比较：中文和英文环境各有 5 句要念的句子", zhPrompts.count == 5 && enPrompts.count == 5 && zhPrompts != enPrompts && zhPrompts.allSatisfy { !$0.isEmpty })
        let fake = FakeCompareCapture()
        let perfect = compareEntry("cmp-perfect"), blank = compareEntry("cmp-blank")
        func makeCompare(models: [LocalModelEntry], failing: Set<String> = []) -> VoiceCompare {
            VoiceCompare(prompts: zhPrompts, models: models, makeCapture: { fake }, loader: { entry in
                if failing.contains(entry.id) { return nil }
                if entry.id == "cmp-perfect" { return { samples in zhPrompts[max(0, min(zhPrompts.count - 1, Int((Double(samples.count) / 16000).rounded()) - 1))] } }
                return { _ in "" }
            })
        }
        func waitDone(_ cmp: VoiceCompare) { let end = Date().addingTimeInterval(10); while cmp.analyzing && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) } }
        let cmp = makeCompare(models: [perfect, blank])
        c("比较：录音开始后进入录音状态，且不能同时录第二句", cmp.startRecording(0) && cmp.recordingIndex == 0 && !cmp.startRecording(1) && fake.started)
        fake.emit(seconds: 1.0, amplitude: 0.3)
        cmp.stopRecording()
        c("比较：录好的片段按秒数保存，麦克风被关闭", cmp.recordingIndex == nil && !fake.started && abs((cmp.seconds(0) ?? 0) - 1.0) < 0.01 && cmp.recordedCount == 1)
        _ = cmp.startRecording(1); fake.emit(seconds: 0.2, amplitude: 0.3); cmp.stopRecording()
        c("比较：太短的录音被拒绝并提示", cmp.seconds(1) == nil && !cmp.message.isEmpty)
        _ = cmp.startRecording(1); fake.emit(seconds: 1.0, amplitude: 0.0001); cmp.stopRecording()
        c("比较：几乎无声的录音被拒绝并提示", cmp.seconds(1) == nil && !cmp.message.isEmpty)
        c("比较：少于 3 句不能开始对比", !cmp.canAnalyze)
        for i in 1...4 { _ = cmp.startRecording(i); fake.emit(seconds: Double(i + 1), amplitude: 0.3); cmp.stopRecording() }
        c("比较：录够句数后可以开始对比", cmp.recordedCount == 5 && cmp.canAnalyze)
        cmp.analyze(); waitDone(cmp)
        c("比较：每个模型对每句都有结果", cmp.results.count == 5 && cmp.results.allSatisfy { $0.count == 2 && $0.allSatisfy { $0 != nil } })
        c("比较：完全正确的模型错误率为 0，空结果的模型为 100%", cmp.averageError(0) == 0 && cmp.averageError(1) == 1)
        c("比较：错误率最低的模型被标为最准", cmp.bestModel == 0)
        c("比较：重录后旧结果作废", { _ = cmp.startRecording(2); fake.emit(seconds: 3.0, amplitude: 0.3); cmp.stopRecording(); return cmp.results.isEmpty }())
        let tie = makeCompare(models: [blank, compareEntry("cmp-blank2")])
        for i in 0..<3 { tie.setClip(i, [Float](repeating: 0.2, count: 16000 * (i + 1))) }
        tie.analyze(); waitDone(tie)
        c("比较：差距小于 1% 时不标最准", tie.results.count == 5 && tie.recordedCount == 3 && tie.bestModel == nil)
        let broken = makeCompare(models: [perfect, blank], failing: ["cmp-blank"])
        for i in 0..<3 { broken.setClip(i, [Float](repeating: 0.2, count: 16000 * (i + 1))) }
        broken.analyze(); waitDone(broken)
        c("比较：加载失败的模型被标出，其余模型照常出结果", broken.failedModels == ["cmp-blank"] && broken.averageError(0) == 0 && broken.averageError(1) == nil)
        func promptFor(_ samples: [Float]) -> String {
            let index = max(0, min(zhPrompts.count - 1, Int((Double(samples.count) / 16000).rounded()) - 1))
            return zhPrompts[index]
        }
        let punct = VoiceCompare(prompts: zhPrompts, models: [perfect, blank], makeCapture: { fake }, loader: { entry in
            if entry.id == "cmp-perfect" { return { samples in promptFor(samples) } }
            return { samples in String(promptFor(samples).filter { !VoiceCompare.punctuation.contains($0) }) }
        })
        for i in 0..<3 { punct.setClip(i, [Float](repeating: 0.2, count: 16000 * (i + 1))) }
        punct.analyze(); waitDone(punct)
        c("比较：识别出的文字完全没有标点时给出提示，有标点的不提示", punct.writesNoPunctuation(1) && !punct.writesNoPunctuation(0))
        c("比较：记录每个模型的识别耗时", (punct.averageSeconds(0) ?? -1) >= 0 && (punct.averageSeconds(1) ?? -1) >= 0)
        broken.clear()
        c("比较：关闭后录音和结果都被清除", broken.recordedCount == 0 && broken.results.isEmpty && broken.message.isEmpty)
        fake.failStart = true
        c("比较：麦克风打不开时给出原因而不进入录音", !cmp.startRecording(0) && cmp.recordingIndex == nil && cmp.message == "no mic")
        fake.failStart = false

        // 语言：中文场景直接指定 zh，避免“自动”把短句误判成日语或韩语
        let auto = LocalRecognitionOptions()
        c("中文识别语言自动改为 zh", auto.resolved(forLanguages: ["zh-CN"]).language == "zh" && auto.resolved(forLanguages: ["zh"]).language == "zh" && auto.resolved(forLanguages: ["zh", "en"]).language == "zh")
        c("英文与其他语言保持自动", auto.resolved(forLanguages: ["en"]).language == "auto" && auto.resolved(forLanguages: ["en-US"]).language == "auto" && auto.resolved(forLanguages: []).language == "auto")
        c("粤语区域不被强制成普通话", auto.resolved(forLanguages: ["zh-HK"]).language == "auto" && auto.resolved(forLanguages: ["yue"]).language == "auto")
        var chosen = LocalRecognitionOptions(); chosen.language = "ja"
        c("用户明确选择的语言不被覆盖", chosen.resolved(forLanguages: ["zh-CN"]).language == "ja")
        c("切段前后各留 0.8 秒（0.2 秒会吃掉句首轻音节）", LocalDecoder.segmentPad == 12800)

        // 准确度基准的打分
        c("CER 完全相同为 0，标点和空格不计", AccuracyBenchmark.cer(reference: "今天，天气不错。", hypothesis: "今天天气 不错") == 0)
        c("CER 阿拉伯数字与中文数字等价", AccuracyBenchmark.cer(reference: "下午三点开会", hypothesis: "下午3点开会") == 0 && AccuracyBenchmark.cer(reference: "一共二十五个人", hypothesis: "一共25个人") == 0)
        c("CER 一个字错误按字数计算", abs(AccuracyBenchmark.cer(reference: "一二三四", hypothesis: "一二三五") - 0.25) < 1e-9)
        c("CER 漏字与多字都计错", AccuracyBenchmark.cer(reference: "你好吗", hypothesis: "你好") > 0.3 && AccuracyBenchmark.cer(reference: "你好", hypothesis: "你好吗") == 0.5)
        c("CER 英文不区分大小写", AccuracyBenchmark.cer(reference: "打开 Chrome", hypothesis: "打开chrome") == 0)
        c("CER 空识别结果为 100%", AccuracyBenchmark.cer(reference: "好的", hypothesis: "") == 1)
        let noisy = AccuracyBenchmark.addNoise(quietClip, snrDB: 10, seed: 3)
        c("加噪后长度不变且在 ±1 内", noisy.count == quietClip.count && noisy.allSatisfy { abs($0) <= 1 } && noisy != quietClip && noisy == AccuracyBenchmark.addNoise(quietClip, snrDB: 10, seed: 3))

        // 缓存：当前版本加载失败 → 回滚到上一版再试
        let cache = LocalTranscriberCache()
        var attempts: [String] = []
        cache.loader = { dir, _, _ in attempts.append(dir.lastPathComponent); if dir.lastPathComponent.hasSuffix("1.1.0") { throw LocalModelError.loadFailed }; return FakeTranscriber("ok") }
        let loaded = try? cache.transcriber(for: e.id, center: center)
        c("新版加载失败时自动回滚到上一版并成功加载", loaded != nil && attempts == ["rec-model-1.1.0", "rec-model-1.0.0"] && center.installed[e.id]?.version == "1.0.0")
        let again = try? cache.transcriber(for: e.id, center: center)
        c("同一模型再次取用复用已加载实例", again === loaded && attempts.count == 2)
        cache.unload()
        c("卸载后释放", !cache.isLoaded)
        cache.loader = { _, _, _ in throw LocalModelError.loadFailed }
        c("没有上一版又加载失败 → 抛错", (try? cache.transcriber(for: e.id, center: center)) == nil)

        // 本地录音会话：喂入音频 → 结束 → 最终文本
        cache.loader = { _, _, _ in FakeTranscriber("你好世界") }
        let cap = FakeCapture()
        let rec = LocalASRRecorder(modelID: e.id, center: center, cache: cache, capture: cap)
        var result: String?? = nil
        rec.onFinal = { result = .some($0) }
        // 受测环境没有链接推理库时 begin 会如实拒绝；有库时走完整流程
        if LocalTranscriberLoader.supported {
            c("本地会话可开始", rec.begin())
            cap.feed(32000); rec.end()
            c("本地会话结束后交付识别文字", wait { result != nil } && result == .some("你好世界"))
        } else {
            c("无推理库时本地会话如实拒绝", !rec.begin() && rec.lastError == L10n.tr("local.err.unsupportedBuild"))
        }
        let noModel = LocalASRRecorder(modelID: "absent", center: center, cache: cache, capture: FakeCapture())
        c("模型未安装时本地会话拒绝并给出下载提示", !noModel.begin() && (noModel.lastError == L10n.tr("local.err.notInstalled") || noModel.lastError == L10n.tr("local.err.unsupportedBuild")))
    }

    // MARK: 配置兼容

    static func config(_ c: (String, Bool) -> Void) {
        let old = "{\"engine\":\"apple\"}".data(using: .utf8)!
        let decoded = try? JSONDecoder().decode(BridgeConfig.self, from: old)
        c("旧配置缺少 localModel 键时用默认值", decoded?.localModel == LocalModelSettings())
        var cfg = BridgeConfig.default(); cfg.engine = "local"; cfg.localModel.modelID = "m"; cfg.localModel.offlineDirect = false; cfg.localModel.manifestURL = "https://example.com/m.json"
        let round = try? JSONDecoder().decode(BridgeConfig.self, from: JSONEncoder().encode(cfg))
        c("本地模型设置往返保留", round?.localModel == cfg.localModel && round?.engine == "local")
        c("引擎 local 是有效配置", BridgeConfig.validate(cfg).isEmpty)
        c("回退默认开启、没网直连默认开启", LocalModelSettings().enabled && LocalModelSettings().offlineDirect)
        c("本地引擎的就绪判断需要推理库与已安装模型", EngineReadiness.ready(engine: "local", mic: true, speech: false, local: false, cloud: false, credentials: false, consent: false) == (LocalTranscriberLoader.supported && LocalModelCenter.shared.installedEntries.contains { LocalModelCatalog.usable($0) }))
        c("本地引擎不需要云端凭据和同意", ASREngine.local.credentialFields.isEmpty)
    }

    // MARK: 真实模型验证（--selftest-local-model-real）
    // 用户在应用里下载模型之后运行：用系统 `say` 合成语音，跑真实加载、识别、VAD 切段与本地录音会话。
    // 没有安装模型或没有链接推理库时跳过（返回 0），不下载任何东西。

    static func wavSamples(_ url: URL) -> [Float] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        var i = 12
        while i + 8 <= d.count {
            let id = String(decoding: d[i..<i+4], as: UTF8.self)
            let size = Int(d[i+4]) | Int(d[i+5]) << 8 | Int(d[i+6]) << 16 | Int(d[i+7]) << 24
            if id == "data" { return LocalDecoder.samples(fromPCM16: d.subdata(in: (i+8)..<min(d.count, i+8+size))) }
            i += 8 + size + (size & 1)
        }
        return []
    }

    static func synthesize(_ text: String, voice: String?) -> [Float]? {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("cadenza-say-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: out) }
        var args = ["-o", out.path, "--file-format=WAVE", "--data-format=LEI16@16000"]
        if let voice { args += ["-v", voice] }
        guard run("/usr/bin/say", args + [text]) else { return nil }
        let s = wavSamples(out); return s.isEmpty ? nil : s
    }

    /// Developer probe (`--local-accuracy-probe`): the same synthesized Mandarin sentences through different settings.
    /// Synthesized speech is cleaner than a microphone, so this isolates the effect of language, ITN and threads.
    static func accuracyProbe() -> Int32 {
        guard LocalTranscriberLoader.supported else { print("probe: no inference library in this build"); return 0 }
        let installed = LocalModelCatalog.builtin.compactMap { entry -> (LocalModelEntry, URL)? in
            guard let dir = LocalModelCenter.shared.modelDir(entry.id), FileManager.default.fileExists(atPath: dir.appendingPathComponent("tokens.txt").path) else { return nil }
            return (entry, dir)
        }
        guard !installed.isEmpty else { print("probe: no local model is installed"); return 0 }
        print("probe: installed models = \(installed.map { $0.0.id })")
        let voices = (CommandLine.arguments.first { $0.hasPrefix("--probe-voices=") }.map { String($0.dropFirst("--probe-voices=".count)).split(separator: ",").map(String.init) }) ?? ["Tingting"]
        let sentences = ["为什么还有本地模型这个选项？", "我想只用本地识别，不想用云端。", "今天下午三点开会，请提前十分钟到。", "这个应用的识别准确度有很大的问题。", "请把这个文件发给产品经理，谢谢。"]
        var senseVoiceZh = LocalRecognitionOptions(); senseVoiceZh.language = "zh"
        for voice in voices {
            for sentence in sentences {
                guard let audio = synthesize(sentence, voice: voice) else { print("probe: say failed for \(voice)"); continue }
                print("\(voice) | 原句: \(sentence)")
                for (entry, dir) in installed {
                    let options = entry.kind == "sensevoice" ? senseVoiceZh : LocalRecognitionOptions()
                    guard let t = try? LocalTranscriberLoader.load(dir: dir, entry: entry, options: options) else { print("   \(entry.id): load failed"); continue }
                    let start = ProcessInfo.processInfo.systemUptime
                    let text = LocalDecoder.transcribe(audio, with: t)
                    print("   \(entry.id): \(text)   [\(String(format: "%.0f", (ProcessInfo.processInfo.systemUptime - start) * 1000)) ms]")
                }
            }
        }
        return 0
    }

    /// `Cadenza --selftest-local-model-download=<id>`: downloads a built-in model with the app's own downloader into a temporary
    /// folder (the size is in the model list), checks and loads it, reads two synthesized sentences and deletes it again.
    static func realDownload(id: String) -> Int32 {
        guard LocalTranscriberLoader.supported else { print("[model-download] this build has no inference library"); return 2 }
        guard let entry = LocalModelCatalog.builtin.first(where: { $0.id == id && !LocalModelCatalog.isOCR($0) }) else {
            print("[model-download] unknown speech model \(id); built in: " + LocalModelCatalog.builtin.filter { !LocalModelCatalog.isOCR($0) }.map(\.id).joined(separator: ", ")); return 2
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let center = LocalModelCenter(root: root)
        center.validator = { dir, e in (try? LocalTranscriberLoader.load(dir: dir, entry: e)) != nil }
        // CADENZA_MODEL_IMPORT=<file>,<file>: use files that are already on disk (they still go through the same checks and
        // installation as a download) instead of downloading them again.
        if let list = ProcessInfo.processInfo.environment["CADENZA_MODEL_IMPORT"] {
            var imported: Result<LocalModelEntry, Error>?
            center.importFiles(list.split(separator: ",").map { URL(fileURLWithPath: String($0)) }) { imported = $0 }
            while imported == nil { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
            if case .failure(let error) = imported { print("[model-download] FAIL import: \(error)"); return 1 }
        } else { center.download(entry) }
        let started = Date()
        var last = -1, lastState = ""
        loop: while Date().timeIntervalSince(started) < 3600 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            let state = center.state(entry.id)
            let name = "\(state)".prefix(14); if String(name) != lastState, !"\(state)".hasPrefix("downloading") { lastState = String(name); print("[model-download] \(Int(Date().timeIntervalSince(started))) s: \(state)") }
            switch state {
            case .installed: break loop
            case .failed(let message): print("[model-download] FAIL download: \(message)"); return 1
            case .downloading(let done, let total): let p = Int(Double(done) / Double(max(total, 1)) * 100); if p / 25 != last / 25 { print("[model-download] downloading \(p)%"); last = p }
            default: break
            }
        }
        guard center.isReady(entry.id), let dir = center.modelDir(entry.id) else { print("[model-download] FAIL: not installed after \(Int(Date().timeIntervalSince(started))) s, state \(center.state(entry.id))"); return 1 }
        print("[model-download] installed in \(Int(Date().timeIntervalSince(started))) s")
        guard let t = try? LocalTranscriberLoader.load(dir: dir, entry: entry) else { print("[model-download] FAIL: installed but cannot be loaded"); return 1 }
        var failures = 0
        for (label, voice, text, expect) in [("zh", "Tingting", "今天天气很好，我们一起去公园散步。", "天气"), ("en", nil, "Hello world. This is a local speech recognition test.", "hello")] as [(String, String?, String, String)] {
            guard let clip = synthesize(text, voice: voice) else { print("[model-download] SKIP \(label): no system voice"); continue }
            let s = ProcessInfo.processInfo.systemUptime
            let out = LocalDecoder.transcribe(clip, with: t)
            let ok = out.lowercased().contains(expect)
            if !ok { failures += 1 }
            print("[model-download] \(ok ? "PASS" : "FAIL") \(label) \(Int((ProcessInfo.processInfo.systemUptime - s) * 1000)) ms: \(out)")
        }
        center.delete(entry.id)
        print("[model-download] deleted: \(center.state(entry.id) == .notInstalled)")
        return failures == 0 ? 0 : 1
    }

    static func realModel() -> Int32 {
        func line(_ ok: Bool?, _ name: String) { print("[local-model-real] \(ok == nil ? "SKIP" : ok! ? "PASS" : "FAIL"): \(name)") }
        guard LocalTranscriberLoader.supported else { line(nil, "当前构建不含推理库"); return 0 }
        let entry = LocalModelCatalog.builtin[0]
        let dir = ProcessInfo.processInfo.environment["CADENZA_LOCAL_MODEL_DIR"].map { URL(fileURLWithPath: $0) } ?? LocalModelCenter.shared.modelDir(entry.id)
        guard let dir, FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.int8.onnx").path) else { line(nil, "没有安装本地模型（先在设置 → 识别引擎 → 本地 下载，或用 CADENZA_LOCAL_MODEL_DIR 指定目录）"); return 0 }
        var failures = 0
        func check(_ name: String, _ ok: Bool) { line(ok, name); if !ok { failures += 1 } }
        let t0 = ProcessInfo.processInfo.systemUptime
        guard let t = try? LocalTranscriberLoader.load(dir: dir, entry: entry) else { check("模型可加载", false); return 1 }
        print("[local-model-real] load \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - t0))s dir=\(dir.lastPathComponent)")
        var clips: [[Float]] = []
        if let en = synthesize("Hello world. This is a local speech recognition test.", voice: nil) {
            let start = ProcessInfo.processInfo.systemUptime
            let text = LocalDecoder.transcribe(en, with: t)
            let dt = ProcessInfo.processInfo.systemUptime - start
            print("[local-model-real] en audio=\(String(format: "%.1f", Double(en.count) / 16000))s decode=\(String(format: "%.0f", dt * 1000))ms text=\(text)")
            check("英文识别含 hello", text.lowercased().contains("hello")); clips.append(en)
        } else { line(nil, "系统 say 不可用，跳过英文合成") }
        if let zh = synthesize("今天天气很好，我们一起去公园散步。", voice: "Tingting") {
            let text = LocalDecoder.transcribe(zh, with: t)
            print("[local-model-real] zh text=\(text)")
            check("中文识别含“天气”", text.contains("天气")); clips.append(zh)
        } else { line(nil, "没有普通话语音（Tingting），跳过中文合成") }
        if let zh = synthesize("今天下午三点开会，请提前十分钟到。", voice: "Tingting") {
            let realCompare = VoiceCompare(prompts: ["今天下午三点开会，请提前十分钟到。", "今天下午三点开会，请提前十分钟到。", "今天下午三点开会，请提前十分钟到。"], models: [entry], loader: { _ in { LocalDecoder.transcribe($0, with: t) } })
            realCompare.setClip(0, zh); realCompare.setClip(1, zh); realCompare.setClip(2, zh)
            realCompare.analyze()
            let end = Date().addingTimeInterval(60); while realCompare.analyzing && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            print("[local-model-real] compare error=\(String(format: "%.3f", realCompare.averageError(0) ?? -1)) text=\(realCompare.results.first?.first??.text ?? "")")
            check("真实模型：用我的声音比较能识别并打分（数字写法不算错）", (realCompare.averageError(0) ?? 1) < 0.1 && realCompare.results.count == 3)
        }
        if clips.count >= 2 {
            let silence = [Float](repeating: 0, count: 16000 * 3 / 2)
            let joined = clips.enumerated().flatMap { $0.offset == 0 ? $0.element : silence + $0.element }
            let segments = t.speechSegments(joined)
            print("[local-model-real] vad segments=\(segments.count) total=\(String(format: "%.1f", Double(joined.count) / 16000))s")
            check("VAD 能在停顿处切段", segments.count >= 2)
            check("切段后整体识别非空", !LocalDecoder.transcribe(joined + joined, with: t).isEmpty)   // 超过直接解码上限，走切段路径
        }
        if let en = clips.first {
            // 本地录音会话：按 100ms 一块喂入，结束后应得到最终文字；同时检查中途出现过预览
            let center = LocalModelCenter.shared
            let cache = LocalTranscriberCache(); cache.loader = { _, _, _ in t }
            let cap = FakeCapture(); var partials = 0; var final: String??
            let rec = LocalASRRecorder(modelID: entry.id, center: center, cache: cache, capture: cap)
            rec.onPartial = { _ in partials += 1 }; rec.onFinal = { final = .some($0) }
            if center.isReady(entry.id), rec.begin() {
                var i = 0
                while i < en.count {
                    let chunk = Array(en[i..<min(en.count, i + 1600)])
                    cap.onPCM?(Data(bytes: chunk.map { Int16(max(-1, min(1, $0)) * 32767) }, count: chunk.count * 2)); i += 1600
                    _ = wait(0.1) { false }
                }
                rec.end()
                check("本地录音会话交付最终文字", wait(20) { final != nil } && final! != nil && final!!.lowercased().contains("hello"))
                print("[local-model-real] session partials=\(partials) final=\(final.flatMap { $0 } ?? "nil")")
            } else { line(nil, "本地录音会话需要通过应用安装的模型（CADENZA_LOCAL_MODEL_DIR 模式跳过）") }
        }
        print("[local-model-real] done failures=\(failures)")
        return failures == 0 ? 0 : 1
    }
}
