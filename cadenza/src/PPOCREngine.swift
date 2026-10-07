import Foundation
import CoreGraphics

enum PaddleOCRError: Error, Equatable { case runtimeMissing, files, dictionary, output }

extension PaddleOCRError {
    var reason: String {
        switch self {
        case .runtimeMissing: return L10n.tr("ppocr.err.runtime")
        case .files: return L10n.tr("ppocr.err.files")
        case .dictionary: return L10n.tr("ppocr.err.dict")
        case .output: return L10n.tr("ppocr.err.output")
        }
    }
}

/// Reads text on this Mac with a PP-OCR model set installed from the local model list: a detection model, a recognition model
/// and the dictionary. Nothing leaves the Mac. Loading a set checks that the pieces fit together.
final class PaddleOCREngine: OCREngine {
    static let engineID = "ppocr"
    static let detectionFile = "det.onnx", recognitionFile = "rec.onnx", dictionaryFile = "dict.txt"
    static var isAvailable: Bool { OrtModel.isAvailable }

    let id = PaddleOCREngine.engineID
    let uploadsImage = false
    private let detector: OrtModel
    private let recognizer: OrtModel
    private let charset: [String]

    init(directory: URL) throws {
        guard OrtModel.isAvailable else { throw PaddleOCRError.runtimeMissing }
        let fm = FileManager.default
        let det = directory.appendingPathComponent(Self.detectionFile), rec = directory.appendingPathComponent(Self.recognitionFile)
        let dict = directory.appendingPathComponent(Self.dictionaryFile)
        guard fm.fileExists(atPath: det.path), fm.fileExists(atPath: rec.path), fm.fileExists(atPath: dict.path) else { throw PaddleOCRError.files }
        do { detector = try OrtModel(path: det.path); recognizer = try OrtModel(path: rec.path) } catch { throw PaddleOCRError.files }
        // The dictionary has to fit the recognition model, and both models have to answer in the expected shape.
        let height = PPOCR.recognitionHeight, width = PPOCR.recognitionMinWidth
        guard let probe = try? recognizer.run([Float](repeating: 0, count: 3 * height * width), shape: [1, 3, height, width]),
              probe.shape.count == 3, probe.shape[2] > 1 else { throw PaddleOCRError.output }
        guard let table = PPOCR.loadCharset(from: dict, classes: probe.shape[2]) else { throw PaddleOCRError.dictionary }
        charset = table
        // A small, non-square probe (both sides multiples of 32): the map has to come back at the size of the picture.
        guard let map = try? detector.run([Float](repeating: 0, count: 3 * 32 * 64), shape: [1, 3, 32, 64]), map.data.count == 32 * 64 else { throw PaddleOCRError.output }
    }

    /// Used by the model list to decide whether a freshly installed set may be activated.
    static func validate(directory: URL) -> Bool { (try? PaddleOCREngine(directory: directory)) != nil }

    func recognize(_ image: CGImage) async throws -> OCRResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try self.recognizeSynchronously(image)) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static let maxLines = 200

    func recognizeSynchronously(_ image: CGImage) throws -> OCRResult {
        let width = image.width, height = image.height
        guard width >= 8, height >= 8 else { throw OCRError.tooSmall }
        let size = PPOCR.detectionSize(width: width, height: height)
        guard let rgba = PPOCR.renderRGBA(image, width: size.width, height: size.height) else { throw OCRError.failed(PaddleOCRError.output.reason) }
        let input = PPOCR.normalize(rgba: rgba, width: size.width, height: size.height, mean: PPOCR.detectionMean, std: PPOCR.detectionStd)
        let map = try run(detector, input, [1, 3, size.height, size.width])
        guard map.data.count == size.width * size.height else { throw OCRError.localModel(PaddleOCRError.output.reason) }
        let boxes = PPOCR.detectBoxes(map: map.data, width: size.width, height: size.height)
        let scaleX = Double(width) / Double(size.width), scaleY = Double(height) / Double(size.height)
        var lines: [OCRLine] = []
        for box in boxes.prefix(Self.maxLines) {
            let x0 = max(0, Int((box.x0 * scaleX).rounded(.down))), y0 = max(0, Int((box.y0 * scaleY).rounded(.down)))
            let x1 = min(width, Int((box.x1 * scaleX).rounded(.up))), y1 = min(height, Int((box.y1 * scaleY).rounded(.up)))
            guard x1 - x0 >= 1, y1 - y0 >= 1, var crop = image.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)) else { continue }
            if PPOCR.needsRotation(cropWidth: crop.width, cropHeight: crop.height), let turned = PPOCR.rotatedCounterclockwise(crop) { crop = turned }
            let widths = PPOCR.recognitionWidths(cropWidth: crop.width, cropHeight: crop.height)
            guard let pixels = PPOCR.renderRGBA(crop, width: widths.resized, height: PPOCR.recognitionHeight) else { continue }
            let tensor = PPOCR.normalize(rgba: pixels, width: widths.resized, height: PPOCR.recognitionHeight, mean: [0.5, 0.5, 0.5], std: [0.5, 0.5, 0.5], paddedWidth: widths.padded)
            let out = try run(recognizer, tensor, [1, 3, PPOCR.recognitionHeight, widths.padded])
            guard out.shape.count == 3, out.shape[2] == charset.count else { throw OCRError.localModel(PaddleOCRError.output.reason) }
            let decoded = PPOCR.decodeCTC(probabilities: out.data, steps: out.shape[1], classes: out.shape[2], charset: charset)
            if decoded.text.trimmingCharacters(in: .whitespaces).isEmpty || decoded.confidence < 0.5 { continue }
            let rect = CGRect(x: Double(x0) / Double(width), y: 1 - Double(y1) / Double(height), width: Double(x1 - x0) / Double(width), height: Double(y1 - y0) / Double(height))
            lines.append(OCRLine(text: decoded.text, box: rect))
        }
        let joined = OCRLayout.join(lines)
        return OCRResult(text: joined.text, lines: joined.ordered, engine: id)
    }

    private func run(_ model: OrtModel, _ input: [Float], _ shape: [Int]) throws -> OrtModel.Output {
        do { return try model.run(input, shape: shape) } catch { throw OCRError.localModel(PaddleOCRError.output.reason) }
    }
}

/// Keeps the loaded model set between recognitions (loading takes a moment) and drops it when the set changes or is deleted.
enum PaddleOCRCache {
    private static let lock = NSLock()
    private static var cached: (path: String, engine: PaddleOCREngine)?

    static func engine(directory: URL) throws -> PaddleOCREngine {
        lock.lock(); defer { lock.unlock() }
        if let cached, cached.path == directory.path { return cached.engine }
        let engine: PaddleOCREngine
        do { engine = try PaddleOCREngine(directory: directory) }
        catch let error as PaddleOCRError { throw OCRError.localModel(error.reason) }
        cached = (directory.path, engine)
        return engine
    }

    static func unload() { lock.lock(); cached = nil; lock.unlock() }
}
