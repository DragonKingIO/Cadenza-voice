import Foundation

struct LocalModelCheckResult: Codable {
    var modelID:String
    var version:String
    var checks:Int
    var failures:Int
    var loadMilliseconds:Int
    var cases:[Case]
    struct Case:Codable {var name:String;var passed:Bool;var errorRate:Double?;var decodeMilliseconds:Int?}
}

enum LocalModelHealthCheck {
    static func normalized(_ text:String)->String {
        text.lowercased().unicodeScalars.map {CharacterSet.alphanumerics.contains($0) ? String($0):" "}.joined().split(whereSeparator:{$0.isWhitespace}).joined(separator:" ")
    }
    static func errorRate(_ reference:String,_ actual:String,characters:Bool)->Double {
        let r=normalized(reference),a=normalized(actual)
        let expected=characters ? r.filter{!$0.isWhitespace}.map(String.init):r.split(separator:" ").map(String.init)
        let observed=characters ? a.filter{!$0.isWhitespace}.map(String.init):a.split(separator:" ").map(String.init)
        guard !expected.isEmpty else{return observed.isEmpty ? 0:1}
        var row=Array(0...observed.count)
        for (i,word) in expected.enumerated() {
            var next=[i+1]
            for (j,value) in observed.enumerated() {next.append(min(next[j]+1,row[j+1]+1,row[j]+(word==value ? 0:1)))}
            row=next
        }
        return Double(row.last!)/Double(expected.count)
    }
    static func run(dir:URL,entry:LocalModelEntry,options:LocalRecognitionOptions=LocalRecognitionOptions(),comprehensive:Bool=false)throws->LocalModelCheckResult {
        let start=ProcessInfo.processInfo.systemUptime
        let t=try LocalTranscriberLoader.load(dir:dir,entry:entry,options:options)
        var result=LocalModelCheckResult(modelID:entry.id,version:entry.version,checks:0,failures:0,loadMilliseconds:Int((ProcessInfo.processInfo.systemUptime-start)*1000),cases:[])
        func record(_ name:String,_ passed:Bool,rate:Double?=nil,ms:Int?=nil) {result.checks+=1;if !passed{result.failures+=1};result.cases.append(.init(name:name,passed:passed,errorRate:rate,decodeMilliseconds:ms))}
        record("vad-available",t.vadAvailable)
        let silence=[Float](repeating:0,count:16000*2)
        record("silence-empty",LocalDecoder.transcribe(silence,with:t).isEmpty)
        record("too-short-empty",LocalDecoder.transcribe([Float](repeating:0.1,count:1600),with:t).isEmpty)
        let sentences:[(String,String,String)] = entry.kind == "sensevoice" ? [
            ("en","Samantha","Hello world. This is a local speech recognition test."),
            ("zh","Tingting","今天天气很好，我们一起去公园散步。"),
            ("ja","Kyoko","今日は天気がいいです。一緒に公園に行きましょう。"),
            ("ko","Yuna","오늘 날씨가 좋습니다. 함께 공원에 가요.")
        ]:[
            ("en","Samantha","Hello world. This is a local speech recognition test."),
            ("fr","Thomas","Bonjour tout le monde. Ceci est un test de reconnaissance vocale."),
            ("de","Anna","Hallo Welt. Dies ist ein Test zur Erkennung von Sprache."),
            ("es","Mónica","Hola mundo. Esta es una prueba de reconocimiento de voz.")
        ]
        var firstClip:[Float]?
        for (language,voice,reference) in comprehensive ? sentences:[sentences[0]] {
            guard let clip=LocalModelFixtures.synthesize(reference,voice:voice) else {record(language+"-synthesis",false);continue}
            if firstClip==nil {firstClip=clip}
            let begin=ProcessInfo.processInfo.systemUptime
            let actual=LocalDecoder.transcribe(clip,with:t)
            let rate=errorRate(reference,actual,characters:["zh","ja","ko","yue"].contains(language))
            record(language+"-recognition",!actual.isEmpty && rate<=0.35,rate:rate,ms:Int((ProcessInfo.processInfo.systemUptime-begin)*1000))
            if comprehensive,rate>0.35 {
                let raw=t.transcribe(clip)
                print("[local-quality] synthetic=true language=\(language) actual=\(actual) raw=\(raw) vadSegments=\(t.speechSegments(clip))")
            }
            if language == "es",comprehensive, let alternative=LocalModelFixtures.synthesize(reference,voice:"Paulina") {
                let alternativeText=LocalDecoder.transcribe(alternative,with:t)
                let alternativeRate=errorRate(reference,alternativeText,characters:false)
                record("es-alternative-voice",!alternativeText.isEmpty && alternativeRate<=0.35,rate:alternativeRate)
                print("[local-quality] synthetic=true alternate-voice=Paulina actual=\(alternativeText)")
            }
            if language == "en",comprehensive {
                let quiet=LocalDecoder.transcribe(clip.map{$0*0.2},with:t)
                let quietRate=errorRate(reference,quiet,characters:false)
                record("en-quiet-synthetic",!quiet.isEmpty && quietRate<=0.35,rate:quietRate)
            }
        }
        if comprehensive {
            for language in entry.kind == "sensevoice" ? ["zh","en","ja","ko","yue"]:["en","fr","de","es"] {
                let wav=dir.appendingPathComponent("test_wavs/"+language+".wav")
                let clip=LocalModelFixtures.wavSamples(wav)
                let actual=LocalDecoder.transcribe(clip,with:t)
                record(language+"-upstream-sample",!clip.isEmpty && !actual.isEmpty)
                print("[local-quality] upstream=true language=\(language) text=\(actual)")
            }
        }
        if let firstClip,comprehensive {
            let long=Array(repeating:firstClip+silence,count:6).flatMap{$0}
            let segments=t.speechSegments(long)
            let begin=ProcessInfo.processInfo.systemUptime
            let text=LocalDecoder.transcribe(long,with:t)
            let expected=Array(repeating:sentences[0].2,count:6).joined(separator:" ")
            let rate=errorRate(expected,text,characters:false)
            record("long-paused-recognition",segments.count>=6 && !text.isEmpty && rate<=0.35,rate:rate,ms:Int((ProcessInfo.processInfo.systemUptime-begin)*1000))
            let noise=(0..<32000).map {i->Float in let n=UInt32(truncatingIfNeeded:i &* 1103515245 &+ 12345);return (Float(n%65536)/32768-1)*0.025}
            record("synthetic-noise-empty",LocalDecoder.transcribe(noise,with:t).isEmpty)
        }
        return result
    }
}

/// Explicit developer acceptance: uses production downloader/installer and real inference.
/// No microphone, credentials, cloud audio requests, insertion or clipboard use.
enum LocalModelAcceptance {
    static func run(download:Bool)->Int32 {
        let center=LocalModelCenter.shared
        guard LocalTranscriberLoader.supported else {print("[local-acceptance] FAIL inference-library-unavailable");return 1}
        center.validator={dir,entry in (try? LocalTranscriberLoader.load(dir:dir,entry:entry)) != nil}
        var failures=0
        for entry in LocalModelCatalog.builtin {
            if !center.isReady(entry.id),download {
                print("[local-acceptance] download-start model=\(entry.id) bytes=\(entry.downloadSize)");fflush(stdout)
                center.download(entry)
                let deadline=Date().addingTimeInterval(1800);var nextReport=Date()
                while Date()<deadline,!center.isReady(entry.id) {
                    if case .failed(let reason)=center.state(entry.id){print("[local-acceptance] FAIL download model=\(entry.id) reason=\(reason)");break}
                    if Date()>=nextReport {print("[local-acceptance] progress model=\(entry.id) state=\(center.state(entry.id))");fflush(stdout);nextReport=Date().addingTimeInterval(15)}
                    RunLoop.main.run(until:Date().addingTimeInterval(0.05))
                }
            }
            guard let dir=center.modelDir(entry.id),center.isReady(entry.id) else {print("[local-acceptance] FAIL model-not-installed id=\(entry.id)");failures+=1;continue}
            do {
                let result=try LocalModelHealthCheck.run(dir:dir,entry:entry,comprehensive:true)
                if let clip=LocalModelFixtures.synthesize("Hello world. This is a local speech recognition test.",voice:"Samantha") {
                    let capture=LocalModelFixtures.FakeCapture()
                    let recorder=LocalASRRecorder(modelID:entry.id,center:center,cache:LocalTranscriberCache(),capture:capture)
                    var finals=0,finalText:String?
                    recorder.onFinal={text in finals+=1;finalText=text}
                    let began=recorder.begin()
                    let pcm=clip.map {Int16(max(-1,min(1,$0))*32767)}
                    capture.onPCM?(pcm.withUnsafeBytes{Data($0)})
                    recorder.end()
                    let completed=LocalModelFixtures.wait(30){finals>0}
                    let passed=began && completed && finals==1 && LocalModelHealthCheck.errorRate("Hello world. This is a local speech recognition test.",finalText ?? "",characters:false)<=0.35
                    print("[local-acceptance] session model=\(entry.id) passed=\(passed) microphone=false");if !passed{failures+=1}
                    let fallbackCapture=LocalModelFixtures.FakeCapture();var primary:LocalModelFixtures.FakePrimary?
                    let fallback=FallbackRecordingSession(modelID:entry.id,capture:fallbackCapture,center:center,cache:LocalTranscriberCache(),makePrimary:{feed in let p=LocalModelFixtures.FakePrimary(capture:feed);primary=p;return p})
                    var fallbackFinals=0,fallbackText:String?
                    fallback.onFinal={text in fallbackFinals+=1;fallbackText=text}
                    let fallbackBegan=fallback.begin()
                    let split=pcm.count/2
                    fallbackCapture.onPCM?(Array(pcm.prefix(split)).withUnsafeBytes{Data($0)})
                    primary?.fail("synthetic-provider-disconnect")
                    _=LocalModelFixtures.wait(0.1){false}
                    fallbackCapture.onPCM?(Array(pcm.suffix(pcm.count-split)).withUnsafeBytes{Data($0)})
                    fallback.end()
                    let fallbackDone=LocalModelFixtures.wait(30){fallbackFinals>0}
                    let fallbackPassed=fallbackBegan && fallbackDone && fallbackFinals==1 && fallback.usedFallback && LocalModelHealthCheck.errorRate("Hello world. This is a local speech recognition test.",fallbackText ?? "",characters:false)<=0.35
                    print("[local-acceptance] fallback model=\(entry.id) passed=\(fallbackPassed) simulated-cloud=true network-audio=false");if !fallbackPassed{failures+=1}
                } else {failures+=1}
                let data=try JSONEncoder().encode(result)
                print("[local-acceptance] result "+String(decoding:data,as:UTF8.self));fflush(stdout)
                failures+=result.failures
            } catch {print("[local-acceptance] FAIL model=\(entry.id) load=\(error.localizedDescription)");failures+=1}
        }
        print("[local-acceptance] done failures=\(failures) microphone=false cloud-audio=false synthetic-speech=true");return failures==0 ? 0:1
    }
}
