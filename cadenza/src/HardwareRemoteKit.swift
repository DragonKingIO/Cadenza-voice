import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import CoreBluetooth
import Foundation
import IOKit
import IOKit.hid
import Observation
import Speech
import SwiftUI

// MARK: - 1. IMA/DVI ADPCM 16kHz 解码器 (ATVV 标准高半字节优先)

struct RemoteIMAADPCMDecoder {
    static let stepTable: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
        19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
        130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
        337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
        2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
        5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
    ]
    static let indexTable: [Int] = [
        -1, -1, -1, -1, 2, 4, 6, 8,
        -1, -1, -1, -1, 2, 4, 6, 8
    ]

    var predictor: Int = 0
    var stepIndex: Int = 0

    mutating func reset(initialPredictor: Int = 0, initialIndex: Int = 0) {
        predictor = max(-32768, min(32767, initialPredictor))
        stepIndex = max(0, min(88, initialIndex))
    }

    mutating func decodeNibble(_ nibble: UInt8, gain: Float = 1.0) -> Int16 {
        let code = Int(nibble & 0x0F)
        let step = Self.stepTable[stepIndex]

        var diff = step >> 3
        if (code & 0x01) != 0 { diff += step >> 2 }
        if (code & 0x02) != 0 { diff += step >> 1 }
        if (code & 0x04) != 0 { diff += step }
        if (code & 0x08) != 0 { diff = -diff }

        predictor = max(-32768, min(32767, predictor + diff))
        stepIndex = max(0, min(88, stepIndex + Self.indexTable[code]))

        if abs(gain - 1.0) < 0.01 {
            return Int16(predictor)
        }
        let amplified = Int((Float(predictor) * gain).rounded())
        return Int16(max(-32768, min(32767, amplified)))
    }

    /// ATVV 标准：High-Nibble First（先解高 4 位，后解低 4 位），输出 16kHz S16LE 单声道 PCM
    mutating func decode(adpcmData: Data, gain: Float = 1.0) -> Data {
        var pcmData = Data(capacity: adpcmData.count * 4)
        for byte in adpcmData {
            let high = (byte >> 4) & 0x0F
            let low = byte & 0x0F

            var s1 = decodeNibble(high, gain: gain).littleEndian
            withUnsafeBytes(of: &s1) { pcmData.append(contentsOf: $0) }

            var s2 = decodeNibble(low, gain: gain).littleEndian
            withUnsafeBytes(of: &s2) { pcmData.append(contentsOf: $0) }
        }
        return pcmData
    }
}

// MARK: - 2. Apple Speech 外部 16kHz PCM 识别适配器（补齐内置识别对外部 PCM 源的支持）

final class AppleSpeechExternalPCMRecorder: HoldRecordingSession {
    private let capture: ExternalPCMSource
    private let locale: String
    private let allowCloud: Bool
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finalHandler: ((String?) -> Void)?
    private var active = false
    private var deliveredOnce = false

    var onLevel: ((Float) -> Void)?
    var onPartial: ((String) -> Void)?
    var onFinal: ((String?) -> Void)?
    private(set) var lastError: String?
    var captureStartedUptime: TimeInterval? { capture.startedUptime }
    var capturedAudioHasSignal: Bool? { capture.hasSignal }

    init(capture: ExternalPCMSource, locale: String, allowCloud: Bool) {
        self.capture = capture
        self.locale = locale
        self.allowCloud = allowCloud
    }

    func begin() -> Bool {
        guard HoldNativeEngine.speechAuthorized() else {
            lastError = L10n.tr("ui.60916822baf4")
            return false
        }
        guard !active else { return false }
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: locale)),
              rec.supportsOnDeviceRecognition || allowCloud else {
            lastError = L10n.tr("ui.af99029c7185")
            return false
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else {
            lastError = L10n.tr("ui.9275ca79cfc9")
            return false
        }

        deliveredOnce = false
        lastError = nil
        finalHandler = onFinal

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        self.request = req

        capture.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.onLevel?(level) }
        }
        capture.onPCM = { [weak req] pcmData in
            let frameCount = AVAudioFrameCount(pcmData.count / 2)
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
                  let dst = buffer.int16ChannelData?[0] else { return }
            buffer.frameLength = frameCount
            pcmData.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                memcpy(dst, base, Int(frameCount) * 2)
            }
            req?.append(buffer)
        }

        _ = capture.start(uid: "ble-atvv-remote")
        active = true
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    self.deliverFinal(text)
                } else if !text.isEmpty {
                    self.onPartial?(text)
                }
            }
            if error != nil, self.finalHandler != nil {
                self.deliverFinal(nil)
            }
        }
        return true
    }

    func end() {
        guard active else { return }
        active = false
        capture.stop()
        let req = request
        req?.endAudio()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self, weak req] in
            guard let self = self, self.request != nil, self.request === req, self.finalHandler != nil else { return }
            self.deliverFinal(nil)
        }
    }

    func abort() {
        if active {
            active = false
            capture.stop()
        }
        deliveredOnce = true
        capture.onPCM = nil
        capture.onLevel = nil
        onFinal = nil
        onPartial = nil
        task?.cancel()
        task = nil
        request = nil
        finalHandler = nil
    }

    private func deliverFinal(_ text: String?) {
        guard !deliveredOnce else { return }
        deliveredOnce = true
        let cb = finalHandler
        finalHandler = nil
        task = nil
        request = nil
        cb?(text)
    }
}

// MARK: - 3. 13 键硬件按键定义与可持久化预设配置
// 规则：语音输入动作（按住说话 / 单击说话）仅限物理【语音键 (🎤)】独占使用；
// 其余 12 个按键均可自由调整为任意非语音动作或自定义键盘快捷键！

enum HardwareRemoteKey: String, CaseIterable, Codable, Identifiable {
    case voice      // 0x07:0x3E (F5) — 硬件麦克风专属语音键
    case ok         // 0x07:0x28 (Return)
    case back       // 0x07:0xF1 (Back)
    case up         // 0x07:0x52
    case down       // 0x07:0x51
    case left       // 0x07:0x50
    case right      // 0x07:0x4F
    case home       // 0x07:0x4A
    case menu       // 0x07:0x65
    case tv         // 0x07:0x35
    case volumeUp   // 0x07:0x80
    case volumeDown // 0x07:0x81
    case power      // 0x07:0x66

    var id: String { rawValue }

    var isDedicatedVoiceKey: Bool { self == .voice }

    var displayName: String {
        switch self {
        case .voice: return L10n.tr("hardware.key.voice")
        case .ok: return L10n.tr("hardware.key.ok")
        case .back: return L10n.tr("hardware.key.back")
        case .up: return L10n.tr("hardware.key.up")
        case .down: return L10n.tr("hardware.key.down")
        case .left: return L10n.tr("hardware.key.left")
        case .right: return L10n.tr("hardware.key.right")
        case .home: return L10n.tr("hardware.key.home")
        case .menu: return L10n.tr("hardware.key.menu")
        case .tv: return L10n.tr("hardware.key.tv")
        case .volumeUp: return L10n.tr("hardware.key.volumeUp")
        case .volumeDown: return L10n.tr("hardware.key.volumeDown")
        case .power: return L10n.tr("hardware.key.power")
        }
    }

    var symbolName: String {
        switch self {
        case .voice: return "mic.fill"
        case .ok: return "circle.circle.fill"
        case .back: return "chevron.backward.circle"
        case .up: return "chevron.up"
        case .down: return "chevron.down"
        case .left: return "chevron.left"
        case .right: return "chevron.right"
        case .home: return "house"
        case .menu: return "line.3.horizontal"
        case .tv: return "tv"
        case .volumeUp: return "speaker.wave.3.fill"
        case .volumeDown: return "speaker.wave.1.fill"
        case .power: return "power"
        }
    }

    static func fromHID(page: UInt32, usage: UInt32) -> HardwareRemoteKey? {
        switch (page, usage) {
        case (0x07, 0x3E), (0x0C, 0x00CF), (0x0C, 0x0221), (0xFF00, 0x48): return .voice
        case (0x07, 0x28): return .ok
        case (0x07, 0xF1), (0x07, 0x29), (0x0C, 0x0224): return .back
        case (0x07, 0x52): return .up
        case (0x07, 0x51): return .down
        case (0x07, 0x50): return .left
        case (0x07, 0x4F): return .right
        case (0x07, 0x4A), (0x0C, 0x0223): return .home
        case (0x07, 0x65), (0x0C, 0x0040): return .menu
        case (0x07, 0x35): return .tv
        case (0x07, 0x80), (0x0C, 0x00E9): return .volumeUp
        case (0x07, 0x81), (0x0C, 0x00EA): return .volumeDown
        case (0x07, 0x66): return .power
        default: return nil
        }
    }
}

enum HardwareRemoteAction: String, CaseIterable, Codable, Identifiable {
    // 仅限【语音键 (🎤)】使用的语音专属动作
    case holdToTalk          // 按住说话，松开上屏（硬件麦克风专属）
    case toggleVoice         // 单击开始 / 再按停止语音输入（硬件麦克风专属）

    // 其余 12 个按键可自由调整的全部非语音动作
    case confirmReturn       // 立即完成录音并发送回车 (Return ↵)
    case cancelOrBackspace   // 录音中取消；非录音时发送退格删除 (Backspace ⌫)
    case cancelOrEscape      // 录音中取消；非录音时发送 Esc (⎋)
    case arrowUp             // 光标上移 (↑)
    case arrowDown           // 光标下移 (↓)
    case arrowLeft           // 光标左移 (←)
    case arrowRight          // 光标右移 (→)
    case space               // 发送空格 (Space)
    case tab                 // 发送制表符 (Tab ⇥)
    case copyShortcut        // 复制选中内容 (⌘C)
    case pasteShortcut       // 粘贴 (⌘V)
    case undoShortcut        // 撤销 (⌘Z)
    case copyLastResult      // 复制最近一次语音识别结果
    case openSettings        // 打开随言设置窗口
    case startScreenshot     // 开始随言区域截图
    case startDirectOCR      // 开始随言截图取字 (OCR)
    case systemVolumeUp      // 调高系统音量
    case systemVolumeDown    // 调低系统音量
    case systemMute          // 系统静音切换
    case customShortcut      // 自定义键盘快捷键 (HotkeySpec)
    case disabled            // 静默屏蔽（不向系统发送按键）

    var id: String { rawValue }

    var isVoiceAction: Bool {
        self == .holdToTalk || self == .toggleVoice
    }

    /// 语音键 (🎤) 专属可选动作
    static var voiceKeyOptions: [HardwareRemoteAction] {
        [.holdToTalk, .toggleVoice]
    }

    /// 其余 12 个按键可选动作（严禁包含语音动作，确保只有语音键触发语音）
    static var nonVoiceKeyOptions: [HardwareRemoteAction] {
        allCases.filter { !$0.isVoiceAction }
    }

    var displayName: String {
        switch self {
        case .holdToTalk: return L10n.tr("hardware.act.holdToTalk")
        case .toggleVoice: return L10n.tr("hardware.act.toggleVoice")
        case .confirmReturn: return L10n.tr("hardware.act.confirmReturn")
        case .cancelOrBackspace: return L10n.tr("hardware.act.cancelOrBackspace")
        case .cancelOrEscape: return L10n.tr("hardware.act.cancelOrEscape")
        case .arrowUp: return L10n.tr("hardware.act.arrowUp")
        case .arrowDown: return L10n.tr("hardware.act.arrowDown")
        case .arrowLeft: return L10n.tr("hardware.act.arrowLeft")
        case .arrowRight: return L10n.tr("hardware.act.arrowRight")
        case .space: return L10n.tr("hardware.act.space")
        case .tab: return L10n.tr("hardware.act.tab")
        case .copyShortcut: return L10n.tr("hardware.act.copy")
        case .pasteShortcut: return L10n.tr("hardware.act.paste")
        case .undoShortcut: return L10n.tr("hardware.act.undo")
        case .copyLastResult: return L10n.tr("hardware.act.copyLast")
        case .openSettings: return L10n.format("hardware.act.openSettings", String(describing: Brand.name))
        case .startScreenshot: return L10n.format("hardware.act.screenshot", String(describing: Brand.name))
        case .startDirectOCR: return L10n.format("hardware.act.ocr", String(describing: Brand.name))
        case .systemVolumeUp: return L10n.tr("hardware.act.sysVolUp")
        case .systemVolumeDown: return L10n.tr("hardware.act.sysVolDown")
        case .systemMute: return L10n.tr("hardware.act.sysMute")
        case .customShortcut: return L10n.tr("hardware.act.custom")
        case .disabled: return L10n.tr("hardware.act.disabled")
        }
    }
}

struct HardwareRemoteConfig: Codable, Equatable {
    var isPaired: Bool = false
    var deviceName: String = "小米蓝牙语音遥控器"
    var vendorID: Int = 0x2717
    var productID: Int = 0x32B8
    var seizeHID: Bool = true
    var autoPopCardOnConnect: Bool = true
    var micGain: Float = 1.0
    var keyMappings: [String: String] = Self.defaultVoiceAssistantMappings
    var customShortcuts: [String: HotkeySpec] = [:]

    static var defaultVoiceAssistantMappings: [String: String] {
        [
            HardwareRemoteKey.voice.rawValue: HardwareRemoteAction.holdToTalk.rawValue,
            HardwareRemoteKey.ok.rawValue: HardwareRemoteAction.confirmReturn.rawValue,
            HardwareRemoteKey.back.rawValue: HardwareRemoteAction.cancelOrBackspace.rawValue,
            HardwareRemoteKey.up.rawValue: HardwareRemoteAction.arrowUp.rawValue,
            HardwareRemoteKey.down.rawValue: HardwareRemoteAction.arrowDown.rawValue,
            HardwareRemoteKey.left.rawValue: HardwareRemoteAction.arrowLeft.rawValue,
            HardwareRemoteKey.right.rawValue: HardwareRemoteAction.arrowRight.rawValue,
            HardwareRemoteKey.home.rawValue: HardwareRemoteAction.openSettings.rawValue,
            HardwareRemoteKey.menu.rawValue: HardwareRemoteAction.copyLastResult.rawValue,
            HardwareRemoteKey.tv.rawValue: HardwareRemoteAction.startDirectOCR.rawValue,
            HardwareRemoteKey.volumeUp.rawValue: HardwareRemoteAction.systemVolumeUp.rawValue,
            HardwareRemoteKey.volumeDown.rawValue: HardwareRemoteAction.systemVolumeDown.rawValue,
            HardwareRemoteKey.power.rawValue: HardwareRemoteAction.disabled.rawValue
        ]
    }

    func action(for key: HardwareRemoteKey) -> HardwareRemoteAction {
        if key.isDedicatedVoiceKey {
            if let raw = keyMappings[key.rawValue],
               let act = HardwareRemoteAction(rawValue: raw),
               act.isVoiceAction {
                return act
            }
            return .holdToTalk
        }
        guard let raw = keyMappings[key.rawValue],
              let act = HardwareRemoteAction(rawValue: raw),
              !act.isVoiceAction else {
            if let defaultRaw = Self.defaultVoiceAssistantMappings[key.rawValue],
               let defaultAct = HardwareRemoteAction(rawValue: defaultRaw) {
                return defaultAct
            }
            return .disabled
        }
        return act
    }

    mutating func setAction(_ action: HardwareRemoteAction, for key: HardwareRemoteKey) {
        if key.isDedicatedVoiceKey {
            keyMappings[key.rawValue] = (action.isVoiceAction ? action : .holdToTalk).rawValue
        } else {
            guard !action.isVoiceAction else { return }
            keyMappings[key.rawValue] = action.rawValue
        }
    }

    func customShortcut(for key: HardwareRemoteKey) -> HotkeySpec? {
        customShortcuts[key.rawValue]
    }

    mutating func setCustomShortcut(_ spec: HotkeySpec?, for key: HardwareRemoteKey) {
        customShortcuts[key.rawValue] = spec
    }
}

// MARK: - 4. 原生硬件外设总控引擎 (BLE ATVV + IOHID 独占去重 + 休眠静默重连)

@Observable
final class HardwareRemoteCenter: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = HardwareRemoteCenter()

    static let targetVendorID = 0x2717
    static let targetProductID = 0x32B8
    static let atvvServiceUUID = CBUUID(string: "AB5E0001-5A21-4F05-BC7D-AF01F617B664")
    static let batteryServiceUUID = CBUUID(string: "180F")
    static let hidServiceUUID = CBUUID(string: "1812")
    static let batteryCharUUID = CBUUID(string: "2A19")

    // 可观测状态（驱动 AirPods 配对弹窗与设置页实时刷新）
    var config: HardwareRemoteConfig
    var isHIDConnected = false
    /// 菜单栏里的一行：已接入的遥控器及其状态；未接入时为 nil。
    var menuSummary: (title: String, status: String)? {
        guard config.isPaired else { return nil }
        let online = isBLEConnected || isHIDConnected
        var status = online ? L10n.tr("hardware.connected") : L10n.tr("hardware.standby")
        if online, let battery = batteryLevel { status += " · \(battery)%" }
        return (remoteModel.title, status)
    }
    /// 试说卡片正在显示：这段识别只在卡片里反馈，不弹输入框旁的录音条。
    var isTrialCardActive: Bool { pairingPanel.isShowingTrialStep }
    /// 正被按住（及松开后短暂保留）的遥控器按键，用于设置页和示意图实时亮起。
    var litKeys: Set<HardwareRemoteKey> = []
    /// 按键测试：按键只亮灯，不执行动作、不触发识别。
    var keyTestMode = false
    @ObservationIgnored private var testVoiceLatched = false
    @ObservationIgnored private var levelBoostInstalled = false
    @ObservationIgnored private var lastAudioPacketAt = Date()
    @ObservationIgnored private var streamWatchdog: Timer?
    /// 由 HID/BLE 读到的设备名决定外观（名字含 Pro 为 2 Pro）。
    var remoteModel: XiaomiRemoteModel { XiaomiRemoteModel.detect(config.deviceName) }
    var isBLEConnected = false
    var isATVVReady = false
    var isStreamingVoice = false
    var batteryLevel: Int? = nil
    var liveAudioLevel: Float = 0
    var lastPressedKey: HardwareRemoteKey? = nil
    var lastPressedAt: Date? = nil
    var inputMonitoringGranted: Bool = false
    var trialCompletedTranscript: String? = nil
    var recordingShortcutForKey: HardwareRemoteKey? = nil

    @ObservationIgnored weak var pipeline: VoicePipeline?
    @ObservationIgnored private let configURL: URL
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var hidManager: IOHIDManager?
    /// 按 IOHIDDevice 的 CFHashCode 去重，彻底消除 Stage 0 实测发现的 3 次重复回调
    @ObservationIgnored private var seizedDeviceHashes: Set<CFHashCode> = []
    @ObservationIgnored private var keyDownState: [HardwareRemoteKey: Bool] = [:]
    @ObservationIgnored private var shortcutRecordMonitor: Any?

    // ATVV GATT 特征与音频解码状态
    @ObservationIgnored private var atvvTxChar: CBCharacteristic?
    @ObservationIgnored private var atvvAudioChar: CBCharacteristic?
    @ObservationIgnored private var atvvCtlChar: CBCharacteristic?
    @ObservationIgnored private var negotiatedATVVVersionMajor: UInt8 = 1
    @ObservationIgnored private var activeSessionId: UInt8 = 0
    @ObservationIgnored private var didReceiveCapsResponse = false
    @ObservationIgnored private var pendingNotifySubscriptions = 0
    @ObservationIgnored private var didTriggerHandshake = false
    @ObservationIgnored private var decoder = RemoteIMAADPCMDecoder()
    @ObservationIgnored private var activePCMSource: ExternalPCMSource?
    @ObservationIgnored private var previousRecorderFactory: (() -> HoldRecordingSession)?
    @ObservationIgnored private var didDismissPairingPromptForCurrentConnection = false
    @ObservationIgnored lazy var pairingPanel = RemotePairingPanelController(center: self)

    override init() {
        self.configURL = AppPaths.supportDir.appendingPathComponent("hardware-remotes.json")
        if let data = try? Data(contentsOf: configURL),
           var decoded = try? JSONDecoder().decode(HardwareRemoteConfig.self, from: data) {
            // 强制清洗历史配置：确保语音键只绑定语音动作，非语音键绝不绑定语音动作
            for k in HardwareRemoteKey.allCases {
                let valid = decoded.action(for: k)
                decoded.setAction(valid, for: k)
            }
            self.config = decoded
        } else {
            self.config = HardwareRemoteConfig()
        }
        super.init()
        self.inputMonitoringGranted = (IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted)
    }

    func saveConfig() {
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) {
            try? data.write(to: configURL, options: .atomic)
        }
    }

    /// 在应用启动时挂载语音管线并开启后台零配置嗅探
    func start(pipeline: VoicePipeline) {
        self.pipeline = pipeline
        refreshPermissions()
        setupHIDManager()
        // Bluetooth (and its permission prompt) is only touched once a remote is set up, or when the person opens
        // the Hardware page to look for one.
        if config.isPaired { startDiscovery() }
        Log.write("hardware-remote-center started paired=\(config.isPaired) seize=\(config.seizeHID)")
    }

    /// Starts Bluetooth discovery of the remote (asks for the Bluetooth permission the first time).
    func startDiscovery() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    func refreshPermissions() {
        inputMonitoringGranted = (IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted)
    }

    func requestInputMonitoringPermission() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 自定义快捷键录制（供 12 个非语音按键绑定任意 Mac 快捷键）

    func beginRecordingCustomShortcut(for key: HardwareRemoteKey) {
        guard !key.isDedicatedVoiceKey else { return }
        stopRecordingCustomShortcut()
        recordingShortcutForKey = key
        shortcutRecordMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self, let targetKey = self.recordingShortcutForKey else { return event }
            let code = UInt32(event.keyCode)
            if code == UInt32(kVK_Escape) && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                self.stopRecordingCustomShortcut()
                return nil
            }
            var mods: UInt32 = 0
            if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
            if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
            if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
            if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
            let spec = HotkeySpec(keyCode: code, modifiers: mods)
            self.config.setCustomShortcut(spec, for: targetKey)
            self.config.setAction(.customShortcut, for: targetKey)
            self.saveConfig()
            self.stopRecordingCustomShortcut()
            return nil
        }
    }

    func stopRecordingCustomShortcut() {
        if let mon = shortcutRecordMonitor {
            NSEvent.removeMonitor(mon)
            shortcutRecordMonitor = nil
        }
        recordingShortcutForKey = nil
    }

    // MARK: - 一键接入绑定与解绑

    /// 用户点击类 AirPods 弹窗上的「一键接入随言」按钮
    func pairOneClick() {
        config.isPaired = true
        config.seizeHID = true
        saveConfig()
        refreshPermissions()
        if !inputMonitoringGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        reopenHIDManager(seize: config.isPaired && config.seizeHID)
        if let p = peripheral, p.state == .connected, !didTriggerHandshake {
            triggerATVVHandshakeIfNeeded(for: p)
        }
        Log.write("hardware-remote one-click-paired vid=0x2717 pid=0x32b8")
    }

    func unpairDevice() {
        if isStreamingVoice {
            stopRemoteVoiceSession(triggerSource: "unpair")
        }
        config.isPaired = false
        saveConfig()
        reopenHIDManager(seize: false)
        pairingPanel.hide()
        Log.write("hardware-remote unpaired")
    }

    func resetDefaultMappings() {
        config.keyMappings = HardwareRemoteConfig.defaultVoiceAssistantMappings
        saveConfig()
    }

    // MARK: - IOHIDManager 独占拦截与单字典去重

    private func setupHIDManager() {
        reopenHIDManager(seize: config.isPaired && config.seizeHID)
    }

    private func reopenHIDManager(seize: Bool) {
        if let existing = hidManager {
            IOHIDManagerClose(existing, IOOptionBits(kIOHIDOptionsTypeNone))
            hidManager = nil
        }
        seizedDeviceHashes.removeAll()
        keyDownState.removeAll()

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = mgr

        // 仅用单一字典匹配（避免多 UsagePage 字典导致三重回调）。二代与 2 Pro 的 PID 不同，
        // 因此只按小米 VID 匹配，再在回调里用 PID / 产品名确认是语音遥控器，不误吞小米鼠标等设备。
        let matchDict: [String: Any] = [
            kIOHIDVendorIDKey: Self.targetVendorID
        ]
        IOHIDManagerSetDeviceMatching(mgr, matchDict as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { _, _, _, device in
            HardwareRemoteCenter.shared.handleHIDDeviceMatched(device)
        }, nil)

        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { _, _, _, device in
            HardwareRemoteCenter.shared.handleHIDDeviceRemoved(device)
        }, nil)

        IOHIDManagerRegisterInputValueCallback(mgr, { _, _, _, value in
            HardwareRemoteCenter.shared.handleHIDInputValue(value)
        }, nil)

        // 独占 (Seize) 键盘类设备需要 root，普通进程必得 0xE00002C1；这里始终普通打开，改由 RemoteKeyGate 拦截。
        _ = seize
        let options = IOOptionBits(kIOHIDOptionsTypeNone)
        RemoteKeyGate.shared.setEnabled(config.isPaired)
        let status = IOHIDManagerOpen(mgr, options)
        if status != kIOReturnSuccess && options != IOOptionBits(kIOHIDOptionsTypeNone) {
            _ = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            Log.write("hardware-remote hid-open-fallback status=\(status)")
        } else {
            Log.write("hardware-remote hid-open status=\(status) seize=\(options == IOOptionBits(kIOHIDOptionsTypeSeizeDevice))")
        }
    }

    /// 小米语音遥控器：已知 PID（二代），或产品名含 Remote / 遥控 / RC00（2 Pro 等）。
    private static func isRemoteDevice(_ device: IOHIDDevice) -> Bool {
        let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
        guard vendor == targetVendorID else { return false }
        if (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) == targetProductID { return true }
        let product = ((IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "").lowercased()
        return product.contains("remote") || product.contains("遥控") || product.contains("rc00") || product.contains("mi rc")
    }

    private func handleHIDDeviceMatched(_ device: IOHIDDevice) {
        guard Self.isRemoteDevice(device) else { return }
        let hash = CFHash(device)
        guard !seizedDeviceHashes.contains(hash) else { return }
        seizedDeviceHashes.insert(hash)

        if let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String, !product.isEmpty {
            config.deviceName = product
        }
        isHIDConnected = true
        RemoteKeyGate.shared.setRemotePresent(true)
        Log.write("hardware-remote hid-matched count=\(seizedDeviceHashes.count)")
        evaluateAutoPairingPrompt()
    }

    private func handleHIDDeviceRemoved(_ device: IOHIDDevice) {
        let hash = CFHash(device)
        seizedDeviceHashes.remove(hash)
        if seizedDeviceHashes.isEmpty {
            isHIDConnected = false
            RemoteKeyGate.shared.setRemotePresent(false)
            keyDownState.removeAll()
            Log.write("hardware-remote hid-removed-all")
        }
    }

    private func handleHIDInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard Self.isRemoteDevice(IOHIDElementGetDevice(element)) else { return }
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        guard page != 0, usage != 0, usage != 0xFFFFFFFF else { return }
        guard let key = HardwareRemoteKey.fromHID(page: page, usage: usage) else { return }

        let isDown = (IOHIDValueGetIntegerValue(value) != 0)
        RemoteKeyGate.shared.note(page: page, usage: usage, isDown: isDown)
        // 过滤物理按键连发与多重 HID 接口重复上报（彻底抑制 F5 ^[[15~ 连发污染）
        if keyDownState[key] == isDown { return }
        keyDownState[key] = isDown

        if isDown {
            lastPressedKey = key
            lastPressedAt = Date()
            litKeys.insert(key)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.keyDownState[key] != true else { return }
                self.litKeys.remove(key)
            }
        }

        // 未绑定状态下若正在展示配对卡片，按下语音键直接触发「一键接入」
        if !config.isPaired {
            if key == .voice && isDown && pairingPanel.isVisible {
                pairOneClick()
                pairingPanel.transitionToTrialStep()
            }
            return
        }

        // 按键测试中只亮灯；试说卡片打开时语音键仍然正常工作。
        if keyTestMode && !pairingPanel.isShowingTrialStep { return }
        let action = config.action(for: key)
        dispatchKeyAction(action, key: key, isDown: isDown)
    }

    private func dispatchKeyAction(_ action: HardwareRemoteAction, key: HardwareRemoteKey, isDown: Bool) {
        // 安全护栏：语音动作仅允许物理语音键 (🎤) 触发
        if action.isVoiceAction && !key.isDedicatedVoiceKey {
            return
        }

        switch action {
        case .holdToTalk:
            if isDown {
                // Stage 0 铁证指导：握手包已启用 HTT 模式，遥控器按下语音键会主动发 0x04 开始推流；
                // 此处仅启动随言外部录音会话，绝不重复向 BLE 发送 [0x0C, 0x00]，防止触发 3 次 0x04 重置流吞字！
                startRemoteVoiceSession(triggerSource: "hid-hold-down", sendBLEMicOpen: false)
            } else {
                stopRemoteVoiceSession(triggerSource: "hid-hold-up")
            }

        case .toggleVoice:
            guard isDown else { return }
            if isStreamingVoice {
                stopRemoteVoiceSession(triggerSource: "hid-toggle-stop")
            } else {
                startRemoteVoiceSession(triggerSource: "hid-toggle-start", sendBLEMicOpen: false)
            }

        case .confirmReturn:
            guard isDown else { return }
            if isStreamingVoice {
                stopRemoteVoiceSession(triggerSource: "hid-ok-confirm")
            } else {
                KeyEventPoster.post(HotkeySpec(keyCode: UInt32(kVK_Return), modifiers: 0), label: "remote-ok-return")
            }

        case .cancelOrBackspace:
            guard isDown else { return }
            if isStreamingVoice || pipeline?.hasActiveSession == true {
                cancelRemoteVoiceSession(reason: "remote-back-cancel")
            } else {
                KeyEventPoster.post(HotkeySpec(keyCode: UInt32(kVK_Delete), modifiers: 0), label: "remote-backspace")
            }

        case .cancelOrEscape:
            guard isDown else { return }
            if isStreamingVoice || pipeline?.hasActiveSession == true {
                cancelRemoteVoiceSession(reason: "remote-esc-cancel")
            } else {
                KeyEventPoster.post(HotkeySpec(keyCode: UInt32(kVK_Escape), modifiers: 0), label: "remote-escape")
            }

        case .arrowUp:
            guard isDown else { return }
            KeyEventPoster.post(HotkeySpec(keyCode: UInt32(kVK_UpArrow), modifiers: 0), label: "remote-up")
        case .arrowDown:
            guard isDown else { return }
            KeyEventPoster.post(HotkeySpec(keyCode: UInt32(kVK_DownArrow), modifiers: 0), label: "remote-down")
        case .arrowLeft:
            guard isDown else { return }
            KeyEventPoster.post(HotkeySpec(keyCode: UInt32(kVK_LeftArrow), modifiers: 0), label: "remote-left")
        case .arrowRight:
            guard isDown else { return }
            KeyEventPoster.post(HotkeySpec(keyCode: UInt32(kVK_RightArrow), modifiers: 0), label: "remote-right")

        case .space:
            guard isDown else { return }
            KeyEventPoster.post(HotkeySpec(keyCode: UInt32(kVK_Space), modifiers: 0), label: "remote-space")

        case .tab:
            guard isDown else { return }
            KeyEventPoster.post(HotkeySpec(keyCode: UInt32(kVK_Tab), modifiers: 0), label: "remote-tab")

        case .copyShortcut:
            guard isDown else { return }
            KeyEventPoster.post(HotkeySpec(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey)), label: "remote-cmd-c")

        case .pasteShortcut:
            guard isDown else { return }
            KeyEventPoster.post(HotkeySpec(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey)), label: "remote-cmd-v")

        case .undoShortcut:
            guard isDown else { return }
            KeyEventPoster.post(HotkeySpec(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey)), label: "remote-cmd-z")

        case .copyLastResult:
            guard isDown, let text = pipeline?.lastTranscript, !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)

        case .openSettings:
            guard isDown else { return }
            NSApp.sendAction(Selector(("showSettings")), to: nil, from: nil)

        case .startScreenshot:
            guard isDown else { return }
            NSApp.sendAction(Selector(("startScreenshot")), to: nil, from: nil)

        case .startDirectOCR:
            guard isDown else { return }
            NSApp.sendAction(Selector(("startDirectOCR")), to: nil, from: nil)

        case .systemVolumeUp:
            guard isDown else { return }
            postSystemMediaKey(Int32(NX_KEYTYPE_SOUND_UP))

        case .systemVolumeDown:
            guard isDown else { return }
            postSystemMediaKey(Int32(NX_KEYTYPE_SOUND_DOWN))

        case .systemMute:
            guard isDown else { return }
            postSystemMediaKey(Int32(NX_KEYTYPE_MUTE))

        case .customShortcut:
            guard isDown, let spec = config.customShortcut(for: key) else { return }
            KeyEventPoster.post(spec, label: "remote-custom-\(key.rawValue)")

        case .disabled:
            break
        }
    }

    private func postSystemMediaKey(_ key: Int32) {
        func post(down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key << 16) | ((down ? 0xA : 0xB) << 8))
            guard let ev = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) else { return }
            ev.cgEvent?.post(tap: .cghidEventTap)
        }
        post(down: true)
        post(down: false)
    }

    // MARK: - CoreBluetooth 发现、ATVV 握手与断连静默重连

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            isBLEConnected = false
            isATVVReady = false
            return
        }
        connectOrScanForRemote(central)
    }

    private func connectOrScanForRemote(_ central: CBCentralManager) {
        let services = [Self.hidServiceUUID, Self.batteryServiceUUID, Self.atvvServiceUUID]
        let connected = central.retrieveConnectedPeripherals(withServices: services)
        for p in connected where Self.matchesRemoteName(p.name) {
            attachPeripheral(p, central: central)
            return
        }
        central.scanForPeripherals(withServices: [Self.atvvServiceUUID, Self.hidServiceUUID], options: nil)
    }

    private static func matchesRemoteName(_ name: String?) -> Bool {
        guard let n = name, !n.isEmpty else { return false }
        return n.contains("小米") || n.contains("MI RC") || n.contains("RC00") || n.contains("Xiaomi") || n.contains("遥控") || n.lowercased().contains("remote")
    }

    private func attachPeripheral(_ p: CBPeripheral, central: CBCentralManager) {
        self.peripheral = p
        if let name = p.name, !name.isEmpty {
            config.deviceName = name
        }
        p.delegate = self
        central.stopScan()
        central.connect(p, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        if Self.matchesRemoteName(peripheral.name) || Self.matchesRemoteName(advName) {
            attachPeripheral(peripheral, central: central)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isBLEConnected = true
        didReceiveCapsResponse = false
        didTriggerHandshake = false
        pendingNotifySubscriptions = 0
        peripheral.discoverServices([Self.atvvServiceUUID, Self.batteryServiceUUID])
        evaluateAutoPairingPrompt()
        Log.write("hardware-remote ble-connected")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // 第 4 步：日常休眠无感重连（绝不弹窗打扰，后台直接发起重连挂起，下次按键 100~200ms 瞬时恢复）
        isBLEConnected = false
        isATVVReady = false
        if isStreamingVoice {
            stopRemoteVoiceSession(triggerSource: "ble-disconnect")
        }
        central.connect(peripheral, options: nil)
        Log.write("hardware-remote ble-sleeping-awaiting-wake")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for s in services {
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        let serviceUUID = service.uuid.uuidString.uppercased()

        for c in chars {
            let charUUID = c.uuid.uuidString.uppercased()
            if serviceUUID == Self.atvvServiceUUID.uuidString.uppercased() {
                if charUUID.hasPrefix("AB5E0002") {
                    if c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) {
                        atvvTxChar = c
                    }
                    if c.properties.contains(.notify) && atvvAudioChar == nil {
                        atvvAudioChar = c
                    }
                } else if charUUID.hasPrefix("AB5E0003") {
                    if c.properties.contains(.notify) {
                        atvvAudioChar = c
                    }
                    if (c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse)) && atvvTxChar == nil {
                        atvvTxChar = c
                    }
                } else if charUUID.hasPrefix("AB5E0004") {
                    atvvCtlChar = c
                }
            }

            if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                if serviceUUID == Self.atvvServiceUUID.uuidString.uppercased() {
                    pendingNotifySubscriptions += 1
                }
                peripheral.setNotifyValue(true, for: c)
            }

            if charUUID == "2A19" && c.properties.contains(.read) {
                peripheral.readValue(for: c)
            }
        }

        if serviceUUID == Self.atvvServiceUUID.uuidString.uppercased(), pendingNotifySubscriptions == 0 {
            triggerATVVHandshakeIfNeeded(for: peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let charUUID = characteristic.uuid.uuidString.uppercased()
        if charUUID.hasPrefix("AB5E") {
            pendingNotifySubscriptions = max(0, pendingNotifySubscriptions - 1)
            if pendingNotifySubscriptions == 0 {
                triggerATVVHandshakeIfNeeded(for: peripheral)
            }
        }
    }

    private func triggerATVVHandshakeIfNeeded(for peripheral: CBPeripheral) {
        guard !didTriggerHandshake, let tx = atvvTxChar else { return }
        didTriggerHandshake = true
        let writeType: CBCharacteristicWriteType = tx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        // Stage 0 实测验证通过：写入 6 字节 GET_CAPS [0A 01 00 00 03 03] 开启 16kHz ADPCM + HTT 按住即推流模式
        let getCapsV1 = Data([0x0A, 0x01, 0x00, 0x00, 0x03, 0x03])
        peripheral.writeValue(getCapsV1, for: tx, type: writeType)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self, !self.didReceiveCapsResponse, let p = self.peripheral, let tx = self.atvvTxChar else { return }
            p.writeValue(Data([0x0A, 0x00, 0x04, 0x00, 0x03]), for: tx, type: writeType)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        let charUUID = characteristic.uuid.uuidString.uppercased()
        let bytes = [UInt8](data)

        // 1. 电池电量特征 (0x2A19)
        if charUUID == "2A19" {
            batteryLevel = Int(bytes[0])
            return
        }

        // 2. ATVV 控制特征 (AB5E0004)
        if characteristic.uuid == atvvCtlChar?.uuid || (charUUID.hasPrefix("AB5E") && data.count <= 12) {
            let cmd = bytes[0]
            switch cmd {
            case 0x0B: // CAPS_RESP: [0B 01 00 02 03 00 78 00 00]
                didReceiveCapsResponse = true
                isATVVReady = true
                if bytes.count >= 3 {
                    negotiatedATVVVersionMajor = bytes[1]
                }
                Log.write("hardware-remote atvv-caps-ready v=\(negotiatedATVVVersionMajor)")

            case 0x08: // START_SEARCH (仅当固件未自动推流而发 0x08 请求时，才补发 [0C 00])
                guard config.isPaired else { return }
                if !isStreamingVoice {
                    startRemoteVoiceSession(triggerSource: "ble-0x08", sendBLEMicOpen: true)
                }

            case 0x04: // AUDIO_START: Stage 0 实测按下语音键瞬发 [04 03 02 03]，零延迟直接进流！
                if bytes.count >= 3 {
                    activeSessionId = bytes[2]
                }
                guard config.isPaired else { return }
                if keyTestMode && !pairingPanel.isShowingTrialStep {
                    testVoiceLatched = true
                    RemoteKeyGate.shared.setVoiceStreaming(true)
                    return
                }
                if !isStreamingVoice {
                    startRemoteVoiceSession(triggerSource: "ble-0x04-htt", sendBLEMicOpen: false)
                }

            case 0x0A: // AUDIO_SYNC: 同步 ADPCM Predictor 与 StepIndex
                if bytes.count >= 6 {
                    let pred = Int(Int16(bitPattern: (UInt16(bytes[3]) << 8) | UInt16(bytes[4])))
                    let idx = Int(bytes[5])
                    decoder.reset(initialPredictor: pred, initialIndex: idx)
                }

            case 0x00: // AUDIO_STOP: 松开语音键流结束
                if testVoiceLatched {
                    testVoiceLatched = false
                    RemoteKeyGate.shared.setVoiceStreaming(false)
                    if !isStreamingVoice { return }
                }
                if isStreamingVoice && config.action(for: .voice) == .holdToTalk {
                    stopRemoteVoiceSession(triggerSource: "ble-0x00")
                }

            default:
                break
            }
            return
        }

        // 3. ATVV 音频流特征 (AB5E0003, 120 字节 16kHz ADPCM 帧)
        if characteristic.uuid == atvvAudioChar?.uuid {
            guard config.isPaired else { return }
            if !isStreamingVoice {
                // 按键测试中不开始识别（否则松手后没有人结束这段录音）。
                if keyTestMode && !pairingPanel.isShowingTrialStep { return }
                startRemoteVoiceSession(triggerSource: "ble-audio-packet", sendBLEMicOpen: false)
            }
            lastAudioPacketAt = Date()
            // 遥控器麦克风音量偏小：显示用的电平放大后再交给录音条，否则低于波形噪声下限，条上看不到起伏。
            if let source = activePCMSource, !levelBoostInstalled, let base = source.onLevel {
                source.onLevel = { v in base(min(1, v * 5)) }
                levelBoostInstalled = true
            }
            let pcm = decoder.decode(adpcmData: data, gain: config.micGain)
            activePCMSource?.push(pcm)
            if !pcm.isEmpty {
                var sum: Float = 0
                for v in pcm { let f = Float(v) / 32768; sum += f * f }
                let level = min(1, (sum / Float(pcm.count)).squareRoot() * 6)
                liveAudioLevel = level
                pairingPanel.updateWaveform(level: level)
            }
            return
        }
    }

    // MARK: - 对接随言 VoicePipeline (复用 ExternalPCMSource 16kHz 直通管道)

    func startRemoteVoiceSession(triggerSource: String, sendBLEMicOpen: Bool) {
        guard config.isPaired else { return }
        if sendBLEMicOpen, let p = peripheral, let tx = atvvTxChar {
            let writeType: CBCharacteristicWriteType = tx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            let cmd = (negotiatedATVVVersionMajor >= 1) ? Data([0x0C, 0x00]) : Data([0x0C, 0x00, 0x01])
            p.writeValue(cmd, for: tx, type: writeType)
        }

        guard !isStreamingVoice else { return }
        isStreamingVoice = true
        levelBoostInstalled = false
        RemoteKeyGate.shared.setVoiceStreaming(true)
        decoder.reset()
        // 兜底：遥控器停止推流（松手、断连）后 1.5 秒内没有新音频，就结束这段录音，不会一直卡在录音状态。
        lastAudioPacketAt = Date()
        streamWatchdog?.invalidate()
        streamWatchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.isStreamingVoice else { return }
            if Date().timeIntervalSince(self.lastAudioPacketAt) > 1.5 {
                Log.write("hardware-remote voice-watchdog-stop")
                self.stopRemoteVoiceSession(triggerSource: "audio-timeout")
            }
        }

        let pcmSource = ExternalPCMSource()
        activePCMSource = pcmSource

        guard let pipeline = pipeline else { return }
        previousRecorderFactory = pipeline.recorderFactory

        // 构造外部 16kHz PCM 识别会话（兼容本地 Sherpa-ONNX、云端 API 及 Apple Speech）
        pipeline.recorderFactory = { [weak self, weak pipeline] in
            guard let pipeline = pipeline else {
                return AppleSpeechExternalPCMRecorder(capture: pcmSource, locale: "zh-CN", allowCloud: false)
            }
            let originalLevelCallback = pcmSource.onLevel
            let recorder: HoldRecordingSession
            switch pipeline.makeExternalRecorder(capture: pcmSource) {
            case .success(let extRecorder):
                recorder = extRecorder
            case .failure:
                let cfg = pipeline.configStore.config
                recorder = AppleSpeechExternalPCMRecorder(
                    capture: pcmSource,
                    locale: cfg.recognitionLocale,
                    allowCloud: cfg.allowCloudRecognition
                )
            }
            // 同步驱动配对卡片/设置页的实时声波条
            let wrappedOnLevel = recorder.onLevel
            recorder.onLevel = { [weak self] level in
                self?.liveAudioLevel = level
                self?.pairingPanel.updateWaveform(level: level)
                wrappedOnLevel?(level)
                originalLevelCallback?(level)
            }
            return recorder
        }

        let isTrialInCard = pairingPanel.isShowingTrialStep
        pipeline.holdStarted(source: isTrialInCard ? .button : .hotkey, localOnly: isTrialInCard)
        Log.write("hardware-remote voice-start source=\(triggerSource) trial=\(isTrialInCard)")
    }

    func stopRemoteVoiceSession(triggerSource: String) {
        guard isStreamingVoice else { return }
        isStreamingVoice = false
        streamWatchdog?.invalidate(); streamWatchdog = nil
        RemoteKeyGate.shared.setVoiceStreaming(false)
        liveAudioLevel = 0
        pairingPanel.updateWaveform(level: 0)

        if let p = peripheral, let tx = atvvTxChar {
            let writeType: CBCharacteristicWriteType = tx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            let closeCmd = (negotiatedATVVVersionMajor >= 1) ? Data([0x0D, activeSessionId]) : Data([0x0D])
            p.writeValue(closeCmd, for: tx, type: writeType)
        }

        if let pipeline = pipeline {
            pipeline.holdEnded()
            pipeline.recorderFactory = previousRecorderFactory
            previousRecorderFactory = nil

            if pairingPanel.isShowingTrialStep {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self = self else { return }
                    let text = self.pipeline?.lastTranscript ?? L10n.tr("hardware.channelReady")
                    self.trialCompletedTranscript = text
                    self.pairingPanel.markTrialSuccess(transcript: text)
                }
            }
        }
        activePCMSource = nil
        Log.write("hardware-remote voice-stop source=\(triggerSource)")
    }

    func cancelRemoteVoiceSession(reason: String) {
        isStreamingVoice = false
        streamWatchdog?.invalidate(); streamWatchdog = nil
        RemoteKeyGate.shared.setVoiceStreaming(false)
        liveAudioLevel = 0
        activePCMSource = nil
        if let pipeline = pipeline {
            pipeline.forceEnd(reason: reason)
            pipeline.recorderFactory = previousRecorderFactory
            previousRecorderFactory = nil
        }
        Log.write("hardware-remote voice-cancel reason=\(reason)")
    }

    // MARK: - 类 AirPods 自动弹窗判定

    private func evaluateAutoPairingPrompt() {
        guard !config.isPaired, config.autoPopCardOnConnect, !didDismissPairingPromptForCurrentConnection else { return }
        guard isHIDConnected || isBLEConnected else { return }
        guard !CommandLine.arguments.contains(where: { $0.hasPrefix("--selftest") || $0.hasPrefix("--preview") }) else { return }
        pairingPanel.presentDiscoveryCard()
    }

    func presentPairingCardManually() {
        didDismissPairingPromptForCurrentConnection = false
        pairingPanel.presentDiscoveryCard()
    }

    fileprivate func markPairingCardDismissed() {
        didDismissPairingPromptForCurrentConnection = true
    }
}

// MARK: - 5. 类 AirPods 悬浮毛玻璃配对卡片 (NSPanel)

final class RemotePairingPanelController: NSObject {
    enum Step {
        case discovery   // 第 2 步：发现设备 + 🔋 电量 + 「一键接入随言」
        case trial       // 第 3 步：按住语音键 3 秒试说 + 实时声波跳动
        case completed   // 试说成功出字，自动收起
    }

    private unowned let center: HardwareRemoteCenter
    private var panel: NSPanel?
    private var waveformView: WaveformView?
    private(set) var currentStep: Step = .discovery

    var isVisible: Bool { panel?.isVisible == true }
    var isShowingTrialStep: Bool { isVisible && currentStep == .trial }

    init(center: HardwareRemoteCenter) {
        self.center = center
        super.init()
    }

    func presentDiscoveryCard() {
        currentStep = center.config.isPaired ? .trial : .discovery
        ensurePanel()
        rebuildContent()
        guard let panel = panel else { return }
        if let screen = NSScreen.main {
            let vis = screen.visibleFrame
            let size = panel.frame.size
            // 右上角滑出（类 AirPods 靠近 Mac 时的系统设备卡片位置）
            let origin = NSPoint(x: vis.maxX - size.width - 24, y: vis.maxY - size.height - 24)
            panel.setFrameOrigin(origin)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 1
        }
    }

    func transitionToTrialStep() {
        currentStep = .trial
        rebuildContent()
    }

    func markTrialSuccess(transcript: String) {
        currentStep = .completed
        rebuildContent(transcript: transcript)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.hide()
        }
    }

    private var idleTimer: Timer?
    private var lastRealLevelAt: CFAbsoluteTime = 0

    func updateWaveform(level: Float) {
        guard isVisible else { return }
        lastRealLevelAt = CFAbsoluteTimeGetCurrent()
        let displayed = WaveformAppearance.displayLevel(level)
        waveformView?.push(CGFloat(displayed))
    }

    /// 试说页：没有声音时波纹也轻微起伏，提示可以开口。
    private func restartIdleBreathing() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard currentStep == .trial else { return }
        let started = CFAbsoluteTimeGetCurrent()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24, repeats: true) { [weak self] _ in
            guard let self, self.isVisible, self.currentStep == .trial else { return }
            let now = CFAbsoluteTimeGetCurrent()
            guard now - self.lastRealLevelAt > 0.25 else { return }
            let t = now - started
            let v = 0.16 + 0.10 * sin(t * 3.2) + 0.05 * sin(t * 7.1 + 1.3)
            self.waveformView?.push(CGFloat(max(0.06, v)))
        }
    }

    func hide() {
        guard let panel = panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.idleTimer?.invalidate(); self?.idleTimer = nil
            self?.panel?.orderOut(nil)
        })
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let size = NSSize(width: 320, height: 340)
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        self.panel = p
    }

    private func rebuildContent(transcript: String? = nil) {
        guard let panel = panel else { return }
        let size = NSSize(width: 320, height: 340)
        panel.setContentSize(size)

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        // 卡片固定深色玻璃，不随桌面或系统外观变白。
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        let corner: CGFloat = 24
        let mask = NSImage(size: NSSize(width: corner * 2 + 1, height: corner * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: corner, left: corner, bottom: corner, right: corner)
        mask.resizingMode = .stretch
        effect.maskImage = mask

        // 关闭按钮 (右上角 ✕)
        let closeBtn = NSButton(title: "✕", target: self, action: #selector(closeTapped))
        closeBtn.isBordered = false
        closeBtn.font = .systemFont(ofSize: 13, weight: .semibold)
        closeBtn.contentTintColor = .secondaryLabelColor
        closeBtn.frame = NSRect(x: size.width - 36, y: size.height - 36, width: 24, height: 24)
        effect.addSubview(closeBtn)

        // 标题与副标题
        let titleLabel = NSTextField(labelWithString: center.remoteModel.title)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: 20, y: size.height - 52, width: size.width - 40, height: 24)
        effect.addSubview(titleLabel)

        let subText = center.batteryLevel.map { L10n.format("hardware.battery", "\($0)") } ?? L10n.tr("hardware.connected")
        let subLabel = NSTextField(labelWithString: subText)
        subLabel.font = .systemFont(ofSize: 12, weight: .medium)
        subLabel.textColor = .secondaryLabelColor
        subLabel.alignment = .center
        subLabel.frame = NSRect(x: 20, y: size.height - 72, width: size.width - 40, height: 18)
        effect.addSubview(subLabel)

        // 遥控器简笔示意图区域
        let figure = NSHostingView(rootView: XiaomiRemoteFigure(
            model: center.remoteModel, lit: [], voiceActive: currentStep == .trial))
        figure.frame = NSRect(x: (size.width - 46) / 2, y: 120, width: 46, height: 138)
        effect.addSubview(figure)

        switch currentStep {
        case .discovery:
            let hintLabel = NSTextField(labelWithString: L10n.tr("hardware.card.hint"))
            hintLabel.font = .systemFont(ofSize: 12)
            hintLabel.textColor = .secondaryLabelColor
            hintLabel.alignment = .center
            hintLabel.frame = NSRect(x: 20, y: 92, width: size.width - 40, height: 18)
            effect.addSubview(hintLabel)

            let connectBtn = NSButton(title: L10n.format("hardware.pair", String(describing: Brand.name)), target: self, action: #selector(oneClickPairTapped))
            connectBtn.bezelStyle = .regularSquare
            connectBtn.isBordered = false
            connectBtn.wantsLayer = true
            connectBtn.layer?.backgroundColor = DesignTokens.jade.cgColor
            connectBtn.layer?.cornerRadius = 12
            connectBtn.font = .systemFont(ofSize: 14, weight: .semibold)
            connectBtn.contentTintColor = .white
            connectBtn.frame = NSRect(x: 28, y: 32, width: size.width - 56, height: 42)
            effect.addSubview(connectBtn)

        case .trial:
            let wave = WaveformView(frame: NSRect(x: (size.width - 180) / 2, y: 86, width: 180, height: 34))
            self.waveformView = wave
            effect.addSubview(wave)

            let promptLabel = NSTextField(labelWithString: L10n.tr("hardware.card.prompt"))
            promptLabel.font = .systemFont(ofSize: 13, weight: .medium)
            promptLabel.alignment = .center
            promptLabel.frame = NSRect(x: 16, y: 54, width: size.width - 32, height: 20)
            effect.addSubview(promptLabel)

            let skipBtn = NSButton(title: L10n.tr("hardware.card.done"), target: self, action: #selector(closeTapped))
            skipBtn.bezelStyle = .rounded
            skipBtn.frame = NSRect(x: (size.width - 110) / 2, y: 18, width: 110, height: 28)
            effect.addSubview(skipBtn)

        case .completed:
            let doneLabel = NSTextField(labelWithString: L10n.format("hardware.done", transcript ?? L10n.tr("hardware.channelReady")))
            doneLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            doneLabel.textColor = DesignTokens.accent
            doneLabel.alignment = .center
            doneLabel.lineBreakMode = .byTruncatingTail
            doneLabel.frame = NSRect(x: 20, y: 64, width: size.width - 40, height: 22)
            effect.addSubview(doneLabel)
        }

        panel.contentView = effect
        restartIdleBreathing()
    }

    @objc private func oneClickPairTapped() {
        center.pairOneClick()
        transitionToTrialStep()
    }

    @objc private func closeTapped() {
        center.markPairingCardDismissed()
        hide()
    }
}

/// 绘制小米蓝牙语音遥控器外观轮廓与高亮语音键
private final class RemoteIllustrationView: NSView {
    var highlightVoiceButton = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }

        let bodyRect = bounds.insetBy(dx: 8, dy: 4)
        let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 16, yRadius: 16)
        NSColor.black.withAlphaComponent(0.38).setFill()
        bodyPath.fill()
        NSColor.white.withAlphaComponent(0.24).setStroke()
        bodyPath.lineWidth = 1.2
        bodyPath.stroke()

        // 顶部方向环 (D-Pad + OK)
        let ringRect = NSRect(x: bounds.midX - 18, y: bounds.maxY - 52, width: 36, height: 36)
        let ringPath = NSBezierPath(ovalIn: ringRect)
        NSColor.white.withAlphaComponent(0.18).setStroke()
        ringPath.lineWidth = 1.5
        ringPath.stroke()

        let okRect = NSRect(x: bounds.midX - 7, y: bounds.maxY - 41, width: 14, height: 14)
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(ovalIn: okRect).fill()

        // 中部语音键（高亮翠绿圆点）
        let micRect = NSRect(x: bounds.midX - 9, y: bounds.midY - 12, width: 18, height: 18)
        let micColor = highlightVoiceButton ? DesignTokens.waveform : DesignTokens.jade
        micColor.setFill()
        NSBezierPath(ovalIn: micRect).fill()
    }
}

// MARK: - 6. SwiftUI 「硬件外设」独立设置页面

/// 硬件外设列表里的一项。以后接入别的硬件：加一个 case，并在 `HardwareDevicesPage` 里补它的行与详情页。
enum HardwareDeviceID: String, CaseIterable, Identifiable {
    case xiaomiRemote
    var id: String { rawValue }
}

struct HardwareRemoteSettingsSection: View {
    @Bindable var center = HardwareRemoteCenter.shared

    private var online: Bool { center.isBLEConnected || center.isHIDConnected }
    private var jade: Color { Color(nsColor: DesignTokens.jade) }

    var body: some View {
        Section {
            HStack(spacing: 14) {
                XiaomiRemoteFigure(model: center.remoteModel, lit: center.litKeys, voiceActive: center.isStreamingVoice)
                    .opacity(online ? 1 : 0.5)
                    .frame(width: 38, height: 114)

                VStack(alignment: .leading, spacing: 4) {
                    Text(center.remoteModel.title).font(.headline)
                    HStack(spacing: 8) {
                        if !center.config.isPaired {
                            Text(L10n.tr("hardware.notPaired")).foregroundStyle(.secondary)
                        } else if online {
                            Text(L10n.tr("hardware.connected")).foregroundStyle(jade)
                        } else {
                            Text(L10n.tr("hardware.standbyLong")).foregroundStyle(.secondary)
                        }
                        if let battery = center.batteryLevel {
                            Text("\(battery)%").foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }

                Spacer()

                if center.config.isPaired {
                    Button(L10n.tr("hardware.tryIt")) { center.presentPairingCardManually() }
                        .buttonStyle(.bordered)
                    Button(L10n.tr("hardware.unpair"), role: .destructive) { center.unpairDevice() }
                        .buttonStyle(.borderless)
                } else {
                    Button(L10n.format("hardware.pair", String(describing: Brand.name))) {
                        center.pairOneClick()
                        center.presentPairingCardManually()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(jade)
                }
            }
            .padding(.vertical, 4)

            if center.config.isPaired && !center.inputMonitoringGranted {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(L10n.tr("hardware.needInputMonitoring")).font(.callout)
                    Spacer()
                    Button(L10n.tr("hardware.allow")) { center.requestInputMonitoringPermission() }
                        .buttonStyle(.bordered)
                }
            }

            if center.config.isPaired {
                HStack {
                    Text(L10n.tr("hardware.micGain"))
                    Slider(
                        value: Binding(
                            get: { Double(center.config.micGain) },
                            set: { center.config.micGain = Float($0); center.saveConfig() }
                        ),
                        in: 0.5...2.5,
                        step: 0.1
                    )
                    Text(String(format: "%.1fx", center.config.micGain))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }

        if center.config.isPaired {
            Section {
                Toggle(L10n.tr("hardware.keyTest"), isOn: $center.keyTestMode)
                Text(center.keyTestMode ? L10n.tr("hardware.keyTestOn") : L10n.tr("hardware.keyTestOff"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 10) {
                    Image(systemName: HardwareRemoteKey.voice.symbolName)
                        .frame(width: 20)
                        .foregroundStyle(center.litKeys.contains(.voice) ? jade : .secondary)
                    Text(HardwareRemoteKey.voice.displayName)
                        .fontWeight(.semibold)
                    Spacer()
                    Picker(
                        "",
                        selection: Binding<HardwareRemoteAction>(
                            get: { center.config.action(for: .voice) },
                            set: { newAction in
                                center.config.setAction(newAction, for: .voice)
                                center.saveConfig()
                            }
                        )
                    ) {
                        ForEach(HardwareRemoteAction.voiceKeyOptions) { action in
                            Text(action.displayName).tag(action)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }
            } header: {
                Text(L10n.tr("hardware.voiceKeyHeader"))
            }

            Section {
                ForEach(HardwareRemoteKey.allCases.filter { !$0.isDedicatedVoiceKey }) { key in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Image(systemName: key.symbolName)
                                .frame(width: 20)
                                .foregroundStyle(center.litKeys.contains(key) ? jade : .secondary)
                            Text(key.displayName)
                                .fontWeight(center.litKeys.contains(key) ? .semibold : .regular)
                            Spacer()
                            Picker(
                                "",
                                selection: Binding<HardwareRemoteAction>(
                                    get: { center.config.action(for: key) },
                                    set: { newAction in
                                        center.config.setAction(newAction, for: key)
                                        center.saveConfig()
                                        if newAction == .customShortcut && center.config.customShortcut(for: key) == nil {
                                            center.beginRecordingCustomShortcut(for: key)
                                        }
                                    }
                                )
                            ) {
                                ForEach(HardwareRemoteAction.nonVoiceKeyOptions) { action in
                                    Text(action.displayName).tag(action)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 240)
                        }

                        if center.config.action(for: key) == .customShortcut {
                            HStack(spacing: 8) {
                                Spacer()
                                if center.recordingShortcutForKey == key {
                                    Text(L10n.tr("hardware.recordPrompt"))
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                    Button(L10n.tr("hardware.cancel")) { center.stopRecordingCustomShortcut() }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                } else {
                                    if let spec = center.config.customShortcut(for: key) {
                                        KeyCap(HotkeySpecDisplay.string(spec))
                                    } else {
                                        Text(L10n.tr("hardware.notSet")).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Button(L10n.tr("hardware.record")) { center.beginRecordingCustomShortcut(for: key) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button(L10n.tr("hardware.reset")) { center.resetDefaultMappings() }
                        .buttonStyle(.bordered)
                }
            } header: {
                Text(L10n.tr("hardware.keysHeader"))
            }
        }
    }
}

/// 「硬件外设」：先是已支持的硬件列表，点进某个设备才是它的设置。
struct HardwareRemoteSettingsPage: View {
    @Bindable private var center = HardwareRemoteCenter.shared
    @State private var selected: HardwareDeviceID?

    var body: some View {
        SettingsPage {
            if let device = selected {
                Section {
                    Button { selected = nil } label: {
                        Label(L10n.tr("hardware.title"), systemImage: "chevron.backward")
                    }
                    .buttonStyle(.borderless)
                }
                switch device {
                case .xiaomiRemote:
                    HardwareRemoteSettingsSection()
                        .onDisappear { center.keyTestMode = false }
                        .onAppear { center.keyTestMode = true }
                }
            } else {
                Section {
                    ForEach(HardwareDeviceID.allCases) { device in
                        Button { selected = device } label: { row(for: device) }
                            .buttonStyle(.plain)
                    }
                } header: {
                    Text(L10n.tr("hardware.title"))
                }
            }
        }
        .onAppear { center.startDiscovery() }
        .onDisappear { center.keyTestMode = false }
    }

    @ViewBuilder
    private func row(for device: HardwareDeviceID) -> some View {
        switch device {
        case .xiaomiRemote:
            let online = center.isBLEConnected || center.isHIDConnected
            HStack(spacing: 12) {
                XiaomiRemoteFigure(model: center.remoteModel)
                    .opacity(online ? 1 : 0.5)
                    .frame(width: 20, height: 60)
                VStack(alignment: .leading, spacing: 2) {
                    Text(center.remoteModel.title).font(.headline)
                    Text(!center.config.isPaired ? L10n.tr("hardware.notPaired") : online ? L10n.tr("hardware.connected") : L10n.tr("hardware.standby"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
    }
}

// MARK: - 4. 遥控器键盘事件拦截（Seize 被系统拒绝时的兜底）
// 实测：普通用户进程独占键盘类 HID 设备会得到 kIOReturnNotPrivileged (0xE00002C1)，
// 遥控器按键因此仍会以系统键盘事件（F5 → ^[[15~、Return、方向键…）漏到前台窗口。
// 这里用主动式 CGEventTap 吞掉「正被遥控器 HID 报告按住」的键盘事件，真键盘不受影响。

final class RemoteKeyGate {
    static let shared = RemoteKeyGate()

    /// HID 键盘页 (0x07) usage → macOS 虚拟键码
    private static let usageToKeyCode: [UInt32: Int64] = [
        0x3E: 96,   // F5（语音键）
        0x28: 36,   // Return（OK）
        0x29: 53,   // Esc
        0x52: 126,  // ↑
        0x51: 125,  // ↓
        0x50: 123,  // ←
        0x4F: 124,  // →
        0x4A: 115,  // Home
        0x65: 110,  // Application（菜单）
        0x35: 50,   // `（TV）
    ]

    private let cond = NSCondition()
    private var held: Set<Int64> = []
    private var releasedAt: [Int64: CFAbsoluteTime] = [:]
    private var present = false
    private var wanted = false
    private var tap: CFMachPort?
    private var tapRunLoop: CFRunLoop?
    private var swallowLogBudget = 40

    private var voiceStreaming = false
    private var voiceStoppedAt: CFAbsoluteTime = 0

    /// 遥控器语音会话由 BLE 0x04 开始、0x00 结束；期间 F5（语音键）的系统键盘事件全部属于遥控器。
    func setVoiceStreaming(_ on: Bool) {
        cond.lock()
        if voiceStreaming && !on { voiceStoppedAt = CFAbsoluteTimeGetCurrent() }
        voiceStreaming = on
        cond.broadcast()
        cond.unlock()
    }

    func setRemotePresent(_ value: Bool) {
        cond.lock(); present = value; if !value { held.removeAll() }; cond.unlock()
    }

    func note(page: UInt32, usage: UInt32, isDown: Bool) {
        guard page == 0x07, let code = Self.usageToKeyCode[usage] else { return }
        cond.lock()
        if isDown { held.insert(code) } else if held.remove(code) != nil { releasedAt[code] = CFAbsoluteTimeGetCurrent() }
        cond.broadcast()
        cond.unlock()
    }

    func setEnabled(_ enabled: Bool) {
        cond.lock()
        guard wanted != enabled else { cond.unlock(); return }
        wanted = enabled
        cond.unlock()
        enabled ? startTap() : stopTap()
    }

    private func startTap() {
        let thread = Thread { [weak self] in
            guard let self else { return }
            let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            let callback: CGEventTapCallBack = { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let gate = Unmanaged<RemoteKeyGate>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    gate.cond.lock(); let port = gate.tap; gate.cond.unlock()
                    if let port { CGEvent.tapEnable(tap: port, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                // 软件合成的事件（包括随言自己发出的 Return/方向键）来源进程号非 0，一律放行。
                let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
                guard sourcePID == 0 else { return Unmanaged.passUnretained(event) }
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                return gate.shouldSwallow(code: code, isDown: type == .keyDown, repeated: repeated)
                    ? nil : Unmanaged.passUnretained(event)
            }
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: mask, callback: callback,
                                               userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                Log.write("hardware-remote key-gate tap-create-failed (Accessibility not granted?)")
                self.cond.lock(); self.wanted = false; self.cond.unlock()
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            self.cond.lock(); self.tap = port; self.tapRunLoop = loop; self.cond.unlock()
            CGEvent.tapEnable(tap: port, enable: true)
            Log.write("hardware-remote key-gate started")
            CFRunLoopRun()
        }
        thread.name = "cadenza.remote-key-gate"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func stopTap() {
        cond.lock()
        let port = tap, loop = tapRunLoop
        tap = nil; tapRunLoop = nil; held.removeAll()
        cond.unlock()
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let loop { CFRunLoopStop(loop) }
        Log.write("hardware-remote key-gate stopped")
    }

    fileprivate func shouldSwallow(code: Int64, isDown: Bool, repeated: Bool) -> Bool {
        guard Set(Self.usageToKeyCode.values).contains(code) else { return false }
        cond.lock()
        defer { cond.unlock() }
        guard present else { return false }
        var swallow = held.contains(code)
        let now = CFAbsoluteTimeGetCurrent()
        // 语音键：BLE 语音会话进行中（及结束后 0.3s）的 F5 一律属于遥控器。
        if !swallow, code == 96, voiceStreaming || now - voiceStoppedAt < 0.3 { swallow = true }
        if !swallow, code == 96, isDown, !repeated {
            // F5 的系统事件早于 BLE 0x04 到达：最多等 80ms。
            let deadline = Date(timeIntervalSinceNow: 0.08)
            while !voiceStreaming, !held.contains(code), cond.wait(until: deadline) {}
            swallow = voiceStreaming || held.contains(code)
        }
        if !swallow {
            let sinceRelease = releasedAt[code].map { now - $0 } ?? .infinity
            if !isDown {
                swallow = sinceRelease < 0.25
            } else if repeated {
                swallow = sinceRelease < 0.25
            } else if sinceRelease < 0.08 {
                swallow = true
            } else {
                // 系统键盘事件可能早于 HID 回调到达：最多等 20ms 看遥控器是否正好按下了该键。
                let deadline = Date(timeIntervalSinceNow: 0.02)
                while !held.contains(code), cond.wait(until: deadline) {}
                swallow = held.contains(code)
            }
        }
        if swallow && !repeated && swallowLogBudget > 0 {
            swallowLogBudget -= 1
            Log.write("hardware-remote key-gate swallowed code=\(code) down=\(isDown)")
        }
        return swallow
    }
}

// MARK: - 5. 小米蓝牙语音遥控器 2 / 2 Pro 外观（按官方产品图的按键布局矢量绘制）

enum XiaomiRemoteModel {
    case remote2
    case remote2Pro

    /// 设备名里带 Pro 的识别为 2 Pro，其余按第二代处理。
    static func detect(_ name: String?) -> XiaomiRemoteModel {
        (name ?? "").lowercased().contains("pro") ? .remote2Pro : .remote2
    }

    var title: String {
        switch self {
        case .remote2: return L10n.tr("hardware.model.2")
        case .remote2Pro: return L10n.tr("hardware.model.pro")
        }
    }
}

/// 竖直放置的遥控器：顶排电源（左）与语音键（右），中间圆形方向盘（中心为确定），
/// 下方左列 返回 / 主页 / 菜单，右列 音量 +/− 竖条与 TV 键。画布 100 × 300。
struct XiaomiRemoteFigure: View {
    var model: XiaomiRemoteModel = .remote2
    var lit: Set<HardwareRemoteKey> = []
    var voiceActive = false

    var body: some View {
        Canvas { context, size in
            var c = context
            let s = size.width / 100
            c.scaleBy(x: s, y: s)
            Self.draw(&c, lit: lit, voiceActive: voiceActive)
        }
        .aspectRatio(100.0 / 300.0, contentMode: .fit)
        .accessibilityLabel(Text(model.title))
    }

    private static let jade = Color(nsColor: DesignTokens.jade)
    private static let glyph = Color(white: 0.92)
    private static let darkButton = Color(white: 0.13)

    private static func circle(_ center: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    }

    private static func draw(_ c: inout GraphicsContext, lit litKeys: Set<HardwareRemoteKey>, voiceActive: Bool) {
        func lit(_ key: HardwareRemoteKey) -> Bool { litKeys.contains(key) || (key == .voice && voiceActive) }
        let stroke = StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)

        // 机身：银色金属，横向高光
        let body = Path(roundedRect: CGRect(x: 0, y: 0, width: 100, height: 300), cornerRadius: 18)
        c.fill(body, with: .linearGradient(
            Gradient(colors: [Color(white: 0.95), Color(white: 0.78), Color(white: 0.90)]),
            startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 100, y: 0)))
        c.stroke(body, with: .color(Color(white: 0.55)), lineWidth: 0.8)

        // 顶排：电源（左，空心圈）与语音键（右，空心圈）
        let power = CGPoint(x: 27, y: 24), mic = CGPoint(x: 73, y: 24)
        for (center, key) in [(power, HardwareRemoteKey.power), (mic, .voice)] {
            let ring = circle(center, 11)
            if lit(key) { c.fill(ring, with: .color(jade)) }
            c.stroke(ring, with: .color(Color(white: lit(key) ? 0.2 : 0.35)), lineWidth: 1)
        }
        var p = Path()   // 电源图标
        p.addArc(center: power, radius: 4.6, startAngle: .degrees(-60), endAngle: .degrees(240), clockwise: false)
        p.move(to: CGPoint(x: power.x, y: power.y - 6)); p.addLine(to: CGPoint(x: power.x, y: power.y - 1))
        c.stroke(p, with: .color(Color(white: 0.2)), style: stroke)
        var m = Path()   // 麦克风图标
        m.addRoundedRect(in: CGRect(x: mic.x - 2.4, y: mic.y - 6, width: 4.8, height: 8.5), cornerSize: CGSize(width: 2.4, height: 2.4))
        m.addArc(center: CGPoint(x: mic.x, y: mic.y + 0.5), radius: 5, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        m.move(to: CGPoint(x: mic.x, y: mic.y + 5.5)); m.addLine(to: CGPoint(x: mic.x, y: mic.y + 8))
        c.stroke(m, with: .color(Color(white: lit(.voice) ? 1 : 0.2)), style: stroke)

        // 方向盘 + 确定
        let pad = CGPoint(x: 50, y: 92)
        c.fill(circle(pad, 40), with: .radialGradient(
            Gradient(colors: [Color(white: 0.20), Color(white: 0.09)]), center: pad, startRadius: 4, endRadius: 40))
        let okCircle = circle(pad, 20)
        c.fill(okCircle, with: .color(lit(.ok) ? jade : Color(white: 0.08)))
        c.stroke(okCircle, with: .color(Color(white: 0.30)), lineWidth: 1)
        let dots: [(HardwareRemoteKey, CGFloat, CGFloat)] = [(.up, 0, -31), (.down, 0, 31), (.left, -31, 0), (.right, 31, 0)]
        for (key, dx, dy) in dots {
            let on = lit(key)
            c.fill(circle(CGPoint(x: pad.x + dx, y: pad.y + dy), on ? 4 : 1.6), with: .color(on ? jade : Color(white: 0.55)))
        }

        // 下方：左列 返回 / 主页 / 菜单；右列 TV
        let leftX: CGFloat = 27, rightX: CGFloat = 73
        let rows: [CGFloat] = [160, 199, 238]
        func button(_ center: CGPoint, _ key: HardwareRemoteKey) {
            let b = circle(center, 14)
            c.fill(b, with: .color(lit(key) ? jade : darkButton))
            c.stroke(b, with: .color(Color(white: 0.3)), lineWidth: 0.8)
        }
        button(CGPoint(x: leftX, y: rows[0]), .back)
        button(CGPoint(x: leftX, y: rows[1]), .home)
        button(CGPoint(x: leftX, y: rows[2]), .menu)
        button(CGPoint(x: rightX, y: rows[2]), .tv)

        var back = Path()
        back.move(to: CGPoint(x: leftX + 2.5, y: rows[0] - 5)); back.addLine(to: CGPoint(x: leftX - 2.5, y: rows[0]))
        back.addLine(to: CGPoint(x: leftX + 2.5, y: rows[0] + 5))
        c.stroke(back, with: .color(glyph), style: stroke)
        var home = Path()
        let hx = leftX, hy = rows[1]
        home.move(to: CGPoint(x: hx - 5, y: hy + 5)); home.addLine(to: CGPoint(x: hx - 5, y: hy - 1))
        home.addLine(to: CGPoint(x: hx, y: hy - 5.5)); home.addLine(to: CGPoint(x: hx + 5, y: hy - 1))
        home.addLine(to: CGPoint(x: hx + 5, y: hy + 5)); home.closeSubpath()
        c.stroke(home, with: .color(glyph), style: stroke)
        var menu = Path()
        for dy in [-4.0, 0.0, 4.0] {
            menu.move(to: CGPoint(x: leftX - 5, y: rows[2] + dy)); menu.addLine(to: CGPoint(x: leftX + 5, y: rows[2] + dy))
        }
        c.stroke(menu, with: .color(glyph), style: stroke)
        let tvRect = CGRect(x: rightX - 6.5, y: rows[2] - 5, width: 13, height: 10)
        c.stroke(Path(roundedRect: tvRect, cornerRadius: 2.5), with: .color(glyph), lineWidth: 1.2)
        c.draw(Text("TV").font(.system(size: 5.5, weight: .bold)).foregroundColor(glyph),
               at: CGPoint(x: rightX, y: rows[2]))

        // 音量竖条：+ 在上、− 在下
        let pill = CGRect(x: rightX - 14, y: rows[0] - 14, width: 28, height: rows[1] - rows[0] + 28)
        let pillPath = Path(roundedRect: pill, cornerRadius: 14)
        c.fill(pillPath, with: .color(darkButton))
        c.stroke(pillPath, with: .color(Color(white: 0.3)), lineWidth: 0.8)
        if lit(.volumeUp) { c.fill(circle(CGPoint(x: rightX, y: rows[0]), 12), with: .color(jade)) }
        if lit(.volumeDown) { c.fill(circle(CGPoint(x: rightX, y: rows[1]), 12), with: .color(jade)) }
        var plus = Path()
        plus.move(to: CGPoint(x: rightX - 4.5, y: rows[0])); plus.addLine(to: CGPoint(x: rightX + 4.5, y: rows[0]))
        plus.move(to: CGPoint(x: rightX, y: rows[0] - 4.5)); plus.addLine(to: CGPoint(x: rightX, y: rows[0] + 4.5))
        plus.move(to: CGPoint(x: rightX - 4.5, y: rows[1])); plus.addLine(to: CGPoint(x: rightX + 4.5, y: rows[1]))
        c.stroke(plus, with: .color(glyph), style: stroke)

        c.draw(Text("xiaomi").font(.system(size: 7, weight: .medium)).foregroundColor(Color(white: 0.45)),
               at: CGPoint(x: 50, y: 280))
    }
}
