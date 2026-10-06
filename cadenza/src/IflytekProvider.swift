import AVFoundation
import CryptoKit
import Foundation

// MARK: - 讯飞开放平台 · 语音听写（流式 WebSocket）Provider
// 协议: wss://iat-api.xfyun.cn/v2/iat（官方文档 xfyun.cn/doc/asr/voicedictation/API.html）
// 鉴权: 握手 URL 附 HMAC-SHA256 签名（host / date / authorization）
// 音频: 16k/16bit/单声道 PCM，1280 字节每帧、40ms 节奏；首帧 status=0、尾帧 status=2
// 结果: data.result.ws[].cw[].w 拼接；ls=true 表示结束；code!=0 为服务端错误
// 凭据: 仅从钥匙串读取，不写源码/配置/日志

struct IflytekCredentials {
    var appId: String
    var apiKey: String
    var apiSecret: String

    static func fromKeychain() -> IflytekCredentials? {
        guard let a = KeychainStore.get("iflytek.appid"), !a.isEmpty,
              let k = KeychainStore.get("iflytek.apikey"), !k.isEmpty,
              let s = KeychainStore.get("iflytek.apisecret"), !s.isEmpty else { return nil }
        return IflytekCredentials(appId: a, apiKey: k, apiSecret: s)
    }
}

enum IflytekAuth {
    static func webSocketURL(apiKey: String, apiSecret: String,
                             host: String = "iat-api.xfyun.cn", path: String = "/v2/iat", now:Date=Date()) -> URL? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let date = df.string(from: now)

        let origin = "host: \(host)\ndate: \(date)\nGET \(path) HTTP/1.1"
        let sig = Data(HMAC<SHA256>.authenticationCode(for: Data(origin.utf8),
                                                      using: SymmetricKey(data: Data(apiSecret.utf8)))).base64EncodedString()
        let authOrigin = "api_key=\"\(apiKey)\", algorithm=\"hmac-sha256\", headers=\"host date request-line\", signature=\"\(sig)\""
        let auth = Data(authOrigin.utf8).base64EncodedString()

        var comps = URLComponents()
        comps.scheme = "wss"
        comps.host = host
        comps.path = path
        comps.queryItems = [
            URLQueryItem(name: "authorization", value: auth),
            URLQueryItem(name: "date", value: date),
            URLQueryItem(name: "host", value: host),
        ]
        return comps.url
    }
}

enum IflytekErrors {
    /// 把服务端错误码翻译成用户可读的原因
    static func describe(code: Int, message: String) -> String {
        let hint: String
        switch code {
        case 11200: hint = L10n.tr("ui.af1f354358ba")
        case 11201: hint = L10n.tr("ui.97061a329ffc")
        case 10005, 10105: hint = L10n.tr("ui.bf15d4bf687b")
        case 10006, 10106: hint = L10n.tr("ui.91aa3198b2ea")
        case 10163, 10164, 10165: hint = L10n.tr("ui.dfe2cd840945")
        case 11202: hint = L10n.tr("ui.2f055b8fc969")
        case 11203: hint = L10n.tr("ui.ef971682b208")
        default: hint = L10n.tr("ui.5e9773cdf727")
        }
        Log.write("asr-service-error provider=iflytek code=\(code)")
        return L10n.format("engine.failure", ASREngine.iflytek.title, hint)
    }
}

// MARK: - 统一录音会话接口（Apple 引擎与讯飞引擎共用）

protocol HoldRecordingSession: AnyObject {
    var onLevel: ((Float) -> Void)? { get set }
    var onPartial: ((String) -> Void)? { get set }
    var onFinal: ((String?) -> Void)? { get set }
    var lastError: String? { get }
    var captureStartedUptime:TimeInterval? { get }
    var capturedAudioHasSignal:Bool? { get }
    /// 回退到本地模型时的提示（成功输入后附在结果后面）
    var fallbackNotice:String? { get }
    func begin() -> Bool
    func end()
    func abort()
}

extension HoldRecordingSession {var captureStartedUptime:TimeInterval? {nil};var capturedAudioHasSignal:Bool? {nil};var fallbackNotice:String? {nil}}

// Native IAT uses the shared capture, paced transport, and final-result gate.
final class IflytekRecorder: CloudASRRecorder {
    init(credentials:IflytekCredentials,language:String,options:CloudASROptions=CloudASROptions()) {
        super.init(provider:.iflytek,options:options,credentials:["appid":credentials.appId,"apikey":credentials.apiKey,"apisecret":credentials.apiSecret],language:language)
    }
    static func autoLanguage(forSourceID sourceID:String?)->String {sourceID?.contains("keylayout")==true ? "en_us":"zh_cn"}
    static func resolveLanguage(_ pref:String,forSourceID sourceID:String?)->String {pref=="auto" ? autoLanguage(forSourceID:sourceID):pref=="en_us" ? "en_us":"zh_cn"}
    /// 真实连接测试：鉴权握手 + 一帧静音 + 尾帧，按服务端 code 判定（消耗 1 次听写额度，如实标注）
    static func testConnection(credentials:IflytekCredentials,completion:@escaping(Bool,String)->Void) {
        guard let url = IflytekAuth.webSocketURL(apiKey:credentials.apiKey,apiSecret:credentials.apiSecret) else {
            completion(false,"鉴权 URL 生成失败：请核对 API Key / API Secret");return
        }
        let probe=IATConnectionProbe(credentials:credentials){ ok,msg in
            DispatchQueue.main.async{ completion(ok,msg) }
        }
        probe.start(url:url)
    }
}


// MARK: - IAT 连接探针：独立会话，握手后发静音首帧+尾帧，按服务端 code 判定鉴权与额度

private final class IATConnectionProbe:NSObject,URLSessionWebSocketDelegate {
    private let credentials:IflytekCredentials
    private let finish:(Bool,String)->Void
    private var session:URLSession?,task:URLSessionWebSocketTask?,done=false
    private var timeout:DispatchWorkItem?
    init(credentials:IflytekCredentials,finish:@escaping(Bool,String)->Void){self.credentials=credentials;self.finish=finish}
    func start(url:URL){
        let cfg=URLSessionConfiguration.ephemeral;cfg.timeoutIntervalForRequest=10
        let s=URLSession(configuration:cfg,delegate:self,delegateQueue:nil);session=s
        let t=s.webSocketTask(with:url);task=t;t.resume()
        let w=DispatchWorkItem{[weak self] in self?.done(false,"连接超时：12 秒内无服务端响应")}
        timeout=w;DispatchQueue.global().asyncAfter(deadline:.now()+12,execute:w)
    }
    private func done(_ ok:Bool,_ msg:String){
        guard !done else {return};done=true
        timeout?.cancel();task?.cancel(with:.goingAway,reason:nil);session?.invalidateAndCancel()
        finish(ok,msg)
    }
    func urlSession(_ session:URLSession,webSocketTask:URLSessionWebSocketTask,didOpenWithProtocol protocol:String?){
        let silence=Data(repeating:0,count:1280)
        let first:[String:Any]=["common":["app_id":credentials.appId],"business":["language":"zh_cn","domain":"iat","accent":"mandarin"],"data":["status":0,"format":"audio/L16;rate=16000","encoding":"raw","audio":silence.base64EncodedString()]]
        let end:[String:Any]=["data":["status":2,"format":"audio/L16;rate=16000","encoding":"raw","audio":""]]
        for m in [first,end] {
            if let d=try? JSONSerialization.data(withJSONObject:m),let s=String(data:d,encoding:.utf8) {
                task?.send(.string(s)){[weak self] err in if let err {self?.done(false,"发送失败：\(err.localizedDescription)")}}
            }
        }
        task?.receive{[weak self] result in
            guard let self else {return}
            switch result {
            case .success(let msg):
                let text:String
                switch msg {case .string(let s):text=s;case .data(let d):text=String(data:d,encoding:.utf8) ?? "";@unknown default:text=""}
                if let data=text.data(using:.utf8),let o=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let code=o["code"] as? Int {
                    if code==0 {self.done(true,"鉴权与额度正常（本次测试消耗 1 次听写额度）")}
                    else {self.done(false,IflytekErrors.describe(code:code,message:(o["message"] as? String) ?? ""))}
                } else {self.done(false,"服务端响应无法解析")}
            case .failure(let err):self.done(false,"连接失败：\(err.localizedDescription)")
            }
        }
    }
    func urlSession(_ session:URLSession,webSocketTask:URLSessionWebSocketTask,didCloseWith closeCode:URLSessionWebSocketTask.CloseCode,reason:Data?){
        done(false,"连接被服务端关闭（closeCode=\(closeCode.rawValue)）")
    }
}
