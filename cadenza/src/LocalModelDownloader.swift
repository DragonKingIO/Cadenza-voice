import Foundation

// MARK: - 单文件断点续传下载
// 边下边写 .part 文件；失败/暂停后保留 .part，下次用 Range 从断点继续。
// 多个地址依次尝试（主地址在前，镜像在后），同一地址最多尝试 2 次。
// 所有状态只在内部串行队列访问；回调在该队列触发，调用方自行切线程。

final class ResumableDownloader: NSObject, URLSessionDataDelegate {
    private let file: LocalModelFile
    private let partURL: URL
    private let queue: DispatchQueue
    private let operations = OperationQueue()
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var urlIndex = 0, attempt = 0
    private var received: Int64 = 0
    private var expectingRange = false
    private var finished = false, stopping = false
    private var pending: Pending = .none
    private var lastError: Error = LocalModelError.network("unknown")
    private var progress: ((Int64) -> Void)?
    private var completion: ((Result<Void, Error>) -> Void)?
    private var lastReport: TimeInterval = 0
    private enum Pending { case none, retryFresh, nextAddress }

    init(file: LocalModelFile, partURL: URL, configuration: URLSessionConfiguration? = nil) {
        self.file = file; self.partURL = partURL
        queue = DispatchQueue(label: "cadenza.localmodel.download." + file.name)
        super.init()
        operations.maxConcurrentOperationCount = 1; operations.underlyingQueue = queue
        let c = configuration ?? {
            let c = URLSessionConfiguration.default
            c.timeoutIntervalForRequest = 30; c.requestCachePolicy = .reloadIgnoringLocalCacheData; c.httpCookieStorage = nil; c.urlCredentialStorage = nil
            return c
        }()
        session = URLSession(configuration: c, delegate: self, delegateQueue: operations)
    }

    func start(progress: @escaping (Int64) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            self.progress = progress; self.completion = completion
            if self.stopping { return }
            try? FileManager.default.createDirectory(at: self.partURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            self.attemptCurrent()
        }
    }

    /// 暂停/取消：保留 .part，完成回调以 .cancelled 结束
    /// `then` runs on the downloader's queue once it has stopped, so a caller can clean up after the last possible write.
    func stop(then done: (() -> Void)? = nil) {
        queue.async {
            defer { done?() }
            guard !self.finished else { return }
            self.stopping = true
            if let t = self.task { t.cancel() } else { self.finish(.failure(LocalModelError.cancelled)) }
        }
    }

    private func partSize() -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: partURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func attemptCurrent() {
        guard !finished else { return }
        var size = partSize()
        if size > file.size { try? FileManager.default.removeItem(at: partURL); size = 0 }
        received = size
        if size == file.size { finish(.success(())); return }
        guard urlIndex < file.urls.count, let url = URL(string: file.urls[urlIndex]) else { finish(.failure(lastError)); return }
        var request = URLRequest(url: url)
        if size > 0 { request.setValue("bytes=\(size)-", forHTTPHeaderField: "Range") }
        expectingRange = size > 0; pending = .none
        try? handle?.close(); handle = nil
        task = session.dataTask(with: request); task?.resume()
    }

    private func openHandle(truncate: Bool) -> Bool {
        if truncate || !FileManager.default.fileExists(atPath: partURL.path) {
            guard FileManager.default.createFile(atPath: partURL.path, contents: nil) else { return false }
            received = 0
        }
        guard let h = try? FileHandle(forWritingTo: partURL) else { return false }
        do { try h.seekToEnd() } catch { try? h.close(); return false }
        handle = h; return true
    }

    static func validRange(_ value:String?,offset:Int64,total:Int64)->Bool {
        guard let value,value.hasPrefix("bytes ") else{return false}
        let parts=value.dropFirst(6).split(separator:"/"), span=parts.first?.split(separator:"-") ?? []
        guard parts.count==2,span.count==2,let lower=Int64(span[0]),let upper=Int64(span[1]),let length=Int64(parts[1]) else{return false}
        return lower==offset && upper>=lower && upper<length && length==total
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if stopping { completionHandler(.cancel); return }   // never create the .part file after a stop
        guard let http = response as? HTTPURLResponse else { lastError = LocalModelError.network("response"); pending = .nextAddress; completionHandler(.cancel); return }
        switch http.statusCode {
        case 206 where expectingRange:
            guard Self.validRange(http.value(forHTTPHeaderField:"Content-Range"),offset:received,total:file.size) else{lastError=LocalModelError.sizeMismatch(file.name);pending = .nextAddress;completionHandler(.cancel);return}
            if openHandle(truncate: false) { completionHandler(.allow) } else { lastError = LocalModelError.network("disk"); pending = .nextAddress; completionHandler(.cancel) }
        case 200:
            // 服务器没有按 Range 响应（或首次下载）：从头写
            if openHandle(truncate: true) { completionHandler(.allow) } else { lastError = LocalModelError.network("disk"); pending = .nextAddress; completionHandler(.cancel) }
        case 416:
            try? FileManager.default.removeItem(at: partURL); pending = expectingRange ? .retryFresh:.nextAddress; completionHandler(.cancel)
        default:
            lastError = LocalModelError.http(http.statusCode); pending = .nextAddress; completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let h = handle else { return }
        do { try h.write(contentsOf: data) } catch { lastError = LocalModelError.network("disk"); pending = .nextAddress; dataTask.cancel(); return }
        received += Int64(data.count)
        if received > file.size { lastError = LocalModelError.sizeMismatch(file.name); try? FileManager.default.removeItem(at: partURL); pending = .nextAddress; dataTask.cancel(); return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastReport >= 0.1 { lastReport = now; progress?(received) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        try? handle?.close(); handle = nil; self.task = nil
        if stopping { finish(.failure(LocalModelError.cancelled)); return }
        switch pending {
        case .retryFresh: attemptCurrent(); return
        case .nextAddress: advance(); return
        case .none: break
        }
        if let error { lastError = LocalModelError.network((error as NSError).localizedDescription); advance(); return }
        progress?(received)
        if received == file.size { finish(.success(())) }
        else { lastError = LocalModelError.network("incomplete"); advance() }
    }

    private func advance() {
        attempt += 1
        if attempt % 2 == 0 { urlIndex += 1 }
        guard urlIndex < file.urls.count else { finish(.failure(lastError)); return }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.finished else { return }
            if self.stopping { self.finish(.failure(LocalModelError.cancelled)) } else { self.attemptCurrent() }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        try? handle?.close(); handle = nil
        let c = completion; completion = nil; progress = nil
        session.invalidateAndCancel()
        c?(result)
    }
}

// MARK: - 压缩包解压（系统 tar，解压前检查路径与链接）

enum ArchiveExtractor {
    @discardableResult
    private static func tar(_ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); p.arguments = args
        let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err
        try p.run()
        // 先读输出再等待退出，避免管道写满死锁
        let data = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw LocalModelError.extractFailed(String(decoding: e.prefix(300), as: UTF8.self)) }
        return String(decoding: data, as: UTF8.self)
    }

    /// 只允许普通文件与目录；拒绝绝对路径、.. 路径、符号链接与硬链接
    static func validateEntries(_ archive: URL) throws {
        let names = try tar(["-tf", archive.path]).split(separator: "\n").map(String.init)
        for n in names where n.hasPrefix("/") || n.split(separator: "/").contains("..") { throw LocalModelError.unsafeArchive(n) }
        let verbose = try tar(["-tvf", archive.path]).split(separator: "\n")
        for line in verbose { if let c = line.first, c != "-", c != "d" { throw LocalModelError.unsafeArchive(String(line.prefix(80))) } }
    }

    /// 解压到 destination，并去掉唯一的最外层目录
    static func extract(_ archive: URL, into destination: URL) throws {
        let fm = FileManager.default
        try validateEntries(archive)
        let scratch = destination.deletingLastPathComponent().appendingPathComponent(".extract-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        try tar(["-xf", archive.path, "-C", scratch.path, "--no-same-owner"])
        var root = scratch
        let top = try fm.contentsOfDirectory(at: scratch, includingPropertiesForKeys: [.isDirectoryKey])
        if top.count == 1, (try? top[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { root = top[0] }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try fm.moveItem(at: item, to: destination.appendingPathComponent(item.lastPathComponent))
        }
    }
}
