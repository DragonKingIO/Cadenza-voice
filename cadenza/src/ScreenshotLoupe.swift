import AppKit

// MARK: - 取色与放大镜

/// 把整屏图片读成像素缓冲，按物理像素取色。第一次使用时才创建（4K 屏约 33MB），会话结束随画布释放。
final class PixelSampler {
    let width: Int, height: Int
    private var bytes: [UInt8]

    init?(_ image: CGImage) {
        width = image.width; height = image.height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !ok { return nil }
    }

    /// x、y 以图片左上角为原点的物理像素；越界返回 nil
    func color(x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = (y * width + x) * 4          // 位图第 0 行就是最上面一行
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }
}

enum ColorText {
    static func hex(_ c: (r: Int, g: Int, b: Int)) -> String { String(format: "#%02X%02X%02X", c.r, c.g, c.b) }
    static func rgb(_ c: (r: Int, g: Int, b: Int)) -> String { "RGB(\(c.r), \(c.g), \(c.b))" }
    /// format 0 = RGB，1 = HEX
    static func text(_ c: (r: Int, g: Int, b: Int), format: Int) -> String { format == 0 ? rgb(c) : hex(c) }
}

enum LoupeGeometry {
    /// 放大镜取景范围（单侧像素数）与放大倍数
    static let radiusPixels = 7, zoom: CGFloat = 8
    static var boxSize: CGFloat { CGFloat(radiusPixels * 2 + 1) * zoom }

    /// 放大镜方框位置：默认在鼠标右下，靠近边缘时翻到另一侧；`extra` 是方框下面信息条的高度
    static func frame(cursor: CGPoint, bounds: CGRect, extra: CGFloat = 46, offset: CGFloat = 22) -> CGRect {
        let size = boxSize
        var x = cursor.x + offset, y = cursor.y + offset
        if x + size > bounds.maxX - 4 { x = cursor.x - offset - size }
        if y + size + extra > bounds.maxY - 4 { y = cursor.y - offset - size - extra }
        x = min(max(x, bounds.minX + 4), bounds.maxX - size - 4); y = max(y, bounds.minY + 4)
        return CGRect(x: x, y: y, width: size, height: size)
    }

    /// 取景的物理像素范围（可能超出图片，绘制时会被裁掉）
    static func sourcePixels(cursor: CGPoint, scale: CGFloat) -> CGRect {
        let cx = Int((cursor.x * scale).rounded(.down)), cy = Int((cursor.y * scale).rounded(.down))
        return CGRect(x: cx - radiusPixels, y: cy - radiusPixels, width: radiusPixels * 2 + 1, height: radiusPixels * 2 + 1)
    }
}
