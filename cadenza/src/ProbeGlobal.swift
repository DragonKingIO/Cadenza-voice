import AppKit
import Carbon.HIToolbox

/// 可行性探针（--probe-global）：苹果输入源保持激活，全程只读 TIS（不调用任何切换），
/// 验证讯飞语音热键是否独立于激活输入法生效：
/// t=1s 发 ⌃Fn（启动）、t=8s 再发 ⌃Fn（停止，语义未验证），
/// 300ms 粒度记录：讯飞窗口增量（窗口证据）、输入源是否被改变。
final class ProbeGlobalRunner {
    private let configStore: ConfigStore
    private let input: InputSourceController
    private var timer: Timer?
    private var baseSource = ""
    private var lastWindows: Set<String> = []
    private var appearedAt: Double?
    private var closedAt: Double?
    private var sourceChangedAt: Double?
    private let start = Date()

    init(configStore: ConfigStore, input: InputSourceController) {
        self.configStore = configStore
        self.input = input
    }

    func run() {
        let apple = "com.apple.inputmethod.SCIM.ITABC"
        baseSource = input.currentID() ?? apple
        if !baseSource.hasPrefix("com.apple.") {
            try? input.select(id: apple)
            Thread.sleep(forTimeInterval: 0.3)
            baseSource = input.currentID() ?? apple
            Log.write("pg setup switched-to-apple \(baseSource)")
        }
        Log.write("pg START baseSource=\(baseSource)（此后全程只读 TIS，不切换）")
        lastWindows = PanelObserver.iflytekWindows()
        Log.write("pg baseline windows=\(lastWindows.count)")
        let t = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            Log.write("pg t=1.0 SEND start ⌃Fn")
            KeyEventPoster.post(self.configStore.config.iflytekVoiceHotkey, label: "pg-start")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            guard let self = self else { return }
            Log.write("pg t=8.0 SEND stop ⌃Fn（语义未验证）")
            KeyEventPoster.post(self.configStore.config.iflytekVoiceHotkey, label: "pg-stop")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
            self?.finish()
        }
    }

    private func tick() {
        let t = Date().timeIntervalSince(start)
        let wins = PanelObserver.iflytekWindows()
        let added = wins.subtracting(lastWindows)
        if !added.isEmpty {
            Log.write("pg t=\(String(format: "%.1f", t)) window-added \(added.joined(separator: " ; "))")
            if appearedAt == nil { appearedAt = t }
        }
        let removed = lastWindows.subtracting(wins)
        if !removed.isEmpty {
            Log.write("pg t=\(String(format: "%.1f", t)) window-removed \(removed.joined(separator: " ; "))")
            if appearedAt != nil, closedAt == nil { closedAt = t }
        }
        lastWindows = wins
        if let src = input.currentID(), src != baseSource, sourceChangedAt == nil {
            sourceChangedAt = t
            Log.write("pg t=\(String(format: "%.1f", t)) SOURCE-CHANGED to=\(src) !!")
        }
    }

    private func finish() {
        timer?.invalidate()
        let appeared = appearedAt.map { String(format: "%.1f", $0) } ?? "nil"
        let closed = closedAt.map { String(format: "%.1f", $0) } ?? "nil"
        let switched = sourceChangedAt.map { String(format: "%.1f", $0) } ?? "nil"
        Log.write("pg SUMMARY appearedAt=\(appeared)s closedAt=\(closed)s sourceChangedAt=\(switched)s finalSource=\(input.currentID() ?? "nil")")
        if let a = appearedAt, sourceChangedAt == nil {
            Log.write("pg CONCLUSION 讯飞热键在苹果输入源激活时独立生效（面板窗口 t=\(String(format: "%.1f", a))s 出现，输入源全程未变；面板是否为语音面板、文字是否上屏需真实说话验证）")
        } else if appearedAt != nil {
            Log.write("pg CONCLUSION 面板出现但输入源被改变（sourceChangedAt=\(switched)s）——不满足「全程保持苹果输入源」")
        } else {
            Log.write("pg CONCLUSION 苹果输入源激活下未见讯飞面板窗口（热键疑为 IME 内作用域）→ 无可用独立入口，需转独立语音工具路线")
        }
        NSApp.terminate(nil)
    }
}
