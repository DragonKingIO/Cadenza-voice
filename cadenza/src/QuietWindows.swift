import AppKit
import ObjectiveC

/// Self-tests and preview renders create real windows (including the legacy AppKit ones kept as test fixtures). They must
/// never appear on the user's screen: in those modes every window that is ordered front is made fully transparent and
/// click-through, and the app gets no Dock icon. The windows still exist, so tests that look at them keep working.
enum QuietWindows {
    private static var installed = false

    static var wanted: Bool {
        CommandLine.arguments.contains { $0.hasPrefix("--selftest") || $0.hasPrefix("--preview-brand-page") || $0 == "--check-brand-resources" || $0 == "--local-accuracy-probe" || $0 == "--accuracy-benchmark" }
    }

    static func installIfNeeded() {
        guard wanted, !installed else { return }
        installed = true
        func swap(_ original: Selector, _ replacement: Selector) {
            guard let a = class_getInstanceMethod(NSWindow.self, original), let b = class_getInstanceMethod(NSWindow.self, replacement) else { return }
            method_exchangeImplementations(a, b)
        }
        swap(#selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSWindow.quiet_makeKeyAndOrderFront(_:)))
        swap(#selector(NSWindow.orderFront(_:)), #selector(NSWindow.quiet_orderFront(_:)))
        swap(#selector(NSWindow.orderFrontRegardless), #selector(NSWindow.quiet_orderFrontRegardless))
        swap(#selector(NSWindow.beginSheet(_:completionHandler:)), #selector(NSWindow.quiet_beginSheet(_:completionHandler:)))
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

extension NSWindow {
    fileprivate func quietly() { alphaValue = 0; ignoresMouseEvents = true; hasShadow = false }
    @objc fileprivate func quiet_makeKeyAndOrderFront(_ sender: Any?) { quietly(); quiet_makeKeyAndOrderFront(sender) }
    @objc fileprivate func quiet_orderFront(_ sender: Any?) { quietly(); quiet_orderFront(sender) }
    @objc fileprivate func quiet_orderFrontRegardless() { quietly(); quiet_orderFrontRegardless() }
    /// Sheets fade in on their own; hide them before they are attached.
    @objc fileprivate func quiet_beginSheet(_ sheet: NSWindow, completionHandler: ((NSApplication.ModalResponse) -> Void)?) { sheet.quietly(); quietly(); quiet_beginSheet(sheet, completionHandler: completionHandler) }
}
