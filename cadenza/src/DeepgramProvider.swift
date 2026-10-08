import Foundation

/// Official Nova streaming API only. No custom endpoint, preconnection or automatic vendor fallback.
enum DeepgramAPI {
    static let languages = "multi en zh-CN zh-TW zh-HK af ar hy as be bn bs bg ca hr cs da nl et fi fr ka de el gu he hi hu id it ja kn kk ko lv lt mk ms mr mn ne no ps fa pl pt pa ro ru sr sk sl es sv tl ta te th tr uk ur vi".split(separator:" ").map(String.init)
    /// "multi" covers English, Spanish, French, German, Hindi, Russian, Portuguese, Japanese, Italian and Dutch, not Chinese.
    static func effectiveLanguage(_ language:String,recognitionLocale:String)->String {
        guard language == "multi" else{return language}
        let l=recognitionLocale.lowercased().replacingOccurrences(of:"_",with:"-")
        guard l == "zh" || l.hasPrefix("zh-") else{return language}
        if l.contains("hk") || l.contains("yue") {return "zh-HK"}
        if l.contains("tw") || l.contains("hant") {return "zh-TW"}
        return "zh-CN"
    }
    static func fallbackLanguages(_ options:CloudASROptions)->[String] {
        options.language == "multi" ? ["en","es","fr","de","hi","ru","pt","ja","it","nl"]:[String(options.language.split(separator:"-").first ?? "")]
    }
    /// Key terms are one per line, up to 100, each up to 60 characters. Nova-3 takes them as repeated `keyterm` parameters.
    static func validKeyterms(_ hotwords:String)->Bool {
        let lines=hotwords.split(separator:"\n",omittingEmptySubsequences:false)
        return hotwords.isEmpty || lines.count<=100 && lines.allSatisfy{!$0.isEmpty && $0.count<=60 && $0 == $0.trimmingCharacters(in:.whitespaces)}
    }
    /// Key terms are only sent for English and the multilingual model; elsewhere the service's support is not confirmed, and a
    /// refused request would cost the whole dictation.
    static func keytermsApply(_ language:String)->Bool { ["en","multi"].contains(language) }
    static func request(options:CloudASROptions,key:String)->URLRequest? {
        guard options.consent,ASROptionPolicy.validate(.deepgram,options)==nil,!key.isEmpty,key.count<=4096,
              key.rangeOfCharacter(from:.controlCharacters)==nil else{return nil}
        var url=URLComponents(string:"wss://api.deepgram.com/v1/listen")!
        url.queryItems=[URLQueryItem(name:"model",value:"nova-3"),URLQueryItem(name:"language",value:options.language),
            URLQueryItem(name:"encoding",value:"linear16"),URLQueryItem(name:"sample_rate",value:"16000"),
            URLQueryItem(name:"channels",value:"1"),URLQueryItem(name:"interim_results",value:"true"),
            URLQueryItem(name:"punctuate",value:String(options.punctuation)),URLQueryItem(name:"smart_format",value:String(options.itn))]
        if keytermsApply(options.language) {url.queryItems! += options.hotwords.split(separator:"\n").map{URLQueryItem(name:"keyterm",value:String($0))}}
        var request=URLRequest(url:url.url!);request.setValue("Token "+key,forHTTPHeaderField:"Authorization")
        return request
    }
}

/// Results are segments, not whole-transcript snapshots. Only close-stream metadata completes a recording.
final class DeepgramWire:ASRWire {
    let frameBytes=1280,interval=0.04,rotateAfterBytes:Int?=nil,readyOnOpen=true
    let start:URLSessionWebSocketTask.Message?=nil
    private var closed=false
    private var segments:[Double:(duration:Double,text:String)]=[:]
    private var partial=""
    private var finalEnd:Double=0
    private var text:String { (segments.keys.sorted().compactMap{segments[$0]?.text}+(!partial.isEmpty ? [partial]:[])).filter{!$0.isEmpty}.joined(separator:" ") }
    func audio(_ bytes:Data,first:Bool,last:Bool)throws->URLSessionWebSocketTask.Message {
        guard !closed,bytes.count%2==0 else{throw ASRFailure.protocolInvalid}
        if last {guard bytes.isEmpty else{throw ASRFailure.protocolInvalid};closed=true;return try ASRJSON.message(["type":"CloseStream"])}
        return .data(bytes)
    }
    func parse(_ message:URLSessionWebSocketTask.Message)throws->ASRWireUpdate {
        let o=try ASRJSON.object(message)
        guard let type=o["type"] as? String else{throw ASRFailure.protocolInvalid}
        if type == "Error" {
            // Never echo the remote message, which can contain user or credential data.
            let code=o["code"] as? String ?? ""
            let key=code.contains("401") || code.contains("403") ? "deepgram.auth":code.contains("429") ? "deepgram.quota":"deepgram.failure"
            throw ASRServiceError(hint:L10n.tr(key))
        }
        if type == "Metadata" {
            guard let requestID=o["request_id"] as? String,!requestID.isEmpty,requestID.count<=128,
                  let duration=o["duration"] as? Double,duration.isFinite,duration>=0,
                  let channels=o["channels"] as? Int,(0...1).contains(channels) else{throw ASRFailure.protocolInvalid}
            guard !closed || partial.isEmpty else{throw ASRFailure.protocolInvalid}
            return ASRWireUpdate(text:text,final:closed)
        }
        if type == "SpeechStarted" || type == "UtteranceEnd" {return ASRWireUpdate()}
        guard type == "Results",let isFinal=o["is_final"] as? Bool,let start=o["start"] as? Double,
              let duration=o["duration"] as? Double,start.isFinite,duration.isFinite,start>=0,duration>=0,
              let channel=o["channel"] as? [String:Any],let alternatives=channel["alternatives"] as? [[String:Any]],
              let transcript=alternatives.first?["transcript"] as? String,transcript.utf8.count<=262144 else{throw ASRFailure.protocolInvalid}
        if let previous=segments[start] {
            guard !isFinal || previous.text==transcript && abs(previous.duration-duration)<0.001 else{throw ASRFailure.protocolInvalid}
            return ASRWireUpdate(text:text)
        }
        // Already-finalized windows cannot be resurrected by a late interim packet.
        if start+0.001<finalEnd{return ASRWireUpdate(text:text)}
        if isFinal {
            guard segments.count<10000 else{throw ASRFailure.protocolInvalid}
            segments[start]=(duration,transcript);finalEnd=max(finalEnd,start+duration);partial=""
        } else {partial=transcript}
        guard text.utf8.count<=1048576 else{throw ASRFailure.protocolInvalid}
        return ASRWireUpdate(text:text) // speech_final is an utterance boundary, not session completion.
    }
}
