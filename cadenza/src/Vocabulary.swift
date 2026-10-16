import AppKit
import Foundation

// A vocabulary of terms (product names, code names, jargon) that speech recognizers often get wrong. It works on the text
// after recognition, for every engine alike, and is also handed to AI polish as a glossary. Everything runs on this Mac.
//
// Three kinds of fixes, all exact enough to be safe:
//  - an alias the person (or a pack) listed for a term ("吉特哈勃" -> GitHub);
//  - an English term written apart or in the wrong case ("git hub", "github" -> GitHub, "node js" -> Node.js);
//  - a Chinese term written with other characters that sound the same (same pinyin, tones ignored);
//  - a Chinese alias of a term (a transliteration such as "拖肯" for token) heard as other characters that sound the same;
//  - an English term misheard as a non-word that is one sound-alike slip away ("gbt" -> GPT, "opvs" -> Opus).

struct VocabEntry: Codable, Equatable, Hashable {
    var term: String
    var aliases: [String] = []
    init(term: String, aliases: [String] = []) { self.term = term; self.aliases = aliases }
    enum CodingKeys: String, CodingKey { case term, aliases }
    init(from decoder: Decoder) throws {
        let d = try decoder.container(keyedBy: CodingKeys.self)
        term = try d.decode(String.self, forKey: .term)
        aliases = (try? d.decodeIfPresent([String].self, forKey: .aliases)) ?? []
    }
}

/// A shared list of terms, shipped in the app (`cadenza/vocab/*.json`) and open to contributions.
struct VocabPack: Codable, Equatable {
    var schema = 1
    var id: String
    var name: [String: String]
    var description: [String: String] = [:]
    var license: String
    /// Whether the pack is on until the person switches it off.
    var enabledByDefault = false
    var entries: [VocabEntry]

    enum CodingKeys: String, CodingKey { case schema, id, name, description, license, enabledByDefault = "default", entries }
    init(id: String, name: [String: String], license: String = "CC0-1.0", entries: [VocabEntry]) { self.id = id; self.name = name; self.license = license; self.entries = entries }
    init(from decoder: Decoder) throws {
        let d = try decoder.container(keyedBy: CodingKeys.self)
        schema = (try? d.decodeIfPresent(Int.self, forKey: .schema)) ?? 1
        id = try d.decode(String.self, forKey: .id)
        name = try d.decode([String: String].self, forKey: .name)
        description = (try? d.decodeIfPresent([String: String].self, forKey: .description)) ?? [:]
        license = try d.decode(String.self, forKey: .license)
        enabledByDefault = (try? d.decodeIfPresent(Bool.self, forKey: .enabledByDefault)) ?? false
        entries = try d.decode([VocabEntry].self, forKey: .entries)
    }
    func localizedName(_ language: String) -> String { name[language] ?? name["en"] ?? id }
    func localizedDescription(_ language: String) -> String { description[language] ?? description["en"] ?? "" }
}

struct VocabularySettings: Codable, Equatable {
    var enabled = true
    /// Give the terms to a cloud recognizer that accepts hot words, together with the recording. Only the service that already
    /// gets the recording (the one the person consented to) receives them.
    var sendToCloud = true
    /// Packs the person switched on or off, against each pack's own default.
    var packOverrides: [String: Bool] = [:]
    init() {}
    enum CodingKeys: String, CodingKey { case enabled, sendToCloud, packOverrides }
    init(from decoder: Decoder) throws {
        let d = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? d.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        sendToCloud = (try? d.decodeIfPresent(Bool.self, forKey: .sendToCloud)) ?? true
        packOverrides = (try? d.decodeIfPresent([String: Bool].self, forKey: .packOverrides)) ?? [:]
    }
    func isOn(_ pack: VocabPack) -> Bool { packOverrides[pack.id] ?? pack.enabledByDefault }
}

enum VocabularyRules {
    static let allowedLicenses: Set<String> = ["CC0-1.0", "CC-BY-4.0", "MIT"]
    static let maxEntriesPerPack = 5000
    static let maxUserEntries = 2000

    static func validTerm(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 60 && s == s.trimmingCharacters(in: .whitespacesAndNewlines) && !s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0 == "`" }
    }
    /// The reason an entry is not acceptable, or nil.
    static func problem(_ e: VocabEntry) -> String? {
        guard validTerm(e.term) else { return "term" }
        guard e.aliases.count <= 12, e.aliases.allSatisfy(validTerm) else { return "alias" }
        let lowered = e.aliases.map { $0.lowercased() }
        guard Set(lowered).count == lowered.count, !lowered.contains(e.term.lowercased()) else { return "duplicate-alias" }
        return nil
    }
    /// The first alias of an entry the person is adding that would rewrite ordinary sentences, or nil.
    static func unsafeAlias(_ e: VocabEntry) -> String? {
        e.aliases.first { !VocabularyMatcher.usableAlias($0, fromUser: true) }
    }
    static func problem(_ p: VocabPack) -> String? {
        guard p.schema == 1 else { return "schema" }
        guard p.id.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil, p.id.count <= 40 else { return "id" }
        guard p.name["en"]?.isEmpty == false, p.name.values.allSatisfy({ $0.count <= 60 }), p.description.values.allSatisfy({ $0.count <= 300 }) else { return "name" }
        guard allowedLicenses.contains(p.license) else { return "license" }
        guard !p.entries.isEmpty, p.entries.count <= maxEntriesPerPack else { return "size" }
        var seen = Set<String>()
        for e in p.entries {
            if let reason = problem(e) { return "\(e.term): \(reason)" }
            guard seen.insert(e.term.lowercased()).inserted else { return "\(e.term): duplicate-term" }
        }
        return nil
    }
}

/// One term with where it came from. A term the person typed is trusted more than one from a shared pack.
struct VocabTerm: Equatable {
    var term: String
    var aliases: [String]
    var fromUser: Bool
}

enum VocabularyMatcher {
    private struct Hit { var range: NSRange; var replacement: String }

    // MARK: Pinyin

    private static let pinyinLock = NSLock()
    private static var pinyinCache: [Character: String] = [:]
    /// The pinyin of one Chinese character without tones, or nil for anything else. Polyphonic characters get their usual reading.
    static func pinyin(_ ch: Character) -> String? {
        guard ch.unicodeScalars.allSatisfy({ (0x4E00...0x9FFF).contains($0.value) }) else { return nil }
        pinyinLock.lock(); defer { pinyinLock.unlock() }
        if let cached = pinyinCache[ch] { return cached.isEmpty ? nil : cached }
        let m = NSMutableString(string: String(ch))
        var result = ""
        if CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false), CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false) {
            let s = (m as String).lowercased()
            if s != String(ch) { result = s }
        }
        pinyinCache[ch] = result
        return result.isEmpty ? nil : result
    }
    static func pinyinKey(_ s: String) -> String? {
        var parts: [String] = []
        for ch in s { guard let p = pinyin(ch) else { return nil }; parts.append(p) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
    private static func isAllHan(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { pinyin($0) != nil } }

    /// The pinyin key with the front/back nasal finals merged (en/eng, in/ing). Recognizers write "拖坑" for "拖肯"; a
    /// transliteration of a foreign word is the one place where that slip is common enough to be worth matching.
    static func fuzzyPinyinKey(_ s: String) -> String? {
        guard let key = pinyinKey(s) else { return nil }
        return key.split(separator: " ").map { syllable -> String in
            let t = String(syllable)
            return t.hasSuffix("eng") || t.hasSuffix("ing") ? String(t.dropLast()) : t
        }.joined(separator: " ")
    }

    // MARK: Sound-alike Latin tokens

    /// Letter pairs a recognizer or a listener mixes up: voiced/unvoiced consonants and a few look- or sound-alikes.
    private static let confusable: Set<String> = ["bp", "dt", "gk", "fv", "sz", "uv", "vw", "ck", "cs", "mn", "lr", "iy"]
    private static func confusable(_ a: Character, _ b: Character) -> Bool {
        confusable.contains(String([a, b])) || confusable.contains(String([b, a]))
    }

    /// True when `token` is an English word the system dictionary knows. Only answered on the main thread (the spell
    /// checker is an AppKit object); elsewhere the answer is "yes", which keeps the rule from firing.
    static var isKnownEnglishWord: (String) -> Bool = { token in
        guard Thread.isMainThread else { return true }
        let range = NSSpellChecker.shared.checkSpelling(of: token, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }

    /// Damerau-Levenshtein distance (adjacent swaps count once).
    static func slipDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[a.count][b.count]
    }

    private static func isSubsequence(_ small: [Character], of big: [Character]) -> Bool {
        var i = 0
        for ch in big where i < small.count && ch == small[i] { i += 1 }
        return i == small.count
    }

    /// Whether `token` (lower-case letters) is a plausible mis-hearing of `key` (lower-case letters, one word).
    /// A short name one letter away from an ordinary name or word is not evidence of a slip, so four-letter terms accept
    /// only a swap of two letters that are easily mixed up.
    static func soundsLike(_ token: String, _ key: String) -> Bool {
        let a = Array(token), b = Array(key)
        guard a.count >= 3, b.count >= 3, a.first == b.first, a != b else { return false }
        if b.count == 3 {
            // An acronym: only one confusable consonant ("gbt" for GPT), and no vowel to make it a word.
            guard a.count == 3, !a.contains(where: { "aeiou".contains($0) }) else { return false }
            let diff = (0..<3).filter { a[$0] != b[$0] }
            return diff.count == 1 && confusable(a[diff[0]], b[diff[0]])
        }
        let distance = slipDistance(a, b)
        if distance == 1 {
            if a.count == b.count {
                let diff = (0..<a.count).filter { a[$0] != b[$0] }
                if diff.count == 1 { return confusable(a[diff[0]], b[diff[0]]) }
                return b.count >= 5   // two neighbours swapped
            }
            return b.count >= 5       // one letter dropped or added
        }
        // Two extra letters inside a name of five or more ("lininux" for Linux): the term is still all there, in order.
        return b.count >= 5 && a.count == b.count + 2 && a.last == b.last && isSubsequence(b, of: a)
    }

    // MARK: Aliases that would rewrite ordinary sentences

    /// The most frequent Han characters. An alias made only of them is an everyday phrase ("你那个", "家还"), not a mishearing.
    private static let commonHan: Set<Character> = Set("的一是不了人我在有他这中大来上国个到说们为子和你地出道也时年得就那要下以生会自着去之过家学对可她里后小么心多天而能好都然没日于起还发成事只作当想看文无开手十用主行方又如前所本见经头面公同三已老从动两长知民样现分很种实"
        + "给什么吗呢吧啊嗯哦呃但是因为所以如果还是已经可以不是没有就是这样那样一个一下一些自己他们她们我们你们什么时候怎么这些那些")
    /// Everyday English words. A single one of them as an alias would rewrite every sentence that really says it.
    private static let commonEnglish: Set<String> = ["the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one", "our", "out", "day", "get", "has",
        "him", "his", "how", "man", "new", "now", "old", "see", "two", "way", "who", "boy", "did", "its", "let", "put", "say", "she", "too", "use", "open", "up", "go", "on", "in", "it",
        "is", "to", "of", "at", "be", "do", "so", "we", "me", "my", "or", "an", "as", "by", "if", "no", "up", "us", "this", "that", "with", "from", "have", "they", "will", "your", "what",
        "when", "make", "like", "time", "just", "know", "take", "people", "into", "year", "good", "some", "could", "them", "other", "than", "then", "look", "only", "come", "over", "think",
        "also", "back", "after", "work", "first", "well", "even", "want", "because", "give", "most", "need", "should", "very", "much", "more", "here", "there", "where", "which", "about",
        "would", "their", "been", "were", "said", "each", "many", "these", "those", "play", "run", "set", "show", "start", "stop", "close", "close", "read", "write", "call", "find",
        "keep", "turn", "move", "live", "help", "ask", "tell", "try", "feel", "leave", "mean", "high", "long", "great", "little", "own", "same", "big", "small", "large", "next", "last"]

    /// Whether a saved alias may rewrite text. A mishearing is never a single Han character, a one- or two-letter string, an
    /// everyday English word (from the person's own list) or a Han phrase of only the commonest characters; such an alias
    /// would change correct sentences, so it is ignored, whoever added it.
    static func usableAlias(_ alias: String, fromUser: Bool) -> Bool {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let hasLatin = trimmed.unicodeScalars.contains { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
        let hanCount = trimmed.filter { pinyin($0) != nil }.count
        if hanCount > 0 && !hasLatin {
            if trimmed.count < 2 { return false }
            if fromUser && trimmed.allSatisfy({ commonHan.contains($0) }) { return false }
            return true
        }
        let letters = trimmed.filter { $0.isLetter || $0.isNumber }
        if hanCount == 0 {
            if letters.count < 3 { return false }
            let words = trimmed.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            if fromUser, words.count == 1, commonEnglish.contains(words[0]) { return false }
            if fromUser, words.count > 1, words.allSatisfy({ commonEnglish.contains($0) }) { return false }
        }
        return true
    }

    // MARK: Matching

    /// Replaces mis-recognized terms. Links, e-mail addresses and `code` are left alone.
    static func apply(_ text: String, terms: [VocabTerm]) -> String {
        guard !terms.isEmpty, !text.isEmpty else { return text }
        return TextPolish.mapUnprotected(text) { segment in correct(segment, terms: terms) }
    }

    private static func correct(_ text: String, terms: [VocabTerm]) -> String {
        let ns = text as NSString
        var hits: [Hit] = []

        // 1. Aliases
        for t in terms {
            for alias in t.aliases where alias.lowercased() != t.term.lowercased() && usableAlias(alias, fromUser: t.fromUser) {
                let escaped = NSRegularExpression.escapedPattern(for: alias).replacingOccurrences(of: " ", with: "[ \\t]+")
                let ascii = alias.unicodeScalars.allSatisfy { $0.isASCII }
                let pattern = ascii ? "(?<![A-Za-z0-9])" + escaped + "(?![A-Za-z0-9])" : escaped
                guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
                for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) { hits.append(Hit(range: m.range, replacement: t.term)) }
            }
        }

        // 2. English terms written apart, joined by a hyphen or in the wrong case
        let squashed = terms.compactMap { t -> (String, VocabTerm)? in
            guard t.term.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
            let key = squash(t.term)
            return key.count >= 3 ? (key, t) : nil
        }
        if !squashed.isEmpty, let tokenRE = try? NSRegularExpression(pattern: "[A-Za-z0-9]+") {
            let tokens = tokenRE.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
            var byKey: [String: VocabTerm] = [:]
            for (k, t) in squashed where byKey[k] == nil { byKey[k] = t }
            for i in tokens.indices {
                var windowEnd = i
                for length in 1...4 {
                    let j = i + length - 1
                    guard j < tokens.count else { break }
                    if j > i {
                        // Tokens belong together only when a single space or hyphen separates them.
                        let gap = NSRange(location: tokens[j - 1].location + tokens[j - 1].length, length: tokens[j].location - (tokens[j - 1].location + tokens[j - 1].length))
                        guard gap.length == 1, [" ", "-"].contains(ns.substring(with: gap)) else { break }
                    }
                    windowEnd = j
                    let range = NSRange(location: tokens[i].location, length: tokens[windowEnd].location + tokens[windowEnd].length - tokens[i].location)
                    let spoken = ns.substring(with: range)
                    guard let t = byKey[squash(spoken)], spoken != t.term else { continue }
                    // Part of an address or a path (github.com, user@github, /github/) is not a mention of the name.
                    let after = range.location + range.length
                    if after < ns.length, ns.substring(with: NSRange(location: after, length: 1)) == "/" { continue }
                    if after + 1 < ns.length, ns.substring(with: NSRange(location: after, length: 1)) == ".", let next = ns.substring(with: NSRange(location: after + 1, length: 1)).unicodeScalars.first, CharacterSet.alphanumerics.contains(next), next.isASCII { continue }
                    if range.location > 0, ["@", "/", "."].contains(ns.substring(with: NSRange(location: range.location - 1, length: 1))) { continue }
                    // One token that only differs in case is fixed for names with a capital inside or a digit (GitHub, iOS, k8s);
                    // a plain word (React, Swift, Go) is left alone unless the person added it themselves.
                    if length == 1 && !t.fromUser && !isMixedCase(t.term) { continue }
                    hits.append(Hit(range: range, replacement: t.term))
                }
            }
        }

        // 2b. A Latin token that is no English word, one sound-alike slip away from exactly one single-word term
        let singles = terms.compactMap { t -> (String, VocabTerm)? in
            guard t.term.unicodeScalars.allSatisfy({ $0.isASCII }), !t.term.contains(where: { $0 == " " || $0 == "-" || $0 == "." }) else { return nil }
            let key = squash(t.term)
            return key.count >= 3 && key.count <= 12 && key.allSatisfy({ $0.isLetter }) ? (key, t) : nil
        }
        if !singles.isEmpty, let wordRE = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9])[A-Za-z]{3,14}(?![A-Za-z0-9])") {
            for m in wordRE.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let spoken = ns.substring(with: m.range)
                let token = spoken.lowercased()
                if singles.contains(where: { $0.0 == token }) { continue }
                let after = m.range.location + m.range.length
                if after < ns.length, ["/", "."].contains(ns.substring(with: NSRange(location: after, length: 1))) { continue }
                if m.range.location > 0, ["@", "/", "."].contains(ns.substring(with: NSRange(location: m.range.location - 1, length: 1))) { continue }
                let near = singles.filter { soundsLike(token, $0.0) }
                guard near.count == 1, let target = near.first?.1, !isKnownEnglishWord(token) else { continue }
                hits.append(Hit(range: m.range, replacement: target.term))
            }
        }

        // 3. Chinese terms written with other characters that sound the same. A canonical Han term matches by its pinyin;
        // a Han alias of any term (the person's own from two characters, a pack's from three) also matches when the
        // recognizer wrote other characters of the same sound, with the nasal finals en/eng and in/ing merged.
        struct HanKey { var length: Int; var key: String; var fuzzy: Bool; var term: VocabTerm }
        var han: [HanKey] = []
        for t in terms {
            if isAllHan(t.term), t.term.count >= (t.fromUser ? 2 : 3), t.term.count <= 8, let key = pinyinKey(t.term) {
                han.append(HanKey(length: t.term.count, key: key, fuzzy: false, term: t))
            }
            for alias in t.aliases where isAllHan(alias) && alias != t.term && alias.count >= (t.fromUser ? 2 : 3) && alias.count <= 8 && usableAlias(alias, fromUser: t.fromUser) {
                if let key = fuzzyPinyinKey(alias) { han.append(HanKey(length: alias.count, key: key, fuzzy: true, term: t)) }
            }
        }
        if !han.isEmpty {
            let chars = Array(text.utf16)
            var index = 0
            while index < chars.count {
                // A run of Han characters
                var end = index
                while end < chars.count, let scalar = UnicodeScalar(chars[end]), (0x4E00...0x9FFF).contains(scalar.value) { end += 1 }
                if end > index {
                    let runString = String(utf16CodeUnits: Array(chars[index..<end]), count: end - index)
                    let runChars = Array(runString)
                    for h in han where runChars.count >= h.length {
                        for start in 0...(runChars.count - h.length) {
                            let window = String(runChars[start..<(start + h.length)])
                            guard window != h.term.term, (h.fuzzy ? fuzzyPinyinKey(window) : pinyinKey(window)) == h.key else { continue }
                            let prefix = String(runChars[0..<start]).utf16.count
                            hits.append(Hit(range: NSRange(location: index + prefix, length: window.utf16.count), replacement: h.term.term))
                        }
                    }
                    index = end
                } else { index += 1 }
            }
        }

        guard !hits.isEmpty else { return text }
        // Earlier first, longer first; drop what overlaps.
        hits.sort { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length }
        var out = "", cursor = 0
        for h in hits where h.range.location >= cursor {
            out += ns.substring(with: NSRange(location: cursor, length: h.range.location - cursor)) + h.replacement
            cursor = h.range.location + h.range.length
        }
        return out + ns.substring(from: cursor)
    }

    static func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
    /// A name with a capital after its first letter, or a digit: GitHub, iOS, k8s, OpenAI. Not React, Swift or Go.
    static func isMixedCase(_ s: String) -> Bool {
        s.dropFirst().contains { $0.isUppercase } || s.contains { $0.isNumber } || s.contains { !$0.isLetter && !$0.isNumber && $0 != " " }
    }
}

/// Packs shipped in the app plus the person's own terms.
final class VocabularyStore {
    static let shared = VocabularyStore()

    private let lock = NSLock()
    private var packsStorage: [VocabPack] = []
    private var userStorage: [VocabEntry] = []
    private var loaded = false
    var userFile: URL = AppPaths.supportDir.appendingPathComponent("vocabulary.json")
    /// Tests and previews set this to avoid the real files.
    var packDirectories: [URL] = VocabularyStore.defaultPackDirectories()

    static func defaultPackDirectories() -> [URL] {
        var urls: [URL] = []
        if let resource = Bundle.main.resourceURL { urls.append(resource.appendingPathComponent("vocab", isDirectory: true)) }
        // Running from a checkout: the repository copy.
        urls.append(URL(fileURLWithPath: "vocab", isDirectory: true))
        urls.append(URL(fileURLWithPath: "cadenza/vocab", isDirectory: true))
        return urls
    }

    var packs: [VocabPack] { ensureLoaded(); lock.lock(); defer { lock.unlock() }; return packsStorage }
    var user: [VocabEntry] { ensureLoaded(); lock.lock(); defer { lock.unlock() }; return userStorage }

    func reload() { lock.lock(); loaded = false; lock.unlock(); ensureLoaded() }

    private func ensureLoaded() {
        lock.lock(); defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        var found: [VocabPack] = []
        for dir in packDirectories {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url), data.count <= 4_000_000, let pack = try? JSONDecoder().decode(VocabPack.self, from: data),
                      VocabularyRules.problem(pack) == nil, !found.contains(where: { $0.id == pack.id }) else { continue }
                found.append(pack)
            }
            if !found.isEmpty { break }
        }
        packsStorage = found
        userStorage = (try? Data(contentsOf: userFile)).flatMap { try? JSONDecoder().decode(UserFile.self, from: $0) }?.entries.filter { VocabularyRules.problem($0) == nil } ?? []
    }

    private struct UserFile: Codable { var schema = 1; var entries: [VocabEntry] }

    /// Replaces the person's terms and writes them. Returns false when something is not acceptable or the file cannot be written.
    @discardableResult func setUser(_ entries: [VocabEntry]) -> Bool {
        guard entries.count <= VocabularyRules.maxUserEntries, entries.allSatisfy({ VocabularyRules.problem($0) == nil }),
              Set(entries.map { $0.term.lowercased() }).count == entries.count else { return false }
        ensureLoaded()
        guard let data = try? JSONEncoder().encode(UserFile(entries: entries)) else { return false }
        do {
            try FileManager.default.createDirectory(at: userFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: userFile, options: .atomic)
        } catch { return false }
        lock.lock(); userStorage = entries; lock.unlock()
        return true
    }

    func terms(_ settings: VocabularySettings) -> [VocabTerm] {
        guard settings.enabled else { return [] }
        var out = user.map { VocabTerm(term: $0.term, aliases: $0.aliases, fromUser: true) }
        var position = Dictionary(uniqueKeysWithValues: out.enumerated().map { ($1.term.lowercased(), $0) })
        for pack in packs where settings.isOn(pack) {
            for e in pack.entries {
                if let i = position[e.term.lowercased()] {
                    // The person's spelling of the term wins; the pack's aliases still help.
                    for a in e.aliases where !out[i].aliases.contains(where: { $0.lowercased() == a.lowercased() }) { out[i].aliases.append(a) }
                } else {
                    position[e.term.lowercased()] = out.count
                    out.append(VocabTerm(term: e.term, aliases: e.aliases, fromUser: false))
                }
            }
        }
        return out
    }

    /// Terms to hand to a recognizer before it starts: the person's own first, then pack terms that have aliases (the ones
    /// recognizers get wrong most), then the rest.
    func hotwordCandidates(_ settings: VocabularySettings) -> [(term: String, user: Bool)] {
        guard settings.enabled else { return [] }
        var out: [(term: String, user: Bool)] = user.map { ($0.term, true) }
        var seen = Set(out.map { $0.term.lowercased() })
        let entries = packs.filter { settings.isOn($0) }.flatMap(\.entries)
        for e in entries.filter({ !$0.aliases.isEmpty }) + entries.filter({ $0.aliases.isEmpty }) where seen.insert(e.term.lowercased()).inserted { out.append((e.term, false)) }
        return out
    }

    func apply(_ text: String, _ settings: VocabularySettings) -> String { VocabularyMatcher.apply(text, terms: terms(settings)) }

    /// Terms worth telling a language model about: all of the person's own, and the pack terms that occur in this text.
    func glossary(for text: String, _ settings: VocabularySettings, limit: Int = 60) -> [String] {
        guard limit > 0 else { return [] }
        let all = terms(settings)
        let lowered = text.lowercased()
        var out: [String] = []
        for t in all where t.fromUser { out.append(t.term) }
        for t in all where !t.fromUser && lowered.contains(t.term.lowercased()) && !out.contains(t.term) { out.append(t.term) }
        // A misspelled English name in mixed speech cannot select its own correct
        // spelling by exact substring. Supply a bounded, balanced set of enabled
        // pack names as hints to polish; never turn these hints into replacements.
        // Ordinary English prose, protected code/URLs, and disabled packs don't
        // trigger this expansion. User entries and actual mentions keep priority.
        var editable = ""
        _ = TextPolish.mapUnprotected(text) { part in editable += part; return part }
        let known = Set(all.map { VocabularyMatcher.squash($0.term) })
        let ns = editable as NSString
        let words = try! NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9]{2,}")
        let uncertain = words.matches(in: editable, range: NSRange(location: 0, length: ns.length)).contains {
            !known.contains(VocabularyMatcher.squash(ns.substring(with: $0.range)))
        }
        if editable.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }), uncertain {
            let lists = packs.filter { settings.enabled && settings.isOn($0) }.map { pack in
                pack.entries.filter { $0.term.unicodeScalars.allSatisfy(\.isASCII) }.map(\.term)
            }
            let count = lists.map(\.count).max() ?? 0
            if count > 0 {
                for index in 0..<count {
                    for list in lists where index < list.count && out.count < limit {
                        let term = list[index]
                        if !out.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) { out.append(term) }
                    }
                    if out.count >= limit { break }
                }
            }
        }
        return Array(out.prefix(limit))
    }
}
