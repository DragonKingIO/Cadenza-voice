// isw — 输入源枚举/切换实测工具（只读 + 显式 select）
import Carbon.HIToolbox
import Foundation

func prop(_ src: TISInputSource, _ key: CFString) -> AnyObject? {
    guard let p = TISGetInputSourceProperty(src, key) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue()
}

func sourceID(_ src: TISInputSource) -> String {
    (prop(src, kTISPropertyInputSourceID) as? String) ?? "?"
}

func boolProp(_ src: TISInputSource, _ key: CFString) -> Bool {
    guard let v = prop(src, key) else { return false }
    return CFEqual(v, kCFBooleanTrue)
}

func describe(_ src: TISInputSource) {
    let id = sourceID(src)
    let name = (prop(src, kTISPropertyLocalizedName) as? String) ?? "?"
    let bundle = (prop(src, kTISPropertyBundleID) as? String) ?? "?"
    let enabled = boolProp(src, kTISPropertyInputSourceIsEnabled)
    let selectable = boolProp(src, kTISPropertyInputSourceIsSelectCapable)
    let ascii = boolProp(src, kTISPropertyInputSourceIsASCIICapable)
    print("id=\(id)")
    print("    name=\(name) bundle=\(bundle) enabled=\(enabled) selectable=\(selectable) ascii=\(ascii)")
}

func listSources(allInstalled: Bool) -> [TISInputSource] {
    guard let cf = TISCreateInputSourceList(nil, allInstalled)?.takeRetainedValue() else { return [] }
    var out: [TISInputSource] = []
    for i in 0..<CFArrayGetCount(cf) {
        let v = CFArrayGetValueAtIndex(cf, i)
        out.append(unsafeBitCast(v, to: TISInputSource.self))
    }
    return out
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: isw list | all <keyword> | current | find <keyword> | select <id>")
    exit(2)
}

switch args[1] {
case "list":
    for s in listSources(allInstalled: false) { describe(s) }
case "all":
    let kw = args.count > 2 ? args[2].lowercased() : ""
    for s in listSources(allInstalled: true) {
        if kw.isEmpty || sourceID(s).lowercased().contains(kw) { describe(s) }
    }
case "current":
    if let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() {
        describe(cur)
    } else { print("current: none") }
case "find":
    let kw = args.count > 2 ? args[2].lowercased() : ""
    for s in listSources(allInstalled: true) {
        if sourceID(s).lowercased().contains(kw) { describe(s) }
    }
case "select":
    guard args.count > 2 else { print("select: need id"); exit(2) }
    let target = args[2]
    guard let src = listSources(allInstalled: false).first(where: { sourceID($0) == target }) else {
        print("select: id not found in enabled list: \(target)")
        exit(1)
    }
    let status = TISSelectInputSource(src)
    print("select status=\(status)")
    Thread.sleep(forTimeInterval: 0.4)
    if let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() {
        print("now-current=\(sourceID(cur))")
    }
default:
    print("unknown command: \(args[1])")
    exit(2)
}
