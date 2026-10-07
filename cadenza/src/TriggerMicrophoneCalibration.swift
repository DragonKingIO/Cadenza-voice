import AVFoundation

/// Explicit opt-in diagnostic. Only scalar RMS/detector statistics survive each PCM callback.
/// No recognizer, network transport, credentials, audio file, or application config is used.
enum TriggerMicrophoneCalibration {
    /// Each sample has one user-marked condition, no automatic mixed-phase labeling.
    static func sample(label:String,seconds:Int)->Int32 {
        guard ["quiet","fan-music","keyboard-mouse","normal","whisper","far"].contains(label),[30,60].contains(seconds) else{return 2}
        guard TCC.micStatus() == .authorized else{print("calibration permission-required=true");return 3}
        let capture=CloudPCMCapture(),lock=NSLock();var detector=SpeechEnergyDetector()
        var rms:[Float]=[],durations:[Double]=[],total=0.0,detected=0.0,onsets=0
        capture.onPCM={data in
            guard data.count>=2 else{return};var sum=0.0
            data.withUnsafeBytes{raw in for i in stride(from:0,to:data.count-1,by:2){let v=Double(Int16(littleEndian:raw.loadUnaligned(fromByteOffset:i,as:Int16.self)))/32768;sum+=v*v}}
            let level=Float(sqrt(sum/Double(data.count/2))),duration=Double(data.count)/32000
            lock.lock();let was=detector.speaking;let speech=detector.observe(level:level,duration:duration)
            if speech && !was{onsets+=1};if speech{detected+=duration}
            rms.append(level);durations.append(duration);total+=duration;lock.unlock()
        }
        guard capture.start(uid:"") else{print("calibration capture-failed=true");return 4}
        print("condition=\(label) duration=\(seconds) noise_floor_seed=0.00737 onset_ratio=3 release_ratio=1.8 onset_seconds=0.12 release_seconds=0.20");fflush(stdout)
        RunLoop.main.run(until:Date().addingTimeInterval(Double(seconds)));capture.stop();capture.onPCM=nil
        lock.lock();defer{lock.unlock()};let sorted=rms.sorted(),frameLengths=durations.sorted()
        guard !sorted.isEmpty,total>0 else{return 5}
        func p(_ q:Double)->Float{sorted[min(sorted.count-1,Int(Double(sorted.count-1)*q))]}
        let medianFrame=frameLengths[frameLengths.count/2]
        print(String(format:"frames=%d pcm_seconds=%.3f frame_seconds_p50=%.5f rms_p5=%.5f rms_p10=%.5f rms_p50=%.5f rms_p90=%.5f rms_p95=%.5f rms_p99=%.5f rms_max=%.5f detected_seconds=%.3f onset_count=%d nondetected_time_fraction=%.5f",sorted.count,total,medianFrame,p(0.05),p(0.1),p(0.5),p(0.9),p(0.95),p(0.99),sorted.last!,detected,onsets,max(0,1-detected/total)))
        // Retain scalar levels only. Compare complete vs trimmed statistics; no PCM is retained.
        for trim in [0.0,1.0,2.0] {
            var elapsed=0.0;var kept:[Float]=[]
            for (level,duration) in zip(rms,durations) {if elapsed>=trim{kept.append(level)};elapsed+=duration}
            kept.sort();if !kept.isEmpty {
                func q(_ p:Double)->Float{kept[min(kept.count-1,Int(Double(kept.count-1)*p))]}
                print(String(format:"trim_start_seconds=%.0f frames=%d rms_p5=%.5f rms_p50=%.5f rms_p95=%.5f",trim,kept.count,q(0.05),q(0.5),q(0.95)))
            }
        }
        var elapsed=0.0
        for window in [0,1,2] {
            elapsed=0;var kept:[Float]=[]
            for (level,duration) in zip(rms,durations) {if elapsed>=Double(window),elapsed<Double(window+1){kept.append(level)};elapsed+=duration}
            kept.sort();if !kept.isEmpty{print(String(format:"startup_second=%d rms_p50=%.5f rms_p95=%.5f",window,kept[kept.count/2],kept[Int(Double(kept.count-1)*0.95)]))}
        }
        print("audio_saved=false transcript_generated=false upload=false")
        return 0
    }
    static func run(environment:String)->Int32 {
        guard ["quiet","noise"].contains(environment) else {print("calibration invalid environment");return 2}
        guard TCC.micStatus() == .authorized else {
            print("calibration microphone permission required; allow the app in System Settings before retrying");return 3
        }
        let capture=CloudPCMCapture(),lock=NSLock();var detector=SpeechEnergyDetector()
        var levels:[[Float]]=[[],[]],speaking=[0.0,0.0],seconds=[0.0,0.0],frames=[0,0]
        let start=ProcessInfo.processInfo.systemUptime
        capture.onPCM={data in
            let phase=min(1,Int((ProcessInfo.processInfo.systemUptime-start)/5))
            var sum=0.0
            data.withUnsafeBytes{raw in for i in stride(from:0,to:data.count-1,by:2){let v=Double(Int16(littleEndian:raw.loadUnaligned(fromByteOffset:i,as:Int16.self)))/32768;sum += v*v}}
            let rms=Float(sqrt(sum/Double(max(1,data.count/2)))),duration=Double(data.count)/32000
            lock.lock();levels[phase].append(rms);seconds[phase]+=duration;frames[phase]+=1
            if detector.observe(level:rms,duration:duration){speaking[phase]+=duration};lock.unlock()
        }
        guard capture.start(uid:"") else{print("calibration microphone could not start");return 4}
        print("calibration environment=\(environment) noise_floor_seed=0.00737 onset_ratio=3 release_ratio=1.8 onset=0.12s release=0.20s audioSaved=false upload=false")
        print("phase=baseline duration=5s remain silent");fflush(stdout)
        RunLoop.main.run(until:Date().addingTimeInterval(5))
        print("phase=speech duration=5s say one sentence continuously");fflush(stdout)
        RunLoop.main.run(until:Date().addingTimeInterval(5));capture.stop();capture.onPCM=nil
        lock.lock();defer{lock.unlock()}
        for i in 0..<2 {
            let sorted=levels[i].sorted();guard !sorted.isEmpty else{print("calibration no samples phase=\(i)");return 5}
            func percentile(_ p:Double)->Float{sorted[min(sorted.count-1,Int(Double(sorted.count-1)*p))]}
            print(String(format:"phase=%@ frames=%d seconds=%.3f rms_p5=%.5f rms_p50=%.5f rms_p95=%.5f rms_max=%.5f detected_seconds=%.3f",i==0 ? "baseline":"speech",frames[i],seconds[i],percentile(0.05),percentile(0.5),percentile(0.95),sorted.last!,speaking[i]))
        }
        return 0
    }
}
