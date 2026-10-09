import Foundation
import AVFoundation
import CryptoKit

// Provider configuration contains no credentials. Missing keys in older app configs retain defaults.
enum ASREngine: String, CaseIterable, Codable {
    case apple, iflytek, volcengine, tencent, aliyun, baidu, deepgram
    /// 本地模型（sherpa-onnx）：无需凭据，需要至少安装一个本地模型。
    case local
    /// 旧版 AppKit 设置窗口按固定分段列出的引擎（不含本地：本地模型在 SwiftUI 设置页管理）
    static var legacyListed:[ASREngine]{allCases.filter{$0 != .local}}
    var title:String{L10n.tr("engine."+rawValue)}
    var credentialFields: [(String,String)] { switch self {
    case .apple,.local:return []
    case .iflytek:return [("appid","App ID"),("apikey","API Key"),("apisecret","API Secret")]
    case .volcengine:return [("apikey","API Key")]
    case .tencent:return [("appid",L10n.tr("credential.accountID")),("secretid","Secret ID"),("secretkey","Secret Key")]
    case .aliyun:return [("appkey","NLS AppKey"),("accesskeyid","AccessKey ID"),("accesskeysecret","AccessKey Secret")]
    case .baidu:return [("apikey","API Key"),("secretkey","Secret Key")]
    case .deepgram:return [("apikey","API Key")]
    } }
    var configured:Bool {self == .local ? LocalModelCenter.shared.installedEntries.contains{LocalModelCatalog.usable($0)} : credentialFields.allSatisfy{SharedCredentials.has(rawValue+"."+$0.0)}}
    func credentials()->[String:String]? {
        var out:[String:String]=[:]
        for (key,_) in credentialFields { guard let value=SharedCredentials.get(rawValue+"."+key) else{return nil};out[key]=value }
        return out
    }
}
struct CloudASROptions:Codable,Equatable {
    var consent=false
    var model=""
    var region="cn-shanghai"
    var language="multi"
    var punctuation=false
    var itn=false
    var smoothing=false
    var secondPass=false
    var hotwords=""
    var vocabularyID=""
    var correctionTableID=""
    /// Tencent models that accept punctuation, number conversion and filler filtering (the Mandarin engine and the
    /// Chinese-English large model; the English-only engine does not).
    static let tencentTextModels=["16k_zh","16k_zh_en"]
    static func defaults(_ engine:ASREngine)->Self {var o=Self();o.punctuation=engine != .baidu;o.itn=engine != .baidu;switch engine {case .volcengine:o.model="volc.seedasr.sauc.duration";case .tencent:o.model="16k_zh";case .baidu:o.model="1537";case .deepgram:o.model="nova-3";default:break};return o}
    // Decode fields individually so future option additions do not invalidate saved settings.
    enum CodingKeys:String,CodingKey {case consent,model,region,language,punctuation,itn,smoothing,secondPass,hotwords,vocabularyID,correctionTableID}
    init() {}
    init(from decoder:Decoder)throws {let d=try decoder.container(keyedBy:CodingKeys.self)
        consent=try d.decodeIfPresent(Bool.self,forKey:.consent) ?? false;model=try d.decodeIfPresent(String.self,forKey:.model) ?? ""
        language=try d.decodeIfPresent(String.self,forKey:.language) ?? "multi"
        region=try d.decodeIfPresent(String.self,forKey:.region) ?? "cn-shanghai"
        punctuation=try d.decodeIfPresent(Bool.self,forKey:.punctuation) ?? false;itn=try d.decodeIfPresent(Bool.self,forKey:.itn) ?? false
        smoothing=try d.decodeIfPresent(Bool.self,forKey:.smoothing) ?? false;secondPass=try d.decodeIfPresent(Bool.self,forKey:.secondPass) ?? false
        hotwords=try d.decodeIfPresent(String.self,forKey:.hotwords) ?? "";vocabularyID=try d.decodeIfPresent(String.self,forKey:.vocabularyID) ?? "";correctionTableID=try d.decodeIfPresent(String.self,forKey:.correctionTableID) ?? ""
    }
}
struct LocalASRMapping:Codable,Equatable {var source:String;var replacement:String}
/// Streaming recognizers punctuate each segment on its own, which can leave a stray mark before a
/// sentence-final particle ("划算。吗？") or stacked marks at the end ("吗？。"). Only full-width
/// marks are touched, so ellipses, decimals and ASCII punctuation are never altered.
enum ASRPunctuationCleanup {
    static func apply(_ text:String)->String {
        var out=text.replacingOccurrences(of:"[。，；]+(?=[吗呢吧啊嘛呀么])",with:"",options:.regularExpression)
        guard let run=try? NSRegularExpression(pattern:"[。！？，；]{2,}") else{return out}
        let ns=out as NSString
        var result="",last=0
        for m in run.matches(in:out,range:NSRange(location:0,length:ns.length)) {
            result += ns.substring(with:NSRange(location:last,length:m.range.location-last))
            let marks=ns.substring(with:m.range)
            result += marks.contains("？") ? "？":marks.contains("！") ? "！":String(marks.last!)
            last=m.range.location+m.range.length
        }
        result += ns.substring(from:last);out=result
        return out
    }
}
enum LocalASRCorrection {
    // Exact complete lexical tokens only. Han phrases require punctuation/whitespace boundaries too.
    // URL/code/number/negation candidates are never altered. Matches are collected on original text once.
    static func protected(_ s:String)->Bool {
        s.rangeOfCharacter(from:.decimalDigits) != nil || s.contains("不") || s.contains("没") || s.contains("无") || s.contains("别") || s.lowercased().contains("not") || s.lowercased().contains("never") || s.rangeOfCharacter(from:CharacterSet(charactersIn:"/\\:._@`{}[]<>=+")) != nil
    }
    static func valid(_ maps:[LocalASRMapping])->Bool {
        let sources=maps.map{$0.source};return maps.count<=100 && Set(sources).count==sources.count && maps.allSatisfy{!$0.source.isEmpty && !$0.replacement.isEmpty && $0.source.count<=60 && $0.replacement.count<=60 && !protected($0.source) && !protected($0.replacement) && !$0.source.contains("\n") && !$0.replacement.contains("\n")}
    }
    static func apply(_ text:String,maps:[LocalASRMapping])->String {
        guard valid(maps),!maps.isEmpty,!text.contains("`"),text.range(of:"(?:https?://|www\\.)\\S+",options:.regularExpression)==nil else{return text}
        var result="",token="",inCode=false
        let dict=Dictionary(uniqueKeysWithValues:maps.map{($0.source,$0.replacement)})
        func flush(){result += (!inCode && !protected(token) ? dict[token]:nil) ?? token;token=""}
        for ch in text {
            if ch == "`" {flush();inCode.toggle();result.append(ch)}
            else if ch.isWhitespace || "，。！？；、,!?;()\"“”‘’".contains(ch) {flush();result.append(ch)}
            else {token.append(ch)}
        };flush();return result
    }
}

struct ASRTranscriptLedger {
    private(set) var fragments:[Int:String]=[:]
    private var replaced:Set<Int>=[]
    private var seen:Set<Int>=[]
    private var latestSnapshot = -1
    private var partials:[Int:String]=[:]
    mutating func iat(sn:Int,text:String,range:[Int]?)throws {
        guard sn>=0,sn<100000,text.utf8.count<=262144 else{throw ASRFailure.protocolInvalid}
        guard !seen.contains(sn),!replaced.contains(sn) else{return}
        if let r=range {guard r.count==2,r[0]>=0,r[1]>=r[0],r[1]<sn,r[1]-r[0]<=10000 else{throw ASRFailure.protocolInvalid};for n in r[0]...r[1] {fragments[n]=nil;replaced.insert(n)}}
        seen.insert(sn);fragments[sn]=text;guard stable.utf8.count<=1048576 else{throw ASRFailure.protocolInvalid}
    }
    mutating func sentence(index:Int,text:String,stable:Bool) throws {guard index>=0,index<100000,text.utf8.count<=262144 else{throw ASRFailure.protocolInvalid}
        if stable {fragments[index]=text;partials[index]=nil} else if fragments[index]==nil{partials[index]=text};guard preview.utf8.count<=1048576 else{throw ASRFailure.protocolInvalid}
    }
    mutating func snapshot(sequence:Int,text:String) {guard sequence>=latestSnapshot else{return};latestSnapshot=sequence;fragments=[0:text];partials=[:]}
    var stable:String{fragments.keys.sorted().compactMap{fragments[$0]}.joined()}
    var preview:String{Set(fragments.keys).union(partials.keys).sorted().compactMap{fragments[$0] ?? partials[$0]}.joined()}
}
struct ASRCompletionGate {
    private(set) var ended=false,confirmed=false,terminal=false
    mutating func userEnded(){ended=true}
    mutating func streamConfirmed(){confirmed=true}
    mutating func take()->Bool {guard ended,confirmed,!terminal else{return false};terminal=true;return true}
    mutating func cancel(){terminal=true}
}
struct ASRPCMQueue {
    let limit:Int
    private(set) var bytes=Data()
    mutating func append(_ data:Data)throws {guard data.count%2==0,bytes.count+data.count<=limit else{throw ASRFailure.bufferFull};bytes.append(data)}
    mutating func take(_ count:Int,tail:Bool)->Data? {guard bytes.count>=count || tail && !bytes.isEmpty else{return nil};let n=min(count,bytes.count);let out=Data(bytes.prefix(n));bytes.removeFirst(n);return out}
}
enum ASRFailure:Error {case protocolInvalid,bufferFull,tokenInvalid,credentialMissing,timeout}
enum ASRState:String {case connecting,ready,capturing,finishing,completed,failed,cancelled}

protocol CloudPCMCapturing:AnyObject {
    var onPCM:((Data)->Void)?{get set};var onLevel:((Float)->Void)?{get set}
    var hasSignal:Bool{get};var startedUptime:TimeInterval?{get};var lastError:String?{get}
    func start(uid:String)->Bool;func stop()
}
final class PCM16Converter {
    let outputFormat:AVAudioFormat
    private let converter:AVAudioConverter
    init?(input:AVAudioFormat){guard input.sampleRate>0,let out=AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:16000,channels:1,interleaved:true),let converter=AVAudioConverter(from:input,to:out) else{return nil};outputFormat=out;self.converter=converter}
    func convert(_ input:AVAudioPCMBuffer?,emit:(Data,Float)->Void)throws {
        var supplied=false
        for _ in 0..<16 {
            guard let output=AVAudioPCMBuffer(pcmFormat:outputFormat,frameCapacity:8192) else{throw ASRFailure.protocolInvalid}
            var error:NSError?
            let status=converter.convert(to:output,error:&error){_,state in
                guard let input=input else{state.pointee = .endOfStream;return nil}
                if supplied{state.pointee = .noDataNow;return nil};supplied=true;state.pointee = .haveData;return input
            }
            guard error==nil,status != .error else{throw ASRFailure.protocolInvalid}
            if output.frameLength>0,let samples=output.int16ChannelData?[0] {
                let n=Int(output.frameLength);var sum:Double=0
                for i in 0..<n{let v=Double(samples[i])/32768;sum+=v*v}
                emit(Data(bytes:samples,count:n*2),Float(min(1,sqrt(sum/Double(n))*10)))
            }
            if status == .inputRanDry || status == .endOfStream || output.frameLength==0{return}
        }
        throw ASRFailure.protocolInvalid
    }
}
final class CloudPCMCapture:CloudPCMCapturing {
    var onPCM:((Data)->Void)?,onLevel:((Float)->Void)?
    let evidence=AudioSignalEvidence();var hasSignal:Bool{evidence.hasSignal == true}
    private(set) var startedUptime:TimeInterval?,lastError:String?
    private let engine=AVAudioEngine(),lock=NSLock()
    private var running=false,tapped=false,converter:PCM16Converter?
    func start(uid:String)->Bool {
        evidence.reset();lastError=nil
        if let e=Microphones.configure(engine,uid:uid){lastError=e;return false}
        let node=engine.inputNode,format=node.outputFormat(forBus:0)
        guard let converter=PCM16Converter(input:format) else{lastError=L10n.tr("ui.7643b233ca93");return false}
        self.converter=converter;lock.lock();running=true;lock.unlock()
        node.installTap(onBus:0,bufferSize:2048,format:format){[weak self] input,_ in
            guard let self=self else{return};self.lock.lock();defer{self.lock.unlock()};guard self.running else{return}
            self.evidence.observe(input)
            do{try converter.convert(input){data,level in self.onLevel?(level);self.onPCM?(data)}}catch{self.lastError=L10n.tr("ui.028a7dbb433f");self.running=false}
        }
        tapped=true;engine.prepare()
        do{try engine.start();startedUptime=ProcessInfo.processInfo.systemUptime;return true}catch{lastError=L10n.tr("ui.ff7cdaede703");stop();return false}
    }
    func stop(){lock.lock();let wasRunning=running;running=false
        if wasRunning,let converter=converter{do{try converter.convert(nil){data,_ in self.onPCM?(data)}}catch{lastError=L10n.tr("ui.aa0d43827ac9")}}
        converter=nil;lock.unlock();if tapped{tapped=false;engine.inputNode.removeTap(onBus:0)};engine.stop()
    }
    deinit{stop()}
}

enum ASRAuth {
    static func encode(_ s:String)->String{s.addingPercentEncoding(withAllowedCharacters:CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~"))!}
    static func sorted(_ values:[String:String],encoded:Bool)->String{values.keys.sorted().map{(encoded ? encode($0):$0)+"="+(encoded ? encode(values[$0]!):values[$0]!)}.joined(separator:"&")}
    static func sha1(_ value:String,secret:String)->String{Data(HMAC<Insecure.SHA1>.authenticationCode(for:Data(value.utf8),using:SymmetricKey(data:Data(secret.utf8)))).base64EncodedString()}
    static func tencent(appID:String,secretID:String,secret:String,model:String,hotwords:String,punc:Bool,itn:Bool,smoothing:Bool,now:Int=Int(Date().timeIntervalSince1970),nonce:String=String(UInt32.random(in:1...UInt32.max)),voiceID:String=UUID().uuidString)->URL? {
        var p=["secretid":secretID,"timestamp":String(now),"expired":String(now+3600),"nonce":nonce,"engine_model_type":model,"voice_id":voiceID,"voice_format":"1","needvad":"1"]
        if CloudASROptions.tencentTextModels.contains(model){p["filter_modal"]=smoothing ? "2":"0";p["filter_punc"]=punc ? "0":"1";p["convert_num_mode"]=itn ? "1":"0"}
        if !hotwords.isEmpty{p["hotword_list"]=hotwords}
        let path="asr.cloud.tencent.com/asr/v2/"+appID
        p["signature"]=sha1(path+"?"+sorted(p,encoded:false),secret:secret)
        return URL(string:"wss://"+path+"?"+sorted(p,encoded:true))
    }
    static func aliyunToken(key:String,secret:String,timestamp:String,nonce:String)->URL? {
        var p=["AccessKeyId":key,"Action":"CreateToken","Version":"2019-02-28","Timestamp":timestamp,"Format":"JSON","RegionId":"cn-shanghai","SignatureMethod":"HMAC-SHA1","SignatureVersion":"1.0","SignatureNonce":nonce]
        p["Signature"]=sha1("GET&%2F&"+encode(sorted(p,encoded:true)),secret:secret+"&")
        return URL(string:"https://nls-meta.cn-shanghai.aliyuncs.com/?"+sorted(p,encoded:true))
    }
}
