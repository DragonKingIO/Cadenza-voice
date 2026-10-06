import AppKit
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "record"
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let c = CapsuleWindowController()
switch mode {
case "record":
    c.showRecord(elapsed: 8)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        for v in [0.6,0.9,0.4,1.0,0.5,0.8,0.35,0.75,0.55,0.95,0.45,0.85] {
            c.tick(elapsed: 8, level: Float(v))
        }
    }
case "recognize": c.showRecognize()
default: c.showError("连接失败", retryStart: {}, retryEnd: {})
}
DispatchQueue.main.asyncAfter(deadline: .now() + 4) { NSApp.terminate(nil) }
app.run()
