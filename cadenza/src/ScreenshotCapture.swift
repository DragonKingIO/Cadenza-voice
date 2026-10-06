import AppKit
import ScreenCaptureKit
import Carbon.HIToolbox

// MARK: - 屏幕录制权限（截图需要）

enum ScreenCapturePermission {
    static var granted: Bool { CGPreflightScreenCaptureAccess() }
    /// 第一次调用会弹出系统授权窗口；之后只返回当前状态
    @discardableResult static func request() -> Bool { CGRequestScreenCaptureAccess() }
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
}

// MARK: - 抓取每块屏幕的“冻结画面”

struct CapturedDisplay {
    let screen: NSScreen
    /// 物理像素大小的整屏图片
    let image: CGImage
    /// 像素 / 点
    let scale: CGFloat
    /// 本屏上的窗口矩形（本屏局部坐标、左上角为原点、y 向下），从前到后排序，用于“悬停高亮窗口”
    let windows: [CGRect]
    var pointSize: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }
}

enum ScreenshotCaptureError: LocalizedError {
    case noDisplays
    var errorDescription: String? { L10n.tr("screenshot.err.noDisplay") }
}

enum ScreenshotCapture {
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// 在显示选区窗口之前调用，保证画面里没有我们自己的覆盖层
    static func captureAll() async throws -> [CapturedDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var result: [CapturedDisplay] = []
        for screen in NSScreen.screens {
            guard let id = displayID(of: screen), let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = Int((filter.contentRect.width * scale).rounded())
            config.height = Int((filter.contentRect.height * scale).rounded())
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            result.append(CapturedDisplay(screen: screen, image: image, scale: CGFloat(image.width) / max(1, screen.frame.width),
                                          windows: windowRects(onDisplay: id)))
        }
        guard !result.isEmpty else { throw ScreenshotCaptureError.noDisplays }
        return result
    }

    /// 窗口列表只用边界信息，不需要屏幕录制权限；顺序是从前到后
    static func windowRects(onDisplay id: CGDirectDisplayID) -> [CGRect] {
        let bounds = CGDisplayBounds(id)
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
            let local = rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY).intersection(CGRect(origin: .zero, size: bounds.size))
            return local.isNull || local.width < 40 || local.height < 24 ? nil : local
        }
    }
}

// MARK: - 截图全局快捷键（Carbon，无需额外权限）

final class ScreenshotHotkey {
    static let signature = OSType(0x43444E53)   // 'CDNS'
    /// 同一个签名下用不同 id 区分截图（1）与截图识字（2）
    let hotkeyID: UInt32
    var onPress: (() -> Void)?
    init(id: UInt32 = 1) { hotkeyID = id }
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var status = ""
    private(set) var registered: HotkeySpec?

    deinit { unregister(); if let handler { RemoveEventHandler(handler) } }

    @discardableResult
    func register(_ spec: HotkeySpec) -> Bool {
        unregister()
        installHandler()
        var newRef: EventHotKeyRef?
        let rc = RegisterEventHotKey(spec.keyCode, spec.modifiers, EventHotKeyID(signature: Self.signature, id: hotkeyID), GetApplicationEventTarget(), 0, &newRef)
        guard rc == noErr else {
            status = L10n.format("ui.17223dc1cc51", String(describing: rc))
            Log.write("screenshot-hotkey-register-FAILED status=\(rc) \(HotkeySpecDisplay.string(spec))")
            return false
        }
        ref = newRef; registered = spec; status = ""
        Log.write("screenshot-hotkey-registered \(HotkeySpecDisplay.string(spec))")
        return true
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil; registered = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID(); var size = 0
            let rc = withUnsafeMutableBytes(of: &id) { GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, $0.count, &size, $0.baseAddress) }
            // 只处理自己的热键；其余（语音触发键等）交还给原来的处理器
            guard rc == noErr, id.signature == ScreenshotHotkey.signature else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<ScreenshotHotkey>.fromOpaque(userData).takeUnretainedValue()
            guard id.id == hotkey.hotkeyID else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { hotkey.onPress?() }
            return noErr
        }, 1, &spec, me, &handler)
    }
}
