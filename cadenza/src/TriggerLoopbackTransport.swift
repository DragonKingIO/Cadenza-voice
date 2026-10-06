import Foundation
import Darwin

/// Test-only, fail-closed routing: every original provider hostname is queried through
/// a loopback UDP DNS fixture, then ONLY numeric loopback URLs reach URLSession.
/// This does not change system DNS or observe unrelated processes' OS DNS traffic.
enum TriggerLoopbackTransport {
    static let credentials=["appid":"123456","apikey":"test-key","apisecret":"test-secret","secretid":"test-id","secretkey":"test-secret","appkey":"test-app","accesskeyid":"test-id","accesskeysecret":"test-secret"]
    static var available:Bool {port("TRIGGER_LOCAL_PORT") != nil && port("TRIGGER_DNS_PORT") != nil}
    static func port(_ name:String)->UInt16? {
        guard let raw=ProcessInfo.processInfo.environment[name],let p=UInt16(raw),p>1024 else{return nil};return p
    }
    static func routed(_ request:URLRequest,scenario:String,down:Double)->URLRequest? {
        guard let tcp=port("TRIGGER_LOCAL_PORT"),let dns=port("TRIGGER_DNS_PORT"),let host=request.url?.host,
              host.hasSuffix("xfyun.cn") || host.hasSuffix("bytedance.com") || host.hasSuffix("tencentcloudapi.com") || host.hasSuffix("tencent.com") || host.hasSuffix("aliyuncs.com") || host.hasSuffix("baidubce.com") || host.hasSuffix("baidu.com"),
              resolveLocally(host,port:dns) else{return nil}
        let scheme=request.url?.scheme == "wss" ? "ws":"http"
        var local=URLRequest(url:URL(string:"\(scheme)://127.0.0.1:\(tcp)/\(scenario)")!)
        local.httpMethod=request.httpMethod;local.httpBody=request.httpBody
        local.setValue(String(down),forHTTPHeaderField:"X-Probe-Down")
        if let voiceID=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name == "voice_id"})?.value {
            local.setValue(voiceID,forHTTPHeaderField:"X-Probe-Voice-ID")
        }
        // Never forward real authorization headers or provider query parameters.
        return local
    }
    private static func resolveLocally(_ host:String,port:UInt16)->Bool {
        let fd=socket(AF_INET,SOCK_DGRAM,0);guard fd>=0 else{return false};defer{Darwin.close(fd)}
        var timeout=timeval(tv_sec:1,tv_usec:0)
        _=setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout.size(ofValue:timeout)))
        var addr=sockaddr_in();addr.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);addr.sin_family=sa_family_t(AF_INET);addr.sin_port=port.bigEndian
        _=inet_pton(AF_INET,"127.0.0.1",&addr.sin_addr)
        var query=Data([0x54,0x52,1,0,0,1,0,0,0,0,0,0])
        for label in host.split(separator:"."){query.append(UInt8(label.utf8.count));query.append(contentsOf:label.utf8)}
        query.append(contentsOf:[0,0,1,0,1])
        let sent=query.withUnsafeBytes{raw in withUnsafePointer(to:&addr){ptr in ptr.withMemoryRebound(to:sockaddr.self,capacity:1){sendto(fd,raw.baseAddress,raw.count,0,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}}
        guard sent==query.count else{return false}
        var bytes=[UInt8](repeating:0,count:512);let count=recv(fd,&bytes,bytes.count,0)
        return count>=16 && bytes[0]==0x54 && bytes[1]==0x52 && Array(bytes[(count-4)..<count])==[127,0,0,1]
    }
    final class Socket:ASRSocket {
        let native=NativeASRSocket(),scenario:String,down:Double
        var opened:(()->Void)?{get{native.opened}set{native.opened=newValue}}
        var received:((URLSessionWebSocketTask.Message)->Void)?{get{native.received}set{native.received=newValue}}
        var failed:(()->Void)?{get{native.failed}set{native.failed=newValue}}
        var authRejected:(()->Void)?{get{native.authRejected}set{native.authRejected=newValue}}
        init(_ scenario:String,down:Double){self.scenario=scenario;self.down=down}
        func connect(_ request:URLRequest){guard let r=TriggerLoopbackTransport.routed(request,scenario:scenario,down:down) else{failed?();return};native.connect(r)}
        func send(_ message:URLSessionWebSocketTask.Message,completion:@escaping(Bool)->Void){native.send(message,completion:completion)}
        func close(){native.close()}
    }
    final class HTTP:ASRHTTP {
        let native=NativeASRHTTP(),scenario:String,down:Double
        init(_ scenario:String,down:Double){self.scenario=scenario;self.down=down}
        func request(_ request:URLRequest,completion:@escaping(Result<Data,Error>)->Void){guard let r=TriggerLoopbackTransport.routed(request,scenario:scenario,down:down) else{completion(.failure(ASRFailure.protocolInvalid));return};native.request(r,completion:completion)}
        func cancel(){native.cancel()}
    }
    final class SyntheticCapture:CloudPCMCapturing {
        var onPCM:((Data)->Void)?,onLevel:((Float)->Void)?,startedUptime:TimeInterval?,lastError:String?
        var hasSignal=true
        private var timer:Timer?,sampleIndex=0
        func start(uid:String)->Bool {
            startedUptime=ProcessInfo.processInfo.systemUptime
            timer=Timer.scheduledTimer(withTimeInterval:0.02,repeats:true){[weak self] _ in
                guard let self=self else{return};var pcm=Data()
                for _ in 0..<320 {var sample=Int16(4000*sin(Double(self.sampleIndex)*2*Double.pi*440/16000)).littleEndian;self.sampleIndex+=1;withUnsafeBytes(of:&sample){pcm.append(contentsOf:$0)}}
                self.onPCM?(pcm)
            };return true
        }
        func stop(){timer?.invalidate();timer=nil}
    }
}
