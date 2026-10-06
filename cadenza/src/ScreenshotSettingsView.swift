import SwiftUI
import AppKit
import Carbon.HIToolbox

/// 设置 → 快捷键 里的“截图”区块：两个快捷键默认都不占用任何键，用户自己录制
enum ScreenshotShortcutTarget: String, Identifiable {
    case capture, ocr
    var id: String { rawValue }
    func current(_ c: BridgeConfig) -> HotkeySpec? { self == .capture ? c.screenshot.trigger : c.screenshot.ocrTrigger }
    func other(_ c: BridgeConfig) -> HotkeySpec? { self == .capture ? c.screenshot.ocrTrigger : c.screenshot.trigger }
    func set(_ c: inout BridgeConfig, _ spec: HotkeySpec?) { if self == .capture { c.screenshot.trigger = spec } else { c.screenshot.ocrTrigger = spec } }
}

struct ScreenshotShortcutSection: View {
    @Bindable var model: SettingsModel
    @State private var recording: ScreenshotShortcutTarget?

    private func row(_ target: ScreenshotShortcutTarget, _ title: String, binding: String) -> some View {
        LabeledContent(title) {
            HStack {
                Text(binding.isEmpty ? L10n.tr("screenshot.shortcut.none") : binding).foregroundStyle(binding.isEmpty ? Color.secondary : Color.primary)
                Button(L10n.tr(binding.isEmpty ? "shortcut.set" : "shortcut.change")) { recording = target }.buttonStyle(.bordered)
                if !binding.isEmpty { Button(L10n.tr("screenshot.shortcut.clear")) { model.persist { target.set(&$0, nil) } }.buttonStyle(.borderless) }
            }
        }
    }

    var body: some View {
        Section {
            row(.capture, L10n.tr("screenshot.shortcut"), binding: model.screenshotBinding)
            row(.ocr, L10n.tr("screenshot.shortcut.ocr"), binding: model.ocrBinding)
            LabeledContent(L10n.tr("screenshot.start")) {
                Button(L10n.tr("screenshot.start.button")) { model.onStartScreenshot?() }.buttonStyle(.bordered)
            }
        } header: {
            Text(L10n.tr("screenshot.header"))
        } footer: {
            Text(L10n.tr("screenshot.footer")).font(.callout).foregroundStyle(.primary)
        }
        .sheet(item: $recording) { target in ScreenshotShortcutRecorder(model: model, target: target) { recording = nil } }
    }
}

/// 截图快捷键专用规则。语音触发键要避开所有会误触的组合，规则很严；截图是一次性的全局组合键，只需要避开：
/// 单独的修饰键与 Fn、没有修饰键的普通键、⌘ 单独修饰的标准命令（⌘C、⌘V…）、系统与应用菜单已占用的组合。
/// 例如 ⌥A、⌘⇧A、⌘⌥A、⌃⇧A 都可以使用。
enum ScreenshotShortcutPolicy {
    /// ⌘ 单独修饰时属于标准命令的按键（A S D 之外的常见命令键）
    static let standardCommandKeys: [UInt32: String] = [0: "A", 1: "S", 6: "Z", 7: "X", 8: "C", 9: "V", 12: "Q", 13: "W", 45: "N", 31: "O", 35: "P", 3: "F", 17: "T", 4: "H", 46: "M", 15: "R", 11: "B", 34: "I", 32: "U", 37: "L", 40: "K", 43: ",", 49: "Space", 48: "Tab", 50: "`"]

    static func reason(_ s: HotkeySpec,
                       systemAssignments: [HotkeySpec]? = ShortcutPolicy.systemAssignments(),
                       menuAssignments: [HotkeySpec]? = ShortcutPolicy.globalMenuAssignments(),
                       voiceOver: Bool = NSWorkspace.shared.isVoiceOverEnabled) -> String? {
        let c = UInt32(controlKey), o = UInt32(optionKey), m = UInt32(cmdKey), h = UInt32(shiftKey)
        if s.keyCode == 63 { return L10n.tr("ui.be1ca2ee706d") }
        if ListenTrigger.modifierKeyFlags[s.keyCode] != nil { return L10n.tr("screenshot.shortcut.loneModifier") }
        let isFunction = ShortcutPolicy.functionKeys.contains(s.keyCode)
        guard s.keyCode <= 126, isFunction || HotkeySpecDisplay.printableKeys.keys.contains(s.keyCode) || ShortcutPolicy.navigational.contains(s.keyCode) else { return L10n.tr("ui.1e86164926a6") }
        if s.modifiers & ~(c | o | m | h) != 0 { return L10n.tr("ui.b21dfa61556d") }
        if !isFunction && s.modifiers & (c | o | m) == 0 { return L10n.tr("screenshot.shortcut.needModifier") }
        if voiceOver && s.modifiers & c != 0 && s.modifiers & o != 0 { return L10n.tr("ui.52fb99b1743b") }
        if s.modifiers == m, standardCommandKeys[s.keyCode] != nil { return L10n.tr("screenshot.shortcut.reserved") }
        // 读取不到系统/应用已占用列表时不拦截（最后还有一次真实注册检查）
        if menuAssignments?.contains(where: { $0.keyCode == s.keyCode && $0.modifiers == s.modifiers }) == true { return L10n.tr("ui.2cbbbc5906ec") }
        if systemAssignments?.contains(where: { $0.keyCode == s.keyCode && $0.modifiers == s.modifiers }) == true { return L10n.tr("ui.992a958d0bbe") }
        return nil
    }

    /// 录制窗口里给出的候选：按顺序挑出当前真正可用的几个
    static let suggestionCandidates: [HotkeySpec] = {
        let c = UInt32(controlKey), o = UInt32(optionKey), m = UInt32(cmdKey), h = UInt32(shiftKey)
        return [HotkeySpec(keyCode: 0, modifiers: c | h), HotkeySpec(keyCode: 1, modifiers: c | h), HotkeySpec(keyCode: 0, modifiers: o),
                HotkeySpec(keyCode: 0, modifiers: m | h), HotkeySpec(keyCode: 1, modifiers: o), HotkeySpec(keyCode: 0, modifiers: m | o),
                HotkeySpec(keyCode: 7, modifiers: c | h), HotkeySpec(keyCode: 6, modifiers: c | h), HotkeySpec(keyCode: 105, modifiers: 0)]
    }()
    static func suggestions(limit: Int = 4, validate: (HotkeySpec) -> String?) -> [HotkeySpec] {
        Array(suggestionCandidates.filter { validate($0) == nil }.prefix(limit))
    }
}

enum ScreenshotShortcutValidation {
    /// 返回 nil 表示可用：先排除与语音快捷键相同，再按截图规则检查，最后做一次真实的系统注册试探
    static func problem(for spec: HotkeySpec, config: BridgeConfig, other: HotkeySpec? = nil,
                        policy: (HotkeySpec) -> String? = { ScreenshotShortcutPolicy.reason($0) ?? ShortcutPolicy.registrationReason($0) }) -> String? {
        if spec == config.trigger || spec == config.toggleTrigger || spec == config.diagnosticTrigger { return L10n.tr("screenshot.shortcut.duplicate") }
        if let other, spec == other { return L10n.tr("screenshot.shortcut.duplicateScreenshot") }
        return policy(spec)
    }
}

struct ScreenshotShortcutRecorder: View {
    var model: SettingsModel
    let target: ScreenshotShortcutTarget
    let close: () -> Void
    @State private var candidate: HotkeySpec?
    @State private var problem: String?
    @State private var monitor: Any?
    @State private var suggestions: [HotkeySpec] = []

    var body: some View {
        VStack(spacing: 14) {
            Text(L10n.tr("screenshot.shortcut.recording")).font(.headline)
            Text(candidate.map { HotkeySpecDisplay.string($0) } ?? "…")
                .font(.system(.title2, design: .rounded, weight: .medium))
                .frame(minWidth: 200, minHeight: 44)
                .background(.quaternary, in: .rect(cornerRadius: 8))
            if let problem { Text(problem).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true) }
            else { Text(L10n.tr("screenshot.shortcut.advice")).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true) }
            if !suggestions.isEmpty {
                VStack(spacing: 6) {
                    Text(L10n.tr("screenshot.shortcut.try")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        ForEach(suggestions, id: \.keyCode) { spec in
                            Button(HotkeySpecDisplay.string(spec)) { candidate = spec; problem = nil }.buttonStyle(.bordered)
                        }
                    }
                }
            }
            HStack {
                Button(L10n.tr("action.cancel"), action: close).keyboardShortcut(.cancelAction)
                Button(L10n.tr("screenshot.shortcut.save")) {
                    if let candidate { model.persist { target.set(&$0, candidate) } }
                    close()
                }.disabled(candidate == nil || problem != nil).buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 380)
        .onAppear {
            model.onScreenshotRecording?(true)
            if let config = model.store?.config { suggestions = ScreenshotShortcutPolicy.suggestions { ScreenshotShortcutValidation.problem(for: $0, config: config, other: target.other(config)) } }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in handle(event); return nil }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            model.onScreenshotRecording?(false)
        }
    }

    private func handle(_ event: NSEvent) {
        let modifiers = ShortcutPolicy.carbon(event.modifierFlags)
        if event.keyCode == 53, modifiers == 0 { close(); return }
        let spec = HotkeySpec(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        candidate = spec
        problem = model.store.flatMap { ScreenshotShortcutValidation.problem(for: spec, config: $0.config, other: target.other($0.config)) }
    }
}
