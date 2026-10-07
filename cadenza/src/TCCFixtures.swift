import Foundation
import ApplicationServices

/// The permission guard. None of this asks the system anything.
enum TCCFixtures {
    static func run(_ check: (String, Bool) -> Void) {
        func c(_ name: String, _ ok: Bool) { check("TCC " + name, ok) }

        c("test, preview, benchmark and check modes are isolated",
          ["--selftest", "--selftest-local-model", "--preview-brand-page=input", "--check-brand-resources", "--bench-speed", "--accuracy-benchmark", "--local-accuracy-probe", "--inspect-menu"].allSatisfy { TCC.isolates(arguments: ["Cadenza", $0]) })
        c("the real app and the live diagnostics are not", !TCC.isolates(arguments: ["Cadenza"]) && !TCC.isolates(arguments: ["Cadenza", "--diagnose-front-focus"]) && !TCC.isolates(arguments: ["Cadenza", "--probe"]))
        c("this very run is isolated and answers without asking the system",
          TCC.isolated && !TCC.axTrusted() && !TCC.listenAllowed() && !TCC.screenGranted() && !TCC.screenRequest() && TCC.micStatus() == .notDetermined && TCC.speechStatus() == .notDetermined)
        var asked: [String] = []
        TCC.requestMic { asked.append("mic:\($0)") }
        TCC.requestSpeech { asked.append("speech:\($0.rawValue)") }
        c("requests in isolated mode finish at once with no", asked == ["mic:false", "speech:0"])

        var probes = 0
        c("accessibility: not trusted never probes", !TCC.axWorking(trusted: { false }, probe: { probes += 1; return .success }) && probes == 0)
        c("accessibility: trusted but every call refused is not working", !TCC.axWorking(trusted: { true }, probe: { .apiDisabled }))
        c("accessibility: trusted and answering is working", TCC.axWorking(trusted: { true }, probe: { .success }))
        c("accessibility: no focused app is still working", TCC.axWorking(trusted: { true }, probe: { .noValue }) && TCC.axWorking(trusted: { true }, probe: { .cannotComplete }))

        var computed = 0
        let base = ProcessInfo.processInfo.systemUptime + 100_000   // later than anything the rest of the run cached
        let first = TCC.axWorkingCached(now: base, compute: { computed += 1; return true })
        let second = TCC.axWorkingCached(now: base + 0.5, compute: { computed += 1; return false })
        let third = TCC.axWorkingCached(now: base + 1.5, compute: { computed += 1; return false })
        TCC.forgetAXAnswer()
        c("accessibility: the answer is remembered for a second", first && second && !third && computed == 2)
    }
}
