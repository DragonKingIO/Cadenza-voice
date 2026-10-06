import Carbon.HIToolbox
import Foundation

enum InputSourceError: Error, CustomStringConvertible {
    case notEnabled(String)
    case selectFailed(OSStatus)

    var description: String {
        switch self {
        case .notEnabled(let id): return "输入源未启用: \(id)"
        case .selectFailed(let s): return "TISSelectInputSource status=\(s)"
        }
    }
}

final class InputSourceController {
    private func prop(_ src: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let p = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue()
    }

    private func all() -> [TISInputSource] {
        guard let cf = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return [] }
        return (0..<CFArrayGetCount(cf)).map {
            unsafeBitCast(CFArrayGetValueAtIndex(cf, $0), to: TISInputSource.self)
        }
    }

    func currentID() -> String? {
        guard let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return prop(cur, kTISPropertyInputSourceID) as? String
    }

    func findEnabled(id: String) -> Bool {
        all().contains { (prop($0, kTISPropertyInputSourceID) as? String) == id }
    }

    func allEnabledIDs() -> [String] {
        all().compactMap { (prop($0, kTISPropertyInputSourceID) as? String) }
    }

    func select(id: String) throws {
        guard let src = all().first(where: { (prop($0, kTISPropertyInputSourceID) as? String) == id }) else {
            throw InputSourceError.notEnabled(id)
        }
        let status = TISSelectInputSource(src)
        guard status == noErr else { throw InputSourceError.selectFailed(status) }
    }
}
