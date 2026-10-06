import AVFoundation
import Speech

/// Relative energy approximation, not semantic VAD. Seed is provisional quiet calibration,
/// not a fixed speech cutoff; calibrate separately for each device/environment before enabling.
struct SpeechEnergyDetector {
    var noiseFloor:Float = 0.00737
    var onsetRatio:Float = 3.0
    var releaseRatio:Float = 1.8
    var onsetSeconds:Double = 0.12
    var releaseSeconds:Double = 0.20
    private var above=0.0,below=0.0
    private(set) var speaking=false
    init(noiseFloor:Float=0.00737){self.noiseFloor=max(Float.leastNormalMagnitude,noiseFloor)}
    mutating func observe(level:Float,duration:Double)->Bool {
        guard level.isFinite,level>=0,duration.isFinite,duration>0 else{return speaking}
        let floor=max(noiseFloor,Float.leastNormalMagnitude)
        if !speaking {
            if level >= floor*onsetRatio {above += duration;if above >= onsetSeconds{speaking=true;below=0}}
            else {
                above=0
                // Update only confidently quiet frames, never learn a voice onset as noise.
                if level < floor*releaseRatio {
                    let weight=Float(1-exp(-duration/5))
                    noiseFloor=max(Float.leastNormalMagnitude,noiseFloor+(level-noiseFloor)*weight)
                }
            }
        } else {
            if level < floor*releaseRatio {below += duration;if below >= releaseSeconds{speaking=false;above=0}}
            else {below=0}
        }
        return speaking
    }
}

/// Virtual capture for an ASR consumer. It never starts a microphone or a service itself.
final class TriggerPCMFeed:CloudPCMCapturing {
    var onPCM:((Data)->Void)?,onLevel:((Float)->Void)?
    var startedUptime:TimeInterval?,lastError:String?,hasSignal=false
    func start(uid:String)->Bool {true}
    func stop(){}
}

/// Apple recognizer consuming already-captured PCM16; no second microphone/tap.
final class TriggerAppleRecognizer:HoldRecordingSession {
    var onLevel:((Float)->Void)?,onPartial:((String)->Void)?,onFinal:((String?)->Void)?
    private(set) var lastError:String?
    private let feed:TriggerPCMFeed,locale:String,allowCloud:Bool
    private var request:SFSpeechAudioBufferRecognitionRequest?,task:SFSpeechRecognitionTask?
    private var ended=false,delivered=false
    var capturedAudioHasSignal:Bool?{feed.hasSignal}
    init(feed:TriggerPCMFeed,locale:String,allowCloud:Bool){self.feed=feed;self.locale=locale;self.allowCloud=allowCloud}
    func begin()->Bool {
        guard HoldNativeEngine.speechAuthorized(),let recognizer=SFSpeechRecognizer(locale:Locale(identifier:locale)),recognizer.supportsOnDeviceRecognition || allowCloud else{lastError=L10n.tr("ui.5758a2095d35");return false}
        let req=SFSpeechAudioBufferRecognitionRequest();req.shouldReportPartialResults=true
        req.requiresOnDeviceRecognition=recognizer.supportsOnDeviceRecognition;request=req
        feed.onPCM={data in
            let format=AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:16000,channels:1,interleaved:true)!
            guard let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(data.count/2)),let target=buffer.int16ChannelData?[0] else{return}
            buffer.frameLength=AVAudioFrameCount(data.count/2)
            data.withUnsafeBytes{raw in if let source=raw.baseAddress{memcpy(target,source,data.count)}};req.append(buffer)
        }
        task=recognizer.recognitionTask(with:req){[weak self] result,error in DispatchQueue.main.async{
            guard let self=self,!self.delivered else{return}
            if let result=result {if result.isFinal{self.finish(result.bestTranscription.formattedString)}else{self.onPartial?(result.bestTranscription.formattedString)}}
            else if error != nil{self.lastError=L10n.tr("ui.b9ca8c5af699");self.finish(nil)}
        }}
        return true
    }
    func end(){guard !ended else{return};ended=true;request?.endAudio();DispatchQueue.main.asyncAfter(deadline:.now()+5){[weak self] in self?.finish(nil)}}
    private func finish(_ text:String?){guard !delivered else{return};delivered=true;feed.onPCM=nil;let cb=onFinal;onFinal=nil;cb?(text)}
    func abort(){delivered=true;feed.onPCM=nil;request=nil;task?.cancel();task=nil;onFinal=nil;onPartial=nil}
}

/// One hardware capture, bounded pre-gate buffer, lazy service construction.
/// All mutable session state is main-thread owned; PCM callbacks enter in capture order.
final class TriggeredRecorder:HoldRecordingSession {
    var onLevel:((Float)->Void)?,onPartial:((String)->Void)?,onFinal:((String?)->Void)?
    var onSamples:((Double,Bool)->Void)?,onOverflow:(()->Void)?
    private(set) var lastError:String?
    var captureStartedUptime:TimeInterval?{capture.startedUptime}
    var capturedAudioHasSignal:Bool?{capture.hasSignal}
    private let capture:CloudPCMCapturing,limit:Int,uid:String
    private let allowed:()->Bool,makeConsumer:(TriggerPCMFeed)->HoldRecordingSession?
    private let feed=TriggerPCMFeed()
    private var buffer=Data(),consumer:HoldRecordingSession?,detector=SpeechEnergyDetector()
    private var capturing=false,cancelled=false,released=false,ended=false
    private var ingressBytes=0
    private let ingressLock=NSLock()
    var bufferedBytes:Int{buffer.count}
    var serviceStarted:Bool{released}
    init(capture:CloudPCMCapturing=CloudPCMCapture(),limit:Int,uid:String,allowed:@escaping()->Bool,makeConsumer:@escaping(TriggerPCMFeed)->HoldRecordingSession?) {
        self.capture=capture;self.limit=limit;self.uid=uid;self.allowed=allowed;self.makeConsumer=makeConsumer
    }
    func begin()->Bool {
        guard !capturing,!cancelled,allowed() else{lastError=L10n.tr("ui.bff9ad6ef28e");return false}
        capturing=true
        capture.onPCM={[weak self] data in
            guard let self=self else{return}
            self.ingressLock.lock();let accept=self.ingressBytes+data.count<=self.limit;if accept{self.ingressBytes += data.count};self.ingressLock.unlock()
            if !accept {DispatchQueue.main.async{[weak self] in self?.overflow()};return}
            DispatchQueue.main.async{[weak self] in
                guard let self=self else{return};self.ingressLock.lock();self.ingressBytes -= data.count;self.ingressLock.unlock()
                self.ingest(data)
            }
        }
        guard capture.start(uid:uid) else{capturing=false;lastError=capture.lastError;capture.onPCM=nil;return false}
        feed.startedUptime=capture.startedUptime;return true
    }
    private func ingest(_ data:Data) {
        guard !cancelled,!ended,data.count%2==0 else{return}
        var sum=0.0
        data.withUnsafeBytes{raw in for i in stride(from:0,to:data.count,by:2){let value=Double(Int16(littleEndian:raw.loadUnaligned(fromByteOffset:i,as:Int16.self)))/32768;sum += value*value}}
        let duration=Double(data.count)/32000,level=Float(sqrt(sum/Double(max(1,data.count/2))))
        feed.hasSignal=feed.hasSignal || level>0;onLevel?(min(1,level*10))
        onSamples?(duration,detector.observe(level:level,duration:duration))
        guard !cancelled else{return}
        if released {feed.onPCM?(data)}
        else if buffer.count+data.count<=limit {buffer.append(data)} else {overflow()}
    }
    private func overflow(){guard !cancelled,!ended else{return};lastError=L10n.tr("ui.af34b4d93562");onOverflow?()}
    @discardableResult func releaseSubmission()->Bool {
        guard !cancelled else{return false};if released{return true}
        guard allowed(),let consumer=makeConsumer(feed) else{lastError=L10n.tr("ui.638bbd8fe92b");return false}
        self.consumer=consumer
        consumer.onPartial={[weak self] text in DispatchQueue.main.async{[weak self] in guard let self=self,!self.cancelled else{return};self.onPartial?(text)}}
        consumer.onFinal={[weak self] text in DispatchQueue.main.async{[weak self] in guard let self=self,!self.cancelled else{return};self.lastError=self.consumer?.lastError;self.onFinal?(text)}}
        guard consumer.begin() else{lastError=consumer.lastError;consumer.abort();self.consumer=nil;return false}
        released=true;feed.hasSignal=capture.hasSignal
        let pending=buffer;buffer.removeAll(keepingCapacity:false);if !pending.isEmpty{feed.onPCM?(pending)}
        Log.write("trigger-submit service-started=true buffered-bytes=\(pending.count)")
        return true
    }
    func stopCapture(){guard capturing else{return};capture.stop();capturing=false;capture.onPCM=nil}
    func end(){guard !ended,!cancelled else{return};stopCapture();DispatchQueue.main.async{[weak self] in guard let self=self,!self.ended,!self.cancelled else{return};self.ended=true;self.consumer?.end()}}
    func abort(){guard !cancelled else{return};cancelled=true;stopCapture();buffer.removeAll();consumer?.abort();consumer=nil;feed.onPCM=nil;onPartial=nil;onFinal=nil;onSamples=nil}
}
