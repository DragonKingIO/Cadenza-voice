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
        c("engines: default models are ones the service offers", ASREngine.allCases.filter { BatchTranscription.service($0) != nil && $0 != .compat && $0 != .azure }.allSatisfy { e in BatchTranscription.service(e)!.models.contains(CloudASROptions.defaults(e).model) })
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
        c("compat: listed, takes the whole recording, not in the old window's list", ASREngine.allCases.contains(.compat) && ASREngine.compat.uploadsWholeRecording && !ASREngine.legacyListed.contains(.compat) && !ASREngine.legacyListed.contains(.azure))
        c("compat: the default is the first preset and is valid", BatchTranscription.validate(.compat, options(.compat)) == nil && options(.compat).baseURL == BatchTranscription.compatPresets[0].baseURL)
        c("compat: every preset is valid and recognized by its address", BatchTranscription.compatPresets.allSatisfy { p in BatchTranscription.validate(.compat, custom(p.baseURL, p.model)) == nil && BatchTranscription.preset(forBaseURL: p.baseURL)?.id == p.id } && BatchTranscription.preset(forBaseURL: "https://example.com/v1") == nil)
        c("compat: the address gets the transcription path, with or without a trailing slash or the path itself",
          BatchTranscription.endpointURL(.compat, custom("https://api.example.com/v1"))?.absoluteString == "https://api.example.com/v1/audio/transcriptions"
          && BatchTranscription.endpointURL(.compat, custom("https://api.example.com/v1/"))?.absoluteString == "https://api.example.com/v1/audio/transcriptions"
          && BatchTranscription.endpointURL(.compat, custom("https://api.example.com/v1/audio/transcriptions"))?.absoluteString == "https://api.example.com/v1/audio/transcriptions"
          && BatchTranscription.modelsURL(.compat, custom("https://api.example.com/v1"))?.absoluteString == "https://api.example.com/v1/models")
        c("compat: http is for this Mac only; credentials, queries and other schemes are refused",
          BatchTranscription.validate(.compat, custom("http://localhost:8000/v1")) == nil && BatchTranscription.validate(.compat, custom("http://192.168.1.5:8000/v1")) != nil
          && BatchTranscription.validate(.compat, custom("https://" + "user" + ":" + "pw" + "@" + "api.example.com/v1")) != nil && BatchTranscription.validate(.compat, custom("https://api.example.com/v1?key=1")) != nil
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

        // Google Cloud
        func json(_ r: URLRequest?) -> [String: Any]? { r?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
        c("google: listed, one minute at most, language and model are chosen", ASREngine.google.uploadsWholeRecording && ASREngine.google.wholeRecordingSeconds == 60 && options(.google).language == "zh" && options(.google).model == "default" && BatchTranscription.validate(.google, options(.google)) == nil)
        c("google: it needs a language named, and a known model", BatchTranscription.validate(.google, options(.google) { $0.language = "multi" }) != nil && BatchTranscription.validate(.google, options(.google) { $0.model = "x" }) != nil && BatchTranscription.validate(.google, options(.google) { $0.language = "yue" }) == nil)
        let gr = BatchTranscription.request(.google, options: options(.google) { $0.hotwords = "Cadenza\nGitHub" }, key: "g-key", pcm: pcm)
        let gj = json(gr), gconfig = gj?["config"] as? [String: Any], gaudio = gj?["audio"] as? [String: Any]
        c("google: the key is a header, never in the address or the body", gr?.url?.absoluteString == "https://speech.googleapis.com/v1/speech:recognize" && gr?.value(forHTTPHeaderField: "X-Goog-Api-Key") == "g-key" && !body(gr).contains("g-key") && gr?.httpMethod == "POST")
        c("google: the recording, the language and the terms go in the body", gconfig?["languageCode"] as? String == "cmn-Hans-CN" && gconfig?["encoding"] as? String == "LINEAR16" && gconfig?["sampleRateHertz"] as? Int == 16000 && gconfig?["model"] as? String == "default"
          && gconfig?["enableAutomaticPunctuation"] as? Bool == true && ((gconfig?["speechContexts"] as? [[String: Any]])?.first?["phrases"] as? [String]) == ["Cadenza", "GitHub"] && (gaudio?["content"] as? String).flatMap { Data(base64Encoded: $0) } == pcm)
        c("google: no terms, no speech context", (json(BatchTranscription.request(.google, options: options(.google), key: "k", pcm: pcm))?["config"] as? [String: Any])?["speechContexts"] == nil)
        let goodGoogle = "{\"results\":[{\"alternatives\":[{\"transcript\":\"你好\"}]},{\"alternatives\":[{\"transcript\":\"世界\"}]}]}"
        func gparsed(_ status: Int, _ s: String, _ o: CloudASROptions? = nil) -> Result<String, Error> { Result { try BatchTranscription.parse(status: status, data: Data(s.utf8), engine: .google, options: o ?? options(.google)) } }
        c("google: sentences are joined without spaces for Chinese and with one for English", (try? gparsed(200, goodGoogle).get()) == "你好世界" && (try? gparsed(200, "{\"results\":[{\"alternatives\":[{\"transcript\":\"hello\"}]},{\"alternatives\":[{\"transcript\":\"world\"}]}]}", options(.google) { $0.language = "en" }).get()) == "hello world")
        c("google: a recording with nothing recognized is an empty answer, not a failure", (try? gparsed(200, "{}").get()) == "")
        func ghint(_ status: Int, _ s: String) -> String { if case .failure(let e) = gparsed(status, s), let x = e as? ASRServiceError { return x.hint }; return "" }
        c("google: a wrong key, a project without the API, a limit each say so", ghint(400, "{\"error\":{\"message\":\"API key not valid. Please pass a valid API key.\",\"status\":\"INVALID_ARGUMENT\"}}") == L10n.format("batch.err.auth", ASREngine.google.title)
          && ghint(403, "{\"error\":{\"status\":\"PERMISSION_DENIED\"}}") == L10n.format("batch.err.googleDenied", ASREngine.google.title) && ghint(429, "{}") == L10n.format("batch.err.quota", ASREngine.google.title))
        let gk = BatchTranscription.keyCheckRequest(.google, key: "g", options: options(.google))
        c("google: the key check sends an empty request and no audio", gk?.httpMethod == "POST" && gk?.httpBody == Data("{}".utf8) && gk?.value(forHTTPHeaderField: "X-Goog-Api-Key") == "g")
        c("google: a good key is told from a wrong one by the answer to the empty request", BatchTranscription.keyCheckPassed(.google, status: 400, data: Data("{\"error\":{\"status\":\"INVALID_ARGUMENT\",\"message\":\"Invalid recognition config\"}}".utf8))
          && !BatchTranscription.keyCheckPassed(.google, status: 400, data: Data("{\"error\":{\"status\":\"INVALID_ARGUMENT\",\"message\":\"API key not valid.\",\"details\":[{\"reason\":\"API_KEY_INVALID\"}]}}".utf8))
          && !BatchTranscription.keyCheckPassed(.google, status: 403, data: Data("{}".utf8)) && BatchTranscription.keyCheckPassed(.openai, status: 200, data: Data()) && !BatchTranscription.keyCheckPassed(.openai, status: 401, data: Data()))

        // Microsoft Azure
        c("azure: listed, one minute at most, region eastus and a language are the defaults", ASREngine.azure.uploadsWholeRecording && ASREngine.azure.wholeRecordingSeconds == 60 && options(.azure).region == "eastus" && options(.azure).language == "zh" && BatchTranscription.validate(.azure, options(.azure)) == nil)
        c("azure: a region or the address of the resource is accepted", BatchTranscription.azureEndpoints("westeurope")?.recognize.absoluteString == "https://westeurope.stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1"
          && BatchTranscription.azureEndpoints("westeurope")?.token.absoluteString == "https://westeurope.api.cognitive.microsoft.com/sts/v1.0/issueToken"
          && BatchTranscription.azureEndpoints("https://my-speech.cognitiveservices.azure.com")?.recognize.absoluteString == "https://my-speech.cognitiveservices.azure.com/stt/speech/recognition/conversation/cognitiveservices/v1"
          && BatchTranscription.azureEndpoints("https://my-speech.cognitiveservices.azure.com/")?.token.absoluteString == "https://my-speech.cognitiveservices.azure.com/sts/v1.0/issueToken")
        c("azure: an address that could send the key elsewhere is refused",
          BatchTranscription.azureEndpoints("http://my-speech.cognitiveservices.azure.com") == nil && BatchTranscription.azureEndpoints("https://evil.example.com") == nil && BatchTranscription.azureEndpoints("https://azure.com.evil.example") == nil
          && BatchTranscription.azureEndpoints("https://" + "u" + ":" + "p" + "@my.azure.com") == nil && BatchTranscription.azureEndpoints("https://my.azure.com/path?x=1") == nil && BatchTranscription.azureEndpoints("East US") == nil && BatchTranscription.azureEndpoints("") == nil)
        c("azure: it takes no list of terms and needs a named language", BatchTranscription.validate(.azure, options(.azure) { $0.hotwords = "a" }) != nil && BatchTranscription.validate(.azure, options(.azure) { $0.language = "multi" }) != nil)
        let ar = BatchTranscription.request(.azure, options: options(.azure) { $0.language = "en" }, key: "a-key", pcm: pcm)
        c("azure: language, plain result format and unmasked words are in the address; the key is a header only",
          ar?.url?.host == "eastus.stt.speech.microsoft.com" && ar?.url?.query == "language=en-US&format=simple&profanity=raw" && ar?.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") == "a-key" && !(ar?.url?.absoluteString.contains("a-key") ?? true))
        c("azure: the body is the recording as a WAV file", ar?.httpBody == BatchTranscription.wav(pcm: pcm) && ar?.value(forHTTPHeaderField: "Content-Type") == "audio/wav; codecs=audio/pcm; samplerate=16000")
        func aparsed(_ status: Int, _ s: String) -> Result<String, Error> { Result { try BatchTranscription.parse(status: status, data: Data(s.utf8), engine: .azure, options: options(.azure)) } }
        c("azure: the display text of a success", (try? aparsed(200, "{\"RecognitionStatus\":\"Success\",\"DisplayText\":\" 你好，世界。 \"}").get()) == "你好，世界。")
        c("azure: nothing recognized is an empty answer; an internal error and a wrong key are failures",
          (try? aparsed(200, "{\"RecognitionStatus\":\"NoMatch\"}").get()) == "" && (try? aparsed(200, "{\"RecognitionStatus\":\"InitialSilenceTimeout\"}").get()) == ""
          && { if case .failure = aparsed(200, "{\"RecognitionStatus\":\"Error\"}") { return true }; return false }() && { if case .failure = aparsed(401, "{}") { return true }; return false }())
        let ak = BatchTranscription.keyCheckRequest(.azure, key: "a", options: options(.azure))
        c("azure: the key check asks for a token and sends no audio", ak?.url?.host == "eastus.api.cognitive.microsoft.com" && ak?.httpMethod == "POST" && ak?.httpBody == Data() && ak?.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") == "a")

        // The explicit connection check for each of the new services, with scripted answers
        func probed(_ engine: ASREngine, _ reply: (Int, String)) -> Bool? {
            let http = FakeHTTP([(reply.0, Data(reply.1.utf8))])
            let probe = ProviderConnectionProbe(engine: engine, options: options(engine), credentials: ["apikey": "k"], http: http)
            var outcome: Bool?
            probe.start { outcome = $0 }
            for _ in 0..<6 { probe.synchronizeForTests() }
            return outcome.flatMap { http.requests.count == 1 && http.requests[0].httpBody.map { $0.count <= 2 } != false ? $0 : nil }
        }
        c("check: Google passes on invalid-argument and fails on a wrong key or a project without the API",
          probed(.google, (400, "{\"error\":{\"status\":\"INVALID_ARGUMENT\"}}")) == true && probed(.google, (400, "{\"error\":{\"status\":\"INVALID_ARGUMENT\",\"details\":[{\"reason\":\"API_KEY_INVALID\"}]}}")) == false && probed(.google, (403, "{}")) == false)
        c("check: Azure passes on a token and fails on a wrong key", probed(.azure, (200, "eyJ.token")) == true && probed(.azure, (401, "{}")) == false)
        c("check: OpenAI, Groq and a custom address pass on the model list", probed(.openai, (200, "{}")) == true && probed(.groq, (200, "{}")) == true && probed(.compat, (200, "{}")) == true && probed(.openai, (401, "{}")) == false)

        // AssemblyAI
        c("assemblyai: listed, two minutes at most, English-free defaults valid", ASREngine.assemblyai.uploadsWholeRecording && ASREngine.assemblyai.wholeRecordingSeconds == 120 && options(.assemblyai).language == "zh" && BatchTranscription.validate(.assemblyai, options(.assemblyai)) == nil)
        c("assemblyai: only the languages its model covers, and a language must be named", BatchTranscription.validate(.assemblyai, options(.assemblyai) { $0.language = "multi" }) != nil && BatchTranscription.validate(.assemblyai, options(.assemblyai) { $0.language = "th" }) != nil && BatchTranscription.validate(.assemblyai, options(.assemblyai) { $0.language = "ja" }) == nil)
        let sr = BatchTranscription.request(.assemblyai, options: options(.assemblyai) { $0.language = "en"; $0.hotwords = "Cadenza\nGitHub\none two three four five six seven" }, key: "aai-key", pcm: pcm, boundary: "BOUND")
        let sb = body(sr)
        c("assemblyai: the address, the key and the model are in the headers only", sr?.url?.absoluteString == "https://sync.assemblyai.com/v1/transcribe/live" && sr?.value(forHTTPHeaderField: "Authorization") == "aai-key" && sr?.value(forHTTPHeaderField: "X-AAI-Model") == "universal-3-5-pro" && !sb.contains("aai-key"))
        c("assemblyai: the settings come first as JSON, then the recording as the audio part",
          { guard let a = sb.range(of: "name=\"config\""), let b = sb.range(of: "name=\"audio\"") else { return false }; return a.lowerBound < b.lowerBound }() && sb.contains("name=\"config\"\r\nContent-Type: application/json\r\n\r\n") && sb.contains("\"language_codes\":[\"en\"]") && sb.contains("RIFF"))
        c("assemblyai: the terms go as key terms, a phrase of more than six words is left out", sb.contains("\"keyterms_prompt\":[\"Cadenza\",\"GitHub\"]"))
        func sparsed(_ status: Int, _ s: String) -> Result<String, Error> { Result { try BatchTranscription.parse(status: status, data: Data(s.utf8), engine: .assemblyai, options: options(.assemblyai)) } }
        func shint(_ status: Int, _ s: String) -> String { if case .failure(let e) = sparsed(status, s), let x = e as? ASRServiceError { return x.hint }; return "" }
        c("assemblyai: the text, a plain error string and a wrong key", (try? sparsed(200, "{\"text\":\" 你好 \",\"confidence\":0.9}").get()) == "你好" && shint(401, "{\"error\":\"Invalid API key\"}") == L10n.format("batch.err.auth", ASREngine.assemblyai.title) && shint(400, "{\"error\":\"Audio too short\"}").contains("Audio too short"))
        let sk = BatchTranscription.keyCheckRequest(.assemblyai, key: "aai", options: options(.assemblyai))
        c("assemblyai: the key check lists transcripts and sends no audio", sk?.url?.host == "api.assemblyai.com" && sk?.url?.query == "limit=1" && sk?.value(forHTTPHeaderField: "Authorization") == "aai" && sk?.httpBody == nil)

        // ElevenLabs
        c("elevenlabs: listed, defaults valid, the language is detected unless named", ASREngine.elevenlabs.uploadsWholeRecording && options(.elevenlabs).model == "scribe_v2" && options(.elevenlabs).language == "multi" && BatchTranscription.validate(.elevenlabs, options(.elevenlabs)) == nil)
        let er = BatchTranscription.request(.elevenlabs, options: options(.elevenlabs) { $0.language = "zh"; $0.hotwords = "Cadenza\nGitHub\nthis phrase has far too many words in it" }, key: "xi-key", pcm: pcm, boundary: "BOUND")
        let eb = body(er)
        c("elevenlabs: the key is a header only, the address is the speech-to-text one", er?.url?.absoluteString == "https://api.elevenlabs.io/v1/speech-to-text" && er?.value(forHTTPHeaderField: "xi-api-key") == "xi-key" && !eb.contains("xi-key") && er?.value(forHTTPHeaderField: "Authorization") == nil)
        c("elevenlabs: model, language, one field per key term, no sound descriptions, the recording as the file",
          eb.contains("name=\"model_id\"\r\n\r\nscribe_v2") && eb.contains("name=\"language_code\"\r\n\r\nzh") && eb.contains("name=\"keyterms\"\r\n\r\nCadenza") && eb.contains("name=\"keyterms\"\r\n\r\nGitHub")
          && !eb.contains("far too many") && eb.contains("name=\"tag_audio_events\"\r\n\r\nfalse") && eb.contains("name=\"file\"; filename=\"speech.wav\""))
        let eOld = body(BatchTranscription.request(.elevenlabs, options: options(.elevenlabs) { $0.model = "scribe_v1"; $0.hotwords = "Cadenza" }, key: "k", pcm: pcm, boundary: "B"))
        c("elevenlabs: the older model gets no key terms, and auto-detection sends no language", !eOld.contains("name=\"keyterms\"") && !body(BatchTranscription.request(.elevenlabs, options: options(.elevenlabs), key: "k", pcm: pcm, boundary: "B")).contains("name=\"language_code\""))
        func eparsed(_ status: Int, _ s: String) -> Result<String, Error> { Result { try BatchTranscription.parse(status: status, data: Data(s.utf8), engine: .elevenlabs, options: options(.elevenlabs)) } }
        func ehint(_ status: Int, _ s: String) -> String { if case .failure(let e) = eparsed(status, s), let x = e as? ASRServiceError { return x.hint }; return "" }
        c("elevenlabs: the text, a wrong key, a limit and a message that echoes the key", (try? eparsed(200, "{\"text\":\"hello\",\"language_code\":\"eng\"}").get()) == "hello" && ehint(401, "{\"detail\":{\"status\":\"invalid_api_key\"}}") == L10n.format("batch.err.auth", ASREngine.elevenlabs.title)
          && ehint(429, "{}") == L10n.format("batch.err.quota", ASREngine.elevenlabs.title) && !ehint(400, "{\"detail\":{\"message\":\"Invalid key xi-abc\"}}").contains("xi-abc"))
        let ek = BatchTranscription.keyCheckRequest(.elevenlabs, key: "xi", options: options(.elevenlabs))
        c("elevenlabs: the key check lists models with the key header and sends no audio", ek?.url?.path == "/v1/models" && ek?.value(forHTTPHeaderField: "xi-api-key") == "xi" && ek?.httpBody == nil)

        // Through the recorder
        func dictateWith(_ engine: ASREngine, _ http: FakeHTTP) -> ClipResult {
            CloudClipTranscriber.transcribe([Float](repeating: 0.2, count: 16000), provider: engine, options: options(engine), credentials: ["apikey": "k"], language: "zh_cn", speed: 100, timeout: 5,
                                            makeRecorder: { CloudASRRecorder(provider: engine, options: options(engine), credentials: ["apikey": "k"], capture: $0, http: http) })
        }
        let gh = FakeHTTP([(200, Data(goodGoogle.utf8))])
        c("recorder: Google uploads once and its text comes back", dictateWith(.google, gh) == .text("你好世界") && gh.requests.count == 1 && gh.requests[0].url?.host == "speech.googleapis.com")
        let ah = FakeHTTP([(200, Data("{\"RecognitionStatus\":\"Success\",\"DisplayText\":\"你好世界\"}".utf8))])
        c("recorder: Azure uploads once and its text comes back", dictateWith(.azure, ah) == .text("你好世界") && ah.requests.count == 1 && ah.requests[0].url?.host == "eastus.stt.speech.microsoft.com")
        let gd = FakeHTTP([(403, Data("{}".utf8))])
        if case .failed(let why) = dictateWith(.google, gd) { c("recorder: a project without the API is reported with what to do", why == L10n.format("batch.err.googleDenied", ASREngine.google.title)) } else { c("recorder: a project without the API is reported with what to do", false) }

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
        var withAzure = vocab; withAzure.sendToCloud = true
        c("vocabulary: Google gets the terms as phrases, Azure takes none", VocabularyHotwords.apply(.google, to: options(.google), settings: withAzure, store: store).hotwords == "Kubernetes" && VocabularyHotwords.apply(.azure, to: options(.azure), settings: withAzure, store: store).hotwords == "")
        c("vocabulary: AssemblyAI and ElevenLabs get the terms", VocabularyHotwords.apply(.assemblyai, to: options(.assemblyai), settings: withAzure, store: store).hotwords == "Kubernetes" && VocabularyHotwords.apply(.elevenlabs, to: options(.elevenlabs), settings: withAzure, store: store).hotwords == "Kubernetes")
        c("vocabulary: nothing is added unless the person allowed sending it", VocabularyHotwords.apply(.openai, to: options(.openai), settings: vocab, store: store).hotwords == "")
        var zh = CloudASROptions(); zh.language = "zh"; zh.hotwords = BatchTranscription.simplifiedHint + "\nGitHub"
        c("Whisper-style: Simplified is asked for and an answer in Traditional is converted", BatchTranscription.scriptFixed("寶寶，你想說玩過這個東西嗎", options: zh) == "宝宝，你想说玩过这个东西吗" && BatchTranscription.scriptFixed("寶寶", options: CloudASROptions()) == "寶寶")
        c("Whisper-style: the app set to Chinese names the language and the script; other languages are left alone",
          BatchTranscription.chineseHint(recognitionLocale: "zh-CN") == BatchTranscription.simplifiedHint && BatchTranscription.chineseHint(recognitionLocale: "zh_TW") == BatchTranscription.traditionalHint && BatchTranscription.chineseHint(recognitionLocale: "en-US") == nil)
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
