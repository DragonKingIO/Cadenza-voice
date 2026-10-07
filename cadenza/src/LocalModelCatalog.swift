import Foundation
import CryptoKit

// MARK: - 本地模型清单
// 模型不进安装包：用户在“设置 → 语音识别 → 本地”里下载、使用、删除。
// 清单 = 内置清单（保证离线/开源构建可用）+ 可选的远端清单（新增模型或更新版本）。

struct LocalModelFile: Codable, Equatable {
    /// 下载后在磁盘上的文件名（只允许单层文件名）
    var name: String
    /// 主地址在前，镜像在后；全部必须是 https
    var urls: [String]
    var sha256: String
    var size: Int64
    /// true：tar.bz2 压缩包，校验后解压并去掉最外层目录；false：原样放入模型目录
    var extract: Bool = false

    enum CodingKeys: String, CodingKey { case name, urls, sha256, size, extract }
    init(name: String, urls: [String], sha256: String, size: Int64, extract: Bool = false) { self.name = name; self.urls = urls; self.sha256 = sha256; self.size = size; self.extract = extract }
    init(from decoder: Decoder) throws {
        let d = try decoder.container(keyedBy: CodingKeys.self)
        name = try d.decode(String.self, forKey: .name); urls = try d.decode([String].self, forKey: .urls)
        sha256 = try d.decode(String.self, forKey: .sha256); size = try d.decode(Int64.self, forKey: .size)
        extract = try d.decodeIfPresent(Bool.self, forKey: .extract) ?? false
    }
}

struct LocalModelEntry: Codable, Equatable, Identifiable {
    var id: String
    /// 清单版本（语义化版本，用于判断是否有更新，不是上游模型日期）
    var version: String
    var displayName: [String: String]
    var summary: [String: String]
    /// 推理后端家族：目前实现 sensevoice；其余在清单里出现但本版本不支持时会被标为“需要更新软件”
    var kind: String
    var languages: [String]
    var downloadSize: Int64
    var installedSize: Int64
    var minAppVersion: String
    /// 协议名称；具体条款以模型包内 LICENSE 为准（安装后可在界面打开）
    var license: String
    var changelog: String
    var files: [LocalModelFile]
    /// 安装完成后必须存在的相对路径
    var requiredFiles: [String]
    /// 适用平台（macos / windows …）；缺省或为空 = 所有平台。清单是平台无关的，各平台客户端只显示适用于自己的条目。
    var platforms: [String] = []

    enum CodingKeys: String, CodingKey { case id, version, displayName, summary, kind, languages, downloadSize, installedSize, minAppVersion, license, changelog, files, requiredFiles, platforms }
    init(id: String, version: String, displayName: [String: String], summary: [String: String], kind: String, languages: [String], downloadSize: Int64, installedSize: Int64, minAppVersion: String, license: String, changelog: String, files: [LocalModelFile], requiredFiles: [String], platforms: [String] = []) {
        self.id = id; self.version = version; self.displayName = displayName; self.summary = summary; self.kind = kind; self.languages = languages
        self.downloadSize = downloadSize; self.installedSize = installedSize; self.minAppVersion = minAppVersion; self.license = license; self.changelog = changelog
        self.files = files; self.requiredFiles = requiredFiles; self.platforms = platforms
    }
    /// 说明性字段缺失时给默认值；安全相关字段（文件、哈希、地址、大小）一律必填
    init(from decoder: Decoder) throws {
        let d = try decoder.container(keyedBy: CodingKeys.self)
        id = try d.decode(String.self, forKey: .id); version = try d.decode(String.self, forKey: .version)
        displayName = try d.decodeIfPresent([String: String].self, forKey: .displayName) ?? [:]
        summary = try d.decodeIfPresent([String: String].self, forKey: .summary) ?? [:]
        kind = try d.decode(String.self, forKey: .kind); languages = try d.decodeIfPresent([String].self, forKey: .languages) ?? []
        downloadSize = try d.decode(Int64.self, forKey: .downloadSize); installedSize = try d.decode(Int64.self, forKey: .installedSize)
        minAppVersion = try d.decodeIfPresent(String.self, forKey: .minAppVersion) ?? "1.0.0"
        license = try d.decodeIfPresent(String.self, forKey: .license) ?? ""; changelog = try d.decodeIfPresent(String.self, forKey: .changelog) ?? ""
        files = try d.decode([LocalModelFile].self, forKey: .files); requiredFiles = try d.decode([String].self, forKey: .requiredFiles)
        platforms = try d.decodeIfPresent([String].self, forKey: .platforms) ?? []
    }

    func name(_ language: String = L10n.language) -> String { displayName[language] ?? displayName["en"] ?? id }
    func detail(_ language: String = L10n.language) -> String { summary[language] ?? summary["en"] ?? "" }
}

struct LocalModelManifest: Codable, Equatable {
    var schema: Int
    var models: [LocalModelEntry]
}

enum LocalModelVersion {
    /// 点分数字版本比较；缺位按 0
    static func isNewer(_ remote: String, than local: String?) -> Bool {
        guard let local else { return true }
        let r = remote.split(separator: ".").map { Int($0) ?? 0 }, l = local.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0, lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }
    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0" }
}

enum LocalModelCatalog {
    /// 当前客户端所在平台（清单里 platforms 使用的名字）
    static let currentPlatform = "macos"
    static func appliesToCurrentPlatform(_ e: LocalModelEntry) -> Bool { e.platforms.isEmpty || e.platforms.contains(currentPlatform) }

    /// 本版本推理层能运行的语音识别模型家族
    static let supportedKinds: Set<String> = ["sensevoice", "parakeet-tdt", "fire-red-ctc"]
    /// 文字识别（OCR）模型家族：和语音模型共用下载、校验、安装机制，但在“文字识别”页管理，不属于语音识别
    static let ocrKinds: Set<String> = ["ppocr"]
    static func isOCR(_ e: LocalModelEntry) -> Bool { ocrKinds.contains(e.kind) }
    /// 能下载并安装：语音模型，或本版本能运行的文字识别模型
    static func downloadable(_ e: LocalModelEntry) -> Bool { usable(e) || usableOCR(e) }
    /// 能用于文字识别：属于 OCR 家族、本版本带有推理库、软件版本够新
    static func usableOCR(_ e: LocalModelEntry, appVersion: String = LocalModelVersion.appVersion) -> Bool {
        isOCR(e) && PaddleOCREngine.isAvailable && !LocalModelVersion.isNewer(e.minAppVersion, than: appVersion)
    }

    /// 远端清单地址（空 = 只用内置清单）。开源后填项目托管地址；用户也可在配置里覆盖。
    static let defaultManifestURLs: [String] = []
    /// 清单签名公钥（Ed25519 原始 32 字节，base64）。非空时远端清单必须带有效签名。
    static let manifestPublicKeys: [String] = []

    static let builtin: [LocalModelEntry] = [
        LocalModelEntry(
            id: "sensevoice-multilingual-int8", version: "1.0.0",
            displayName: ["en": "East Asian languages (SenseVoice)", "zh-Hans": "东亚语言（SenseVoice）"],
            summary: ["en": "Chinese, English, Japanese, Korean and Cantonese with automatic language detection, punctuation and number formatting. Runs fully on this Mac.",
                      "zh-Hans": "中文、英文、日文、韩文、粤语，自动判断语种，自带标点与数字规整，完全在本机运行。"],
            kind: "sensevoice", languages: ["zh", "en", "ja", "ko", "yue"],
            downloadSize: 163_646_737, installedSize: 238_100_000, minAppVersion: "1.0.0",
            license: "See LICENSE in the model package", changelog: "sherpa-onnx SenseVoice small int8 (2024-07-17), Silero VAD.",
            files: [
                LocalModelFile(name: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2",
                               urls: ["https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2"],
                               sha256: "7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e", size: 163_002_883, extract: true),
                LocalModelFile(name: "silero_vad.onnx",
                               urls: ["https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"],
                               sha256: "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6", size: 643_854)
            ],
            requiredFiles: ["model.int8.onnx", "tokens.txt", "silero_vad.onnx"], platforms: ["macos", "windows"]),
        LocalModelEntry(
            id: "parakeet-tdt-v3-int8", version: "1.0.0",
            displayName: ["en": "European languages (Parakeet TDT v3) · experimental", "zh-Hans": "欧洲语言（Parakeet TDT v3）· 实验性"],
            summary: ["en": "25 European languages (English, French, German, Spanish, Italian, Portuguese, Russian, Polish and more) with automatic language detection, punctuation and capitalization. Runs fully on this Mac.",
                      "zh-Hans": "25 种欧洲语言（英、法、德、西、意、葡、俄、波兰语等），自动判断语种，自带标点与大小写，完全在本机运行。"],
            kind: "parakeet-tdt", languages: ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"],
            downloadSize: 487_813_909, installedSize: 700_000_000, minAppVersion: "1.0.0",
            license: "See LICENSE in the model package", changelog: "sherpa-onnx NeMo Parakeet TDT 0.6B v3 int8 (ONNX, CPU), Silero VAD.",
            files: [
                LocalModelFile(name: "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2",
                               urls: ["https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2"],
                               sha256: "5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf", size: 487_170_055, extract: true),
                LocalModelFile(name: "silero_vad.onnx",
                               urls: ["https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"],
                               sha256: "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6", size: 643_854)
            ],
            requiredFiles: ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt", "silero_vad.onnx"], platforms: ["macos", "windows"]),
        LocalModelEntry(
            id: "fire-red-asr2-ctc-int8", version: "1.0.0",
            displayName: ["en": "High-accuracy Chinese (FireRedASR2) · experimental", "zh-Hans": "高精度中文（FireRedASR2）· 实验性"],
            summary: ["en": "Mandarin and English. In our tests its accuracy matched the recommended model, but it writes no punctuation, does not format numbers, and is about four times slower. Runs fully on this Mac.",
                      "zh-Hans": "普通话和英文。我们的测试里准确度和推荐模型相当，但不输出标点、不规整数字，速度约慢 4 倍。完全在本机运行。"],
            kind: "fire-red-ctc", languages: ["zh", "en"],
            downloadSize: 521_160_132, installedSize: 800_000_000, minAppVersion: "1.0.0",
            license: "See LICENSE in the model package", changelog: "sherpa-onnx FireRedASR2 CTC zh+en int8 (2026-02-25), Silero VAD.",
            files: [
                LocalModelFile(name: "sherpa-onnx-fire-red-asr2-ctc-zh_en-int8-2026-02-25.tar.bz2",
                               urls: ["https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-fire-red-asr2-ctc-zh_en-int8-2026-02-25.tar.bz2"],
                               sha256: "1da8b737ecc5e29f36759a4460c754863e7c919a4ba325aea187331fbfc83274", size: 520_516_278, extract: true),
                LocalModelFile(name: "silero_vad.onnx",
                               urls: ["https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"],
                               sha256: "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6", size: 643_854)
            ],
            requiredFiles: ["model.int8.onnx", "tokens.txt", "silero_vad.onnx"], platforms: ["macos", "windows"]),
        LocalModelEntry(
            id: "ppocr-v4-mobile-zh-en", version: "1.0.0",
            displayName: ["en": "Chinese and English (PP-OCRv4 mobile)", "zh-Hans": "中英文（PP-OCRv4 移动版）"],
            summary: ["en": "Reads Chinese and English text lines, including small print and busy backgrounds. Runs on this Mac and works offline. It can miss the spaces between English words, so Apple Vision suits English-only text better.",
                      "zh-Hans": "识别中英文文字行，对小字和复杂背景更稳。完全在本机运行，可离线使用。英文单词之间的空格有时会漏掉，纯英文内容用 Apple Vision 更合适。"],
            kind: "ppocr", languages: [],
            downloadSize: 15_629_724, installedSize: 16_000_000, minAppVersion: "1.0.0",
            license: "Apache-2.0 (see the model package)", changelog: "PP-OCRv4 mobile detection and recognition models (ONNX, converted by the RapidOCR project) and the PaddleOCR v2.7.1 character dictionary.",
            files: [
                LocalModelFile(name: "det.onnx",
                               urls: ["https://huggingface.co/SWHL/RapidOCR/resolve/1cfba2e90fc938db55889873735088de210cc173/PP-OCRv4/ch_PP-OCRv4_det_infer.onnx"],
                               sha256: "d2a7720d45a54257208b1e13e36a8479894cb74155a5efe29462512d42f49da9", size: 4_745_517),
                LocalModelFile(name: "rec.onnx",
                               urls: ["https://huggingface.co/SWHL/RapidOCR/resolve/1cfba2e90fc938db55889873735088de210cc173/PP-OCRv4/ch_PP-OCRv4_rec_infer.onnx"],
                               sha256: "48fc40f24f6d2a207a2b1091d3437eb3cc3eb6b676dc3ef9c37384005483683b", size: 10_857_958),
                LocalModelFile(name: "dict.txt",
                               urls: ["https://raw.githubusercontent.com/PaddlePaddle/PaddleOCR/v2.7.1/ppocr/utils/ppocr_keys_v1.txt"],
                               sha256: "28b2362ad4ab2dc38769aa72feb535e3a9ddb3fd2a7585a05920e6393b1dc7f7", size: 26_249)
            ],
            requiredFiles: ["det.onnx", "rec.onnx", "dict.txt"], platforms: ["macos"])
    ]

    // MARK: 清单校验（远端来源一律不可信）

    static func isSafeFileName(_ s: String) -> Bool { !s.isEmpty && !s.contains("/") && !s.contains("\\") && s != "." && s != ".." && !s.hasPrefix(".") }
    static func isSafeRelativePath(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix("/") && !s.contains("\\") && !s.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }
    static func isHex256(_ s: String) -> Bool { s.count == 64 && s.allSatisfy { $0.isHexDigit } }

    static func validate(_ e: LocalModelEntry) -> String? {
        guard isSafeFileName(e.id), e.id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return "id" }
        guard e.platforms.count <= 8, e.platforms.allSatisfy({ !$0.isEmpty && $0.count <= 16 && $0.allSatisfy { $0.isLowercase || $0.isNumber } }) else { return "platforms" }
        guard !e.version.isEmpty, e.version.allSatisfy({ $0.isNumber || $0 == "." }) else { return "version" }
        guard !e.files.isEmpty, e.files.count <= 16, !e.requiredFiles.isEmpty, e.requiredFiles.allSatisfy(isSafeRelativePath) else { return "files" }
        guard e.downloadSize > 0, e.installedSize > 0, e.downloadSize <= 8_000_000_000, e.installedSize <= 16_000_000_000 else { return "size" }
        var names = Set<String>()
        for f in e.files {
            guard isSafeFileName(f.name), names.insert(f.name).inserted, isHex256(f.sha256), f.size > 0,
                  !f.urls.isEmpty, f.urls.count <= 6,
                  f.urls.allSatisfy({ URL(string: $0)?.scheme == "https" && URL(string: $0)?.host != nil }) else { return "file:" + f.name }
            if f.extract && !(f.name.hasSuffix(".tar.bz2") || f.name.hasSuffix(".tar.gz")) { return "extract:" + f.name }
        }
        return nil
    }

    /// 合并内置与远端清单：同 id 取版本更新者；无效条目丢弃；本软件版本不满足的条目保留但标记不可用
    static func merge(builtin: [LocalModelEntry], remote: [LocalModelEntry]) -> [LocalModelEntry] {
        var byID: [String: LocalModelEntry] = [:], order: [String] = []
        for e in builtin where validate(e) == nil { byID[e.id] = e; order.append(e.id) }
        for e in remote where validate(e) == nil {
            if let old = byID[e.id] { if LocalModelVersion.isNewer(e.version, than: old.version) { byID[e.id] = e } }
            else { byID[e.id] = e; order.append(e.id) }
        }
        return order.compactMap { byID[$0] }.filter(appliesToCurrentPlatform)
    }

    static func usable(_ e: LocalModelEntry, appVersion: String = LocalModelVersion.appVersion) -> Bool {
        supportedKinds.contains(e.kind) && !LocalModelVersion.isNewer(e.minAppVersion, than: appVersion)
    }

    static func decode(_ data: Data) throws -> LocalModelManifest {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        let m = try d.decode(LocalModelManifest.self, from: data)
        guard m.schema == 1, m.models.count <= 64 else { throw LocalModelError.manifestInvalid }
        return m
    }

    /// publicKeys 为空：不要求签名；非空：必须有任一公钥验证通过
    static func verifySignature(manifest: Data, signatureBase64: String?, publicKeys: [String] = manifestPublicKeys) -> Bool {
        guard !publicKeys.isEmpty else { return true }
        guard let s = signatureBase64, let sig = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        for k in publicKeys {
            if let raw = Data(base64Encoded: k), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw), key.isValidSignature(sig, for: manifest) { return true }
        }
        return false
    }

    static func languageCode(_ language:String)->String {
        let normalized=language.lowercased().replacingOccurrences(of:"_",with:"-")
        if normalized.hasPrefix("zh-hk") {return "yue"}
        return String(normalized.split(separator:"-").first ?? "")
    }
    static func covers(_ entry:LocalModelEntry,languages:[String])->Bool {
        entry.languages.contains("*") || (!languages.isEmpty && languages.allSatisfy { entry.languages.contains(languageCode($0)) })
    }
    /// 按语言集合选已安装的模型：精确匹配优先，其后是 "*" 兜底；没有则 nil
    static func pick(forLanguages langs: [String], installed: [LocalModelEntry]) -> LocalModelEntry? {
        let codes = langs.map { $0.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? $0.lowercased() }
        // Automatic choice never depends on install order: among models for the language, the recommended one wins.
        for c in codes {
            let matches = installed.filter { $0.languages.map { $0.lowercased() }.contains(c) }
            if let e = matches.first(where: { $0.id == recommendedID }) ?? matches.first { return e }
        }
        return installed.first { $0.languages.contains("*") }
    }
}

enum LocalModelError: LocalizedError, Equatable {
    case manifestInvalid, signatureInvalid
    case insufficientDisk(need: Int64, free: Int64)
    case checksumMismatch(String), sizeMismatch(String)
    case network(String), http(Int)
    case extractFailed(String), unsafeArchive(String)
    case incomplete(String), loadFailed, busy, unsupported, cancelled
    var errorDescription: String? {
        switch self {
        case .manifestInvalid: return L10n.tr("local.err.manifest")
        case .signatureInvalid: return L10n.tr("local.err.signature")
        case .insufficientDisk(let need, let free): return L10n.format("local.err.disk", Self.mb(need), Self.mb(free))
        case .checksumMismatch(let f): return L10n.format("local.err.checksum", f)
        case .sizeMismatch(let f): return L10n.format("local.err.checksum", f)
        case .network(let m): return L10n.format("local.err.network", m)
        case .http(let c): return L10n.format("local.err.http", c)
        case .extractFailed(let m): return L10n.format("local.err.extract", m)
        case .unsafeArchive(let f): return L10n.format("local.err.unsafe", f)
        case .incomplete(let f): return L10n.format("local.err.incomplete", f)
        case .loadFailed: return L10n.tr("local.err.load")
        case .busy: return L10n.tr("local.err.busy")
        case .unsupported: return L10n.tr("local.err.unsupported")
        case .cancelled: return L10n.tr("local.err.cancelled")
        }
    }
    static func mb(_ b: Int64) -> String { String(b / 1_000_000) }
}

enum Hashing {
    /// 分块计算 SHA256，避免把几百 MB 的模型读进内存
    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
