import Foundation

enum LocalModelRobustnessFixtures {
    final class VAD:LocalTranscriber {
        var vadAvailable=true
        var ranges:[Range<Int>]=[]
        var seen:[Int]=[]
        func speechSegments(_ s:[Float])->[Range<Int>] {ranges}
        func transcribe(_ s:[Float])->String {seen.append(s.count);return "hello"}
    }
    final class Blocking:LocalTranscriber {
        let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        func speechSegments(_ s:[Float])->[Range<Int>] {[]}
        func transcribe(_ s:[Float])->String {entered.signal();_ = release.wait(timeout:.now()+5);return "cancelled text"}
    }
    static func run(_ check:(String,Bool)->Void) {
        func c(_ name:String,_ ok:Bool){check("LocalRobustness "+name,ok)}
        let east=LocalModelCatalog.builtin[0],europe=LocalModelCatalog.builtin[1]
        c("unsupported language never selects arbitrary model",LocalModelCatalog.pick(forLanguages:["ar"],installed:[east,europe])==nil)
        c("fallback requires all intended languages",LocalModelCatalog.covers(east,languages:["zh-CN","en-US"]) && !LocalModelCatalog.covers(europe,languages:["zh","en"]))
        var setting=LocalModelSettings();setting.modelID=east.id
        c("automatic French primary chooses European model",FallbackPolicy.resolvePrimary(settings:setting,ready:[east,europe],recognitionLocale:"fr-FR")?.id==europe.id)
        setting.primaryModelID=east.id
        c("explicit primary preserved independently of system locale",FallbackPolicy.resolvePrimary(settings:setting,ready:[east,europe],recognitionLocale:"fr-FR")?.id==east.id)
        c("incompatible explicit fallback replaced with compatible model",FallbackPolicy.resolveModel(settings:setting,ready:[east,europe],languages:["fr"])?.id==europe.id)
        c("incompatible explicit fallback has no substitute",FallbackPolicy.resolveModel(settings:setting,ready:[east],languages:["fr"])==nil)
        var tencent=CloudASROptions.defaults(.tencent);tencent.model="16k_en"
        c("cloud language independent of unrelated iflytek preference",FallbackPolicy.languages(provider:.tencent,options:tencent,iflytekLanguage:"zh_cn",recognitionLocale:"zh-CN")==["en"])
        c("range validates resumed offset and full length",ResumableDownloader.validRange("bytes 100-999/1000",offset:100,total:1000) && !ResumableDownloader.validRange("bytes 0-999/1000",offset:100,total:1000) && !ResumableDownloader.validRange("bytes 100-999/2000",offset:100,total:1000))
        let vad=VAD(),samples=[Float](repeating:0.1,count:32000)
        c("short noise rejected by VAD before decoding",LocalDecoder.transcribe(samples,with:vad).isEmpty && vad.seen.isEmpty)
        vad.ranges=[8000..<16000]
        c("VAD keeps 0.8s on both speech edges",LocalDecoder.transcribe(samples,with:vad)=="hello" && vad.seen==[28800])
        vad.seen=[];vad.ranges=[20000..<21000,21500..<22500]
        c("neighbouring padded segments never overlap",{_=LocalDecoder.transcribe(samples,with:vad);return vad.seen.reduce(0,+)<=samples.count}())
        vad.seen=[];vad.ranges=[-1..<100,0..<640000]
        c("invalid VAD ranges never index audio",LocalDecoder.transcribe(samples,with:vad).isEmpty && vad.seen.isEmpty)
        c("nonfinite samples rejected",LocalDecoder.transcribe([Float](repeating:.nan,count:16000),with:vad).isEmpty)
        c("zero waveform rejected before inference",LocalDecoder.transcribe([Float](repeating:0,count:16000),with:vad).isEmpty)
        vad.ranges=[0..<800000];vad.seen=[]
        _=LocalDecoder.transcribe([Float](repeating:0.1,count:800000),with:vad)
        c("every long inference call bounded",vad.seen==[400000,400000])
        c("word error metric counts substitutions",LocalModelHealthCheck.errorRate("hello world","hello word",characters:false)==0.5)
        c("character error metric ignores punctuation",LocalModelHealthCheck.errorRate("今天天气很好。","今天天气很好",characters:true)==0)
        let temp=LocalModelFixtures.tempDir("robustness");defer{try? FileManager.default.removeItem(at:temp)}
        let center=LocalModelCenter(root:temp);var entry=east;entry.id="robustness-model";entry.requiredFiles=["model.int8.onnx"]
        center.testInject(entry);let dir=temp.appendingPathComponent(entry.id+"-"+entry.version);try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);try? Data([1]).write(to:dir.appendingPathComponent("model.int8.onnx"));center.testSetInstalled(entry.id,.init(version:entry.version,previous:nil,installedAt:Date()))
        let cache=LocalTranscriberCache();var loads=0;cache.loader={_,_,_ in loads+=1;return LocalModelFixtures.FakeTranscriber("hello")}
        _=try? cache.transcriber(for:entry.id,center:center)
        var options=LocalRecognitionOptions();options.useITN=false;_=try? cache.transcriber(for:entry.id,center:center,options:options)
        c("option changes invalidate cached model",loads==2)
        if LocalTranscriberLoader.supported {
            let cap=LocalModelFixtures.FakeCapture();let blocking=Blocking();cache.unload();cache.loader={_,_,_ in blocking}
            let recorder=LocalASRRecorder(modelID:entry.id,center:center,cache:cache,capture:cap);var finals=0
            recorder.onFinal={_ in finals+=1};_=recorder.begin();cap.feed(32000);recorder.end()
            var entered=false;_=LocalModelFixtures.wait{if entered{return true};entered=blocking.entered.wait(timeout:.now()) == .success;return entered}
            recorder.abort();blocking.release.signal();_=LocalModelFixtures.wait(0.4){false}
            c("cancel during final decoding never emits text",entered && finals==0)
            cache.unload();cache.loader={_,_,_ in LocalModelFixtures.FakeTranscriber("bounded")}
            var result:String?
            let limitCap=LocalModelFixtures.FakeCapture();let bounded=LocalASRRecorder(modelID:entry.id,center:center,cache:cache,capture:limitCap);bounded.sampleLimit=16000;bounded.onFinal={result=$0};_=bounded.begin();limitCap.feed(17000)
            c("recording limit auto-finishes instead of dropping tail silently",LocalModelFixtures.wait{result != nil} && result=="bounded" && limitCap.stops>0)
        }
    }
}
