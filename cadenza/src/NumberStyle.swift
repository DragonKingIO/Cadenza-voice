import Foundation

/// Makes a number the recognizer wrote half in digits and half in Chinese numerals (`十0本`, `二0次`, `一至3张`) use digits
/// throughout, the way the person writes counts. It only ever acts on a numeral that touches an ASCII digit or sits in a
/// `X至Y` range with a digit on the other side, so `一个`, `一下`, `一样`, `一直`, `第二章`, `百分之百`, `30万` and idioms
/// have no digit beside them and are never touched. Used on the local-engine path only.
enum NumberStyle {
    private static let digits: [Character: String] = ["零": "0", "〇": "0", "一": "1", "二": "2", "两": "2", "三": "3", "四": "4", "五": "5", "六": "6", "七": "7", "八": "8", "九": "9"]
    private static let numerals = "零〇一二三四五六七八九十百千万亿两"

    static func apply(_ text: String) -> String {
        guard text.rangeOfCharacter(from: .decimalDigits) != nil else { return text }
        var s = text
        func rewrite(_ pattern: String, _ transform: (NSTextCheckingResult, NSString) -> String) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            let ns = s as NSString
            var out = "", last = 0
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + transform(m, ns)
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            s = out
        }
        // 十0 -> 10, 十5 -> 15 (ten, then a digit)
        rewrite("(?<![\(numerals)])十(?=[0-9])") { _, _ in "1" }
        // 二0 -> 20 (a single digit numeral directly before an ASCII digit, not part of a longer numeral)
        rewrite("(?<![\(numerals)])([零〇二三四五六七八九])(?=[0-9])") { m, ns in digits[Character(ns.substring(with: m.range(at: 1)))] ?? ns.substring(with: m.range) }
        // 1三 -> 13 (an ASCII digit directly before a digit numeral; 一 is left alone because of 一个/一下/一些)
        rewrite("(?<=[0-9])([零〇二三四五六七八九])(?![\(numerals)])") { m, ns in digits[Character(ns.substring(with: m.range(at: 1)))] ?? ns.substring(with: m.range) }
        // 一至3 -> 1至3, 1至三 -> 1至3
        rewrite("(?<![\(numerals)])([一二两三四五六七八九])至(?=[0-9])") { m, ns in (digits[Character(ns.substring(with: m.range(at: 1)))] ?? "") + "至" }
        rewrite("(?<=[0-9])至([一二两三四五六七八九])(?![\(numerals)])") { m, ns in "至" + (digits[Character(ns.substring(with: m.range(at: 1)))] ?? "") }
        return s
    }
}

enum NumberStyleFixtures {
    static func run(_ check: (String, Bool) -> Void) {
        func c(_ name: String, _ ok: Bool) { check("NumberStyle " + name, ok) }
        c("ten then digit", NumberStyle.apply("本月读完的十0本小说") == "本月读完的10本小说" && NumberStyle.apply("十5次") == "15次")
        c("numeral before digit", NumberStyle.apply("复查三0天") == "复查30天")
        c("digit before numeral", NumberStyle.apply("一共2四个") == "一共24个")
        c("range", NumberStyle.apply("翻一至4页看一下") == "翻1至4页看一下" && NumberStyle.apply("2至五章") == "2至5章")
        c("untouched words", ["一个人", "稍等一下", "一样的", "一直做", "百分之百", "第二章", "三心二意", "一二三四五", "30万字", "100%", "十个", "二十本", "说一说", "九九乘法"].allSatisfy { NumberStyle.apply($0) == $0 })
        c("untouched mixed with digits far away", NumberStyle.apply("第二章有30万字，一下就好") == "第二章有30万字，一下就好")
        c("no digits is a no-op", NumberStyle.apply("十本书一至三章") == "十本书一至三章")
        c("idempotent", NumberStyle.apply(NumberStyle.apply("十0本，一至3张")) == "10本，1至3张")
    }
}
