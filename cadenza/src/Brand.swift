import Foundation

/// Display names are localized resources. Technical identities are never derived from this type.
enum Brand {
    static var name:String{L10n.tr("app.name")}
    static var tagline:String{L10n.tr("app.tagline")}
}
/// The language the user picked inside the app; `system` follows macOS. Only the two bundled languages exist.
enum AppLanguage: String, CaseIterable {
    case system, zhHans = "zh-Hans", en
    private static let key = "appLanguage"
    static var current: AppLanguage {
        get { UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init(rawValue:)) ?? .system }
        set {
            guard newValue != current else { return }
            if newValue == .system { UserDefaults.standard.removeObject(forKey: key) } else { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
            NotificationCenter.default.post(name: .appLanguageChanged, object: nil)
        }
    }
    /// nil = follow the system.
    var resolved: String? { self == .system ? nil : rawValue }
    /// Names are localized, so an English interface never shows Chinese text (see BRAND.md).
    var title: String { L10n.tr(self == .system ? "language.system" : self == .zhHans ? "language.zh" : "language.en") }
}
extension Notification.Name { static let appLanguageChanged = Notification.Name("AppLanguageChanged") }

enum L10n {
    static var language:String {
        // Inspection builds can render a given language without touching saved preferences.
        if let flag=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--ui-language=")}) {return flag.hasSuffix("zh-Hans") ? "zh-Hans":"en"}
        if let chosen=AppLanguage.current.resolved {return chosen}
        let preferred=Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? "zh-Hans":"en"
    }
    static var resourceBundle:Bundle {
        guard let path=Bundle.main.path(forResource:language,ofType:"lproj"),let bundle=Bundle(path:path) else{return Bundle.main}
        return bundle
    }
    static func tr(_ key:String)->String{resourceBundle.localizedString(forKey:key,value:nil,table:"Localizable")}
    static func format(_ key:String,_ args:CVarArg...)->String{String(format:tr(key),locale:Locale(identifier:language),arguments:args)}
}

extension L10n {
    /// Validate actual bundled languages/format contracts without opening UI or reading credentials.
    static func verifyResources()->Int32 {
        var tables:[String:[String:String]]=[:]
        for lang in ["en","zh-Hans"] {
            guard let dir=Bundle.main.resourceURL?.appendingPathComponent(lang+".lproj"),
                  let data=try? Data(contentsOf:dir.appendingPathComponent("Localizable.strings")),
                  let table=(try? PropertyListSerialization.propertyList(from:data,format:nil)) as? [String:String],
                  let info=try? Data(contentsOf:dir.appendingPathComponent("InfoPlist.strings")),
                  let metadata=(try? PropertyListSerialization.propertyList(from:info,format:nil)) as? [String:String],
                  metadata["CFBundleDisplayName"]==table["app.name"],metadata["NSMicrophoneUsageDescription"] != nil,metadata["NSSpeechRecognitionUsageDescription"] != nil else {print("brand-resources missing-or-invalid=\(lang)");return 2}
            if lang == "en",table.values.contains(where:{$0.unicodeScalars.contains(where:{$0.value>=0x4E00 && $0.value<=0x9FFF})}){print("brand-resources English-has-Chinese=true");return 3}
            tables[lang]=table
        }
        guard let en=tables["en"],let zh=tables["zh-Hans"],Set(en.keys)==Set(zh.keys) else{return 4}
        let regex=try! NSRegularExpression(pattern:"%(?:[0-9]+\\$)?(?:@|[0-9.]*[dflu])")
        func tokens(_ s:String)->[String]{regex.matches(in:s,range:NSRange(s.startIndex...,in:s)).map{String(s[Range($0.range,in:s)!])}.sorted()}
        for key in en.keys {if tokens(en[key]!) != tokens(zh[key]!) {print("brand-format-mismatch=\(key)");return 5}}
        print("brand-resources languages=en,zh-Hans keys=\(en.count) valid=true selected=\(language) name=\(Brand.name) tagline=\(Brand.tagline)")
        return 0
    }
}
