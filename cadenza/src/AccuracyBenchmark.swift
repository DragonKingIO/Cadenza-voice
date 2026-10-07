import Foundation

/// Repeatable recognition accuracy measurement (`--accuracy-benchmark`). The same sentences are spoken by several system
/// voices under several conditions (clean, quiet microphone, noise, fast speech) and every engine is scored with the
/// character error rate. Synthesized speech is cleaner and more regular than a person, so absolute numbers are optimistic;
/// the value is in comparing settings and engines on identical audio, and in catching regressions.
enum AccuracyBenchmark {
    struct Item { let category: String; let text: String }

    static let corpus: [Item] = [
        Item(category: "short", text: "好的，我马上处理。"), Item(category: "short", text: "今天天气不错。"), Item(category: "short", text: "请稍等一下。"),
        Item(category: "daily", text: "我们明天上午十点在会议室开会。"), Item(category: "daily", text: "麻烦把文件发到我的邮箱。"), Item(category: "daily", text: "这个功能什么时候能上线？"),
        Item(category: "daily", text: "我已经把报告改好了，你再看一遍。"), Item(category: "daily", text: "晚上我们一起去吃火锅怎么样？"),
        Item(category: "numbers", text: "今天下午三点开会，请提前十分钟到。"), Item(category: "numbers", text: "这个月一共花了五千三百块。"), Item(category: "numbers", text: "一共有二十五个人参加。"),
        Item(category: "tech", text: "为什么还有本地模型这个选项？"), Item(category: "tech", text: "我想只用本地识别，不想用云端。"), Item(category: "tech", text: "这个应用的识别准确度有很大的问题。"),
        Item(category: "tech", text: "请打开设置里的识别引擎页面。"), Item(category: "tech", text: "快捷键冲突的时候需要重新设置。"), Item(category: "tech", text: "按住说话松开以后文字会自动输入。"),
        Item(category: "mixed", text: "帮我打开 Chrome 浏览器。"), Item(category: "mixed", text: "把这段代码提交到 GitHub 上。"), Item(category: "mixed", text: "这个 API 的返回结果不对。"),
        Item(category: "long", text: "我觉得我们应该先把核心功能做稳定，再考虑增加翻译和智能整理这些扩展功能。"),
        Item(category: "long", text: "如果网络不好的时候，软件应该自动改用本地模型继续识别，而不是让用户重新说一遍。"),
        Item(category: "spoken", text: "那个，我想问一下，这个东西到底怎么用啊？"), Item(category: "spoken", text: "嗯，我觉得这样应该可以吧。"),
        Item(category: "names", text: "明天我要去北京见李明和王芳。"), Item(category: "names", text: "张老师说下周一交作业。"),
        Item(category: "question", text: "你知道最近的地铁站在哪里吗？"), Item(category: "question", text: "为什么识别出来的字总是不对？"),
        Item(category: "privacy", text: "我的录音只在这台电脑上处理，不会上传。"), Item(category: "privacy", text: "请不要把我的语音发给任何服务器。"),
    ]

    enum Condition: String, CaseIterable {
        case clean, quiet, noise20, noise10, fast, tail, quietnoise
        var rate: Int? { self == .fast ? 260 : nil }
        /// Applies the acoustic condition to samples at 16 kHz.
        func apply(_ samples: [Float], seed: UInt64) -> [Float] {
            switch self {
            case .clean, .fast: return samples
            case .quiet: return samples.map { $0 * 0.05 }
            case .noise20: return addNoise(samples, snrDB: 20, seed: seed)
            case .noise10: return addNoise(samples, snrDB: 10, seed: seed)
            case .quietnoise: return addNoise(samples, snrDB: 15, seed: seed).map { $0 * 0.08 }
            case .tail: // speech, then a second of room noise with no speech
                let room = addNoise([Float](repeating: 0.02, count: 24000), snrDB: 0, seed: seed ^ 7).map { $0 * 0.5 }
                return samples + room
            }
        }
    }

    static func addNoise(_ samples: [Float], snrDB: Float, seed: UInt64) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let power = samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
        let sigma = (power / pow(10, snrDB / 10)).squareRoot()
        var state = seed | 1
        func next() -> Float { // xorshift, uniform in [-1, 1)
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(Double(state % 2_000_001) / 1_000_000 - 1)
        }
        return samples.map { s in
            let gaussian = (next() + next() + next() + next()) * 0.866 // approx. unit variance
            return max(-1, min(1, s + gaussian * sigma))
        }
    }

    // MARK: Scoring

    static func chineseNumber(_ n: Int) -> String {
        let digits = Array("零一二三四五六七八九")
        if n < 10 { return String(digits[n]) }
        if n < 20 { return "十" + (n % 10 == 0 ? "" : String(digits[n % 10])) }
        if n < 100 { return String(digits[n / 10]) + "十" + (n % 10 == 0 ? "" : String(digits[n % 10])) }
        if n < 1000 { let r = n % 100; return String(digits[n / 100]) + "百" + (r == 0 ? "" : (r < 10 ? "零" : "") + chineseNumber(r)) }
        if n < 10_000 { let r = n % 1000; return String(digits[n / 1000]) + "千" + (r == 0 ? "" : (r < 100 ? "零" : "") + chineseNumber(r)) }
        return String(n).map { String(digits[Int(String($0))!]) }.joined()
    }

    /// Lower-cases, drops punctuation and spaces, and reads Arabic numerals as Chinese numerals so "3点" equals "三点".
    static func normalize(_ text: String) -> [Character] {
        var out: [Character] = [], run = ""
        func flush() {
            guard !run.isEmpty else { return }
            if let n = Int(run), run.first != "0" || run == "0" { out.append(contentsOf: chineseNumber(n)) }
            else { out.append(contentsOf: run.map { Array("零一二三四五六七八九")[Int(String($0))!] }) }
            run = ""
        }
        for ch in text.lowercased() {
            if ch.isASCII && ch.isNumber { run.append(ch); continue }
            flush()
            if ch.isLetter || ch.isNumber { out.append(ch) }
        }
        flush()
        return out
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count { current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
            previous = current
        }
        return previous[b.count]
    }

    /// Character error rate against the reference, after normalization. 0 is perfect; can exceed 1.
    static func cer(reference: String, hypothesis: String) -> Double {
        let r = normalize(reference), h = normalize(hypothesis)
        return r.isEmpty ? 0 : Double(editDistance(r, h)) / Double(r.count)
    }

    // MARK: Audio

    /// Synthesized speech is cached on disk (`--bench-cache=<dir>`) so repeated runs only pay for recognition, and each
    /// `say` call has a timeout because the system synthesizer occasionally stalls when many run at once.
    static func speech(_ text: String, voice: String, rate: Int?) -> [Float]? {
        let cacheDir = value("--bench-cache").map { URL(fileURLWithPath: $0) }
        var name = ""
        if let cacheDir {
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            name = "\(abs("\(voice)|\(rate ?? 0)|\(text)".hashValue)).wav"
            let cached = LocalModelFixtures.wavSamples(cacheDir.appendingPathComponent(name))
            if !cached.isEmpty { return cached }
        }
        for _ in 0..<3 {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: out) }
            var args = ["-v", voice, "-o", out.path, "--file-format=WAVE", "--data-format=LEI16@16000"]
            if let rate { args += ["-r", String(rate)] }
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say"); p.arguments = args + [text]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let deadline = Date().addingTimeInterval(20)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if p.isRunning { p.terminate(); continue }
            let samples = LocalModelFixtures.wavSamples(out)
            if p.terminationStatus == 0, !samples.isEmpty {
                if let cacheDir { try? FileManager.default.copyItem(at: out, to: cacheDir.appendingPathComponent(name)) }
                return samples
            }
        }
        return nil
    }

    // MARK: Engines

    /// `make` builds an independent recognizer, so several can run at once (a recognizer is not safe to share between threads).
    struct Engine { let name: String; let parallel: Bool; let make: () -> (([Float]) -> String) }

    static func value(_ name: String) -> String? { CommandLine.arguments.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) } }

    static func localEngines() -> [Engine] {
        guard LocalTranscriberLoader.supported else { return [] }
        var engines: [Engine] = []
        var candidates: [(entry: LocalModelEntry, dir: URL)] = LocalModelCenter.shared.installedEntries.compactMap { e in LocalModelCenter.shared.modelDir(e.id).map { (e, $0) } }
        // Models that are not installed in the app can be compared too: `--bench-model=<kind>:<folder>` (repeatable), e.g.
        // `--bench-model=paraformer:/path/to/folder`. The folder holds the files the kind needs, as in the model list.
        for argument in CommandLine.arguments where argument.hasPrefix("--bench-model=") {
            let parts = argument.dropFirst("--bench-model=".count).split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, LocalModelCatalog.supportedKinds.contains(parts[0]) else { print("[bench] ignored \(argument): expected --bench-model=<kind>:<folder>"); continue }
            let entry = LocalModelEntry(id: "extra-" + parts[0], version: "0", displayName: [:], summary: [:], kind: parts[0], languages: [], downloadSize: 1, installedSize: 1, minAppVersion: "1.0.0", license: "", changelog: "", files: [], requiredFiles: [])
            candidates.append((entry, URL(fileURLWithPath: parts[1])))
        }
        for (entry, dir) in candidates {
            var variants: [(String, LocalRecognitionOptions)] = [("", LocalRecognitionOptions())]
            if entry.kind == "sensevoice" { var zh = LocalRecognitionOptions(); zh.language = "zh"; variants = [("auto", LocalRecognitionOptions()), ("zh", zh)] }
            if let t = value("--bench-vad").flatMap(Float.init) { variants = variants.map { var o = $0.1; o.vadThreshold = t; return ($0.0, o) } }
            if let n = value("--bench-threads").flatMap(Int.init) { variants = variants.map { var o = $0.1; o.threads = n; return ($0.0, o) } }
            for (suffix, options) in variants {
                guard (try? LocalTranscriberLoader.load(dir: dir, entry: entry, options: options)) != nil else { continue }
                let base = entry.id + (suffix.isEmpty ? "" : "/" + suffix)
                engines.append(Engine(name: base, parallel: true, make: {
                    let t = try? LocalTranscriberLoader.load(dir: dir, entry: entry, options: options)
                    return { samples in t.map { LocalDecoder.transcribe(samples, with: $0) } ?? "" }
                }))
            }
        }
        return engines
    }

    /// A real cloud provider through the app's own recorder, fed from memory. Uses the saved credentials and consent.
    static func cloudEngine(_ provider: ASREngine) -> Engine? {
        let config = ConfigStore(fileURL: AppPaths.configFile).config
        guard config.options(provider).consent, let credentials = provider.credentials() else { return nil }
        let language = IflytekRecorder.resolveLanguage(config.iflytekLanguage, forSourceID: nil)
        return Engine(name: provider.rawValue, parallel: false, make: { { samples in
            let source = ExternalPCMSource()
            let recorder = CloudASRRecorder(provider: provider, options: config.recordingOptions(provider), credentials: credentials, language: language, capture: source)
            var result: String?, finished = false
            recorder.onFinal = { result = $0; finished = true }
            guard recorder.begin() else { return "" }
            var pcm = Data()
            for s in samples { var v = Int16(max(-1, min(1, s)) * 32767).littleEndian; withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) } }
            var offset = 0
            // A person speaks in real time and the recorder buffers about 8 s, so feed at 4x real time.
            while offset < pcm.count { source.push(pcm.subdata(in: offset..<min(offset + 3200, pcm.count))); offset += 3200; Thread.sleep(forTimeInterval: 0.025) }
            recorder.end()
            let end = Date().addingTimeInterval(30)
            while !finished && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            recorder.abort()
            return result ?? ""
        } })
    }

    // MARK: Run

    static func run() -> Int32 {
        let args = CommandLine.arguments
        let quick = args.contains("--bench-quick")
        if let v = value("--bench-pad").flatMap(Double.init) { LocalDecoder.segmentPad = Int(v * 16000) }
        if let v = value("--bench-min-speech").flatMap(Float.init) { LocalDecoder.vadMinSpeech = v }
        if let v = value("--bench-min-silence").flatMap(Float.init) { LocalDecoder.vadMinSilence = v }
        let voices = value("--bench-voices")?.split(separator: ",").map(String.init) ?? (quick ? ["Tingting"] : ["Tingting", "Eddy (中文（中国大陆）)", "Grandma (中文（中国大陆）)"])
        let conditions = value("--bench-conditions")?.split(separator: ",").compactMap { Condition(rawValue: String($0)) } ?? Condition.allCases
        let items = quick ? Array(corpus.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)) : corpus
        var engines = args.contains("--bench-cloud-only") ? [] : localEngines()
        // Cloud engines upload the synthesized audio, so each one must be named: --bench-cloud=iflytek,deepgram
        for name in (value("--bench-cloud") ?? "").split(separator: ",") {
            guard let provider = ASREngine(rawValue: String(name)), provider != .apple, provider != .local, provider.configured, let e = cloudEngine(provider) else { print("bench: \(name) is not configured or has no upload consent"); continue }
            engines.append(e)
        }
        let filter = value("--bench-engines")?.split(separator: ",").map(String.init)
        if let filter { engines = engines.filter { e in filter.contains { e.name.contains($0) } } }
        guard !engines.isEmpty else { print("bench: no engine available"); return 0 }
        let cloudLimit = Int(value("--bench-cloud-clips") ?? "40") ?? 40
        print("bench: engines=\(engines.map(\.name)) sentences=\(items.count) voices=\(voices.count) conditions=\(conditions.map(\.rawValue))")

        struct Row { var engine: String; var condition: Condition; var category: String; var text: String; var hypothesis: String; var cer: Double }
        struct Clip { let voice: String; let voiceIndex: Int; let condition: Condition; let index: Int; let item: Item }
        var clips: [Clip] = []
        for (v, voice) in voices.enumerated() { for condition in conditions { for (i, item) in items.enumerated() { clips.append(Clip(voice: voice, voiceIndex: v, condition: condition, index: i, item: item)) } } }

        // Speech is synthesized once, in parallel, and shared by every engine.
        let lock = NSLock()
        var audio = [[Float]?](repeating: nil, count: clips.count)
        var spoken: [String: [Float]] = [:]
        let unique = Array(Set(clips.map { "\($0.voice)|\($0.condition.rate ?? 0)|\($0.item.text)" }))
        let synth = DispatchQueue(label: "bench.say", attributes: .concurrent), gate = DispatchSemaphore(value: 4), group = DispatchGroup()
        for n in 0..<unique.count { gate.wait(); group.enter(); synth.async { defer { gate.signal(); group.leave() }
            let parts = unique[n].split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            let rate = Int(parts[1]) ?? 0
            if let samples = speech(parts[2], voice: parts[0], rate: rate == 0 ? nil : rate) { lock.lock(); spoken[unique[n]] = samples; lock.unlock() }
        } }
        group.wait()
        for (n, clip) in clips.enumerated() {
            guard let clean = spoken["\(clip.voice)|\(clip.condition.rate ?? 0)|\(clip.item.text)"] else { continue }
            audio[n] = clip.condition.apply(clean, seed: UInt64(1000 + clip.voiceIndex * 100 + clip.index))
        }
        let workers = max(1, Int(value("--bench-workers") ?? "") ?? max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        print("bench: audio ready (\(spoken.count) unique clips), workers=\(workers)")

        var rows: [Row] = []
        for engine in engines {
            let started = ProcessInfo.processInfo.systemUptime
            let selected = engine.parallel ? Array(clips.indices) : Array(stride(from: 0, to: clips.count, by: max(1, clips.count / max(1, cloudLimit))).prefix(cloudLimit))
            let count = engine.parallel ? workers : 1
            var next = 0
            let rowLock = NSLock()
            DispatchQueue.concurrentPerform(iterations: count) { _ in
                let transcribe = engine.make()
                while true {
                    rowLock.lock(); let slot = next; next += 1; rowLock.unlock()
                    guard slot < selected.count else { return }
                    let n = selected[slot]
                    guard let samples = audio[n] else { continue }
                    let clip = clips[n], hypothesis = transcribe(samples)
                    let row = Row(engine: engine.name, condition: clip.condition, category: clip.item.category, text: clip.item.text, hypothesis: hypothesis, cer: cer(reference: clip.item.text, hypothesis: hypothesis))
                    rowLock.lock(); rows.append(row); rowLock.unlock()
                }
            }
            print("  \(engine.name): \(rows.filter { $0.engine == engine.name }.count) clips in \(String(format: "%.0f", ProcessInfo.processInfo.systemUptime - started)) s")
        }

        func mean(_ r: [Row]) -> Double { r.isEmpty ? 0 : r.reduce(0) { $0 + $1.cer } / Double(r.count) }
        func pct(_ x: Double) -> String { String(format: "%5.1f%%", x * 100) }
        let names = engines.map(\.name)
        print("\nCharacter error rate by condition (lower is better)")
        print(("engine".padding(toLength: 30, withPad: " ", startingAt: 0)) + conditions.map { $0.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0) }.joined() + "overall")
        for name in names {
            let mine = rows.filter { $0.engine == name }
            print(name.padding(toLength: 30, withPad: " ", startingAt: 0) + conditions.map { c in pct(mean(mine.filter { $0.condition == c })).padding(toLength: 9, withPad: " ", startingAt: 0) }.joined() + pct(mean(mine)))
        }
        let categories = Array(Set(corpus.map(\.category))).sorted()
        print("\nCharacter error rate by sentence type")
        print(("engine".padding(toLength: 30, withPad: " ", startingAt: 0)) + categories.map { $0.padding(toLength: 9, withPad: " ", startingAt: 0) }.joined())
        for name in names {
            let mine = rows.filter { $0.engine == name }
            print(name.padding(toLength: 30, withPad: " ", startingAt: 0) + categories.map { c in pct(mean(mine.filter { $0.category == c })).padding(toLength: 9, withPad: " ", startingAt: 0) }.joined())
        }
        if let best = names.first {
            print("\nWorst clips for \(best)")
            for row in rows.filter({ $0.engine == best }).sorted(by: { $0.cer > $1.cer }).prefix(8) {
                print("  [\(row.condition.rawValue)] \(pct(row.cer)) ref: \(row.text)\n      hyp: \(row.hypothesis)")
            }
        }
        if let out = value("--bench-out") {
            let json: [[String: Any]] = rows.map { ["engine": $0.engine, "condition": $0.condition.rawValue, "category": $0.category, "reference": $0.text, "hypothesis": $0.hypothesis, "cer": $0.cer] }
            if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) { try? data.write(to: URL(fileURLWithPath: out)) }
        }
        return 0
    }
}

// MARK: - Speed and memory (`--bench-speed --bench-model=<kind>:<folder>`)

/// Measures how long a model takes to load, how long it takes to answer a short sentence and how much memory the process holds,
/// so the model list can say it. Run once per model, each in its own process, because memory that was used does not shrink.
enum ModelSpeedBenchmark {
    static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return status == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
    }

    static let chinese = ["我们明天上午十点在会议室开会，请提前十分钟到，带上最新的报告。", "我想只用本地识别，不想用云端，因为我的录音只想留在这台电脑上。", "晚上我们一起去吃火锅怎么样，顺便聊一聊下个月的安排。"]
    static let english = ["Hello world. This is a local speech recognition test, please check the result carefully.", "Tomorrow morning at ten we meet in the conference room, please bring the latest report."]

    static func run() -> Int32 {
        guard LocalTranscriberLoader.supported else { print("[speed] no inference library in this build"); return 2 }
        let args = CommandLine.arguments.filter { $0.hasPrefix("--bench-model=") }
        guard args.count == 1, let spec = args.first?.dropFirst("--bench-model=".count).split(separator: ":", maxSplits: 1).map(String.init), spec.count == 2 else {
            print("[speed] expected exactly one --bench-model=<kind>:<folder>"); return 2
        }
        let entry = LocalModelEntry(id: "speed-" + spec[0], version: "0", displayName: [:], summary: [:], kind: spec[0], languages: [], downloadSize: 1, installedSize: 1, minAppVersion: "1.0.0", license: "", changelog: "", files: [], requiredFiles: [])
        let dir = URL(fileURLWithPath: spec[1])
        let before = residentMB()
        let loadStart = ProcessInfo.processInfo.systemUptime
        guard let t = try? LocalTranscriberLoader.load(dir: dir, entry: entry) else { print("[speed] cannot load \(spec[0]) from \(spec[1])"); return 1 }
        let load = ProcessInfo.processInfo.systemUptime - loadStart
        let clips: [(String, [Float])] = (chinese.map { ("zh", $0) } + english.map { ("en", $0) }).compactMap { language, text in
            AccuracyBenchmark.speech(text, voice: language == "zh" ? "Tingting" : "Samantha", rate: nil).map { (language, $0) }
        }
        guard !clips.isEmpty else { print("[speed] no system voice available"); return 2 }
        _ = LocalDecoder.transcribe(clips[0].1, with: t)             // warm-up: the first answer pays one-time setup
        var rows: [(String, Double, Double, String)] = []
        for (language, samples) in clips {
            var times: [Double] = [], text = ""
            for _ in 0..<3 {
                let s = ProcessInfo.processInfo.systemUptime
                text = LocalDecoder.transcribe(samples, with: t)
                times.append(ProcessInfo.processInfo.systemUptime - s)
            }
            rows.append((language, Double(samples.count) / 16000, times.reduce(0, +) / Double(times.count), text))
        }
        let after = residentMB()
        print("[speed] kind=\(spec[0]) load=\(String(format: "%.1f", load)) s memory=\(after) MB (before load \(before) MB, +\(after - before) MB)")
        for r in rows { print("[speed]   \(r.0) audio=\(String(format: "%.1f", r.1)) s decode=\(Int(r.2 * 1000)) ms rtf=\(String(format: "%.3f", r.2 / r.1)) text=\(r.3)") }
        for language in ["zh", "en"] {
            let own = rows.filter { $0.0 == language }
            guard !own.isEmpty else { continue }
            let audio = own.map(\.1).reduce(0, +) / Double(own.count), decode = own.map(\.2).reduce(0, +) / Double(own.count)
            let punctuated = own.filter { $0.3.contains(where: { "，。,.？?！!".contains($0) }) }.count
            print("[speed] summary \(language): mean audio \(String(format: "%.1f", audio)) s, mean decode \(Int(decode * 1000)) ms, rtf \(String(format: "%.3f", decode / audio)), punctuation in \(punctuated)/\(own.count)")
        }
        return 0
    }
}
