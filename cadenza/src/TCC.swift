import Foundation
import AVFoundation
import Speech
import ApplicationServices
import CoreGraphics

/// Every question the app asks macOS about privacy permissions goes through here.
///
/// Why: macOS keeps one permission record per bundle identifier, tied to the code signature that was granted it. A copy of
/// the app with the same identifier but another signature (a staged build signed ad hoc, a release candidate, a test run)
/// that merely asks "am I allowed?" makes the system distrust the record, and the installed app silently loses its
/// Accessibility, Input Monitoring and Screen Recording grants. The symptom is dictated text that is "kept for you" in the
/// Try card instead of landing in the text field.
///
/// So every mode that is not the real app (self-tests, previews, benchmarks, resource checks) answers "not granted" here
/// without asking the system.
enum TCC {
    /// Command-line modes that must never touch the permission database.
    static let isolatedPrefixes = ["--selftest", "--preview", "--check-", "--bench", "--accuracy-benchmark", "--local-accuracy-probe", "--inspect"]

    static func isolates(arguments: [String]) -> Bool { arguments.contains { argument in isolatedPrefixes.contains { argument.hasPrefix($0) } } }
    static let isolated: Bool = isolates(arguments: CommandLine.arguments)

    // MARK: Accessibility

    /// What the system says right now.
    static func axTrusted() -> Bool { isolated ? false : AXIsProcessTrusted() }

    /// Trusted according to the system *and* answering. After a grant is reset behind a running app's back,
    /// `AXIsProcessTrusted()` can keep saying yes while every accessibility call fails with "API disabled" (-25211).
    static func axWorking(trusted: () -> Bool = TCC.axTrusted, probe: () -> AXError = TCC.systemProbe) -> Bool {
        guard trusted() else { return false }
        return probe() != .apiDisabled
    }

    static func systemProbe() -> AXError {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &value)
    }

    private static let cacheLock = NSLock()
    private static var cached: (at: TimeInterval, value: Bool)?
    static func forgetAXAnswer() { cacheLock.lock(); cached = nil; cacheLock.unlock() }
    /// `axWorking()`, remembered for a second: the settings page asks twice a second and the answer costs a round trip.
    static func axWorkingCached(now: TimeInterval = ProcessInfo.processInfo.systemUptime, compute: () -> Bool = { axWorking() }) -> Bool {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached, now - cached.at < 1 { return cached.value }
        let value = compute()
        cached = (now, value)
        return value
    }

    // MARK: Input Monitoring and Screen Recording

    static func listenAllowed() -> Bool { isolated ? false : CGPreflightListenEventAccess() }
    static func screenGranted() -> Bool { isolated ? false : CGPreflightScreenCaptureAccess() }
    @discardableResult static func screenRequest() -> Bool { isolated ? false : CGRequestScreenCaptureAccess() }

    // MARK: Microphone and speech

    static func micStatus() -> AVAuthorizationStatus { isolated ? .notDetermined : AVCaptureDevice.authorizationStatus(for: .audio) }
    static func requestMic(_ done: @escaping (Bool) -> Void) {
        if isolated { done(false) } else { AVCaptureDevice.requestAccess(for: .audio, completionHandler: done) }
    }
    static func speechStatus() -> SFSpeechRecognizerAuthorizationStatus { isolated ? .notDetermined : SFSpeechRecognizer.authorizationStatus() }
    static func requestSpeech(_ done: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) {
        if isolated { done(.notDetermined) } else { SFSpeechRecognizer.requestAuthorization(done) }
    }
}
