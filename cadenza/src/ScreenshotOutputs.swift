import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 截图的输出：复制、保存、贴图、识别结果
// 都由用户在工具栏上明确点击触发；软件不会在后台自动写剪贴板。

enum ScreenshotOutputs {
    static let lastFolderKey = "screenshot.lastFolder"

    static func copy(_ image: CGImage, scale: CGFloat, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        if let png = ScreenshotRenderer.pngData(image) { pasteboard.setData(png, forType: .png) }
        if let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
    }

    static func fileName(date: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH.mm.ss"   // 文件名里不放冒号
        return L10n.format("screenshot.fileName", Brand.name, f.string(from: date)) + ".png"
    }

    static var defaultFolder: URL {
        if let path = UserDefaults.standard.string(forKey: lastFolderKey), FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// 弹出保存面板并写入；返回 nil 表示用户取消，失败会抛错
    @discardableResult
    static func saveWithPanel(_ image: CGImage) throws -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = fileName()
        panel.directoryURL = defaultFolder
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let png = ScreenshotRenderer.pngData(image) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url, options: .atomic)
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: lastFolderKey)
        return url
    }

    static func alert(title: String, message: String, openSettings: Bool = false) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: L10n.tr(openSettings ? "screenshot.perm.open" : "action.done"))
        if openSettings { alert.addButton(withTitle: L10n.tr("screenshot.perm.later")) }
        if alert.runModal() == .alertFirstButtonReturn, openSettings { ScreenCapturePermission.openSettings() }
    }
}

// MARK: - 识别结果窗口

struct OCRResultView: View {
    let result: OCRResult
    let thumbnail: NSImage
    let close: () -> Void
    @State private var text: String
    @State private var copied = false

    init(result: OCRResult, thumbnail: NSImage, close: @escaping () -> Void) {
        self.result = result; self.thumbnail = thumbnail; self.close = close
        _text = State(initialValue: result.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: thumbnail).resizable().scaledToFit().frame(maxWidth: 120, maxHeight: 64)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.15)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.format("screenshot.ocr.lines", result.lines.count)).font(.callout)
                    Text(ScreenshotController.engineNote(result)).font(.caption).foregroundStyle(result.fallbackReason == nil ? Color.secondary : Color.orange)
                }
            }
            ForEach(Array(result.codes.enumerated()), id: \.offset) { _, code in
                HStack(spacing: 8) {
                    Image(nsImage: ScreenshotIcon.image("qr")).renderingMode(.template).resizable().frame(width: 16, height: 16)
                    Text(code.payload).font(.callout).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button(L10n.tr("screenshot.code.copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code.payload, forType: .string) }.buttonStyle(.borderless)
                    if code.isURL { Button(L10n.tr("screenshot.code.open")) { if let url = URL(string: code.payload.trimmingCharacters(in: .whitespacesAndNewlines)) { NSWorkspace.shared.open(url) } }.buttonStyle(.borderless) }
                }
                .padding(8).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            if result.isEmpty {
                Text(L10n.tr("screenshot.ocr.empty")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: $text).font(.body).frame(maxHeight: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
            }
            HStack {
                Button(L10n.tr(copied ? "screenshot.ocr.copied" : "screenshot.ocr.copy")) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }.disabled(text.isEmpty).keyboardShortcut("c", modifiers: [.command, .shift])
                Spacer()
                Button(L10n.tr("action.done"), action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16).frame(minWidth: 360, minHeight: 260)
    }
}

enum OCRResultWindow {
    private static var open: [NSPanel] = []
    private final class Delegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) { if let w = notification.object as? NSPanel { OCRResultWindow.open.removeAll { $0 === w } } }
    }
    private static let delegate = Delegate()

    static func show(_ result: OCRResult, thumbnail: NSImage, near frame: NSRect) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 340), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = L10n.tr("screenshot.ocr.title"); panel.level = .floating; panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.delegate = delegate
        panel.contentView = NSHostingView(rootView: OCRResultView(result: result, thumbnail: thumbnail, close: { [weak panel] in panel?.close() }))
        let area = (NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main)?.visibleFrame ?? frame
        var origin = NSPoint(x: frame.midX - 220, y: frame.midY - 170)
        origin.x = min(max(origin.x, area.minX + 12), area.maxX - 452); origin.y = min(max(origin.y, area.minY + 12), area.maxY - 352)
        panel.setFrameOrigin(origin)
        open.append(panel)
        panel.makeKeyAndOrderFront(nil)
    }
}
