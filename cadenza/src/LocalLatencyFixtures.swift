import Foundation

/// Scheduling and exact-input reuse, with synthetic audio and no microphone/network.
enum LocalLatencyFixtures {
    final class Counted: LocalTranscriber {
        var seen: [Int] = []
        var answer = "hello"
        func speechSegments(_ samples: [Float]) -> [Range<Int>] { [0..<samples.count] }
        func transcribe(_ samples: [Float]) -> String { seen.append(samples.count); return answer }
    }
    final class PreviewBlock: LocalTranscriber {
        let entered=DispatchSemaphore(value:0), release=DispatchSemaphore(value:0)
        var seen: [Int] = []
        func speechSegments(_ samples: [Float]) -> [Range<Int>] { [0..<samples.count] }
        func transcribe(_ samples: [Float]) -> String {
            seen.append(samples.count)
            if seen.count == 1 { entered.signal(); _ = release.wait(timeout:.now()+5) }
            return "hello"
        }
    }
    static func run(_ check: (String, Bool) -> Void) {
        func c(_ name: String, _ ok: Bool) { check("LocalLatency " + name, ok) }
        let audio=[Float](repeating:0.1,count:16000)
        let base=Counted(), memo=LocalMemoizedTranscriber(base,maxEntries:2)
        let first=memo.transcribe(audio), second=memo.transcribe(audio)
        c("identical input reuses the same text without another inference",first==second && base.seen.count==1 && memo.hits==1)
        var changed=audio; changed[changed.count-1]=0.11
        _=memo.transcribe(changed)
        c("even one changed sample needs a fresh inference",base.seen.count==2)
        _=memo.transcribe(audio); _=memo.transcribe([Float](repeating:0.2,count:16000)); _=memo.transcribe(changed)
        c("bounded memo evicts the least recently used input",base.seen.count==4)
        let oversized=Counted(); oversized.answer=String(repeating:"x",count:20)
        let tiny=LocalMemoizedTranscriber(oversized,maxTextBytes:10)
        c("oversized text is returned intact and never cached",tiny.transcribe(audio).count==20 && tiny.transcribe(audio).count==20 && oversized.seen.count==2)
        let sized=Counted();sized.answer="123456"
        let byteLimited=LocalMemoizedTranscriber(sized,maxTextBytes:10)
        _=byteLimited.transcribe(audio);_=byteLimited.transcribe(changed);_=byteLimited.transcribe(audio)
        c("the total text budget evicts entries even below the count limit",sized.seen.count==3)
        let empty=Counted();empty.answer=""
        let emptyMemo=LocalMemoizedTranscriber(empty)
        c("a cached empty answer remains empty",emptyMemo.transcribe(audio).isEmpty && emptyMemo.transcribe(audio).isEmpty && empty.seen.count==1)
        memo.shouldDecode={false}
        c("stopped precomputation starts no further inference",memo.transcribe(audio).isEmpty && base.seen.count==4)

        let short=Counted()
        c("precomputation never splits a short final sentence",LocalDecoder.transcribe(audio,with:short,completedOnly:true).isEmpty && short.seen.isEmpty)
        // Each 25-second chunk is distinct so an accidental duplicate is observable.
        let long=(0..<56*16000).map { Float(($0 / 400000) + 1) * 0.1 }
        let plain=Counted(), warmed=Counted(), reused=LocalMemoizedTranscriber(warmed)
        let expected=LocalDecoder.transcribe(long,with:plain)
        _=LocalDecoder.transcribe(Array(long.prefix(51*16000)),with:reused,completedOnly:true)
        c("only complete chunks are prepared while the tail is open",warmed.seen==[400000,400000])
        let actual=LocalDecoder.transcribe(long,with:reused)
        c("long final matches cold full decoding and only decodes the tail",actual==expected && warmed.seen==[400000,400000,96000] && reused.hits==2)
        var different=long; different[0]=0.12
        let before=warmed.seen.count
        _=LocalDecoder.transcribe(different,with:reused)
        c("a changed prefix is recomputed instead of trusting a stale result",warmed.seen.count==before+1)
        let quietPrefix=[Float](repeating:0.02,count:26*16000)
        let varyingGain=quietPrefix+[Float](repeating:0.049,count:30*16000)
        let faint=Counted(),faintMemo=LocalMemoizedTranscriber(faint)
        _=LocalDecoder.transcribe(quietPrefix,with:faintMemo,completedOnly:true)
        _=LocalDecoder.transcribe(varyingGain,with:faintMemo)
        c("global faint-speech gain changes invalidate previously prepared audio",faintMemo.decodes==4 && faintMemo.hits==0)
        let other=LocalMemoizedTranscriber(Counted())
        _=other.transcribe(Array(long.prefix(400000)))
        c("a different recognizer has an independent memo",other.decodes==1 && other.hits==0)

        guard LocalTranscriberLoader.supported else { return }
        let temp=LocalModelFixtures.tempDir("latency"); defer {try? FileManager.default.removeItem(at:temp)}
        let center=LocalModelCenter(root:temp)
        var entry=LocalModelCatalog.builtin[0];entry.id="latency-fixture";entry.requiredFiles=["model.int8.onnx"]
        center.testInject(entry)
        let dir=temp.appendingPathComponent(entry.id+"-"+entry.version)
        try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        try? Data([1]).write(to:dir.appendingPathComponent("model.int8.onnx"))
        center.testSetInstalled(entry.id,.init(version:entry.version,previous:nil,installedAt:Date()))
        let cache=LocalTranscriberCache(), blocking=PreviewBlock(), cap=LocalModelFixtures.FakeCapture()
        cache.loader={_,_,_ in blocking}
        let recorder=LocalASRRecorder(modelID:entry.id,center:center,cache:cache,capture:cap)
        var partials=0, finals=0, result:String?
        recorder.onPartial={_ in DispatchQueue.main.async {partials += 1}}
        recorder.onFinal={text in DispatchQueue.main.async {result=text;finals += 1}}
        _=recorder.begin();cap.feed(10*16000)
        var entered=false
        _=LocalModelFixtures.wait(3) {if entered{return true};entered=blocking.entered.wait(timeout:.now()) == .success;return entered}
        cap.feed(2*16000);recorder.end();recorder.end();blocking.release.signal()
        let finished=LocalModelFixtures.wait(3){finals==1}
        c("preview work is bounded while the full final keeps all audio",entered && finished && blocking.seen==[LocalASRRecorder.previewLimit,12*16000] && result=="hello")
        c("release suppresses late previews and duplicate end calls",partials==0 && finals==1 && cap.stops==1)
        recorder.abort()

        cache.unload()
        let cancelling=PreviewBlock(), cancelledCap=LocalModelFixtures.FakeCapture()
        cache.loader={_,_,_ in cancelling}
        let cancelled=LocalASRRecorder(modelID:entry.id,center:center,cache:cache,capture:cancelledCap)
        var callbacks=0
        cancelled.onPartial={_ in DispatchQueue.main.async {callbacks += 1}}
        cancelled.onFinal={_ in DispatchQueue.main.async {callbacks += 1}}
        _=cancelled.begin();cancelledCap.feed(30*16000)
        var warming=false
        _=LocalModelFixtures.wait(3){if warming{return true};warming=cancelling.entered.wait(timeout:.now()) == .success;return warming}
        cancelled.abort();cancelling.release.signal()
        _=LocalModelFixtures.wait(0.2){false}
        c("cancelling warm inference emits nothing and skips remaining work",warming && callbacks==0 && cancelling.seen==[400000])
    }
}
