import Foundation

// Speech recognition by services that take a whole recording and answer with its text: the OpenAI transcription API and the
// services that copy it (Groq and others), Google Cloud Speech-to-Text, Microsoft Azure Speech, AssemblyAI and ElevenLabs. The recording is sent once,
// when the key is released.

enum BatchTranscription {
    struct Service {
        let endpoint: String
        let modelsEndpoint: String
        let models: [String]
        let defaultModel: String
    }
    static func service(_ engine: ASREngine) -> Service? {
        switch engine {
        case .openai:
            return Service(endpoint: "https://api.openai.com/v1/audio/transcriptions", modelsEndpoint: "https://api.openai.com/v1/models",
                           models: ["gpt-4o-mini-transcribe", "gpt-4o-transcribe", "whisper-1"], defaultModel: "gpt-4o-mini-transcribe")
        case .groq:
            return Service(endpoint: "https://api.groq.com/openai/v1/audio/transcriptions", modelsEndpoint: "https://api.groq.com/openai/v1/models",
                           models: ["whisper-large-v3", "whisper-large-v3-turbo"], defaultModel: "whisper-large-v3")
        case .compat:
            // The address and the model are the person's own (see `compatPresets`).
            return Service(endpoint: "", modelsEndpoint: "", models: [], defaultModel: "")
        case .assemblyai:
            // The short-clip API answers in the same call; the key check uses the main API, which lists transcripts.
            return Service(endpoint: "https://sync.assemblyai.com/v1/transcribe/live", modelsEndpoint: "https://api.assemblyai.com/v2/transcript?limit=1", models: ["universal-3-5-pro"], defaultModel: "universal-3-5-pro")
        case .elevenlabs:
            return Service(endpoint: "https://api.elevenlabs.io/v1/speech-to-text", modelsEndpoint: "https://api.elevenlabs.io/v1/models", models: ["scribe_v2", "scribe_v1"], defaultModel: "scribe_v2")
        case .google:
            return Service(endpoint: "https://speech.googleapis.com/v1/speech:recognize", modelsEndpoint: "", models: ["default", "latest_short", "latest_long"], defaultModel: "default")
        case .azure:
            // The address comes from the region (or the resource address) the person gave; see `azureEndpoints`.
            return Service(endpoint: "", modelsEndpoint: "", models: [], defaultModel: "")
        default:
            return nil
        }
    }

    /// Services that copy the OpenAI transcription API, with the address and model each documents. The person can still type any other.
    struct Preset: Identifiable { let id: String; let title: String; let baseURL: String; let model: String }
    static let compatPresets: [Preset] = [
        Preset(id: "together", title: "Together AI", baseURL: "https://api.together.xyz/v1", model: "openai/whisper-large-v3"),
        Preset(id: "mistral", title: "Mistral (Voxtral)", baseURL: "https://api.mistral.ai/v1", model: "voxtral-mini-latest"),
        Preset(id: "siliconflow", title: "SiliconFlow", baseURL: "https://api.siliconflow.cn/v1", model: "FunAudioLLM/SenseVoiceSmall"),
    ]
    static func preset(forBaseURL base: String) -> Preset? { compatPresets.first { $0.baseURL == base.trimmingCharacters(in: .whitespaces) } }

    /// Where the recording goes: a fixed address for OpenAI and Groq, the person's own address (plus the transcription path) otherwise.
    static func endpointURL(_ engine: ASREngine, _ o: CloudASROptions) -> URL? {
        if engine == .azure { return azureEndpoints(o.region)?.recognize }
        return engine == .compat ? LLMEndpoint.resolve(o.baseURL, "/audio/transcriptions") : service(engine).flatMap { URL(string: $0.endpoint) }
    }

    /// Azure takes either the region of the Speech resource ("eastus") or the address of the resource from the Azure portal.
    /// An address must be https on a Microsoft cloud host, so a typo cannot send the key somewhere else.
    static func azureEndpoints(_ place: String) -> (recognize: URL, token: URL)? {
        let p = place.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.range(of: "^[a-z0-9]{3,30}$", options: .regularExpression) != nil {
            guard let r = URL(string: "https://\(p).stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1"),
                  let t = URL(string: "https://\(p).api.cognitive.microsoft.com/sts/v1.0/issueToken") else { return nil }
            return (r, t)
        }
        guard let parts = URLComponents(string: p), parts.scheme?.lowercased() == "https", let host = parts.host?.lowercased(), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              ["azure.com", "azure.cn", "azure.us", "microsoft.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        guard let r = URL(string: "https://\(host)/stt/speech/recognition/conversation/cognitiveservices/v1"), let t = URL(string: "https://\(host)/sts/v1.0/issueToken") else { return nil }
        return (r, t)
    }

    /// Google and Azure need the language named; OpenAI-style services can detect it. "yue" is Cantonese.
    static let explicitLanguages = languages.filter { $0 != "multi" } + ["yue"]
    /// What AssemblyAI's short-clip model covers of the languages listed here (it assumes English when none is named).
    static let assemblyLanguages = ["en", "zh", "ja", "es", "fr", "de", "pt", "it", "nl", "ar", "hi", "tr", "vi"]
    static func languageChoices(_ engine: ASREngine) -> [String] {
        switch engine {
        case .google, .azure: return explicitLanguages
        case .assemblyai: return assemblyLanguages
        default: return languages
        }
    }
    private static let regionalCodes: [String: (google: String, azure: String)] = [
        "zh": ("cmn-Hans-CN", "zh-CN"), "yue": ("yue-Hant-HK", "zh-HK"), "en": ("en-US", "en-US"), "ja": ("ja-JP", "ja-JP"), "ko": ("ko-KR", "ko-KR"),
        "es": ("es-ES", "es-ES"), "fr": ("fr-FR", "fr-FR"), "de": ("de-DE", "de-DE"), "ru": ("ru-RU", "ru-RU"), "pt": ("pt-BR", "pt-BR"), "it": ("it-IT", "it-IT"),
        "ar": ("ar-SA", "ar-SA"), "hi": ("hi-IN", "hi-IN"), "th": ("th-TH", "th-TH"), "vi": ("vi-VN", "vi-VN"), "id": ("id-ID", "id-ID"), "tr": ("tr-TR", "tr-TR"),
        "nl": ("nl-NL", "nl-NL"), "pl": ("pl-PL", "pl-PL"), "uk": ("uk-UA", "uk-UA"),
    ]
    static func regionalCode(_ engine: ASREngine, _ language: String) -> String? { regionalCodes[language].map { engine == .google ? $0.google : $0.azure } }

    static func modelsURL(_ engine: ASREngine, _ o: CloudASROptions) -> URL? {
        guard engine == .compat else { return service(engine).flatMap { URL(string: $0.modelsEndpoint) } }
        guard let url = endpointURL(engine, o), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = String(parts.path.dropLast("/audio/transcriptions".count)) + "/models"
        return parts.url
    }
    /// The name the person sees for where the audio goes.
    static func destination(_ engine: ASREngine, _ o: CloudASROptions) -> String {
        engine == .compat || engine == .azure ? (endpointURL(engine, o)?.host ?? engine.title) : engine.title
    }

    /// "multi" lets the service tell the language; otherwise an ISO 639-1 code from this list.
    static let languages = ["multi", "zh", "en", "ja", "ko", "es", "fr", "de", "ru", "pt", "it", "ar", "hi", "th", "vi", "id", "tr", "nl", "pl", "uk"]
    static let promptLimit = 600

    static func validate(_ engine: ASREngine, _ o: CloudASROptions) -> String? {
        guard let service = service(engine), languageChoices(engine).contains(o.language), o.hotwords.count <= promptLimit,
              !o.smoothing, !o.secondPass, o.vocabularyID.isEmpty, o.correctionTableID.isEmpty else { return L10n.tr("batch.invalidOptions") }
        switch engine {
        case .compat: guard validCompat(o) else { return L10n.tr("batch.invalidOptions") }
        case .azure: guard azureEndpoints(o.region) != nil, o.hotwords.isEmpty else { return L10n.tr("batch.invalidOptions") }
        default: guard service.models.contains(o.model) else { return L10n.tr("batch.invalidOptions") }
        }
        return nil
    }

    private static func validCompat(_ o: CloudASROptions) -> Bool {
        endpointURL(.compat, o) != nil && o.model.range(of: "^[A-Za-z0-9._:/@+-]{1,128}$", options: .regularExpression) != nil
    }

    /// 16 kHz mono 16-bit PCM with a WAV header, which every one of these services accepts.
    static func wav(pcm: Data, sampleRate: Int = 16000) -> Data {
        func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        func le16(_ v: Int) -> [UInt8] { (0..<2).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        var header = Data("RIFF".utf8)
        header.append(contentsOf: le32(36 + pcm.count)); header.append(Data("WAVEfmt ".utf8)); header.append(contentsOf: le32(16))
        header.append(contentsOf: le16(1)); header.append(contentsOf: le16(1)); header.append(contentsOf: le32(sampleRate))
        header.append(contentsOf: le32(sampleRate * 2)); header.append(contentsOf: le16(2)); header.append(contentsOf: le16(16))
        header.append(Data("data".utf8)); header.append(contentsOf: le32(pcm.count))
        return header + pcm
    }

    /// A sentence in the wanted script, as the prompt: these models continue in the style of what they were given, which is
    /// the only way to ask for Simplified or Traditional characters. Nil unless the app is set to Chinese.
    static let simplifiedHint = "以下是普通话的句子。", traditionalHint = "以下是普通話的句子。"
    static func chineseHint(recognitionLocale: String) -> String? {
        let l = recognitionLocale.lowercased().replacingOccurrences(of: "_", with: "-")
        guard l == "zh" || l.hasPrefix("zh-") else { return nil }
        return l.contains("tw") || l.contains("hk") || l.contains("hant") ? traditionalHint : simplifiedHint
    }

    /// The prompt alone does not make these models keep to one script (measured: about one answer in three came back in
    /// Traditional characters for Simplified speech), so when Simplified was asked for, the answer is converted.
    static func scriptFixed(_ text: String, options: CloudASROptions) -> String {
        guard options.language == "zh", options.hotwords.hasPrefix(simplifiedHint) else { return text }
        return text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
    }

    /// The vocabulary and the person's own terms, as the short text these models take to favour names and jargon.
    static func prompt(_ hotwords: String) -> String {
        let terms = hotwords.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return String(terms.joined(separator: ", ").prefix(promptLimit))
    }

    static func request(_ engine: ASREngine, options: CloudASROptions, key: String, pcm: Data, boundary: String = "cadenza-" + UUID().uuidString) -> URLRequest? {
        guard validate(engine, options) == nil, !key.isEmpty, key.count <= 4096, !pcm.isEmpty, pcm.count % 2 == 0,
              let url = endpointURL(engine, options) else { return nil }
        if engine == .google { return googleRequest(url: url, options: options, key: key, pcm: pcm) }
        if engine == .azure { return azureRequest(url: url, options: options, key: key, pcm: pcm) }
        // The terms, one per line or comma, as the lists these services take.
        let terms = options.hotwords.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var fields: [(name: String, value: String, json: Bool)] = []
        var filePart = "file"
        var r = URLRequest(url: url)
        switch engine {
        case .assemblyai:
            // The settings come first, as a JSON part; the model is a header.
            var config: [String: Any] = ["language_codes": [options.language]]
            let list = terms.filter { $0.split(separator: " ").count <= 6 }
            if !list.isEmpty { config["keyterms_prompt"] = Array(list.prefix(200)) }
            guard let json = try? JSONSerialization.data(withJSONObject: config) else { return nil }
            fields.append(("config", String(decoding: json, as: UTF8.self), true)); filePart = "audio"
            r.setValue(key, forHTTPHeaderField: "Authorization"); r.setValue(options.model, forHTTPHeaderField: "X-AAI-Model")
        case .elevenlabs:
            fields.append(("model_id", options.model, false))
            if options.language != "multi" { fields.append(("language_code", options.language, false)) }
            // Key terms are a feature of the newer model, at most five words and fifty characters each.
            if options.model == "scribe_v2" { for t in terms where t.count < 50 && t.split(separator: " ").count <= 5 { fields.append(("keyterms", t, false)) } }
            fields.append(("tag_audio_events", "false", false))
            r.setValue(key, forHTTPHeaderField: "xi-api-key")
        default:
            fields += [("model", options.model, false), ("response_format", "json", false), ("temperature", "0", false)]
            if options.language != "multi" { fields.append(("language", options.language, false)) }
            let hint = prompt(options.hotwords)
            if !hint.isEmpty { fields.append(("prompt", hint, false)) }
            r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
        var body = Data()
        for f in fields { body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(f.name)\"\r\n\(f.json ? "Content-Type: application/json\r\n" : "")\r\n\(f.value)\r\n".utf8)) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(filePart)\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav(pcm: pcm)); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        r.httpMethod = "POST"; r.httpBody = body
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 60
        return r
    }

    private static func googleRequest(url: URL, options: CloudASROptions, key: String, pcm: Data) -> URLRequest? {
        guard let code = regionalCode(.google, options.language) else { return nil }
        var config: [String: Any] = ["encoding": "LINEAR16", "sampleRateHertz": 16000, "audioChannelCount": 1, "languageCode": code, "enableAutomaticPunctuation": true, "model": options.model]
        let phrases = options.hotwords.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0.count <= 100 }.prefix(100)
        if !phrases.isEmpty { config["speechContexts"] = [["phrases": Array(phrases)]] }
        guard let body = try? JSONSerialization.data(withJSONObject: ["config": config, "audio": ["content": pcm.base64EncodedString()]]) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"; r.httpBody = body; r.timeoutInterval = 60
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        return r
    }

    private static func azureRequest(url: URL, options: CloudASROptions, key: String, pcm: Data) -> URLRequest? {
        guard let code = regionalCode(.azure, options.language), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // "raw": dictation is typed as it was said, not with words starred out.
        parts.queryItems = [URLQueryItem(name: "language", value: code), URLQueryItem(name: "format", value: "simple"), URLQueryItem(name: "profanity", value: "raw")]
        guard let full = parts.url else { return nil }
        var r = URLRequest(url: full)
        r.httpMethod = "POST"; r.httpBody = wav(pcm: pcm); r.timeoutInterval = 60
        r.setValue("audio/wav; codecs=audio/pcm; samplerate=16000", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        return r
    }

    /// A key check that sends no audio. OpenAI-style services: the model list, which needs the same key. Azure: a token request.
    /// Google: a recognize request with an empty body, which a valid key answers with "invalid argument" and a wrong key does not.
    static func keyCheckRequest(_ engine: ASREngine, key: String, options: CloudASROptions = CloudASROptions()) -> URLRequest? {
        guard !key.isEmpty else { return nil }
        switch engine {
        case .google:
            guard let url = endpointURL(engine, options) else { return nil }
            var r = URLRequest(url: url)
            r.httpMethod = "POST"; r.httpBody = Data("{}".utf8); r.timeoutInterval = 10
            r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
            return r
        case .azure:
            guard let url = azureEndpoints(options.region)?.token else { return nil }
            var r = URLRequest(url: url)
            r.httpMethod = "POST"; r.httpBody = Data(); r.timeoutInterval = 10
            r.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key"); r.setValue("0", forHTTPHeaderField: "Content-Length")
            return r
        default:
            guard let url = modelsURL(engine, options) else { return nil }
            var r = URLRequest(url: url)
            switch engine {
            case .assemblyai: r.setValue(key, forHTTPHeaderField: "Authorization")
            case .elevenlabs: r.setValue(key, forHTTPHeaderField: "xi-api-key")
            default: r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            }
            r.timeoutInterval = 10
            return r
        }
    }

    /// Whether a service's answer to `keyCheckRequest` means the key is good.
    static func keyCheckPassed(_ engine: ASREngine, status: Int, data: Data) -> Bool {
        if engine == .google {
            let text = String(decoding: data.prefix(4096), as: UTF8.self)
            return status == 400 && text.contains("INVALID_ARGUMENT") && !text.contains("API_KEY_INVALID") && !text.lowercased().contains("api key not valid")
        }
        return (200...299).contains(status)
    }

    /// The recognized text, or the reason the service gave in words a person can act on.
    static func parse(status: Int, data: Data, engine: ASREngine, name: String? = nil, options: CloudASROptions = CloudASROptions()) throws -> String {
        guard data.count <= 1_048_576 else { throw ASRFailure.protocolInvalid }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200...299).contains(status) else {
            // OpenAI-style {"error":{"message"}}, AssemblyAI {"error":"…"}, ElevenLabs {"detail":{"message"}}.
            let raw = ((object?["error"] as? [String: Any])?["message"] as? String) ?? (object?["error"] as? String) ?? ((object?["detail"] as? [String: Any])?["message"] as? String) ?? ""
            let detail = String(raw.prefix(160))
            let who = name ?? engine.title
            // Google answers a wrong key with 400, and a project without the API turned on with 403.
            if engine == .google, status == 400, detail.lowercased().contains("api key not valid") { throw ASRServiceError(hint: L10n.format("batch.err.auth", who), code: status) }
            if engine == .google, status == 403 { throw ASRServiceError(hint: L10n.format("batch.err.googleDenied", who), code: status) }
            throw ASRServiceError(hint: describe(status: status, detail: detail, engine: engine, name: name), code: status)
        }
        switch engine {
        case .google:
            let results = (object?["results"] as? [[String: Any]]) ?? []
            let pieces = results.compactMap { ($0["alternatives"] as? [[String: Any]])?.first?["transcript"] as? String }
            // Chinese, Japanese, Cantonese and Thai are written without spaces between sentences.
            let joiner = ["zh", "yue", "ja", "th"].contains(options.language) ? "" : " "
            guard object != nil else { throw ASRFailure.protocolInvalid }
            return pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: joiner)
        case .azure:
            guard let state = object?["RecognitionStatus"] as? String else { throw ASRFailure.protocolInvalid }
            switch state {
            case "Success": return ((object?["DisplayText"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Nothing was recognized: not a failure, and nothing is typed.
            case "NoMatch", "InitialSilenceTimeout", "BabbleTimeout": return ""
            default: throw ASRServiceError(hint: L10n.format("batch.err.server", name ?? engine.title), code: status)
            }
        default:
            guard let text = object?["text"] as? String else { throw ASRFailure.protocolInvalid }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func describe(status: Int, detail: String, engine: ASREngine, name: String? = nil) -> String {
        let name = name ?? engine.title
        switch status {
        case 401, 403: return L10n.format("batch.err.auth", name)
        case 404: return L10n.format("batch.err.model", name)
        case 413: return L10n.format("batch.err.tooLong", name)
        case 429: return L10n.format("batch.err.quota", name)
        case 500...599: return L10n.format("batch.err.server", name)
        default:
            // A service may echo part of the key in its message; such a message is not shown (the log keeps these lines).
            let lowered = detail.lowercased()
            let safe = lowered.contains("key") || lowered.contains("sk-") || lowered.contains("gsk_") || lowered.contains("bearer") ? "" : detail
            return safe.isEmpty ? L10n.format("batch.err.other", name, String(status)) : L10n.format("batch.err.otherDetail", name, String(status), safe)
        }
    }
}
