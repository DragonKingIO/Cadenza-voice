import AppKit
import SwiftUI

/// Real hosted settings content, temporary configuration, no listeners, audio or credentials.
enum AppearanceTransitionFixtures {
    private final class Reading { var scheme: ColorScheme? }
    private struct Probe: View {
        @Environment(\.colorScheme) private var scheme
        let reading: Reading
        var body: some View {
            Color.clear.onAppear { reading.scheme = scheme }
                .onChange(of: scheme) { _, value in reading.scheme = value }
        }
    }

    static func run(_ check: (String, Bool) -> Void) {
        let app = NSApplication.shared
        let original = app.appearance
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-test-" + UUID().uuidString)
        let store = ConfigStore(fileURL: root.appendingPathComponent("config.json"))
        _ = store.mutate { $0.engine = "apple"; $0.hasSeenOnboarding = true; $0.triggerCoordinatorEnabled = false }
        let pipeline = VoicePipeline(configStore: store, input: InputSourceController())
        pipeline.selfTestMode = true
        let model = SettingsModel(store: store, pipeline: pipeline)
        model.tab = .general
        let reading = Reading()
        let hosted = NSHostingController(rootView: MainSettingsView(model: model).background(Probe(reading: reading)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosted
        defer {
            window.close()
            app.appearance = original
            try? FileManager.default.removeItem(at: root)
        }
        // Offscreen rendering still exercises SwiftUI's environment and native grouped Form.
        func update() {
            hosted.view.layoutSubtreeIfNeeded()
            if let rep = hosted.view.bitmapImageRepForCachingDisplay(in: hosted.view.bounds) {
                hosted.view.cacheDisplay(in: hosted.view.bounds, to: rep)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        for mode in ["light", "system", "dark", "system", "light", "dark", "system"] {
            _ = store.mutate { $0.appearanceMode = mode }
            model.sync()
            AppearanceController.apply(mode)
            update()
            let nativeDark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let expected: ColorScheme = nativeDark ? .dark : .light
            check("hosted settings \(mode): content matches window within 150ms", reading.scheme == expected)
            check("hosted settings \(mode): no window override", window.appearance == nil)
            if mode == "system" { check("system choice clears app override", app.appearance == nil) }
        }
    }
}
