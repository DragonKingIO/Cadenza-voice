import Foundation
import CoreGraphics

/// Pre- and post-processing for the PP-OCR text detection and recognition models. Everything here is a pure function of its
/// inputs (no model, no files except the dictionary), so it can be tested with synthetic data.
///
/// The steps follow the reference pipeline of the PaddleOCR project: the detection model finds text lines on a probability
/// map, each line is cut out and read by the recognition model, and the characters are read off with CTC greedy decoding.
enum PPOCR {
    /// A rectangle in pixels, origin top-left.
    struct Box: Equatable {
        var x0: Double, y0: Double, x1: Double, y1: Double
        var width: Double { x1 - x0 }
        var height: Double { y1 - y0 }
    }

    // MARK: Detection

    static let detectionLimitSide = 960

    /// Size the picture is resized to before detection: the long side is limited, and both sides become a multiple of 32.
    static func detectionSize(width: Int, height: Int, limit: Int = detectionLimitSide) -> (width: Int, height: Int) {
        var ratio = 1.0
        if max(width, height) > limit { ratio = Double(limit) / Double(max(width, height)) }
        func snap(_ value: Int) -> Int {
            let scaled = Int(Double(value) * ratio)
            return max(Int((Double(scaled) / 32).rounded(.toNearestOrEven)) * 32, 32)
        }
        return (snap(width), snap(height))
    }

    static let detectionMean: [Float] = [0.485, 0.456, 0.406]
    static let detectionStd: [Float] = [0.229, 0.224, 0.225]

    /// RGBA bytes → planar float tensor (channels, height, width). The channel order is BGR, as OpenCV hands pictures to PaddleOCR.
    static func normalize(rgba: [UInt8], width: Int, height: Int, mean: [Float], std: [Float], paddedWidth: Int? = nil) -> [Float] {
        let outWidth = paddedWidth ?? width, plane = outWidth * height
        var out = [Float](repeating: 0, count: 3 * plane)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4, o = y * outWidth + x
                out[o] = (Float(rgba[i + 2]) / 255 - mean[0]) / std[0]
                out[plane + o] = (Float(rgba[i + 1]) / 255 - mean[1]) / std[1]
                out[2 * plane + o] = (Float(rgba[i]) / 255 - mean[2]) / std[2]
            }
        }
        return out
    }

    /// Finds text lines on the detection model's probability map (values 0…1, `width` × `height`). Each connected group of
    /// confident pixels becomes one rectangle, which is then grown outwards (the model predicts a shrunken core of each line).
    /// Rectangles are returned in map pixels, top to bottom and left to right.
    static func detectBoxes(map: [Float], width: Int, height: Int, threshold: Float = 0.3, boxThreshold: Float = 0.6,
                            unclipRatio: Double = 1.5, minSide: Double = 3, maxBoxes: Int = 1000) -> [Box] {
        guard width > 0, height > 0, map.count >= width * height else { return [] }
        var visited = [Bool](repeating: false, count: width * height)
        var boxes: [Box] = []
        var stack: [Int] = []
        for start in 0..<(width * height) where !visited[start] && map[start] > threshold {
            visited[start] = true; stack.append(start)
            var minX = width, maxX = -1, minY = height, maxY = -1
            while let p = stack.popLast() {
                let x = p % width, y = p / width
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for dy in -1...1 {
                    let ny = y + dy
                    if ny < 0 || ny >= height { continue }
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx
                        if nx < 0 || nx >= width { continue }
                        let q = ny * width + nx
                        if !visited[q] && map[q] > threshold { visited[q] = true; stack.append(q) }
                    }
                }
            }
            let w = Double(maxX - minX + 1), h = Double(maxY - minY + 1)
            if min(w, h) < minSide { continue }
            var sum: Float = 0
            for y in minY...maxY { for x in minX...maxX { sum += map[y * width + x] } }
            if sum / Float(w * h) < boxThreshold { continue }
            let grow = (w * h * unclipRatio) / (2 * (w + h))
            var box = Box(x0: Double(minX) - grow, y0: Double(minY) - grow, x1: Double(maxX + 1) + grow, y1: Double(maxY + 1) + grow)
            box.x0 = max(0, box.x0); box.y0 = max(0, box.y0); box.x1 = min(Double(width), box.x1); box.y1 = min(Double(height), box.y1)
            if min(box.width, box.height) < minSide + 2 { continue }
            boxes.append(box)
            if boxes.count >= maxBoxes { break }
        }
        return boxes.sorted { ($0.y0, $0.x0) < ($1.y0, $1.x0) }
    }

    // MARK: Recognition

    static let recognitionHeight = 48
    static let recognitionMinWidth = 320
    static let recognitionMaxWidth = 4800

    /// Width of the recognition input for a cut-out line: at least 320, wider for long lines, and the width the line itself
    /// is resized to (the rest is padded with zeros).
    static func recognitionWidths(cropWidth: Int, cropHeight: Int) -> (padded: Int, resized: Int) {
        let ratio = Double(cropWidth) / Double(max(cropHeight, 1))
        let maxRatio = max(Double(recognitionMinWidth) / Double(recognitionHeight), ratio)
        let padded = min(max(Int(Double(recognitionHeight) * maxRatio), 1), recognitionMaxWidth)
        let resized = min(padded, max(Int((Double(recognitionHeight) * ratio).rounded(.up)), 1))
        return (padded, resized)
    }

    /// A line this much taller than wide is vertical text: it is turned a quarter turn before it is read.
    static func needsRotation(cropWidth: Int, cropHeight: Int) -> Bool { Double(cropHeight) / Double(max(cropWidth, 1)) >= 1.5 }

    /// CTC greedy decoding: best class per time step, repeats merged, blanks (class 0) dropped.
    /// `charset[i]` is the text of class `i` (so `charset[0]` is the blank).
    static func decodeCTC(probabilities: [Float], steps: Int, classes: Int, charset: [String]) -> (text: String, confidence: Double) {
        guard steps > 0, classes > 1, probabilities.count >= steps * classes, charset.count >= classes else { return ("", 0) }
        var text = "", total = 0.0, kept = 0, previous = -1
        for t in 0..<steps {
            var best = 0, bestValue = probabilities[t * classes]
            for c in 1..<classes where probabilities[t * classes + c] > bestValue { best = c; bestValue = probabilities[t * classes + c] }
            if best != 0 && best != previous { text += charset[best]; total += Double(bestValue); kept += 1 }
            previous = best
        }
        return (text, kept == 0 ? 0 : total / Double(kept))
    }

    /// Reads the dictionary (one character per line) and returns the class table: the blank first, the characters, and a
    /// trailing space when the model has one more class than the dictionary needs. nil when the counts cannot match.
    static func loadCharset(from url: URL, classes: Int) -> [String]? {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        return charset(fromDictionary: text, classes: classes)
    }

    static func charset(fromDictionary text: String, classes: Int) -> [String]? {
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if lines.last == "" { lines.removeLast() }
        let table = ["blank"] + lines
        if table.count == classes { return table }
        if table.count + 1 == classes { return table + [" "] }
        return nil
    }

    // MARK: Pixels

    /// Draws a picture (or part of it) at the given size into RGBA bytes on a white background.
    static func renderRGBA(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    /// The picture turned a quarter turn counterclockwise (used for vertical text).
    static func rotatedCounterclockwise(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: h, height: w, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: h, height: w))
        ctx.translateBy(x: CGFloat(h), y: 0); ctx.rotate(by: .pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
