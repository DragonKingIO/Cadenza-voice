import Foundation

// A vocabulary of terms (product names, code names, jargon) that speech recognizers often get wrong. It works on the text
// after recognition, for every engine alike, and is also handed to AI polish as a glossary. Everything runs on this Mac.
//
// Three kinds of fixes, all exact enough to be safe:
//  - an alias the person (or a pack) listed for a term ("吉特哈勃" -> GitHub);
//  - an English term written apart or in the wrong case ("git hub", "github" -> GitHub, "node js" -> Node.js);
//  - a Chinese term written with other characters that sound the same (same pinyin, tones ignored).

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
            for alias in t.aliases where alias.lowercased() != t.term.lowercased() {
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

        // 3. Chinese terms written with other characters that sound the same
        let han = terms.compactMap { t -> (Int, String, VocabTerm)? in
            guard isAllHan(t.term), t.term.count >= (t.fromUser ? 2 : 3), t.term.count <= 8, let key = pinyinKey(t.term) else { return nil }
            return (t.term.count, key, t)
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
                    for (length, key, t) in han where runChars.count >= length {
                        for start in 0...(runChars.count - length) {
                            let window = String(runChars[start..<(start + length)])
                            guard window != t.term, pinyinKey(window) == key else { continue }
                            let prefix = String(runChars[0..<start]).utf16.count
                            hits.append(Hit(range: NSRange(location: index + prefix, length: window.utf16.count), replacement: t.term))
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
        let all = terms(settings)
        let lowered = text.lowercased()
        var out: [String] = []
        for t in all where t.fromUser { out.append(t.term) }
        for t in all where !t.fromUser && lowered.contains(t.term.lowercased()) && !out.contains(t.term) { out.append(t.term) }
        return Array(out.prefix(limit))
    }
}
