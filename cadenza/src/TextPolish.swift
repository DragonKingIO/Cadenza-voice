import Foundation

/// How much the recognized text is tidied before it is inserted. Everything here is rule based and runs on this Mac:
/// no model, no network, no waiting.
enum TextPolishLevel: String, Codable, CaseIterable {
    /// Text goes in exactly as the recognizer wrote it.
    case off
    /// Hesitation sounds (呃, 嗯, um, uh), stuttered repeats ("我我我想", "I I think") and stray spaces and marks.
    case standard
    /// Standard, plus spoken connectors that only fill a pause: "那个，", "就是，", "然后，", "you know,".
    case thorough
}

struct TextPolishSettings: Codable, Equatable {
    var level: TextPolishLevel = .standard
    /// Split long text into paragraphs. Off by default: a line break typed into a chat box can send the message.
    var paragraphs = false

    init() {}
    enum CodingKeys: String, CodingKey { case level, paragraphs }
    init(from decoder: Decoder) throws {
        let d = try decoder.container(keyedBy: CodingKeys.self)
        level = (try? d.decodeIfPresent(TextPolishLevel.self, forKey: .level)) ?? .standard
        paragraphs = (try? d.decodeIfPresent(Bool.self, forKey: .paragraphs)) ?? false
    }
}

/// What the tidy step did to one recognized text: counts only, never the text, so it can go into the log.
struct PolishReport: Equatable {
    var hesitations = 0
    var repeats = 0
    var connectors = 0
    var paragraphs = false
    var changed = false
}

enum TextPolish {
    static func apply(_ text: String, _ settings: TextPolishSettings) -> String { applyReporting(text, settings).text }

    static func applyReporting(_ text: String, _ settings: TextPolishSettings) -> (text: String, report: PolishReport) {
        var report = PolishReport()
        guard !text.isEmpty, settings.level != .off || settings.paragraphs else { return (text, report) }
        var out = text
        if settings.level != .off {
            out = mapUnprotected(out) { segment in
                report.hesitations += count(zhHesitations + [enHesitation], in: segment)
                var t = removeHesitations(segment)
                report.repeats += count([zhChars, zhWords, enWords], in: t)
                t = collapseRepeats(t)
                if settings.level == .thorough {
                    report.connectors += count([zhConnectors, enConnectors], in: t)
                    t = removeConnectors(t)
                }
                return tidy(t)
            }
            out = replace(leadingMarks, in: out, with: "").trimmingCharacters(in: .whitespaces)
            // A recording that was only "嗯。" has nothing left once the filler is gone; keep what was said.
            if out.rangeOfCharacter(from: .alphanumerics) == nil { return (text, PolishReport()) }
        }
        if settings.paragraphs { let split = paragraphs(out); report.paragraphs = split != out; out = split }
        report.changed = out != text
        return (out, report)
    }

    private static func count(_ expressions: [NSRegularExpression], in text: String) -> Int {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return expressions.reduce(0) { $0 + $1.numberOfMatches(in: text, range: range) }
    }

    // MARK: Protected spans

    /// Links, e-mail addresses and `code` are never edited.
    private static let protectedPattern = try! NSRegularExpression(pattern: "`[^`]*`|(?:https?://|www\\.)\\S+|[\\w.+-]+@[\\w-]+(?:\\.[\\w-]+)+")

    static func mapUnprotected(_ text: String, _ transform: (String) -> String) -> String {
        let ns = text as NSString
        var result = "", last = 0
        for m in protectedPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += transform(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            result += ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        result += transform(ns.substring(from: last))
        return result
    }

    // MARK: Regular expressions

    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }
    private static func replace(_ r: NSRegularExpression, in text: String, with template: String) -> String {
        r.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    /// 呃 is never part of a word except 呃逆 (hiccup), so it goes anywhere. 嗯 and 唔 go at the start of a clause or between two words, and
    /// 额 only when a comma follows it, because 额度 and 金额 are words. A 嗯 between two words goes too. A 嗯 that is a whole sentence ("你来吗？嗯。") is an answer, so it stays.
    private static let zhHesitations = [
        re("呃(?!逆)[呃啊]*[，、,…]*[ \\t]*"),
        re("(?<![\\p{Han}A-Za-z0-9])(?>[嗯唔]+[嗯唔啊]*)(?![。！？.!?])[，、,…]*[ \\t]*"),
        re("(?<![\\p{Han}A-Za-z0-9])额[，、,…]+[ \\t]*"),
        // Models often write 嗯 between two words with no mark around it ("方案的话嗯成本"); 嗯哼 is a word.
        re("(?<=\\p{Han})(?>[嗯唔]+)(?![哼哈])(?=[\\p{Han}，、,])[，、,]?"),
    ]
    private static let enHesitation = re("(?<![\\p{L}\\p{N}'’-])(?:u+m+|u+h+|erm?)(?![\\p{L}\\p{N}'’-])[,.…]*[ \\t]*", .caseInsensitive)

    private static func removeHesitations(_ text: String) -> String {
        var t = text
        for r in zhHesitations { t = replace(r, in: t, with: "") }
        return removeEnglish(enHesitation, in: t)
    }

    /// Removes the English matches, keeps the capital letter at the start of a sentence, and drops the comma that led into
    /// a filler that was itself followed by a comma ("we should, uh, ship it" becomes "we should ship it").
    private static func removeEnglish(_ r: NSRegularExpression, in text: String) -> String {
        var t = text
        for m in r.matches(in: t, range: NSRange(location: 0, length: (t as NSString).length)).reversed() {
            let ns = t as NSString
            var before = ns.substring(to: m.range.location)
            var after = ns.substring(from: m.range.location + m.range.length)
            let atStart = before.trimmingCharacters(in: .whitespaces).isEmpty || before.range(of: "[.!?]\\s*$", options: .regularExpression) != nil
            var separator = ""
            if ns.substring(with: m.range).contains(","), let comma = before.range(of: ",\\s*$", options: .regularExpression) {
                before.removeSubrange(comma)
                if !before.isEmpty, !after.isEmpty { separator = " " }
            }
            if atStart, let first = after.first, first.isLowercase { after = first.uppercased() + after.dropFirst() }
            t = before + separator + after
        }
        return t
    }

    private static let zhChars = re("([我你他她这那就])\\1+")
    private static let zhWords = re("(我们|你们|他们|因为|所以|但是|如果|这个|那个|然后|我觉得|我想|就是说)\\1+")
    private static let enWords = re("\\b(i|we|the|a|to|and|it)(?:\\s+\\1\\b)+", .caseInsensitive)

    private static func collapseRepeats(_ text: String) -> String {
        var t = replace(zhChars, in: text, with: "$1")
        t = replace(zhWords, in: t, with: "$1")
        return replace(enWords, in: t, with: "$1")
    }

    /// A connector counts as filler only at the start of a clause and with a pause (comma) right after it.
    private static let zhConnectors = re("(?<![\\p{Han}A-Za-z0-9])(?:就是说|就是|那个|这个|然后|其实就是|怎么说呢|你知道吧|你知道)[，、,][ \\t]*")
    private static let enConnectors = re("(?:(?<=^)|(?<=[.!?,;]\\s)|(?<=[.!?,;]))(?:you know|i mean|like|basically)[,][ \\t]*", .caseInsensitive)

    private static func removeConnectors(_ text: String) -> String {
        removeEnglish(enConnectors, in: replace(zhConnectors, in: text, with: ""))
    }

    private static let spaceBetweenHan = re("(?<=\\p{Han})[ \\t]+(?=\\p{Han})")
    private static let spaceBeforeMark = re("[ \\t]+(?=[，。！？、；：])")
    private static let manySpaces = re("[ \\t]{2,}")
    private static let stackedCommas = re("[，、]{2,}|,{2,}|，,|,，")
    private static let leadingMarks = re("^[\\s，、,；;：:]+")

    private static func tidy(_ text: String) -> String {
        var t = ASRPunctuationCleanup.apply(text)
        t = replace(stackedCommas, in: t, with: "，")
        t = replace(spaceBetweenHan, in: t, with: "")
        t = replace(spaceBeforeMark, in: t, with: "")
        t = replace(manySpaces, in: t, with: " ")
        return t
    }

    // MARK: Paragraphs

    static let minimumParagraphCharacters = 80
    static let minimumParagraphSentences = 4
    private static let zhMarker = re("^(?:首先|其次|再次|第[一二三四五六七八九十]|另外|此外|最后|总之|综上|接下来|还有一点|另一方面|一方面)")
    private static let enMarker = re("^(?:first|second|third|finally|lastly|in addition|moreover|furthermore|however|in conclusion|to sum up|next)\\b", .caseInsensitive)

    /// Starts a new paragraph before a sentence that opens a new point ("首先", "另外", "最后", "However") and after
    /// about four sentences. Short text and text that already has line breaks are left alone.
    static func paragraphs(_ text: String) -> String {
        guard !text.contains("\n"), text.count >= minimumParagraphCharacters, text.range(of: "`") == nil else { return text }
        let sentences = splitSentences(text)
        guard sentences.count >= minimumParagraphSentences else { return text }
        var groups: [[String]] = [[]]
        var length = 0
        for s in sentences {
            let range = NSRange(location: 0, length: (s as NSString).length)
            let opensPoint = zhMarker.firstMatch(in: s, range: range) != nil || enMarker.firstMatch(in: s, range: range) != nil
            let current = groups[groups.count - 1]
            if !current.isEmpty, (opensPoint && current.count >= 2) || current.count >= 4 || length >= 140 {
                groups.append([]); length = 0
            }
            groups[groups.count - 1].append(s); length += s.count
        }
        // A single leftover sentence joins the paragraph before it, unless it is a closing remark.
        if groups.count > 1, let tail = groups.last, tail.count == 1,
           zhMarker.firstMatch(in: tail[0], range: NSRange(location: 0, length: (tail[0] as NSString).length)) == nil,
           enMarker.firstMatch(in: tail[0], range: NSRange(location: 0, length: (tail[0] as NSString).length)) == nil {
            groups.removeLast(); groups[groups.count - 1].append(tail[0])
        }
        return groups.map(join).joined(separator: "\n")
    }

    private static func join(_ sentences: [String]) -> String {
        var out = ""
        for s in sentences {
            if let last = out.last, last.isASCII, !last.isWhitespace { out += " " }
            out += s
        }
        return out
    }

    private static func splitSentences(_ text: String) -> [String] {
        var result: [String] = [], current = ""
        var ended = false
        let chars = Array(text)
        func flush() { let t = current.trimmingCharacters(in: .whitespaces); if !t.isEmpty { result.append(t) }; current = ""; ended = false }
        for (i, c) in chars.enumerated() {
            if ended {
                // Closing quotes and brackets belong to the sentence that just ended.
                if "”’\"')）」".contains(c) { current.append(c); continue }
                flush()
            }
            current.append(c)
            let zhEnd = "。！？".contains(c)
            // An English full stop ends a sentence only when a space or the end follows (not in "3.5" or "a.b").
            let asciiEnd = ".!?".contains(c) && (i + 1 == chars.count || chars[i + 1] == " ")
            if zhEnd || asciiEnd { ended = true }
        }
        flush()
        return result
    }
}
