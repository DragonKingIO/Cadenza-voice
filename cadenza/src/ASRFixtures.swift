import Foundation
import AVFoundation

// Fixed fake credentials, constructed audio and transcripts only. No network, mic, target text or secrets.
enum ASRFixtures {
    static func run(_ check:(String,Bool)->Void) {
        func c(_ name:String,_ condition:Bool){check("ASR "+name,condition)}
        func rejects(_ body:()throws->Void)->Bool{do{try body();return false}catch{return true}}
        func message(_ o:[String:Any])->URLSessionWebSocketTask.Message{try! ASRJSON.message(o)}
        func iat(_ sn:Int,_ text:String,_ pgs:String="apd",_ range:[Int]?=nil,_ ls:Bool=false,_ status:Int=1)->URLSessionWebSocketTask.Message {
            var r:[String:Any]=["sn":sn,"pgs":pgs,"ls":ls,"ws":[["cw":[["w":text],["w":"alternate-never-append"]]]]];if let range=range{r["rg"]=range};return message(["code":0,"data":["status":status,"result":r]])
        }
        let i=IATWire(appID:"fake",language:"zh_cn",options:CloudASROptions())
        c("IAT追加",(try? i.parse(iat(0,"a")))?.text=="a")
        c("IAT乱序排序",(try? i.parse(iat(2,"c")))?.text=="ac" && (try? i.parse(iat(1,"b")))?.text=="abc")
        c("IAT动态替换",(try? i.parse(iat(3,"correct","rpl",[1,2])))?.text=="acorrect")
        c("IAT重复不追加",(try? i.parse(iat(3,"incorrect","rpl",[1,2])))?.text=="acorrect")
        c("IAT旧片迟到不复活",(try? i.parse(iat(2,"late")))?.text=="acorrect")
        c("IAT ls不单独终结",(try? i.parse(iat(4,"tail","apd",nil,true,1)))?.final==false)
        c("IAT整流和末片共同终结",(try? i.parse(message(["code":0,"data":["status":2]])))?.final==true)
        c("IAT非法范围拒绝",rejects{_ = try IATWire(appID:"fake",language:"zh_cn",options:CloudASROptions()).parse(iat(1,"bad","rpl",[1,9]))})
        let first=try! ASRJSON.object(i.audio(Data([0,0]),first:true,last:false));let business=first["business"] as! [String:Any]
        c("IAT普通话首帧dwa",business["dwa"] as? String=="wpgs")
        let en=IATWire(appID:"fake",language:"en_us",options:CloudASROptions());let english=try! ASRJSON.object(en.audio(Data(),first:true,last:false))["business"] as! [String:Any]
        c("IAT英文不发送未支持选项",english["dwa"]==nil && english["nunum"]==nil && english["ptt"]==nil)
        let date=ISO8601DateFormatter().date(from:"2019-07-10T07:35:43Z")!
        let auth=IflytekAuth.webSocketURL(apiKey:"public-fixture",apiSecret:"secretxxxxxxxx2df7900c09xxxxxxxx",now:date)!
        let encoded=URLComponents(url:auth,resolvingAgainstBaseURL:false)!.queryItems!.first{$0.name=="authorization"}!.value!
        let decoded=String(data:Data(base64Encoded:encoded)!,encoding:.utf8)!
        c("IAT官方公开假密钥签名",decoded.contains("Hp3Ty4ZkSBmL8jKyOLpQiv9Sr5nvmeYEH7WsL/ZO2Jg="))
        c("IAT无固定免费承诺",![11200,11201,11202,11203].map{IflytekErrors.describe(code:$0,message:"secret-echo")}.contains{$0.contains("500") || $0.contains("secret-echo")})
        c("IAT错误码11203授权过期",IflytekErrors.describe(code:11203,message:"").contains(L10n.tr("ui.ef971682b208")))

        let t=TencentWire(voiceID:"fixture")
        func tc(_ index:Int,_ kind:Int,_ text:String,_ final:Int=0)->URLSessionWebSocketTask.Message{message(["code":0,"voice_id":"fixture","final":final,"result":["index":index,"slice_type":kind,"voice_text_str":text]])}
        c("Tencent稳定句不结束整流",(try? t.parse(tc(2,2,"c")))?.final==false)
        c("Tencent多句乱序",(try? t.parse(tc(0,2,"a")))?.text=="ac" && (try? t.parse(tc(1,2,"b")))?.text=="abc")
        c("Tencent重复稳定句覆盖去重",(try? t.parse(tc(1,2,"b")))?.text=="abc")
        c("Tencent迟到partial不覆盖稳定",(try? t.parse(tc(1,1,"late")))?.text=="abc")
        c("Tencent root final终结",(try? t.parse(message(["code":0,"voice_id":"fixture","final":1])))?.final==true)
        c("Tencent其他voice_id拒绝",rejects{_ = try t.parse(message(["code":0,"voice_id":"old"]))})
        let tu=ASRAuth.tencent(appID:"123",secretID:"fake-id",secret:"fake-secret",model:"16k_zh",hotwords:"柚子+/=|10",punc:false,itn:false,smoothing:false,now:1700000000,nonce:"123",voiceID:"fixture")!
        let tp=Dictionary(uniqueKeysWithValues:URLComponents(url:tu,resolvingAgainstBaseURL:false)!.queryItems!.map{($0.name,$0.value ?? "")})
        c("Tencent Unicode和加号只编码一次",tp["hotword_list"]=="柚子+/=|10")
        c("Tencent独立HMAC假密钥fixture",tp["signature"]=="aOrIVWJcCXKuCZnwUWNtXeDStLw=")
        c("Tencent PCM200ms帧",t.frameBytes==6400 && t.interval==0.2)
        func tencentParams(_ model:String,punc:Bool,itn:Bool,smoothing:Bool)->[String:String] {
            let u=ASRAuth.tencent(appID:"123",secretID:"i",secret:"s",model:model,hotwords:"",punc:punc,itn:itn,smoothing:smoothing,now:1700000000,nonce:"1",voiceID:"v")!
            return Dictionary(uniqueKeysWithValues:URLComponents(url:u,resolvingAgainstBaseURL:false)!.queryItems!.map{($0.name,$0.value ?? "")})
        }
        let zhEn=tencentParams("16k_zh_en",punc:true,itn:true,smoothing:true),tencentEN=tencentParams("16k_en",punc:true,itn:true,smoothing:true),zh=tencentParams("16k_zh",punc:false,itn:false,smoothing:false)
        c("Deepgram多语言模式遇到中文环境改用中文模型",DeepgramAPI.effectiveLanguage("multi",recognitionLocale:"zh-CN")=="zh-CN" && DeepgramAPI.effectiveLanguage("multi",recognitionLocale:"zh_TW")=="zh-TW" && DeepgramAPI.effectiveLanguage("multi",recognitionLocale:"zh-HK")=="zh-HK")
        c("Deepgram非中文环境和明确选择的语言不改动",DeepgramAPI.effectiveLanguage("multi",recognitionLocale:"en-US")=="multi" && DeepgramAPI.effectiveLanguage("en",recognitionLocale:"zh-CN")=="en" && DeepgramAPI.effectiveLanguage("ja",recognitionLocale:"zh-CN")=="ja")
        var dgConfig=ConfigStore(fileURL:FileManager.default.temporaryDirectory.appendingPathComponent("dg-\(UUID().uuidString).json")).config
        dgConfig.recognitionLocale="zh-CN"
        c("录音使用的 Deepgram 选项中文环境下为 zh-CN 且不改写保存的设置",dgConfig.recordingOptions(.deepgram).language=="zh-CN" && dgConfig.options(.deepgram).language=="multi" && ASROptionPolicy.validate(.deepgram,dgConfig.recordingOptions(.deepgram))==nil && (DeepgramAPI.request(options:{var o=dgConfig.recordingOptions(.deepgram);o.consent=true;return o}(),key:"k")?.url?.absoluteString.contains("language=zh-CN")==true))
        c("Tencent中英文大模型发送标点、数字转换和语气词过滤",zhEn["filter_punc"]=="0" && zhEn["convert_num_mode"]=="1" && zhEn["filter_modal"]=="2" && zhEn["engine_model_type"]=="16k_zh_en")
        c("Tencent纯英文模型不发送中文文本参数",tencentEN["filter_punc"]==nil && tencentEN["convert_num_mode"]==nil && tencentEN["filter_modal"]==nil)
        c("Tencent普通话模型关闭选项时显式关闭",zh["filter_punc"]=="1" && zh["convert_num_mode"]=="0" && zh["filter_modal"]=="0")
        var big=CloudASROptions.defaults(.tencent);big.model="16k_zh_en";big.punctuation=true;big.itn=true;big.smoothing=true
        c("Tencent中英文大模型允许这些选项通过校验",ASROptionPolicy.validate(.tencent,big)==nil)
        big.model="16k_en"
        c("Tencent纯英文模型仍拒绝这些选项",ASROptionPolicy.validate(.tencent,big) != nil)
        c("标点清理：句末助词前的句号和叠加标点",ASRPunctuationCleanup.apply("你觉得划算。吗？。") == "你觉得划算吗？")
        c("标点清理：不改省略号、小数和普通句子",ASRPunctuationCleanup.apply("内存1.5个g……好的。下一句！") == "内存1.5个g……好的。下一句！")
        c("标点清理：感叹优先且保留单个标点",ASRPunctuationCleanup.apply("真的！。") == "真的！" && ASRPunctuationCleanup.apply("好，。") == "好。" && ASRPunctuationCleanup.apply("") == "")
        var bad=CloudASROptions.defaults(.tencent);bad.hotwords="词|100";bad.model="16k_en"
        c("Tencent100权重不能泛化",ASROptionPolicy.validate(.tencent,bad) != nil)

        let a=AliyunWire(taskID:"fixture",appKey:"fake",options:CloudASROptions())
        func ali(_ name:String,_ index:Int=0,_ text:String="",_ status:Int=20000000)->URLSessionWebSocketTask.Message{message(["header":["task_id":"fixture","name":name,"status":status],"payload":["index":index,"result":text,"status":0]])}
        c("NLS服务Started才ready",(try? a.parse(ali("TranscriptionStarted")))?.ready==true && !a.readyOnOpen)
        c("NLS payload.status0不是错误",(try? a.parse(ali("TranscriptionResultChanged",1,"preview")))?.text=="preview")
        c("NLS SentenceEnd不结束整流",(try? a.parse(ali("SentenceEnd",1,"stable")))?.final==false)
        c("NLS句子排序与重复",(try? a.parse(ali("SentenceEnd",0,"first")))?.text=="firststable" && (try? a.parse(ali("SentenceEnd",1,"stable")))?.text=="firststable")
        c("NLS Completed才final",(try? a.parse(ali("TranscriptionCompleted")))?.text=="firststable" && (try? a.parse(ali("TranscriptionCompleted")))?.final==true)
        c("NLS header错误码捕获",rejects{_ = try a.parse(ali("TaskFailed",0,"private-echo",40000001))})
        c("NLS旧task拒绝",rejects{_ = try a.parse(message(["header":["task_id":"old","name":"TranscriptionStarted","status":20000000]]))})
        let ah=try! ASRJSON.object(a.start!)["header"] as! [String:Any];let stop=try! ASRJSON.object(a.audio(Data(),first:false,last:true))["header"] as! [String:Any]
        c("NLS唯一message_id和相同task",ah["task_id"] as? String==stop["task_id"] as? String && ah["message_id"] as? String != stop["message_id"] as? String)
        let au=ASRAuth.aliyunToken(key:"my_access_key_id",secret:"my_access_key_secret",timestamp:"2019-04-18T08:32:31Z",nonce:"b924c8c3-6d03-4c5d-ad36-d984d3116788")!
        let ap=URLComponents(url:au,resolvingAgainstBaseURL:false)!.queryItems!
        c("NLS官方假密钥签名fixture",ap.first{$0.name=="Signature"}?.value=="hHq4yNsPitlfDJ2L0nQPdugdEzM=")

        let v=VolcengineWire(options:.defaults(.volcengine))
        func volc(_ text:String,_ flags:Int,_ seq:Int32=1,_ gzip:Bool=true,_ extensionHeader:Bool=false)->Data {
            let raw=try! JSONSerialization.data(withJSONObject:["result":["text":text]])
            let p=gzip ? try! ASRGzip.transform(raw,compress:true):raw
            var d=Data([extensionHeader ? 0x12:0x11,UInt8(0x90|flags),gzip ? 0x11:0x10,0]);if extensionHeader{d.append(contentsOf:[0,0,0,0])}
            if flags&1==1{var n=seq.bigEndian;withUnsafeBytes(of:&n){d.append(contentsOf:$0)}}
            var size=UInt32(p.count).bigEndian;withUnsafeBytes(of:&size){d.append(contentsOf:$0)};d.append(p);return d
        }
        c("Volc gzip完整响应",(try? v.parse(.data(volc("one",1))))?.text=="one")
        c("Volc扩展头按长度解析",(try? VolcFrame.parse(volc("extension",1,2,true,true)))?.sequence==2)
        c("Volc旧快照不覆盖",(try? v.parse(.data(volc("new",1,3))))?.text=="new" && (try? v.parse(.data(volc("old",1,2))))?.text=="new")
        c("Volc负序号末包",(try? v.parse(.data(volc("complete",3,-4))))?.final==true)
        c("Volc无序号末包能覆盖高序号快照",(try? v.parse(.data(volc("high",1,100))))?.text=="high" && (try? v.parse(.data(volc("tail",2))))?.text=="tail")
        c("Volc不带序号末包",(try? VolcFrame.parse(volc("complete",2,1,false)))?.flags==2)
        c("Volc截断载荷拒绝",rejects{_ = try VolcFrame.parse(Data(volc("truncated",1).dropLast()))})
        c("Volc错误帧独立code",(try? VolcFrame.parse(Data([0x11,0xF0,0x10,0,0,0,0,42,0,0,0,2,123,125])))?.errorCode==42)
        c("Volc错误处理不回显消息",rejects{_ = try v.parse(.data(Data([0x11,0xF0,0x10,0,0,0,0,42,0,0,0,2,123,125])))})
        c("Volc非法header拒绝",rejects{_ = try VolcFrame.parse(Data([0x10,0x91,0x11,0,0,0,0,0]))})
        c("Volc无界解压拒绝",rejects{_ = try ASRGzip.transform(Data(repeating:0,count:1048577),compress:true)})
        if case .data(let start)=v.start! {c("Volc首包JSON gzip位正确",start.prefix(4)==Data([0x11,0x10,0x11,0]))}
        var vo=CloudASROptions.defaults(.volcengine);vo.hotwords="fixture";vo.vocabularyID="table"
        if case .data(let start)=VolcengineWire(options:vo).start! {let size=Int(start[4..<8].reduce(UInt32(0)){($0<<8)|UInt32($1)});let payload=try! ASRGzip.transform(Data(start[8..<8+size]),compress:false);let obj=try! JSONSerialization.jsonObject(with:payload) as! [String:Any];let req=obj["request"] as! [String:Any];c("Volc corpus在request且无上下文",req["corpus"] != nil && obj["corpus"]==nil && String(data:payload,encoding:.utf8)!.contains("dialog_ctx")==false)}

        let pcm=Data([1,0,2,0]);let body=try! BaiduASR.body(pcm:pcm,token:"fake-token",model:"1537");let bo=try! JSONSerialization.jsonObject(with:body) as! [String:Any]
        c("Baidu len为原始PCM字节",bo["len"] as? Int==4 && Data(base64Encoded:bo["speech"] as! String)==pcm)
        c("Baidu超60秒拒绝",rejects{_ = try BaiduASR.body(pcm:Data(repeating:0,count:1920002),token:"fake",model:"1537")})
        c("Baidu非16bit长度拒绝",rejects{_ = try BaiduASR.body(pcm:Data([1]),token:"fake",model:"1537")})
        c("Baidu成功整段结果",(try? BaiduASR.parse(Data("{\"err_no\":0,\"result\":[\"fixture\"]}".utf8)))=="fixture")
        c("Baidu失败不是成功final",rejects{_ = try BaiduASR.parse(Data("{\"err_no\":3304,\"err_msg\":\"private-echo\"}".utf8))})
        c("Baidu并发错误不冒充余额",ASRServiceErrors.describe(.baidu,code:3304).contains(L10n.tr("ui.22f41c907c67")))
        c("Token提前60秒过期",!ASRToken(value:"fake",expires:120).valid(now:60) && ASRToken(value:"fake",expires:121).valid(now:60))
        let cache=ASRTokenCache();cache.put(ASRToken(value:"fake",expires:Date().timeIntervalSince1970+200),key:"test");c("Token内存缓存",cache.get("test") != nil);cache.remove("test");c("Token失效刷新前清除",cache.get("test")==nil)

        var gate=ASRCompletionGate();gate.streamConfirmed();c("服务final先到不输出",!gate.take());gate.userEnded();c("用户停止及服务final输出一次",gate.take() && !gate.take())
        var cancelled=ASRCompletionGate();cancelled.cancel();cancelled.userEnded();cancelled.streamConfirmed();c("取消后final永不输出",!cancelled.take())
        var q=ASRPCMQueue(limit:12);try! q.append(Data(repeating:0,count:10));c("队列上限拒绝",rejects{try q.append(Data(repeating:0,count:4))});c("帧与尾音均保留",q.take(8,tail:false)?.count==8 && q.take(8,tail:true)?.count==2)
        let maps=[LocalASRMapping(source:"alpha",replacement:"beta"),LocalASRMapping(source:"beta",replacement:"gamma")]
        c("用户映射一次无级联",LocalASRCorrection.apply("alpha beta unchanged",maps:maps)=="beta gamma unchanged")
        c("映射不改变非匹配子串",LocalASRCorrection.apply("alphabet",maps:maps)=="alphabet")
        c("映射保护URL代码",LocalASRCorrection.apply("https://fixture/alpha?beta alpha",maps:maps)=="https://fixture/alpha?beta alpha" && LocalASRCorrection.apply("`alpha` alpha",maps:maps)=="`alpha` alpha")
        c("否定数字映射拒绝",!LocalASRCorrection.valid([LocalASRMapping(source:"不可以",replacement:"可以")]) && !LocalASRCorrection.valid([LocalASRMapping(source:"1",replacement:"two")]))
        c("映射重复冲突拒绝",!LocalASRCorrection.valid([maps[0],maps[0]]))
        let old=try! JSONDecoder().decode(BridgeConfig.self,from:Data("{\"engine\":\"iflytek\",\"iflytekConsent\":true}".utf8));c("旧配置云同意兼容",old.options(.iflytek).consent && old.cloudASR.isEmpty)
        var config=old;var options=CloudASROptions.defaults(.tencent);options.consent=true;options.hotwords="fixture|10";config.setOptions(.tencent,options);config.engine="tencent";config.localASRMappings=maps
        let round=try! JSONDecoder().decode(BridgeConfig.self,from:JSONEncoder().encode(config));c("厂商切换保留其他配置",round.engine=="tencent" && round.iflytekConsent && round.options(.tencent)==options && round.localASRMappings==maps && BridgeConfig.validate(round).isEmpty)
        c("云引擎权限无Apple要求",ASREngine.allCases.filter{$0 != .apple && $0 != .local}.allSatisfy{EngineReadiness.ready(engine:$0.rawValue,mic:true,speech:false,local:false,cloud:false,credentials:true,consent:true)})
        let inputFormat=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:48000,channels:2,interleaved:false)!
        let conversion=PCM16Converter(input:inputFormat)!,audio=AVAudioPCMBuffer(pcmFormat:inputFormat,frameCapacity:4800)!;audio.frameLength=4800
        for channel in 0..<2 {for n in 0..<4800{audio.floatChannelData![channel][n]=0.1}}
        var converted=Data();var conversionLevel:Float=0
        try! conversion.convert(audio){d,l in converted.append(d);conversionLevel=max(conversionLevel,l)};try! conversion.convert(nil){d,_ in converted.append(d)}
        c("共享AVAudioConverter立体声连续重采样含尾音",abs(converted.count-3200)<=4 && conversionLevel>0 && converted.count%2==0)
        testRecorder(c)
    }
    private final class Capture:CloudPCMCapturing {
        var onPCM:((Data)->Void)?,onLevel:((Float)->Void)?,hasSignal=true,startedUptime:TimeInterval?=0,lastError:String?,starts=0,stops=0
        func start(uid:String)->Bool{starts+=1;return true};func stop(){stops+=1}
    }
    private final class Socket:ASRSocket {
        var opened:(()->Void)?,received:((URLSessionWebSocketTask.Message)->Void)?,failed:(()->Void)?,authRejected:(()->Void)?
        var messages:[URLSessionWebSocketTask.Message]=[],sentTimes:[TimeInterval]=[],closed=0,voiceID="",taskID=""
        func connect(_ request:URLRequest){voiceID=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first{$0.name=="voice_id"}?.value ?? ""};func send(_ message:URLSessionWebSocketTask.Message,completion:@escaping(Bool)->Void){messages.append(message);sentTimes.append(ProcessInfo.processInfo.systemUptime);if let o=try? ASRJSON.object(message),let h=o["header"] as? [String:Any]{taskID=h["task_id"] as? String ?? ""};completion(true)};func close(){closed+=1;opened=nil;received=nil;failed=nil}
    }
    private final class HTTP:ASRHTTP {
        var responses:[Data],calls=0,cancelled=0
        init(_ responses:[Data]=[]){self.responses=responses}
        func request(_ request:URLRequest,completion:@escaping(Result<Data,Error>)->Void){calls+=1;if !responses.isEmpty{completion(.success(responses.removeFirst()))}else{completion(.failure(ASRFailure.tokenInvalid))}}
        func cancel(){cancelled+=1}
    }
    private static func wait(_ seconds:Double){RunLoop.current.run(until:Date().addingTimeInterval(seconds))}
    /// Polls until `done` is true or `timeout` passes, so paced sending is not tied to the speed of the machine (CI runners are slower).
    private static func waitUntil(_ timeout:Double,_ done:()->Bool){let end=Date().addingTimeInterval(timeout);while !done() && Date()<end {wait(0.02)}}
    private static func testRecorder(_ c:(String,Bool)->Void) {
        func json(_ o:[String:Any])->URLSessionWebSocketTask.Message{try! ASRJSON.message(o)}
        let capture=Capture(),socket=Socket(),http=HTTP();let r=CloudASRRecorder(provider:.tencent,options:.defaults(.tencent),credentials:["appid":"123","secretid":"fake","secretkey":"fake"],capture:capture,http:http,socketFactory:{socket})
        var finals=0;r.onFinal={_ in finals+=1};c("共享录音单采集器",r.begin() && capture.starts==1);c("共享会话拒绝重复begin",!r.begin() && capture.starts==1);r.synchronizeForTests();socket.opened?();r.synchronizeForTests();capture.onPCM?(Data(repeating:1,count:6400));r.synchronizeForTests();wait(0.25);r.synchronizeForTests();c("TCP/WS open不等于Tencent ready",socket.messages.isEmpty)
        // Capture generated request voice_id without logging URL or any credential.
        let late=socket.received;r.abort();c("取消清理采集传输",capture.stops>0 && socket.closed>0 && http.cancelled>0 && finals==0)
        late?(json(["code":0,"voice_id":"old","final":1]));r.synchronizeForTests();c("旧回调不输出",finals==0)
        let tt=Capture(),ts=Socket();let tr=CloudASRRecorder(provider:.tencent,options:.defaults(.tencent),credentials:["appid":"123","secretid":"fake","secretkey":"fake"],capture:tt,http:HTTP(),socketFactory:{ts});var tFinals=0,tText:String?;tr.onFinal={tFinals+=1;tText=$0};_=tr.begin();tr.synchronizeForTests();ts.opened?();tr.synchronizeForTests();tt.onPCM?(Data(repeating:1,count:6402));tr.synchronizeForTests();ts.received?(json(["code":0,"voice_id":ts.voiceID]));tr.synchronizeForTests();tr.end();wait(0.65);tr.synchronizeForTests();ts.received?(json(["code":0,"voice_id":ts.voiceID,"result":["index":0,"slice_type":2,"voice_text_str":"fixture"]]));tr.synchronizeForTests();c("Tencent稳定句仍不输出",tFinals==0);ts.received?(json(["code":0,"voice_id":ts.voiceID,"final":1]));tr.synchronizeForTests();c("Tencent完整会话输出一次",tFinals==1 && tText=="fixture");tr.abort()
        let cp=Capture(),sp=Socket(),hp=HTTP();let i=CloudASRRecorder(provider:.iflytek,options:CloudASROptions(),credentials:["appid":"fake","apikey":"fake","apisecret":"fake"],capture:cp,http:hp,socketFactory:{sp});var iFinals=0,final:String?;i.onFinal={iFinals+=1;final=$0};_=i.begin();i.synchronizeForTests();sp.opened?();i.synchronizeForTests();cp.onPCM?(Data(repeating:1,count:1280*3+2));i.synchronizeForTests();wait(0.055);i.synchronizeForTests();c("IAT每拍最多一帧不突发",sp.messages.count==1);i.end();i.synchronizeForTests();c("松开不提前突发冲刷流式帧",sp.messages.count==1);waitUntil(3){i.synchronizeForTests();return (sp.messages.compactMap{try? ASRJSON.object($0)}.last?["data"] as? [String:Any])?["status"] as? Int==2};i.synchronizeForTests();let frames=sp.messages.compactMap{try? ASRJSON.object($0)};let bytes=frames.compactMap{($0["data"] as? [String:Any])?["audio"] as? String}.compactMap{Data(base64Encoded:$0)}.reduce(0){$0+$1.count};c("停止保留尾音且发送end",bytes==3842 && (frames.last?["data"] as? [String:Any])?["status"] as? Int==2)
        let finalMessage=json(["code":0,"data":["status":2,"result":["sn":0,"ls":true,"ws":[["cw":[["w":"fixture"]]]]]]])
        let callback=sp.received;callback?(finalMessage);i.synchronizeForTests();callback?(finalMessage);i.synchronizeForTests();c("生产会话最终只回调一次",iFinals==1 && final=="fixture");i.abort()
        let cf=Capture(),sf=Socket();let f=CloudASRRecorder(provider:.iflytek,options:CloudASROptions(),credentials:["appid":"fake","apikey":"fake","apisecret":"fake"],capture:cf,http:HTTP(),socketFactory:{sf});var failedText:String?="unchanged";f.onFinal={failedText=$0};_=f.begin();f.synchronizeForTests();sf.opened?();f.synchronizeForTests();sf.received?(json(["code":0,"data":["status":1,"result":["sn":0,"ls":false,"ws":[["cw":[["w":"unconfirmed"]]]]]]]));f.synchronizeForTests();sf.failed?();f.synchronizeForTests();c("断线不输出partial",failedText==nil && f.lastError != nil);f.abort()
        let vc=Capture();var vs:[Socket]=[];let vr=CloudASRRecorder(provider:.iflytek,options:CloudASROptions(),credentials:["appid":"fake","apikey":"fake","apisecret":"fake"],capture:vc,http:HTTP(),socketFactory:{let s=Socket();vs.append(s);return s});var vf=0;vr.onFinal={_ in vf+=1};_=vr.begin();vr.synchronizeForTests();vs[0].opened?();vr.synchronizeForTests();let oldVAD=vs[0].received;oldVAD?(json(["code":0,"data":["status":2,"result":["sn":0,"ls":true,"ws":[["cw":[["w":"prefix"]]]]]]]));vr.synchronizeForTests();c("IAT非主动VAD续接保留且禁止自动输出",vs.count==2 && vf==0 && vr.lastError != nil);oldVAD?(json(["code":11200]));vr.synchronizeForTests();c("IAT续接旧socket迟到不影响新流",vf==0 && vr.state != .failed);vr.abort()
        let ct=Capture(),st=Socket();let timed=CloudASRRecorder(provider:.tencent,options:.defaults(.tencent),credentials:["appid":"123","secretid":"fake-timeout","secretkey":"fake"],capture:ct,http:HTTP(),socketFactory:{st});var timeoutFinal=0;timed.onFinal={_ in timeoutFinal+=1};_=timed.begin();timed.synchronizeForTests();timed.expireForTests();c("超时清理并只失败一次",timeoutFinal==1 && timed.lastError != nil && st.closed>0);timed.expireForTests();c("超时重复回调去重",timeoutFinal==1);timed.abort()
        let cl=Capture(),sl=Socket();let long=CloudASRRecorder(provider:.iflytek,options:CloudASROptions(),credentials:["appid":"fake","apikey":"fake","apisecret":"fake"],capture:cl,http:HTTP(),socketFactory:{sl});_=long.begin();long.synchronizeForTests();sl.opened?();long.synchronizeForTests()
        for _ in 0..<1375 {cl.onPCM?(Data(repeating:1,count:1280));long.synchronizeForTests();long.pumpForTests();long.synchronizeForTests()};long.pumpForTests();long.synchronizeForTests()
        let longFrames=sl.messages.compactMap{try? ASRJSON.object($0)};c("IAT55秒发送端主动尾帧等待确认 synthetic=true",(longFrames.last?["data"] as? [String:Any])?["status"] as? Int==2);long.abort()
        let overflowCapture=Capture();let overflow=CloudASRRecorder(provider:.tencent,options:.defaults(.tencent),credentials:["appid":"123","secretid":"fake","secretkey":"fake"],capture:overflowCapture,http:HTTP(),socketFactory:{Socket()});_=overflow.begin();overflow.synchronizeForTests();overflowCapture.onPCM?(Data(repeating:0,count:256002));overflow.synchronizeForTests();c("连接等待时音频内存上限失败清理",overflow.lastError != nil && overflowCapture.stops>0);overflow.abort()
        let cn=Capture(),sn=Socket(),hn=HTTP([Data("{\"Token\":{\"Id\":\"fake-token-one\",\"ExpireTime\":4102444800}}".utf8),Data("{\"Token\":{\"Id\":\"fake-token-two\",\"ExpireTime\":4102444800}}".utf8)])
        let n=CloudASRRecorder(provider:.aliyun,options:.defaults(.aliyun),credentials:["appkey":"fake","accesskeyid":"fake-nls-refresh","accesskeysecret":"fake"],capture:cn,http:hn,socketFactory:{sn});var nFinals=0;n.onFinal={_ in nFinals+=1};_=n.begin();for _ in 0..<4{n.synchronizeForTests()};sn.opened?();n.synchronizeForTests();n.synchronizeForTests();cn.onPCM?(Data(repeating:1,count:3200));n.synchronizeForTests();c("NLS Start成功发送尚不ready",sn.messages.count==1)
        sn.received?(json(["header":["task_id":sn.taskID,"name":"TaskFailed","status":40000001]]));for _ in 0..<5{n.synchronizeForTests()};c("NLS未发PCM的Token错误只刷新一次",hn.calls==2 && nFinals==0);sn.opened?();for _ in 0..<3{n.synchronizeForTests()};sn.received?(json(["header":["task_id":sn.taskID,"name":"TaskFailed","status":40000001]]));n.synchronizeForTests();c("NLS重复Token错误不无限重连",hn.calls==2 && nFinals==1 && n.lastError != nil);n.abort()
        let ca=Capture(),sa=Socket(),ha=HTTP([Data("{\"Token\":{\"Id\":\"fake-token-success\",\"ExpireTime\":4102444800}}".utf8)]);let ar=CloudASRRecorder(provider:.aliyun,options:.defaults(.aliyun),credentials:["appkey":"fake","accesskeyid":"fake-nls-success","accesskeysecret":"fake"],capture:ca,http:ha,socketFactory:{sa});var aFinals=0,aText:String?;ar.onFinal={aFinals+=1;aText=$0};_=ar.begin();for _ in 0..<4{ar.synchronizeForTests()};sa.opened?();for _ in 0..<3{ar.synchronizeForTests()};ca.onPCM?(Data(repeating:1,count:3202));ar.synchronizeForTests();sa.received?(json(["header":["task_id":sa.taskID,"name":"TranscriptionStarted","status":20000000]]));ar.synchronizeForTests();ar.end();wait(0.35);ar.synchronizeForTests();sa.received?(json(["header":["task_id":sa.taskID,"name":"SentenceEnd","status":20000000],"payload":["index":1,"result":"fixture"]]));ar.synchronizeForTests();c("NLS句子稳定仍不输出",aFinals==0);sa.received?(json(["header":["task_id":sa.taskID,"name":"TranscriptionCompleted","status":20000000]]));ar.synchronizeForTests();c("NLS完整会话输出一次",aFinals==1 && aText=="fixture");ar.abort()
        let rbCapture=Capture(),rbHTTP=HTTP([Data("{\"access_token\":\"fake-one\",\"expires_in\":3600}".utf8),Data("{\"err_no\":3302}".utf8),Data("{\"access_token\":\"fake-two\",\"expires_in\":3600}".utf8),Data("{\"err_no\":3302}".utf8)]);let rb=CloudASRRecorder(provider:.baidu,options:.defaults(.baidu),credentials:["apikey":"fake-baidu-retry","secretkey":"fake"],capture:rbCapture,http:rbHTTP);var rbFinals=0;rb.onFinal={_ in rbFinals+=1};_=rb.begin();rb.synchronizeForTests();rbCapture.onPCM?(Data(repeating:1,count:32));rb.synchronizeForTests();rb.end();for _ in 0..<10{rb.synchronizeForTests()};c("百度Token过期有限刷新后失败无重试循环",rbHTTP.calls==4 && rbFinals==1 && rb.lastError != nil);rb.abort()
        let cb=Capture(),hb=HTTP([Data("{\"access_token\":\"fake\",\"expires_in\":3600}".utf8),Data("{\"err_no\":0,\"result\":[\"fixture\"]}".utf8)]);let b=CloudASRRecorder(provider:.baidu,options:.defaults(.baidu),credentials:["apikey":"fake-baidu","secretkey":"fake-baidu"],capture:cb,http:hb,socketFactory:{Socket()});var bFinals=0;b.onFinal={_ in bFinals+=1};_=b.begin();b.synchronizeForTests();cb.onPCM?(Data(repeating:1,count:32));b.synchronizeForTests();c("百度停止前不HTTP上传",hb.calls==0);b.end();for _ in 0..<4{b.synchronizeForTests()};c("百度整段Token及识别完成",hb.calls==2 && bFinals==1);b.abort()
        let cs=Capture();cs.hasSignal=false;let hs=HTTP();let silent=CloudASRRecorder(provider:.baidu,options:.defaults(.baidu),credentials:["apikey":"fake-silent","secretkey":"fake-silent"],capture:cs,http:hs);var silentText:String?="unchanged";silent.onFinal={silentText=$0};_=silent.begin();silent.synchronizeForTests();cs.onPCM?(Data(repeating:0,count:32));silent.synchronizeForTests();silent.end();silent.synchronizeForTests();c("百度全零信号不外发",hs.calls==0 && silentText==nil);silent.abort()
    }
}
