import Foundation
import Observation

// MARK: - 本地模型管理：下载 → 校验 → 解压 → 自检 → 原子激活；删除、回滚、导入、检查更新

enum LocalModelState: Equatable {
    case notInstalled
    case downloading(done: Int64, total: Int64)
    case paused(done: Int64, total: Int64)
    case verifying
    case installing
    case installed(version: String)
    case failed(String)
}

struct LocalModelInstalled: Codable, Equatable {
    var version: String
    var previous: String?
    var installedAt: Date
}

@Observable
final class LocalModelCenter {
    static let shared = LocalModelCenter()

    private(set) var entries: [LocalModelEntry] = LocalModelCatalog.builtin
    private(set) var installed: [String: LocalModelInstalled] = [:]
    private(set) var active: [String: LocalModelState] = [:]      // 下载中/暂停/失败等临时状态
    private(set) var updates: [String: LocalModelEntry] = [:]
    private(set) var lastCheck: Date?
    private(set) var checkMessage = ""
    private(set) var checking = false

    /// 已安装集合或其可用性变化（UI、配置、管线据此刷新）
    @ObservationIgnored var onChange: (() -> Void)?
    /// 激活前的加载自检；返回 false 则丢弃新版本，现行版本不受影响
    @ObservationIgnored var validator: ((URL, LocalModelEntry) -> Bool)?

    @ObservationIgnored let root: URL
    @ObservationIgnored private let work = DispatchQueue(label: "cadenza.localmodel.work", qos: .userInitiated)
    @ObservationIgnored private var jobs: [String: Job] = [:]
    @ObservationIgnored private var remote: [LocalModelEntry] = []
    @ObservationIgnored private let configuration: URLSessionConfiguration?
    @ObservationIgnored private var injected: [LocalModelEntry] = []   // 仅自检使用：绕过 https 校验的测试条目

    private final class Job {
        let entry: LocalModelEntry
        var index = 0, completed: Int64 = 0, current: Int64 = 0
        var downloader: ResumableDownloader?
        var paused = false, cancelled = false
        init(_ e: LocalModelEntry) { entry = e }
        var total: Int64 { entry.files.reduce(0) { $0 + $1.size } }
    }

    init(root: URL = AppPaths.supportDir.appendingPathComponent("models", isDirectory: true), configuration: URLSessionConfiguration? = nil) {
        self.root = root; self.configuration = configuration
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    // MARK: 路径

    private var recordURL: URL { root.appendingPathComponent("installed.json") }
    private var remoteCacheURL: URL { root.appendingPathComponent("remote-manifest.json") }
    private func versionDir(_ id: String, _ version: String) -> URL { root.appendingPathComponent("\(id)-\(version)", isDirectory: true) }
    private func staging(_ e: LocalModelEntry) -> URL { root.appendingPathComponent(".downloads/\(e.id)-\(e.version)", isDirectory: true) }

    func entry(_ id: String) -> LocalModelEntry? { entries.first { $0.id == id } }
    func modelDir(_ id: String) -> URL? {
        guard let rec = installed[id] else { return nil }
        let dir = versionDir(id, rec.version)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }
    /// 已安装且文件完整的模型条目（条目取清单中对应版本，找不到则取当前清单条目）
    var installedEntries: [LocalModelEntry] { entries.compactMap { e in guard installed[e.id] != nil, isComplete(e) else{return nil};return installedEntry(e.id) } }
    func installedEntry(_ id:String)->LocalModelEntry? {
        guard let dir=modelDir(id) else{return nil}
        if let data=try? Data(contentsOf:dir.appendingPathComponent(".cadenza-model-entry.json")),let e=try? JSONDecoder().decode(LocalModelEntry.self,from:data),e.id==id,e.version==installed[id]?.version,LocalModelCatalog.validate(e)==nil {return e}
        return entry(id)
    }
    func isReady(_ id: String) -> Bool { entry(id).map { installed[id] != nil && isComplete($0) } ?? false }

    private func isComplete(_ e: LocalModelEntry) -> Bool {
        guard let dir = modelDir(e.id) else { return false }
        return (installedEntry(e.id) ?? e).requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    /// 仅预览/自检：覆盖显示状态，不触碰磁盘与网络
    @ObservationIgnored var previewStates: [String: LocalModelState]?

    func state(_ id: String) -> LocalModelState {
        if let s = previewStates?[id] { return s }
        if let s = active[id] { return s }
        if let rec = installed[id], isReady(id) { return .installed(version: rec.version) }
        return .notInstalled
    }

    // MARK: 启动加载

    func reload() {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: recordURL), let rec = try? JSONDecoder().decode([String: LocalModelInstalled].self, from: data) { installed = rec } else { installed = [:] }
        if let data = try? Data(contentsOf: remoteCacheURL), let m = try? LocalModelCatalog.decode(data) { remote = m.models }
        rebuildEntries()
        // 清掉上次异常退出留下的半成品目录；保留可续传的下载暂存
        for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where item.lastPathComponent.hasSuffix(".tmp") || item.lastPathComponent.hasPrefix(".extract-") {
            try? fm.removeItem(at: item)
        }
        // 暂存里有数据的模型显示为“已暂停”，用户点继续即可
        for e in entries where installed[e.id]?.version != e.version || installed[e.id] == nil {
            let dir = staging(e)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path), !names.isEmpty else { continue }
            let done = names.reduce(Int64(0)) { $0 + (((try? fm.attributesOfItem(atPath: dir.appendingPathComponent($1).path))?[.size] as? NSNumber)?.int64Value ?? 0) }
            active[e.id] = .paused(done: done, total: e.files.reduce(0) { $0 + $1.size })
        }
        recomputeUpdates()
    }

    private func rebuildEntries() {
        entries = LocalModelCatalog.merge(builtin: LocalModelCatalog.builtin, remote: remote)
        for e in injected { if let i = entries.firstIndex(where: { $0.id == e.id }) { entries[i] = e } else { entries.append(e) } }
    }

    // 自检专用
    func testInject(_ e: LocalModelEntry) { injected.removeAll { $0.id == e.id }; injected.append(e); rebuildEntries() }
    func testStaging(_ e: LocalModelEntry) -> URL { staging(e) }
    func testSetInstalled(_ id: String, _ rec: LocalModelInstalled) { installed[id] = rec; saveRecord() }

    @discardableResult private func saveRecord()->Bool {
        do {try JSONEncoder().encode(installed).write(to:recordURL,options:.atomic);return true}
        catch {return false}
    }

    private func recomputeUpdates() {
        var u: [String: LocalModelEntry] = [:]
        for e in entries { if let rec = installed[e.id], LocalModelVersion.isNewer(e.version, than: rec.version), LocalModelCatalog.downloadable(e) { u[e.id] = e } }
        updates = u
    }

    private func publish() { recomputeUpdates(); onChange?() }

    // MARK: 下载

    func download(_ entry: LocalModelEntry) {
        guard jobs[entry.id] == nil else { return }
        guard LocalModelCatalog.downloadable(entry) else { active[entry.id] = .failed(LocalModelError.unsupported.localizedDescription); return }
        let need = entry.downloadSize + entry.installedSize
        let free = Self.freeBytes(at: root)
        guard free >= need + need / 10 else { active[entry.id] = .failed(LocalModelError.insufficientDisk(need: need, free: free).localizedDescription); return }
        let job = Job(entry); jobs[entry.id] = job
        active[entry.id] = .downloading(done: 0, total: job.total)
        startFile(job)
    }

    private func startFile(_ job: Job) {
        guard !job.cancelled else { return }
        let e = job.entry
        guard job.index < e.files.count else { finalize(job); return }
        let f = e.files[job.index], dir = staging(e), done = dir.appendingPathComponent(f.name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: done.path) {
            // 之前已下载完成的文件（含用户导入）：重新校验后跳过
            active[e.id] = .verifying
            work.async { [weak self] in
                let ok = (try? done.resourceValues(forKeys:[.fileSizeKey]).fileSize).map{Int64($0)==f.size} == true && (try? Hashing.sha256(of: done)) == f.sha256.lowercased()
                DispatchQueue.main.async {
                    guard let self, self.jobs[e.id] === job, !job.cancelled else { return }
                    if ok { job.completed += f.size; job.index += 1; self.startFile(job) }
                    else { try? FileManager.default.removeItem(at: done); self.startFile(job) }
                }
            }
            return
        }
        job.current = 0
        publishProgress(job)
        let dl = ResumableDownloader(file: f, partURL: dir.appendingPathComponent(f.name + ".part"), configuration: configuration)
        job.downloader = dl
        dl.start(progress: { [weak self] bytes in
            DispatchQueue.main.async { guard let self, self.jobs[e.id] === job, !job.cancelled, !job.paused else { return }; job.current = bytes; self.publishProgress(job) }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.jobs[e.id] === job, !job.cancelled else { return }
                job.downloader = nil
                switch result {
                case .success:
                    self.active[e.id] = .verifying
                    self.work.async {
                        let part = dir.appendingPathComponent(f.name + ".part")
                        var error: LocalModelError?
                        if (try? Hashing.sha256(of: part)) != f.sha256.lowercased() { error = .checksumMismatch(f.name); try? FileManager.default.removeItem(at: part) }
                        else { try? FileManager.default.moveItem(at: part, to: done) }
                        DispatchQueue.main.async {
                            guard self.jobs[e.id] === job, !job.cancelled else { return }
                            if let error { self.fail(job, error) } else { job.completed += f.size; job.current = 0; job.index += 1; self.startFile(job) }
                        }
                    }
                case .failure(let error):
                    if (error as? LocalModelError) == .cancelled {
                        if job.paused { self.active[e.id] = .paused(done: job.completed + job.current, total: job.total) } else {self.startFile(job)}
                    } else { self.fail(job, error) }
                }
            }
        })
    }

    private func publishProgress(_ job: Job) { active[job.entry.id] = .downloading(done: min(job.total, job.completed + job.current), total: job.total) }

    private func fail(_ job: Job, _ error: Error) {
        jobs[job.entry.id] = nil
        active[job.entry.id] = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        publish()
    }

    func pause(_ id: String) {
        guard let job = jobs[id], !job.paused else { return }
        job.paused = true
        if let d = job.downloader { d.stop() } else { active[id] = .paused(done: job.completed + job.current, total: job.total) }
    }

    func resume(_ id: String) {
        if let job = jobs[id], job.paused { job.paused = false; active[id] = .downloading(done: job.completed + job.current, total: job.total); if job.downloader == nil {startFile(job)}; return }
        // 重启后的“已暂停”：没有 Job，重新开始，已有 .part 与已完成文件会被复用
        if jobs[id] == nil, let e = (updates[id] ?? entry(id)) { active[id] = nil; download(e) }
    }

    func cancel(_ id: String) {
        let staged = entry(id).map { staging($0) }
        if let job = jobs[id] {
            job.cancelled = true; jobs[id] = nil
            // The downloader creates its folder on its own queue, which can happen after the removal below; clean up again once it has stopped.
            job.downloader?.stop { if let staged { try? FileManager.default.removeItem(at: staged) } }
        }
        if let staged { try? FileManager.default.removeItem(at: staged) }
        active[id] = nil
        publish()
    }

    // MARK: 安装（解压、检查、自检、原子激活）

    private func finalize(_ job: Job) {
        let e = job.entry
        active[e.id] = .installing
        let source = staging(e), tmp = root.appendingPathComponent("\(e.id)-\(e.version).tmp", isDirectory: true), final = versionDir(e.id, e.version)
        let validator = self.validator
        work.async { [weak self] in
            let fm = FileManager.default
            var failure: Error?
            do {
                try? fm.removeItem(at: tmp)
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                for f in e.files {
                    let src = source.appendingPathComponent(f.name)
                    if f.extract { try ArchiveExtractor.extract(src, into: tmp) } else { try fm.copyItem(at: src, to: tmp.appendingPathComponent(f.name)) }
                }
                for r in e.requiredFiles {
                    let p = tmp.appendingPathComponent(r)
                    guard let size = (try? fm.attributesOfItem(atPath: p.path))?[.size] as? NSNumber, size.int64Value > 0 else { throw LocalModelError.incomplete(r) }
                }
                if let validator, !validator(tmp, e) { throw LocalModelError.loadFailed }
                try JSONEncoder().encode(e).write(to:tmp.appendingPathComponent(".cadenza-model-entry.json"),options:.atomic)
            } catch { failure = error }
            DispatchQueue.main.async {
                guard let self, self.jobs[e.id] === job, !job.cancelled else { try? fm.removeItem(at: tmp); return }
                if let failure { try? fm.removeItem(at: tmp); self.fail(job, failure); return }
                self.activate(job, tmp: tmp, final: final)
            }
        }
    }

    /// 原子激活：同版本重装先挪开旧目录；记录用原子写入；成功后只保留当前版与上一版
    private func activate(_ job: Job, tmp: URL, final: URL) {
        let e = job.entry, fm = FileManager.default
        let aside = final.appendingPathExtension("old")
        try? fm.removeItem(at: aside)
        let hadFinal = fm.fileExists(atPath: final.path)
        do {
            if hadFinal { try fm.moveItem(at: final, to: aside) }
            do { try fm.moveItem(at: tmp, to: final) } catch { if hadFinal { try? fm.moveItem(at: aside, to: final) }; throw error }
        } catch { try? fm.removeItem(at: tmp); fail(job, LocalModelError.extractFailed(error.localizedDescription)); return }
        let old = installed[e.id]
        installed[e.id] = LocalModelInstalled(version: e.version, previous: old.flatMap { $0.version != e.version ? $0.version : $0.previous }, installedAt: Date())
        guard saveRecord() else {
            installed[e.id]=old
            try? fm.removeItem(at:final)
            if hadFinal {try? fm.moveItem(at:aside,to:final)}
            fail(job,LocalModelError.extractFailed(L10n.tr("ui.bcd8e5694934")));return
        }
        try? fm.removeItem(at:aside)
        try? fm.removeItem(at: staging(e))
        prune(e.id)
        jobs[e.id] = nil; active[e.id] = nil
        publish()
    }

    private func prune(_ id: String) {
        guard let rec = installed[id] else { return }
        var keep: Set<String> = ["\(id)-\(rec.version)"]
        if let p = rec.previous { keep.insert("\(id)-\(p)") }
        for item in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let n = item.lastPathComponent
            if n.hasPrefix(id + "-"), !n.hasSuffix(".tmp"), !keep.contains(n) { try? FileManager.default.removeItem(at: item) }
        }
    }

    // MARK: 删除 / 回滚 / 导入

    func delete(_ id: String) {
        guard jobs[id] == nil else { return }
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where item.lastPathComponent.hasPrefix(id + "-") { try? fm.removeItem(at: item) }
        installed[id] = nil; active[id] = nil
        saveRecord()
        publish()
    }

    /// 当前版本无法加载时回到上一版；没有上一版则返回 false
    @discardableResult
    func rollback(_ id: String) -> Bool {
        guard var rec = installed[id], let prev = rec.previous, FileManager.default.fileExists(atPath: versionDir(id, prev).path) else { return false }
        let bad = rec.version
        rec = LocalModelInstalled(version: prev, previous: nil, installedAt: Date())
        installed[id] = rec; saveRecord()
        try? FileManager.default.removeItem(at: versionDir(id, bad))
        Log.write("local-model rollback id=\(id) from=\(bad) to=\(prev)")
        publish()
        return true
    }

    func clearFailure(_ id: String) { if case .failed = active[id] { active[id] = nil } }

    /// 导入用户自己下载的文件（可一次选多个，例如模型包和 VAD）。
    /// 每个文件都必须与清单中某个条目的某个文件 SHA-256 完全一致，否则拒绝；通过后放入下载暂存，走与在线下载完全相同的校验与安装流程。
    func importFiles(_ urls: [URL], completion: @escaping (Result<LocalModelEntry, Error>) -> Void) {
        work.async { [weak self] in
            guard let self else { return }
            do {
                var target: LocalModelEntry?
                for url in urls {
                    let hash = try Hashing.sha256(of: url)
                    guard let hit = self.entries.first(where: { $0.files.contains { $0.sha256.lowercased() == hash } }),
                          let f = hit.files.first(where: { $0.sha256.lowercased() == hash }) else { throw LocalModelError.checksumMismatch(url.lastPathComponent) }
                    if let t = target, t.id != hit.id { throw LocalModelError.checksumMismatch(url.lastPathComponent) }
                    target = hit
                    let dir = self.staging(hit)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let dest = dir.appendingPathComponent(f.name)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: url, to: dest)
                }
                guard let hit = target else { throw LocalModelError.checksumMismatch("") }
                DispatchQueue.main.async { completion(.success(hit)); self.download(hit) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }

    func importFile(_ url: URL, completion: @escaping (Result<LocalModelEntry, Error>) -> Void) { importFiles([url], completion: completion) }

    // MARK: 检查更新（只下载小清单，不下载模型）

    func checkForUpdates(manifestURLs: [String], completion: (() -> Void)? = nil) {
        guard !checking else { return }
        let urls = manifestURLs.filter { URL(string: $0)?.scheme == "https" }
        guard !urls.isEmpty else { checkMessage = L10n.tr("local.update.noSource"); completion?(); return }
        checking = true; checkMessage = ""
        Task { [weak self] in
            let result = await Self.loadManifest(urls)
            await MainActor.run {
                guard let self else { return }
                self.checking = false; self.lastCheck = Date()
                if let manifest = result.manifest, let raw = result.raw {
                    self.remote = manifest.models; try? raw.write(to: self.remoteCacheURL, options: .atomic)
                    self.rebuildEntries()
                    self.publish()
                    self.checkMessage = self.updates.isEmpty ? L10n.tr("local.update.none") : L10n.format("local.update.found", self.updates.count)
                } else { self.checkMessage = L10n.format("local.update.failed", result.error) }
                completion?()
            }
        }
    }

    /// 依次尝试每个清单地址；配置了公钥时必须通过签名校验
    private static func loadManifest(_ urls: [String]) async -> (manifest: LocalModelManifest?, raw: Data?, error: String) {
        var lastError = ""
        for u in urls {
            guard let url = URL(string: u) else { continue }
            do {
                let data = try await fetch(url)
                var signature: String?
                if !LocalModelCatalog.manifestPublicKeys.isEmpty, let sigURL = URL(string: u + ".sig") {
                    signature = (try? await fetch(sigURL)).flatMap { String(data: $0, encoding: .utf8) }
                }
                guard LocalModelCatalog.verifySignature(manifest: data, signatureBase64: signature) else { throw LocalModelError.signatureInvalid }
                return (try LocalModelCatalog.decode(data), data, "")
            } catch { lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
        return (nil, nil, lastError)
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url); req.timeoutInterval = 15; req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 1_048_576 else { throw LocalModelError.network("manifest") }
        return data
    }

    static func freeBytes(at url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
    }
}
