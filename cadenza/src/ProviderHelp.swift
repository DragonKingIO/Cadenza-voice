import Foundation

/// Public documentation only. Never attach settings, credentials or account identifiers.
enum ProviderHelp {
    static func credentialGuideURL(engine: ASREngine, language: String) -> URL? {
        guard engine != .apple && engine != .local else { return nil }
        let localePath = language.hasPrefix("zh") ? "zh-cn/" : ""
        return URL(string: "https://dragonkingio.github.io/cadenza-site/" + localePath + "cloud-credentials/#" + engine.rawValue)
    }
}
