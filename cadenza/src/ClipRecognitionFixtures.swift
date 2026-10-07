import Foundation

/// Scripted recognizers only: no microphone, no network, no models, no credentials.
enum ClipRecognitionFixtures {
    private final class FakeRecorder: HoldRecordingSession {
        var onLevel: ((Float) -> Void)?, onPartial: ((String) -> Void)?, onFinal: ((String?) -> Void)?
        var lastError: String?
        let beginResult: Bool, answer: String?, answers: Bool
        init(begin: Bool = true, answer: String? = nil, answers: Bool = true, error: String? = nil) { beginResult = begin; self.answer = answer; self.answers = answers; lastError = error }
        func begin() -> Bool { beginResult }
        func end() { guard answers else { return }; DispatchQueue.global().async { [self] in onFinal?(answer) } }
        func abort() { onFinal = nil }
    }

    static func run(_ check: (String, Bool) -> Void) {
        func c(_ name: String, _ ok: Bool) { check("Compare " + name, ok) }
        let clip = [Float](repeating: 0.2, count: 16000)
        func transcribe(_ r: @autoclosure () -> FakeRecorder, timeout: TimeInterval = 5) -> ClipResult {
            let recorder = r()
            return CloudClipTranscriber.transcribe(clip, provider: .deepgram, options: CloudASROptions(), credentials: [:], language: "zh_cn", speed: 400, timeout: timeout, makeRecorder: { _ in recorder })
        }

        // One clip through a cloud recorder
        c("cloud clip: text comes back", transcribe(FakeRecorder(answer: "你好")) == .text("你好"))
        c("cloud clip: nothing heard is an empty text, not a failure", transcribe(FakeRecorder(answer: nil)) == .text(""))
        c("cloud clip: a refused start reports why", transcribe(FakeRecorder(begin: false, error: "麦克风")) == .failed("麦克风"))
        c("cloud clip: an error reported with no text is a failure", transcribe(FakeRecorder(answer: nil, error: "鉴权拒绝")) == .failed("鉴权拒绝"))
        c("cloud clip: no answer in time is a failure", { if case .failed = transcribe(FakeRecorder(answers: false), timeout: 0.3) { return true }; return false }())

        // Which ways are listed
        let sense = LocalModelCatalog.builtin[0], second = LocalModelCatalog.builtin[1]
        let config = BridgeConfig.default()
        let list = CompareCandidates.available(config: config, locale: "zh-CN", localEntries: { _ in [sense, second] },
                                               cloudReady: { engine, _ in engine == .deepgram || engine == .tencent }, systemReady: { _ in true })
        c("candidates: local, then ready cloud, then system", list.map(\.id) == [sense.id, second.id, "cloud:tencent", "cloud:deepgram", CompareCandidate.systemID] || list.map(\.id) == [sense.id, second.id, "cloud:deepgram", "cloud:tencent", CompareCandidate.systemID])
        c("candidates: only cloud services that are ready appear", !list.contains { $0.id == "cloud:baidu" || $0.id == "cloud:aliyun" || $0.id == "cloud:iflytek" || $0.id == "cloud:volcengine" })
        c("candidates: cloud is marked as uploading, local and system are not", list.filter(\.uploadsAudio).count == 2 && list.filter { !$0.uploadsAudio }.count == 3)
        let none = CompareCandidates.available(config: config, locale: "zh-CN", localEntries: { _ in [] }, cloudReady: { _, _ in false }, systemReady: { _ in false })
        c("candidates: nothing set up means nothing listed", none.isEmpty)
        c("candidates: a service without consent or credentials is not ready", !CompareCandidates.cloudReady(.deepgram, config) && !CompareCandidates.cloudReady(.tencent, config))
        c("candidates: the built-in engine is never listed as cloud", !list.contains { $0.engine == .apple && $0.kind == .cloud })

        // A comparison across kinds
        let fake = FakeCapture()
        let prompts = VoiceCompare.prompts(forLocale: "zh-CN")
        let cloud = CompareCandidate.cloud(.deepgram), broken = CompareCandidate.cloud(.tencent), system = CompareCandidate.system()
        func make(selected: Set<String>? = nil) -> VoiceCompare {
            let compare = VoiceCompare(prompts: prompts, candidates: [.local(sense), cloud, broken, system], makeCapture: { fake }, recognizer: { candidate in
                switch candidate.id {
                case sense.id: return { samples in .text(prompts[min(prompts.count - 1, max(0, Int((Double(samples.count) / 16000).rounded()) - 2))]) }
                case cloud.id: return { samples in .text(prompts[min(prompts.count - 1, max(0, Int((Double(samples.count) / 16000).rounded()) - 2))] + "吧") }
                case broken.id: return { _ in .failed("鉴权拒绝") }
                default: return { _ in .text("") }
                }
            })
            if let selected { compare.selected = selected }
            for i in 0..<3 { compare.setClip(i, [Float](repeating: 0.2, count: 16000 * (i + 2))) }
            return compare
        }
        func wait(_ compare: VoiceCompare) { let end = Date().addingTimeInterval(10); while compare.analyzing && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) } }
        let all = make(); all.analyze(); wait(all)
        c("compare: every selected candidate takes part", all.ran == Set([sense.id, cloud.id, broken.id, system.id]) && all.results.count == prompts.count)
        c("compare: the perfect local result scores zero", all.averageError(0) == 0)
        c("compare: the cloud result is scored like any other", (all.averageError(1) ?? -1) > 0)
        c("compare: a failed service has no score and says why", all.averageError(2) == nil && all.failureReason(2) == "鉴权拒绝")
        c("compare: a failed service never wins", all.bestModel == 0)
        c("compare: heard-nothing is scored as all wrong but is not a failure", all.failureReason(3) == nil && (all.averageError(3) ?? 0) == 1)
        c("compare: failures do not count towards average time", all.averageSeconds(2) == nil)
        let partial = make(selected: [sense.id, cloud.id]); partial.analyze(); wait(partial)
        c("compare: unticked candidates are not run", partial.ran == Set([sense.id, cloud.id]) && partial.results.allSatisfy { $0[2] == nil && $0[3] == nil })
        c("compare: ticking and unticking", { let m = make(); m.toggle(cloud.id); let off = !m.selected.contains(cloud.id); m.toggle(cloud.id); return off && m.selected.contains(cloud.id) }())
        c("compare: cloud services that will upload are listed for the warning", make(selected: [sense.id, cloud.id]).cloudSelected.map(\.id) == [cloud.id])
        c("compare: nothing ticked cannot start", { let m = make(selected: []); return !m.canAnalyze }())
        c("compare: new recordings clear the results and the run list", { let m = make(); m.analyze(); wait(m); m.setClip(0, clip); return m.results.isEmpty && m.ran.isEmpty }())
    }

    private final class FakeCapture: CloudPCMCapturing {
        var onPCM: ((Data) -> Void)?, onLevel: ((Float) -> Void)?
        var hasSignal = true, startedUptime: TimeInterval? = nil, lastError: String? = nil
        func start(uid: String) -> Bool { true }
        func stop() {}
    }
}
