import AppKit

/// 覆盖整块屏幕的选区窗口。不激活应用，因此截图前的输入框焦点不会被抢走。
final class ScreenshotPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

enum ScreenshotKeyCommand: Equatable {
    case cancel, confirm, undo, redo, save
    case tool(ScreenshotTool)
    /// 识别结果叠加层：退出 / 全选 / 复制所选
    case exitRecognition, selectAllText, copySelectedText
}

struct ScreenshotStyle: Equatable {
    var color: ScreenshotColor = .red
    var level = 1
    var filled = false
    var arrowStyle: ArrowStyle = .single
    var textStyle: TextStyle = .plain
}

/// 识别结果在画布上的一个可选文字块
struct RecognizedBox: Equatable {
    var rect: CGRect
    var text: String
    var selected = false
}

/// 一块屏幕上的画布：显示冻结画面、选区、标注、放大镜、识别叠加层。坐标为本屏点坐标，左上角为原点（isFlipped）。
final class ScreenshotCanvasView: NSView, NSTextFieldDelegate {
    let display: CapturedDisplay
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: 状态

    private(set) var selection: CGRect?
    private(set) var objects: [AnnotationObject] = []
    private(set) var selectedID: UUID?
    private var history = AnnotationHistory()
    var tool: ScreenshotTool? {
        didSet {
            guard tool != oldValue else { return }
            commitEditor(); if tool != nil { setSelected(nil) }
            window?.invalidateCursorRects(for: self); needsDisplay = true
        }
    }
    var style = ScreenshotStyle() { didSet { restyleEditor() } }
    /// 另一块屏幕正在选区时，本屏只显示暗色，不响应鼠标
    var locked = false { didSet { needsDisplay = true } }
    /// 直接识字模式：框选完成即交给控制器，不出现标注工具
    var directMode = false
    var colorFormat = 1
    private(set) var recognition: [RecognizedBox]?
    /// 按 C 复制颜色时写入的剪贴板（自检会换成专用的）
    var pasteboard: NSPasteboard = .general

    var onSelectionBegan: ((ScreenshotCanvasView) -> Void)?
    /// finished == false 表示正在拖动
    var onSelectionChanged: ((ScreenshotCanvasView, Bool) -> Void)?
    var onObjectsChanged: (() -> Void)?
    /// 选中（或取消选中）某个标注：控制器据此把调色板同步成它的样式
    var onObjectSelected: ((AnnotationObject?) -> Void)?
    var onKeyCommand: ((ScreenshotKeyCommand) -> Void)?
    var onColorFormatChanged: ((Int) -> Void)?

    private enum ObjectHandle: Equatable { case rect(SelectionHandle), endpoint(Int) }
    private enum Mode {
        case idle, selecting(CGPoint), moving(CGPoint, CGRect), resizing(SelectionHandle, CGRect), drawing(CGPoint)
        case movingObject(CGPoint, AnnotationObject), resizingObject(ObjectHandle, AnnotationObject), picking
    }
    private var mode: Mode = .idle
    private var hover: CGRect?
    private var draft: AnnotationObject?
    private var penPoints: [CGPoint] = []
    private var editor: NSTextField?
    private var editorOrigin: CGPoint = .zero
    private var editingID: UUID?
    private var pendingBefore: [AnnotationObject]?
    private var lastMouse: CGPoint?
    /// 点在一段已选中的文字上：松开时如果没拖动，就进入编辑
    private var reeditCandidate: (id: UUID, at: CGPoint)?
    private var sampler: PixelSampler?
    private var toast: (text: String, until: TimeInterval)?
    private lazy var effects = ScreenshotEffects(image: display.image, scale: display.scale)

    init(display: CapturedDisplay) {
        self.display = display
        super.init(frame: NSRect(origin: .zero, size: display.screen.frame.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    var selectedObject: AnnotationObject? { selectedID.flatMap { id in objects.first { $0.id == id } } }
    var nextMarkerNumber: Int { (objects.compactMap(\.markerNumber).max() ?? 0) + 1 }

    // MARK: 输出

    func renderedImage() -> CGImage? {
        guard let selection else { return nil }
        return ScreenshotRenderer.render(display: display.image, effects: effects, selection: selection, scale: display.scale, objects: objects)
    }
    /// 不含标注的原图，供 OCR 使用（标注会干扰识别）
    func cleanImage() -> CGImage? {
        guard let selection else { return nil }
        return ScreenshotRenderer.render(display: display.image, effects: nil, selection: selection, scale: display.scale, objects: [])
    }

    // MARK: 对外操作

    /// 直接设定选区（全屏截图、重复上次区域）
    func presetSelection(_ rect: CGRect) {
        onSelectionBegan?(self)
        selection = ScreenshotGeometry.clamp(rect, to: bounds); hover = nil; needsDisplay = true
        onSelectionChanged?(self, true)
    }

    func showToast(_ text: String, seconds: TimeInterval = 1.6) {
        toast = (text, ProcessInfo.processInfo.systemUptime + seconds); needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.05) { [weak self] in self?.needsDisplay = true }
    }

    func undo() {
        commitEditor(cancel: true)
        guard let previous = history.undo(current: objects) else { return }
        objects = previous; fixSelection(); changed()
    }
    func redo() {
        commitEditor(cancel: true)
        guard let next = history.redo(current: objects) else { return }
        objects = next; fixSelection(); changed()
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        mutate { $0.removeAll { $0.id == id } }
        setSelected(nil)
    }

    /// 调色板改了样式：已选中的标注同步更新
    func applyStyleToSelected() {
        guard let id = selectedID, let index = objects.firstIndex(where: { $0.id == id }) else { return }
        var updated = objects[index]
        if updated.usesColor { updated.color = style.color }
        updated.level = style.level
        switch updated.shape {
        case .rectangle, .ellipse: updated.filled = style.filled
        case .line: updated.arrowStyle = style.arrowStyle
        case .text: updated.textStyle = style.textStyle
        default: break
        }
        guard updated != objects[index] else { return }
        // 只重画这个标注附近：整屏重画在大屏上会让换色有明显延迟
        let dirty = objects[index].bounds.union(updated.bounds).insetBy(dx: -24, dy: -24)
        history.record(objects); objects[index] = updated
        setNeedsDisplay(dirty); onObjectsChanged?()
    }

    func resetSelection() {
        commitEditor(cancel: true)
        selection = nil; objects.removeAll(); history.reset(); draft = nil; mode = .idle; setSelected(nil); recognition = nil
        needsDisplay = true; changed(); onSelectionChanged?(self, true)
    }

    // 自检专用：不经过鼠标事件直接设置选区/标注
    func testSetSelection(_ r: CGRect?) { selection = r; needsDisplay = true }
    func testAdd(_ o: AnnotationObject) { objects.append(o) }

    private func changed() { needsDisplay = true; onObjectsChanged?() }
    /// 所有改动标注的操作都经过这里，统一记录撤销历史
    private func mutate(_ change: (inout [AnnotationObject]) -> Void) {
        history.record(objects); change(&objects); changed()
    }
    private func fixSelection() { if let id = selectedID, !objects.contains(where: { $0.id == id }) { setSelected(nil) } }
    private func setSelected(_ id: UUID?) {
        guard selectedID != id else { return }
        selectedID = id; needsDisplay = true; onObjectSelected?(selectedObject)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ScreenshotRenderer.drawUpright(ctx, display.image, in: bounds)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.42))
        guard let sel = selection else {
            ctx.addRect(bounds)
            if let hover { ctx.addRect(hover) }
            ctx.fillPath(using: .evenOdd)
            if let hover { stroke(hover, ctx, width: 2) }
            if !locked, hover == nil { drawHint(ctx) }
            if !locked { drawLoupe(ctx) }
            drawToast(ctx)
            return
        }
        ctx.addRect(bounds); ctx.addRect(sel); ctx.fillPath(using: .evenOdd)
        var visible = objects.filter { $0.id != editingID }
        if let draft { visible.append(draft) }
        ctx.saveGState(); ctx.clip(to: sel)
        ScreenshotRenderer.draw(visible, in: ctx, effects: effects, displayRect: CGRect(origin: .zero, size: bounds.size))
        ctx.restoreGState()
        guard !locked else { return }
        stroke(sel, ctx, width: 1.5)
        if recognition == nil { drawHandles(sel, ctx); drawObjectChrome(ctx) } else { drawRecognition(ctx) }
        drawSizeLabel(sel, ctx)
        if case .resizing = mode { drawLoupe(ctx) } else if case .selecting = mode { drawLoupe(ctx) }
        drawToast(ctx)
    }

    /// 跟随系统强调色（用户可在系统设置里更改）
    private var accent: CGColor { NSColor.controlAccentColor.usingColorSpace(.sRGB)?.cgColor ?? CGColor(srgbRed: 0.0, green: 0.48, blue: 1, alpha: 1) }
    private func stroke(_ r: CGRect, _ ctx: CGContext, width: CGFloat) {
        ctx.setStrokeColor(accent); ctx.setLineWidth(width); ctx.stroke(r)
    }

    /// 角上是粗的“L”形角标，边中点是短胶囊条（命中位置与 ScreenshotGeometry.hitHandle 一致）
    private func drawHandles(_ sel: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(accent); ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setLineWidth(3.5)
        let arm: CGFloat = min(14, min(sel.width, sel.height) / 3)
        for handle in [SelectionHandle.topLeft, .topRight, .bottomRight, .bottomLeft] {
            let c = ScreenshotGeometry.center(of: handle, in: sel)
            let dx: CGFloat = (handle == .topLeft || handle == .bottomLeft) ? 1 : -1, dy: CGFloat = (handle == .topLeft || handle == .topRight) ? 1 : -1
            ctx.beginPath(); ctx.move(to: CGPoint(x: c.x + dx * arm, y: c.y)); ctx.addLine(to: c); ctx.addLine(to: CGPoint(x: c.x, y: c.y + dy * arm)); ctx.strokePath()
        }
        if sel.width >= 28 && sel.height >= 28 {
            ctx.setLineWidth(4)
            for handle in [SelectionHandle.top, .bottom] { let c = ScreenshotGeometry.center(of: handle, in: sel); ctx.beginPath(); ctx.move(to: CGPoint(x: c.x - 8, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + 8, y: c.y)); ctx.strokePath() }
            for handle in [SelectionHandle.left, .right] { let c = ScreenshotGeometry.center(of: handle, in: sel); ctx.beginPath(); ctx.move(to: CGPoint(x: c.x, y: c.y - 8)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 8)); ctx.strokePath() }
        }
        ctx.restoreGState()
    }

    /// 选中标注的虚线外框与手柄（圆点）
    private func drawObjectChrome(_ ctx: CGContext) {
        guard let o = selectedObject, editor == nil else { return }
        ctx.saveGState()
        ctx.setStrokeColor(accent); ctx.setLineWidth(1); ctx.setLineDash(phase: 0, lengths: [4, 3])
        if let (a, b) = o.endpoints {
            for p in [a, b] { drawDot(ctx, p) }
            ctx.restoreGState(); return
        }
        ctx.stroke(o.bounds)
        ctx.setLineDash(phase: 0, lengths: [])
        if let r = o.resizableRect {
            for h in SelectionHandle.allCases where (r.width >= 24 && r.height >= 24) || [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(h) { drawDot(ctx, ScreenshotGeometry.center(of: h, in: r)) }
        }
        ctx.restoreGState()
    }
    private func drawDot(_ ctx: CGContext, _ p: CGPoint) {
        let r = CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillEllipse(in: r)
        ctx.setStrokeColor(accent); ctx.setLineWidth(1.5); ctx.strokeEllipse(in: r)
    }

    private func drawRecognition(_ ctx: CGContext) {
        guard let boxes = recognition else { return }
        for b in boxes {
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(b.selected ? 0.42 : 0.16).cgColor)
            ctx.addPath(CGPath(roundedRect: b.rect.insetBy(dx: -2, dy: -1), cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.fillPath()
            if b.selected { ctx.setStrokeColor(accent); ctx.setLineWidth(1.2); ctx.stroke(b.rect.insetBy(dx: -2, dy: -1)) }
        }
    }

    private func pill(_ text: String, centeredAt point: CGPoint, _ ctx: CGContext, font: CGFloat = 12) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: font, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        let r = CGRect(x: point.x - size.width / 2 - 8, y: point.y - size.height / 2 - 3, width: size.width + 16, height: size.height + 6)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.7))
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)); ctx.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        (text as NSString).draw(at: CGPoint(x: r.minX + 8, y: r.minY + 3), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }
    private func drawSizeLabel(_ sel: CGRect, _ ctx: CGContext) {
        let size = ScreenshotGeometry.pixelSize(of: sel, scale: display.scale)
        let above = sel.minY - 18 >= 4
        pill("\(size.w) × \(size.h)", centeredAt: CGPoint(x: min(max(sel.minX + 40, 50), bounds.maxX - 50), y: above ? sel.minY - 16 : sel.minY + 16), ctx)
    }
    private func drawHint(_ ctx: CGContext) { pill(L10n.tr("screenshot.hint"), centeredAt: CGPoint(x: bounds.midX, y: 44), ctx) }
    private func drawToast(_ ctx: CGContext) {
        guard let toast, ProcessInfo.processInfo.systemUptime < toast.until else { return }
        pill(toast.text, centeredAt: CGPoint(x: bounds.midX, y: bounds.maxY - 80), ctx, font: 13)
    }

    // MARK: 放大镜与取色

    private var loupeVisible: Bool {
        guard lastMouse != nil, !locked else { return false }
        if selection == nil { return true }
        switch mode { case .selecting, .resizing: return true; default: return false }
    }

    private func pixel(at p: CGPoint) -> (r: Int, g: Int, b: Int)? {
        if sampler == nil { sampler = PixelSampler(display.image) }
        return sampler?.color(x: Int((p.x * display.scale).rounded(.down)), y: Int((p.y * display.scale).rounded(.down)))
    }
    /// 鼠标所在位置的颜色文字（RGB 或 HEX）
    func colorText(at p: CGPoint) -> String? { pixel(at: p).map { ColorText.text($0, format: colorFormat) } }

    private func drawLoupe(_ ctx: CGContext) {
        guard loupeVisible, let p = lastMouse else { return }
        let box = LoupeGeometry.frame(cursor: p, bounds: bounds)
        let src = LoupeGeometry.sourcePixels(cursor: p, scale: display.scale)
        let imageRect = CGRect(x: 0, y: 0, width: display.image.width, height: display.image.height)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.clip()
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fill(box)
        let inter = src.intersection(imageRect)
        if !inter.isNull, let crop = display.image.cropping(to: inter) {
            let cell = LoupeGeometry.zoom
            let dest = CGRect(x: box.minX + (inter.minX - src.minX) * cell, y: box.minY + (inter.minY - src.minY) * cell, width: inter.width * cell, height: inter.height * cell)
            ctx.interpolationQuality = .none          // 放大后看清每一个像素
            ScreenshotRenderer.drawUpright(ctx, crop, in: dest)
        }
        ctx.restoreGState()
        // 中心像素框 + 十字线
        let c = LoupeGeometry.zoom, center = CGRect(x: box.minX + CGFloat(LoupeGeometry.radiusPixels) * c, y: box.minY + CGFloat(LoupeGeometry.radiusPixels) * c, width: c, height: c)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95)); ctx.setLineWidth(1.5); ctx.stroke(center.insetBy(dx: -0.5, dy: -0.5))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.9)); ctx.setLineWidth(1); ctx.stroke(center.insetBy(dx: -1.5, dy: -1.5))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9)); ctx.setLineWidth(1.5); ctx.addPath(CGPath(roundedRect: box, cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.strokePath()
        // 信息条：坐标（物理像素）+ 颜色
        let px = Int((p.x * display.scale).rounded(.down)), py = Int((p.y * display.scale).rounded(.down))
        if let color = pixel(at: p) {
            let swatch = CGRect(x: box.minX, y: box.maxY + 6, width: 18, height: 18)
            ctx.setFillColor(CGColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)); ctx.fill(swatch)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9)); ctx.setLineWidth(1); ctx.stroke(swatch)
            pill("\(px), \(py)   \(ColorText.text(color, format: colorFormat))", centeredAt: CGPoint(x: box.minX + 26 + 82, y: box.maxY + 15), ctx, font: 11)
        }
        pill(L10n.tr("screenshot.loupe.hint"), centeredAt: CGPoint(x: box.midX, y: box.maxY + 38), ctx, font: 10)
    }

    // MARK: 鼠标（事件入口只做转换，逻辑都在 handleMouse* 里，便于自检直接驱动）

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseMoved(with event: NSEvent) { handleMouseMoved(point(event)) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(at: point(event)) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); handleMouseDown(point(event), clickCount: event.clickCount, shift: event.modifierFlags.contains(.shift)) }
    override func mouseDragged(with event: NSEvent) { handleMouseDragged(point(event), shift: event.modifierFlags.contains(.shift)) }
    override func mouseUp(with event: NSEvent) { handleMouseUp(point(event)) }
    override func rightMouseDown(with event: NSEvent) {
        // 右键：已有选区先取消选区，否则退出截图（与常见截图工具一致）
        if selection != nil { resetSelection() } else { onKeyCommand?(.cancel) }
    }

    func handleMouseMoved(_ p: CGPoint) {
        guard !locked else { return }
        lastMouse = p
        if selection == nil {
            let found = ScreenshotGeometry.window(at: p, in: display.windows)
            if found != hover { hover = found }
            needsDisplay = true
        }
        updateCursor(at: p)
    }

    private func updateCursor(at p: CGPoint) {
        if recognition != nil { NSCursor.iBeam.set(); return }
        guard let sel = selection else { NSCursor.crosshair.set(); return }
        if let o = selectedObject, objectHandle(at: p, for: o) != nil { NSCursor.crosshair.set(); return }
        if let h = ScreenshotGeometry.hitHandle(p, in: sel) {
            switch h { case .top, .bottom: NSCursor.resizeUpDown.set(); case .left, .right: NSCursor.resizeLeftRight.set(); default: NSCursor.crosshair.set() }
        } else if sel.contains(p) {
            switch tool {
            case nil: (topObject(at: p) != nil ? NSCursor.pointingHand : NSCursor.openHand).set()
            case .text?: NSCursor.iBeam.set()
            default: NSCursor.crosshair.set()
            }
        } else { NSCursor.arrow.set() }
    }

    private func topObject(at p: CGPoint) -> AnnotationObject? { objects.last { $0.hit(p) } }

    private func objectHandle(at p: CGPoint, for o: AnnotationObject) -> ObjectHandle? {
        if let (a, b) = o.endpoints {
            if hypot(p.x - a.x, p.y - a.y) <= 8 { return .endpoint(0) }
            if hypot(p.x - b.x, p.y - b.y) <= 8 { return .endpoint(1) }
            return nil
        }
        if let r = o.resizableRect, let h = ScreenshotGeometry.hitHandle(p, in: r, tolerance: 7) { return .rect(h) }
        return nil
    }

    func handleMouseDown(_ p: CGPoint, clickCount: Int = 1, shift: Bool = false) {
        guard !locked else { return }
        commitEditor()
        lastMouse = p; reeditCandidate = nil
        if recognition != nil { recognitionToggle(at: p); mode = .picking; return }
        guard let sel = selection else {
            onSelectionBegan?(self)
            mode = .selecting(ScreenshotGeometry.clamp(p, to: bounds)); return
        }
        if let o = selectedObject, let h = objectHandle(at: p, for: o) { pendingBefore = objects; mode = .resizingObject(h, o); return }
        if let handle = ScreenshotGeometry.hitHandle(p, in: sel) { mode = .resizing(handle, sel); return }
        guard sel.contains(p) else { setSelected(nil); return }
        switch tool {
        case nil:
            if let o = topObject(at: p) {
                let wasSelected = selectedID == o.id
                setSelected(o.id)
                if clickCount >= 2, o.textValue != nil { beginEditText(o); return }
                if wasSelected, o.textValue != nil { reeditCandidate = (o.id, p) }
                pendingBefore = objects; mode = .movingObject(p, o)
            } else { setSelected(nil); mode = .moving(p, sel); NSCursor.closedHand.set() }
        case .eraser?:
            if let o = topObject(at: p) { mutate { $0.removeAll { $0.id == o.id } } }
        case .text?:
            if let o = topObject(at: p), o.textValue != nil { beginEditText(o) } else { beginText(at: p) }
        case .marker?:
            let o = AnnotationObject(shape: .marker(p, nextMarkerNumber), color: style.color, level: style.level)
            mutate { $0.append(o) }
        case .some:
            mode = .drawing(p); penPoints = [p]
            draft = makeDraft(start: p, current: p, shift: shift)
            needsDisplay = true
        }
    }

    private func makeDraft(start: CGPoint, current: CGPoint, shift: Bool) -> AnnotationObject? {
        guard let tool else { return nil }
        let end = shift && [.rectangle, .ellipse].contains(tool) ? ScreenshotConstraint.square(from: start, to: current) : current
        let rect = ScreenshotGeometry.normalized(from: start, to: end)
        var o = AnnotationObject(shape: .rectangle(rect), color: style.color, level: style.level, filled: style.filled, arrowStyle: style.arrowStyle, textStyle: style.textStyle)
        switch tool {
        case .rectangle: o.shape = .rectangle(rect)
        case .ellipse: o.shape = .ellipse(rect)
        case .arrow: o.shape = .line(start, shift ? ScreenshotConstraint.snapAngle(from: start, to: current) : current)
        case .pen: o.shape = .pen(penPoints)
        case .highlighter: o.shape = .highlighter(penPoints)
        case .mosaic: o.shape = .mosaic(rect)
        case .blur: o.shape = .blur(rect)
        case .text, .marker, .eraser: return nil
        }
        return o
    }

    func handleMouseDragged(_ p: CGPoint, shift: Bool = false) {
        guard !locked else { return }
        lastMouse = p
        switch mode {
        case .selecting(let start):
            let clamped = ScreenshotGeometry.clamp(p, to: bounds)
            let end = shift ? ScreenshotGeometry.clamp(ScreenshotConstraint.square(from: start, to: clamped), to: bounds) : clamped
            selection = ScreenshotGeometry.normalized(from: start, to: end)
            hover = nil; needsDisplay = true; onSelectionChanged?(self, false)
        case .moving(let start, let original):
            selection = ScreenshotGeometry.clamp(original.offsetBy(dx: p.x - start.x, dy: p.y - start.y), to: bounds)
            needsDisplay = true; onSelectionChanged?(self, false)
        case .resizing(let handle, let original):
            var r = ScreenshotGeometry.resize(original, handle: handle, to: p, bounds: bounds)
            if shift { r = ScreenshotGeometry.clamp(ScreenshotConstraint.lockAspect(r, original: original, handle: handle), to: bounds) }
            selection = r; needsDisplay = true; onSelectionChanged?(self, false)
        case .movingObject(let start, let original):
            guard let index = objects.firstIndex(where: { $0.id == original.id }) else { return }
            objects[index] = original.translated(by: CGSize(width: p.x - start.x, height: p.y - start.y)); changed()
        case .resizingObject(let handle, let original):
            guard let index = objects.firstIndex(where: { $0.id == original.id }) else { return }
            switch handle {
            case .rect(let h):
                guard let r = original.resizableRect else { return }
                var next = ScreenshotGeometry.resize(r, handle: h, to: p, bounds: bounds)
                if shift { next = ScreenshotConstraint.lockAspect(next, original: r, handle: h) }
                objects[index] = original.withRect(next)
            case .endpoint(let i):
                var target = p
                if shift, let (a, b) = original.endpoints { target = ScreenshotConstraint.snapAngle(from: i == 0 ? b : a, to: p) }
                objects[index] = original.withEndpoint(i, target)
            }
            changed()
        case .drawing(let start):
            guard let sel = selection, let tool else { return }
            let q = ScreenshotGeometry.clamp(p, to: sel)
            if tool == .pen || tool == .highlighter {
                if let last = penPoints.last, hypot(q.x - last.x, q.y - last.y) < 1 { return }
                penPoints.append(q)
            }
            draft = makeDraft(start: start, current: q, shift: shift); needsDisplay = true
        case .picking:
            recognitionToggle(at: p, extendOnly: true)
        case .idle: break
        }
    }

    func handleMouseUp(_ p: CGPoint) {
        guard !locked else { return }
        defer { mode = .idle; updateCursor(at: p) }
        switch mode {
        case .selecting(let start):
            var sel = selection ?? .zero
            if hypot(p.x - start.x, p.y - start.y) < 4, let hover { sel = hover }   // 只点击：选中悬停的窗口
            if sel.width < ScreenshotGeometry.minimumSelection || sel.height < ScreenshotGeometry.minimumSelection { selection = nil; needsDisplay = true; onSelectionChanged?(self, true); return }
            selection = sel; hover = nil; needsDisplay = true; onSelectionChanged?(self, true)
        case .moving, .resizing:
            onSelectionChanged?(self, true)
        case .movingObject, .resizingObject:
            if let before = pendingBefore, before != objects { history.record(before); changed() }
            pendingBefore = nil
            if let c = reeditCandidate, hypot(p.x - c.at.x, p.y - c.at.y) < 3, let o = objects.first(where: { $0.id == c.id }) { reeditCandidate = nil; beginEditText(o) }
        case .drawing:
            if let d = draft, isMeaningful(d) { mutate { $0.append(d) }; setSelected(nil) }
            draft = nil; penPoints = []; needsDisplay = true
        case .picking, .idle: break
        }
    }

    private func isMeaningful(_ o: AnnotationObject) -> Bool {
        switch o.shape {
        case .rectangle(let r), .ellipse(let r), .mosaic(let r), .blur(let r): return r.width >= 3 && r.height >= 3
        case .line(let a, let b): return hypot(a.x - b.x, a.y - b.y) >= 6
        case .pen(let pts), .highlighter(let pts): return !pts.isEmpty
        case .text(let t, _): return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .marker: return true
        }
    }

    // MARK: 键盘

    override func keyDown(with event: NSEvent) {
        if !handleKey(code: event.keyCode, characters: event.charactersIgnoringModifiers ?? "", flags: event.modifierFlags) { super.keyDown(with: event) }
    }

    private static let toolKeys: [String: ScreenshotTool] = ["r": .rectangle, "o": .ellipse, "a": .arrow, "p": .pen, "h": .highlighter, "m": .mosaic, "b": .blur, "t": .text, "n": .marker, "e": .eraser]

    /// 返回是否已处理
    @discardableResult
    func handleKey(code: UInt16, characters: String, flags: NSEvent.ModifierFlags) -> Bool {
        let cmd = flags.contains(.command), shift = flags.contains(.shift), option = flags.contains(.option)
        let key = characters.lowercased()
        if recognition != nil {
            switch code {
            case 53: onKeyCommand?(.exitRecognition); return true
            case 36, 76: onKeyCommand?(.copySelectedText); return true
            default: break
            }
            if cmd && key == "a" { onKeyCommand?(.selectAllText); return true }
            if cmd && key == "c" { onKeyCommand?(.copySelectedText); return true }
            return false
        }
        switch code {
        case 53: onKeyCommand?(.cancel); return true
        case 36, 76: onKeyCommand?(.confirm); return true
        case 51, 117: if selectedID != nil { deleteSelected(); return true }; return false
        case 123, 124, 125, 126:
            guard selection != nil else { return false }
            nudge(code: code, shift: shift, option: option); return true
        default: break
        }
        if cmd {
            switch key {
            case "z": onKeyCommand?(shift ? .redo : .undo); return true
            case "c": onKeyCommand?(.confirm); return true
            case "s": onKeyCommand?(.save); return true
            default: return false
            }
        }
        if selection == nil {
            if shift && code == 56 { return false }
            if key == "c", let text = colorText(at: lastMouse ?? .zero) {
                pasteboard.clearContents(); pasteboard.setString(text, forType: .string)   // 用户按下 C，明确要求复制
                showToast(L10n.format("screenshot.color.copied", text)); return true
            }
            return false
        }
        if let t = Self.toolKeys[key], !flags.contains(.control), !option { onKeyCommand?(.tool(t)); return true }
        return false
    }

    /// 切换取色格式（RGB / HEX），Shift 键触发
    func cycleColorFormat() { colorFormat = colorFormat == 0 ? 1 : 0; onColorFormatChanged?(colorFormat); needsDisplay = true }
    override func flagsChanged(with event: NSEvent) {
        if event.modifierFlags.contains(.shift), selection == nil { cycleColorFormat() }
        super.flagsChanged(with: event)
    }

    /// 上下左右：已选中标注 → 微调标注（1 点，Shift 10 点）；否则微调选区（1 物理像素，Shift 10 像素；⌥ 为改变大小）
    private func nudge(code: UInt16, shift: Bool, option: Bool) {
        let (ux, uy): (CGFloat, CGFloat) = code == 123 ? (-1, 0) : code == 124 ? (1, 0) : code == 125 ? (0, 1) : (0, -1)
        if let o = selectedObject, let index = objects.firstIndex(where: { $0.id == o.id }) {
            let step: CGFloat = shift ? 10 : 1
            mutate { $0[index] = o.translated(by: CGSize(width: ux * step, height: uy * step)) }; return
        }
        guard var sel = selection else { return }
        let step = (shift ? 10 : 1) / display.scale
        if option { sel.size.width += ux * step; sel.size.height += uy * step } else { sel.origin.x += ux * step; sel.origin.y += uy * step }
        if sel.width < ScreenshotGeometry.minimumSelection || sel.height < ScreenshotGeometry.minimumSelection { return }
        selection = ScreenshotGeometry.clamp(sel, to: bounds); needsDisplay = true
        onSelectionChanged?(self, true)
    }

    // MARK: 文字标注

    private func beginText(at p: CGPoint) { setSelected(nil); startEditor(at: p, text: "", editing: nil) }
    private func beginEditText(_ o: AnnotationObject) {
        guard case .text(let s, let origin) = o.shape else { return }
        setSelected(o.id)      // 编辑期间换颜色 / 样式，作用在这段文字上
        startEditor(at: origin, text: s, editing: o)
    }

    private func startEditor(at p: CGPoint, text: String, editing: AnnotationObject?) {
        guard let sel = selection else { return }
        let fontSize = ScreenshotMetrics.fontSizes[ScreenshotMetrics.clamp(editing?.level ?? style.level)]
        let height = fontSize * 1.5
        let field = NSTextField(frame: NSRect(x: p.x - 2, y: p.y - (height - fontSize * 1.2) / 2, width: min(320, max(120, sel.maxX - p.x)), height: height))
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize, weight: .medium)
        field.textColor = NSColor(cgColor: (editing?.color ?? style.color).cgColor)
        field.stringValue = text
        field.placeholderString = L10n.tr("screenshot.text.placeholder")
        field.delegate = self
        addSubview(field); window?.makeFirstResponder(field)
        editor = field; editorOrigin = p; editingID = editing?.id; needsDisplay = true
    }

    func commitEditor(cancel: Bool = false) {
        guard let field = editor else { return }
        editor = nil
        let text = field.stringValue, id = editingID
        editingID = nil
        field.delegate = nil; field.removeFromSuperview()
        window?.makeFirstResponder(self)
        defer { needsDisplay = true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id, let index = objects.firstIndex(where: { $0.id == id }) {
            guard !cancel else { return }
            if trimmed.isEmpty { mutate { $0.removeAll { $0.id == id } }; setSelected(nil); return }
            var updated = objects[index]; updated.shape = .text(text, editorOrigin)
            if updated != objects[index] { mutate { $0[index] = updated } }
            return
        }
        guard !cancel, !trimmed.isEmpty else { return }
        let o = AnnotationObject(shape: .text(text, editorOrigin), color: style.color, level: style.level, textStyle: style.textStyle)
        mutate { $0.append(o) }
        setSelected(o.id)      // 写完保持选中：随后点颜色 / 样式会作用在它上面，再点一次可重新编辑
    }

    /// 正在输入时换颜色或字号：输入框同步变化，所见即所得
    private func restyleEditor() {
        guard let field = editor else { return }
        let size = ScreenshotMetrics.fontSizes[ScreenshotMetrics.clamp(style.level)]
        field.textColor = NSColor(cgColor: style.color.cgColor)
        field.font = .systemFont(ofSize: size, weight: .medium)
        field.frame.size.height = size * 1.5
    }
    var isEditingText: Bool { editor != nil }
    var editorTextColorForTest: NSColor? { editor?.textColor }

    /// 自检专用：模拟在文字框里输入并提交
    func testTypeText(_ text: String, at p: CGPoint) {
        handleMouseDown(p)
        editor?.stringValue = text
        commitEditor()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { commitEditor(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { commitEditor(cancel: true); return true }
        return false
    }
    func controlTextDidEndEditing(_ notification: Notification) { commitEditor() }

    // MARK: 识别结果叠加层（像 Live Text 一样逐块选择复制）

    /// 把 OCR 行（归一化坐标，原点在左下）映射到画布上；没有位置信息的行会被忽略
    func showRecognition(_ lines: [OCRLine]) {
        guard let sel = selection else { return }
        recognition = lines.filter { $0.box.width > 0 && $0.box.height > 0 }.map { line in
            RecognizedBox(rect: CGRect(x: sel.minX + line.box.minX * sel.width, y: sel.minY + (1 - line.box.maxY) * sel.height, width: line.box.width * sel.width, height: line.box.height * sel.height), text: line.text)
        }
        setSelected(nil); mode = .idle; needsDisplay = true
    }
    func hideRecognition() { recognition = nil; needsDisplay = true }
    var recognitionActive: Bool { recognition != nil }
    var recognizedCount: Int { recognition?.count ?? 0 }

    func selectAllRecognized(_ on: Bool = true) { guard recognition != nil else { return }; for i in recognition!.indices { recognition![i].selected = on }; needsDisplay = true }
    /// 已选的文字块（按阅读顺序）；一块也没选则返回全部
    func recognizedText(onlySelected: Bool = true) -> String {
        guard let boxes = recognition else { return "" }
        let chosen = boxes.filter(\.selected)
        return (onlySelected && !chosen.isEmpty ? chosen : boxes).map(\.text).joined(separator: "\n")
    }
    var selectedRecognizedCount: Int { recognition?.filter(\.selected).count ?? 0 }

    private func recognitionToggle(at p: CGPoint, extendOnly: Bool = false) {
        guard var boxes = recognition, let index = boxes.firstIndex(where: { $0.rect.insetBy(dx: -3, dy: -2).contains(p) }) else { return }
        if extendOnly { boxes[index].selected = true } else { boxes[index].selected.toggle() }
        recognition = boxes; needsDisplay = true
    }
}
