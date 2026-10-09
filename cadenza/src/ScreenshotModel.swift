import Foundation
import CoreGraphics

// MARK: - 截图：设置、标注数据与选区几何（纯逻辑，不依赖界面，可直接测试）

struct ScreenshotSettings: Codable, Equatable {
    /// 截图快捷键；nil = 不占用任何键（默认），只能从菜单或设置页开始截图
    var trigger: HotkeySpec? = nil
    /// “截图并直接识字”快捷键：框选后不弹工具栏，识别完把文字复制到剪贴板；nil = 不占用任何键
    var ocrTrigger: HotkeySpec? = nil
    /// 文字识别引擎：vision = Apple Vision（本机、免费、离线）；baidu / tencent / google = 云端，必须先明确同意上传图片
    var ocrEngine = "vision"
    /// 云端识别失败、没网或没同意上传时，自动改用本机识别
    var ocrFallback = true
    /// 每个云端引擎各自的“允许上传图片”开关
    var ocrConsent: [String: Bool] = [:]
    /// 每个云端引擎各自的“高精度”开关
    var ocrAccurate: [String: Bool] = [:]
    /// 腾讯云地域
    var ocrTencentRegion = "ap-guangzhou"
    /// Azure: the region of the resource ("eastus") or the address of the resource.
    var ocrAzurePlace = "eastus"
    /// 本机文字识别模型（ocrEngine == "ppocr" 时使用）：在“文字识别”页下载的模型条目 id
    var ocrLocalModel = ""
    /// "My AI models" entry that reads the picture (ocrEngine == "ai").
    var ocrProfileID = ""
    /// 选区外按下 C 复制取色值的格式：0 = RGB，1 = HEX
    var colorFormat = 1

    enum CodingKeys: String, CodingKey { case trigger, ocrTrigger, ocrEngine, ocrFallback, ocrConsent, ocrAccurate, ocrTencentRegion, ocrAzurePlace, ocrLocalModel, ocrProfileID, colorFormat }
    init() {}
    init(from decoder: Decoder) throws {
        let d = try decoder.container(keyedBy: CodingKeys.self)
        trigger = try d.decodeIfPresent(HotkeySpec.self, forKey: .trigger)
        ocrTrigger = try d.decodeIfPresent(HotkeySpec.self, forKey: .ocrTrigger)
        ocrEngine = try d.decodeIfPresent(String.self, forKey: .ocrEngine) ?? "vision"
        ocrFallback = try d.decodeIfPresent(Bool.self, forKey: .ocrFallback) ?? true
        ocrConsent = try d.decodeIfPresent([String: Bool].self, forKey: .ocrConsent) ?? [:]
        ocrAccurate = try d.decodeIfPresent([String: Bool].self, forKey: .ocrAccurate) ?? [:]
        ocrTencentRegion = try d.decodeIfPresent(String.self, forKey: .ocrTencentRegion) ?? "ap-guangzhou"
        ocrAzurePlace = try d.decodeIfPresent(String.self, forKey: .ocrAzurePlace) ?? "eastus"
        ocrLocalModel = try d.decodeIfPresent(String.self, forKey: .ocrLocalModel) ?? ""
        let pid = try d.decodeIfPresent(String.self, forKey: .ocrProfileID) ?? ""
        ocrProfileID = pid.range(of: "^[a-z0-9]{0,16}$", options: .regularExpression) != nil ? pid : ""
        colorFormat = try d.decodeIfPresent(Int.self, forKey: .colorFormat) ?? 1
    }
}

enum SelectionHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

enum ScreenshotGeometry {
    static let minimumSelection: CGFloat = 6

    static func normalized(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func clamp(_ p: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }

    /// 把矩形平移到边界内（保持大小）；比边界还大时缩到边界
    static func clamp(_ r: CGRect, to bounds: CGRect) -> CGRect {
        var out = r
        out.size.width = min(out.width, bounds.width); out.size.height = min(out.height, bounds.height)
        out.origin.x = min(max(out.minX, bounds.minX), bounds.maxX - out.width)
        out.origin.y = min(max(out.minY, bounds.minY), bounds.maxY - out.height)
        return out
    }

    static func center(of handle: SelectionHandle, in r: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        }
    }

    /// 命中检测：优先角点；选区很小时只保留角点，避免把整块选区变成手柄
    static func hitHandle(_ p: CGPoint, in r: CGRect, tolerance: CGFloat = 7) -> SelectionHandle? {
        let small = r.width < 28 || r.height < 28
        let order: [SelectionHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft] + (small ? [] : [.top, .right, .bottom, .left])
        return order.first { h in
            let c = center(of: h, in: r)
            return abs(p.x - c.x) <= tolerance && abs(p.y - c.y) <= tolerance
        }
    }

    /// 拖动手柄后的新选区；可越过对边（自动翻转），限制在边界内，不小于最小尺寸
    static func resize(_ r: CGRect, handle: SelectionHandle, to point: CGPoint, bounds: CGRect) -> CGRect {
        let p = clamp(point, to: bounds)
        var left = r.minX, right = r.maxX, top = r.minY, bottom = r.maxY
        switch handle {
        case .topLeft: left = p.x; top = p.y
        case .top: top = p.y
        case .topRight: right = p.x; top = p.y
        case .right: right = p.x
        case .bottomRight: right = p.x; bottom = p.y
        case .bottom: bottom = p.y
        case .bottomLeft: left = p.x; bottom = p.y
        case .left: left = p.x
        }
        var out = CGRect(x: min(left, right), y: min(top, bottom), width: abs(right - left), height: abs(bottom - top))
        if out.width < minimumSelection { out.size.width = minimumSelection; out.origin.x = min(out.origin.x, bounds.maxX - minimumSelection) }
        if out.height < minimumSelection { out.size.height = minimumSelection; out.origin.y = min(out.origin.y, bounds.maxY - minimumSelection) }
        return out
    }

    /// 工具栏位置：优先在选区下方右对齐；下方放不下放上方；都不行放在选区内部底部。始终限制在屏幕内。
    static func toolbarFrame(selection: CGRect, size: CGSize, bounds: CGRect, gap: CGFloat = 8) -> CGRect {
        var x = selection.maxX - size.width
        x = min(max(x, bounds.minX + gap), bounds.maxX - size.width - gap)
        let below = selection.maxY + gap, above = selection.minY - gap - size.height
        let y: CGFloat
        if below + size.height <= bounds.maxY - gap { y = below }
        else if above >= bounds.minY + gap { y = above }
        else { y = max(bounds.minY + gap, min(selection.maxY - size.height - gap, bounds.maxY - size.height - gap)) }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// 标注工具条位置：优先贴在选区左侧（外侧），其次右侧，再不行放在选区内部左缘；顶端与选区对齐，并避开操作条
    static func paletteFrame(selection: CGRect, size: CGSize, bounds: CGRect, avoiding other: CGRect? = nil, gap: CGFloat = 4) -> CGRect {
        var x = selection.minX - gap - size.width
        if x < bounds.minX + gap { x = selection.maxX + gap }
        if x + size.width > bounds.maxX - gap { x = selection.minX + gap }
        x = min(max(x, bounds.minX + gap), bounds.maxX - size.width - gap)
        var y = max(bounds.minY + gap, min(selection.minY, bounds.maxY - size.height - gap))
        var frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        if let other, frame.intersects(other) {
            y = max(bounds.minY + gap, other.minY - gap - size.height)
            frame.origin.y = y
        }
        return frame
    }

    /// 鼠标下最上层的窗口矩形（列表按从前到后排序）
    static func window(at p: CGPoint, in windows: [CGRect]) -> CGRect? { windows.first { $0.contains(p) } }

    /// 对齐到像素网格，导出时选区边缘不出现半个像素
    static func snapped(_ r: CGRect, scale: CGFloat) -> CGRect {
        let x0 = (r.minX * scale).rounded(.down) / scale, y0 = (r.minY * scale).rounded(.down) / scale
        let x1 = (r.maxX * scale).rounded(.up) / scale, y1 = (r.maxY * scale).rounded(.up) / scale
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    static func pixelSize(of r: CGRect, scale: CGFloat) -> (w: Int, h: Int) { (Int((r.width * scale).rounded()), Int((r.height * scale).rounded())) }
}
