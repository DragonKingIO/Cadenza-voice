import Foundation

/// Hands the vocabulary to the cloud recognizers that take hot words, at the moment a recording starts. Nothing is saved:
/// the person's own hot-word field stays as it is, and the vocabulary is added to what is sent.
enum VocabularyHotwords {
    static let tencentUserWeight = 8, tencentPackWeight = 5

    /// The options a recording should use. When the result would not be accepted by the provider's own rules, the options come
    /// back unchanged: hot words must never make a dictation fail.
    static func apply(_ engine: ASREngine, to options: CloudASROptions, settings: VocabularySettings, store: VocabularyStore = .shared) -> CloudASROptions {
        guard settings.enabled, settings.sendToCloud, [.volcengine, .tencent, .deepgram].contains(engine) else { return options }
        if engine == .deepgram && !DeepgramAPI.keytermsApply(options.language) { return options }
        let candidates = store.hotwordCandidates(settings)
        guard !candidates.isEmpty else { return options }
        var merged = options
        switch engine {
        case .volcengine:
            var lines = options.hotwords.split(separator: "\n").map(String.init)
            var seen = Set(lines.map { $0.lowercased() })
            for c in candidates where lines.count < 50 && plain(c.term) && c.term.count <= 30 && seen.insert(c.term.lowercased()).inserted { lines.append(c.term) }
            merged.hotwords = lines.joined(separator: "\n")
        case .tencent:
            var entries = options.hotwords.isEmpty ? [] : options.hotwords.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            var seen = Set(entries.map { ($0.split(separator: "|").first.map(String.init) ?? "").lowercased() })
            for c in candidates where entries.count < 128 && tencentWord(c.term) && seen.insert(c.term.lowercased()).inserted {
                entries.append("\(c.term)|\(c.user ? tencentUserWeight : tencentPackWeight)")
            }
            merged.hotwords = entries.joined(separator: ",")
        default:   // Deepgram: one key term per line
            var lines = options.hotwords.split(separator: "\n").map(String.init)
            var seen = Set(lines.map { $0.lowercased() })
            for c in candidates where lines.count < 100 && plain(c.term) && c.term.count <= 60 && seen.insert(c.term.lowercased()).inserted { lines.append(c.term) }
            merged.hotwords = lines.joined(separator: "\n")
        }
        return ASROptionPolicy.validate(engine, merged) == nil ? merged : options
    }

    /// No separators any provider uses.
    static func plain(_ term: String) -> Bool { !term.isEmpty && !term.contains { $0 == "," || $0 == "|" || $0.isNewline } }
    /// Tencent: letters, digits and Chinese characters only, at most 30 characters and 10 Chinese ones, no spaces.
    static func tencentWord(_ term: String) -> Bool {
        term.count <= 30 && term.allSatisfy { $0.isLetter || $0.isNumber } && term.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count <= 10
    }
}
