import Foundation
import zlib

struct ASRWireUpdate {var ready=false;var text:String?;var final=false}
protocol ASRWire:AnyObject {
    var frameBytes:Int{get};var interval:Double{get};var rotateAfterBytes:Int?{get}
    var readyOnOpen:Bool{get};var start:URLSessionWebSocketTask.Message?{get}
    func audio(_ bytes:Data,first:Bool,last:Bool)throws->URLSessionWebSocketTask.Message
    func parse(_ message:URLSessionWebSocketTask.Message)throws->ASRWireUpdate
}
enum ASRJSON {
    static func object(_ message:URLSessionWebSocketTask.Message)throws->[String:Any] {
        let data:Data;switch message{case .data(let d):data=d;case .string(let s):data=Data(s.utf8);@unknown default:throw ASRFailure.protocolInvalid}
        guard data.count<=1048576,let o=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw ASRFailure.protocolInvalid};return o
    }
    static func message(_ object:[String:Any])throws->URLSessionWebSocketTask.Message {.string(String(data:try JSONSerialization.data(withJSONObject:object),encoding:.utf8)!)}
}
final class IATWire:ASRWire {
    let frameBytes=1280,interval=0.04,rotateAfterBytes:Int?=55*32000,readyOnOpen=true
    let start:URLSessionWebSocketTask.Message?=nil
    let appID:String,language:String,options:CloudASROptions
    private var ledger=ASRTranscriptLedger(),lastSlice=false
    init(appID:String,language:String,options:CloudASROptions){self.appID=appID;self.language=language;self.options=options}
    func audio(_ bytes:Data,first:Bool,last:Bool)throws->URLSessionWebSocketTask.Message {
        var o:[String:Any]=["data":["status":last ? 2:first ? 0:1,"format":"audio/L16;rate=16000","encoding":"raw","audio":bytes.base64EncodedString()]]
        if first {o["common"]=["app_id":appID];var b:[String:Any]=["language":language,"domain":"iat","vad_eos":10000];if language=="zh_cn"{b["accent"]="mandarin";b["dwa"]="wpgs";b["ptt"]=options.punctuation ? 1:0;b["nunum"]=options.itn ? 1:0};o["business"]=b}
        return try ASRJSON.message(o)
    }
    func parse(_ message:URLSessionWebSocketTask.Message)throws->ASRWireUpdate {
        let o=try ASRJSON.object(message);guard let code=o["code"] as? Int else{throw ASRFailure.protocolInvalid}
        guard code==0 else{throw ASRServiceError(hint:IflytekErrors.describe(code:code,message:""),code:code)}
        guard let d=o["data"] as? [String:Any] else{throw ASRFailure.protocolInvalid}
        if let r=d["result"] as? [String:Any] {
            guard let sn=r["sn"] as? Int else{throw ASRFailure.protocolInvalid}
            let words=(r["ws"] as? [[String:Any]] ?? []).compactMap{($0["cw"] as? [[String:Any]])?.first?["w"] as? String}.joined()
            let pgs=r["pgs"] as? String
            guard pgs==nil || pgs=="apd" || pgs=="rpl" else{throw ASRFailure.protocolInvalid}
            if pgs=="rpl",r["rg"] as? [Int]==nil{throw ASRFailure.protocolInvalid}
            try ledger.iat(sn:sn,text:words,range:pgs=="rpl" ? r["rg"] as? [Int]:nil)
            if r["ls"] as? Bool==true{lastSlice=true}
        }
        return ASRWireUpdate(text:ledger.preview,final:(d["status"] as? Int==2 && lastSlice))
    }
}
struct ASRServiceError:Error {let hint:String;let code:Int?;init(hint:String,code:Int?=nil){self.hint=hint;self.code=code}}
final class TencentWire:ASRWire {
    let frameBytes=6400,interval=0.2,rotateAfterBytes:Int?=nil,readyOnOpen=false
    let start:URLSessionWebSocketTask.Message?=nil
    let voiceID:String;private var ledger=ASRTranscriptLedger()
    init(voiceID:String){self.voiceID=voiceID}
    func audio(_ bytes:Data,first:Bool,last:Bool)throws->URLSessionWebSocketTask.Message {last ? .string("{\"type\":\"end\"}"):.data(bytes)}
    func parse(_ message:URLSessionWebSocketTask.Message)throws->ASRWireUpdate {
        let o=try ASRJSON.object(message);guard let code=o["code"] as? Int else{throw ASRFailure.protocolInvalid}
        guard code==0 else{throw ASRServiceError(hint:ASRServiceErrors.describe(.tencent,code:code),code:code)}
        guard o["voice_id"] as? String==voiceID else{throw ASRFailure.protocolInvalid}
        if let r=o["result"] as? [String:Any],let index=r["index"] as? Int,let kind=r["slice_type"] as? Int,let text=r["voice_text_str"] as? String {
            guard (0...2).contains(kind) else{throw ASRFailure.protocolInvalid};try ledger.sentence(index:index,text:text,stable:kind==2)
        }
        let final=o["final"] as? Int==1
        return ASRWireUpdate(ready:true,text:final ? ledger.stable:ledger.preview,final:final)
    }
}
final class AliyunWire:ASRWire {
    let frameBytes=3200,interval=0.1,rotateAfterBytes:Int?=nil,readyOnOpen=false
    let taskID:String,appKey:String,options:CloudASROptions;private var ledger=ASRTranscriptLedger()
    init(taskID:String,appKey:String,options:CloudASROptions){self.taskID=taskID;self.appKey=appKey;self.options=options}
    func command(_ name:String,payload:[String:Any]=[:])throws->URLSessionWebSocketTask.Message {try ASRJSON.message(["header":["appkey":appKey,"message_id":UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased(),"task_id":taskID,"namespace":"SpeechTranscriber","name":name],"payload":payload])}
    var start:URLSessionWebSocketTask.Message? {
        var p:[String:Any]=["format":"pcm","sample_rate":16000,"enable_intermediate_result":true,"enable_punctuation_prediction":options.punctuation,"enable_inverse_text_normalization":options.itn,"disfluency":options.smoothing]
        if !options.vocabularyID.isEmpty{p["vocabulary_id"]=options.vocabularyID};if !options.model.isEmpty{p["customization_id"]=options.model}
        return try? command("StartTranscription",payload:p)
    }
    func audio(_ bytes:Data,first:Bool,last:Bool)throws->URLSessionWebSocketTask.Message {last ? try command("StopTranscription"):.data(bytes)}
    func parse(_ message:URLSessionWebSocketTask.Message)throws->ASRWireUpdate {
        let o=try ASRJSON.object(message)
        guard let h=o["header"] as? [String:Any],h["task_id"] as? String==taskID,let name=h["name"] as? String,let code=h["status"] as? Int else{
            // Names and codes only, never text: what the service answered that this parser did not expect.
            let header=(o["header"] as? [String:Any]) ?? [:]
            Log.write("aliyun-unexpected-reply keys=\(o.keys.sorted()) header=\(header.keys.sorted()) name=\(header["name"] as? String ?? "-") status=\(header["status"].map{String(describing:$0)} ?? "-") taskMatch=\(header["task_id"] as? String == taskID)")
            throw ASRFailure.protocolInvalid
        }
        guard code==20000000,name != "TaskFailed" else{throw ASRServiceError(hint:ASRServiceErrors.describe(.aliyun,code:code),code:code)}
        let p=o["payload"] as? [String:Any] ?? [:]
        if name=="SentenceEnd" || name=="TranscriptionResultChanged" {
            guard let index=p["index"] as? Int,let text=p["result"] as? String else{throw ASRFailure.protocolInvalid};try ledger.sentence(index:index,text:text,stable:name=="SentenceEnd")
        }
        let final=name=="TranscriptionCompleted"
        return ASRWireUpdate(ready:name=="TranscriptionStarted",text:final ? ledger.stable:ledger.preview,final:final)
    }
}

enum ASRGzip {
    static let limit=1048576
    static func transform(_ data:Data,compress:Bool)throws->Data {
        guard data.count<=limit else{throw ASRFailure.protocolInvalid}
        var stream=z_stream();let initRC=compress ? deflateInit2_(&stream,Z_DEFAULT_COMPRESSION,Z_DEFLATED,31,8,Z_DEFAULT_STRATEGY,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size)):inflateInit2_(&stream,31,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size))
        guard initRC==Z_OK else{throw ASRFailure.protocolInvalid};defer{if compress{deflateEnd(&stream)}else{inflateEnd(&stream)}}
        return try data.withUnsafeBytes { raw in
            stream.next_in=UnsafeMutablePointer<Bytef>(mutating:raw.bindMemory(to:Bytef.self).baseAddress);stream.avail_in=uInt(data.count)
            var output=Data(),buffer=[UInt8](repeating:0,count:16384)
            while true {
                let rc=buffer.withUnsafeMutableBytes { target->Int32 in stream.next_out=target.bindMemory(to:Bytef.self).baseAddress;stream.avail_out=uInt(target.count);return compress ? deflate(&stream,Z_FINISH):inflate(&stream,Z_NO_FLUSH) }
                let n=buffer.count-Int(stream.avail_out);guard output.count+n<=limit else{throw ASRFailure.protocolInvalid};output.append(contentsOf:buffer.prefix(n))
                if rc==Z_STREAM_END {guard stream.avail_in==0 else{throw ASRFailure.protocolInvalid};return output}
                guard rc==Z_OK,n>0 else{throw ASRFailure.protocolInvalid}
            }
        }
    }
}
struct VolcFrame {
    let type:Int,flags:Int,sequence:Int?,errorCode:Int?,payload:Data
    static func pack(type:Int,flags:Int,json:Bool,payload:Data)throws->Data {
        let p=try ASRGzip.transform(payload,compress:true);var d=Data([0x11,UInt8(type<<4|flags),json ? 0x11:0x01,0]);var n=UInt32(p.count).bigEndian;withUnsafeBytes(of:&n){d.append(contentsOf:$0)};d.append(p);return d
    }
    static func parse(_ d:Data)throws->Self {
        guard d.count>=8,d.count<=ASRGzip.limit,d[0]>>4==1 else{throw ASRFailure.protocolInvalid}
        var offset=Int(d[0]&15)*4;let type=Int(d[1]>>4),flags=Int(d[1]&15),serialization=d[2]>>4,compression=d[2]&15
        guard offset>=4,offset<=d.count,flags<=3,compression<=1,(type==9 || type==15) else{throw ASRFailure.protocolInvalid}
        func integer()throws->UInt32 {guard offset+4<=d.count else{throw ASRFailure.protocolInvalid};let v=d[offset..<offset+4].reduce(UInt32(0)){($0<<8)|UInt32($1)};offset+=4;return v}
        let sequence=flags&1==1 ? Int(Int32(bitPattern:try integer())):nil
        let errorCode=type==15 ? Int(try integer()):nil
        let size=Int(try integer());guard size<=ASRGzip.limit,offset+size==d.count else{throw ASRFailure.protocolInvalid}
        let raw=Data(d[offset..<offset+size]),payload=compression==1 ? try ASRGzip.transform(raw,compress:false):raw
        guard type==15 || serialization==1 else{throw ASRFailure.protocolInvalid}
        // Official examples have both positive and negative sequence values for flags=3.
        // Termination is signaled by flag bit 1, independently of optional sequence encoding.
        return Self(type:type,flags:flags,sequence:sequence,errorCode:errorCode,payload:payload)
    }
}
final class VolcengineWire:ASRWire {
    let frameBytes=6400,interval=0.2,rotateAfterBytes:Int?=nil,readyOnOpen=true
    let options:CloudASROptions;private var ledger=ASRTranscriptLedger(),fallbackSequence=0
    init(options:CloudASROptions){self.options=options}
    var start:URLSessionWebSocketTask.Message? {
        var r:[String:Any]=["model_name":"bigmodel","enable_itn":options.itn,"enable_punc":options.punctuation,"enable_ddc":options.smoothing,"enable_nonstream":options.secondPass,"result_type":"full"]
        var corpus:[String:Any]=[:];if !options.vocabularyID.isEmpty{corpus["boosting_table_id"]=options.vocabularyID};if !options.correctionTableID.isEmpty{corpus["correct_table_id"]=options.correctionTableID}
        let words=options.hotwords.split(separator:"\n").map{["word":String($0)]}
        if !words.isEmpty,let d=try? JSONSerialization.data(withJSONObject:["hotwords":words]),let s=String(data:d,encoding:.utf8){corpus["context"]=s}
        if !corpus.isEmpty{r["corpus"]=corpus}
        let o:[String:Any]=["user":["uid":"cadenza"],"audio":["format":"pcm","rate":16000,"bits":16,"channel":1,"language":"zh-CN"],"request":r]
        guard let json=try? JSONSerialization.data(withJSONObject:o),let data=try? VolcFrame.pack(type:1,flags:0,json:true,payload:json) else{return nil};return .data(data)
    }
    func audio(_ bytes:Data,first:Bool,last:Bool)throws->URLSessionWebSocketTask.Message {.data(try VolcFrame.pack(type:2,flags:last ? 2:0,json:false,payload:bytes))}
    func parse(_ message:URLSessionWebSocketTask.Message)throws->ASRWireUpdate {
        guard case .data(let data)=message else{throw ASRFailure.protocolInvalid};let frame=try VolcFrame.parse(data)
        if let code=frame.errorCode{throw ASRServiceError(hint:ASRServiceErrors.describe(.volcengine,code:code),code:code)}
        guard let o=try JSONSerialization.jsonObject(with:frame.payload) as? [String:Any] else{throw ASRFailure.protocolInvalid}
        fallbackSequence=max(fallbackSequence+1,frame.sequence.map{abs($0)} ?? 0)
        if let r=o["result"] as? [String:Any],let text=r["text"] as? String {ledger.snapshot(sequence:frame.sequence.map{abs($0)} ?? fallbackSequence,text:text)}
        return ASRWireUpdate(text:ledger.stable,final:frame.flags&2 != 0)
    }
}
enum ASRServiceErrors {
    static func describe(_ engine:ASREngine,code:Int)->String {
        let hint:String
        switch (engine,code) {
        case (.tencent,4002),(.baidu,3302):hint=L10n.tr("ui.af3dc0e65e4f")
        case (.tencent,4003):hint=L10n.tr("ui.62dc655da639")
        case (.tencent,4004),(.tencent,4005),(.baidu,3305):hint=L10n.tr("ui.f56c7e77d3ac")
        case (.tencent,4000),(.tencent,4006),(.baidu,3304):hint=L10n.tr("ui.22f41c907c67")
        case (.baidu,3301):hint=L10n.tr("ui.8dba5bdeebec")
        case (.baidu,3308),(.baidu,3310),(.baidu,3311):hint=L10n.tr("ui.ebab778b7d52")
        case (.aliyun,40000001):hint=L10n.tr("ui.2d065ce10fe7")
        case (.aliyun,40000010):hint=L10n.tr("asr.aliyun.trialEnded")
        default:hint=L10n.tr("ui.9a42af5af515")
        }
        Log.write("asr-service-error provider=\(engine.rawValue) code=\(code)");return L10n.format("engine.failure",engine.title,hint)
    }
}
