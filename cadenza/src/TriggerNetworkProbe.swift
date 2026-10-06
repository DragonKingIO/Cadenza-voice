import AppKit


/// Event-based loopback transport + local UDP DNS fixture. No microphone/real credentials.
enum TriggerNetworkProbe {
    static func run()->Int32 {
        guard TriggerLoopbackTransport.available else{print("local-fixture-required=true");return 3}
        var phase="",downTime=0.0
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("trigger-net-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=ConfigStore(fileURL:root.appendingPathComponent("config.json"))
        let pipeline=VoicePipeline(configStore:store,input:InputSourceController());pipeline.selfTestMode=true
        pipeline.snapshotFocus={FocusIdentity(pid:ProcessInfo.processInfo.processIdentifier,appName:"probe",element:nil,window:nil,role:nil,readable:false,selectedTextWritable:false,value:nil)}
        let coordinator=TriggerCoordinator(store:store,pipeline:pipeline)
        coordinator.microphoneAccess={true};coordinator.credentialsReady={_ in true}
        var lastCapture:TriggerStage2Fixtures.Capture?
        coordinator.captureFactory={let c=TriggerStage2Fixtures.Capture();lastCapture=c;return c}
        coordinator.consumerFactory={feed in
            let c=store.config,provider=ASREngine(rawValue:c.engine)!
            return CloudASRRecorder(provider:provider,options:c.options(provider),credentials:TriggerLoopbackTransport.credentials,capture:feed,
                http:TriggerLoopbackTransport.HTTP(phase,down:downTime),socketFactory:{TriggerLoopbackTransport.Socket(phase,down:downTime)})
        }
        coordinator.automaticTimers=false;coordinator.automaticEscapeMonitoring=false
        func mark(_ name:String){print("network-probe phase=\(name) uptime=\(ProcessInfo.processInfo.systemUptime)");fflush(stdout)}
        let down=AppTriggerMachine.Event.keyDown(binding:.primary,isRepeat:false,standaloneModifier:true)
        for scenario in ["no-consent","pre-gate-chord","extreme-tap"] {
            mark(scenario)
            var n=0
            for _ in 0..<15 {
                var c=BridgeConfig.default();let provider:[ASREngine]=[.iflytek,.volcengine,.tencent,.aliyun,.baidu]
                let selected=provider[n%provider.count];c.engine=selected.rawValue;c.triggerCoordinatorEnabled=true
                c.inputMode=["hold","toggle","hybrid"][n%3]
                var o=CloudASROptions();o.consent=scenario != "no-consent";c.setOptions(selected,o);_=store.mutate{$0=c}
                lastCapture=nil;phase=scenario;downTime=ProcessInfo.processInfo.systemUptime;coordinator.handle(down)
                lastCapture?.emit(0.02)
                // Real elapsed time stays below the 300ms gate; no cloud factory override.
                RunLoop.main.run(until:Date().addingTimeInterval(0.015))
                if scenario == "extreme-tap" {coordinator.handle(.keyUp(binding:.primary))}
                else {coordinator.handle(.otherKeyDown);coordinator.handle(.keyUp(binding:.primary))}
                RunLoop.main.run(until:Date().addingTimeInterval(0.08));n+=1
            }
            mark(scenario+"-finished-cycles-"+String(n))
        }
        phase="whole-cancel-after-gate";mark(phase)
        for mode in ["hold","toggle","hybrid"] {
            var c=BridgeConfig.default();c.engine="baidu";c.inputMode=mode;c.triggerCoordinatorEnabled=true
            var o=CloudASROptions.defaults(.baidu);o.consent=true;c.setOptions(.baidu,o);_=store.mutate{$0=c}
            downTime=ProcessInfo.processInfo.systemUptime;coordinator.handle(down);lastCapture?.emit(0.6)
            RunLoop.main.run(until:Date().addingTimeInterval(0.31));coordinator.poll();coordinator.handle(.escape)
            RunLoop.main.run(until:Date().addingTimeInterval(0.08))
        }
        mark(phase+"-finished-cycles-3")
        // Positive controls use the SAME routing and native transports as zero-request cases.
        for provider in [ASREngine.iflytek,.volcengine,.tencent,.aliyun,.baidu] {
            var options=CloudASROptions.defaults(provider);options.consent=true
            let name="positive-"+provider.rawValue,at=ProcessInfo.processInfo.systemUptime
            let capture=TriggerLoopbackTransport.SyntheticCapture()
            let recorder=CloudASRRecorder(provider:provider,options:options,credentials:TriggerLoopbackTransport.credentials,capture:capture,
                http:TriggerLoopbackTransport.HTTP(name,down:at),socketFactory:{TriggerLoopbackTransport.Socket(name,down:at)})
            _=recorder.begin();RunLoop.main.run(until:Date().addingTimeInterval(0.7))
            recorder.end();RunLoop.main.run(until:Date().addingTimeInterval(0.5));recorder.abort()
        }
        print("network-probe loopback_only=true keychain=false microphone=false real_key_events=false")
        return 0
    }
}
