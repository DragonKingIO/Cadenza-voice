import Foundation

/// Fixed sentences only. Every rule has a case that must change and a case that must stay as it is.
enum TextPolishFixtures {
    static func run(_ check: (String, Bool) -> Void) {
        func c(_ name: String, _ ok: Bool) { check("Polish " + name, ok) }
        let std = TextPolishSettings()
        var thorough = TextPolishSettings(); thorough.level = .thorough
        var off = TextPolishSettings(); off.level = .off
        var paras = TextPolishSettings(); paras.paragraphs = true
        func p(_ t: String, _ s: TextPolishSettings = std) -> String { TextPolish.apply(t, s) }

        // Hesitations
        c("呃 anywhere", p("我呃觉得可以") == "我觉得可以" && p("呃，我们开始吧") == "我们开始吧" && p("我们，呃，开始吧") == "我们，开始吧")
        c("嗯 at the start of a clause", p("嗯，我想一下") == "我想一下" && p("好的，嗯，那就这样") == "好的，那就这样" && p("嗯嗯我知道了") == "我知道了")
        c("额 only with a comma", p("额，我再看看") == "我再看看" && p("额度已经用完了") == "额度已经用完了" && p("本月金额很大") == "本月金额很大")
        c("呃逆 is a word", p("他一直在呃逆") == "他一直在呃逆")
        c("嗯 as a whole answer is kept", p("你来吗？嗯。") == "你来吗？嗯。" && p("嗯，我来") == "我来")
        c("嗯 between two words goes, as models write it", p("我嗯想") == "我想" && p("这个方案的话嗯成本可能有点高") == "这个方案的话成本可能有点高" && p("方案的话嗯，成本高") == "方案的话成本高")
        c("嗯哼 and an ending 嗯 are kept", p("他嗯哼了一声") == "他嗯哼了一声" && p("好的嗯。") == "好的嗯。")
        c("a recording that was only a filler is kept", p("嗯") == "嗯" && p("呃。") == "呃。")
        c("English um uh", p("Um, I think so") == "I think so" && p("I think, uh, we should go") == "I think we should go" && p("So um the plan works") == "So the plan works")
        c("English capital after the removed filler", p("Uh, send it today") == "Send it today" && p("Done. Um, next one") == "Done. Next one")
        c("English err and umbrella are words", p("Better to err on the side of caution") == "Better to err on the side of caution" && p("Take an umbrella") == "Take an umbrella")

        // Repeats
        c("repeated pronouns", p("我我我想问一下") == "我想问一下" && p("他他说得对") == "他说得对")
        c("repeated words", p("我们我们先看这个这个方案") == "我们先看这个方案" && p("因为因为下雨") == "因为下雨")
        c("legitimate doubling stays", p("看看这个，试试那个") == "看看这个，试试那个" && p("是是是，没错") == "是是是，没错" && p("慢慢来") == "慢慢来")
        c("English repeats, also three in a row", p("So I I I think the the the plan works") == "So I think the plan works" && p("I I think the the plan works") == "I think the plan works" && p("I know that that is true") == "I know that that is true")

        // Spaces and marks
        c("spaces between Han characters", p("你 好 世界") == "你好世界")
        c("space before a mark and doubled marks", p("你好 ，世界") == "你好，世界" && p("好，，我们走") == "好，我们走")
        c("English spacing between words is kept", p("open the file") == "open the file" && p("iPhone 15 Pro") == "iPhone 15 Pro")
        c("leading comma after a removed filler", p("，我们开始") == "我们开始")

        // Connectors
        c("connectors stay at standard", p("那个，我们开始") == "那个，我们开始" && p("然后，再试一次") == "然后，再试一次")
        c("connectors go at thorough", p("那个，我们开始", thorough) == "我们开始" && p("然后，再试一次", thorough) == "再试一次" && p("就是，这样不行", thorough) == "这样不行")
        c("connectors in the middle of a clause stay", p("我喜欢这个，那个不行", thorough) == "我喜欢这个，那个不行" && p("就是这样", thorough) == "就是这样" && p("然后我们走了", thorough) == "然后我们走了")
        c("English connectors", p("You know, it works", thorough) == "It works" && p("It works, like, really well", thorough) == "It works really well" && p("I like, you know, apples", thorough) == "I like apples")
        c("a connector kept as-is when only that was said", p("然后，", thorough) == "然后，")

        // Off
        c("off changes nothing", p("呃，我我我想", off) == "呃，我我我想")

        // Protected text
        c("links and code are untouched", p("打开 https://a.com/um 然后呃好了") == "打开 https://a.com/um 然后好了" && p("运行 `呃 呃` 就行") == "运行 `呃 呃` 就行")
        c("e-mail untouched", p("发到 uh@example.com 呃谢谢") == "发到 uh@example.com 谢谢")

        // Paragraphs
        let long = "今天我们讨论三件事。首先是预算，目前预算已经确认。其次是人员，招聘进度比预期慢。另外是时间表，需要重新评估。最后是风险，主要集中在供应商交付上。我们会在下周一前给出结论。"
        let split = p(long, paras)
        c("paragraphs split at points", split.contains("\n") && split.split(separator: "\n").count >= 2)
        c("paragraphs keep every character", split.replacingOccurrences(of: "\n", with: "") == p(long))
        c("paragraphs off by default", !p(long).contains("\n"))
        c("short text has no paragraphs", p("好的。可以。没问题。就这样。", paras) == "好的。可以。没问题。就这样。")
        c("existing line breaks are kept", p(long + "\n第二行", paras).split(separator: "\n").count == 2)
        let long2 = long
        let english = "We reviewed the budget today. It is confirmed for the quarter. However, hiring is slower than planned. We need more candidates. Finally, the schedule needs a new review before the next meeting."
        let englishSplit = p(english, paras)
        c("English paragraphs", englishSplit.contains("\n") && englishSplit.replacingOccurrences(of: "\n", with: " ") == english)
        c("decimal point is not a sentence end", TextPolish.paragraphs("版本是3.5。好。好。好。好。" + String(repeating: "字", count: 80)).contains("3.5"))

        // Report: counts only
        let reported = TextPolish.applyReporting("呃，我我我想，那个，明天开会 https://a.example/um", thorough)
        c("report: counts what each rule did", reported.report.hesitations == 1 && reported.report.repeats == 1 && reported.report.connectors == 1 && reported.report.changed && reported.text.hasPrefix("我想"))
        c("report: nothing done means not changed", !TextPolish.applyReporting("今天天气很好。", std).report.changed && !TextPolish.applyReporting("嗯", std).report.changed && TextPolish.applyReporting("嗯", std).text == "嗯")
        c("report: off reports nothing", TextPolish.applyReporting("呃，我想", off).report == PolishReport())
        c("report: paragraphs are noted", TextPolish.applyReporting(long2, paras).report.paragraphs)

        // Settings
        c("settings default", TextPolishSettings().level == .standard && !TextPolishSettings().paragraphs)
        c("settings decode old and broken data", {
            let empty = try? JSONDecoder().decode(TextPolishSettings.self, from: Data("{}".utf8))
            let broken = try? JSONDecoder().decode(TextPolishSettings.self, from: Data(#"{"level":"nonsense","paragraphs":"x"}"#.utf8))
            return empty == TextPolishSettings() && broken == TextPolishSettings()
        }())
        c("settings round trip", {
            var s = TextPolishSettings(); s.level = .thorough; s.paragraphs = true
            guard let data = try? JSONEncoder().encode(s), let back = try? JSONDecoder().decode(TextPolishSettings.self, from: data) else { return false }
            return back == s
        }())
        c("config without the key gets the default", {
            guard let data = try? JSONEncoder().encode(BridgeConfig.default()),
                  var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
            object.removeValue(forKey: "polish")
            guard let stripped = try? JSONSerialization.data(withJSONObject: object),
                  let config = try? JSONDecoder().decode(BridgeConfig.self, from: stripped) else { return false }
            return config.polish == TextPolishSettings()
        }())
        c("empty text", p("") == "")
    }
}
