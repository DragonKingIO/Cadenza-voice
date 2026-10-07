import Cocoa
import CoreGraphics

/// Live state of the Input Monitoring permission. `TCC.listenAllowed()` is cached for the life of the process,
/// so it keeps saying "allowed" after the switch is turned off (and after a rebuilt app lost its grant). Creating a
/// listen-only event tap asks the system again, so it tells the truth about what the process can actually receive.
enum MonitorPermission: Equatable {
    case granted
    case denied
    /// The system list says allowed but the process cannot receive keys; turn the switch off and on, then restart.
    case stale
}

enum PermissionProbe {
    /// Overridable so tests need neither a real permission nor an event tap.
    static var tapProbe: () -> Bool = {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask,
                                          callback: { _, _, event, _ in Unmanaged.passUnretained(event) }, userInfo: nil) else { return false }
        CFMachPortInvalidate(tap)
        return true
    }
    static var preflight: () -> Bool = { TCC.listenAllowed() }

    /// Never creates a tap when the system says no, so it cannot trigger a permission prompt.
    static func monitor() -> MonitorPermission {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached, now - cached.at < 0.8 { return cached.state }
        let state: MonitorPermission = preflight() ? (tapProbe() ? .granted : .stale) : .denied
        cached = (now, state)
        return state
    }
    private static var cached: (at: TimeInterval, state: MonitorPermission)?
    static func forget() { cached = nil }
    static var monitorGranted: Bool { monitor() == .granted }
}

extension Notification.Name {
    /// Posted when a permission changed, or the Mac woke up or was unlocked, so listeners should be set up again.
    static let permissionsChanged = Notification.Name("local.cadenza.permissionsChanged")
}

/// Watches permissions and wake/unlock events in the background, so the shortcut recovers without a restart.
final class PermissionWatcher {
    static let shared = PermissionWatcher()
    struct Snapshot: Equatable { var mic: Bool; var accessibility: Bool; var monitor: MonitorPermission }
    private(set) var last: Snapshot?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    var snapshot: () -> Snapshot = { Snapshot(mic: HoldNativeEngine.micAuthorized(), accessibility: FocusProbe.accessibilityTrusted, monitor: PermissionProbe.monitor()) }

    func start() {
        guard timer == nil else { return }
        let first = snapshot()
        last = first
        Log.write("permissions mic=\(first.mic) accessibility=\(first.accessibility) input-monitoring=\(first.monitor)")
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer!, forMode: .common)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                Log.write("permissions rearm reason=\(n.name.rawValue)")
                // The system needs a moment after wake before event monitors can be created again.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.poll(force: true) }
            })
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers = []
    }

    func poll(force: Bool = false) {
        PermissionProbe.forget()
        let now = snapshot()
        defer { last = now }
        guard force || now != last else { return }
        Log.write("permissions mic=\(now.mic) accessibility=\(now.accessibility) input-monitoring=\(now.monitor)\(force ? " forced" : "")")
        NotificationCenter.default.post(name: .permissionsChanged, object: nil)
    }
}
