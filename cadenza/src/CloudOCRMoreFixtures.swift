import AppKit
import Foundation
import CoreGraphics

/// Azure AI Vision (Read) and Mistral OCR, with scripted answers.
enum CloudOCRMoreFixtures {
    static func run(_ check: (String, Bool) -> Void) {
        func c(_ name: String, _ ok: Bool) { check("CloudOCR " + name, ok) }
        guard let image = OCRTestImage.make() else { c("test picture exists", false); return }
        // Azure AI Vision (Read) and Mistral OCR
        func run(_ engine: OCREngine) -> Result<OCRResult, Error>? { ScreenshotFixtures.waitFor(10) { try await engine.recognize(image) } }
        let W = image.width, H = image.height
        c("azure: a region or the address of the resource, https on a Microsoft cloud host only",
          AzureVision.readURL("eastus")?.absoluteString == "https://eastus.api.cognitive.microsoft.com/computervision/imageanalysis:analyze?api-version=2023-10-01&features=read"
          && AzureVision.readURL("https://my-vision.cognitiveservices.azure.com/")?.host == "my-vision.cognitiveservices.azure.com"
          && AzureVision.readURL("https://evil.example.com") == nil && AzureVision.readURL("http://my.azure.com") == nil && AzureVision.readURL("East US") == nil && AzureVision.readURL("") == nil)
        let az = ScreenshotFixtures.FakeTransport()
        az.enqueue("{\"metadata\":{\"width\":\(W),\"height\":\(H)},\"readResult\":{\"blocks\":[{\"lines\":[{\"text\":\"Second\",\"boundingPolygon\":[{\"x\":10,\"y\":\(H / 2)},{\"x\":60,\"y\":\(H / 2)},{\"x\":60,\"y\":\(H / 2 + 20)},{\"x\":10,\"y\":\(H / 2 + 20)}]},{\"text\":\"First\",\"boundingPolygon\":[{\"x\":10,\"y\":5},{\"x\":50,\"y\":5},{\"x\":50,\"y\":25},{\"x\":10,\"y\":25}]}]}]}}")
        let azr = try? run(AzureReadOCREngine(key: "az-key", place: "westeurope", transport: az))?.get()
        c("azure: the key is a header, the picture is the body, lines come back in reading order with positions",
          az.requests.first?.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") == "az-key" && az.requests.first?.url?.host == "westeurope.api.cognitive.microsoft.com" && !(az.requests.first?.url?.absoluteString.contains("az-key") ?? true)
          && az.requests.first?.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream" && azr?.text == "First\nSecond" && azr?.hasBoxes == true && azr?.engine == "azure")
        func azureError(_ status: Int) -> OCRError? { let t = ScreenshotFixtures.FakeTransport(); t.enqueue("{\"error\":{\"message\":\"nope\"}}", status: status); if case .failure(let e)? = run(AzureReadOCREngine(key: "k", place: "eastus", transport: t)) { return e as? OCRError }; return nil }
        c("azure: a wrong key and a limit are told apart", { if case .auth? = azureError(401) { return true }; return false }() && { if case .quota? = azureError(429) { return true }; return false }() && { if case .service? = azureError(500) { return true }; return false }())
        c("azure: a place that is not valid sends nothing", { let t = ScreenshotFixtures.FakeTransport(); if case .failure? = run(AzureReadOCREngine(key: "k", place: "https://evil.example.com", transport: t)) { return t.requests.isEmpty }; return false }())
        let mi = ScreenshotFixtures.FakeTransport()
        mi.enqueue("{\"pages\":[{\"index\":0,\"markdown\":\"Hello there\\n\\n![img-0.jpeg](img-0.jpeg)\\nSecond line\"}]}")
        let mir = try? run(MistralOCREngine(key: "mi-key", transport: mi))?.get()
        let mib = (mi.requests.first?.httpBody).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        c("mistral: the key is a header, the picture is an inline JPEG, and the picture placeholders are removed from the Markdown",
          mi.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer mi-key" && mi.requests.first?.url?.absoluteString == "https://api.mistral.ai/v1/ocr" && mib?["model"] as? String == "mistral-ocr-latest"
          && ((mib?["document"] as? [String: Any])?["image_url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true && mir?.lines.map(\.text) == ["Hello there", "Second line"] && mir?.engine == "mistral")
        func mistralError(_ status: Int) -> OCRError? { let t = ScreenshotFixtures.FakeTransport(); t.enqueue("{}", status: status); if case .failure(let e)? = run(MistralOCREngine(key: "k", transport: t)) { return e as? OCRError }; return nil }
        c("mistral: a wrong key and a limit are told apart", { if case .auth? = mistralError(401) { return true }; return false }() && { if case .quota? = mistralError(429) { return true }; return false }())
        c("providers: five online services, each uploads and has a console address, only two have a high-accuracy switch",
          OCRProvider.allCases.count == 5 && OCRProvider.allCases.allSatisfy { URL(string: $0.consoleURL)?.scheme == "https" } && OCRProvider.allCases.filter(\.supportsAccurate).count == 2
          && OCRProvider.azure.credentialFields.map(\.0) == ["apikey"] && OCRProvider.keychainKey(.mistral, "apikey") == "ocr.mistral.apikey")


        func decode(_ json: String) -> ScreenshotSettings? { try? JSONDecoder().decode(ScreenshotSettings.self, from: Data(json.utf8)) }
        // Every cloud speech engine links to its setup guide; the guide has a section with the same anchor (cloud-credentials).
        let cloudEngines = ASREngine.allCases.filter { $0 != .apple && $0 != .local }
        c("凭据指南：每个云端语音服务都有指南链接并指向对应锚点", cloudEngines.allSatisfy { engine in
            ProviderHelp.credentialGuideURL(engine: engine, language: "en")?.absoluteString.hasSuffix("cloud-credentials/#" + engine.rawValue) == true })
        c("凭据指南：苹果与本机识别没有指南链接", ProviderHelp.credentialGuideURL(engine: .apple, language: "en") == nil && ProviderHelp.credentialGuideURL(engine: .local, language: "en") == nil)
        c("settings: the Azure place defaults to a region and survives", decode("{}")?.ocrAzurePlace == "eastus" && decode("{\"ocrAzurePlace\":\"westeurope\"}")?.ocrAzurePlace == "westeurope")
    }
}
