import AppKit
import CoreImage

// MARK: - 截图渲染：屏幕预览与导出共用同一套绘制代码，保证“所见即所得”
// 约定：传入的 CGContext 已经是“y 向下、单位为点”的坐标系（原点在左上角），标注坐标是整屏坐标。

/// 整屏的马赛克/模糊版本：按强度档位各算一次并缓存，之后每个标注从中裁取对应区域
final class ScreenshotEffects {
    let image: CGImage
    let scale: CGFloat
    private var pixelatedCache: [Int: CGImage] = [:]
    private var blurredCache: [Int: CGImage] = [:]
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init(image: CGImage, scale: CGFloat) { self.image = image; self.scale = scale }

    func pixelated(level: Int) -> CGImage? {
        let level = ScreenshotMetrics.clamp(level)
        if let hit = pixelatedCache[level] { return hit }
        let made = Self.pixelate(image, blockPixels: ScreenshotMetrics.mosaicBlocks[level] * scale)
        pixelatedCache[level] = made; return made
    }
    func blurred(level: Int) -> CGImage? {
        let level = ScreenshotMetrics.clamp(level)
        if let hit = blurredCache[level] { return hit }
        let made = Self.blur(image, radiusPixels: ScreenshotMetrics.blurRadii[level] * scale)
        blurredCache[level] = made; return made
    }

    static func pixelate(_ image: CGImage, blockPixels: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(max(2, blockPixels), forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: input.extent.minX, y: input.extent.minY), forKey: kCIInputCenterKey)
        guard let out = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return ciContext.createCGImage(out, from: input.extent)
    }

    /// 高斯模糊：先把边缘向外延伸，避免图片四周被模糊成半透明
    static func blur(_ image: CGImage, radiusPixels: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(max(1, radiusPixels), forKey: kCIInputRadiusKey)
        guard let out = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return ciContext.createCGImage(out, from: input.extent)
    }
}

enum ScreenshotRenderer {
    // MARK: 基础

    /// 在“y 向下”的上下文里把图片正着画出来（CGContext.draw 默认按 y 向上解释图片）
    static func drawUpright(_ ctx: CGContext, _ image: CGImage, in rect: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    private static func withText(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: 标注

    /// - Parameter displayRect: 整屏图片在当前坐标系里的位置，通常是 (0, 0, 屏幕点尺寸)。
    static func draw(_ objects: [AnnotationObject], in ctx: CGContext, effects: ScreenshotEffects?, displayRect: CGRect) {
        for o in objects {
            ctx.saveGState()
            switch o.shape {
            case .rectangle(let r):
                if o.filled { ctx.setFillColor(o.color.cgColor); ctx.fill(r.standardized) }
                else { ctx.setStrokeColor(o.color.cgColor); ctx.setLineWidth(o.stroke); ctx.setLineJoin(.round); ctx.stroke(r.standardized) }
            case .ellipse(let r):
                if o.filled { ctx.setFillColor(o.color.cgColor); ctx.fillEllipse(in: r.standardized) }
                else { ctx.setStrokeColor(o.color.cgColor); ctx.setLineWidth(o.stroke); ctx.strokeEllipse(in: r.standardized) }
            case .line(let a, let b):
                drawLine(ctx, from: a, to: b, color: o.color, width: o.stroke, style: o.arrowStyle)
            case .pen(let pts):
                strokePolyline(ctx, pts, color: o.color.cgColor, width: o.stroke, cap: .round)
            case .highlighter(let pts):
                ctx.setBlendMode(.multiply)          // 像真正的荧光笔：压在文字上不遮挡
                strokePolyline(ctx, pts, color: o.color.cgColor(alpha: 0.55), width: o.highlighterWidth, cap: .square)
            case .mosaic(let r):
                if let img = effects?.pixelated(level: o.level) { ctx.clip(to: r.standardized); drawUpright(ctx, img, in: displayRect) }
            case .blur(let r):
                if let img = effects?.blurred(level: o.level) { ctx.clip(to: r.standardized); drawUpright(ctx, img, in: displayRect) }
            case .text(let string, let origin):
                drawText(ctx, string, at: origin, color: o.color, fontSize: o.fontSize, style: o.textStyle)
            case .marker(let center, let number):
                drawMarker(ctx, center: center, number: number, radius: o.markerRadius, color: o.color)
            }
            ctx.restoreGState()
        }
    }

    private static func strokePolyline(_ ctx: CGContext, _ pts: [CGPoint], color: CGColor, width: CGFloat, cap: CGLineCap) {
        guard let first = pts.first else { return }
        ctx.setStrokeColor(color); ctx.setFillColor(color); ctx.setLineWidth(width); ctx.setLineCap(cap); ctx.setLineJoin(.round)
        if pts.count == 1 { ctx.fillEllipse(in: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width)); return }
        ctx.beginPath(); ctx.move(to: first); pts.dropFirst().forEach { ctx.addLine(to: $0) }; ctx.strokePath()
    }

    static func arrowHead(from: CGPoint, to: CGPoint, width: CGFloat) -> (left: CGPoint, right: CGPoint, base: CGPoint)? {
        let dx = to.x - from.x, dy = to.y - from.y, length = hypot(dx, dy)
        guard length > 1 else { return nil }
        let head = min(length * 0.6, max(12, width * 4.5)), half = head * 0.5
        let ux = dx / length, uy = dy / length
        let base = CGPoint(x: to.x - ux * head, y: to.y - uy * head)
        return (CGPoint(x: base.x - uy * half, y: base.y + ux * half), CGPoint(x: base.x + uy * half, y: base.y - ux * half), base)
    }

    private static func drawLine(_ ctx: CGContext, from: CGPoint, to: CGPoint, color: ScreenshotColor, width: CGFloat, style: ArrowStyle) {
        ctx.setStrokeColor(color.cgColor); ctx.setFillColor(color.cgColor); ctx.setLineWidth(width); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        var start = from, end = to
        let headEnd = style == .line ? nil : arrowHead(from: from, to: to, width: width)
        let headStart = style == .double ? arrowHead(from: to, to: from, width: width) : nil
        if let h = headEnd { end = h.base }
        if let h = headStart { start = h.base }
        ctx.beginPath(); ctx.move(to: start); ctx.addLine(to: end); ctx.strokePath()
        if let h = headEnd { ctx.beginPath(); ctx.move(to: to); ctx.addLine(to: h.left); ctx.addLine(to: h.right); ctx.closePath(); ctx.fillPath() }
        if let h = headStart { ctx.beginPath(); ctx.move(to: from); ctx.addLine(to: h.left); ctx.addLine(to: h.right); ctx.closePath(); ctx.fillPath() }
    }

    private static func drawText(_ ctx: CGContext, _ string: String, at origin: CGPoint, color: ScreenshotColor, fontSize: CGFloat, style: TextStyle) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let ns = NSColor(cgColor: color.cgColor) ?? .red
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ns]
        switch style {
        case .plain: break
        case .filled:
            let size = ScreenshotMetrics.textSize(string, fontSize: fontSize)
            let box = CGRect(origin: origin, size: size).insetBy(dx: -5, dy: -2)
            ctx.setFillColor(color.contrast.cgColor(alpha: 0.92))
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 5, cornerHeight: 5, transform: nil)); ctx.fillPath()
        case .outlined:
            // 先画一圈反差色的外描边，再把所选颜色实心填在上面：描边只在字的外侧，不会盖住颜色
            let halo: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ns, .strokeColor: NSColor(cgColor: color.contrast.cgColor) ?? .white, .strokeWidth: 14]
            withText(ctx) { (string as NSString).draw(at: origin, withAttributes: halo) }
        }
        withText(ctx) { (string as NSString).draw(at: origin, withAttributes: attributes) }
    }

    private static func drawMarker(_ ctx: CGContext, center: CGPoint, number: Int, radius: CGFloat, color: ScreenshotColor) {
        let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        ctx.setFillColor(color.cgColor); ctx.fillEllipse(in: circle)
        ctx.setStrokeColor(color.contrast.cgColor(alpha: 0.9)); ctx.setLineWidth(1.5); ctx.strokeEllipse(in: circle.insetBy(dx: 0.75, dy: 0.75))
        let text = "\(number)"
        let fontSize = radius * (text.count > 1 ? 0.95 : 1.15)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize, weight: .bold), .foregroundColor: NSColor(cgColor: color.contrast.cgColor) ?? .white]
        let size = (text as NSString).size(withAttributes: attributes)
        withText(ctx) { (text as NSString).draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes) }
    }

    // MARK: 导出

    /// 导出：把整屏图片按选区裁剪并叠加标注，输出像素与屏幕物理像素一一对应
    static func render(display: CGImage, effects: ScreenshotEffects?, selection: CGRect, scale: CGFloat, objects: [AnnotationObject]) -> CGImage? {
        let snapped = ScreenshotGeometry.snapped(selection, scale: scale)
        let size = ScreenshotGeometry.pixelSize(of: snapped, scale: scale)
        guard size.w > 0, size.h > 0, scale > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size.w, height: size.h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        // 把“整屏点坐标”映射到导出位图：平移到对齐后的选区原点，再放大到物理像素
        ctx.translateBy(x: 0, y: CGFloat(size.h)); ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -snapped.minX, y: -snapped.minY)
        let displayRect = CGRect(x: 0, y: 0, width: CGFloat(display.width) / scale, height: CGFloat(display.height) / scale)
        drawUpright(ctx, display, in: displayRect)
        draw(objects, in: ctx, effects: effects, displayRect: displayRect)
        return ctx.makeImage()
    }

    static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// 以点为单位的 NSImage（像素尺寸 / scale），用于剪贴板与贴图
    static func nsImage(_ image: CGImage, scale: CGFloat) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }
}
