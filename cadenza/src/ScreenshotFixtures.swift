import AppKit
import Carbon.HIToolbox
import SwiftUI
import CoreImage

// 截图自检：几何与像素级渲染使用构造图片；OCR 使用真实的 Apple Vision 识别程序自己渲染出来的文字；
// 云端 OCR 使用假的传输层，只检查请求格式与应答解析，不联网；不抓取屏幕、不打开窗口、不使用麦克风。
enum ScreenshotFixtures {
    // MARK: 工具

    static func bitmapContext(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// 画一张测试底图（像素尺寸 w×h）：左半蓝、右半绿，左上角有 20×20 的红块（用来检验上下方向没有翻转）
    static func baseImage(_ w: Int, _ h: Int) -> CGImage {
        let ctx = ScreenshotFixtures.bitmapContext(w, h)
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)); ctx.fill(CGRect(x: w / 2, y: 0, width: w - w / 2, height: h))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: h - 20, width: 20, height: 20))   // CG 是 y 向上：这是左上角
        return ctx.makeImage()!
    }

    /// 黑白逐像素交替的棋盘，用来验证马赛克确实把细节抹平
    static func checkerImage(_ w: Int, _ h: Int) -> CGImage {
        let ctx = ScreenshotFixtures.bitmapContext(w, h)
        for y in 0..<h { for x in 0..<w { ctx.setFillColor(CGColor(gray: (x + y) % 2 == 0 ? 0 : 1, alpha: 1)); ctx.fill(CGRect(x: x, y: y, width: 1, height: 1)) } }
        return ctx.makeImage()!
    }

    /// 水平渐变（灰度随 x 增加）：用来测量马赛克色块的宽度
    static func rampImage(_ w: Int, _ h: Int) -> CGImage {
        let ctx = ScreenshotFixtures.bitmapContext(w, h)
        for x in 0..<w { ctx.setFillColor(CGColor(gray: CGFloat(x) / CGFloat(w - 1), alpha: 1)); ctx.fill(CGRect(x: x, y: 0, width: 1, height: h)) }
        return ctx.makeImage()!
    }

    /// 左半黑、右半白：用来验证模糊在分界线上产生渐变
    static func splitImage(_ w: Int, _ h: Int) -> CGImage {
        let ctx = ScreenshotFixtures.bitmapContext(w, h)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: w / 2, y: 0, width: w - w / 2, height: h))
        return ctx.makeImage()!
    }

    struct RGB: Equatable { var r: Int, g: Int, b: Int }
    /// 取像素（x、y 从图片左上角起算）
    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> RGB? {
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        let ctx = bitmapContext(image.width, image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = ctx.data else { return nil }
        let p = data.assumingMemoryBound(to: UInt8.self) + (y * ctx.bytesPerRow + x * 4)     // 行 0 即顶行
        return RGB(r: Int(p[0]), g: Int(p[1]), b: Int(p[2]))
    }
    static func isRed(_ c: RGB?) -> Bool { c.map { $0.r > 200 && $0.g < 80 && $0.b < 80 } ?? false }
    static func isBlue(_ c: RGB?) -> Bool { c.map { $0.b > 200 && $0.r < 60 && $0.g < 60 } ?? false }
    static func isGreen(_ c: RGB?) -> Bool { c.map { $0.g > 200 && $0.r < 60 && $0.b < 60 } ?? false }
    static func isDark(_ c: RGB?) -> Bool { c.map { $0.r < 60 && $0.g < 60 && $0.b < 60 } ?? false }
    static func isLight(_ c: RGB?) -> Bool { c.map { $0.r > 195 && $0.g > 195 && $0.b > 195 } ?? false }

    /// 同步等待异步任务（自检在主线程运行，期间继续处理主线程队列）
    static func waitFor<T>(_ timeout: TimeInterval = 20, _ body: @escaping () async throws -> T) -> Result<T, Error>? {
        var result: Result<T, Error>?
        Task {
            let r: Result<T, Error>
            do { r = .success(try await body()) } catch { r = .failure(error) }
            DispatchQueue.main.async { result = r }
        }
        let end = Date().addingTimeInterval(timeout)
        while result == nil && Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        return result
    }

    /// 把一行文字渲染成白底黑字图片，交给真实的 Vision 识别
    static func textImage(_ text: String, size: CGFloat = 54) -> CGImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black]
        let measured = (text as NSString).size(withAttributes: attributes)
        let ctx = bitmapContext(Int(measured.width) + 60, Int(measured.height) + 40)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (text as NSString).draw(at: CGPoint(x: 30, y: 20), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    /// 生成二维码图片（CoreImage），四周留白
    static func qrImage(_ payload: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage"); filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let code = CIContext().createCGImage(out, from: out.extent) else { return nil }
        let ctx = bitmapContext(code.width + 80, code.height + 80)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.interpolationQuality = .none
        ctx.draw(code, in: CGRect(x: 40, y: 40, width: code.width, height: code.height))
        return ctx.makeImage()
    }

    // MARK: 入口

    static func run(_ check: (String, Bool) -> Void) {
        func c(_ name: String, _ ok: Bool) { check("Screenshot " + name, ok) }
        geometry(c); objects(c); colors(c); renderer(c); canvas(c); ocrCore(c); providers(c); router(c); ocrPage(c); pins(c); outputs(c); settings(c); icons(c)
    }

    // MARK: 选区几何

    static func geometry(_ c: (String, Bool) -> Void) {
        typealias G = ScreenshotGeometry
        c("反向拖动得到规范化矩形", G.normalized(from: CGPoint(x: 50, y: 40), to: CGPoint(x: 10, y: 5)) == CGRect(x: 10, y: 5, width: 40, height: 35))
        let screen = CGRect(x: 0, y: 0, width: 400, height: 300)
        c("移动选区不出屏幕且保持大小", G.clamp(CGRect(x: 380, y: -20, width: 100, height: 50), to: screen) == CGRect(x: 300, y: 0, width: 100, height: 50))
        let sel = CGRect(x: 100, y: 100, width: 100, height: 80)
        c("命中角点与边中点", G.hitHandle(CGPoint(x: 101, y: 99), in: sel) == .topLeft && G.hitHandle(CGPoint(x: 150, y: 181), in: sel) == .bottom && G.hitHandle(CGPoint(x: 150, y: 140), in: sel) == nil)
        c("选区很小时只保留角点手柄", G.hitHandle(CGPoint(x: 110, y: 100), in: CGRect(x: 100, y: 100, width: 20, height: 20)) == nil)
        c("拖动右下角手柄放大", G.resize(sel, handle: .bottomRight, to: CGPoint(x: 260, y: 220), bounds: screen) == CGRect(x: 100, y: 100, width: 160, height: 120))
        c("拖过对边会翻转而不是负尺寸", G.resize(sel, handle: .topLeft, to: CGPoint(x: 250, y: 250), bounds: screen).width >= G.minimumSelection && G.resize(sel, handle: .topLeft, to: CGPoint(x: 250, y: 250), bounds: screen).minX >= 200)
        c("拖动手柄不会超出屏幕", G.resize(sel, handle: .right, to: CGPoint(x: 999, y: 140), bounds: screen).maxX == 400)
        let bar = CGSize(width: 360, height: 42)
        let below = G.toolbarFrame(selection: sel, size: bar, bounds: screen)
        c("操作条优先放在选区下方（间距 8），放不下时靠屏幕左边", below.minY == 188 && below.minX == 8)
        let wide = G.toolbarFrame(selection: CGRect(x: 40, y: 100, width: 340, height: 50), size: CGSize(width: 300, height: 42), bounds: screen)
        c("操作条右边缘与选区右边缘对齐", wide.maxX == 380 && wide.minY == 158)
        c("下方放不下时放到上方", G.toolbarFrame(selection: CGRect(x: 100, y: 230, width: 100, height: 60), size: bar, bounds: screen).maxY <= 230)
        let inside = G.toolbarFrame(selection: CGRect(x: 0, y: 0, width: 400, height: 300), size: bar, bounds: screen)
        c("整屏选区时操作条放在选区内且不出屏幕", screen.contains(inside))
        c("悬停窗口取最上层", G.window(at: CGPoint(x: 50, y: 50), in: [CGRect(x: 40, y: 40, width: 30, height: 30), CGRect(x: 0, y: 0, width: 300, height: 300)]) == CGRect(x: 40, y: 40, width: 30, height: 30) && G.window(at: CGPoint(x: 500, y: 500), in: [CGRect(x: 0, y: 0, width: 10, height: 10)]) == nil)
        let snapped = G.snapped(CGRect(x: 10.25, y: 5.25, width: 20.5, height: 10.5), scale: 2)
        c("选区对齐到物理像素网格", snapped == CGRect(x: 10, y: 5, width: 21, height: 11) && G.pixelSize(of: snapped, scale: 2) == (42, 22))
        let palette = CGSize(width: 104, height: 200)
        let left = G.paletteFrame(selection: CGRect(x: 200, y: 60, width: 150, height: 120), size: palette, bounds: screen)
        c("标注工具条优先贴在选区左侧外面，顶端与选区对齐", left.maxX <= 204 && left.minY == 60 && left.minX >= 0)
        c("左侧放不下时贴在右侧", { let r = G.paletteFrame(selection: CGRect(x: 10, y: 20, width: 150, height: 120), size: palette, bounds: screen); return r.minX >= 156 && screen.contains(r) }())
        c("两侧都放不下时放在选区内部左缘", { let r = G.paletteFrame(selection: CGRect(x: 10, y: 20, width: 380, height: 260), size: palette, bounds: screen); return r.minX >= 10 && screen.contains(r) }())
        c("工具条不会超出屏幕下沿", screen.contains(G.paletteFrame(selection: CGRect(x: 200, y: 250, width: 150, height: 40), size: palette, bounds: screen)))
        let barRect = CGRect(x: 100, y: 100, width: 200, height: 50)
        c("工具条与操作条重叠时让到操作条上方", !G.paletteFrame(selection: CGRect(x: 120, y: 110, width: 160, height: 30), size: CGSize(width: 66, height: 60), bounds: screen, avoiding: barRect).intersects(barRect))
        // Shift 约束
        let start = CGPoint(x: 10, y: 10)
        c("Shift：拖成正方形（取较长边，保持方向）", ScreenshotConstraint.square(from: start, to: CGPoint(x: 70, y: 40)) == CGPoint(x: 70, y: 70) && ScreenshotConstraint.square(from: start, to: CGPoint(x: -20, y: 5)) == CGPoint(x: -20, y: -20))
        let snappedEnd = ScreenshotConstraint.snapAngle(from: .zero, to: CGPoint(x: 100, y: 12))
        c("Shift：直线吸附到 45° 的整数倍", abs(snappedEnd.y) < 0.001 && snappedEnd.x > 99 && { let d = ScreenshotConstraint.snapAngle(from: .zero, to: CGPoint(x: 50, y: 52)); return abs(d.x - d.y) < 0.001 }())
        let locked = ScreenshotConstraint.lockAspect(CGRect(x: 100, y: 100, width: 150, height: 90), original: CGRect(x: 100, y: 100, width: 100, height: 50), handle: .bottomRight)
        c("Shift：缩放选区时锁定宽高比", abs(locked.width / locked.height - 2) < 0.001 && locked.minX == 100 && locked.minY == 100)
        let lockedTL = ScreenshotConstraint.lockAspect(CGRect(x: 60, y: 80, width: 140, height: 70), original: CGRect(x: 100, y: 100, width: 100, height: 50), handle: .topLeft)
        c("Shift：从左上角缩放时右下角固定", abs(lockedTL.maxX - 200) < 0.001 && abs(lockedTL.maxY - 150) < 0.001 && abs(lockedTL.width / lockedTL.height - 2) < 0.001)
    }

    // MARK: 标注对象：命中、编辑、历史

    static func obj(_ shape: AnnotationObject.Shape, _ color: ScreenshotColor = .red, level: Int = 1, filled: Bool = false, arrow: ArrowStyle = .single, text: TextStyle = .plain) -> AnnotationObject {
        AnnotationObject(shape: shape, color: color, level: level, filled: filled, arrowStyle: arrow, textStyle: text)
    }

    static func objects(_ c: (String, Bool) -> Void) {
        let rect = obj(.rectangle(CGRect(x: 10, y: 10, width: 80, height: 50)))
        c("命中：空心矩形只在边线附近命中，内部不命中", rect.hit(CGPoint(x: 10, y: 30)) && rect.hit(CGPoint(x: 50, y: 10)) && !rect.hit(CGPoint(x: 50, y: 35)) && !rect.hit(CGPoint(x: 200, y: 200)))
        c("命中：实心矩形内部命中", obj(.rectangle(CGRect(x: 10, y: 10, width: 80, height: 50)), filled: true).hit(CGPoint(x: 50, y: 35)))
        let ellipse = obj(.ellipse(CGRect(x: 0, y: 0, width: 100, height: 60)))
        c("命中：椭圆在边上命中，中心与外部不命中", ellipse.hit(CGPoint(x: 0, y: 30)) && ellipse.hit(CGPoint(x: 50, y: 0)) && !ellipse.hit(CGPoint(x: 50, y: 30)) && !ellipse.hit(CGPoint(x: 120, y: 30)))
        let line = obj(.line(CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)))
        c("命中：直线按到线段的距离", line.hit(CGPoint(x: 50, y: 4)) && !line.hit(CGPoint(x: 50, y: 20)) && !line.hit(CGPoint(x: 140, y: 0)))
        c("命中：画笔按到折线的距离", obj(.pen([CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 50)])).hit(CGPoint(x: 52, y: 25)) && !obj(.pen([CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0)])).hit(CGPoint(x: 25, y: 30)))
        c("命中：荧光笔较宽", obj(.highlighter([CGPoint(x: 0, y: 0), CGPoint(x: 80, y: 0)])).hit(CGPoint(x: 40, y: 8)))
        c("命中：马赛克与模糊按区域", obj(.mosaic(CGRect(x: 0, y: 0, width: 40, height: 40))).hit(CGPoint(x: 20, y: 20)) && obj(.blur(CGRect(x: 0, y: 0, width: 40, height: 40))).hit(CGPoint(x: 39, y: 39)) && !obj(.blur(CGRect(x: 0, y: 0, width: 40, height: 40))).hit(CGPoint(x: 80, y: 20)))
        let text = obj(.text("Hello", CGPoint(x: 20, y: 20)))
        c("命中：文字按文字块范围", text.hit(CGPoint(x: 30, y: 30)) && !text.hit(CGPoint(x: 400, y: 30)) && text.bounds.width > 20)
        c("命中：序号标记按圆", obj(.marker(CGPoint(x: 50, y: 50), 1)).hit(CGPoint(x: 55, y: 50)) && !obj(.marker(CGPoint(x: 50, y: 50), 1)).hit(CGPoint(x: 90, y: 50)))
        c("平移：矩形/直线/画笔/文字/标记都随之移动", {
            let d = CGSize(width: 10, height: -5)
            return rect.translated(by: d).resizableRect == CGRect(x: 20, y: 5, width: 80, height: 50)
                && line.translated(by: d).endpoints.map { $0.0 == CGPoint(x: 10, y: -5) && $0.1 == CGPoint(x: 110, y: -5) } == true
                && obj(.pen([CGPoint(x: 1, y: 1)])).translated(by: d).bounds.midX > 5
                && text.translated(by: d).bounds.minX == text.bounds.minX + 10
                && obj(.marker(CGPoint(x: 5, y: 5), 3)).translated(by: d).markerNumber == 3
        }())
        c("缩放：withRect 换矩形，withEndpoint 换端点", rect.withRect(CGRect(x: 0, y: 0, width: 5, height: 5)).resizableRect == CGRect(x: 0, y: 0, width: 5, height: 5) && line.withEndpoint(1, CGPoint(x: 9, y: 9)).endpoints?.1 == CGPoint(x: 9, y: 9) && line.withEndpoint(0, CGPoint(x: 3, y: 3)).endpoints?.0 == CGPoint(x: 3, y: 3))
        c("缩放：文字、标记没有矩形手柄", text.resizableRect == nil && obj(.marker(.zero, 1)).resizableRect == nil && obj(.pen([.zero])).resizableRect == nil)
        c("颜色：马赛克与模糊不使用颜色", !obj(.mosaic(.zero)).usesColor && !obj(.blur(.zero)).usesColor && rect.usesColor)
        c("颜色对比：浅色配深色、深色配浅色", ScreenshotColor.yellow.contrast == .black && ScreenshotColor.white.contrast == .black && ScreenshotColor.black.contrast == .white && ScreenshotColor.blue.contrast == .white)
        c("档位：粗细/字号/半径随档位增大且越界被夹住", ScreenshotMetrics.strokeWidths == ScreenshotMetrics.strokeWidths.sorted() && obj(.rectangle(.zero), level: 9).stroke == 7 && obj(.rectangle(.zero), level: -3).stroke == 2 && obj(.text("x", .zero), level: 2).fontSize == 32 && obj(.marker(.zero, 1), level: 0).markerRadius == 10)
        c("工具能力：每种工具只显示相关选项", ScreenshotTool.rectangle.usesFill && !ScreenshotTool.pen.usesFill && ScreenshotTool.arrow.usesArrowStyle && ScreenshotTool.text.usesTextStyle && !ScreenshotTool.eraser.usesLevel && !ScreenshotTool.mosaic.usesColor && ScreenshotTool.highlighter.usesColor)
        // 历史
        var history = AnnotationHistory()
        let a = [rect], b = [rect, line], d = [rect, line, text]
        history.record([])         // 加入 a 之前的状态
        history.record(a)          // 加入 b 之前的状态
        c("历史：可撤销、不可重做", history.canUndo && !history.canRedo)
        c("历史：撤销回到上一个状态并产生可重做", history.undo(current: b) == a && history.canRedo)
        c("历史：重做回到被撤销的状态", history.redo(current: a) == b)
        history.record(b); _ = history.undo(current: d)
        history.record(a)
        c("历史：新的修改会清掉重做栈", !history.canRedo)
        var many = AnnotationHistory(); for i in 0..<150 { many.record([obj(.marker(.zero, i))]) }
        c("历史：最多保留 100 步", many.undoStack.count == AnnotationHistory.limit)
    }

    // MARK: 颜色与色盘

    static func colors(_ c: (String, Bool) -> Void) {
        c("颜色：十六进制构造与输出一致", ScreenshotColor(hex: 0xFF8000).hex == "#FF8000" && ScreenshotColor(hex: 0x0A84FF).hex == "#0A84FF" && ScreenshotColor.white.hex == "#FFFFFF" && ScreenshotColor.black.hex == "#1C1C1E")
        c("颜色：常用色 8 个，且都不重复", ScreenshotColor.palette.count == 8 && Set(ScreenshotColor.palette.map(\.hex)).count == 8)
        c("颜色：色块里黑、白都有，白色不会被当成深色", ScreenshotColor.palette.contains(.black) && ScreenshotColor.palette.contains(.white) && ScreenshotColor.white.luminance > 0.9 && ScreenshotColor.black.luminance < 0.2)
        c("颜色：提亮后仍在 0…1 范围内且更亮", ScreenshotColor.palette.allSatisfy { let l = $0.lighter(0.22); return [l.r, l.g, l.b].allSatisfy { (0...1).contains($0) } && l.luminance >= $0.luminance })
        let m = ScreenshotToolbarModel()
        var styleCalls = 0
        m.onStyleChanged = { styleCalls += 1 }
        m.chooseColor(.blue)
        c("色块模型：选色更新样式并通知一次", m.style.color == .blue && styleCalls == 1)
        m.chooseColor(.white)
        c("色块模型：可以连续换色", m.style.color == .white && styleCalls == 2)
    }

    // MARK: 渲染（像素级）

    static func renderer(_ c: (String, Bool) -> Void) {
        let base = baseImage(200, 100)          // 缩放 2：100×50 点
        func render(_ selection: CGRect, _ objects: [AnnotationObject] = [], image: CGImage? = nil) -> CGImage? {
            let source = image ?? base
            return ScreenshotRenderer.render(display: source, effects: ScreenshotEffects(image: source, scale: 2), selection: selection, scale: 2, objects: objects)
        }
        let whole = CGRect(x: 0, y: 0, width: 100, height: 50)
        let full = render(whole)
        c("整屏导出尺寸等于物理像素", full.map { $0.width == 200 && $0.height == 100 } == true)
        c("导出不翻转：红块在左上角", isRed(full.flatMap { pixel($0, 5, 5) }) && !isRed(full.flatMap { pixel($0, 5, 95) }))
        c("导出左蓝右绿", isBlue(full.flatMap { pixel($0, 70, 50) }) && isGreen(full.flatMap { pixel($0, 130, 50) }))
        let cropped = render(CGRect(x: 50, y: 0, width: 50, height: 25))
        c("裁剪只保留选区（右半绿色）", cropped.map { $0.width == 100 && $0.height == 50 } == true && isGreen(cropped.flatMap { pixel($0, 0, 0) }) && isGreen(cropped.flatMap { pixel($0, 99, 49) }))
        c("非整数选区按像素网格导出", render(CGRect(x: 10.25, y: 5.25, width: 20.5, height: 10.5)).map { $0.width == 42 && $0.height == 22 } == true)

        let rect = obj(.rectangle(CGRect(x: 10, y: 10, width: 40, height: 20)))
        let withRect = render(whole, [rect])
        c("矩形：边线着色、内部保持原样", isRed(withRect.flatMap { pixel($0, 60, 20) }) && isBlue(withRect.flatMap { pixel($0, 60, 40) }))
        c("实心矩形：内部也着色", isRed(render(whole, [obj(.rectangle(CGRect(x: 10, y: 10, width: 40, height: 20)), filled: true)]).flatMap { pixel($0, 60, 40) }))
        let ring = render(whole, [obj(.ellipse(CGRect(x: 10, y: 5, width: 60, height: 40)))])
        c("椭圆：最左点着色、中心不变", isRed(ring.flatMap { pixel($0, 20, 50) }) && !isRed(ring.flatMap { pixel($0, 80, 50) }))
        c("实心椭圆：中心着色", isRed(render(whole, [obj(.ellipse(CGRect(x: 10, y: 5, width: 60, height: 40)), filled: true)]).flatMap { pixel($0, 80, 50) }))
        let single = render(whole, [obj(.line(CGPoint(x: 10, y: 25), CGPoint(x: 90, y: 25)))])
        c("箭头：杆与终点箭头都着色", isRed(single.flatMap { pixel($0, 60, 50) }) && isRed(single.flatMap { pixel($0, 176, 50) }))
        let double = render(whole, [obj(.line(CGPoint(x: 20, y: 25), CGPoint(x: 90, y: 25)), arrow: .double)])
        c("双向箭头：两端都有箭头头部（头部比杆更宽）", isRed(double.flatMap { pixel($0, 60, 44) }) && isRed(double.flatMap { pixel($0, 164, 44) }))
        let plain = render(whole, [obj(.line(CGPoint(x: 20, y: 25), CGPoint(x: 90, y: 25)), arrow: .line)])
        c("直线：杆着色但没有箭头头部", isRed(plain.flatMap { pixel($0, 100, 50) }) && !isRed(plain.flatMap { pixel($0, 164, 44) }) && !isRed(plain.flatMap { pixel($0, 60, 44) }))
        let pen = render(whole, [obj(.pen([CGPoint(x: 10, y: 40), CGPoint(x: 30, y: 40), CGPoint(x: 30, y: 20)]))])
        c("画笔：折线经过的位置着色", isRed(pen.flatMap { pixel($0, 40, 80) }) && isRed(pen.flatMap { pixel($0, 60, 60) }))
        // 荧光笔：正片叠底，压在深色上仍然看得见底色（不是不透明涂块）
        let marker = render(whole, [obj(.highlighter([CGPoint(x: 10, y: 25), CGPoint(x: 90, y: 25)]), .yellow)])
        let hl = marker.flatMap { pixel($0, 60, 50) }
        c("荧光笔：半透明正片叠底，蓝底上变暗而不是被盖住", hl.map { $0.b < 160 && $0.b > 20 } == true && !isBlue(hl))
        c("荧光笔：笔迹外不受影响", isBlue(marker.flatMap { pixel($0, 60, 5) }))
        // 文字
        func redCount(_ image: CGImage?, _ xs: Range<Int>, _ ys: Range<Int>) -> Int { guard let image else { return 0 }; var n = 0; for y in ys { for x in xs where isRed(pixel(image, x, y)) { n += 1 } }; return n }
        let text = render(whole, [obj(.text("Hi", CGPoint(x: 55, y: 5)))])
        c("文字：目标位置出现着色像素", redCount(text, 108..<170, 8..<48) > 25)
        let filledText = render(whole, [obj(.text("Hi", CGPoint(x: 55, y: 5)), .red, text: .filled)])
        c("文字加底色：文字周围出现反差底色", isLight(filledText.flatMap { pixel($0, 106, 12) }))
        let outlinedText = render(whole, [obj(.text("Hi", CGPoint(x: 55, y: 5)), .red, level: 2, text: .outlined)])
        c("文字描边：出现反差描边像素", { guard let o = outlinedText else { return false }; var n = 0; for y in 8..<60 { for x in 108..<180 where isLight(pixel(o, x, y)) { n += 1 } }; return n > 10 }())
        // 序号标记
        let badge = render(whole, [obj(.marker(CGPoint(x: 50, y: 25), 3), level: 2)])
        c("序号标记：圆底着色，圆内有反差色数字", isRed(badge.flatMap { pixel($0, 70, 50) }) && { guard let b = badge else { return false }; var n = 0; for y in 36..<64 { for x in 88..<112 where isLight(pixel(b, x, y)) { n += 1 } }; return n > 6 }())
        // 锚定
        let shifted = render(CGRect(x: 5, y: 5, width: 90, height: 40), [rect])
        c("标注锚定在画面上：选区偏移后标注随画面一起偏移", isRed(shifted.flatMap { pixel($0, 50, 10) }) && isBlue(shifted.flatMap { pixel($0, 60, 20) }) && isRed(withRect.flatMap { pixel($0, 60, 20) }))
        c("没有标注时与原图一致", isBlue(render(whole).flatMap { pixel($0, 60, 40) }))
        c("标注按添加顺序叠放（后加的在上面）", render(whole, [obj(.rectangle(CGRect(x: 0, y: 0, width: 100, height: 50)), .red, filled: true), obj(.rectangle(CGRect(x: 0, y: 0, width: 100, height: 50)), .blue, filled: true)]).flatMap { pixel($0, 100, 50) }.map { $0.b > 200 && $0.r < 80 } == true)

        // 马赛克
        let checker = checkerImage(240, 120), checkerFX = ScreenshotEffects(image: checker, scale: 2)
        func flat(_ level: Int) -> CGImage? { ScreenshotRenderer.render(display: checker, effects: checkerFX, selection: CGRect(x: 0, y: 0, width: 120, height: 60), scale: 2, objects: [obj(.mosaic(CGRect(x: 10, y: 10, width: 60, height: 30)), level: level)]) }
        func gray(_ image: CGImage?, _ x: Int, _ y: Int) -> Int? { image.flatMap { pixel($0, x, y) }.map { $0.r } }
        let original = ScreenshotRenderer.render(display: checker, effects: nil, selection: CGRect(x: 0, y: 0, width: 120, height: 60), scale: 2, objects: [])
        let m1 = flat(1)
        c("马赛克区域内相邻像素被抹平", gray(m1, 50, 50) == gray(m1, 51, 50) && gray(original, 50, 50) != gray(original, 51, 50))
        c("马赛克区域外保持原样", gray(m1, 5, 5) == gray(original, 5, 5) && gray(m1, 6, 5) == gray(original, 6, 5))
        let ramp = rampImage(240, 120), rampFX = ScreenshotEffects(image: ramp, scale: 2)
        func longestRun(_ level: Int) -> Int {
            guard let m = ScreenshotRenderer.render(display: ramp, effects: rampFX, selection: CGRect(x: 0, y: 0, width: 120, height: 60), scale: 2, objects: [obj(.mosaic(CGRect(x: 10, y: 10, width: 100, height: 30)), level: level)]) else { return 0 }
            var run = 1, best = 1, last = gray(m, 24, 50)
            for x in 25..<216 { let g = gray(m, x, 50); if g == last { run += 1; best = max(best, run) } else { run = 1; last = g } }
            return best
        }
        let runs = (longestRun(0), longestRun(1), longestRun(2))
        c("马赛克强度档位：色块宽度随档位变大（12 / 20 / 32 像素）", runs.0 >= 10 && runs.0 <= 14 && runs.1 >= 18 && runs.1 <= 22 && runs.2 >= 30 && runs.2 <= 34)
        // 模糊
        let split = splitImage(200, 100), splitFX = ScreenshotEffects(image: split, scale: 2)
        func blurred(_ rect: CGRect, level: Int) -> CGImage? { ScreenshotRenderer.render(display: split, effects: splitFX, selection: whole, scale: 2, objects: [obj(.blur(rect), level: level)]) }
        let b2 = blurred(CGRect(x: 30, y: 10, width: 40, height: 30), level: 2)
        c("高斯模糊：黑白分界线变成渐变", b2.flatMap { pixel($0, 100, 50) }.map { $0.r > 60 && $0.r < 200 } == true)
        c("高斯模糊：区域外保持锐利", isDark(b2.flatMap { pixel($0, 98, 5) }) && isLight(b2.flatMap { pixel($0, 102, 5) }))
        func spread(_ level: Int) -> Int {
            guard let img = blurred(CGRect(x: 0, y: 0, width: 100, height: 50), level: level) else { return 0 }
            var n = 0; for x in 60..<140 { if let g = pixel(img, x, 50)?.r, g > 20, g < 235 { n += 1 } }; return n
        }
        c("高斯模糊：强度档位越高越模糊", spread(0) < spread(1) && spread(1) < spread(2))
        c("模糊不吃边缘：图片边缘的白色不会变暗或透明", isLight(blurred(CGRect(x: 80, y: 0, width: 20, height: 20), level: 2).flatMap { pixel($0, 197, 2) }))
    }

    // MARK: 画布交互（直接驱动鼠标/键盘处理逻辑）

    final class CanvasRig {
        let canvas: ScreenshotCanvasView
        var commands: [ScreenshotKeyCommand] = []
        var finishedSelections = 0, selected: [AnnotationObject?] = [], objectChanges = 0
        let board = NSPasteboard(name: NSPasteboard.Name("cadenza-canvas-" + UUID().uuidString))
        init?() {
            guard let screen = NSScreen.main else { return nil }
            let display = CapturedDisplay(screen: screen, image: ScreenshotFixtures.baseImage(Int(screen.frame.width), Int(screen.frame.height)), scale: 1, windows: [CGRect(x: 50, y: 50, width: 300, height: 200)])
            canvas = ScreenshotCanvasView(display: display)
            canvas.pasteboard = board
            canvas.onKeyCommand = { [unowned self] in commands.append($0) }
            canvas.onSelectionChanged = { [unowned self] _, finished in if finished { finishedSelections += 1 } }
            canvas.onObjectSelected = { [unowned self] in selected.append($0) }
            canvas.onObjectsChanged = { [unowned self] in objectChanges += 1 }
        }
        deinit { board.releaseGlobally() }
        func select(_ r: CGRect) { canvas.handleMouseDown(r.origin); canvas.handleMouseDragged(CGPoint(x: r.maxX, y: r.maxY)); canvas.handleMouseUp(CGPoint(x: r.maxX, y: r.maxY)) }
        func drag(_ a: CGPoint, _ b: CGPoint, shift: Bool = false) { canvas.handleMouseDown(a, shift: shift); canvas.handleMouseDragged(b, shift: shift); canvas.handleMouseUp(b) }
        func click(_ p: CGPoint, count: Int = 1) { canvas.handleMouseDown(p, clickCount: count); canvas.handleMouseUp(p) }
    }

    static func canvas(_ c: (String, Bool) -> Void) {
        guard let rig = CanvasRig() else { print("[screenshot-selftest] SKIP: no screen for canvas checks"); return }
        let cv = rig.canvas
        let region = CGRect(x: 100, y: 100, width: 400, height: 300)

        // 选区
        rig.select(region)
        c("画布：鼠标拖出选区并通知", cv.selection == region && rig.finishedSelections >= 1)
        rig.drag(CGPoint(x: 150, y: 150), CGPoint(x: 200, y: 175))
        c("画布：无工具时拖动选区内部可移动选区", cv.selection == region.offsetBy(dx: 50, dy: 25))
        cv.testSetSelection(region)

        // 画矩形
        cv.tool = .rectangle; cv.style = ScreenshotStyle(color: .red, level: 1)
        rig.drag(CGPoint(x: 150, y: 150), CGPoint(x: 250, y: 200))
        c("画布：矩形工具拖出一个矩形标注", cv.objects.count == 1 && cv.objects[0].resizableRect == CGRect(x: 150, y: 150, width: 100, height: 50) && cv.canUndo)
        rig.drag(CGPoint(x: 300, y: 150), CGPoint(x: 400, y: 190), shift: true)
        c("画布：按住 Shift 画出正方形", cv.objects.count == 2 && cv.objects[1].resizableRect.map { abs($0.width - $0.height) < 0.001 && $0.width == 100 } == true)
        cv.undo(); cv.undo()
        c("画布：撤销两次后没有标注，可重做", cv.objects.isEmpty && cv.canRedo)
        cv.redo()
        c("画布：重做恢复一个标注", cv.objects.count == 1)
        rig.drag(CGPoint(x: 160, y: 300), CGPoint(x: 162, y: 301))
        c("画布：过小的拖动不会产生标注", cv.objects.count == 1)

        // 直线 / 箭头（Shift 吸附 45°）
        cv.tool = .arrow; cv.style.arrowStyle = .double
        rig.drag(CGPoint(x: 200, y: 300), CGPoint(x: 300, y: 312), shift: true)
        c("画布：Shift 画箭头吸附到水平线，且使用双向样式", cv.objects.count == 2 && cv.objects[1].endpoints.map { abs($0.1.y - $0.0.y) < 0.001 } == true && cv.objects[1].arrowStyle == .double)

        // 选中、移动、缩放、改样式、删除
        cv.tool = nil
        rig.click(CGPoint(x: 170, y: 150))                  // 矩形上边线（避开中点手柄）
        c("画布：无工具时点击标注会选中它", cv.selectedObject?.resizableRect == CGRect(x: 150, y: 150, width: 100, height: 50) && rig.selected.last??.id == cv.objects[0].id)
        let before = cv.objects[0].resizableRect!
        rig.drag(CGPoint(x: 170, y: 150), CGPoint(x: 190, y: 160))
        c("画布：拖动已选中的标注会移动它", cv.objects[0].resizableRect == before.offsetBy(dx: 20, dy: 10))
        cv.undo()
        c("画布：撤销移动回到原位", cv.objects[0].resizableRect == before)
        cv.handleMouseDown(CGPoint(x: before.maxX, y: before.maxY)); cv.handleMouseDragged(CGPoint(x: before.maxX + 30, y: before.maxY + 30)); cv.handleMouseUp(CGPoint(x: before.maxX + 30, y: before.maxY + 30))
        c("画布：拖动已选中标注的手柄可缩放", cv.objects[0].resizableRect == CGRect(x: before.minX, y: before.minY, width: before.width + 30, height: before.height + 30))
        cv.style.color = .blue; cv.style.level = 2; cv.style.filled = true; cv.applyStyleToSelected()
        c("画布：调色板改样式会同步到选中的标注", cv.objects[0].color == .blue && cv.objects[0].level == 2 && cv.objects[0].filled)
        cv.handleKey(code: 125, characters: "", flags: [])    // ↓
        c("画布：方向键微调选中的标注 1 点", cv.objects[0].resizableRect?.minY == before.minY + 1)
        cv.handleKey(code: 124, characters: "", flags: [.shift]) // Shift+→
        c("画布：Shift+方向键微调 10 点", cv.objects[0].resizableRect?.minX == before.minX + 10)
        let countBefore = cv.objects.count
        cv.handleKey(code: 51, characters: "", flags: [])     // 删除键
        c("画布：删除键删掉选中的标注", cv.objects.count == countBefore - 1 && cv.selectedObject == nil)
        cv.undo()
        c("画布：撤销删除", cv.objects.count == countBefore)

        // 序号标记
        cv.tool = .marker; cv.style = ScreenshotStyle(color: .green, level: 1)
        rig.click(CGPoint(x: 120, y: 380)); rig.click(CGPoint(x: 160, y: 380)); rig.click(CGPoint(x: 200, y: 380))
        c("画布：序号标记依次编号 1 2 3", cv.objects.compactMap(\.markerNumber) == [1, 2, 3])
        cv.tool = .eraser
        rig.click(CGPoint(x: 160, y: 380))
        c("画布：橡皮擦删除点到的标注", cv.objects.compactMap(\.markerNumber) == [1, 3])
        cv.tool = .marker; rig.click(CGPoint(x: 240, y: 380))
        c("画布：删掉中间的标记后新标记取最大号 + 1", cv.objects.compactMap(\.markerNumber).max() == 4)

        // 文字
        cv.tool = .text; cv.style = ScreenshotStyle(color: .red, level: 1, textStyle: .filled)
        cv.testTypeText("备注 note", at: CGPoint(x: 300, y: 250))
        c("画布：文字工具生成文字标注并带上样式", cv.objects.last?.textValue == "备注 note" && cv.objects.last?.textStyle == .filled)
        cv.testTypeText("   ", at: CGPoint(x: 300, y: 330))
        c("画布：只有空格的文字不会生成标注", cv.objects.last?.textValue == "备注 note")
        cv.testTypeText("选中 test", at: CGPoint(x: 300, y: 200))
        let textID = cv.objects.last?.id
        c("文字：写完后保持选中，随后换颜色会作用在它上面", cv.selectedID == textID)
        cv.style.color = .blue; cv.applyStyleToSelected()
        c("文字：写完后点颜色，文字立刻变色", cv.objects.last?.color == .blue)
        rig.click(CGPoint(x: 310, y: 208))
        c("文字：文字工具下再点一下已写好的文字，重新进入编辑", cv.isEditingText && cv.objects.last?.id == textID)
        cv.style.color = .green
        c("文字：输入时换颜色，输入框同步变色", cv.editorTextColorForTest == NSColor(cgColor: ScreenshotColor.green.cgColor))
        cv.commitEditor()
        c("文字：编辑完成后文字内容不变、数量不变", cv.objects.last?.textValue == "选中 test" && cv.objects.filter { $0.textValue != nil }.count == 2)
        cv.tool = nil
        rig.click(CGPoint(x: 310, y: 208), count: 2)
        c("文字：选择工具下双击文字，重新进入编辑", cv.isEditingText)
        cv.commitEditor(cancel: true)
        cv.tool = nil
        rig.click(CGPoint(x: 310, y: 208))
        c("文字：选择工具下，已选中的文字再单击一下就能编辑", cv.isEditingText)
        cv.commitEditor()
        rig.click(CGPoint(x: 600, y: 90))                    // 点空白处取消选中
        rig.click(CGPoint(x: 310, y: 208))
        c("文字：没选中的文字单击只是选中，不会误进入编辑", !cv.isEditingText && cv.selectedID == textID)
        cv.tool = .text

        // 区域微调
        cv.tool = nil
        cv.testSetSelection(region)
        cv.handleKey(code: 124, characters: "", flags: [])    // → 1 物理像素（缩放 1 → 1 点）
        c("画布：方向键微调选区 1 像素", cv.selection == region.offsetBy(dx: 1, dy: 0))
        cv.handleKey(code: 125, characters: "", flags: [.shift])
        c("画布：Shift+方向键微调选区 10 像素", cv.selection == region.offsetBy(dx: 1, dy: 10))
        cv.testSetSelection(region)
        cv.handleKey(code: 124, characters: "", flags: [.option])
        c("画布：⌥+方向键改变选区大小", cv.selection == CGRect(x: 100, y: 100, width: 401, height: 300))

        // 快捷键
        rig.commands.removeAll(); cv.testSetSelection(region)
        cv.handleKey(code: 15, characters: "r", flags: []); cv.handleKey(code: 6, characters: "z", flags: .command); cv.handleKey(code: 6, characters: "z", flags: [.command, .shift])
        cv.handleKey(code: 8, characters: "c", flags: .command); cv.handleKey(code: 1, characters: "s", flags: .command); cv.handleKey(code: 53, characters: "", flags: []); cv.handleKey(code: 36, characters: "", flags: [])
        c("画布：键盘命令（R 工具、⌘Z、⇧⌘Z、⌘C、⌘S、Esc、Return）", rig.commands == [.tool(.rectangle), .undo, .redo, .confirm, .save, .cancel, .confirm])
        rig.commands.removeAll()
        for key in ["o", "a", "p", "h", "m", "b", "t", "n", "e"] { cv.handleKey(code: 0, characters: key, flags: []) }
        c("画布：每个工具都有字母快捷键", rig.commands == [.tool(.ellipse), .tool(.arrow), .tool(.pen), .tool(.highlighter), .tool(.mosaic), .tool(.blur), .tool(.text), .tool(.marker), .tool(.eraser)])

        // 导出：不含标注的原图
        cv.tool = nil; cv.testSetSelection(CGRect(x: 0, y: 0, width: 60, height: 40))
        c("画布：OCR 用的原图不含标注（左上角仍是底图的红块）", cv.cleanImage().map { isRed(pixel($0, 5, 5)) } == true)

        // 识别叠加层
        rig.commands.removeAll()
        cv.testSetSelection(CGRect(x: 100, y: 100, width: 200, height: 100))
        cv.showRecognition([OCRLine(text: "第一行", box: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.2)), OCRLine(text: "second", box: CGRect(x: 0.1, y: 0.3, width: 0.5, height: 0.2)), OCRLine(text: "无位置", box: .zero)])
        c("识别叠加：只显示有位置信息的行", cv.recognitionActive && cv.recognizedCount == 2)
        c("识别叠加：未选择时复制全部（按阅读顺序）", cv.recognizedText() == "第一行\nsecond")
        rig.click(CGPoint(x: 160, y: 120))                  // 第一行的位置
        c("识别叠加：点击切换单行选中，复制只含所选", cv.selectedRecognizedCount == 1 && cv.recognizedText() == "第一行")
        cv.selectAllRecognized()
        c("识别叠加：全选", cv.selectedRecognizedCount == 2)
        cv.handleKey(code: 53, characters: "", flags: []); cv.handleKey(code: 0, characters: "a", flags: .command); cv.handleKey(code: 8, characters: "c", flags: .command); cv.handleKey(code: 36, characters: "", flags: [])
        c("识别叠加：Esc 返回、⌘A 全选、⌘C / Return 复制文字", rig.commands == [.exitRecognition, .selectAllText, .copySelectedText, .copySelectedText])
        cv.hideRecognition()
        c("识别叠加：返回后叠加层消失", !cv.recognitionActive)

        // 取色
        cv.resetSelection()
        cv.handleMouseMoved(CGPoint(x: 5, y: 5))
        c("取色：红块位置读出 #FF0000，右侧是绿色", cv.colorText(at: CGPoint(x: 5, y: 5)) == "#FF0000" && cv.colorText(at: CGPoint(x: cv.bounds.width - 5, y: 100)) == "#00FF00")
        cv.colorFormat = 0
        c("取色：RGB 格式", cv.colorText(at: CGPoint(x: 5, y: 5)) == "RGB(255, 0, 0)")
        cv.handleKey(code: 8, characters: "c", flags: [])
        c("取色：按 C 把颜色复制到剪贴板（用的是自检专用剪贴板）", rig.board.string(forType: .string) == "RGB(255, 0, 0)")
        c("取色：Shift 切换格式并通知保存", { var seen: [Int] = []; cv.onColorFormatChanged = { seen.append($0) }; cv.cycleColorFormat(); cv.cycleColorFormat(); return seen == [1, 0] }())
        c("取色：ColorText 格式", ColorText.hex((255, 128, 0)) == "#FF8000" && ColorText.rgb((1, 2, 3)) == "RGB(1, 2, 3)")
        let sampler = PixelSampler(baseImage(40, 20))
        c("取色：像素采样越界返回 nil，红块在左上", sampler?.color(x: 2, y: 2).map { $0.r == 255 && $0.g == 0 } == true && sampler?.color(x: 99, y: 0) == nil && sampler?.color(x: -1, y: 0) == nil)
        let frame = LoupeGeometry.frame(cursor: CGPoint(x: 1000, y: 700), bounds: CGRect(x: 0, y: 0, width: 1024, height: 768))
        c("放大镜：靠近右下角时翻到左上方且不出屏幕", frame.maxX <= 1024 && frame.minX < 1000 && frame.maxY + 46 <= 769)
        c("放大镜：取景是以鼠标为中心的 15×15 像素", LoupeGeometry.sourcePixels(cursor: CGPoint(x: 10, y: 10), scale: 2) == CGRect(x: 13, y: 13, width: 15, height: 15))

        // 预设选区
        let preset = CanvasRig()!
        preset.canvas.presetSelection(CGRect(x: -50, y: -50, width: 90000, height: 90000))
        c("预设选区（全屏截图/重复上次区域）会限制在屏幕内", preset.canvas.selection == preset.canvas.bounds && preset.finishedSelections == 1)
        // 点击悬停窗口
        let hoverRig = CanvasRig()!
        hoverRig.canvas.handleMouseMoved(CGPoint(x: 100, y: 100)); hoverRig.click(CGPoint(x: 100, y: 100))
        c("只点击不拖动：选中鼠标下的窗口", hoverRig.canvas.selection == CGRect(x: 50, y: 50, width: 300, height: 200))
        hoverRig.canvas.resetSelection()
        c("清除选区后可重新选择", hoverRig.canvas.selection == nil && hoverRig.canvas.objects.isEmpty)
    }

    // MARK: OCR：阅读顺序、二维码

    static func ocrCore(_ c: (String, Bool) -> Void) {
        let lines = [OCRLine(text: "second", box: CGRect(x: 0.1, y: 0.40, width: 0.3, height: 0.1)),
                     OCRLine(text: "first-right", box: CGRect(x: 0.6, y: 0.81, width: 0.3, height: 0.1)),
                     OCRLine(text: "first-left", box: CGRect(x: 0.1, y: 0.80, width: 0.3, height: 0.1)),
                     OCRLine(text: "   ", box: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1))]
        let joined = OCRLayout.join(lines)
        c("OCR 阅读顺序：自上而下、同行自左向右、丢弃空白行", joined.text == "first-left first-right\nsecond" && joined.ordered.count == 3)
        c("OCR 阅读顺序：没有位置信息时保持原顺序", OCRLayout.join([OCRLine(text: "b", box: .zero), OCRLine(text: "a", box: .zero)]).text == "b\na")
        c("OCR 结果：所有行都有位置才能叠加", OCRResult(text: "x", lines: [OCRLine(text: "x", box: CGRect(x: 0, y: 0, width: 1, height: 1))], engine: "vision").hasBoxes && !OCRResult(text: "x", lines: [OCRLine(text: "x", box: .zero)], engine: "baidu").hasBoxes)
        let english = waitFor(30) { try await VisionOCREngine().recognize(textImage("Hello World 2026")) }
        let englishResult = try? english?.get()
        let englishText = englishResult?.text.lowercased() ?? ""
        c("真实 Vision 识别英文与数字", englishText.contains("hello") && englishText.contains("world") && englishText.contains("2026"))
        c("真实 Vision 返回位置：文字块位于图片内部", englishResult?.hasBoxes == true && englishResult?.lines.allSatisfy { CGRect(x: -0.01, y: -0.01, width: 1.02, height: 1.02).contains($0.box) } == true)
        let chinese = waitFor(30) { try await VisionOCREngine().recognize(textImage("你好世界，今天天气很好")) }
        let chineseText = (try? chinese?.get().text) ?? ""
        c("真实 Vision 识别中文", chineseText.contains("你好") && chineseText.contains("天气"))
        let blank = waitFor(30) { try await VisionOCREngine().recognize(baseImage(120, 80)) }
        c("没有文字的图片返回空结果而不是报错", (try? blank?.get().isEmpty) == true)
        // 二维码
        if let qr = qrImage("https://example.com/path?a=1") {
            let found = (try? waitFor(30) { await BarcodeScanner.scan(qr) }?.get()) ?? []
            c("二维码：识别出内容并判断为网址", found.first?.payload == "https://example.com/path?a=1" && found.first?.isURL == true)
        } else { c("生成测试二维码", false) }
        if let qr = qrImage("just some text 你好") {
            let found = (try? waitFor(30) { await BarcodeScanner.scan(qr) }?.get()) ?? []
            c("二维码：普通文字内容不是网址", found.first?.payload == "just some text 你好" && found.first?.isURL == false)
        }
        c("二维码：没有二维码的图片返回空", ((try? waitFor(30) { await BarcodeScanner.scan(baseImage(100, 100)) }?.get()) ?? [ScannedCode(payload: "x", symbology: "", box: .zero)]).isEmpty)
        c("二维码：网址判断只认 http/https", ScannedCode(payload: "http://a.com", symbology: "", box: .zero).isURL && !ScannedCode(payload: "javascript:alert(1)", symbology: "", box: .zero).isURL && !ScannedCode(payload: "file:///etc/passwd", symbology: "", box: .zero).isURL && !ScannedCode(payload: "hello world", symbology: "", box: .zero).isURL)
        // 图片预处理
        let prepared = OCRImagePrep.encode(baseImage(6000, 3000), maxSide: 4096, maxBytes: 3_000_000)
        c("云端上传前：过大的图片缩小到允许边长内并受体积限制", prepared.map { max($0.width, $0.height) <= 4096 && $0.data.count <= 3_000_000 && $0.width / 2 == $0.height } == true)
        c("云端上传前：编码结果是 JPEG", prepared?.data.prefix(2) == Data([0xFF, 0xD8]))
        let box = OCRImagePrep.normalized(left: 10, top: 20, width: 30, height: 40, imageWidth: 100, imageHeight: 200)
        c("云端位置换算：左上角像素框 → 左下角归一化框", abs(box.minX - 0.1) < 1e-6 && abs(box.minY - (1 - 60.0 / 200)) < 1e-6 && abs(box.width - 0.3) < 1e-6 && abs(box.height - 0.2) < 1e-6)
    }

    // MARK: 云端 OCR 请求与应答（假传输层）

    final class FakeTransport: OCRTransport {
        var queue: [Result<(Data, Int), Error>] = []
        private(set) var requests: [URLRequest] = []
        func enqueue(_ json: String, status: Int = 200) { queue.append(.success((Data(json.utf8), status))) }
        func send(_ request: URLRequest) async throws -> (Data, Int) {
            requests.append(request)
            guard !queue.isEmpty else { throw URLError(.notConnectedToInternet) }
            return try queue.removeFirst().get()
        }
        func bodyString(_ i: Int) -> String { requests[i].httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    }

    static func providers(_ c: (String, Bool) -> Void) {
        let img = textImage("Cloud OCR test", size: 40)
        let W = img.width, H = img.height
        func run(_ engine: OCREngine) -> Result<OCRResult, Error>? { waitFor(30) { try await engine.recognize(img) } }
        func error(_ r: Result<OCRResult, Error>?) -> OCRError? { if case .failure(let e)? = r { return e as? OCRError }; return nil }

        // ---- 百度 ----
        let baiduKey = "ak-" + UUID().uuidString
        let t1 = FakeTransport()
        t1.enqueue("{\"access_token\":\"TOKEN-1\",\"expires_in\":2592000}")
        t1.enqueue("{\"words_result_num\":2,\"words_result\":[{\"words\":\"第二行\",\"location\":{\"top\":\(H * 6 / 10),\"left\":\(W / 10),\"width\":\(W / 2),\"height\":\(H / 5)}},{\"words\":\"第一行\",\"location\":{\"top\":\(H / 10),\"left\":\(W / 10),\"width\":\(W / 2),\"height\":\(H / 5)}}]}")
        let b = try? run(BaiduOCREngine(apiKey: baiduKey, secretKey: "sk", accurate: false, transport: t1))?.get()
        c("百度：先取令牌再识别，请求地址与表单正确", t1.requests.count == 2 && t1.requests[0].url?.host == "aip.baidubce.com" && t1.requests[0].url?.path == "/oauth/2.0/token" && t1.bodyString(0).contains("grant_type=client_credentials") && t1.bodyString(0).contains("client_id=" + baiduKey)
              && t1.requests[1].url?.path == "/rest/2.0/ocr/v1/general" && t1.requests[1].url?.query == "access_token=TOKEN-1" && t1.bodyString(1).contains("image=") && t1.bodyString(1).contains("language_type=auto_detect") && t1.requests[1].value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        c("百度：解析文字与位置并按阅读顺序排列", b?.text == "第一行\n第二行" && b?.engine == "baidu" && b?.hasBoxes == true)
        c("百度：位置换算为归一化坐标（左下角为原点）", b.map { r in let first = r.lines[0].box; return abs(first.minX - 0.1) < 0.02 && abs(first.minY - 0.7) < 0.02 && abs(first.height - 0.2) < 0.02 } == true)
        t1.enqueue("{\"words_result\":[{\"words\":\"again\"}]}")
        _ = run(BaiduOCREngine(apiKey: baiduKey, secretKey: "sk", accurate: false, transport: t1))
        c("百度：令牌缓存复用，第二次只发识别请求", t1.requests.count == 3 && t1.requests[2].url?.path == "/rest/2.0/ocr/v1/general")
        let t2 = FakeTransport(); t2.enqueue("{\"access_token\":\"T\",\"expires_in\":3600}"); t2.enqueue("{\"words_result\":[]}")
        _ = run(BaiduOCREngine(apiKey: "ak-" + UUID().uuidString, secretKey: "sk", accurate: true, transport: t2))
        c("百度：高精度选项改用 accurate 接口", t2.requests.last?.url?.path == "/rest/2.0/ocr/v1/accurate")
        let t3 = FakeTransport(); let k3 = "ak-" + UUID().uuidString
        t3.enqueue("{\"access_token\":\"OLD\",\"expires_in\":3600}"); t3.enqueue("{\"error_code\":111,\"error_msg\":\"Access token expired\"}")
        t3.enqueue("{\"access_token\":\"NEW\",\"expires_in\":3600}"); t3.enqueue("{\"words_result\":[{\"words\":\"ok\"}]}")
        let retried = try? run(BaiduOCREngine(apiKey: k3, secretKey: "sk", accurate: false, transport: t3))?.get()
        c("百度：令牌过期时换新令牌重试并成功", retried?.text == "ok" && t3.requests.count == 4 && t3.requests[3].url?.query == "access_token=NEW")
        func baiduError(_ body: String) -> OCRError? { let t = FakeTransport(); t.enqueue("{\"access_token\":\"T\",\"expires_in\":3600}"); t.enqueue(body); return error(run(BaiduOCREngine(apiKey: "ak-" + UUID().uuidString, secretKey: "s", accurate: false, transport: t))) }
        c("百度：额度用尽归类为 quota", { if case .quota? = baiduError("{\"error_code\":17,\"error_msg\":\"Open api daily request limit reached\"}") { return true }; return false }())
        c("百度：无权限归类为 auth", { if case .auth? = baiduError("{\"error_code\":6,\"error_msg\":\"No permission\"}") { return true }; return false }())
        c("百度：其它错误归类为 service", { if case .service? = baiduError("{\"error_code\":216202,\"error_msg\":\"image size error\"}") { return true }; return false }())
        c("百度：应答不是 JSON 归类为 invalidResponse", { if case .invalidResponse? = baiduError("not json") { return true }; return false }())
        let tBadToken = FakeTransport(); tBadToken.enqueue("{\"error\":\"invalid_client\",\"error_description\":\"unknown client id\"}")
        c("百度：取令牌失败归类为 auth", { if case .auth? = error(run(BaiduOCREngine(apiKey: "ak-" + UUID().uuidString, secretKey: "s", accurate: false, transport: tBadToken))) { return true }; return false }())
        c("百度：网络不通归类为 network", { if case .network? = error(run(BaiduOCREngine(apiKey: "ak-" + UUID().uuidString, secretKey: "s", accurate: false, transport: FakeTransport()))) { return true }; return false }())
        c("百度：图片太小直接报错且不发请求", { let t = FakeTransport(); let r = waitFor(10) { try await BaiduOCREngine(apiKey: "a", secretKey: "b", accurate: false, transport: t).recognize(baseImage(8, 8)) }; if case .failure(let e)? = r, (e as? OCRError) == .tooSmall { return t.requests.isEmpty }; return false }())

        // ---- 腾讯 ----（签名对照独立计算的参考值）
        let expected = "db2da91cdeb3c168d3322c595e64b6c9fa1edecb7530f3cbdd0730d16bc08381"
        let headers = TencentSigner.headers(secretId: "AKIDz8krbsJ5yKBZQpn74WFkmLPx3EXAMPLE", secretKey: "Gu5t9xGARNpq86cd98joQYCN3EXAMPLE", service: "ocr", host: "ocr.tencentcloudapi.com", action: "GeneralBasicOCR", version: "2018-11-19", region: "ap-guangzhou", payload: Data("{\"ImageBase64\":\"AAAA\",\"LanguageType\":\"auto\"}".utf8), timestamp: 1_551_113_065)
        c("腾讯：TC3 签名与独立计算的参考值一致", headers["Authorization"] == "TC3-HMAC-SHA256 Credential=AKIDz8krbsJ5yKBZQpn74WFkmLPx3EXAMPLE/2019-02-25/ocr/tc3_request, SignedHeaders=content-type;host;x-tc-action, Signature=" + expected)
        c("腾讯：请求头完整", headers["X-TC-Action"] == "GeneralBasicOCR" && headers["X-TC-Version"] == "2018-11-19" && headers["X-TC-Region"] == "ap-guangzhou" && headers["X-TC-Timestamp"] == "1551113065" && headers["Host"] == "ocr.tencentcloudapi.com" && headers["Content-Type"] == "application/json; charset=utf-8")
        func sig(_ key: String, _ body: String) -> String? { TencentSigner.headers(secretId: "A", secretKey: key, service: "ocr", host: "h", action: "X", version: "v", region: "r", payload: Data(body.utf8), timestamp: 1)["Authorization"] }
        c("腾讯：载荷不同签名不同，密钥不同签名不同", sig("k1", "a") != sig("k1", "b") && sig("k1", "a") != sig("k2", "a"))
        let tt = FakeTransport()
        tt.enqueue("{\"Response\":{\"TextDetections\":[{\"DetectedText\":\"B 行\",\"Confidence\":99,\"ItemPolygon\":{\"X\":\(W / 10),\"Y\":\(H * 6 / 10),\"Width\":\(W / 2),\"Height\":\(H / 5)}},{\"DetectedText\":\"A 行\",\"Confidence\":98,\"ItemPolygon\":{\"X\":\(W / 10),\"Y\":\(H / 10),\"Width\":\(W / 2),\"Height\":\(H / 5)}}],\"Language\":\"zh\",\"RequestId\":\"r\"}}")
        let tResult = try? run(TencentOCREngine(secretId: "sid", secretKey: "skey", region: "ap-shanghai", accurate: false, transport: tt, now: { Date(timeIntervalSince1970: 1_551_113_065) }))?.get()
        c("腾讯：请求地址、动作、地域与载荷正确", tt.requests.first?.url?.absoluteString == "https://ocr.tencentcloudapi.com/" && tt.requests.first?.value(forHTTPHeaderField: "X-TC-Action") == "GeneralBasicOCR" && tt.requests.first?.value(forHTTPHeaderField: "X-TC-Region") == "ap-shanghai" && tt.bodyString(0).contains("\"ImageBase64\"") && tt.bodyString(0).contains("\"LanguageType\":\"auto\"") && tt.requests.first?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("TC3-HMAC-SHA256 Credential=sid/2019-02-25/ocr/tc3_request") == true)
        c("腾讯：解析文字与位置并排序", tResult?.text == "A 行\nB 行" && tResult?.hasBoxes == true && tResult?.engine == "tencent")
        let ta = FakeTransport(); ta.enqueue("{\"Response\":{\"TextDetections\":[]}}")
        _ = run(TencentOCREngine(secretId: "s", secretKey: "k", region: "", accurate: true, transport: ta))
        c("腾讯：高精度改用 GeneralAccurateOCR，默认地域 ap-guangzhou", ta.requests.first?.value(forHTTPHeaderField: "X-TC-Action") == "GeneralAccurateOCR" && ta.requests.first?.value(forHTTPHeaderField: "X-TC-Region") == "ap-guangzhou")
        func tencentError(_ code: String) -> OCRError? { let t = FakeTransport(); t.enqueue("{\"Response\":{\"Error\":{\"Code\":\"\(code)\",\"Message\":\"msg\"},\"RequestId\":\"r\"}}"); return error(run(TencentOCREngine(secretId: "s", secretKey: "k", region: "", accurate: false, transport: t))) }
        c("腾讯：签名/鉴权错误归类为 auth", { if case .auth? = tencentError("AuthFailure.SignatureFailure") { return true }; return false }())
        c("腾讯：欠费或限流归类为 quota", { if case .quota? = tencentError("RequestLimitExceeded") { return true }; if case .quota? = tencentError("ResourceUnavailable.InArrears") { return true }; return false }())
        c("腾讯：其它错误归类为 service", { if case .service? = tencentError("FailedOperation.ImageDecodeFailed") { return true }; return false }())

        // ---- Google ----
        let tg = FakeTransport()
        tg.enqueue("{\"responses\":[{\"fullTextAnnotation\":{\"text\":\"Hello world\\nSec\",\"pages\":[{\"width\":\(W),\"height\":\(H),\"blocks\":[{\"paragraphs\":[{\"words\":[{\"boundingBox\":{\"vertices\":[{\"x\":10,\"y\":10},{\"x\":60,\"y\":10},{\"x\":60,\"y\":30},{\"x\":10,\"y\":30}]},\"symbols\":[{\"text\":\"H\"},{\"text\":\"e\"},{\"text\":\"l\"},{\"text\":\"l\"},{\"text\":\"o\",\"property\":{\"detectedBreak\":{\"type\":\"SPACE\"}}}]},{\"boundingBox\":{\"vertices\":[{\"x\":70,\"y\":10},{\"x\":120,\"y\":10},{\"x\":120,\"y\":30},{\"x\":70,\"y\":30}]},\"symbols\":[{\"text\":\"w\"},{\"text\":\"o\"},{\"text\":\"r\"},{\"text\":\"l\"},{\"text\":\"d\",\"property\":{\"detectedBreak\":{\"type\":\"LINE_BREAK\"}}}]},{\"boundingBox\":{\"vertices\":[{\"y\":40},{\"x\":100,\"y\":40},{\"x\":100,\"y\":60},{\"y\":60}]},\"symbols\":[{\"text\":\"S\"},{\"text\":\"e\"},{\"text\":\"c\",\"property\":{\"detectedBreak\":{\"type\":\"EOL_SURE_SPACE\"}}}]}]}]}]}]}}]}")
        let gResult = try? run(GoogleOCREngine(apiKey: "gkey", transport: tg))?.get()
        c("Google：密钥放在请求头而不是网址里，请求格式正确", tg.requests.first?.value(forHTTPHeaderField: "X-Goog-Api-Key") == "gkey" && tg.requests.first?.url?.query == nil && tg.requests.first?.url?.absoluteString == "https://vision.googleapis.com/v1/images:annotate" && tg.bodyString(0).contains("DOCUMENT_TEXT_DETECTION") && tg.bodyString(0).contains("\"content\""))
        c("Google：按“行结束”标记把词拼成行，并换算位置", gResult?.lines.map(\.text).sorted() == ["Hello world", "Sec"] && gResult?.hasBoxes == true && gResult?.lines.first { $0.text == "Hello world" }.map { abs($0.box.minX - 10.0 / Double(W)) < 0.01 } == true)
        c("Google：省略为 0 的坐标（x 或 y 缺失）按 0 处理", gResult?.lines.first { $0.text == "Sec" }.map { $0.box.minX == 0 } == true)
        let tgText = FakeTransport(); tgText.enqueue("{\"responses\":[{\"fullTextAnnotation\":{\"text\":\"only text\\nline two\"}}]}")
        let gText = try? run(GoogleOCREngine(apiKey: "k", transport: tgText))?.get()
        c("Google：只有整段文字时仍然返回（没有位置）", gText?.text == "only text\nline two" && gText?.hasBoxes == false)
        func googleError(_ json: String, status: Int = 200) -> OCRError? { let t = FakeTransport(); t.enqueue(json, status: status); return error(run(GoogleOCREngine(apiKey: "k", transport: t))) }
        c("Google：403 / API key 错误归类为 auth", { if case .auth? = googleError("{\"error\":{\"code\":403,\"message\":\"API key not valid\",\"status\":\"PERMISSION_DENIED\"}}", status: 403) { return true }; return false }())
        c("Google：429 归类为 quota", { if case .quota? = googleError("{\"error\":{\"code\":429,\"message\":\"quota\",\"status\":\"RESOURCE_EXHAUSTED\"}}", status: 429) { return true }; return false }())
        c("Google：单个请求内的错误同样识别", { if case .service? = googleError("{\"responses\":[{\"error\":{\"code\":3,\"message\":\"Bad image data\"}}]}") { return true }; return false }())
        c("引擎表：三家云端引擎都要上传图片，本机不上传", { let t = FakeTransport(); return BaiduOCREngine(apiKey: "a", secretKey: "b", accurate: false, transport: t).uploadsImage && TencentOCREngine(secretId: "a", secretKey: "b", region: "", accurate: false, transport: t).uploadsImage && GoogleOCREngine(apiKey: "a", transport: t).uploadsImage && !VisionOCREngine().uploadsImage }())
        c("服务商信息：字段、钥匙串键名与高精度支持", OCRProvider.baidu.credentialFields.map(\.0) == ["apikey", "secretkey"] && OCRProvider.tencent.credentialFields.map(\.0) == ["secretid", "secretkey"] && OCRProvider.google.credentialFields.map(\.0) == ["apikey"] && OCRProvider.keychainKey(.baidu, "apikey") == "ocr.baidu.apikey" && !OCRProvider.google.supportsAccurate && OCRProvider.allCases.allSatisfy { URL(string: $0.consoleURL)?.scheme == "https" })
    }

    // MARK: 路由：同意、凭据、断网与失败时的回退

    static func router(_ c: (String, Bool) -> Void) {
        let img = textImage("Hello World", size: 54)
        var base = ScreenshotSettings()
        func route(_ s: ScreenshotSettings, creds: [OCRProvider: [String: String]] = [:], online: Bool? = true, transport: OCRTransport = FakeTransport()) -> Result<OCRResult, Error>? {
            waitFor(40) { try await OCRRouter(settings: s, credentials: { creds[$0] }, online: { online }, transport: transport).recognize(img) }
        }
        let ok = ["apikey": "a", "secretkey": "b"]
        let local = try? route(base)?.get()
        c("路由：默认引擎是本机 Vision，不发任何网络请求", local?.engine == "vision" && local?.fallbackReason == nil && local?.text.lowercased().contains("hello") == true)
        let fake = FakeTransport()
        base.ocrEngine = "baidu"
        let noConsent = try? route(base, creds: [.baidu: ok], transport: fake)?.get()
        c("路由：选了云端但没同意上传 → 改用本机并说明原因，不发请求", noConsent?.engine == "vision" && noConsent?.fallbackReason?.isEmpty == false && fake.requests.isEmpty)
        base.ocrConsent["baidu"] = true
        let noCreds = try? route(base, creds: [:], transport: fake)?.get()
        c("路由：同意了但没有凭据 → 改用本机", noCreds?.engine == "vision" && noCreds?.fallbackReason?.isEmpty == false && fake.requests.isEmpty)
        let offline = try? route(base, creds: [.baidu: ok], online: false, transport: fake)?.get()
        c("路由：没有网络 → 直接用本机，不尝试云端", offline?.engine == "vision" && offline?.fallbackReason?.isEmpty == false && fake.requests.isEmpty)
        let failing = FakeTransport()      // 空队列：任何请求都会失败
        let failed = try? route(base, creds: [.baidu: ["apikey": "ak-" + UUID().uuidString, "secretkey": "b"]], transport: failing)?.get()
        c("路由：云端请求失败 → 改用本机并带上失败原因", failed?.engine == "vision" && failed?.fallbackReason?.isEmpty == false && !failing.requests.isEmpty && failed?.text.lowercased().contains("hello") == true)
        let good = FakeTransport(); let goodKey = "ak-" + UUID().uuidString
        good.enqueue("{\"access_token\":\"T\",\"expires_in\":3600}"); good.enqueue("{\"words_result\":[{\"words\":\"云端结果\",\"location\":{\"top\":1,\"left\":1,\"width\":50,\"height\":20}}]}")
        let cloud = try? route(base, creds: [.baidu: ["apikey": goodKey, "secretkey": "b"]], transport: good)?.get()
        c("路由：云端成功 → 使用云端结果，无回退说明", cloud?.engine == "baidu" && cloud?.text == "云端结果" && cloud?.fallbackReason == nil)
        var strict = base; strict.ocrFallback = false
        var strictNoConsent = strict; strictNoConsent.ocrConsent = [:]
        c("路由：关闭回退且没同意 → 抛出 noConsent", { if case .failure(let e)? = route(strictNoConsent, creds: [.baidu: ok]), let oe = e as? OCRError, case .noConsent = oe { return true }; return false }())
        c("路由：关闭回退且没有凭据 → 抛出 noCredentials", { if case .failure(let e)? = route(strict, creds: [:]), let oe = e as? OCRError, case .noCredentials = oe { return true }; return false }())
        c("路由：关闭回退且没有网络 → 抛出 offline", { if case .failure(let e)? = route(strict, creds: [.baidu: ok], online: false), (e as? OCRError) == .offline { return true }; return false }())
        c("路由：关闭回退且云端失败 → 抛出云端错误", { if case .failure(let e)? = route(strict, creds: [.baidu: ["apikey": "ak-" + UUID().uuidString, "secretkey": "b"]], transport: FakeTransport()), let oe = e as? OCRError, case .network = oe { return true }; return false }())
        c("路由：没有二维码的图片，二维码结果为空", (try? route(ScreenshotSettings())?.get())?.codes.isEmpty == true)
        if let qr = qrImage("https://example.org/x") {
            let r = (try? waitFor(40) { try await OCRRouter(settings: ScreenshotSettings(), credentials: { _ in nil }, online: { true }).recognize(qr) }?.get())
            c("路由：同一次识别会带回二维码内容", r?.codes.first?.payload == "https://example.org/x")
        }
        c("引擎说明：本机/云端/回退各有不同文案", ScreenshotController.engineNote(OCRResult(text: "", lines: [], engine: "vision")) != ScreenshotController.engineNote(OCRResult(text: "", lines: [], engine: "baidu")) && ScreenshotController.engineNote(OCRResult(text: "", lines: [], engine: "vision", fallbackReason: "断网")).contains("断网"))
    }

    // MARK: 文字识别设置页

    final class FakeKeychain {
        var items: [String: String] = [:]
        var failWrites = false
    }

    static func ocrPage(_ c: (String, Bool) -> Void) {
        func makeDraft(_ provider: OCRProvider, _ kc: FakeKeychain, settings: ScreenshotSettings = ScreenshotSettings(), transport: OCRTransport = FakeTransport(), persisted: @escaping (OCRProvider, Bool, Bool, String) -> Void = { _, _, _, _ in }) -> OCRProviderDraft {
            OCRProviderDraft(provider: provider, settings: settings, has: { kc.items[$0]?.isEmpty == false }, read: { kc.items[$0] },
                             write: { v, k in if kc.failWrites { return false }; kc.items[k] = v; return true }, delete: { kc.items[$0] = nil; return true },
                             persist: { p, consent, accurate, region in persisted(p, consent, accurate, region); return true }, transport: transport)
        }
        let kc = FakeKeychain()
        var persisted: [(OCRProvider, Bool, Bool, String)] = []
        let d = makeDraft(.baidu, kc, persisted: { persisted.append(($0, $1, $2, $3)) })
        c("文字识别页：新配置没有已保存的密钥，也未允许上传", d.saved.isEmpty && !d.complete && !d.consent)
        d.values["apikey"] = "  AK-123  "; d.consent = true
        c("文字识别页：密钥没填完整时不能允许上传，也不会写入", !d.save() && d.isError && kc.items.isEmpty && persisted.isEmpty)
        d.values["secretkey"] = "SK-456"
        c("文字识别页：保存把密钥写入钥匙串（去掉首尾空格、用约定的键名），并清掉输入框", d.save() && kc.items["ocr.baidu.apikey"] == "AK-123" && kc.items["ocr.baidu.secretkey"] == "SK-456" && d.values["apikey"] == "" && d.saved == ["apikey", "secretkey"])
        c("文字识别页：同意、高精度、地域一并保存", persisted.last.map { $0.0 == .baidu && $0.1 && !$0.2 && $0.3 == "ap-guangzhou" } == true)
        var clearedCalls: [(OCRProvider, Bool, Bool, String)] = []
        let reopened = makeDraft(.baidu, kc, settings: { var s = ScreenshotSettings(); s.ocrConsent["baidu"] = true; return s }(), persisted: { clearedCalls.append(($0, $1, $2, $3)) })
        c("文字识别页：重新打开时显示已保存且已允许，不需要再输入，也不回显密钥", reopened.complete && reopened.consent && reopened.values.isEmpty)
        let denied = FakeKeychain(); denied.failWrites = true
        let dd = makeDraft(.google, denied); dd.values["apikey"] = "G"
        c("文字识别页：钥匙串写入失败时如实报错且不当作已保存", !dd.save() && dd.isError && dd.saved.isEmpty)
        reopened.clearCredentials()
        c("文字识别页：移除密钥会清空钥匙串、关闭上传并通知保存", kc.items.isEmpty && reopened.saved.isEmpty && !reopened.consent && clearedCalls.last.map { $0.0 == .baidu && $0.1 == false } == true)
        let tc = makeDraft(.tencent, FakeKeychain(), settings: { var s = ScreenshotSettings(); s.ocrTencentRegion = "ap-shanghai"; s.ocrAccurate["tencent"] = true; return s }())
        c("文字识别页：腾讯的地域与高精度选项取自设置", tc.region == "ap-shanghai" && tc.accurate && OCRProvider.tencent.supportsAccurate && !OCRProvider.google.supportsAccurate)
        // 测试连接
        func runTest(_ draft: OCRProviderDraft) { _ = waitFor(30) { await draft.test() } }
        let t0 = makeDraft(.baidu, FakeKeychain()); t0.values = ["apikey": "a", "secretkey": "b"]
        runTest(t0)
        c("测试连接：没允许上传时不发请求", t0.isError && !t0.testing)
        let fakeKC = FakeKeychain(); let tr = FakeTransport(); let uniqueKey = "ak-" + UUID().uuidString
        tr.enqueue("{\"access_token\":\"T\",\"expires_in\":3600}"); tr.enqueue("{\"words_result\":[{\"words\":\"OCR TEST 123\"}]}")
        let t1 = makeDraft(.baidu, fakeKC, transport: tr); t1.values = ["apikey": uniqueKey, "secretkey": "b"]; t1.consent = true
        runTest(t1)
        c("测试连接：成功时显示服务读到的文字，用的是刚输入的密钥且不要求先保存", !t1.isError && t1.feedback.contains("OCR TEST 123") && tr.requests.count == 2 && tr.bodyString(0).contains("client_id=" + uniqueKey) && fakeKC.items.isEmpty && !t1.testing)
        let tr2 = FakeTransport(); tr2.enqueue("{\"access_token\":\"T\",\"expires_in\":3600}"); tr2.enqueue("{\"words_result\":[]}")
        let t2 = makeDraft(.baidu, FakeKeychain(), transport: tr2); t2.values = ["apikey": "ak-" + UUID().uuidString, "secretkey": "b"]; t2.consent = true
        runTest(t2)
        c("测试连接：服务有应答但没读出文字 → 提示失败", t2.isError)
        let tr3 = FakeTransport(); tr3.enqueue("{\"Response\":{\"Error\":{\"Code\":\"AuthFailure.SignatureFailure\",\"Message\":\"bad key\"}}}")
        let t3 = makeDraft(.tencent, FakeKeychain(), transport: tr3); t3.values = ["secretid": "i", "secretkey": "k"]; t3.consent = true
        runTest(t3)
        c("测试连接：鉴权失败时显示具体原因", t3.isError && t3.feedback.contains("bad key"))
        let t4 = makeDraft(.google, FakeKeychain(), transport: FakeTransport()); t4.consent = true
        runTest(t4)
        c("测试连接：没有密钥时提示先填写", t4.isError && !t4.testing)
        c("测试用图片：能被本机识别出文字", { guard let img = OCRTestImage.make() else { return false }; let r = (try? waitFor(30) { try await VisionOCREngine().recognize(img) }?.get())?.text.uppercased() ?? ""; return r.contains("OCR") || r.contains("123") }())
        // 选择引擎的门槛
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(fileURL: dir.appendingPathComponent("config.json"))
        let pipeline = VoicePipeline(configStore: store, input: InputSourceController()); pipeline.selfTestMode = true
        let model = SettingsModel(store: store, pipeline: pipeline)
        model.selectOCREngine("vision", hasCredentials: { _ in false })
        c("文字识别页：选择本机引擎直接生效", store.config.screenshot.ocrEngine == "vision" && model.configuringOCR == nil)
        model.selectOCREngine("baidu", hasCredentials: { _ in false })
        c("文字识别页：选择没配置的云端引擎 → 打开配置窗口，设置不变", model.configuringOCR == .baidu && store.config.screenshot.ocrEngine == "vision")
        model.configuringOCR = nil
        model.selectOCREngine("baidu", hasCredentials: { _ in true })
        c("文字识别页：有密钥但没允许上传 → 仍然打开配置窗口", model.configuringOCR == .baidu && store.config.screenshot.ocrEngine == "vision")
        model.configuringOCR = nil
        _ = store.mutate { $0.screenshot.ocrConsent["baidu"] = true }; model.sync()
        model.selectOCREngine("baidu", hasCredentials: { _ in true })
        c("文字识别页：密钥与同意都有 → 选择生效", model.configuringOCR == nil && store.config.screenshot.ocrEngine == "baidu")
        let draftModel = model.ocrDraft(.tencent)
        draftModel.consent = true; draftModel.accurate = true; draftModel.region = "ap-beijing"
        let savedOK = draftModel.persistOptionsForTest()
        c("文字识别页：配置窗口保存的选项写入设置并同步到模型", savedOK && store.config.screenshot.ocrConsent["tencent"] == true && store.config.screenshot.ocrAccurate["tencent"] == true && store.config.screenshot.ocrTencentRegion == "ap-beijing" && model.screenshotSettings.ocrTencentRegion == "ap-beijing")
        c("侧栏：文字识别标签位于引擎与快捷键之间，且有标题和图标", MainTab.allCases.firstIndex(of: .ocr) == MainTab.allCases.firstIndex(of: .engines).map { $0 + 1 } && MainTab.ocr.title != "ocr.title" && !MainTab.ocr.icon.isEmpty && MainTab.visible(showDeveloper: false).contains(.ocr))
        let keys = ["ocr.title", "ocr.engines.header", "ocr.fallback", "ocr.sheet.test", "ocr.provider.baidu", "ocr.provider.tencent", "ocr.provider.google", "screenshot.ocr.err.noConsent", "screenshot.recog.back"]
        c("文字识别页：关键文案都已本地化", keys.allSatisfy { L10n.tr($0) != $0 })
    }

    static func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("cadenza-ocr-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }

    // MARK: 贴图

    static func pins(_ c: (String, Bool) -> Void) {
        typealias P = PinGeometry
        c("贴图：缩放范围被限制在 0.1–8 倍", P.clampZoom(0.01) == 0.1 && P.clampZoom(100) == 8 && P.clampZoom(2) == 2)
        c("贴图：滚轮向上放大、向下缩小", P.nextZoom(1, scrollDelta: 5) > 1 && P.nextZoom(1, scrollDelta: -5) < 1 && P.nextZoom(8, scrollDelta: 50) == 8)
        c("贴图：透明度 0.2–1，按 0.1 取整", P.clampOpacity(0.05) == 0.2 && P.clampOpacity(1.4) == 1 && P.clampOpacity(0.74) == 0.7)
        c("贴图：缩放以窗口中心为锚点", P.frame(base: CGSize(width: 200, height: 100), zoom: 2, center: CGPoint(x: 500, y: 400)) == CGRect(x: 300, y: 300, width: 400, height: 200))
        c("贴图：旋转 90° 宽高互换", P.rotatedSize(CGSize(width: 200, height: 100), quarterTurns: 1) == CGSize(width: 100, height: 200) && P.rotatedSize(CGSize(width: 200, height: 100), quarterTurns: 2) == CGSize(width: 200, height: 100))
        let base = baseImage(60, 30)          // 左上角红块，左蓝右绿
        let r1 = P.rotate(base, quarterTurns: 1)
        c("贴图：顺时针旋转 90° 后尺寸互换，红块从左上移到右上", r1.map { $0.width == 30 && $0.height == 60 } == true && isRed(r1.flatMap { pixel($0, 28, 2) }) && !isRed(r1.flatMap { pixel($0, 2, 2) }))
        let r2 = P.rotate(base, quarterTurns: 2)
        c("贴图：旋转 180° 红块到右下，左右颠倒", isRed(r2.flatMap { pixel($0, 57, 27) }) && isGreen(r2.flatMap { pixel($0, 5, 15) }))
        c("贴图：旋转 4 圈等于原图，负数圈数按逆时针（红块到左下）", P.rotate(base, quarterTurns: 4).map { isRed(pixel($0, 2, 2)) } == true && P.rotate(base, quarterTurns: -1).map { isRed(pixel($0, 2, 57)) } == true)
        let manager = PinManager()
        c("贴图管理：初始为空", manager.count == 0 && !manager.anyClickThrough && !manager.hidden)
    }

    // MARK: 输出（复制 / 文件名 / 剪贴板隔离）

    static func outputs(_ c: (String, Bool) -> Void) {
        let image = baseImage(80, 40)
        let board = NSPasteboard(name: NSPasteboard.Name("cadenza-selftest-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        ScreenshotOutputs.copy(image, scale: 2, to: board)
        let png = board.data(forType: .png)
        c("复制：剪贴板含 PNG，尺寸正确", png.flatMap { NSBitmapImageRep(data: $0) }.map { $0.pixelsWide == 80 && $0.pixelsHigh == 40 } == true)
        c("复制：同时提供 TIFF 供旧软件粘贴", board.data(forType: .tiff) != nil)
        let name = ScreenshotOutputs.fileName(date: Date(timeIntervalSince1970: 1_790_000_000))
        c("默认文件名：含品牌名与时间、不含冒号、扩展名 png", name.hasSuffix(".png") && !name.contains(":") && name.contains(Brand.name) && name.contains("2026"))
        c("PNG 编码可被重新解码", ScreenshotRenderer.pngData(image).flatMap { NSBitmapImageRep(data: $0) }.map { $0.pixelsWide == 80 } == true)
        c("以点为单位的 NSImage 尺寸 = 像素 / 缩放", ScreenshotRenderer.nsImage(image, scale: 2).size == NSSize(width: 40, height: 20))
    }

    // MARK: 设置、热键、校验、菜单

    static func settings(_ c: (String, Bool) -> Void) {
        c("默认不占用任何快捷键，OCR 默认本机且允许回退", ScreenshotSettings().trigger == nil && ScreenshotSettings().ocrTrigger == nil && ScreenshotSettings().ocrEngine == "vision" && ScreenshotSettings().ocrFallback && ScreenshotSettings().ocrConsent.isEmpty && BridgeConfig.default().screenshot.trigger == nil)
        let old = try? JSONDecoder().decode(BridgeConfig.self, from: Data("{\"engine\":\"apple\"}".utf8))
        c("旧配置缺少 screenshot 键时用默认值", old?.screenshot == ScreenshotSettings())
        let partial = try? JSONDecoder().decode(ScreenshotSettings.self, from: Data("{\"ocrEngine\":\"google\"}".utf8))
        c("旧的截图设置缺少新字段时逐项取默认", partial?.ocrEngine == "google" && partial?.ocrFallback == true && partial?.colorFormat == 1 && partial?.ocrTencentRegion == "ap-guangzhou")
        var cfg = BridgeConfig.default(); cfg.screenshot.trigger = HotkeySpec(keyCode: 0, modifiers: UInt32(controlKey | shiftKey)); cfg.screenshot.ocrTrigger = HotkeySpec(keyCode: 1, modifiers: UInt32(controlKey | shiftKey))
        cfg.screenshot.ocrEngine = "tencent"; cfg.screenshot.ocrConsent = ["tencent": true]; cfg.screenshot.ocrAccurate = ["tencent": true]; cfg.screenshot.ocrFallback = false; cfg.screenshot.colorFormat = 0
        let round = try? JSONDecoder().decode(BridgeConfig.self, from: JSONEncoder().encode(cfg))
        c("截图设置往返保留，且不影响配置校验", round?.screenshot == cfg.screenshot && BridgeConfig.validate(cfg).isEmpty)

        let config = BridgeConfig.default()
        c("快捷键校验：与语音触发键相同被拒绝", ScreenshotShortcutValidation.problem(for: config.trigger, config: config, policy: { _ in nil }) != nil)
        let spec = HotkeySpec(keyCode: 0, modifiers: UInt32(controlKey | shiftKey))
        c("快捷键校验：规则通过则可用", ScreenshotShortcutValidation.problem(for: spec, config: config, policy: { _ in nil }) == nil)
        c("快捷键校验：与另一个截图快捷键相同被拒绝", ScreenshotShortcutValidation.problem(for: spec, config: config, other: spec, policy: { _ in nil }) != nil)
        c("快捷键校验：规则拒绝时原样返回原因", ScreenshotShortcutValidation.problem(for: spec, config: config, policy: { _ in "占用" }) == "占用")
        c("快捷键校验：单个字母键（无修饰键）被拒绝", ScreenshotShortcutValidation.problem(for: HotkeySpec(keyCode: 0, modifiers: 0), config: config) != nil)
        let C = UInt32(controlKey), O = UInt32(optionKey), M = UInt32(cmdKey), H = UInt32(shiftKey)
        func why(_ key: UInt32, _ mods: UInt32, system: [HotkeySpec] = [], vo: Bool = false) -> String? {
            ScreenshotShortcutPolicy.reason(HotkeySpec(keyCode: key, modifiers: mods), systemAssignments: system, menuAssignments: [], voiceOver: vo)
        }
        c("截图规则：常见组合 ⌥A ⌘⇧A ⌘⌥A ⌃⇧A ⌃⌥A 都可用", [why(0, O), why(0, M | H), why(0, M | O), why(0, C | H), why(0, C | O), why(0, M | C)].allSatisfy { $0 == nil })
        c("截图规则：F 键可单独使用", why(105, 0) == nil && why(122, 0) == nil)
        c("截图规则：⌘ 单独修饰的标准命令被拒绝", why(8, M) != nil && why(9, M) != nil && why(0, M) != nil)
        c("截图规则：Shift 单独修饰、无修饰键、单独修饰键、Fn 被拒绝", why(0, H) != nil && why(0, 0) != nil && why(58, O) != nil && why(63, 0) != nil)
        c("截图规则：系统已占用的组合被拒绝（如 ⌘⇧5）", why(23, M | H, system: [HotkeySpec(keyCode: 23, modifiers: M | H)]) != nil && why(23, M | H) == nil)
        c("截图规则：开启 VoiceOver 时 ⌃⌥ 组合被拒绝", why(0, C | O, vo: true) != nil && why(0, C | O, vo: false) == nil)
        c("截图规则：空格、Tab 等需要修饰键才能使用", why(49, 0) != nil && why(49, C | O) == nil)
        let picks = ScreenshotShortcutPolicy.suggestions(limit: 4) { ScreenshotShortcutPolicy.reason($0, systemAssignments: [], menuAssignments: [], voiceOver: false) }
        c("候选组合：给出 4 个且全部可用", picks.count == 4 && picks.allSatisfy { ScreenshotShortcutPolicy.reason($0, systemAssignments: [], menuAssignments: [], voiceOver: false) == nil })
        c("候选组合：被系统占用的会被跳过", ScreenshotShortcutPolicy.suggestions(limit: 4) { $0 == ScreenshotShortcutPolicy.suggestionCandidates[0] ? "占用" : nil }.first != ScreenshotShortcutPolicy.suggestionCandidates[0])
        c("快捷键目标：截图与识字各管各的字段", { var cfg = BridgeConfig.default(); ScreenshotShortcutTarget.capture.set(&cfg, spec); ScreenshotShortcutTarget.ocr.set(&cfg, HotkeySpec(keyCode: 1, modifiers: C | H)); return cfg.screenshot.trigger == spec && cfg.screenshot.ocrTrigger?.keyCode == 1 && ScreenshotShortcutTarget.capture.other(cfg)?.keyCode == 1 }())

        let hotkey = ScreenshotHotkey(id: 1), second = ScreenshotHotkey(id: 2)
        let probe = HotkeySpec(keyCode: 79, modifiers: C | H | M), probe2 = HotkeySpec(keyCode: 80, modifiers: C | H | M)       // ⌃⇧⌘F18 / F19：冷门组合，仅用于注册检查
        c("热键：两个热键各自注册成功并记录当前组合", hotkey.register(probe) && hotkey.registered == probe && second.register(probe2) && second.registered == probe2)
        hotkey.unregister(); second.unregister()
        c("热键：注销后不再占用", hotkey.registered == nil && second.registered == nil)

        var snapshot = StatusMenuSnapshot(); snapshot.screenshotShortcut = "⌃⇧A"; snapshot.ocrShortcut = "⌃⇧S"
        let menu = NSMenu(); StatusMenuController.rebuild(menu, s: snapshot, target: NSObject())
        let item = menu.items.first { $0.identifier?.rawValue == "screenshot" }
        c("状态栏菜单：有截图项并显示快捷键", item != nil && item?.subtitleText == "⌃⇧A" && item?.isEnabled == true)
        let more = menu.items.first { $0.identifier?.rawValue == "screenshot.more" }?.submenu
        c("状态栏菜单：更多截图方式含全屏、延时 3/5/10 秒、重复上次区域、直接识字", more?.items.contains { $0.identifier?.rawValue == "screenshot.full" } == true && more?.items.first { $0.identifier?.rawValue == "screenshot.delay" }?.submenu?.items.map(\.tag) == [3, 5, 10] && more?.items.contains { $0.identifier?.rawValue == "screenshot.repeat" } == true && more?.items.first { $0.identifier?.rawValue == "screenshot.ocr" }?.subtitleText == "⌃⇧S")
        c("状态栏菜单：没有贴图时不显示贴图菜单", !menu.items.contains { $0.identifier?.rawValue == "pins" })
        snapshot.pinCount = 2; snapshot.pinsClickThrough = true
        let pinMenu = NSMenu(); StatusMenuController.rebuild(pinMenu, s: snapshot, target: NSObject())
        c("状态栏菜单：有贴图时出现隐藏/恢复交互/全部关闭", pinMenu.items.first { $0.identifier?.rawValue == "pins" }?.submenu?.items.compactMap { $0.identifier?.rawValue } == ["pins.hide", "pins.interact", "pins.close"])
        snapshot.busy = true
        let busyMenu = NSMenu(); StatusMenuController.rebuild(busyMenu, s: snapshot, target: NSObject())
        c("状态栏菜单：录音中截图相关项不可用", busyMenu.items.first { $0.identifier?.rawValue == "screenshot" }?.isEnabled == false && busyMenu.items.first { $0.identifier?.rawValue == "screenshot.more" }?.submenu?.items.first { $0.identifier?.rawValue == "screenshot.full" }?.isEnabled == false)
        c("屏幕录制权限查询可用", { _ = ScreenCapturePermission.granted; return true }())
    }

    // MARK: 图标

    static func icons(_ c: (String, Bool) -> Void) {
        let names = ScreenshotIcon.names
        c("原创 SVG 图标全部打包进应用", names.count == 39 && names.allSatisfy { ScreenshotIcon.isOriginal($0) })
        c("图标可加载为模板图且有尺寸", names.allSatisfy { let i = ScreenshotIcon.image($0); return i.isTemplate && i.size.width > 0 && i.size.height > 0 })
        let sources = names.compactMap { n in Bundle.main.url(forResource: "shot-" + n, withExtension: "svg").flatMap { try? String(contentsOf: $0, encoding: .utf8) } }
        c("图标源文件：24×24 视图框，无文字、脚本或外部引用", sources.count == names.count && sources.allSatisfy { $0.contains("viewBox=\"0 0 24 24\"") && !$0.contains("<text") && !$0.contains("<script") && !$0.contains("href") && !$0.contains("<image") })
        c("图标彼此不同", Set(sources).count == names.count)
        c("每个工具都有图标、本地化名称和字母快捷键", ScreenshotTool.allCases.allSatisfy { ScreenshotIcon.names.contains(ScreenshotIcon.toolIcon($0)) && ScreenshotIcon.toolShortcuts[$0] != nil && L10n.tr(ScreenshotIcon.toolLabelKey($0)) != ScreenshotIcon.toolLabelKey($0) } && Set(ScreenshotIcon.toolOrder) == Set(ScreenshotTool.allCases))
        c("字母快捷键互不重复", Set(ScreenshotIcon.toolShortcuts.values).count == ScreenshotTool.allCases.count)
        c("标注形状与工具一一对应", ScreenshotIcon.tool(for: .mosaic(.zero)) == .mosaic && ScreenshotIcon.tool(for: .marker(.zero, 1)) == .marker && ScreenshotIcon.tool(for: .line(.zero, .zero)) == .arrow && ScreenshotIcon.tool(for: .highlighter([])) == .highlighter)
    }
}

// MARK: - 离线渲染预览：合成桌面画面 + 选区 + 标注 + 工具栏，输出 PNG。不打开窗口、不抓屏。
enum ScreenshotPreview {
    static func render(output: String, dark: Bool, tool: ScreenshotTool?, recognizing: Bool, recognition: Bool = false) -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)   // 不出现在 Dock，也不抢焦点
        guard let screen = NSScreen.main else { return 2 }
        let w = Int(screen.frame.width), h = Int(screen.frame.height)
        // 合成一个“桌面”：渐变背景、一块模拟窗口、几行文字
        let ctx = ScreenshotFixtures.bitmapContext(w, h)
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [CGColor(srgbRed: 0.35, green: 0.45, blue: 0.75, alpha: 1), CGColor(srgbRed: 0.75, green: 0.55, blue: 0.80, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        ctx.setFillColor(CGColor(gray: 0.97, alpha: 1)); ctx.fill(CGRect(x: 240, y: CGFloat(h) - 700, width: 760, height: 520))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (i, line) in ["Quarterly report — Revenue 128,400", "电话 138 0000 0000   邮箱 name@example.com", "Hello world, 随口说，随处写。", "Meeting notes: ship the screenshot feature"].enumerated() {
            (line as NSString).draw(at: CGPoint(x: 280, y: CGFloat(h) - 260 - CGFloat(i) * 70), withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        let display = CapturedDisplay(screen: screen, image: ctx.makeImage()!, scale: 1, windows: [])
        let canvas = ScreenshotCanvasView(display: display)
        canvas.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let selection = CGRect(x: 262, y: 190, width: 700, height: 300)
        canvas.testSetSelection(selection)
        func o(_ shape: AnnotationObject.Shape, _ color: ScreenshotColor = .red, level: Int = 1, filled: Bool = false, arrow: ArrowStyle = .single, text: TextStyle = .plain) -> AnnotationObject {
            AnnotationObject(shape: shape, color: color, level: level, filled: filled, arrowStyle: arrow, textStyle: text)
        }
        canvas.testAdd(o(.rectangle(CGRect(x: 272, y: 238, width: 420, height: 44))))
        canvas.testAdd(o(.line(CGPoint(x: 840, y: 420), CGPoint(x: 700, y: 262)), arrow: .double))
        canvas.testAdd(o(.text("Check this", CGPoint(x: 800, y: 430)), .white, level: 1, text: .filled))
        canvas.testAdd(o(.blur(CGRect(x: 272, y: 308, width: 330, height: 40)), level: 2))
        canvas.testAdd(o(.ellipse(CGRect(x: 272, y: 380, width: 220, height: 70)), .blue))
        canvas.testAdd(o(.highlighter([CGPoint(x: 280, y: 250), CGPoint(x: 600, y: 250)]), .yellow))
        canvas.testAdd(o(.marker(CGPoint(x: 700, y: 250), 1), .red, level: 1))
        canvas.testAdd(o(.marker(CGPoint(x: 700, y: 330), 2), .green, level: 1))
        if recognition {
            canvas.showRecognition([OCRLine(text: "Quarterly report", box: CGRect(x: 0.03, y: 0.78, width: 0.55, height: 0.12)), OCRLine(text: "name@example.com", box: CGRect(x: 0.03, y: 0.50, width: 0.45, height: 0.12))])
            canvas.selectAllRecognized()
        }
        let model = ScreenshotToolbarModel()
        model.tool = tool; model.canUndo = true; model.recognizing = recognizing
        if recognition { model.recognition = RecognitionSummary(lineCount: 2, selectedCount: 2, engineNote: "本机", codes: [ScannedCode(payload: "https://example.com/menu", symbology: "QR", box: .zero)]) }
        let palette = NSHostingView(rootView: ScreenshotPaletteView(model: model)), actions = NSHostingView(rootView: ScreenshotActionBarView(model: model))
        for host in [palette, actions] { host.appearance = canvas.appearance; canvas.addSubview(host); host.layoutSubtreeIfNeeded() }
        actions.frame = ScreenshotGeometry.toolbarFrame(selection: selection.insetBy(dx: -10, dy: 0), size: actions.fittingSize, bounds: canvas.bounds, gap: 0)
        palette.frame = ScreenshotGeometry.paletteFrame(selection: selection.offsetBy(dx: 0, dy: -8), size: palette.fittingSize, bounds: canvas.bounds, avoiding: actions.frame, gap: -4)
        palette.isHidden = recognition
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)   // 仅用于布局，不显示
        window.contentView = canvas
        canvas.layoutSubtreeIfNeeded()
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return 3 }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return 4 }
        do { try data.write(to: URL(fileURLWithPath: output)) } catch { return 5 }
        print("screenshot-preview written \(output) \(w)x\(h)")
        return 0
    }

    /// 三种文字样式 × 全部颜色的对照图，叠在浅色 / 深色两块底上，检查每种样式换色后是否都看得出
    static func renderTextStyles(output: String) -> Int32 {
        let w = 1040, h = 560, scale: CGFloat = 2
        let ctx = ScreenshotFixtures.bitmapContext(w, h)
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 2))
        ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.13, blue: 0.16, alpha: 1)); ctx.fill(CGRect(x: 0, y: h / 2, width: w, height: h - h / 2))
        guard let base = ctx.makeImage() else { return 3 }
        var objects: [AnnotationObject] = []
        for (row, style) in [TextStyle.plain, .filled, .outlined].enumerated() {
            for (i, color) in ScreenshotColor.palette.enumerated() {
                for (band, y0) in [0, 140].enumerated() {
                    objects.append(AnnotationObject(shape: .text("Aa 字", CGPoint(x: 16 + CGFloat(i) * 62, y: CGFloat(y0 + 20 + row * 40))), color: color, level: 1, textStyle: style))
                    _ = band
                }
            }
        }
        let size = CGSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        guard let image = ScreenshotRenderer.render(display: base, effects: ScreenshotEffects(image: base, scale: scale), selection: CGRect(origin: .zero, size: size), scale: scale, objects: objects),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return 4 }
        do { try data.write(to: URL(fileURLWithPath: output)) } catch { return 5 }
        print("text-styles written \(output)"); return 0
    }

    /// 所有图标的图样表（按网格排列，放大显示，便于检查造型）
    static func renderIcons(output: String, dark: Bool) -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let names = ScreenshotIcon.names, columns = 8, cell: CGFloat = 130, rows = (names.count + columns - 1) / columns
        let size = NSSize(width: CGFloat(columns) * cell, height: CGFloat(rows) * (cell + 18))
        let image = NSImage(size: size)
        image.lockFocus()
        (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill(); NSRect(origin: .zero, size: size).fill()
        let tint = dark ? NSColor.white : NSColor.black
        for (i, name) in names.enumerated() {
            let col = i % columns, row = i / columns
            let x = CGFloat(col) * cell, y = size.height - CGFloat(row + 1) * (cell + 18)
            let icon = ScreenshotIcon.image(name).copy() as! NSImage
            icon.lockFocus(); tint.set(); NSRect(origin: .zero, size: icon.size).fill(using: .sourceAtop); icon.unlockFocus()
            icon.draw(in: NSRect(x: x + 22, y: y + 30, width: 86, height: 86))
            (name as NSString).draw(at: NSPoint(x: x + 22, y: y + 6), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: tint.withAlphaComponent(0.6)])
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return 4 }
        do { try png.write(to: URL(fileURLWithPath: output)) } catch { return 5 }
        print("screenshot-icons written \(output)")
        return 0
    }
}
