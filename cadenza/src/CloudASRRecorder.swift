import Foundation

protocol ASRSocket:AnyObject {
    var opened:(()->Void)?{get set};var received:((URLSessionWebSocketTask.Message)->Void)?{get set};var failed:(()->Void)?{get set};var authRejected:(()->Void)?{get set}
    func connect(_ request:URLRequest);func send(_ message:URLSessionWebSocketTask.Message,completion:@escaping(Bool)->Void);func close()
}
final class NativeASRSocket:NSObject,ASRSocket,URLSessionWebSocketDelegate {
    var opened:(()->Void)?,received:((URLSessionWebSocketTask.Message)->Void)?,failed:(()->Void)?,authRejected:(()->Void)?
    private var session:URLSession?,task:URLSessionWebSocketTask?
    private let queue=DispatchQueue(label: "cadenza.asr.socket")
    func connect(_ request:URLRequest){queue.async{let cfg=URLSessionConfiguration.ephemeral;cfg.timeoutIntervalForRequest=10;self.session=URLSession(configuration:cfg,delegate:self,delegateQueue:nil);self.task=self.session?.webSocketTask(with:request);self.task?.maximumMessageSize=1048576;self.task?.resume();self.receive()}}
    func send(_ message:URLSessionWebSocketTask.Message,completion:@escaping(Bool)->Void){queue.async{guard let t=self.task else{completion(false);return};t.send(message){error in completion(error==nil)}}}
    private func receive(){guard let t=task else{return};t.receive{[weak self,weak t] r in self?.queue.async{guard let self=self,let t=t,self.task===t else{return};switch r{case .success(let m):self.received?(m);if self.task===t{self.receive()};case .failure:if let response=t.response as? HTTPURLResponse,[401,403].contains(response.statusCode){self.authRejected?()}else{self.failed?()}}}}}
    func urlSession(_ session:URLSession,webSocketTask:URLSessionWebSocketTask,didOpenWithProtocol proto:String?){queue.async{guard self.task===webSocketTask else{return};self.opened?()}}
    func urlSession(_ session:URLSession,webSocketTask:URLSessionWebSocketTask,didCloseWith closeCode:URLSessionWebSocketTask.CloseCode,reason:Data?){queue.async{guard self.task===webSocketTask else{return};self.failed?()}}
    func close(){queue.async{let old=self.task;self.task=nil;self.opened=nil;self.received=nil;self.failed=nil;self.authRejected=nil;old?.cancel(with:.goingAway,reason:nil);self.session?.invalidateAndCancel();self.session=nil}}
}

protocol ASRHTTP:AnyObject {
    func request(_ request:URLRequest,completion:@escaping(Result<Data,Error>)->Void)
    /// Like `request`, but a reply with any status comes back with the status and body, so a rejected key can be told from a dead network.
    func exchange(_ request:URLRequest,completion:@escaping(Result<(status:Int,data:Data),Error>)->Void)
    func cancel()
}
extension ASRHTTP {
    func exchange(_ request:URLRequest,completion:@escaping(Result<(status:Int,data:Data),Error>)->Void){self.request(request){completion($0.map{(200,$0)})}}
}
final class NativeASRHTTP:ASRHTTP {
    private let session:URLSession={let c=URLSessionConfiguration.ephemeral;c.timeoutIntervalForRequest=10;c.timeoutIntervalForResource=30;return URLSession(configuration:c)}()
    func request(_ request:URLRequest,completion:@escaping(Result<Data,Error>)->Void){session.dataTask(with:request){data,response,error in
        guard error==nil,let r=response as? HTTPURLResponse,(200...299).contains(r.statusCode),let d=data,d.count<=1048576 else{completion(.failure(ASRFailure.protocolInvalid));return};completion(.success(d))
    }.resume()}
    private let longSession:URLSession={let c=URLSessionConfiguration.ephemeral;c.timeoutIntervalForRequest=30;c.timeoutIntervalForResource=120;c.httpCookieStorage=nil;return URLSession(configuration:c)}()
    func exchange(_ request:URLRequest,completion:@escaping(Result<(status:Int,data:Data),Error>)->Void){longSession.dataTask(with:request){data,response,error in
        guard error==nil,let r=response as? HTTPURLResponse,let d=data,d.count<=1048576 else{completion(.failure(ASRFailure.protocolInvalid));return};completion(.success((r.statusCode,d)))
    }.resume()}
    func cancel(){session.invalidateAndCancel();longSession.invalidateAndCancel()}
}
struct ASRToken {let value:String;let expires:TimeInterval;func valid(now:TimeInterval=Date().timeIntervalSince1970)->Bool{!value.isEmpty && expires>now+60}}
final class ASRTokenCache {
    static let shared=ASRTokenCache();private let lock=NSLock();private var tokens:[String:ASRToken]=[:]
    func get(_ key:String)->ASRToken?{lock.lock();defer{lock.unlock()};guard let t=tokens[key],t.valid() else{tokens[key]=nil;return nil};return t}
    func put(_ token:ASRToken,key:String){lock.lock();defer{lock.unlock()};tokens[key]=token.valid() ? token:nil}
    func remove(_ key:String){lock.lock();defer{lock.unlock()};tokens[key]=nil}
}
// One serial state owner. UUID invalidates every socket/token/HTTP callback when cancelled or rotated.
class CloudASRRecorder:HoldRecordingSession {
    private let callbackLock=NSLock()
    private var levelCallback:((Float)->Void)?,partialCallback:((String)->Void)?,finalCallback:((String?)->Void)?
    var onLevel:((Float)->Void)?{get{callbackLock.lock();defer{callbackLock.unlock()};return levelCallback}set{callbackLock.lock();levelCallback=newValue;callbackLock.unlock()}}
    var onPartial:((String)->Void)?{get{callbackLock.lock();defer{callbackLock.unlock()};return partialCallback}set{callbackLock.lock();partialCallback=newValue;callbackLock.unlock()}}
    var onFinal:((String?)->Void)?{get{callbackLock.lock();defer{callbackLock.unlock()};return finalCallback}set{callbackLock.lock();finalCallback=newValue;callbackLock.unlock()}}
    private(set) var lastError:String?
    var captureStartedUptime:TimeInterval?{capture.startedUptime};var capturedAudioHasSignal:Bool?{capture.hasSignal}
    var microphoneUID=""
    private(set) var state=ASRState.connecting
    let provider:ASREngine,options:CloudASROptions,credentials:[String:String],language:String
    private let capture:CloudPCMCapturing,http:ASRHTTP,socketFactory:()->ASRSocket,queue=DispatchQueue(label: "cadenza.asr.session")
    private var socket:ASRSocket?,wire:ASRWire?,timer:DispatchSourceTimer?,deadline:DispatchWorkItem?
    private var id=UUID(),gate=ASRCompletionGate(),buffer=ASRPCMQueue(limit:256000),whole=Data(),prefix="",preview=""
    private var began=false
    private var ready=false,first=true,endSent=false,sending=false,userEnding=false,streamBytes=0,rotations=0,tokenRefreshes=0
    private var token:ASRToken?,startTime:TimeInterval=0,streamStart:TimeInterval=0
    private let ingressLock=NSLock();private var ingressBytes=0
    init(provider:ASREngine,options:CloudASROptions,credentials:[String:String],language:String="zh_cn",capture:CloudPCMCapturing=CloudPCMCapture(),http:ASRHTTP=NativeASRHTTP(),socketFactory:@escaping()->ASRSocket={NativeASRSocket()}) {self.provider=provider;self.options=options;self.credentials=credentials;self.language=language;self.capture=capture;self.http=http;self.socketFactory=socketFactory}
    func begin()->Bool {
        guard !began,state == .connecting,provider != .apple else{return false}
        guard provider.credentialFields.allSatisfy({!(credentials[$0.0] ?? "").isEmpty}) else{lastError=ASRUserMessage.describe("识别凭据尚未完整配置");state = .failed;return false}
        if provider == .deepgram, !options.consent || ASROptionPolicy.validate(provider,options) != nil {lastError=L10n.tr(options.consent ? "deepgram.invalidOptions":"deepgram.consentRequired");state = .failed;return false}
        if BatchTranscription.service(provider) != nil, !options.consent || ASROptionPolicy.validate(provider,options) != nil {lastError=L10n.tr(options.consent ? "batch.invalidOptions":"batch.consentRequired");state = .failed;return false}
        began=true
        capture.onLevel={[weak self] v in self?.onLevel?(v)}
        capture.onPCM={[weak self] data in
            guard let self=self else{return}
            self.ingressLock.lock();let accepted=self.ingressBytes+data.count<=256000;if accepted{self.ingressBytes+=data.count};self.ingressLock.unlock()
            guard accepted else{self.queue.async{self.fail("音频发送缓冲已满，请检查连接后重试")};return}
            self.queue.async{self.ingressLock.lock();self.ingressBytes-=data.count;self.ingressLock.unlock();self.ingest(data)}
        }
        guard capture.start(uid:microphoneUID) else{lastError=capture.lastError ?? "麦克风采集失败";state = .failed;capture.onPCM=nil;capture.onLevel=nil;return false}
        startTime=ProcessInfo.processInfo.systemUptime
        queue.async{self.connect()};return true
    }
    /// Optional diagnostic observer: successful nonempty audio-frame send completion, no contents.
    var onAudioSendCompleted:((TimeInterval)->Void)?
    func synchronizeForTests(){queue.sync{}}
    func pumpForTests(){queue.sync{tick()}}
    func expireForTests(){queue.sync{fail("识别连接或最终结果等待超时；未提交部分结果")}}
    func end(){capture.stop();queue.async{guard !self.gate.terminal else{return};if self.capture.lastError != nil{self.fail("麦克风音频转换失败，未提交文字");return};self.userEnding=true;self.gate.userEnded();self.transition(.finishing);self.armDeadline(10)
        if self.provider == .baidu {self.uploadBaidu()} else if BatchTranscription.service(self.provider) != nil {self.armDeadline(60);self.uploadTranscription()} // Streaming tail continues on its provider timer; no release-time burst.
    }}
    func abort(){capture.stop();onFinal=nil;onPartial=nil;onLevel=nil;queue.sync{guard !gate.terminal else{cleanup();return};gate.cancel();transition(.cancelled);cleanup();buffer=ASRPCMQueue(limit:256000);whole.removeAll();preview="";prefix=""}}
    private func transition(_ s:ASRState){state=s;Log.write("asr provider=\(provider.rawValue) state=\(s.rawValue)")}
    private func cleanup(){id=UUID();socket?.close();socket=nil;timer?.cancel();timer=nil;deadline?.cancel();deadline=nil;http.cancel();capture.onPCM=nil;capture.onLevel=nil}
    private func fail(_ hint:String){guard !gate.terminal else{return};Log.write("asr-failure provider=\(provider.rawValue) reason=\(hint)");lastError=ASRUserMessage.describe(hint);gate.cancel();transition(.failed);capture.stop();cleanup();whole.removeAll();buffer=ASRPCMQueue(limit:256000);let callback=onFinal;onFinal=nil;onPartial=nil;callback?(nil)}
    private func finish(_ text:String){guard gate.take() else{return};transition(.completed);capture.stop();cleanup();whole.removeAll();buffer=ASRPCMQueue(limit:256000);let cb=onFinal;onFinal=nil;onPartial=nil;cb?(text.isEmpty || !capture.hasSignal ? nil:text)}
    private func armDeadline(_ seconds:Double){deadline?.cancel();let current=id;let w=DispatchWorkItem{[weak self] in guard let self=self,self.id==current,!self.gate.terminal else{return};self.fail("识别连接或最终结果等待超时；未提交部分结果")};deadline=w;queue.asyncAfter(deadline:.now()+seconds,execute:w)}
    private func ingest(_ data:Data){guard !gate.terminal,!userEnding else{return};do{
        if provider.uploadsWholeRecording {guard whole.count+data.count<=provider.wholeRecordingSeconds*32000 else{fail(provider == .baidu ? "百度短语音最多60秒；本次超限未上传，请缩短录音":L10n.format("batch.err.limit",destinationName,String(provider.wholeRecordingSeconds)));return};whole.append(data)}
        else{try buffer.append(data)}
    }catch{fail("音频发送缓冲已满，请检查连接后重试")}}
    private var cacheKey:String {provider.rawValue+":"+credentials.keys.sorted().map{credentials[$0] ?? ""}.joined(separator:"\u{0}").data(using:.utf8)!.sha256Hex}
    private func connect(){guard !gate.terminal else{return};id=UUID();first=true;endSent=false;sending=false;ready=false;streamBytes=0;streamStart=ProcessInfo.processInfo.systemUptime;transition(userEnding ? .finishing:.connecting);armDeadline(10)
        if provider.uploadsWholeRecording {transition(userEnding ? .finishing:.capturing);deadline?.cancel();return}
        if provider == .aliyun {obtainToken{[weak self] t in self?.openSocket(token:t.value)}}else{openSocket(token:nil)}
    }
    private func openSocket(token:String?){guard !gate.terminal else{return}
        let request:URLRequest
        switch provider {
        case .deepgram:
            guard let r=DeepgramAPI.request(options:options,key:credentials["apikey"] ?? "") else{fail(L10n.tr("deepgram.invalidOptions"));return};request=r;wire=DeepgramWire()
        case .iflytek:
            guard let u=IflytekAuth.webSocketURL(apiKey:credentials["apikey"]!,apiSecret:credentials["apisecret"]!) else{fail("讯飞鉴权参数无效");return};request=URLRequest(url:u);wire=IATWire(appID:credentials["appid"]!,language:language,options:options)
        case .volcengine:
            var r=URLRequest(url:URL(string:"wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!);r.setValue(credentials["apikey"]!,forHTTPHeaderField:"X-Api-Key");r.setValue(options.model,forHTTPHeaderField:"X-Api-Resource-Id");r.setValue(UUID().uuidString,forHTTPHeaderField:"X-Api-Request-Id");r.setValue("-1",forHTTPHeaderField:"X-Api-Sequence");request=r;wire=VolcengineWire(options:options)
        case .tencent:
            let voiceID=UUID().uuidString
            guard let u=ASRAuth.tencent(appID:credentials["appid"]!,secretID:credentials["secretid"]!,secret:credentials["secretkey"]!,model:options.model,hotwords:options.hotwords,punc:options.punctuation,itn:options.itn,smoothing:options.smoothing,voiceID:voiceID) else{fail("腾讯鉴权参数无效");return};request=URLRequest(url:u);wire=TencentWire(voiceID:voiceID)
        case .aliyun:
            guard let token=token else{fail("阿里Token未取得");return};var c=URLComponents(string:"wss://nls-gateway-\(options.region).aliyuncs.com/ws/v1")!;c.queryItems=[URLQueryItem(name:"token",value:token)];request=URLRequest(url:c.url!);wire=AliyunWire(taskID:UUID().uuidString.replacingOccurrences(of:"-",with:""),appKey:credentials["appkey"]!,options:options)
        default:fail("识别引擎不可用");return
        }
        let current=id,s=socketFactory();socket=s
        s.opened={[weak self] in self?.queue.async{guard let self=self,self.id==current,!self.gate.terminal,let w=self.wire else{return}
            if let start=w.start {self.send(start){self.markReadyIfNeeded(w.readyOnOpen)}} else{self.markReadyIfNeeded(w.readyOnOpen)}
        }}
        s.received={[weak self] m in self?.queue.async{guard let self=self,self.id==current,!self.gate.terminal else{return};self.receive(m)}}
        s.failed={[weak self] in self?.queue.async{guard let self=self,self.id==current,!self.gate.terminal else{return};self.fail("识别连接中断；未提交未确认结果")}}
        s.authRejected={[weak self] in self?.queue.async{guard let self=self,self.id==current,!self.gate.terminal else{return};if self.provider == .aliyun,self.streamBytes==0,self.tokenRefreshes==0{self.renewNLS()}else{self.fail("服务鉴权拒绝，请核对凭据及授权；未跨厂商重试")}}}
        s.connect(request)
        let timer=DispatchSource.makeTimerSource(queue:queue);timer.schedule(deadline:.now()+0.04,repeating:wire!.interval);timer.setEventHandler{[weak self] in self?.tick()};timer.resume();self.timer=timer
    }
    private func markReadyIfNeeded(_ value:Bool){guard value,!ready else{return};ready=true;deadline?.cancel();transition(.ready);transition(userEnding ? .finishing:.capturing);if userEnding{armDeadline(10)}}
    private func send(_ message:URLSessionWebSocketTask.Message,completion:(()->Void)?=nil){guard let s=socket,!gate.terminal else{return};sending=true;let current=id;s.send(message){[weak self] ok in self?.queue.async{guard let self=self,self.id==current,!self.gate.terminal else{return};self.sending=false;if ok{completion?()}else{self.fail("音频或控制帧发送失败；未提交部分结果")}}}}
    private func tick(){guard !gate.terminal,ready,!sending,!endSent,let w=wire else{return}
        if ProcessInfo.processInfo.systemUptime-startTime>600{fail("云端录音超过10分钟上限");return}
        do {
            if let cap=w.rotateAfterBytes,streamBytes>=cap {
                endSent=true;send(try w.audio(Data(),first:first,last:true));armDeadline(10);return
            }
            if let data=buffer.take(w.frameBytes,tail:userEnding) {send(try w.audio(data,first:first,last:false)){[weak self] in self?.onAudioSendCompleted?(ProcessInfo.processInfo.systemUptime)};first=false;streamBytes+=data.count;return}
            if userEnding {
                // IAT requires a status=0 frame even when released before the first full chunk.
                if first && provider == .iflytek{send(try w.audio(Data(),first:true,last:false));first=false;return}
                endSent=true;send(try w.audio(Data(),first:first,last:true));armDeadline(10)
            }
        }catch{fail("音频协议编码失败")}
    }
    private func receive(_ message:URLSessionWebSocketTask.Message){do{
        guard let w=wire else{return};let update=try w.parse(message);markReadyIfNeeded(update.ready)
        if let text=update.text{preview=text;onPartial?(prefix+text)}
        if update.final {
            guard provider == .iflytek || endSent else{fail("服务提前结束，未确认全部音频；请重试");return}
            if provider == .iflytek && (!userEnding || !buffer.bytes.isEmpty) {
                guard endSent || !sending else{fail("讯飞提前结束时仍有未确认发送帧；请重试");return}
                guard (prefix+preview).utf8.count<=1048576 else{fail("识别文本超过会话限制");return}
                // An unsolicited VAD ending has no consumed-audio watermark. Continue preview,
                // but prevent automatic external insertion when its tail boundary is unverified.
                if !endSent{lastError=L10n.tr("ui.94eb224cace4");Log.write("asr-tail-unverified provider=iflytek retention-only=true")}
                // Preserve unsent PCM across VAD/55s stream boundaries; only confirmed text enters prefix.
                prefix += preview;preview="";rotations+=1;guard rotations<30 else{fail("讯飞续接次数达到上限");return}
                socket?.close();socket=nil;timer?.cancel();timer=nil;connect();return
            }
            guard endSent else{fail("服务在录音结束帧前结束；本次结果仅保留预览");return}
            gate.streamConfirmed();finish(prefix+preview)
        }
    }catch let error as ASRServiceError{
        // Retry expired NLS token once only before any PCM was transmitted.
        if provider == .aliyun,streamBytes==0,tokenRefreshes==0,error.code == 40000001 {renewNLS()}else{fail(error.hint)}
    }catch{fail("识别响应格式无效；未提交部分结果")}}
    private func renewNLS(){tokenRefreshes+=1;ASRTokenCache.shared.remove(cacheKey);socket?.close();timer?.cancel();timer=nil;connect()}
    private func obtainToken(_ done:@escaping(ASRToken)->Void){if let cached=ASRTokenCache.shared.get(cacheKey){token=cached;done(cached);return}
        let request:URLRequest
        if provider == .aliyun {
            let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.timeZone=TimeZone(secondsFromGMT:0);f.dateFormat="yyyy-MM-dd'T'HH:mm:ss'Z'"
            guard let u=ASRAuth.aliyunToken(key:credentials["accesskeyid"]!,secret:credentials["accesskeysecret"]!,timestamp:f.string(from:Date()),nonce:UUID().uuidString) else{fail("Token鉴权请求无效");return};request=URLRequest(url:u)
        } else {
            var r=URLRequest(url:URL(string:"https://aip.baidubce.com/oauth/2.0/token")!);r.httpMethod="POST";r.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type");r.httpBody=Data(ASRAuth.sorted(["grant_type":"client_credentials","client_id":credentials["apikey"]!,"client_secret":credentials["secretkey"]!],encoded:true).utf8);request=r
        }
        let current=id;http.request(request){[weak self] response in self?.queue.async{guard let self=self,self.id==current,!self.gate.terminal else{return};do {
            let data=try response.get();guard let o=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw ASRFailure.tokenInvalid}
            let token:ASRToken
            if self.provider == .aliyun {guard let t=o["Token"] as? [String:Any],let value=t["Id"] as? String,let expiry=t["ExpireTime"] as? Double else{throw ASRFailure.tokenInvalid};token=ASRToken(value:value,expires:expiry)}
            else {guard let value=o["access_token"] as? String,let seconds=o["expires_in"] as? Double,seconds>60 else{throw ASRFailure.tokenInvalid};token=ASRToken(value:value,expires:Date().timeIntervalSince1970+seconds)}
            guard token.valid() else{throw ASRFailure.tokenInvalid};self.token=token;ASRTokenCache.shared.put(token,key:self.cacheKey);done(token)
        }catch{self.fail("Token获取失败，请核对凭据、服务授权和网络")}}}
    }
    private var destinationName:String{let n=BatchTranscription.destination(provider,options);return n.isEmpty ? provider.title:n}
    private func uploadTranscription(){guard userEnding,!gate.terminal else{return}
        guard !whole.isEmpty,whole.count%2==0 else{fail(L10n.format("batch.err.empty",destinationName));return}
        guard capture.hasSignal else{gate.streamConfirmed();finish("");return}
        guard let request=BatchTranscription.request(provider,options:options,key:credentials["apikey"] ?? "",pcm:whole) else{fail(L10n.tr("batch.invalidOptions"));return}
        let current=id
        http.exchange(request){[weak self] result in self?.queue.async{guard let self=self,self.id==current,!self.gate.terminal else{return}
            do{let reply=try result.get();let text=try BatchTranscription.parse(status:reply.status,data:reply.data,engine:self.provider,name:BatchTranscription.destination(self.provider,self.options),options:self.options);self.gate.streamConfirmed();self.finish(text)}
            catch let error as ASRServiceError{self.fail(error.hint)}
            catch{self.fail(L10n.format("batch.err.network",self.destinationName))}
        }}
    }
    private func uploadBaidu(){guard userEnding,!gate.terminal else{return};guard !whole.isEmpty,whole.count<=60*32000,whole.count%2==0 else{fail("百度音频为空或超出60秒限制");return}
        guard capture.hasSignal else{gate.streamConfirmed();finish("");return}
        obtainToken{[weak self] token in guard let self=self else{return};do {
            let body=try BaiduASR.body(pcm:self.whole,token:token.value,model:self.options.model,vocabularyID:self.options.vocabularyID)
            var r=URLRequest(url:URL(string:"https://vop.baidu.com/server_api")!);r.httpMethod="POST";r.setValue("application/json",forHTTPHeaderField:"Content-Type");r.httpBody=body
            let current=self.id;self.http.request(r){[weak self] response in self?.queue.async{guard let self=self,self.id==current,!self.gate.terminal else{return};do{let data=try response.get();let text=try BaiduASR.parse(data);self.gate.streamConfirmed();self.finish(text)}catch let error as ASRServiceError {
                if error.code == 3302,self.tokenRefreshes==0{self.tokenRefreshes+=1;ASRTokenCache.shared.remove(self.cacheKey);self.uploadBaidu()}else{self.fail(error.hint)}
            }catch{self.fail("百度识别响应无效或请求失败")}}}
        }catch{self.fail("百度音频请求不符合接口限制")}}
    }
}
import CryptoKit
extension Data {var sha256Hex:String{SHA256.hash(data:self).map{String(format:"%02x",$0)}.joined()}}
enum BaiduASR {
    static func body(pcm:Data,token:String,model:String,vocabularyID:String="")throws->Data {guard !pcm.isEmpty,pcm.count%2==0,pcm.count<=1920000,let pid=Int(model),[1537,1737,1637,1837].contains(pid) else{throw ASRFailure.protocolInvalid}
        var o:[String:Any]=["format":"pcm","rate":16000,"channel":1,"cuid":"cadenza","token":token,"dev_pid":pid,"len":pcm.count,"speech":pcm.base64EncodedString()];if !vocabularyID.isEmpty,pid==1537{guard let id=Int(vocabularyID) else{throw ASRFailure.protocolInvalid};o["lm_id"]=id};return try JSONSerialization.data(withJSONObject:o)
    }
    static func parse(_ data:Data)throws->String {guard data.count<=1048576,let o=try JSONSerialization.jsonObject(with:data) as? [String:Any],let code=o["err_no"] as? Int else{throw ASRFailure.protocolInvalid};guard code==0 else{throw ASRServiceError(hint:ASRServiceErrors.describe(.baidu,code:code),code:code)};guard let results=o["result"] as? [String],let first=results.first else{throw ASRFailure.protocolInvalid};return first}
}

enum ASRUserMessage {
    static func describe(_ detail: String) -> String {
        switch detail {
        case "识别凭据尚未完整配置": return L10n.tr("ui.8fcebdbca7f8")
        case "音频发送缓冲已满，请检查连接后重试": return L10n.tr("ui.0967c73a0fe0")
        case "识别连接或最终结果等待超时；未提交部分结果": return L10n.tr("ui.cfe394b741d4")
        case "麦克风音频转换失败，未提交文字": return L10n.tr("ui.991696f5a8bd")
        case "讯飞鉴权参数无效": return L10n.tr("ui.67702f1ed66f")
        case "腾讯鉴权参数无效": return L10n.tr("ui.4de146b64bdd")
        case "阿里Token未取得": return L10n.tr("ui.5cbda6156ad9")
        case "识别连接中断；未提交未确认结果": return L10n.tr("ui.c772643e1e7a")
        case "服务鉴权拒绝，请核对凭据及授权；未跨厂商重试": return L10n.tr("ui.3e1ab447178d")
        case "音频或控制帧发送失败；未提交部分结果": return L10n.tr("ui.1b5ebfeb8c64")
        case "音频协议编码失败": return L10n.tr("ui.028a7dbb433f")
        case "服务提前结束，未确认全部音频；请重试": return L10n.tr("ui.baf021077064")
        case "讯飞提前结束时仍有未确认发送帧；请重试": return L10n.tr("ui.b0fa1ffd6aed")
        case "服务在录音结束帧前结束；本次结果仅保留预览": return L10n.tr("ui.4be73b88365c")
        case "识别响应格式无效；未提交部分结果": return L10n.tr("ui.41c99b13fe2c")
        case "Token鉴权请求无效": return L10n.tr("ui.3aefe62e9f0e")
        case "Token获取失败，请核对凭据、服务授权和网络": return L10n.tr("ui.c5952c54fde6")
        case "百度识别响应无效或请求失败": return L10n.tr("ui.1100fffe3350")
        case "百度音频请求不符合接口限制": return L10n.tr("ui.77d90782a631")
        default: return detail
        }
    }
}
