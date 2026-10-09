import Foundation

/// Checks an explicit user-requested connection. Never creates a microphone or sends audio.
/// A successful handshake does not verify App ID, quota, or recognition results.
final class ProviderConnectionProbe {
    private let engine:ASREngine,options:CloudASROptions,credentials:[String:String]
    private let socketFactory:()->ASRSocket,http:ASRHTTP
    private let queue=DispatchQueue(label:"settings.connection-check")
    private var socket:ASRSocket?,timeout:DispatchWorkItem?,completion:((Bool)->Void)?
    private var terminal=false,started=false
    init(engine:ASREngine,options:CloudASROptions,credentials:[String:String],socketFactory:@escaping()->ASRSocket={NativeASRSocket()},http:ASRHTTP=NativeASRHTTP()){
        self.engine=engine;self.options=options;self.credentials=credentials;self.socketFactory=socketFactory;self.http=http
    }
    static func consoleURL(_ engine:ASREngine)->URL? {
        let addresses:[ASREngine:String]=[.deepgram:"https://console.deepgram.com",.iflytek:"https://console.xfyun.cn",.volcengine:"https://console.volcengine.com/speech/app",.tencent:"https://console.cloud.tencent.com/asr",.aliyun:"https://nls-portal.console.aliyun.com",.baidu:"https://console.bce.baidu.com/ai/#/ai/speech/overview/index",.openai:"https://platform.openai.com/api-keys",.groq:"https://console.groq.com/keys"]
        return addresses[engine].flatMap(URL.init(string:))
    }
    func start(completion:@escaping(Bool)->Void){queue.async{
        guard !self.started,!self.terminal else{return};self.started=true;self.completion=completion
        guard self.options.consent,self.engine != .apple,self.engine.credentialFields.allSatisfy({!(self.credentials[$0.0] ?? "").isEmpty}) else{self.finish(false);return}
        let timeout=DispatchWorkItem{[weak self] in self?.finish(false)};self.timeout=timeout;self.queue.asyncAfter(deadline:.now()+12,execute:timeout)
        if BatchTranscription.service(self.engine) != nil {self.checkKey()}else if self.engine == .aliyun || self.engine == .baidu {self.requestToken()}else{self.openSocket()}
    }}
    func cancel(){queue.async{self.terminal=true;self.completion=nil;self.cleanup()}}
    func synchronizeForTests(){queue.sync{}}
    func expireForTests(){queue.sync{finish(false)}}
    private func cleanup(){timeout?.cancel();timeout=nil;socket?.close();socket=nil;http.cancel()}
    private func finish(_ success:Bool){guard !terminal else{return};terminal=true;let callback=completion;completion=nil;cleanup();callback?(success)}
    private func openSocket(token:String?=nil){
        guard !terminal else{return}
        let request:URLRequest
        switch engine {
        case .deepgram:
            guard let r=DeepgramAPI.request(options:options,key:credentials["apikey"] ?? "") else{finish(false);return};request=r
        case .iflytek:
            guard let url=IflytekAuth.webSocketURL(apiKey:credentials["apikey"]!,apiSecret:credentials["apisecret"]!) else{finish(false);return};request=URLRequest(url:url)
        case .volcengine:
            var r=URLRequest(url:URL(string:"wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!);r.setValue(credentials["apikey"]!,forHTTPHeaderField:"X-Api-Key");r.setValue(options.model,forHTTPHeaderField:"X-Api-Resource-Id");r.setValue(UUID().uuidString,forHTTPHeaderField:"X-Api-Request-Id");r.setValue("-1",forHTTPHeaderField:"X-Api-Sequence");request=r
        case .tencent:
            guard let url=ASRAuth.tencent(appID:credentials["appid"]!,secretID:credentials["secretid"]!,secret:credentials["secretkey"]!,model:options.model,hotwords:options.hotwords,punc:options.punctuation,itn:options.itn,smoothing:options.smoothing) else{finish(false);return};request=URLRequest(url:url)
        case .aliyun:
            guard let token else{finish(false);return};var parts=URLComponents(string:"wss://nls-gateway-\(options.region).aliyuncs.com/ws/v1")!;parts.queryItems=[URLQueryItem(name:"token",value:token)];request=URLRequest(url:parts.url!)
        default:finish(false);return
        }
        let s=socketFactory();socket=s
        s.opened={[weak self] in self?.queue.async{self?.finish(true)}}
        s.failed={[weak self] in self?.queue.async{self?.finish(false)}}
        s.authRejected={[weak self] in self?.queue.async{self?.finish(false)}}
        // No send() call: even synthesized silence would be an audio upload.
        s.connect(request)
    }
    /// Batch services have no connection to open; their model list answers 200 for a valid key and sends no audio.
    private func checkKey(){
        guard let request=BatchTranscription.keyCheckRequest(engine,key:credentials["apikey"] ?? "",options:options) else{finish(false);return}
        http.exchange(request){[weak self] result in self?.queue.async{
            guard let self,!self.terminal else{return}
            if case .success(let reply)=result,(200...299).contains(reply.status){self.finish(true)}else{self.finish(false)}
        }}
    }
    private func requestToken(){
        let request:URLRequest
        if engine == .aliyun {
            let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone=TimeZone(secondsFromGMT:0);formatter.dateFormat="yyyy-MM-dd'T'HH:mm:ss'Z'"
            guard let url=ASRAuth.aliyunToken(key:credentials["accesskeyid"]!,secret:credentials["accesskeysecret"]!,timestamp:formatter.string(from:Date()),nonce:UUID().uuidString) else{finish(false);return};request=URLRequest(url:url)
        } else {
            var r=URLRequest(url:URL(string:"https://aip.baidubce.com/oauth/2.0/token")!);r.httpMethod="POST";r.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type");r.httpBody=Data(ASRAuth.sorted(["grant_type":"client_credentials","client_id":credentials["apikey"]!,"client_secret":credentials["secretkey"]!],encoded:true).utf8);request=r
        }
        http.request(request){[weak self] result in self?.queue.async{
            guard let self,!self.terminal else{return}
            guard case .success(let data)=result,data.count<=1048576,let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else{self.finish(false);return}
            if self.engine == .aliyun {
                guard let t=object["Token"] as? [String:Any],let value=t["Id"] as? String,!value.isEmpty,let expiry=t["ExpireTime"] as? Double,expiry>Date().timeIntervalSince1970+60 else{self.finish(false);return};self.openSocket(token:value)
            } else {
                guard let value=object["access_token"] as? String,!value.isEmpty,let seconds=object["expires_in"] as? Double,seconds>60 else{self.finish(false);return};self.finish(true)
            }
        }}
    }
}

enum SettingsReadiness:String {
    case ready,microphone,speech,accessibility,monitoring,credentials,consent,unavailable,shortcut
    static func evaluate(microphone:Bool,speech:Bool,accessibility:Bool,monitoring:Bool,configured:Bool,consent:Bool,engineAvailable:Bool,shortcutEnabled:Bool,systemEngine:Bool)->Self {
        if !microphone{return .microphone}
        if systemEngine && !speech{return .speech}
        if !accessibility{return .accessibility}
        if !monitoring{return .monitoring}
        if !configured{return .credentials}
        if !consent{return .consent}
        if !engineAvailable{return .unavailable}
        if !shortcutEnabled{return .shortcut}
        return .ready
    }
}
