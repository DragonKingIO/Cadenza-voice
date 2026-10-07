import AppKit
import SwiftUI

/// 开始截图的方式
enum ScreenshotLaunch: Equatable {
    case interactive          // 框选区域（默认）
    case fullScreen           // 鼠标所在屏幕整屏
    case repeatLast           // 再次框住上一次的区域
    case directOCR            // 框选后不出工具栏，直接识别文字并复制
}

/// 一次截图会话：抓取 → 选区 → 标注 → 复制 / 保存 / 贴图 / 识别文字。
final class ScreenshotController {
    private(set) var isActive = false
    /// 当前截图设置（OCR 引擎、同意、回退、取色格式）
    var settings: () -> ScreenshotSettings = { ScreenshotSettings() }
    /// 创建 OCR 路由器（便于测试时注入假的传输层）
    var makeRouter: (ScreenshotSettings) -> OCRRouter = { OCRRouter(settings: $0) }
    /// 语音正在录音时不开始截图
    var canStart: () -> Bool = { true }
    var onColorFormatChange: (Int) -> Void = { _ in }
    /// 截图过程中是否已有会话在倒计时
    private(set) var counting = false

    private var panels: [ScreenshotPanel] = []
    private var canvases: [ScreenshotCanvasView] = []
    private var active: ScreenshotCanvasView?
    private let model = ScreenshotToolbarModel()
    private var palette: NSHostingView<ScreenshotPaletteView>?
    private var actionBar: NSHostingView<ScreenshotActionBarView>?
    private var launch: ScreenshotLaunch = .interactive
    private var layoutScheduled = false
    private var lastResult: OCRResult?
    private var lastImage: CGImage?
    private var lastRegion: (displayID: CGDirectDisplayID, rect: CGRect)?
    private var recognitionTask: Task<Void, Never>?
    /// 工具栏视图四周为阴影预留的空白（点）
    private static let shadowPadding: CGFloat = 10

    init() { wireToolbar() }

    // MARK: 开始

    func start(_ mode: ScreenshotLaunch = .interactive, delay: TimeInterval = 0) {
        guard !isActive, !counting, canStart() else { return }
        guard ScreenCapturePermission.granted else {
            ScreenCapturePermission.request()
            ScreenshotOutputs.alert(title: L10n.tr("screenshot.perm.title"), message: L10n.format("screenshot.perm.message", Brand.name), openSettings: true)
            return
        }
        if mode == .repeatLast, lastRegion == nil { CountdownHUD.toast(L10n.tr("screenshot.repeat.none")); return }
        guard delay > 0 else { begin(mode); return }
        counting = true
        CountdownHUD.run(seconds: Int(delay)) { [weak self] in self?.counting = false; self?.begin(mode) }
    }

    private func begin(_ mode: ScreenshotLaunch) {
        guard !isActive else { return }
        isActive = true; launch = mode
        Task { @MainActor [weak self] in
            do {
                let displays = try await ScreenshotCapture.captureAll()
                self?.present(displays)
            } catch {
                self?.isActive = false
                Log.write("screenshot-capture-failed \(error.localizedDescription)")
                // 授权被撤销或系统拒绝时，错误里没有明确原因，统一引导到系统设置
                ScreenshotOutputs.alert(title: L10n.tr("screenshot.perm.title"), message: L10n.format("screenshot.perm.message", Brand.name), openSettings: true)
            }
        }
    }

    private func present(_ displays: [CapturedDisplay]) {
        model.tool = nil; model.message = ""; model.recognizing = false; model.canUndo = false; model.canRedo = false
        model.recognition = nil; model.selectedTool = nil
        lastResult = nil; lastImage = nil
        let mouse = NSEvent.mouseLocation
        let format = settings().colorFormat
        for display in displays {
            let canvas = ScreenshotCanvasView(display: display)
            canvas.colorFormat = format
            canvas.directMode = launch == .directOCR
            canvas.onSelectionBegan = { [weak self] c in self?.selectionBegan(on: c) }
            canvas.onSelectionChanged = { [weak self] c, finished in self?.selectionChanged(c, finished: finished) }
            canvas.onObjectsChanged = { [weak self] in self?.syncHistoryState() }
            canvas.onObjectSelected = { [weak self] object in self?.objectSelected(object) }
            canvas.onKeyCommand = { [weak self] command in self?.handle(command) }
            canvas.onColorFormatChanged = { [weak self] value in self?.onColorFormatChange(value) }
            let panel = ScreenshotPanel(contentRect: display.screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false, screen: display.screen)
            panel.level = .screenSaver; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false; panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.onCancel = { [weak self] in self?.finish() }
            panel.contentView = canvas
            panel.setFrame(display.screen.frame, display: false)
            panels.append(panel); canvases.append(canvas)
        }
        let key = panels.first { $0.frame.contains(mouse) } ?? panels.first
        panels.forEach { $0.orderFrontRegardless() }
        key?.makeKey()
        if let key { key.makeFirstResponder(key.contentView) }
        NSCursor.crosshair.set()
        switch launch {
        case .fullScreen:
            if let canvas = canvases.first(where: { $0.window === key }) ?? canvases.first { canvas.presetSelection(canvas.bounds) }
        case .repeatLast:
            if let last = lastRegion, let canvas = canvases.first(where: { ScreenshotCapture.displayID(of: $0.display.screen) == last.displayID }) { canvas.presetSelection(last.rect) }
            else { CountdownHUD.toast(L10n.tr("screenshot.repeat.none")); finish() }
        case .interactive, .directOCR: break
        }
    }

    // MARK: 选区事件

    private func selectionBegan(on canvas: ScreenshotCanvasView) {
        active = canvas
        for other in canvases where other !== canvas { other.locked = true }
        (canvas.window as? ScreenshotPanel)?.makeKey()
    }

    private func selectionChanged(_ canvas: ScreenshotCanvasView, finished: Bool) {
        guard finished else { palette?.isHidden = true; actionBar?.isHidden = true; return }
        guard let sel = canvas.selection else {          // 选区被取消：恢复所有屏幕
            canvases.forEach { $0.locked = false }; active = nil; removeToolbars(); model.canUndo = false; model.canRedo = false; model.recognition = nil; return
        }
        if let id = ScreenshotCapture.displayID(of: canvas.display.screen) { lastRegion = (id, sel) }
        if launch == .directOCR { runDirectOCR(on: canvas); return }
        showToolbar(on: canvas)
    }

    private func showToolbar(on canvas: ScreenshotCanvasView) {
        if actionBar == nil || actionBar?.superview !== canvas {
            removeToolbars()
            let paletteHost = NSHostingView(rootView: ScreenshotPaletteView(model: model))
            let actionHost = NSHostingView(rootView: ScreenshotActionBarView(model: model))
            canvas.addSubview(paletteHost); canvas.addSubview(actionHost)
            palette = paletteHost; actionBar = actionHost
            for host in [paletteHost, actionHost] { host.wantsLayer = true; host.alphaValue = 0 }
            NSAnimationContext.runAnimationGroup { context in context.duration = 0.16; paletteHost.animator().alphaValue = 1; actionHost.animator().alphaValue = 1 }
        }
        palette?.isHidden = model.recognition != nil; actionBar?.isHidden = false
        layoutToolbar()
    }

    private func removeToolbars() {
        palette?.removeFromSuperview(); actionBar?.removeFromSuperview(); palette = nil; actionBar = nil
    }

    private func scheduleLayout() {
        guard !layoutScheduled else { return }
        layoutScheduled = true
        DispatchQueue.main.async { [weak self] in self?.layoutScheduled = false; self?.layoutToolbar() }
    }

    private func layoutToolbar() {
        guard let palette, let actionBar, let canvas = active, let sel = canvas.selection else { return }
        let pad = Self.shadowPadding
        actionBar.layoutSubtreeIfNeeded(); palette.layoutSubtreeIfNeeded()
        // 操作条：贴在选区下方，右缘与选区对齐（hosting 视图比卡片多出一圈阴影空白，横向放宽同样的量）
        let actionFrame = ScreenshotGeometry.toolbarFrame(selection: sel.insetBy(dx: -pad, dy: 0), size: actionBar.fittingSize, bounds: canvas.bounds, gap: 0)
        actionBar.frame = actionFrame
        palette.isHidden = model.recognition != nil
        palette.frame = ScreenshotGeometry.paletteFrame(selection: sel.offsetBy(dx: 0, dy: -pad + 2), size: palette.fittingSize, bounds: canvas.bounds, avoiding: actionFrame, gap: -4)
    }

    // MARK: 工具栏同步

    private func wireToolbar() {
        model.onSelectTool = { [weak self] tool in self?.applyTool(tool) }
        model.onStyleChanged = { [weak self] in
            guard let self, let canvas = self.active else { return }
            canvas.style = self.model.style; canvas.applyStyleToSelected()
        }
        model.onUndo = { [weak self] in self?.active?.undo() }
        model.onRedo = { [weak self] in self?.active?.redo() }
        model.onDelete = { [weak self] in self?.active?.deleteSelected() }
        model.onSave = { [weak self] in self?.save() }
        model.onPin = { [weak self] in self?.pin() }
        model.onOCR = { [weak self] in self?.recognize() }
        model.onCancel = { [weak self] in self?.finish() }
        model.onConfirm = { [weak self] in self?.confirm() }
        model.onBackToAnnotate = { [weak self] in self?.leaveRecognition() }
        model.onSelectAllText = { [weak self] in self?.active?.selectAllRecognized(); self?.refreshRecognitionSummary() }
        model.onCopyText = { [weak self] in self?.copyRecognizedText() }
        model.onOpenResultWindow = { [weak self] in self?.openResultWindow() }
        model.onCopyCode = { [weak self] code in
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code.payload, forType: .string)
            self?.active?.showToast(L10n.tr("screenshot.code.copied"))
        }
        model.onOpenCode = { code in if let url = URL(string: code.payload.trimmingCharacters(in: .whitespacesAndNewlines)) { NSWorkspace.shared.open(url) } }
    }

    private func applyTool(_ tool: ScreenshotTool?) {
        guard let canvas = active else { return }
        canvas.tool = tool; canvas.style = model.style
        scheduleLayout()
    }

    private func syncHistoryState() {
        model.canUndo = active?.canUndo ?? false; model.canRedo = active?.canRedo ?? false
    }

    /// 选中了一个已有标注：调色板显示它的样式
    private func objectSelected(_ object: AnnotationObject?) {
        guard let object else { model.selectedTool = nil; scheduleLayout(); return }
        model.selectedTool = ScreenshotIcon.tool(for: object.shape)
        var style = model.style
        if object.usesColor { style.color = object.color }
        style.level = object.level; style.filled = object.filled; style.arrowStyle = object.arrowStyle; style.textStyle = object.textStyle
        model.style = style; active?.style = style
        scheduleLayout()
    }

    private func handle(_ command: ScreenshotKeyCommand) {
        switch command {
        case .cancel: finish()
        case .confirm: if active?.selection != nil { confirm() }
        case .undo: active?.undo()
        case .redo: active?.redo()
        case .save: if active?.selection != nil { save() }
        case .tool(let tool): model.tool = model.tool == tool ? nil : tool; applyTool(model.tool)
        case .exitRecognition: leaveRecognition()
        case .selectAllText: active?.selectAllRecognized(); refreshRecognitionSummary()
        case .copySelectedText: copyRecognizedText()
        }
    }

    /// 选区在屏幕上的位置（用于贴图与识别结果窗口定位）
    private func screenFrame(of canvas: ScreenshotCanvasView) -> NSRect? {
        guard let sel = canvas.selection, let window = canvas.window else { return nil }
        let snapped = ScreenshotGeometry.snapped(sel, scale: canvas.display.scale)
        return NSRect(x: window.frame.minX + snapped.minX, y: window.frame.maxY - snapped.maxY, width: snapped.width, height: snapped.height)
    }

    // MARK: 输出

    func confirm() {
        guard let canvas = active, let image = canvas.renderedImage() else { return }
        ScreenshotOutputs.copy(image, scale: canvas.display.scale)
        finish()
    }

    func save() {
        guard let canvas = active, let image = canvas.renderedImage() else { return }
        panels.forEach { $0.orderOut(nil) }      // 保存面板要显示在最上面
        do {
            if try ScreenshotOutputs.saveWithPanel(image) != nil { finish(); return }
        } catch {
            ScreenshotOutputs.alert(title: L10n.tr("screenshot.save.failed"), message: error.localizedDescription)
        }
        panels.forEach { $0.orderFrontRegardless() }   // 取消保存：回到编辑
        (canvas.window as? ScreenshotPanel)?.makeKey()
    }

    func pin() {
        guard let canvas = active, let image = canvas.renderedImage(), let frame = screenFrame(of: canvas) else { return }
        let configuration = settings()
        PinManager.shared.pin(image: image, scale: canvas.display.scale, at: frame, router: { [makeRouter] in makeRouter(configuration) })
        finish()
    }

    // MARK: 文字识别

    func recognize() {
        guard let canvas = active, !model.recognizing, let image = canvas.cleanImage() else { return }
        canvas.commitEditor()
        model.recognizing = true; model.message = ""
        scheduleLayout()
        let router = makeRouter(settings())
        recognitionTask = Task { @MainActor [weak self] in
            do {
                let result = try await router.recognize(image)
                guard let self, self.isActive, self.active === canvas else { return }
                self.model.recognizing = false
                self.lastResult = result; self.lastImage = image
                if result.hasBoxes {
                    canvas.showRecognition(result.lines)
                    self.refreshRecognitionSummary(result)
                } else {
                    self.openResultWindow()
                    self.model.recognition = RecognitionSummary(lineCount: result.lines.count, engineNote: Self.engineNote(result), codes: result.codes, hasOverlay: false)
                }
                self.scheduleLayout()
            } catch {
                guard let self, self.isActive else { return }
                self.model.recognizing = false
                self.model.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.scheduleLayout()
            }
        }
    }

    static func engineNote(_ result: OCRResult) -> String {
        if let reason = result.fallbackReason { return L10n.format("screenshot.ocr.fellBack", reason) }
        if let provider = OCRProvider(rawValue: result.engine) { return L10n.format("screenshot.ocr.by", provider.title) }
        if result.engine == PaddleOCREngine.engineID { return L10n.format("screenshot.ocr.byLocal", "PP-OCR") }
        return L10n.tr("screenshot.ocr.local")
    }

    private func refreshRecognitionSummary(_ result: OCRResult? = nil) {
        guard let canvas = active, let result = result ?? lastResult else { return }
        model.recognition = RecognitionSummary(lineCount: canvas.recognizedCount, selectedCount: canvas.selectedRecognizedCount, engineNote: Self.engineNote(result), codes: result.codes, hasOverlay: true)
        scheduleLayout()
    }

    private func leaveRecognition() {
        active?.hideRecognition(); model.recognition = nil; model.message = ""; scheduleLayout()
    }

    private func copyRecognizedText() {
        guard let canvas = active else { return }
        let text = canvas.recognitionActive ? canvas.recognizedText() : (lastResult?.text ?? "")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)     // 用户点击“复制文字”
        canvas.showToast(L10n.tr("screenshot.ocr.copied"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.finish() }
    }

    private func openResultWindow() {
        guard let canvas = active, let result = lastResult, let image = lastImage, let frame = screenFrame(of: canvas) else { return }
        OCRResultWindow.show(result, thumbnail: ScreenshotRenderer.nsImage(image, scale: canvas.display.scale), near: frame)
    }

    /// “截图并直接识字”：框选完成后不出工具栏，识别完把文字放进剪贴板
    private func runDirectOCR(on canvas: ScreenshotCanvasView) {
        guard let image = canvas.cleanImage() else { finish(); return }
        let router = makeRouter(settings())
        canvas.showToast(L10n.tr("screenshot.ocr.running"), seconds: 30)
        Task { @MainActor [weak self] in
            var message: String
            do {
                let result = try await router.recognize(image)
                let text = result.isEmpty ? (result.codes.first?.payload ?? "") : result.text
                if text.isEmpty { message = L10n.tr("screenshot.ocr.empty") }
                else {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)   // 由用户触发的“直接识字”快捷键明确要求复制
                    message = result.isEmpty ? L10n.tr("screenshot.code.copied") : L10n.format("screenshot.ocr.directCopied", result.lines.count)
                    if result.fallbackReason != nil { message += " · " + L10n.tr("screenshot.ocr.usedLocal") }
                }
            } catch { message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            guard let self, self.isActive else { return }
            canvas.showToast(message, seconds: 1.4)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.finish() }
        }
    }

    // MARK: 结束

    func finish() {
        guard isActive else { return }
        isActive = false
        recognitionTask?.cancel(); recognitionTask = nil
        removeToolbars()
        panels.forEach { $0.contentView = nil; $0.orderOut(nil) }
        panels.removeAll(); canvases.removeAll(); active = nil
        model.tool = nil; model.recognizing = false; model.message = ""; model.recognition = nil; model.selectedTool = nil
        NSCursor.arrow.set()
    }
}

// MARK: - 倒计时与提示（延时截图用）

enum CountdownHUD {
    private static var panel: NSPanel?
    private static var timer: Timer?

    private static func makePanel(_ text: String, size: CGSize) -> (NSPanel, NSTextField) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let p = NSPanel(contentRect: NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - 140, width: size.width, height: size.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .screenSaver; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.ignoresMouseEvents = true; p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let box = NSVisualEffectView(frame: NSRect(origin: .zero, size: size)); box.material = .hudWindow; box.state = .active; box.wantsLayer = true; box.layer?.cornerRadius = size.height / 2
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size.height > 60 ? 34 : 15, weight: .semibold); label.alignment = .center
        label.frame = NSRect(x: 0, y: (size.height - label.intrinsicContentSize.height) / 2, width: size.width, height: label.intrinsicContentSize.height)
        box.addSubview(label); p.contentView = box
        return (p, label)
    }

    /// 倒数 `seconds` 秒后调用 `done`；倒数窗口先消失再截图，保证画面里没有它
    static func run(seconds: Int, done: @escaping () -> Void) {
        var left = max(1, seconds)
        let (p, label) = makePanel("\(left)", size: CGSize(width: 96, height: 96))
        panel = p; p.orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            left -= 1
            if left > 0 { label.stringValue = "\(left)"; return }
            t.invalidate(); timer = nil; p.orderOut(nil); panel = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: done)   // 等窗口真正消失
        }
    }

    static func toast(_ text: String, seconds: TimeInterval = 1.6) {
        let width = max(180, (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)]).width + 44)
        let (p, _) = makePanel(text, size: CGSize(width: width, height: 40))
        panel = p; p.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { p.orderOut(nil); if panel === p { panel = nil } }
    }
}
