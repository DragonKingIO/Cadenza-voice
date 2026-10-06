import Foundation

/// Synthetic audio, fake transport and fake credentials only; no provider, mic or Keychain reads.
enum DeepgramFixtures {
    private final class Capture:CloudPCMCapturing {
        var onPCM:((Data)->Void)?,onLevel:((Float)->Void)?,hasSignal=true,startedUptime:TimeInterval?=0,lastError:String?
        var starts=0,stops=0
        func start(uid:String)->Bool{starts+=1;return true};func stop(){stops+=1}
    }
    private final class Socket:ASRSocket {
        var opened:(()->Void)?,received:((URLSessionWebSocketTask.Message)->Void)?,failed:(()->Void)?,authRejected:(()->Void)?
        var requests:[URLRequest]=[],messages:[URLSessionWebSocketTask.Message]=[],closed=0
        func connect(_ request:URLRequest){requests.append(request)}
        func send(_ message:URLSessionWebSocketTask.Message,completion:@escaping(Bool)->Void){messages.append(message);completion(true)}
        func close(){closed+=1;opened=nil;received=nil;failed=nil;authRejected=nil}
    }
    private final class HTTP:ASRHTTP {
        var calls=0
        func request(_ request:URLRequest,completion:@escaping(Result<Data,Error>)->Void){calls+=1;completion(.failure(ASRFailure.protocolInvalid))}
        func cancel(){}
    }
    static func run(_ check:(String,Bool)->Void) {
        func c(_ name:String,_ ok:Bool){check("Deepgram "+name,ok)}
        func json(_ o:[String:Any])->URLSessionWebSocketTask.Message{try! ASRJSON.message(o)}
        func result(_ start:Double,_ duration:Double,_ text:String,_ final:Bool)->URLSessionWebSocketTask.Message {
            json(["type":"Results","start":start,"duration":duration,"is_final":final,"speech_final":final,"channel":["alternatives":[["transcript":text]]]])
        }
        func rejects(_ block:()throws->Void)->Bool{do{try block();return false}catch{return true}}
        c("configuration labels localized",["provider.console.deepgram","deepgram.step.1","deepgram.step.2","deepgram.step.3"].allSatisfy{L10n.tr($0) != $0})
        var options=CloudASROptions.defaults(.deepgram)
        c("defaults require consent",!options.consent && options.model == "nova-3")
        c("no request without consent",DeepgramAPI.request(options:options,key:"fake-key")==nil)
        options.consent=true
        let request=DeepgramAPI.request(options:options,key:"fake-key")!
        let query=Dictionary(uniqueKeysWithValues:URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!.map{($0.name,$0.value ?? "")})
        c("pinned secure endpoint, key in header only",request.url?.scheme=="wss" && request.url?.host=="api.deepgram.com" && request.value(forHTTPHeaderField:"Authorization")=="Token fake-key" && !request.url!.absoluteString.contains("fake-key"))
        c("PCM format and language",query["encoding"]=="linear16" && query["sample_rate"]=="16000" && query["channels"]=="1" && query["language"]=="multi")
        c("header injection rejected",DeepgramAPI.request(options:options,key:"fake\r\nInjected: value")==nil)
        var invalid=options;invalid.language="private-invalid";c("unsupported language rejected",DeepgramAPI.request(options:invalid,key:"fake")==nil)
        let decoded=try! JSONDecoder().decode(CloudASROptions.self,from:Data("{\"consent\":true,\"model\":\"nova-3\"}".utf8))
        c("old option payload retains language default",decoded.language=="multi")
        options.language="fr";c("new language persists",(try? JSONDecoder().decode(CloudASROptions.self,from:JSONEncoder().encode(options)))==options)
        c("fallback language independent of Chinese settings",DeepgramAPI.fallbackLanguages(options)==["fr"])
        let w=DeepgramWire()
        c("interim preview",(try? w.parse(result(0,1,"hello",false)))?.text=="hello")
        c("speech final is not session final",(try? w.parse(result(0,1,"Hello.",true)))?.final==false)
        c("duplicate final does not duplicate text",(try? w.parse(result(0,1,"Hello.",true)))?.text=="Hello.")
        c("new interim appended to stable text",(try? w.parse(result(1,1,"world",false)))?.text=="Hello. world")
        c("final segment appended",(try? w.parse(result(1,1,"World.",true)))?.text=="Hello. World.")
        c("late interim cannot revive text",(try? w.parse(result(0,1,"stale",false)))?.text=="Hello. World.")
        c("metadata before end is not final",(try? w.parse(json(["type":"Metadata","request_id":"fake-request","duration":2.0,"channels":1])))?.final==false)
        let ending=try! ASRJSON.object(w.audio(Data(),first:false,last:true))
        c("close command flushes server audio",ending["type"] as? String=="CloseStream")
        c("post-close metadata completes",(try? w.parse(json(["type":"Metadata","request_id":"fake-request","duration":2.0,"channels":1])))?.final==true)
        c("post-close audio refused",rejects{_ = try w.audio(Data([0,0]),first:false,last:false)})
        c("unknown result refused",rejects{_ = try DeepgramWire().parse(json(["type":"Results"]))})
        do {_ = try DeepgramWire().parse(json(["type":"Error","code":"401","description":"private-echo"]));c("service error",false)}
        catch let e as ASRServiceError {c("remote message never echoed",e.hint==L10n.tr("deepgram.auth") && !e.hint.contains("private-echo"))}catch{c("service error type",false)}

        let deniedCapture=Capture(),deniedSocket=Socket(),deniedHTTP=HTTP()
        let denied=CloudASRRecorder(provider:.deepgram,options:.defaults(.deepgram),credentials:["apikey":"fake"],capture:deniedCapture,http:deniedHTTP,socketFactory:{deniedSocket})
        c("no consent means no capture, connection or request",!denied.begin() && deniedCapture.starts==0 && deniedSocket.requests.isEmpty && deniedHTTP.calls==0)
        let cap=Capture(),sock=Socket(),http=HTTP()
        let recorder=CloudASRRecorder(provider:.deepgram,options:options,credentials:["apikey":"fake"],capture:cap,http:http,socketFactory:{sock})
        var finals=0,finalText:String?;recorder.onFinal={finals+=1;finalText=$0}
        c("begin captures once",recorder.begin() && cap.starts==1);recorder.synchronizeForTests();sock.opened?();recorder.synchronizeForTests()
        cap.onPCM?(Data(repeating:1,count:1282));recorder.synchronizeForTests();recorder.end();recorder.synchronizeForTests()
        for _ in 0..<8 {recorder.pumpForTests();recorder.synchronizeForTests()}
        c("stop sends all PCM including tail",sock.messages.reduce(0){total,message in if case .data(let bytes)=message{return total+bytes.count};return total}==1282)
        c("last message is close command",sock.messages.last.flatMap{try? ASRJSON.object($0)}?["type"] as? String=="CloseStream")
        sock.received?(result(0,0.0400625,"Fixture.",true));recorder.synchronizeForTests();c("finalized utterance cannot insert early",finals==0)
        sock.received?(json(["type":"Metadata","request_id":"fake-request","duration":2.0,"channels":1]));recorder.synchronizeForTests();c("completed session emits once",finals==1 && finalText=="Fixture.")
        let cancelCap=Capture(),cancelSocket=Socket();let cancelling=CloudASRRecorder(provider:.deepgram,options:options,credentials:["apikey":"fake"],capture:cancelCap,http:HTTP(),socketFactory:{cancelSocket})
        var cancelledFinals=0;cancelling.onFinal={_ in cancelledFinals+=1};_=cancelling.begin();cancelling.synchronizeForTests();let late=cancelSocket.received;cancelling.abort()
        late?(json(["type":"Metadata","request_id":"fake-request","duration":2.0,"channels":1]));cancelling.synchronizeForTests();c("cancel closes stream and ignores late callback",cancelledFinals==0 && cancelSocket.closed>0 && cancelCap.stops>0)
        let probeSocket=Socket(),probeHTTP=HTTP();let probe=ProviderConnectionProbe(engine:.deepgram,options:options,credentials:["apikey":"fake"],socketFactory:{probeSocket},http:probeHTTP)
        var connected=false;probe.start{connected=$0};probe.synchronizeForTests();probeSocket.opened?();probe.synchronizeForTests()
        c("connection test sends no audio",connected && probeSocket.messages.isEmpty && probeHTTP.calls==0)
    }
}
