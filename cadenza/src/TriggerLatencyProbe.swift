import AppKit

/// Simulated keyDown -> successful nonempty SDK audio send, with production IAT serialization
/// and native WebSocket, loopback server, identical synthetic source. No config/Keychain/mic.
enum TriggerLatencyProbe {
    static func run(mode:String)->Int32 {
        guard ["legacy","gated"].contains(mode),TriggerLoopbackTransport.available else{print("local-fixture-required=true");return 3}
        let capture=TriggerLoopbackTransport.SyntheticCapture(),lock=NSLock();var first:Double?
        var options=CloudASROptions();options.consent=true
        let down=ProcessInfo.processInfo.systemUptime
        func consumer(_ feed:CloudPCMCapturing)->HoldRecordingSession {
            let cloud=CloudASRRecorder(provider:.iflytek,options:options,credentials:TriggerLoopbackTransport.credentials,capture:feed,
                http:TriggerLoopbackTransport.HTTP("latency-"+mode,down:down),socketFactory:{TriggerLoopbackTransport.Socket("latency-"+mode,down:down)})
            cloud.onAudioSendCompleted={at in lock.lock();if first==nil{first=at};lock.unlock()};return cloud
        }
        let recorder:HoldRecordingSession
        if mode == "legacy"{recorder=consumer(capture)}
        else{recorder=TriggeredRecorder(capture:capture,limit:256000,uid:"",allowed:{true},makeConsumer:{consumer($0)})}
        guard recorder.begin() else{return 4}
        if let staged=recorder as? TriggeredRecorder {
            RunLoop.main.run(until:Date().addingTimeInterval(0.3));guard staged.releaseSubmission() else{staged.abort();return 5}
        }
        RunLoop.main.run(until:Date().addingTimeInterval(max(0,1.5-(ProcessInfo.processInfo.systemUptime-down))))
        recorder.abort();lock.lock();let sent=first;lock.unlock()
        guard let sent=sent else{print("first_audio_sent=false");return 6}
        print(String(format:"mode=%@ simulated_down_to_first_audio_sdk_completion_ms=%.3f synthetic=true loopback_only=true keychain=false microphone=false",mode,(sent-down)*1000));return 0
    }
}
