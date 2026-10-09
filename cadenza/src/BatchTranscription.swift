import Foundation

// Speech recognition by services that take a whole recording and answer with its text: the OpenAI transcription API and the
// services that copy it (Groq). The recording is sent once, when the key is released.

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
                           models: ["whisper-large-v3-turbo", "whisper-large-v3"], defaultModel: "whisper-large-v3-turbo")
        default:
            return nil
        }
    }

    /// "multi" lets the service tell the language; otherwise an ISO 639-1 code from this list.
    static let languages = ["multi", "zh", "en", "ja", "ko", "es", "fr", "de", "ru", "pt", "it", "ar", "hi", "th", "vi", "id", "tr", "nl", "pl", "uk"]
    static let promptLimit = 600

    static func validate(_ engine: ASREngine, _ o: CloudASROptions) -> String? {
        guard let service = service(engine), service.models.contains(o.model), languages.contains(o.language), o.hotwords.count <= promptLimit,
              !o.smoothing, !o.secondPass, o.vocabularyID.isEmpty, o.correctionTableID.isEmpty else { return L10n.tr("batch.invalidOptions") }
        return nil
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

    /// The vocabulary and the person's own terms, as the short text these models take to favour names and jargon.
    static func prompt(_ hotwords: String) -> String {
        let terms = hotwords.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return String(terms.joined(separator: ", ").prefix(promptLimit))
    }

    static func request(_ engine: ASREngine, options: CloudASROptions, key: String, pcm: Data, boundary: String = "cadenza-" + UUID().uuidString) -> URLRequest? {
        guard let service = service(engine), validate(engine, options) == nil, !key.isEmpty, key.count <= 4096, !pcm.isEmpty, pcm.count % 2 == 0,
              let url = URL(string: service.endpoint) else { return nil }
        var fields: [(String, String)] = [("model", options.model), ("response_format", "json"), ("temperature", "0")]
        if options.language != "multi" { fields.append(("language", options.language)) }
        let hint = prompt(options.hotwords)
        if !hint.isEmpty { fields.append(("prompt", hint)) }
        var body = Data()
        for (name, value) in fields { body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav(pcm: pcm)); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var r = URLRequest(url: url)
        r.httpMethod = "POST"; r.httpBody = body
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 60
        return r
    }

    /// A key check that sends no audio: the service's model list, which needs the same key.
    static func keyCheckRequest(_ engine: ASREngine, key: String) -> URLRequest? {
        guard let service = service(engine), !key.isEmpty, let url = URL(string: service.modelsEndpoint) else { return nil }
        var r = URLRequest(url: url)
        r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization"); r.timeoutInterval = 10
        return r
    }

    /// The recognized text, or the reason the service gave in words a person can act on.
    static func parse(status: Int, data: Data, engine: ASREngine) throws -> String {
        guard data.count <= 1_048_576 else { throw ASRFailure.protocolInvalid }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200...299).contains(status) else {
            let detail = ((object?["error"] as? [String: Any])?["message"] as? String).map { String($0.prefix(160)) } ?? ""
            throw ASRServiceError(hint: describe(status: status, detail: detail, engine: engine), code: status)
        }
        guard let text = object?["text"] as? String else { throw ASRFailure.protocolInvalid }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func describe(status: Int, detail: String, engine: ASREngine) -> String {
        let name = engine.title
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
