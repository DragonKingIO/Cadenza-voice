import AppKit

// MARK: - 标注对象：每个标注都有身份，可选中、移动、缩放、改色、删除，并支持撤销/重做。
// 坐标为整屏点坐标（原点在屏幕左上角、y 向下），锚定在画面上而不是选区上。

enum ScreenshotTool: String, CaseIterable, Identifiable {
    case rectangle, ellipse, arrow, pen, highlighter, mosaic, blur, text, marker, eraser
    var id: String { rawValue }
    var usesColor: Bool { !(self == .mosaic || self == .blur || self == .eraser) }
    /// 粗细档位；马赛克/模糊是强度档位，文字是字号档位，序号是大小档位
    var usesLevel: Bool { self != .eraser }
    var usesFill: Bool { self == .rectangle || self == .ellipse }
    var usesArrowStyle: Bool { self == .arrow }
    var usesTextStyle: Bool { self == .text }
}

enum ArrowStyle: String, CaseIterable { case single, double, line }
enum TextStyle: String, CaseIterable { case plain, filled, outlined }

struct ScreenshotColor: Equatable {
    var r: CGFloat, g: CGFloat, b: CGFloat
    init(r: CGFloat, g: CGFloat, b: CGFloat) { self.r = r; self.g = g; self.b = b }
    /// 0xRRGGBB
    init(hex: UInt32) { self.init(r: CGFloat((hex >> 16) & 0xFF) / 255, g: CGFloat((hex >> 8) & 0xFF) / 255, b: CGFloat(hex & 0xFF) / 255) }
    // 八个精选色：鲜明但不刺眼，互相之间一眼能分清
    static let red = ScreenshotColor(hex: 0xFF453A)
    static let orange = ScreenshotColor(hex: 0xFF9F0A)
    static let yellow = ScreenshotColor(hex: 0xFFD60A)
    static let green = ScreenshotColor(hex: 0x30D158)
    static let blue = ScreenshotColor(hex: 0x0A84FF)
    static let purple = ScreenshotColor(hex: 0xBF5AF2)
    static let black = ScreenshotColor(hex: 0x1C1C1E)
    static let white = ScreenshotColor(hex: 0xFFFFFF)
    static let palette: [ScreenshotColor] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    func cgColor(alpha: CGFloat) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
    /// 感知亮度：用来决定叠在它上面的文字用黑还是白
    var luminance: CGFloat { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    /// 与自己反差大的颜色（文字底色、描边）
    var contrast: ScreenshotColor { luminance > 0.62 ? .black : .white }
    var hex: String { String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded())) }
    /// 稍微提亮：色块上缘的高光
    func lighter(_ amount: CGFloat) -> ScreenshotColor { ScreenshotColor(r: min(1, r + (1 - r) * amount), g: min(1, g + (1 - g) * amount), b: min(1, b + (1 - b) * amount)) }
}

/// 各档位对应的实际尺寸（点）
enum ScreenshotMetrics {
    static let strokeWidths: [CGFloat] = [2, 4, 7]
    static let highlighterWidths: [CGFloat] = [12, 18, 26]
    static let markerRadii: [CGFloat] = [10, 13, 17]
    static let fontSizes: [CGFloat] = [16, 22, 32]
    static let mosaicBlocks: [CGFloat] = [6, 10, 16]
    static let blurRadii: [CGFloat] = [4, 8, 14]
    static func clamp(_ level: Int) -> Int { min(max(level, 0), 2) }
    static func textSize(_ string: String, fontSize: CGFloat) -> CGSize {
        let size = (string as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium)])
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }
}

struct AnnotationObject: Identifiable, Equatable {
    enum Shape: Equatable {
        case rectangle(CGRect), ellipse(CGRect)
        case line(CGPoint, CGPoint)            // 箭头与直线（样式见 arrowStyle）
        case pen([CGPoint]), highlighter([CGPoint])
        case mosaic(CGRect), blur(CGRect)
        case text(String, CGPoint)             // 原点为文字块左上角
        case marker(CGPoint, Int)              // 圆心与序号
    }
    var id = UUID()
    var shape: Shape
    var color: ScreenshotColor = .red
    var level = 1
    var filled = false
    var arrowStyle: ArrowStyle = .single
    var textStyle: TextStyle = .plain

    var stroke: CGFloat { ScreenshotMetrics.strokeWidths[ScreenshotMetrics.clamp(level)] }
    var highlighterWidth: CGFloat { ScreenshotMetrics.highlighterWidths[ScreenshotMetrics.clamp(level)] }
    var markerRadius: CGFloat { ScreenshotMetrics.markerRadii[ScreenshotMetrics.clamp(level)] }
    var fontSize: CGFloat { ScreenshotMetrics.fontSizes[ScreenshotMetrics.clamp(level)] }

    /// 是否使用颜色（马赛克与模糊没有颜色）
    var usesColor: Bool { switch shape { case .mosaic, .blur: return false; default: return true } }

    // MARK: 几何

    var bounds: CGRect {
        switch shape {
        case .rectangle(let r), .ellipse(let r), .mosaic(let r), .blur(let r): return r.standardized
        case .line(let a, let b): return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).insetBy(dx: -stroke * 2, dy: -stroke * 2)
        case .pen(let p): return Self.box(of: p).insetBy(dx: -stroke, dy: -stroke)
        case .highlighter(let p): return Self.box(of: p).insetBy(dx: -highlighterWidth / 2, dy: -highlighterWidth / 2)
        case .text(let s, let o): return CGRect(origin: o, size: ScreenshotMetrics.textSize(s, fontSize: fontSize)).insetBy(dx: -4, dy: -2)
        case .marker(let c, _): return CGRect(x: c.x - markerRadius, y: c.y - markerRadius, width: markerRadius * 2, height: markerRadius * 2)
        }
    }

    static func box(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 点到线段的距离
    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// 命中检测：线条类按到线的距离，空心图形按到边的距离，实心图形/马赛克/文字按区域
    func hit(_ p: CGPoint, tolerance t: CGFloat = 6) -> Bool {
        switch shape {
        case .rectangle(let r0):
            let r = r0.standardized
            if filled { return r.insetBy(dx: -t, dy: -t).contains(p) }
            return r.insetBy(dx: -t - stroke / 2, dy: -t - stroke / 2).contains(p) && !r.insetBy(dx: t + stroke / 2, dy: t + stroke / 2).contains(p)
        case .ellipse(let r0):
            let r = r0.standardized
            guard r.width > 0, r.height > 0 else { return false }
            let a = r.width / 2, b = r.height / 2, nx = (p.x - r.midX) / a, ny = (p.y - r.midY) / b, d = sqrt(nx * nx + ny * ny)
            if filled { return d <= 1 + t / min(a, b) }
            return abs(d - 1) * min(a, b) <= t + stroke / 2
        case .line(let a, let b): return Self.distance(p, toSegment: a, b) <= t + stroke / 2
        case .pen(let pts): return Self.hitPolyline(p, pts, t + stroke / 2)
        case .highlighter(let pts): return Self.hitPolyline(p, pts, highlighterWidth / 2 + 2)
        case .mosaic(let r), .blur(let r): return r.standardized.contains(p)
        case .text: return bounds.contains(p)
        case .marker(let c, _): return hypot(p.x - c.x, p.y - c.y) <= markerRadius + 3
        }
    }

    private static func hitPolyline(_ p: CGPoint, _ pts: [CGPoint], _ t: CGFloat) -> Bool {
        if pts.count == 1 { return hypot(p.x - pts[0].x, p.y - pts[0].y) <= t }
        return zip(pts, pts.dropFirst()).contains { distance(p, toSegment: $0, $1) <= t }
    }

    // MARK: 编辑

    func translated(by d: CGSize) -> AnnotationObject {
        var o = self
        func mv(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.width, y: p.y + d.height) }
        switch shape {
        case .rectangle(let r): o.shape = .rectangle(r.offsetBy(dx: d.width, dy: d.height))
        case .ellipse(let r): o.shape = .ellipse(r.offsetBy(dx: d.width, dy: d.height))
        case .mosaic(let r): o.shape = .mosaic(r.offsetBy(dx: d.width, dy: d.height))
        case .blur(let r): o.shape = .blur(r.offsetBy(dx: d.width, dy: d.height))
        case .line(let a, let b): o.shape = .line(mv(a), mv(b))
        case .pen(let p): o.shape = .pen(p.map(mv))
        case .highlighter(let p): o.shape = .highlighter(p.map(mv))
        case .text(let s, let origin): o.shape = .text(s, mv(origin))
        case .marker(let c, let n): o.shape = .marker(mv(c), n)
        }
        return o
    }

    /// 可用矩形手柄缩放的图形
    var resizableRect: CGRect? {
        switch shape { case .rectangle(let r), .ellipse(let r), .mosaic(let r), .blur(let r): return r.standardized; default: return nil }
    }
    func withRect(_ r: CGRect) -> AnnotationObject {
        var o = self
        switch shape {
        case .rectangle: o.shape = .rectangle(r)
        case .ellipse: o.shape = .ellipse(r)
        case .mosaic: o.shape = .mosaic(r)
        case .blur: o.shape = .blur(r)
        default: break
        }
        return o
    }
    /// 直线的两个端点
    var endpoints: (CGPoint, CGPoint)? { if case .line(let a, let b) = shape { return (a, b) }; return nil }
    func withEndpoint(_ index: Int, _ p: CGPoint) -> AnnotationObject {
        guard case .line(let a, let b) = shape else { return self }
        var o = self; o.shape = index == 0 ? .line(p, b) : .line(a, p); return o
    }

    /// 序号标记的号码；非标记返回 nil
    var markerNumber: Int? { if case .marker(_, let n) = shape { return n }; return nil }
    var textValue: String? { if case .text(let s, _) = shape { return s }; return nil }
}

// MARK: - 约束与对齐（按住 Shift）

enum ScreenshotConstraint {
    /// 把终点约束成相对起点的正方形（边长取较长一边）
    static func square(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y, side = max(abs(dx), abs(dy))
        return CGPoint(x: a.x + (dx < 0 ? -side : side), y: a.y + (dy < 0 ? -side : side))
    }
    /// 直线按 45° 的整数倍对齐
    static func snapAngle(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y, length = hypot(dx, dy)
        guard length > 0 else { return b }
        let step = CGFloat.pi / 4, angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: a.x + cos(angle) * length, y: a.y + sin(angle) * length)
    }
    /// 保持宽高比缩放：返回满足比例的新矩形（以 anchor 角固定）
    static func lockAspect(_ r: CGRect, original: CGRect, handle: SelectionHandle) -> CGRect {
        guard original.width > 0, original.height > 0 else { return r }
        let ratio = original.width / original.height
        var out = r
        switch handle {
        case .top, .bottom: out.size.width = r.height * ratio; out.origin.x = original.midX - out.width / 2
        case .left, .right: out.size.height = r.width / ratio; out.origin.y = original.midY - out.height / 2
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            let w = max(r.width, r.height * ratio), h = w / ratio
            out.size = CGSize(width: w, height: h)
            out.origin.x = (handle == .topLeft || handle == .bottomLeft) ? original.maxX - w : original.minX
            out.origin.y = (handle == .topLeft || handle == .topRight) ? original.maxY - h : original.minY
        }
        return out
    }
}

// MARK: - 撤销 / 重做

struct AnnotationHistory {
    private(set) var undoStack: [[AnnotationObject]] = []
    private(set) var redoStack: [[AnnotationObject]] = []
    static let limit = 100
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// 在修改之前调用：记下修改前的状态
    mutating func record(_ before: [AnnotationObject]) {
        undoStack.append(before); if undoStack.count > Self.limit { undoStack.removeFirst() }
        redoStack.removeAll()
    }
    mutating func undo(current: [AnnotationObject]) -> [AnnotationObject]? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current); return previous
    }
    mutating func redo(current: [AnnotationObject]) -> [AnnotationObject]? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current); return next
    }
    mutating func reset() { undoStack.removeAll(); redoStack.removeAll() }
}
