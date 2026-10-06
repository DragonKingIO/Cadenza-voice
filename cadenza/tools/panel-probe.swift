// panel-probe — 列出讯飞进程拥有的窗口（只收集讯飞自身窗口的
// pid/layer/onscreen/bounds 元数据；不读窗口名，不涉及其他应用，无需屏幕录制权限）
import AppKit

func iflytekPids() -> Set<Int32> {
    var set = Set<Int32>()
    for app in NSWorkspace.shared.runningApplications {
        let path = (app.bundleURL?.path ?? app.executableURL?.path ?? "").lowercased()
        let name = (app.localizedName ?? "").lowercased()
        if path.contains("iflytek") || name.contains("iflytek") || path.contains("讯飞") || name.contains("讯飞") {
            set.insert(app.processIdentifier)
        }
    }
    return set
}

let pids = iflytekPids()
print("iflytek-pids=\(pids.sorted())")
guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
    print("CGWindowListCopyWindowInfo failed")
    exit(1)
}
var count = 0
for w in list {
    guard let pid = w[kCGWindowOwnerPID as String] as? Int, pids.contains(Int32(pid)) else { continue }
    let layer = w[kCGWindowLayer as String] as? Int ?? -99
    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
    print("window pid=\(pid) layer=\(layer) onscreen=\(onscreen) bounds=\(bounds)")
    count += 1
}
print("windows=\(count)")
