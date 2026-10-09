import Foundation
import CoreGraphics

// Two more online text recognition services: Azure AI Vision (Read) and Mistral OCR. Their keys are shared with the speech
// recognition and AI model entries of the same company (see `SharedCredentials`), so nothing is registered twice.

enum AzureVision {
    /// The address of the Read call for a region ("eastus") or the address of the resource from the Azure portal; https on a
    /// Microsoft cloud host only, so a typo cannot send the key elsewhere.
    static func readURL(_ place: String) -> URL? {
        let p = place.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = "/computervision/imageanalysis:analyze"
        var host: String
        if p.range(of: "^[a-z0-9]{3,30}$", options: .regularExpression) != nil {
            host = "\(p).api.cognitive.microsoft.com"
        } else {
            guard let parts = URLComponents(string: p), parts.scheme?.lowercased() == "https", let h = parts.host?.lowercased(), parts.user == nil, parts.password == nil,
                  parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
                  ["azure.com", "azure.cn", "azure.us", "microsoft.com"].contains(where: { h == $0 || h.hasSuffix("." + $0) }) else { return nil }
            host = h
        }
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = host; parts.path = path
        parts.queryItems = [URLQueryItem(name: "api-version", value: "2023-10-01"), URLQueryItem(name: "features", value: "read")]
        return parts.url
    }
}

final class AzureReadOCREngine: OCREngine {
    let id = "azure", uploadsImage = true
    private let key: String, place: String, transport: OCRTransport
    private var name: String { OCRProvider.azure.title }

    init(key: String, place: String, transport: OCRTransport = NativeOCRTransport()) { self.key = key; self.place = place; self.transport = transport }

    func recognize(_ image: CGImage) async throws -> OCRResult {
        guard let encoded = OCRImagePrep.encode(image, maxSide: 8000, maxBytes: 4_000_000, minSide: 50), encoded.width >= 50, encoded.height >= 50 else { throw OCRError.tooSmall }
        guard let url = AzureVision.readURL(place) else { throw OCRError.service(name, L10n.tr("ocr.azure.place.invalid")) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = encoded.data
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        let data: Data, status: Int
        do { (data, status) = try await transport.send(request) } catch let e as OCRError { throw e } catch { throw OCRError.network(name, error.localizedDescription) }
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200...299).contains(status) else {
            let message = ((root?["error"] as? [String: Any])?["message"] as? String) ?? ((root?["message"] as? String) ?? String(status))
            switch status {
            case 401, 403: throw OCRError.auth(name, String(status))
            case 429: throw OCRError.quota(name, String(status))
            default: throw OCRError.service(name, message.lowercased().contains("key") ? String(status) : message)
            }
        }
        guard let blocks = (root?["readResult"] as? [String: Any])?["blocks"] as? [[String: Any]] else { throw OCRError.invalidResponse(name) }
        let width = Int(BaiduOCREngine.number((root?["metadata"] as? [String: Any])?["width"])), height = Int(BaiduOCREngine.number((root?["metadata"] as? [String: Any])?["height"]))
        let iw = width > 0 ? width : encoded.width, ih = height > 0 ? height : encoded.height
        var lines: [OCRLine] = []
        for block in blocks {
            for row in (block["lines"] as? [[String: Any]]) ?? [] {
                guard let text = row["text"] as? String else { continue }
                var box = CGRect.zero
                if let poly = row["boundingPolygon"] as? [[String: Any]], !poly.isEmpty {
                    let xs = poly.map { BaiduOCREngine.number($0["x"]) }, ys = poly.map { BaiduOCREngine.number($0["y"]) }
                    box = OCRImagePrep.normalized(left: xs.min()!, top: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!, imageWidth: iw, imageHeight: ih)
                }
                lines.append(OCRLine(text: text, box: box))
            }
        }
        let joined = OCRLayout.join(lines)
        return OCRResult(text: joined.text, lines: joined.ordered, engine: "azure")
    }
}

final class MistralOCREngine: OCREngine {
    let id = "mistral", uploadsImage = true
    private let key: String, transport: OCRTransport
    private var name: String { OCRProvider.mistral.title }

    init(key: String, transport: OCRTransport = NativeOCRTransport()) { self.key = key; self.transport = transport }

    func recognize(_ image: CGImage) async throws -> OCRResult {
        guard let encoded = OCRImagePrep.encode(image, maxSide: 4096, maxBytes: 4_000_000, minSide: 8) else { throw OCRError.tooSmall }
        let body: [String: Any] = ["model": "mistral-ocr-latest", "document": ["type": "image_url", "image_url": "data:image/jpeg;base64," + encoded.data.base64EncodedString()]]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { throw OCRError.invalidResponse(name) }
        var request = URLRequest(url: URL(string: "https://api.mistral.ai/v1/ocr")!)
        request.httpMethod = "POST"; request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let data: Data, status: Int
        do { (data, status) = try await transport.send(request) } catch let e as OCRError { throw e } catch { throw OCRError.network(name, error.localizedDescription) }
        guard (200...299).contains(status) else {
            switch status {
            case 401, 403: throw OCRError.auth(name, String(status))
            case 429: throw OCRError.quota(name, String(status))
            default: throw OCRError.service(name, String(status))
            }
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let pages = root["pages"] as? [[String: Any]] else { throw OCRError.invalidResponse(name) }
        let text = Self.plain(pages.compactMap { $0["markdown"] as? String }.joined(separator: "\n"))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { OCRLine(text: String($0), box: .zero) }
        return OCRResult(text: text, lines: lines, engine: "mistral")
    }

    /// The service answers in Markdown. Picture placeholders it adds for figures are not text from the picture.
    static func plain(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
