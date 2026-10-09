import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision
import CoreImage
import CryptoKit
import AppKit

// MARK: - OCR：引擎抽象 + Apple Vision（本机、免费、离线）+ 云端（百度、腾讯、Google）
// 云端引擎必须先由用户在“文字识别”页明确允许上传图片；失败、没网或没同意时自动改用本机识别。

struct OCRLine: Equatable {
    var text: String
    /// 归一化坐标：原点在左下角，范围 0...1；云端没返回位置时为 .zero
    var box: CGRect
}

struct ScannedCode: Equatable {
    var payload: String
    var symbology: String
    var box: CGRect
    var isURL: Bool {
        guard let url = URL(string: payload.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
    }
}

struct OCRResult: Equatable {
    var text: String
    var lines: [OCRLine]
    /// 实际产生结果的引擎：vision / baidu / tencent / google
    var engine: String
    var codes: [ScannedCode] = []
    /// 云端不可用而改用本机时的原因（界面会如实告诉用户）
    var fallbackReason: String?
    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// 所有行都有位置信息，才能在截图上叠加可选文字
    var hasBoxes: Bool { !lines.isEmpty && lines.allSatisfy { $0.box.width > 0 && $0.box.height > 0 } }
}

protocol OCREngine {
    var id: String { get }
    /// 图片是否会离开这台 Mac（决定是否需要用户同意）
    var uploadsImage: Bool { get }
    func recognize(_ image: CGImage) async throws -> OCRResult
}

enum OCRError: LocalizedError, Equatable {
    case failed(String), unknownEngine, tooSmall, localModel(String)
    /// The AI model could not be used for pictures (a name, then what to do).
    case ai(String, String)
    case noConsent(String), noCredentials(String), offline
    case auth(String, String), quota(String, String), service(String, String), network(String, String), invalidResponse(String)
    var errorDescription: String? {
        switch self {
        case .failed(let m): return L10n.format("screenshot.ocr.failed", m)
        case .unknownEngine: return L10n.tr("screenshot.ocr.unknownEngine")
        case .tooSmall: return L10n.tr("screenshot.ocr.err.tooSmall")
        case .localModel(let m): return L10n.format("screenshot.ocr.err.localModel", m)
        case .ai(let p, let m): return L10n.format("screenshot.ocr.err.ai", p, m)
        case .noConsent(let p): return L10n.format("screenshot.ocr.err.noConsent", p)
        case .noCredentials(let p): return L10n.format("screenshot.ocr.err.noCredentials", p)
        case .offline: return L10n.tr("screenshot.ocr.err.offline")
        case .auth(let p, let m): return L10n.format("screenshot.ocr.err.auth", p, m)
        case .quota(let p, let m): return L10n.format("screenshot.ocr.err.quota", p, m)
        case .service(let p, let m): return L10n.format("screenshot.ocr.err.service", p, m)
        case .network(let p, let m): return L10n.format("screenshot.ocr.err.network", p, m)
        case .invalidResponse(let p): return L10n.format("screenshot.ocr.err.invalid", p)
        }
    }
}

// MARK: 阅读顺序

/// 把识别出的行排成阅读顺序：自上而下；同一行里的片段（如分栏）自左向右，用空格连接
enum OCRLayout {
    static func join(_ lines: [OCRLine]) -> (text: String, ordered: [OCRLine]) {
        let nonEmpty = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        // 没有位置信息（云端只给文字）时保持原顺序
        guard nonEmpty.allSatisfy({ $0.box.height > 0 }) else { return (nonEmpty.map(\.text).joined(separator: "\n"), nonEmpty) }
        let sorted = nonEmpty.sorted { $0.box.midY > $1.box.midY }
        var rows: [[OCRLine]] = []
        for line in sorted {
            if var last = rows.last, let anchor = last.first, abs(anchor.box.midY - line.box.midY) < min(anchor.box.height, line.box.height) * 0.5 {
                last.append(line); rows[rows.count - 1] = last
            } else { rows.append([line]) }
        }
        let ordered = rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }
        let text = rows.map { row in row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }.joined(separator: "\n")
        return (text, ordered)
    }
}

// MARK: 本机：Apple Vision

struct VisionOCREngine: OCREngine {
    let id = "vision"
    let uploadsImage = false

    func recognize(_ image: CGImage) async throws -> OCRResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true      // 中英文混排、日韩等无需手动选择
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                    let lines: [OCRLine] = (request.results ?? []).compactMap { obs in
                        guard let candidate = obs.topCandidates(1).first else { return nil }
                        return OCRLine(text: candidate.string, box: obs.boundingBox)
                    }
                    let joined = OCRLayout.join(lines)
                    continuation.resume(returning: OCRResult(text: joined.text, lines: joined.ordered, engine: "vision"))
                } catch {
                    continuation.resume(throwing: OCRError.failed(error.localizedDescription))
                }
            }
        }
    }
}

/// 二维码/条码：始终在本机识别
enum BarcodeScanner {
    static func scan(_ image: CGImage) async -> [ScannedCode] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var codes = visionCodes(image)
                // Vision's barcode detector found nothing (or failed): some systems and virtual machines cannot run it, so try the
                // QR detector of Core Image, which runs on the CPU everywhere. Normal pictures without a code cost a few milliseconds.
                if codes.isEmpty { codes = coreImageQRCodes(image) }
                continuation.resume(returning: codes)
            }
        }
    }

    private static func visionCodes(_ image: CGImage) -> [ScannedCode] {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        var seen = Set<String>()
        return (request.results ?? []).compactMap { obs in
            guard let payload = obs.payloadStringValue, !payload.isEmpty, seen.insert(payload).inserted else { return nil }
            return ScannedCode(payload: payload, symbology: obs.symbology.rawValue, box: obs.boundingBox)
        }
    }

    static func coreImageQRCodes(_ image: CGImage) -> [ScannedCode] {
        guard image.width > 0, image.height > 0,
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return [] }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        var seen = Set<String>()
        return detector.features(in: CIImage(cgImage: image)).compactMap { feature in
            guard let qr = feature as? CIQRCodeFeature, let payload = qr.messageString, !payload.isEmpty, seen.insert(payload).inserted else { return nil }
            // Same convention as Vision: normalized, origin at the lower left.
            let box = CGRect(x: qr.bounds.minX / width, y: qr.bounds.minY / height, width: qr.bounds.width / width, height: qr.bounds.height / height)
            return ScannedCode(payload: payload, symbology: VNBarcodeSymbology.qr.rawValue, box: box)
        }
    }
}

// MARK: 云端：公共部分

enum OCRProvider: String, CaseIterable, Identifiable {
    case baidu, tencent, google, azure, mistral
    var id: String { rawValue }
    var title: String { L10n.tr("ocr.provider." + rawValue) }
    /// (钥匙串字段名, 显示名的本地化键)
    var credentialFields: [(String, String)] {
        switch self {
        case .baidu: return [("apikey", "ocr.field.apiKey"), ("secretkey", "ocr.field.secretKey")]
        case .tencent: return [("secretid", "ocr.field.secretId"), ("secretkey", "ocr.field.secretKey")]
        case .google, .azure, .mistral: return [("apikey", "ocr.field.apiKey")]
        }
    }
    var supportsAccurate: Bool { [.baidu, .tencent].contains(self) }
    var consoleURL: String {
        switch self {
        case .baidu: return "https://console.bce.baidu.com/ai/#/ai/ocr/overview/index"
        case .tencent: return "https://console.cloud.tencent.com/ocr/overview"
        case .google: return "https://console.cloud.google.com/apis/library/vision.googleapis.com"
        case .azure: return "https://portal.azure.com/#create/Microsoft.CognitiveServicesComputerVision"
        case .mistral: return "https://console.mistral.ai/api-keys"
        }
    }
    static func keychainKey(_ provider: OCRProvider, _ field: String) -> String { "ocr." + provider.rawValue + "." + field }
}

enum OCRCredentialStore {
    static func has(_ p: OCRProvider) -> Bool { p.credentialFields.allSatisfy { SharedCredentials.has(OCRProvider.keychainKey(p, $0.0)) } }
    static func values(_ p: OCRProvider) -> [String: String]? {
        var out: [String: String] = [:]
        for (field, _) in p.credentialFields {
            guard let v = SharedCredentials.get(OCRProvider.keychainKey(p, field)) else { return nil }
            out[field] = v
        }
        return out
    }
}

protocol OCRTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

struct NativeOCRTransport: OCRTransport {
    private static let session: URLSession = { let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 30; c.timeoutIntervalForResource = 60; c.httpCookieStorage = nil; return URLSession(configuration: c) }()
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await Self.session.data(for: request)
        guard data.count <= 8_000_000 else { throw OCRError.invalidResponse("size") }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// 云端上传前的图片处理：缩小到服务商允许的边长与体积，编码为 JPEG（截图通常是不透明的）
enum OCRImagePrep {
    struct Encoded { var data: Data; var width: Int; var height: Int }

    static func encode(_ image: CGImage, maxSide: Int, maxBytes: Int, minSide: Int = 16) -> Encoded? {
        var current = image
        let longest = max(current.width, current.height)
        if longest > maxSide, let scaled = resize(current, factor: CGFloat(maxSide) / CGFloat(longest)) { current = scaled }
        for quality in [0.9, 0.8, 0.65, 0.5] as [CGFloat] {
            if let data = jpeg(current, quality: quality), data.count <= maxBytes { return Encoded(data: data, width: current.width, height: current.height) }
        }
        // 仍然太大：再缩小一半重试
        if let smaller = resize(current, factor: 0.5), min(smaller.width, smaller.height) >= minSide { return encode(smaller, maxSide: maxSide, maxBytes: maxBytes, minSide: minSide) }
        return nil
    }

    static func resize(_ image: CGImage, factor: CGFloat) -> CGImage? {
        let w = max(1, Int((CGFloat(image.width) * factor).rounded())), h = max(1, Int((CGFloat(image.height) * factor).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func jpeg(_ image: CGImage, quality: CGFloat) -> Data? {
        // JPEG 不支持透明通道：先铺白底
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let flat = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, flat, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// 像素框（左上角为原点）→ 归一化框（左下角为原点）
    static func normalized(left: Double, top: Double, width: Double, height: Double, imageWidth: Int, imageHeight: Int) -> CGRect {
        guard imageWidth > 0, imageHeight > 0 else { return .zero }
        let w = CGFloat(imageWidth), h = CGFloat(imageHeight)
        let r = CGRect(x: CGFloat(left) / w, y: 1 - CGFloat(top + height) / h, width: CGFloat(width) / w, height: CGFloat(height) / h)
        return r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

// MARK: 百度智能云 OCR

final class BaiduOCREngine: OCREngine {
    let id = "baidu", uploadsImage = true
    private let apiKey: String, secretKey: String, accurate: Bool, transport: OCRTransport
    private let tokenKey: String
    private var name: String { OCRProvider.baidu.title }

    init(apiKey: String, secretKey: String, accurate: Bool, transport: OCRTransport = NativeOCRTransport()) {
        self.apiKey = apiKey; self.secretKey = secretKey; self.accurate = accurate; self.transport = transport
        tokenKey = "ocr-baidu:" + SHA256.hash(data: Data((apiKey + "\u{0}" + secretKey).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func form(_ pairs: [(String, String)]) -> Data { Data(pairs.map { ASRAuth.encode($0.0) + "=" + ASRAuth.encode($0.1) }.joined(separator: "&").utf8) }

    private func token(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let cached = ASRTokenCache.shared.get(tokenKey) { return cached.value }
        var request = URLRequest(url: URL(string: "https://aip.baidubce.com/oauth/2.0/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form([("grant_type", "client_credentials"), ("client_id", apiKey), ("client_secret", secretKey)])
        let (data, _) = try await send(request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OCRError.invalidResponse(name) }
        if let error = json["error"] as? String { throw OCRError.auth(name, (json["error_description"] as? String) ?? error) }
        guard let value = json["access_token"] as? String, !value.isEmpty else { throw OCRError.invalidResponse(name) }
        let expires = (json["expires_in"] as? Double) ?? 2_592_000
        ASRTokenCache.shared.put(ASRToken(value: value, expires: Date().timeIntervalSince1970 + expires), key: tokenKey)
        return value
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do { return try await transport.send(request) } catch let e as OCRError { throw e } catch { throw OCRError.network(name, error.localizedDescription) }
    }

    func recognize(_ image: CGImage) async throws -> OCRResult {
        guard let encoded = OCRImagePrep.encode(image, maxSide: 4096, maxBytes: 3_000_000, minSide: 15), encoded.width >= 15, encoded.height >= 15 else { throw OCRError.tooSmall }
        for attempt in 0..<2 {
            let t = try await token(forceRefresh: attempt == 1)
            var comps = URLComponents(string: "https://aip.baidubce.com/rest/2.0/ocr/v1/" + (accurate ? "accurate" : "general"))!
            comps.queryItems = [URLQueryItem(name: "access_token", value: t)]
            var request = URLRequest(url: comps.url!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = form([("image", encoded.data.base64EncodedString()), ("language_type", "auto_detect"), ("detect_direction", "true"), ("paragraph", "false")])
            let (data, _) = try await send(request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OCRError.invalidResponse(name) }
            if let code = (json["error_code"] as? Int) ?? (json["error_code"] as? NSNumber)?.intValue {
                let message = (json["error_msg"] as? String) ?? "\(code)"
                if [110, 111].contains(code), attempt == 0 { ASRTokenCache.shared.remove(tokenKey); continue }   // 令牌失效：换新令牌重试一次
                throw Self.classify(code: code, message: message, name: name)
            }
            let rows = (json["words_result"] as? [[String: Any]]) ?? []
            let lines: [OCRLine] = rows.compactMap { row in
                guard let words = row["words"] as? String else { return nil }
                var box = CGRect.zero
                if let loc = row["location"] as? [String: Any] {
                    box = OCRImagePrep.normalized(left: Self.number(loc["left"]), top: Self.number(loc["top"]), width: Self.number(loc["width"]), height: Self.number(loc["height"]), imageWidth: encoded.width, imageHeight: encoded.height)
                }
                return OCRLine(text: words, box: box)
            }
            let joined = OCRLayout.join(lines)
            return OCRResult(text: joined.text, lines: joined.ordered, engine: "baidu")
        }
        throw OCRError.invalidResponse(name)
    }

    static func number(_ any: Any?) -> Double { (any as? Double) ?? (any as? NSNumber)?.doubleValue ?? 0 }

    static func classify(code: Int, message: String, name: String) -> OCRError {
        if [4, 6, 14, 110, 111].contains(code) { return .auth(name, message) }    // 无权限 / 认证失败 / 令牌无效或过期
        if [17, 18, 19].contains(code) { return .quota(name, message) }           // 日额度 / 并发 / 总额度
        return .service(name, message)
    }
}

// MARK: 腾讯云 OCR（TC3-HMAC-SHA256 签名）

enum TencentSigner {
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func sha256(_ data: Data) -> String { hex(Data(SHA256.hash(data: data))) }
    static func hmac(_ key: Data, _ message: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))) }

    /// 返回需要加到请求上的头。`timestamp` 是 Unix 秒。
    static func headers(secretId: String, secretKey: String, service: String, host: String, action: String, version: String, region: String, payload: Data, timestamp: Int) -> [String: String] {
        let date: String = {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
        }()
        let contentType = "application/json; charset=utf-8"
        let canonicalHeaders = "content-type:\(contentType)\nhost:\(host)\nx-tc-action:\(action.lowercased())\n"
        let signedHeaders = "content-type;host;x-tc-action"
        let canonicalRequest = ["POST", "/", "", canonicalHeaders, signedHeaders, sha256(payload)].joined(separator: "\n")
        let scope = "\(date)/\(service)/tc3_request"
        let stringToSign = ["TC3-HMAC-SHA256", String(timestamp), scope, sha256(Data(canonicalRequest.utf8))].joined(separator: "\n")
        let secretDate = hmac(Data(("TC3" + secretKey).utf8), date)
        let secretService = hmac(secretDate, service)
        let secretSigning = hmac(secretService, "tc3_request")
        let signature = hex(hmac(secretSigning, stringToSign))
        let authorization = "TC3-HMAC-SHA256 Credential=\(secretId)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return ["Authorization": authorization, "Content-Type": contentType, "Host": host, "X-TC-Action": action, "X-TC-Timestamp": String(timestamp), "X-TC-Version": version, "X-TC-Region": region]
    }
}

final class TencentOCREngine: OCREngine {
    let id = "tencent", uploadsImage = true
    private let secretId: String, secretKey: String, region: String, accurate: Bool, transport: OCRTransport, now: () -> Date
    private var name: String { OCRProvider.tencent.title }

    init(secretId: String, secretKey: String, region: String, accurate: Bool, transport: OCRTransport = NativeOCRTransport(), now: @escaping () -> Date = Date.init) {
        self.secretId = secretId; self.secretKey = secretKey; self.region = region.isEmpty ? "ap-guangzhou" : region; self.accurate = accurate; self.transport = transport; self.now = now
    }

    func recognize(_ image: CGImage) async throws -> OCRResult {
        guard let encoded = OCRImagePrep.encode(image, maxSide: 6000, maxBytes: 4_500_000, minSide: 20), encoded.width >= 20, encoded.height >= 20 else { throw OCRError.tooSmall }
        let action = accurate ? "GeneralAccurateOCR" : "GeneralBasicOCR"
        var body: [String: Any] = ["ImageBase64": encoded.data.base64EncodedString()]
        if !accurate { body["LanguageType"] = "auto" }
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { throw OCRError.invalidResponse(name) }
        var request = URLRequest(url: URL(string: "https://ocr.tencentcloudapi.com/")!)
        request.httpMethod = "POST"; request.httpBody = payload
        let headers = TencentSigner.headers(secretId: secretId, secretKey: secretKey, service: "ocr", host: "ocr.tencentcloudapi.com", action: action, version: "2018-11-19", region: region, payload: payload, timestamp: Int(now().timeIntervalSince1970))
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let data: Data
        do { (data, _) = try await transport.send(request) } catch let e as OCRError { throw e } catch { throw OCRError.network(name, error.localizedDescription) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let response = root["Response"] as? [String: Any] else { throw OCRError.invalidResponse(name) }
        if let error = response["Error"] as? [String: Any] {
            let code = (error["Code"] as? String) ?? "", message = (error["Message"] as? String) ?? code
            throw Self.classify(code: code, message: message, name: name)
        }
        let rows = (response["TextDetections"] as? [[String: Any]]) ?? []
        let lines: [OCRLine] = rows.compactMap { row in
            guard let text = row["DetectedText"] as? String else { return nil }
            var box = CGRect.zero
            if let item = row["ItemPolygon"] as? [String: Any], BaiduOCREngine.number(item["Width"]) > 0 {
                box = OCRImagePrep.normalized(left: BaiduOCREngine.number(item["X"]), top: BaiduOCREngine.number(item["Y"]), width: BaiduOCREngine.number(item["Width"]), height: BaiduOCREngine.number(item["Height"]), imageWidth: encoded.width, imageHeight: encoded.height)
            } else if let poly = row["Polygon"] as? [[String: Any]], !poly.isEmpty {
                let xs = poly.map { BaiduOCREngine.number($0["X"]) }, ys = poly.map { BaiduOCREngine.number($0["Y"]) }
                box = OCRImagePrep.normalized(left: xs.min()!, top: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!, imageWidth: encoded.width, imageHeight: encoded.height)
            }
            return OCRLine(text: text, box: box)
        }
        let joined = OCRLayout.join(lines)
        return OCRResult(text: joined.text, lines: joined.ordered, engine: "tencent")
    }

    static func classify(code: String, message: String, name: String) -> OCRError {
        if code.hasPrefix("AuthFailure") || code.hasPrefix("UnauthorizedOperation") { return .auth(name, message) }
        if code.contains("LimitExceeded") || code.contains("InArrears") || code.contains("Quota") { return .quota(name, message) }
        return .service(name, message)
    }
}

// MARK: Google Cloud Vision

final class GoogleOCREngine: OCREngine {
    let id = "google", uploadsImage = true
    private let apiKey: String, transport: OCRTransport
    private var name: String { OCRProvider.google.title }

    init(apiKey: String, transport: OCRTransport = NativeOCRTransport()) { self.apiKey = apiKey; self.transport = transport }

    func recognize(_ image: CGImage) async throws -> OCRResult {
        guard let encoded = OCRImagePrep.encode(image, maxSide: 4096, maxBytes: 4_000_000, minSide: 8) else { throw OCRError.tooSmall }
        let body: [String: Any] = ["requests": [["image": ["content": encoded.data.base64EncodedString()], "features": [["type": "DOCUMENT_TEXT_DETECTION"]]]]]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { throw OCRError.invalidResponse(name) }
        var request = URLRequest(url: URL(string: "https://vision.googleapis.com/v1/images:annotate")!)
        request.httpMethod = "POST"; request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")      // 放在请求头里，不放进网址
        let data: Data, status: Int
        do { (data, status) = try await transport.send(request) } catch let e as OCRError { throw e } catch { throw OCRError.network(name, error.localizedDescription) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OCRError.invalidResponse(name) }
        if let error = (root["error"] as? [String: Any]) ?? ((root["responses"] as? [[String: Any]])?.first?["error"] as? [String: Any]) {
            throw Self.classify(code: (error["code"] as? Int) ?? status, status: (error["status"] as? String) ?? "", message: (error["message"] as? String) ?? "\(status)", name: name)
        }
        guard let first = (root["responses"] as? [[String: Any]])?.first else { throw OCRError.invalidResponse(name) }
        let full = first["fullTextAnnotation"] as? [String: Any]
        var lines: [OCRLine] = []
        for page in (full?["pages"] as? [[String: Any]]) ?? [] {
            let pw = Int(BaiduOCREngine.number(page["width"])) > 0 ? Int(BaiduOCREngine.number(page["width"])) : encoded.width
            let ph = Int(BaiduOCREngine.number(page["height"])) > 0 ? Int(BaiduOCREngine.number(page["height"])) : encoded.height
            lines += Self.lines(in: page, width: pw, height: ph)
        }
        if lines.isEmpty, let text = full?["text"] as? String, !text.isEmpty {
            lines = text.split(separator: "\n").map { OCRLine(text: String($0), box: .zero) }      // 没有位置信息：只给文字
        }
        let joined = OCRLayout.join(lines)
        return OCRResult(text: joined.text, lines: joined.ordered, engine: "google")
    }

    /// 把页面里的词按“行结束”标记拼成行，行框取各词框的并集
    static func lines(in page: [String: Any], width: Int, height: Int) -> [OCRLine] {
        var out: [OCRLine] = []
        var text = "", minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                let box = minX.isFinite ? OCRImagePrep.normalized(left: minX, top: minY, width: maxX - minX, height: maxY - minY, imageWidth: width, imageHeight: height) : .zero
                out.append(OCRLine(text: trimmed, box: box))
            }
            text = ""; minX = .infinity; minY = .infinity; maxX = -.infinity; maxY = -.infinity
        }
        for block in (page["blocks"] as? [[String: Any]]) ?? [] {
            for paragraph in (block["paragraphs"] as? [[String: Any]]) ?? [] {
                for word in (paragraph["words"] as? [[String: Any]]) ?? [] {
                    let symbols = (word["symbols"] as? [[String: Any]]) ?? []
                    text += symbols.compactMap { $0["text"] as? String }.joined()
                    if let vertices = (word["boundingBox"] as? [String: Any])?["vertices"] as? [[String: Any]], !vertices.isEmpty {
                        for v in vertices { let x = BaiduOCREngine.number(v["x"]), y = BaiduOCREngine.number(v["y"]); minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
                    }
                    let breakType = ((symbols.last?["property"] as? [String: Any])?["detectedBreak"] as? [String: Any])?["type"] as? String
                    switch breakType {
                    case "SPACE", "SURE_SPACE": text += " "
                    case "EOL_SURE_SPACE", "LINE_BREAK": flush()
                    default: break
                    }
                }
                flush()
            }
        }
        flush()
        return out
    }

    static func classify(code: Int, status: String, message: String, name: String) -> OCRError {
        if [401, 403].contains(code) || ["PERMISSION_DENIED", "UNAUTHENTICATED"].contains(status) || message.lowercased().contains("api key") { return .auth(name, message) }
        if code == 429 || status == "RESOURCE_EXHAUSTED" { return .quota(name, message) }
        return .service(name, message)
    }
}

// MARK: 路由：选择引擎、检查同意与凭据、失败回退

struct OCRRouter {
    var settings: ScreenshotSettings
    var credentials: (OCRProvider) -> [String: String]? = OCRCredentialStore.values
    var online: () -> Bool? = { NetworkReachability.shared.isOnline }
    var transport: OCRTransport = NativeOCRTransport()
    var local: OCREngine = VisionOCREngine()
    /// Directory of the installed local model set with this id, nil when it is not installed.
    var localModelDirectory: (String) -> URL? = { id in LocalModelCenter.shared.isReady(id) ? LocalModelCenter.shared.modelDir(id) : nil }
    var localModelEngine: (URL) throws -> OCREngine = { try PaddleOCRCache.engine(directory: $0) }
    /// The chosen "my AI model" (its service settings and key) for picture reading; nil when none is chosen or it was deleted.
    var aiService: (String) -> (name: String, service: TextRefineSettings, key: String?)? = { _ in nil }
    var aiTransport: LLMTransport = NativeLLMTransport()
    var localOnly: () -> Bool = { LocalOnlyMode.enabled }

    /// Why the AI model cannot read pictures right now; nil when it can.
    func aiBlocker() -> OCRError? {
        let title = L10n.tr("ocr.engine.ai")
        guard let chosen = aiService(settings.ocrProfileID), chosen.service.configured else { return .ai(title, L10n.tr("screenshot.ocr.err.ai.none")) }
        if chosen.service.isLocal { return nil }
        if localOnly() { return .ai(chosen.name, L10n.tr("screenshot.ocr.err.ai.locked")) }
        if settings.ocrConsent[AIVisionOCR.engineID] != true { return .noConsent(chosen.name) }
        let needsKey = LLMPresets.preset(chosen.service.preset)?.needsKey ?? true
        if needsKey && (chosen.key ?? "").isEmpty { return .noCredentials(chosen.name) }
        if online() == false { return .offline }
        return nil
    }

    func cloudEngine(for provider: OCRProvider) -> OCREngine? {
        guard let c = credentials(provider) else { return nil }
        let accurate = settings.ocrAccurate[provider.rawValue] ?? false
        switch provider {
        case .baidu: return BaiduOCREngine(apiKey: c["apikey"] ?? "", secretKey: c["secretkey"] ?? "", accurate: accurate, transport: transport)
        case .tencent: return TencentOCREngine(secretId: c["secretid"] ?? "", secretKey: c["secretkey"] ?? "", region: settings.ocrTencentRegion, accurate: accurate, transport: transport)
        case .google: return GoogleOCREngine(apiKey: c["apikey"] ?? "", transport: transport)
        case .azure: return AzureReadOCREngine(key: c["apikey"] ?? "", place: settings.ocrAzurePlace, transport: transport)
        case .mistral: return MistralOCREngine(key: c["apikey"] ?? "", transport: transport)
        }
    }

    /// 选定云端引擎但当前不能用时的原因；nil 表示可以用
    func cloudBlocker(_ provider: OCRProvider) -> OCRError? {
        if settings.ocrConsent[provider.rawValue] != true { return .noConsent(provider.title) }
        if credentials(provider) == nil { return .noCredentials(provider.title) }
        if online() == false { return .offline }
        return nil
    }

    func recognize(_ image: CGImage) async throws -> OCRResult {
        var result: OCRResult
        if settings.ocrEngine == PaddleOCREngine.engineID {
            do {
                guard let directory = localModelDirectory(settings.ocrLocalModel) else { throw OCRError.localModel(L10n.tr("ppocr.err.notInstalled")) }
                result = try await localModelEngine(directory).recognize(image)
            } catch {
                guard settings.ocrFallback else { throw error }
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                result = try await local.recognize(image); result.fallbackReason = reason
            }
        } else if settings.ocrEngine == AIVisionOCR.engineID {
            if let blocker = aiBlocker() {
                guard settings.ocrFallback else { throw blocker }
                result = try await local.recognize(image); result.fallbackReason = blocker.localizedDescription
            } else if let chosen = aiService(settings.ocrProfileID) {
                do { result = try await AIVisionOCREngine(service: chosen.service, apiKey: chosen.key, name: chosen.name, transport: aiTransport).recognize(image) }
                catch {
                    guard settings.ocrFallback else { throw error }
                    let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    result = try await local.recognize(image); result.fallbackReason = reason
                }
            } else { throw OCRError.unknownEngine }
        } else if let provider = OCRProvider(rawValue: settings.ocrEngine) {
            if let blocker = cloudBlocker(provider) {
                guard settings.ocrFallback else { throw blocker }
                result = try await local.recognize(image); result.fallbackReason = blocker.localizedDescription
            } else if let engine = cloudEngine(for: provider) {
                do { result = try await engine.recognize(image) }
                catch {
                    guard settings.ocrFallback else { throw error }
                    let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    result = try await local.recognize(image); result.fallbackReason = reason
                }
            } else { throw OCRError.unknownEngine }
        } else {
            result = try await local.recognize(image)
        }
        result.codes = await BarcodeScanner.scan(image)
        return result
    }
}

// MARK: - 测试连接用的小图：白底黑字 “OCR TEST 123”

enum OCRTestImage {
    static func make() -> CGImage? {
        let text = "OCR TEST 123"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44, weight: .medium), .foregroundColor: NSColor.black]
        let size = (text as NSString).size(withAttributes: attributes)
        let w = Int(size.width) + 60, h = Int(size.height) + 40
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (text as NSString).draw(at: CGPoint(x: 30, y: 20), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
