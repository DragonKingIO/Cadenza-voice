import Foundation
import CoreGraphics

enum OCRLocalFixtures {
    /// A hand-made ONNX model with one Identity node: input "x" float32 [1,2,3] -> output "y" (81 bytes).
    static let identityModel = Data(base64Encoded: "CAhCBAoAEA06RwoQCgF4EgF5IghJZGVudGl0eRIBZ1oXCgF4EhIKEAgBEgwKAggBCgIIAgoCCANiFwoBeRISChAIARIMCgIIAQoCCAIKAggD")!

    static func run(_ c: (String, Bool) -> Void) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ocr-local-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // onnxruntime 封装：不依赖任何真实的识别模型
        if !OrtModel.isAvailable {
            c("本地识别：没有 onnxruntime 头文件的构建会如实报告不可用", (try? OrtModel(path: "/nonexistent")) == nil)
            return
        }
        let modelPath = dir.appendingPathComponent("identity.onnx")
        try? identityModel.write(to: modelPath)
        let model = try? OrtModel(path: modelPath.path)
        c("onnxruntime：能加载手工生成的小模型", model != nil)
        let input: [Float] = [1, 2, 3, 4.5, -6, 0.25]
        let output = model.flatMap { try? $0.run(input, shape: [1, 2, 3]) }
        c("onnxruntime：运行后输出的形状和数值与输入一致", output?.shape == [1, 2, 3] && output?.data == input)
        c("onnxruntime：输入数量与形状不符时报错而不是崩溃", model.map { (try? $0.run([1, 2], shape: [1, 2, 3])) == nil } ?? false)
        c("onnxruntime：形状与模型不符时返回错误", model.map { (try? $0.run(input, shape: [1, 3, 2])) == nil } ?? false)
        c("onnxruntime：文件不存在时加载失败并带原因", { do { _ = try OrtModel(path: dir.appendingPathComponent("missing.onnx").path); return false } catch OrtModelError.load(let reason) { return !reason.isEmpty } catch { return false } }())
        let garbage = dir.appendingPathComponent("garbage.onnx"); try? Data("not a model".utf8).write(to: garbage)
        c("onnxruntime：损坏的文件加载失败，不崩溃", { do { _ = try OrtModel(path: garbage.path); return false } catch { return true } }())
        let first = model.flatMap { try? $0.run(input, shape: [1, 2, 3]) }
        let second = model.flatMap { try? $0.run(input.map { $0 * 2 }, shape: [1, 2, 3]) }
        c("onnxruntime：同一个模型可以连续运行多次", first?.data == input && second?.data == input.map { $0 * 2 })
        runPipeline(c, dir: dir)
        runCatalog(c, dir: dir)
    }


    /// Acceptance test with a REAL PP-OCR model set: `Cadenza --selftest-local-ocr-real`. The set is the one installed from
    /// Settings → Text Recognition, or the folder in CADENZA_OCR_MODEL_DIR (det.onnx, rec.onnx, dict.txt). Nothing is
    /// downloaded by this command.
    static func real() -> Int32 {
        guard OrtModel.isAvailable else { print("[ocr-real] this build has no onnxruntime"); return 2 }
        let center = LocalModelCenter.shared
        let installed = center.installedEntries.first(where: LocalModelCatalog.isOCR).flatMap { center.modelDir($0.id) }
        guard let dir = ProcessInfo.processInfo.environment["CADENZA_OCR_MODEL_DIR"].map({ URL(fileURLWithPath: $0) }) ?? installed else {
            print("[ocr-real] no model: install one in Settings → Text Recognition, or set CADENZA_OCR_MODEL_DIR"); return 2
        }
        let engine: PaddleOCREngine
        do { engine = try PaddleOCREngine(directory: dir) } catch { print("[ocr-real] FAIL load: \((error as? PaddleOCRError)?.reason ?? "\(error)")"); return 1 }
        print("[ocr-real] loaded \(dir.lastPathComponent)")
        var failures = 0
        let cases: [(name: String, image: CGImage?, expect: [String])] = [
            ("english", OCRTestImage.make(), ["OCR", "TEST", "123"]),
            ("chinese", ScreenshotFixtures.textImage("你好，世界 2026 年报告"), ["你好", "世界", "2026"]),
            ("mixed", ScreenshotFixtures.textImage("Meeting notes: 随言 voice input", size: 40), ["Meeting", "voice"])]
        for item in cases {
            guard let image = item.image else { print("[ocr-real] FAIL \(item.name): no test image"); failures += 1; continue }
            let started = Date()
            do {
                let result = try engine.recognizeSynchronously(image)
                let text = result.text.replacingOccurrences(of: "\n", with: " | ")
                let ok = item.expect.allSatisfy { result.text.localizedCaseInsensitiveContains($0) }
                if !ok { failures += 1 }
                print("[ocr-real] \(ok ? "PASS" : "FAIL") \(item.name): \"\(text)\" lines=\(result.lines.count) \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            } catch { failures += 1; print("[ocr-real] FAIL \(item.name): \(error)") }
        }
        print("[ocr-real] done failures=\(failures)")
        return failures == 0 ? 0 : 1
    }

    /// Acceptance of the whole path with the real files: `Cadenza --selftest-local-ocr-download` downloads the built-in model set
    /// with the app's own downloader into a temporary folder (about 16 MB), checks it, activates it and reads a picture.
    static func realDownload() -> Int32 {
        guard OrtModel.isAvailable else { print("[ocr-download] this build has no onnxruntime"); return 2 }
        guard let entry = LocalModelCatalog.builtin.first(where: LocalModelCatalog.isOCR) else { print("[ocr-download] no built-in text recognition model"); return 2 }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let center = LocalModelCenter(root: root)
        center.validator = { dir, e in LocalModelCatalog.isOCR(e) ? PaddleOCREngine.validate(directory: dir) : true }
        center.download(entry)
        let started = Date()
        var lastPercent = -1
        while Date().timeIntervalSince(started) < 180 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            switch center.state(entry.id) {
            case .installed: break
            case .failed(let message): print("[ocr-download] FAIL download: \(message)"); return 1
            case .downloading(let done, let total): let p = Int(Double(done) / Double(max(total, 1)) * 100); if p / 25 != lastPercent / 25 { print("[ocr-download] downloading \(p)%"); lastPercent = p }; continue
            default: continue
            }
            break
        }
        guard center.isReady(entry.id), let dir = center.modelDir(entry.id) else { print("[ocr-download] FAIL: not installed after \(Int(Date().timeIntervalSince(started))) s, state \(center.state(entry.id))"); return 1 }
        print("[ocr-download] installed in \(Int(Date().timeIntervalSince(started))) s: \((try? FileManager.default.contentsOfDirectory(atPath: dir.path).sorted().joined(separator: ", ")) ?? "?")")
        guard let image = OCRTestImage.make(), let result = try? PaddleOCREngine(directory: dir).recognizeSynchronously(image) else { print("[ocr-download] FAIL: could not read the test picture"); return 1 }
        let ok = result.text.uppercased().contains("123")
        print("[ocr-download] \(ok ? "PASS" : "FAIL") read \"\(result.text)\"")
        center.delete(entry.id)
        print("[ocr-download] deleted: \(center.state(entry.id) == .notInstalled)")
        return ok ? 0 : 1
    }

    // MARK: 手工生成 ONNX 模型（输出固定的常量），用来在没有真实识别模型时检查整条流程的衔接

    private enum PB {
        static func varint(_ n: Int) -> Data { var v = UInt64(n), out = Data(); while true { let b = UInt8(v & 0x7f); v >>= 7; if v != 0 { out.append(b | 0x80) } else { out.append(b); return out } } }
        static func key(_ field: Int, _ wire: Int) -> Data { varint((field << 3) | wire) }
        static func bytes(_ field: Int, _ payload: Data) -> Data { key(field, 2) + varint(payload.count) + payload }
        static func int(_ field: Int, _ n: Int) -> Data { key(field, 0) + varint(n) }
        static func string(_ field: Int, _ s: String) -> Data { bytes(field, Data(s.utf8)) }
        static func valueInfo(_ name: String, _ dims: [Int]) -> Data {
            let dim = dims.reduce(Data()) { $0 + bytes(1, int(1, $1)) }
            return string(1, name) + bytes(2, bytes(1, int(1, 1) + bytes(2, dim)))
        }
    }

    /// A model that ignores its input `x` (float32, `inputShape`) and always answers `output` (float32, `outputShape`).
    static func constantModel(inputShape: [Int], outputShape: [Int], output: [Float]) -> Data {
        var raw = Data(); for f in output { raw.append(contentsOf: withUnsafeBytes(of: f.bitPattern.littleEndian) { Array($0) }) }
        let tensor = outputShape.reduce(Data()) { $0 + PB.int(1, $1) } + PB.int(2, 1) + PB.bytes(9, raw)
        let attribute = PB.string(1, "value") + PB.bytes(5, tensor) + PB.int(20, 4)
        let node = PB.string(2, "y") + PB.string(4, "Constant") + PB.bytes(5, attribute)
        let graph = PB.bytes(1, node) + PB.string(2, "g") + PB.bytes(11, PB.valueInfo("x", inputShape)) + PB.bytes(12, PB.valueInfo("y", outputShape))
        return PB.int(1, 8) + PB.bytes(8, PB.string(1, "") + PB.int(2, 13)) + PB.bytes(7, graph)
    }

    /// Detection map for a 64×32 picture: one confident text line, one tiny speck and one faint patch.
    static func detectionMap() -> [Float] {
        var map = [Float](repeating: 0, count: 32 * 64)
        for y in 10...21 { for x in 8...55 { map[y * 64 + x] = 0.9 } }
        for y in 2...3 { for x in 60...61 { map[y * 64 + x] = 0.95 } }
        return map
    }

    /// Recognition output for the line above: classes are blank, a, b, c, space; the best path reads "abc".
    static func recognitionOutput(path: [Int] = [1, 1, 0, 2, 2, 0, 3, 3, 0, 0], confidence: Float = 0.95) -> [Float] {
        var out = [Float](); let classes = 5
        for best in path { for c in 0..<classes { out.append(c == best ? confidence : (1 - confidence) / Float(classes - 1)) } }
        return out
    }

    static func installModelSet(into dir: URL, dictionary: String = "a\nb\nc\n", recognitionPath: [Int] = [1, 1, 0, 2, 2, 0, 3, 3, 0, 0], confidence: Float = 0.95, detection: (shape: [Int], data: [Float])? = nil, withRecognizer: Bool = true) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let det = constantModel(inputShape: [1, 3, 32, 64], outputShape: detection?.shape ?? [1, 1, 32, 64], output: detection?.data ?? detectionMap())
        try? det.write(to: dir.appendingPathComponent(PaddleOCREngine.detectionFile))
        let out = recognitionOutput(path: recognitionPath, confidence: confidence)
        // The engine first probes the recognizer with a [1,3,48,320] picture, then reads each line at the same size here.
        let rec = constantModel(inputShape: [1, 3, 48, 320], outputShape: [1, recognitionPath.count, 5], output: out)
        if withRecognizer { try? rec.write(to: dir.appendingPathComponent(PaddleOCREngine.recognitionFile)) }
        try? Data(dictionary.utf8).write(to: dir.appendingPathComponent(PaddleOCREngine.dictionaryFile))
    }

    private struct FakeEngine: OCREngine {
        var id: String; var result: Result<OCRResult, OCRError>
        var uploadsImage: Bool { false }
        func recognize(_ image: CGImage) async throws -> OCRResult { try result.get() }
    }

    static func runPipeline(_ c: (String, Bool) -> Void, dir: URL) {
        // 纯函数：缩放、归一化、检测框、解码、字典
        c("PP-OCR：检测前缩放到 32 的倍数，长边不超过 960", PPOCR.detectionSize(width: 1920, height: 1080) == (960, 544) && PPOCR.detectionSize(width: 100, height: 50) == (96, 64) && PPOCR.detectionSize(width: 10, height: 10) == (32, 32))
        c("PP-OCR：取整与参考实现一致（四舍六入五成双）", PPOCR.detectionSize(width: 80, height: 48) == (64, 64))
        let red = PPOCR.normalize(rgba: [255, 0, 0, 255], width: 1, height: 1, mean: PPOCR.detectionMean, std: PPOCR.detectionStd)
        c("PP-OCR：归一化按 BGR 顺序，每个通道用各自的均值和方差", red.count == 3 && abs(red[0] - (0 - 0.485) / 0.229) < 1e-5 && abs(red[1] - (0 - 0.456) / 0.224) < 1e-5 && abs(red[2] - (1 - 0.406) / 0.225) < 1e-5)
        let padded = PPOCR.normalize(rgba: [255, 255, 255, 255], width: 1, height: 1, mean: [0.5, 0.5, 0.5], std: [0.5, 0.5, 0.5], paddedWidth: 3)
        c("PP-OCR：识别输入右侧补零，数值落在 -1…1", padded.count == 9 && padded[0] == 1 && padded[1] == 0 && padded[2] == 0 && padded[3] == 1 && padded[6] == 1)

        let boxes = PPOCR.detectBoxes(map: detectionMap(), width: 64, height: 32)
        c("PP-OCR：检测框：只留下可信的文字行，丢掉小斑点", boxes.count == 1)
        if let b = boxes.first { c("PP-OCR：检测框向外扩张（unclip 1.5）并限制在图内", abs(b.x0 - 0.8) < 0.01 && abs(b.y0 - 2.8) < 0.01 && abs(b.x1 - 63.2) < 0.01 && abs(b.y1 - 29.2) < 0.01) } else { c("PP-OCR：检测框向外扩张（unclip 1.5）并限制在图内", false) }
        var two = [Float](repeating: 0, count: 100 * 60)
        for y in 35...44 { for x in 10...49 { two[y * 100 + x] = 0.9 } }
        for y in 5...14 { for x in 10...89 { two[y * 100 + x] = 0.9 } }
        for y in 20...25 { for x in 10...19 { two[y * 100 + x] = 0.5 } }       // 有轮廓但整体不可信
        let ordered = PPOCR.detectBoxes(map: two, width: 100, height: 60)
        c("PP-OCR：检测框：自上而下排序，低分区域被丢弃", ordered.count == 2 && ordered[0].y0 < ordered[1].y0 && abs(ordered[1].x0 - 4) < 0.01 && abs(ordered[1].y1 - 51) < 0.01)
        c("PP-OCR：检测框：空图或全零图没有结果", PPOCR.detectBoxes(map: [Float](repeating: 0, count: 64), width: 8, height: 8).isEmpty && PPOCR.detectBoxes(map: [], width: 0, height: 0).isEmpty)

        c("PP-OCR：识别输入宽度至少 320，长行按比例加宽，窄条不超出", PPOCR.recognitionWidths(cropWidth: 64, cropHeight: 28) == (320, 110) && PPOCR.recognitionWidths(cropWidth: 1000, cropHeight: 40) == (1200, 1200) && PPOCR.recognitionWidths(cropWidth: 3, cropHeight: 50) == (320, 3))
        c("PP-OCR：竖排文字（高 ≥ 1.5 倍宽）先转 90°", PPOCR.needsRotation(cropWidth: 20, cropHeight: 40) && !PPOCR.needsRotation(cropWidth: 40, cropHeight: 40) && !PPOCR.needsRotation(cropWidth: 20, cropHeight: 29))

        let charset = ["blank", "a", "b", "c", " "]
        let decoded = PPOCR.decodeCTC(probabilities: recognitionOutput(), steps: 10, classes: 5, charset: charset)
        c("PP-OCR：CTC 解码：合并重复、去掉空白，得到 abc", decoded.text == "abc" && abs(decoded.confidence - 0.95) < 1e-6)
        c("PP-OCR：CTC 解码：字符之间有空白时重复字符要保留", PPOCR.decodeCTC(probabilities: recognitionOutput(path: [1, 0, 1]), steps: 3, classes: 5, charset: charset).text == "aa")
        c("PP-OCR：CTC 解码：输入长度不够或类别不匹配时返回空而不是崩溃", PPOCR.decodeCTC(probabilities: [0.1], steps: 10, classes: 5, charset: charset) == ("", 0) && PPOCR.decodeCTC(probabilities: recognitionOutput(), steps: 10, classes: 5, charset: ["blank"]) == ("", 0))
        c("PP-OCR：字典：类别数比字典多一个时补上空格", PPOCR.charset(fromDictionary: "a\nb\n", classes: 4) == ["blank", "a", "b", " "] && PPOCR.charset(fromDictionary: "a\nb\n", classes: 3) == ["blank", "a", "b"])
        c("PP-OCR：字典：数量对不上就拒绝，不去猜", PPOCR.charset(fromDictionary: "a\nb\n", classes: 9) == nil)
        c("PP-OCR：字典：保留字典里的空格行并兼容 Windows 换行", PPOCR.charset(fromDictionary: "a\r\n \r\nb\r\n", classes: 4) == ["blank", "a", " ", "b"])

        // 像素：方向与旋转
        let tall = ScreenshotFixtures.bitmapContext(2, 4)
        tall.setFillColor(CGColor(gray: 1, alpha: 1)); tall.fill(CGRect(x: 0, y: 0, width: 2, height: 4))
        tall.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); tall.fill(CGRect(x: 0, y: 3, width: 1, height: 1))     // 左上角红色
        if let image = tall.makeImage(), let px = PPOCR.renderRGBA(image, width: 2, height: 4) {
            c("PP-OCR：像素方向：图片左上角在第 0 行第 0 列", px[0] == 255 && px[1] == 0 && px[2] == 0 && px[(3 * 2) * 4 + 1] == 255)
            if let turned = PPOCR.rotatedCounterclockwise(image), let t = PPOCR.renderRGBA(turned, width: 4, height: 2) {
                c("PP-OCR：逆时针转 90°：尺寸互换，左上角红点转到左下角", turned.width == 4 && turned.height == 2 && t[((1 * 4) + 0) * 4 + 1] == 0 && t[0 * 4 + 1] == 255)
            } else { c("PP-OCR：逆时针转 90°：尺寸互换，左上角红点转到左下角", false) }
        } else { c("PP-OCR：像素方向：图片左上角在第 0 行第 0 列", false) }

        // 整条流程：手工生成的检测 / 识别模型
        let good = dir.appendingPathComponent("good")
        installModelSet(into: good)
        let image = ScreenshotFixtures.baseImage(64, 32)
        let engine = try? PaddleOCREngine(directory: good)
        c("PP-OCR：模型、字典齐全且彼此匹配时可以加载", engine != nil && PaddleOCREngine.validate(directory: good))
        let result = engine.flatMap { try? $0.recognizeSynchronously(image) }
        c("PP-OCR：整条流程：检测 → 裁剪 → 识别，得到 abc 一行，引擎名为 ppocr", result?.text == "abc" && result?.lines.count == 1 && result?.engine == "ppocr")
        if let line = result?.lines.first {
            c("PP-OCR：整条流程：行位置换算为左下角原点的归一化坐标", abs(line.box.minX - 0) < 1e-6 && abs(line.box.width - 1) < 1e-6 && abs(line.box.minY - 0.0625) < 1e-6 && abs(line.box.height - 0.875) < 1e-6)
        } else { c("PP-OCR：整条流程：行位置换算为左下角原点的归一化坐标", false) }
        let lowConfidence = dir.appendingPathComponent("low")
        installModelSet(into: lowConfidence, confidence: 0.3)
        let lowResult = (try? PaddleOCREngine(directory: lowConfidence)).flatMap { try? $0.recognizeSynchronously(image) }
        c("PP-OCR：把握太低的行被丢弃，不输出乱码", lowResult?.lines.isEmpty == true && lowResult?.isEmpty == true)
        let tiny = (try? engine?.recognizeSynchronously(ScreenshotFixtures.baseImage(4, 4))) ?? nil
        c("PP-OCR：太小的图片明确报告过小", tiny == nil && { do { _ = try engine?.recognizeSynchronously(ScreenshotFixtures.baseImage(4, 4)); return false } catch OCRError.tooSmall { return true } catch { return false } }())

        func failure(_ make: (URL) -> Void) -> PaddleOCRError? {
            let d = dir.appendingPathComponent(UUID().uuidString); make(d)
            do { _ = try PaddleOCREngine(directory: d); return nil } catch { return error as? PaddleOCRError }
        }
        c("PP-OCR：缺少识别模型 → 报告文件问题", failure { installModelSet(into: $0, withRecognizer: false) } == .files)
        c("PP-OCR：字典条数与模型不符 → 报告字典问题", failure { installModelSet(into: $0, dictionary: "a\nb\nc\nd\ne\nf\ng\n") } == .dictionary)
        c("PP-OCR：检测模型输出大小不对 → 报告输出问题", failure { installModelSet(into: $0, detection: ([1, 1, 2, 5], [Float](repeating: 0.5, count: 10))) } == .output)
        c("PP-OCR：空文件夹 → 报告文件问题", failure { try? FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) } == .files)

        // 路由：选了本机模型但不能用时，如实回退到 Apple Vision 并说明原因
        let ok = OCRResult(text: "local", lines: [], engine: "ppocr")
        let visionResult = OCRResult(text: "vision", lines: [], engine: "vision")
        var settings = ScreenshotSettings(); settings.ocrEngine = "ppocr"; settings.ocrLocalModel = "m1"
        func route(_ s: ScreenshotSettings, dir: URL?, engine: Result<OCRResult, OCRError>) -> Result<OCRResult, Error>? {
            var router = OCRRouter(settings: s)
            router.local = FakeEngine(id: "vision", result: .success(visionResult))
            router.localModelDirectory = { _ in dir }
            router.localModelEngine = { _ in FakeEngine(id: "ppocr", result: engine) }
            return ScreenshotFixtures.waitFor(20) { try await router.recognize(image) }
        }
        if case .success(let r)? = route(settings, dir: dir, engine: .success(ok)) { c("本机模型识别：用选中的本机模型，不回退、不涉及上传", r.engine == "ppocr" && r.fallbackReason == nil) } else { c("本机模型识别：用选中的本机模型，不回退、不涉及上传", false) }
        if case .success(let r)? = route(settings, dir: nil, engine: .success(ok)) { c("本机模型识别：模型没装 → 改用 Apple Vision 并说明原因", r.engine == "vision" && r.fallbackReason?.isEmpty == false) } else { c("本机模型识别：模型没装 → 改用 Apple Vision 并说明原因", false) }
        if case .success(let r)? = route(settings, dir: dir, engine: .failure(.localModel("x"))) { c("本机模型识别：模型运行失败 → 改用 Apple Vision 并说明原因", r.engine == "vision" && r.fallbackReason?.contains("x") == true) } else { c("本机模型识别：模型运行失败 → 改用 Apple Vision 并说明原因", false) }
        var strict = settings; strict.ocrFallback = false
        if case .failure? = route(strict, dir: nil, engine: .success(ok)) { c("本机模型识别：关闭回退时直接报错，不偷偷换引擎", true) } else { c("本机模型识别：关闭回退时直接报错，不偷偷换引擎", false) }

        // 设置：新字段缺失时用默认值；往返不丢
        let old = try? JSONDecoder().decode(ScreenshotSettings.self, from: Data("{\"ocrEngine\":\"vision\"}".utf8))
        c("文字识别设置：旧配置没有本机模型字段时默认为空", old?.ocrLocalModel == "" && old?.ocrEngine == "vision")
        let round = (try? JSONEncoder().encode(settings)).flatMap { try? JSONDecoder().decode(ScreenshotSettings.self, from: $0) }
        c("文字识别设置：本机模型字段保存后原样读回", round?.ocrEngine == "ppocr" && round?.ocrLocalModel == "m1")
    }

    // MARK: 清单、安装状态、设置与路由的衔接

    static func sampleEntry(id: String = "ppocr-test", version: String = "1.0.0") -> LocalModelEntry {
        func file(_ name: String) -> LocalModelFile { LocalModelFile(name: name, urls: ["https://example.com/\(name)"], sha256: String(repeating: "a", count: 64), size: 1000) }
        return LocalModelEntry(id: id, version: version, displayName: ["en": "Test OCR", "zh-Hans": "测试识别"], summary: ["en": "test", "zh-Hans": "测试"], kind: "ppocr",
                               languages: [], downloadSize: 3000, installedSize: 3000, minAppVersion: "1.0.0", license: "Apache-2.0", changelog: "",
                               files: [file("det.onnx"), file("rec.onnx"), file("dict.txt")], requiredFiles: ["det.onnx", "rec.onnx", "dict.txt"], platforms: ["macos"])
    }

    static func runCatalog(_ c: (String, Bool) -> Void, dir: URL) {
        let entry = sampleEntry()
        c("本机识别模型：条目通过清单校验，属于文字识别家族，不会被当成语音模型", LocalModelCatalog.validate(entry) == nil && LocalModelCatalog.isOCR(entry) && !LocalModelCatalog.usable(entry) && LocalModelCatalog.usableOCR(entry))
        let speech = LocalModelCatalog.builtin[0]
        c("本机识别模型：语音模型不会被当成文字识别模型", !LocalModelCatalog.isOCR(speech) && !LocalModelCatalog.usableOCR(speech) && LocalModelCatalog.usable(speech))
        c("本机识别模型：需要更新软件的条目不可用", !LocalModelCatalog.usableOCR({ var e = entry; e.minAppVersion = "99.0.0"; return e }()))
        c("本机识别模型：和语音模型一起合并进清单，也能被丢弃坏条目", LocalModelCatalog.merge(builtin: LocalModelCatalog.builtin, remote: [entry]).contains { $0.id == entry.id } && !LocalModelCatalog.merge(builtin: [], remote: [{ var e = entry; e.files[0].sha256 = "x"; return e }()]).contains { $0.id == entry.id })

        // 安装状态：用真实的模型管理对象，文件放进它的目录
        let center = LocalModelCenter(root: dir.appendingPathComponent("center"))
        center.testInject(entry)
        c("本机识别模型：没安装时状态为未安装，路由拿不到目录", center.state(entry.id) == .notInstalled && !center.isReady(entry.id))
        installModelSet(into: center.root.appendingPathComponent("\(entry.id)-\(entry.version)"))
        center.testSetInstalled(entry.id, LocalModelInstalled(version: entry.version, previous: nil, installedAt: Date()))
        c("本机识别模型：文件齐全后显示已安装，语音那边的可用列表里没有它", center.isReady(entry.id) && center.state(entry.id) == .installed(version: entry.version) && !center.installedEntries.filter { LocalModelCatalog.usable($0) }.contains { $0.id == entry.id })

        // 设置：只能选已安装、能运行的模型
        let store = ConfigStore(fileURL: dir.appendingPathComponent("config.json"))
        let pipeline = VoicePipeline(configStore: store, input: InputSourceController()); pipeline.selfTestMode = true
        let model = SettingsModel(store: store, pipeline: pipeline)
        model.selectLocalOCRModel("unknown", ready: center.installedEntries)
        c("选择本机识别模型：没安装的 id 不生效", store.config.screenshot.ocrEngine == "vision")
        model.selectLocalOCRModel(speech.id, ready: [speech])
        c("选择本机识别模型：语音模型不能被选作文字识别", store.config.screenshot.ocrEngine == "vision")
        model.selectLocalOCRModel(entry.id, ready: center.installedEntries)
        c("选择本机识别模型：已安装的模型生效，记下引擎和模型 id", store.config.screenshot.ocrEngine == "ppocr" && store.config.screenshot.ocrLocalModel == entry.id)

        // 路由：真实的模型管理对象 + 真实的引擎 + 手工生成的模型，端到端
        PaddleOCRCache.unload(); defer { PaddleOCRCache.unload() }
        let image = ScreenshotFixtures.baseImage(64, 32)
        var router = OCRRouter(settings: store.config.screenshot)
        router.local = FakeEngine(id: "vision", result: .success(OCRResult(text: "vision", lines: [], engine: "vision")))
        router.localModelDirectory = { center.isReady($0) ? center.modelDir($0) : nil }
        if case .success(let r)? = ScreenshotFixtures.waitFor(30, { try await router.recognize(image) }) {
            c("本机识别模型：端到端：模型管理 → 路由 → 引擎 → 结果，识别出 abc", r.text == "abc" && r.engine == "ppocr" && r.fallbackReason == nil)
        } else { c("本机识别模型：端到端：模型管理 → 路由 → 引擎 → 结果，识别出 abc", false) }
        PaddleOCRCache.unload()
        center.delete(entry.id)
        c("本机识别模型：删除后状态回到未安装，路由拿不到目录", center.state(entry.id) == .notInstalled && center.modelDir(entry.id) == nil)
        if case .success(let r)? = ScreenshotFixtures.waitFor(30, { try await router.recognize(image) }) {
            c("本机识别模型：删除后再识别会回退到 Apple Vision 并说明原因", r.engine == "vision" && r.fallbackReason?.isEmpty == false)
        } else { c("本机识别模型：删除后再识别会回退到 Apple Vision 并说明原因", false) }
    }
}
