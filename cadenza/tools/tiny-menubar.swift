// tiny-menubar — 环境隔离测试：最小菜单栏应用能否在当前 shell 上下文存活 4 秒
import AppKit

fputs("[tiny] enter\n", stderr)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
item.button?.title = "T"
fputs("[tiny] status-item-created, entering runloop\n", stderr)
DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
    fputs("[tiny] 4s elapsed, terminating normally\n", stderr)
    NSApp.terminate(nil)
}
app.run()
fputs("[tiny] runloop-exited\n", stderr)
