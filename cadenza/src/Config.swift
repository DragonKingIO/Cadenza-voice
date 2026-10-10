import Foundation
import Carbon.HIToolbox

struct HotkeySpec: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var modifierKeyCodes: [UInt32]? = nil
}

enum HotkeySpecDisplay {
    static let printableKeys: [UInt32:String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",50:"`"]
    static func isLoneModifierSpec(_ hk: HotkeySpec) -> Bool {
        guard let f = ListenTrigger.modifierKeyFlags[hk.keyCode] else { return false }
        return f == hk.modifiers
    }

    static func string(_ hk: HotkeySpec) -> String {
        if isLoneModifierSpec(hk) {
            return keyName(hk.keyCode)
        }
        var s = ""
        if hk.modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if hk.modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if hk.modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if hk.modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        if let sides=hk.modifierKeyCodes, !sides.isEmpty { s = sides.map(keyName).joined(separator:" + ") + " + " }
        s += keyName(hk.keyCode)
        return s
    }

    static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case 58: return L10n.tr("ui.eb6ce8ca0a91")
        case 61: return L10n.tr("ui.aa9c117ed982")
        case 55: return L10n.tr("ui.ffdc1b059fb1")
        case 54: return L10n.tr("ui.182aca24c5ce")
        case 56: return L10n.tr("ui.e73bf4ffb0c6")
        case 60: return L10n.tr("ui.1ef0d7b07f9f")
        case 59: return L10n.tr("ui.cb66bb04ee56")
        case 62: return L10n.tr("ui.7c6a60c827dd")
        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 106: return "F16"
        case 64: return "F17"
        case 79: return "F18"
        case 80: return "F19"
        case 90: return "F20"
        case 49: return "Space"
        case 63: return "Fn"
        case 53: return "Esc"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default: return printableKeys[code] ?? "Key(\(code))"
        }
    }
}

/// hold：独立语音路线（按住 Start 本机录音→松开识别→插入原输入框；全程不切换输入法，默认）
/// minimal / auto：历史实验——切换讯飞输入法的管线，已停止完善，仅保留代码
enum SessionMode: String {
    case hold
    case minimal
    case auto
}

struct BridgeConfig: Codable {
    var appearanceMode = "system"
    var cloudASR: [String:CloudASROptions] = [:]
    /// 本地模型：回退、主引擎所用模型、更新检查。新增键，旧配置缺失时用默认。
    var localModel = LocalModelSettings()
    /// 截图与 OCR。新增键，旧配置缺失时用默认（不占用任何快捷键）。
    var screenshot = ScreenshotSettings()
    var localASRMappings: [LocalASRMapping] = []
    /// 文字整理（去口头禅、重复、分段）。新增键，旧配置缺失时用默认。
    var polish = TextPolishSettings()
    /// 可选的 AI 润色（对话补全接口）。新增键，旧配置缺失时用默认（关闭）。
    var refine = TextRefineSettings()
    /// 词库开关与词库包选择。新增键，旧配置缺失时用默认。
    var vocabulary = VocabularySettings()
    /// 语音翻译：目标语言（空 = 关闭）。新增键，旧配置缺失时用默认。
    var translate = TranslateSettings()
    /// 我添加的 AI 模型（对话补全服务）；润色与翻译各选其一。新增键，旧配置缺失时由旧的单一服务迁移而来。
    var llmProfiles: [LLMProfile] = []
    var microphoneUID = ""
    var inputMode = "hold"
    var triggerCoordinatorEnabled = false
    var triggerThresholdSec = 0.3
    var triggerNoSpeechSec = 10.0
    var triggerPostSpeechSec = 20.0
    var holdShortcutEnabled = true
    var toggleShortcutEnabled = false
    var toggleTrigger: HotkeySpec? = nil
    /// The tap shortcut is on only when it is set and switched on.
    var toggleActive: Bool { toggleShortcutEnabled && toggleTrigger != nil }
    /// At least one way of starting dictation by key is on.
    var anyShortcutOn: Bool { holdShortcutEnabled || toggleActive }
    /// Wording only: tap when that is the only shortcut on, hold otherwise. Both shortcuts work at the same time.
    var primaryIsToggle: Bool { toggleActive && !holdShortcutEnabled }
    /// Keeps the older `inputMode` field in step with the two shortcut switches.
    mutating func syncInputMode() { inputMode = primaryIsToggle ? "toggle" : "hold" }
    /// The configuration after the person sets, switches or clears one of the two shortcuts ("hold" or "toggle"). A shortcut that was
    /// just set is switched on: there is no separate mode to pick afterwards.
    func settingShortcut(mode: String, candidate: HotkeySpec?, enabled: Bool?) -> BridgeConfig {
        var c = self
        if mode == "translate" { c.translate.trigger = candidate; return c }
        if mode == "toggle" {
            c.toggleTrigger = candidate
            if candidate == nil { c.toggleShortcutEnabled = enabled ?? false } else { c.toggleShortcutEnabled = enabled ?? true }
        } else {
            if let candidate { c.trigger = candidate }
            if let enabled { c.holdShortcutEnabled = enabled } else if candidate != nil { c.holdShortcutEnabled = true }
            c.triggerConsume = false
        }
        c.syncInputMode()
        return c
    }
    var enabled: Bool
    var mode: String
    var trigger: HotkeySpec
    /// false = 监听模式（NSEvent 全局监听，不拦截，保留实体键原有功能，需"输入监控"权限）
    /// true  = Carbon 拦截模式（RegisterEventHotKey，会吃掉该组合键的原始行为）
    var triggerConsume: Bool
    /// 诊断组合键（默认 F6，无修饰键）：与触发键走同一入口，用于对照真实按键事件入口
    var diagnosticTrigger: HotkeySpec
    var iflytekSourceID: String
    var iflytekVoiceHotkey: HotkeySpec
    var requireSuitableFocus: Bool
    var focusPollMs: Int
    var recordingTimeoutSec: Double   // 按住上限（兜底防失控）；讯飞 60s 单会话由续接机制跨越
    var commitWaitSec: Double
    var recognitionLocale: String
    /// 讯飞识别语言：zh_cn（默认）/ en_us / auto（跟随输入法布局）
    var iflytekLanguage: String
    /// false（默认）：系统不支持本机识别时直接报错，音频不出设备；
    /// true：允许回退到 Apple 联网识别（音频将上传苹果服务器，须用户知情同意）
    var allowCloudRecognition: Bool
    /// 识别服务：apple（默认，本机）/ iflytek（未接入协议，选择后无法录音并如实提示）
    var engine: String
    /// 讯飞云发送同意（与 allowCloudRecognition 相互独立）
    var iflytekConsent: Bool
    /// 首次引导已确认（引导只在首次出现，菜单可再次打开）
    var hasSeenOnboarding: Bool

    init(enabled: Bool, mode: String, trigger: HotkeySpec, triggerConsume: Bool,
         diagnosticTrigger: HotkeySpec, iflytekSourceID: String, iflytekVoiceHotkey: HotkeySpec,
         requireSuitableFocus: Bool, focusPollMs: Int, recordingTimeoutSec: Double,
         commitWaitSec: Double, recognitionLocale: String, iflytekLanguage: String, allowCloudRecognition: Bool,
         engine: String, iflytekConsent: Bool, hasSeenOnboarding: Bool) {
        self.enabled = enabled
        self.mode = mode
        self.trigger = trigger
        self.triggerConsume = triggerConsume
        self.diagnosticTrigger = diagnosticTrigger
        self.iflytekSourceID = iflytekSourceID
        self.iflytekVoiceHotkey = iflytekVoiceHotkey
        self.requireSuitableFocus = requireSuitableFocus
        self.focusPollMs = focusPollMs
        self.recordingTimeoutSec = recordingTimeoutSec
        self.commitWaitSec = commitWaitSec
        self.recognitionLocale = recognitionLocale
        self.iflytekLanguage = iflytekLanguage
        self.allowCloudRecognition = allowCloudRecognition
        self.engine = engine
        self.iflytekConsent = iflytekConsent
        self.hasSeenOnboarding = hasSeenOnboarding
    }

    static func `default`() -> BridgeConfig {
        BridgeConfig(
            enabled: true,
            mode: SessionMode.hold.rawValue,
            // 目标键：键盘左下角印着 start/opt 的实体键 = 左 Option（keyCode 58，照片确认）。
            // 触发语义：单独按下并松开才触发；与其他键组合不触发（见 ListenTrigger.loneModifierTap）。
            trigger: HotkeySpec(keyCode: 58, modifiers: UInt32(optionKey)),
            triggerConsume: false,
            diagnosticTrigger: HotkeySpec(keyCode: 97, modifiers: 0),       // F6 诊断对照键
            iflytekSourceID: "com.iflytek.inputmethod.iFlytekIME.pinyin",
            iflytekVoiceHotkey: HotkeySpec(keyCode: 63, modifiers: UInt32(controlKey)), // 截图显示 ⌃Fn；以讯飞设置界面为准
            requireSuitableFocus: true,
            focusPollMs: 300,
            recordingTimeoutSec: 600,
            commitWaitSec: 15,
            recognitionLocale: "zh-CN",
            iflytekLanguage: "zh_cn",
            allowCloudRecognition: false,
            engine: "apple",
            iflytekConsent: false,
            hasSeenOnboarding: false
        )
    }

    /// F 键与扩展键（含 F13–F20、Launchpad/DVR 等扩展键码）无修饰键也可作触发键
    static func isExtendedKey(_ code: UInt32) -> Bool {
        let k = Int(code)
        return (96...123).contains(k) || [64, 79, 80, 90, 179, 180].contains(k)
    }

    static func validate(_ c: BridgeConfig) -> [String] {
        var errs: [String] = []
        if ASREngine(rawValue:c.engine)==nil { errs.append(L10n.tr("ui.89450da07dc8")) }
        if !c.triggerThresholdSec.isFinite || !(0.2...0.6).contains(c.triggerThresholdSec) {errs.append(L10n.tr("ui.d8f0cfdfdf8c"))}
        if !c.triggerNoSpeechSec.isFinite || c.triggerNoSpeechSec <= 0 || !c.triggerPostSpeechSec.isFinite || c.triggerPostSpeechSec <= 0 {errs.append(L10n.tr("ui.fef421c936c8"))}
        if !["hybrid","hold","toggle"].contains(c.inputMode) { errs.append(L10n.tr("ui.117ccf9426f8")) }
        if c.toggleShortcutEnabled && c.toggleTrigger == nil { errs.append(L10n.tr("ui.96f8564c9147")) }
        if let toggle=c.toggleTrigger {
            if toggle.keyCode == c.trigger.keyCode && toggle.modifiers == c.trigger.modifiers { errs.append(L10n.tr("ui.998b5cd9d078")) }
            if let reason=ShortcutPolicy.basicReason(toggle,standardFunctionKeys:true) { errs.append(reason) }
        }
        if let t=c.translate.trigger {
            if let reason=ShortcutPolicy.basicReason(t,standardFunctionKeys:true) { errs.append(reason) }
            // A shortcut that is switched off cannot clash with anything.
            var others:[HotkeySpec]=[]; if c.holdShortcutEnabled {others.append(c.trigger)}; if c.toggleActive,let toggle=c.toggleTrigger {others.append(toggle)}
            if let s=c.screenshot.trigger {others.append(s)}; if let o=c.screenshot.ocrTrigger {others.append(o)}
            if others.contains(where:{ShortcutPolicy.overlaps(t,$0)}) { errs.append(L10n.tr("translate.shortcut.conflict")) }
        }
        if SessionMode(rawValue: c.mode) == nil { errs.append(L10n.tr("ui.9810e873ddf8")) }
        if c.iflytekSourceID.isEmpty { errs.append(L10n.tr("ui.5a0016b900bc")) }
        if c.recognitionLocale.isEmpty { errs.append(L10n.tr("ui.658b6372fbf9")) }
        if ["auto", "zh_cn", "en_us"].contains(c.iflytekLanguage) == false { errs.append(L10n.tr("ui.cc7557cc956b")) }
        if c.trigger == c.iflytekVoiceHotkey { errs.append(L10n.tr("ui.605928967074")) }
        if c.diagnosticTrigger == c.iflytekVoiceHotkey { errs.append(L10n.tr("ui.eb899f91d2da")) }
        if let reason = ShortcutPolicy.basicReason(c.trigger, standardFunctionKeys: true) { errs.append(reason) }
        if c.diagnosticTrigger.modifiers == 0 && !isExtendedKey(c.diagnosticTrigger.keyCode) {
            errs.append(L10n.tr("ui.6290f3e844d2"))
        }
        if !["system","light","dark"].contains(c.appearanceMode) {errs.append(L10n.tr("ui.b32dded01262"))}
        if c.focusPollMs < 50 { errs.append(L10n.tr("ui.36948a4a7247")) }
        if c.recordingTimeoutSec <= 0 { errs.append(L10n.tr("ui.c9954390c4b6")) }
        if c.commitWaitSec <= 0 { errs.append(L10n.tr("ui.937c7820df19")) }
        if !c.localModel.recognition.valid {errs.append(L10n.tr("local.err.options"))}
        if LLMProfiles.problem(c.llmProfiles) != nil {errs.append(L10n.tr("llm.err.profiles"))}
        if !LocalASRCorrection.valid(c.localASRMappings){errs.append(L10n.tr("ui.c67ce92c6e74"))}
        for (key,_) in c.cloudASR {if let e=ASREngine(rawValue:key),let reason=ASROptionPolicy.validate(e,c.options(e)){errs.append(reason)}}
        return errs
    }

    enum CodingKeys: String, CodingKey {
        case triggerCoordinatorEnabled, triggerThresholdSec, triggerNoSpeechSec, triggerPostSpeechSec
        case localModel, screenshot, polish, refine, vocabulary, translate, llmProfiles
        case cloudASR, localASRMappings, appearanceMode, microphoneUID, inputMode, holdShortcutEnabled, toggleShortcutEnabled, toggleTrigger
        case enabled, mode, trigger, triggerConsume, diagnosticTrigger, iflytekSourceID, iflytekVoiceHotkey
        case requireSuitableFocus, focusPollMs, recordingTimeoutSec, commitWaitSec, recognitionLocale
        case hasSeenOnboarding
        case iflytekLanguage
        case allowCloudRecognition, engine, iflytekConsent
    }

    /// 兼容旧配置：缺失键回落默认值
    init(from decoder: Decoder) throws {
        let d = try decoder.container(keyedBy: CodingKeys.self)
        let base = BridgeConfig.default()
        cloudASR = try d.decodeIfPresent([String:CloudASROptions].self,forKey:.cloudASR) ?? [:]
        localModel = try d.decodeIfPresent(LocalModelSettings.self,forKey:.localModel) ?? LocalModelSettings()
        screenshot = try d.decodeIfPresent(ScreenshotSettings.self,forKey:.screenshot) ?? ScreenshotSettings()
        polish = try d.decodeIfPresent(TextPolishSettings.self,forKey:.polish) ?? TextPolishSettings()
        refine = try d.decodeIfPresent(TextRefineSettings.self,forKey:.refine) ?? TextRefineSettings()
        vocabulary = try d.decodeIfPresent(VocabularySettings.self,forKey:.vocabulary) ?? VocabularySettings()
        translate = try d.decodeIfPresent(TranslateSettings.self,forKey:.translate) ?? TranslateSettings()
        llmProfiles = (try? d.decodeIfPresent([LLMProfile].self,forKey:.llmProfiles)) ?? []
        localASRMappings = try d.decodeIfPresent([LocalASRMapping].self,forKey:.localASRMappings) ?? []
        appearanceMode = try d.decodeIfPresent(String.self,forKey:.appearanceMode) ?? "system"
        microphoneUID = try d.decodeIfPresent(String.self, forKey: .microphoneUID) ?? ""
        triggerCoordinatorEnabled = try d.decodeIfPresent(Bool.self, forKey: .triggerCoordinatorEnabled) ?? false
        triggerThresholdSec = try d.decodeIfPresent(Double.self, forKey: .triggerThresholdSec) ?? 0.3
        triggerNoSpeechSec = try d.decodeIfPresent(Double.self, forKey: .triggerNoSpeechSec) ?? 10
        triggerPostSpeechSec = try d.decodeIfPresent(Double.self, forKey: .triggerPostSpeechSec) ?? 20
        inputMode = try d.decodeIfPresent(String.self, forKey: .inputMode) ?? "hold"
        holdShortcutEnabled = try d.decodeIfPresent(Bool.self,forKey:.holdShortcutEnabled) ?? true
        toggleShortcutEnabled = try d.decodeIfPresent(Bool.self,forKey:.toggleShortcutEnabled) ?? false
        toggleTrigger = try d.decodeIfPresent(HotkeySpec.self,forKey:.toggleTrigger)
        enabled = try d.decodeIfPresent(Bool.self, forKey: .enabled) ?? base.enabled
        mode = try d.decodeIfPresent(String.self, forKey: .mode) ?? base.mode
        trigger = try d.decodeIfPresent(HotkeySpec.self, forKey: .trigger) ?? base.trigger
        triggerConsume = try d.decodeIfPresent(Bool.self, forKey: .triggerConsume) ?? base.triggerConsume
        diagnosticTrigger = try d.decodeIfPresent(HotkeySpec.self, forKey: .diagnosticTrigger) ?? base.diagnosticTrigger
        iflytekSourceID = try d.decodeIfPresent(String.self, forKey: .iflytekSourceID) ?? base.iflytekSourceID
        iflytekVoiceHotkey = try d.decodeIfPresent(HotkeySpec.self, forKey: .iflytekVoiceHotkey) ?? base.iflytekVoiceHotkey
        requireSuitableFocus = try d.decodeIfPresent(Bool.self, forKey: .requireSuitableFocus) ?? base.requireSuitableFocus
        focusPollMs = try d.decodeIfPresent(Int.self, forKey: .focusPollMs) ?? base.focusPollMs
        recordingTimeoutSec = try d.decodeIfPresent(Double.self, forKey: .recordingTimeoutSec) ?? base.recordingTimeoutSec
        commitWaitSec = try d.decodeIfPresent(Double.self, forKey: .commitWaitSec) ?? base.commitWaitSec
        hasSeenOnboarding = try d.decodeIfPresent(Bool.self, forKey: .hasSeenOnboarding) ?? base.hasSeenOnboarding
        recognitionLocale = try d.decodeIfPresent(String.self, forKey: .recognitionLocale) ?? base.recognitionLocale
        iflytekLanguage = try d.decodeIfPresent(String.self, forKey: .iflytekLanguage) ?? base.iflytekLanguage
        allowCloudRecognition = try d.decodeIfPresent(Bool.self, forKey: .allowCloudRecognition) ?? base.allowCloudRecognition
        engine = try d.decodeIfPresent(String.self, forKey: .engine) ?? base.engine
        iflytekConsent = try d.decodeIfPresent(Bool.self, forKey: .iflytekConsent) ?? base.iflytekConsent
        migrateLLMProfiles()
    }

    func encode(to encoder: Encoder) throws {
        var d = encoder.container(keyedBy: CodingKeys.self)
        try d.encode(cloudASR,forKey:.cloudASR)
        try d.encode(localModel,forKey:.localModel)
        try d.encode(screenshot,forKey:.screenshot)
        try d.encode(polish,forKey:.polish)
        try d.encode(refine,forKey:.refine)
        try d.encode(vocabulary,forKey:.vocabulary)
        try d.encode(translate,forKey:.translate)
        try d.encode(llmProfiles,forKey:.llmProfiles)
        try d.encode(localASRMappings,forKey:.localASRMappings)
        try d.encode(appearanceMode,forKey:.appearanceMode)
        try d.encode(microphoneUID, forKey: .microphoneUID)
        try d.encode(triggerCoordinatorEnabled,forKey:.triggerCoordinatorEnabled)
        try d.encode(triggerThresholdSec,forKey:.triggerThresholdSec)
        try d.encode(triggerNoSpeechSec,forKey:.triggerNoSpeechSec)
        try d.encode(triggerPostSpeechSec,forKey:.triggerPostSpeechSec)
        try d.encode(inputMode, forKey: .inputMode)
        try d.encode(holdShortcutEnabled,forKey:.holdShortcutEnabled)
        try d.encode(toggleShortcutEnabled,forKey:.toggleShortcutEnabled)
        try d.encodeIfPresent(toggleTrigger,forKey:.toggleTrigger)
        try d.encode(enabled, forKey: .enabled)
        try d.encode(mode, forKey: .mode)
        try d.encode(trigger, forKey: .trigger)
        try d.encode(triggerConsume, forKey: .triggerConsume)
        try d.encode(diagnosticTrigger, forKey: .diagnosticTrigger)
        try d.encode(iflytekSourceID, forKey: .iflytekSourceID)
        try d.encode(iflytekVoiceHotkey, forKey: .iflytekVoiceHotkey)
        try d.encode(requireSuitableFocus, forKey: .requireSuitableFocus)
        try d.encode(focusPollMs, forKey: .focusPollMs)
        try d.encode(recordingTimeoutSec, forKey: .recordingTimeoutSec)
        try d.encode(commitWaitSec, forKey: .commitWaitSec)
        try d.encode(hasSeenOnboarding, forKey: .hasSeenOnboarding)
        try d.encode(recognitionLocale, forKey: .recognitionLocale)
        try d.encode(iflytekLanguage, forKey: .iflytekLanguage)
        try d.encode(allowCloudRecognition, forKey: .allowCloudRecognition)
        try d.encode(engine, forKey: .engine)
        try d.encode(iflytekConsent, forKey: .iflytekConsent)
    }
}

enum AppPaths {
    static let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cadenza", isDirectory: true)   // settings, models and logs; the old folder is moved here once by LegacyMigration
    static let configFile = supportDir.appendingPathComponent("config.json")
    static let logFile = supportDir.appendingPathComponent("log.txt")
    static let testField = supportDir.appendingPathComponent("test-field.html")
}

final class ConfigStore {
    private(set) var config: BridgeConfig
    private(set) var validationErrors: [String] = []

    private let fileURL:URL
    private let writeFile:(Data,URL)throws->Void

    private static let isolatedSelfTestFile=FileManager.default.temporaryDirectory.appendingPathComponent("trigger-regression-"+UUID().uuidString).appendingPathComponent("config.json")
    init(fileURL requestedFileURL:URL=AppPaths.configFile,writeFile:@escaping(Data,URL)throws->Void={data,url in try data.write(to:url,options:.atomic)}) {
        // Every self-test suite works on a scratch config; only "--selftest" used to, so the others read and could pick up the person's own settings.
        let fileURL=CommandLine.arguments.contains(where:{$0.hasPrefix("--selftest")}) && requestedFileURL == AppPaths.configFile ? Self.isolatedSelfTestFile:requestedFileURL
        self.fileURL=fileURL;self.writeFile=writeFile
        if FileManager.default.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode(BridgeConfig.self, from: data) {
            let errs = BridgeConfig.validate(loaded)
            if errs.isEmpty {
                config = loaded
            } else {
                config = BridgeConfig.default()
                validationErrors = ["配置文件校验失败，已用内置默认：" + errs.joined(separator: "；")]
            }
        } else {
            config = BridgeConfig.default()
            if FileManager.default.fileExists(atPath: fileURL.path) {
                validationErrors = ["配置文件解析失败，已用内置默认"]
            } else {
                save() // 首次运行写出有效默认配置，保证菜单编辑/重载路径可用
                Log.write("first-run default-config-written")
            }
        }
    }

    /// 显式重载：校验通过才替换，失败沿用当前配置并返回 false
    @discardableResult
    func reload() -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode(BridgeConfig.self, from: data) else {
            validationErrors = ["重载失败：配置文件读取/解析错误（沿用当前配置）"]
            return false
        }
        let errs = BridgeConfig.validate(loaded)
        if !errs.isEmpty {
            validationErrors = ["重载失败，校验未通过：" + errs.joined(separator: "；") + "（沿用当前配置）"]
            return false
        }
        config = loaded
        validationErrors = []
        return true
    }

    /// 带校验的字段修改：通过校验才生效
    @discardableResult
    func mutate(_ body: (inout BridgeConfig) -> Void) -> Bool {
        var copy = config
        body(&copy)
        let errs = BridgeConfig.validate(copy)
        guard errs.isEmpty else {
            validationErrors = ["修改被拒绝：" + errs.joined(separator: "；")]
            return false
        }
        config = copy
        validationErrors = []
        return true
    }

    @discardableResult
    func save() -> Bool {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let data = try JSONEncoder().encode(config)
            try writeFile(data,fileURL)
            return true
        } catch { return false }
    }
}

/// 只记录状态流转，绝不记录音频、识别文本或按键内容。
enum Log {
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func write(_ msg: String) {
        if (CommandLine.arguments.contains("--selftest-settings-ui") || CommandLine.arguments.contains("--diagnose-trigger-latency") || CommandLine.arguments.contains("--diagnose-trigger-network") || CommandLine.arguments.contains("--selftest-trigger-stage2") || CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--selftest-asr-settings") || CommandLine.arguments.contains("--selftest-asr-entry") || CommandLine.arguments.contains("--selftest-wechat-native")) {FileHandle.standardError.write(Data(("[selftest-event] " + msg + "\n").utf8));return}
        let line = "\(fmt.string(from: Date())) \(msg)"
        Diagnostics.append(msg)   // 内存诊断环：界面"诊断区"只读这里，不含音频/文本/凭据
        let out = line + "\n"
        // The on-disk diagnostic log is optional (Settings → Privacy) and size-capped; it never leaves this Mac.
        if DiagnosticLogging.enabled {
            try? FileManager.default.createDirectory(at: AppPaths.supportDir, withIntermediateDirectories: true)
            if let data = out.data(using: .utf8) {
                if let h = try? FileHandle(forWritingTo: AppPaths.logFile) {
                    h.seekToEndOfFile()
                    h.write(data)
                    h.closeFile()
                } else {
                    try? data.write(to: AppPaths.logFile, options: .atomic)
                }
            }
            LogFile.noteWrite()
        }
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }
}

extension BridgeConfig {
    /// The options a recording actually uses. Deepgram's "multilingual" mode has no Mandarin, so when the app is set up
    /// for Chinese the default is replaced by the matching Chinese model language (measured: garbage text otherwise).
    func recordingOptions(_ engine:ASREngine)->CloudASROptions {
        var o=options(engine)
        if engine == .deepgram {o.language=DeepgramAPI.effectiveLanguage(o.language,recognitionLocale:recognitionLocale)}
        var applied=VocabularyHotwords.apply(engine,to:o,settings:vocabulary)
        // Whisper-style services guess the language and the script on their own: measured on real recordings they answered
        // in Traditional characters for Simplified speech. When the app is set to Chinese, name the language and say which script.
        if BatchTranscription.service(engine) != nil,applied.language == "multi",let hint=BatchTranscription.chineseHint(recognitionLocale:recognitionLocale) {
            applied.language="zh"
            applied.hotwords=applied.hotwords.isEmpty ? hint:hint+"\n"+applied.hotwords
        }
        return applied
    }
    func options(_ engine:ASREngine)->CloudASROptions {
        var o=cloudASR[engine.rawValue] ?? .defaults(engine)
        if o.model.isEmpty{o.model=CloudASROptions.defaults(engine).model}
        if engine == .iflytek {o.consent=iflytekConsent}
        return o
    }
    mutating func setOptions(_ engine:ASREngine,_ options:CloudASROptions){cloudASR[engine.rawValue]=options;if engine == .iflytek{iflytekConsent=options.consent}}
}
