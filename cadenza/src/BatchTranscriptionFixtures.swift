import Foundation

enum BatchTranscriptionFixtures {
    /// A scripted service: records what was sent and answers with a status and a body.
    final class FakeHTTP: ASRHTTP {
        var replies: [(Int, Data)]
        var requests: [URLRequest] = []
        init(_ replies: [(Int, Data)]) { self.replies = replies }
        func request(_ request: URLRequest, completion: @escaping (Result<Data, Error>) -> Void) { completion(.failure(ASRFailure.protocolInvalid)) }
        func exchange(_ request: URLRequest, completion: @escaping (Result<(status: Int, data: Data), Error>) -> Void) {
            requests.append(request)
            if replies.isEmpty { completion(.failure(ASRFailure.protocolInvalid)) } else { let r = replies.removeFirst(); completion(.success((r.0, r.1))) }
        }
        func cancel() {}
    }

    static func run(_ check: (String, Bool) -> Void) {
        func c(_ name: String, _ ok: Bool) { check("BatchTranscription " + name, ok) }
        func options(_ engine: ASREngine, consent: Bool = true, tweak: (inout CloudASROptions) -> Void = { _ in }) -> CloudASROptions {
            var o = CloudASROptions.defaults(engine); o.consent = consent; tweak(&o); return o
        }
        func body(_ r: URLRequest?) -> String { r?.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? "" }
        let pcm = Data(repeating: 1, count: 3200)

        // Which engines, and their defaults
        c("engines: OpenAI and Groq are listed, upload the whole recording and keep no Chinese-service switches",
          ASREngine.allCases.contains(.openai) && ASREngine.allCases.contains(.groq) && ASREngine.openai.uploadsWholeRecording && ASREngine.groq.uploadsWholeRecording
          && !ASREngine.openai.hasTextSwitches && ASREngine.tencent.hasTextSwitches && !ASREngine.tencent.uploadsWholeRecording)
        c("engines: default models are ones the service offers", ASREngine.allCases.filter { BatchTranscription.service($0) != nil && $0 != .compat }.allSatisfy { e in BatchTranscription.service(e)!.models.contains(CloudASROptions.defaults(e).model) })
        c("engines: one API key is the only credential", ASREngine.openai.credentialFields.map(\.0) == ["apikey"] && ASREngine.groq.credentialFields.map(\.0) == ["apikey"])

        // Options
        c("options: the defaults are valid", BatchTranscription.validate(.openai, options(.openai)) == nil && BatchTranscription.validate(.groq, options(.groq)) == nil && ASROptionPolicy.validate(.openai, options(.openai)) == nil)
        c("options: another service's model, an unknown language, too long a list, or a Chinese-service switch is refused",
          BatchTranscription.validate(.openai, options(.openai) { $0.model = "whisper-large-v3" }) != nil && BatchTranscription.validate(.groq, options(.groq) { $0.language = "xx" }) != nil
          && BatchTranscription.validate(.openai, options(.openai) { $0.hotwords = String(repeating: "a", count: 601) }) != nil && BatchTranscription.validate(.openai, options(.openai) { $0.smoothing = true }) != nil
          && BatchTranscription.validate(.openai, options(.openai) { $0.vocabularyID = "1" }) != nil)

        // The recording as a file
        let wav = BatchTranscription.wav(pcm: pcm)
        func u32(_ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(wav[at + $1]) << (8 * $1) } }
        c("wav: a 44-byte header for 16 kHz mono 16-bit, with the sizes of this recording",
          wav.count == 44 + pcm.count && String(decoding: wav[0..<4], as: UTF8.self) == "RIFF" && String(decoding: wav[8..<16], as: UTF8.self) == "WAVEfmt " && u32(4) == 36 + pcm.count
          && u32(24) == 16000 && u32(28) == 32000 && String(decoding: wav[36..<40], as: UTF8.self) == "data" && u32(40) == pcm.count && wav.suffix(pcm.count) == pcm)

        // The hint for names and terms
        c("prompt: lines and commas become one short list, empties dropped, capped", BatchTranscription.prompt("GitHub\n\n Kubernetes ,Cadenza") == "GitHub, Kubernetes, Cadenza" && BatchTranscription.prompt(String(repeating: "a,", count: 600)).count <= BatchTranscription.promptLimit)

        // The request
        let r = BatchTranscription.request(.openai, options: options(.openai) { $0.language = "zh"; $0.hotwords = "Cadenza\nGitHub" }, key: "k-1", pcm: pcm, boundary: "BOUND")
        let text = body(r)
        c("request: the address, the key in the header only, and a multipart body",
          r?.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions" && r?.httpMethod == "POST" && r?.value(forHTTPHeaderField: "Authorization") == "Bearer k-1"
          && r?.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=BOUND" && !text.contains("k-1") && text.hasSuffix("--BOUND--\r\n"))
        c("request: model, language and the term list are fields; the recording is the file", text.contains("name=\"model\"\r\n\r\ngpt-4o-mini-transcribe") && text.contains("name=\"language\"\r\n\r\nzh") && text.contains("name=\"prompt\"\r\n\r\nCadenza, GitHub")
          && text.contains("name=\"file\"; filename=\"speech.wav\"") && text.contains("RIFF") && text.contains("name=\"response_format\"\r\n\r\njson"))
        let auto = body(BatchTranscription.request(.groq, options: options(.groq), key: "k", pcm: pcm, boundary: "B"))
        c("request: detecting the language sends no language and no empty hint; Groq has its own address",
          !auto.contains("name=\"language\"") && !auto.contains("name=\"prompt\"") && BatchTranscription.request(.groq, options: options(.groq), key: "k", pcm: pcm)?.url?.host == "api.groq.com")
        c("request: no key, no audio, odd audio, invalid options or another engine make no request",
          BatchTranscription.request(.openai, options: options(.openai), key: "", pcm: pcm) == nil && BatchTranscription.request(.openai, options: options(.openai), key: "k", pcm: Data()) == nil
          && BatchTranscription.request(.openai, options: options(.openai), key: "k", pcm: Data(count: 3)) == nil && BatchTranscription.request(.openai, options: options(.openai) { $0.model = "x" }, key: "k", pcm: pcm) == nil
          && BatchTranscription.request(.tencent, options: options(.tencent), key: "k", pcm: pcm) == nil)
        c("key check: a model-list request with the key and no audio", BatchTranscription.keyCheckRequest(.openai, key: "k")?.url?.path == "/v1/models" && BatchTranscription.keyCheckRequest(.openai, key: "k")?.httpBody == nil && BatchTranscription.keyCheckRequest(.openai, key: "") == nil)

        // A service of the person's own
        func custom(_ base: String, _ model: String = "m-1") -> CloudASROptions { options(.compat) { $0.baseURL = base; $0.model = model } }
        c("compat: listed, takes the whole recording, not in the old window's list", ASREngine.allCases.contains(.compat) && ASREngine.compat.uploadsWholeRecording && !ASREngine.legacyListed.contains(.compat))
        c("compat: the default is the first preset and is valid", BatchTranscription.validate(.compat, options(.compat)) == nil && options(.compat).baseURL == BatchTranscription.compatPresets[0].baseURL)
        c("compat: every preset is valid and recognized by its address", BatchTranscription.compatPresets.allSatisfy { p in BatchTranscription.validate(.compat, custom(p.baseURL, p.model)) == nil && BatchTranscription.preset(forBaseURL: p.baseURL)?.id == p.id } && BatchTranscription.preset(forBaseURL: "https://example.com/v1") == nil)
        c("compat: the address gets the transcription path, with or without a trailing slash or the path itself",
          BatchTranscription.endpointURL(.compat, custom("https://api.example.com/v1"))?.absoluteString == "https://api.example.com/v1/audio/transcriptions"
          && BatchTranscription.endpointURL(.compat, custom("https://api.example.com/v1/"))?.absoluteString == "https://api.example.com/v1/audio/transcriptions"
          && BatchTranscription.endpointURL(.compat, custom("https://api.example.com/v1/audio/transcriptions"))?.absoluteString == "https://api.example.com/v1/audio/transcriptions"
          && BatchTranscription.modelsURL(.compat, custom("https://api.example.com/v1"))?.absoluteString == "https://api.example.com/v1/models")
        c("compat: http is for this Mac only; credentials, queries and other schemes are refused",
          BatchTranscription.validate(.compat, custom("http://localhost:8000/v1")) == nil && BatchTranscription.validate(.compat, custom("http://192.168.1.5:8000/v1")) != nil
          && BatchTranscription.validate(.compat, custom("https://user:pw@api.example.com/v1")) != nil && BatchTranscription.validate(.compat, custom("https://api.example.com/v1?key=1")) != nil
          && BatchTranscription.validate(.compat, custom("ftp://api.example.com/v1")) != nil && BatchTranscription.validate(.compat, custom("")) != nil)
        c("compat: a model name is a short plain word, not empty and not with spaces", BatchTranscription.validate(.compat, custom("https://a.example.com/v1", "")) != nil && BatchTranscription.validate(.compat, custom("https://a.example.com/v1", "two words")) != nil && BatchTranscription.validate(.compat, custom("https://a.example.com/v1", "org/model-v3.1")) == nil)
        let cr = BatchTranscription.request(.compat, options: custom("https://api.example.com/v1", "org/model"), key: "k", pcm: pcm, boundary: "B")
        c("compat: the request goes to that address with that model, and the key only in the header", cr?.url?.host == "api.example.com" && body(cr).contains("name=\"model\"\r\n\r\norg/model") && !body(cr).contains("name=\"k\"") && cr?.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        c("compat: the destination named to the person is the host, the key check asks that host's model list", BatchTranscription.destination(.compat, custom("https://api.example.com/v1")) == "api.example.com" && BatchTranscription.keyCheckRequest(.compat, key: "k", options: custom("https://api.example.com/v1"))?.url?.path == "/v1/models")
        let oldFile = try? JSONDecoder().decode(CloudASROptions.self, from: Data("{\"consent\":true,\"model\":\"nova-3\"}".utf8))
        c("compat: saved settings from before have no address and still load", oldFile?.baseURL == "" && oldFile?.consent == true)
        let again = try? JSONDecoder().decode(CloudASROptions.self, from: JSONEncoder().encode(custom("https://api.example.com/v1")))
        c("compat: the address survives saving", again?.baseURL == "https://api.example.com/v1")
        let named = FakeHTTP([(401, Data("{}".utf8))])
        let namedResult = CloudClipTranscriber.transcribe([Float](repeating: 0.2, count: 16000), provider: .compat, options: custom("https://api.example.com/v1"), credentials: ["apikey": "k"], language: "zh_cn", speed: 100, timeout: 5,
                                                          makeRecorder: { CloudASRRecorder(provider: .compat, options: custom("https://api.example.com/v1"), credentials: ["apikey": "k"], capture: $0, http: named) })
        if case .failed(let why) = namedResult { c("compat: a rejected key names the host, not a brand", why.contains("api.example.com") && named.requests.first?.url?.host == "api.example.com") } else { c("compat: a rejected key names the host, not a brand", false) }

        // The answer
        func parsed(_ status: Int, _ json: String, _ engine: ASREngine = .openai) -> Result<String, Error> { Result { try BatchTranscription.parse(status: status, data: Data(json.utf8), engine: engine) } }
        func hint(_ status: Int, _ json: String) -> String { if case .failure(let e) = parsed(status, json), let s = e as? ASRServiceError { return s.hint }; return "" }
        c("parse: the text of a good answer, trimmed", (try? parsed(200, "{\"text\":\"  你好，世界。\\n\"}").get()) == "你好，世界。")
        c("parse: a wrong key, a missing model, a limit, a server fault each say so", hint(401, "{}") == L10n.format("batch.err.auth", ASREngine.openai.title) && hint(404, "{}") == L10n.format("batch.err.model", ASREngine.openai.title)
          && hint(429, "{}") == L10n.format("batch.err.quota", ASREngine.openai.title) && hint(503, "{}") == L10n.format("batch.err.server", ASREngine.openai.title) && hint(413, "{}") == L10n.format("batch.err.tooLong", ASREngine.openai.title))
        c("parse: a message that echoes the key is never shown, an ordinary one is", !hint(400, "{\"error\":{\"message\":\"Incorrect API key provided: sk-abc***\"}}").contains("sk-") && hint(400, "{\"error\":{\"message\":\"Invalid file format.\"}}").contains("Invalid file format."))
        c("parse: an answer that is not JSON or has no text is refused", { if case .failure = parsed(200, "<html>") { return true }; return false }() && { if case .failure = parsed(200, "{\"x\":1}") { return true }; return false }())

        // A whole dictation through the recorder
        func dictate(_ engine: ASREngine, _ http: FakeHTTP, consent: Bool = true, samples: [Float] = [Float](repeating: 0.2, count: 16000)) -> ClipResult {
            CloudClipTranscriber.transcribe(samples, provider: engine, options: options(engine, consent: consent), credentials: ["apikey": "k"], language: "zh_cn", speed: 100, timeout: 5,
                                            makeRecorder: { CloudASRRecorder(provider: engine, options: options(engine, consent: consent), credentials: ["apikey": "k"], capture: $0, http: http) })
        }
        let good = FakeHTTP([(200, Data("{\"text\":\"你好世界\"}".utf8))])
        c("recorder: the recording is uploaded once and its text comes back", dictate(.openai, good) == .text("你好世界") && good.requests.count == 1 && good.requests[0].url?.host == "api.openai.com")
        let rejected = FakeHTTP([(401, Data("{}".utf8))])
        if case .failed(let why) = dictate(.groq, rejected) { c("recorder: a rejected key is reported as such and nothing is typed", why == L10n.format("batch.err.auth", ASREngine.groq.title) && rejected.requests.count == 1) } else { c("recorder: a rejected key is reported as such and nothing is typed", false) }
        let silent = FakeHTTP([(200, Data("{\"text\":\"x\"}".utf8))])
        c("recorder: silence is not uploaded", dictate(.openai, silent, samples: [Float](repeating: 0, count: 16000)) == .text("") && silent.requests.isEmpty)
        let noConsent = FakeHTTP([(200, Data("{\"text\":\"x\"}".utf8))])
        if case .failed = dictate(.openai, noConsent, consent: false) { c("recorder: without permission to upload nothing is sent", noConsent.requests.isEmpty) } else { c("recorder: without permission to upload nothing is sent", false) }

        // Vocabulary as the hint
        var vocab = VocabularySettings(); vocab.enabled = true; vocab.sendToCloud = true
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("cadenza-batch-vocab-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let store = VocabularyStore(); store.userFile = scratch.appendingPathComponent("vocabulary.json"); store.packDirectories = [scratch.appendingPathComponent("none")]; store.reload()
        store.setUser([VocabEntry(term: "Kubernetes", aliases: [])])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let withVocab = VocabularyHotwords.apply(.openai, to: options(.openai) { $0.hotwords = "Cadenza" }, settings: vocab, store: store)
        c("vocabulary: the terms join the hint for OpenAI and stay within its length", withVocab.hotwords == "Cadenza\nKubernetes" && BatchTranscription.prompt(withVocab.hotwords) == "Cadenza, Kubernetes")
        vocab.sendToCloud = false
        c("vocabulary: nothing is added unless the person allowed sending it", VocabularyHotwords.apply(.openai, to: options(.openai), settings: vocab, store: store).hotwords == "")
    }

    /// `--selftest-batch-real`: one second of a tone through the real network path to a server of your own
    /// (CADENZA_BATCH_BASE, e.g. http://127.0.0.1:8765/v1; CADENZA_BATCH_MODEL, CADENZA_BATCH_KEY). Prints what the server answered.
    static func real() -> Int32 {
        let env = ProcessInfo.processInfo.environment
        var o = CloudASROptions.defaults(.compat); o.consent = true
        o.baseURL = env["CADENZA_BATCH_BASE"] ?? "http://127.0.0.1:8765/v1"; o.model = env["CADENZA_BATCH_MODEL"] ?? "fixture-model"; o.language = "zh"; o.hotwords = "Cadenza\nGitHub"
        let key = env["CADENZA_BATCH_KEY"] ?? "fixture-key"
        let tone = (0..<16000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16000)) * 0.3 }
        let result = CloudClipTranscriber.transcribe(tone, provider: .compat, options: o, credentials: ["apikey": key], language: "zh_cn", speed: 100, timeout: 20)
        print("[batch-real] \(result)")
        if case .text(let t) = result, !t.isEmpty { return 0 }
        return 1
    }
}
