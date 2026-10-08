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

        // The Keychain: tests get an in-memory store and never reach the real one
        let probeKey = "selftest.memory." + UUID().uuidString.prefix(8)
        c("keychain: a test run keeps credentials in memory", KeychainStore.set("secret", for: probeKey) && KeychainStore.has(probeKey) && KeychainStore.get(probeKey) == "secret")
        let realQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: KeychainStore.service, kSecAttrAccount as String: probeKey, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        c("keychain: and the real Keychain never sees it", SecItemCopyMatching(realQuery as CFDictionary, nil) == errSecItemNotFound)
        c("keychain: deleting works", KeychainStore.delete(probeKey) && !KeychainStore.has(probeKey) && KeychainStore.get(probeKey) == nil)
        c("keychain: label migration does nothing in a test run", KeychainStore.migrateLegacyLabels() == (0, 0) && KeychainStore.migrateAccessDescriptions() == (0, 0))

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
