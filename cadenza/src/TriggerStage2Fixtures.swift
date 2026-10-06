import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// Uses production recorder/transport implementations with fake PCM and socket/HTTP boundaries.
/// No permissions, real mic, credentials, network, external input or clipboard are used.
enum TriggerStage2Fixtures {
    final class Capture:CloudPCMCapturing {
        var onPCM:((Data)->Void)?,onLevel:((Float)->Void)?
        var hasSignal=true,startedUptime:TimeInterval?=0,lastError:String?
        var starts=0,stops=0
        func start(uid:String)->Bool{starts+=1;return true}
        func stop(){stops+=1}
        func emit(_ seconds:Double){var data=Data();for _ in 0..<Int(seconds*16000){var sample:Int16=2000;withUnsafeBytes(of:&sample){data.append(contentsOf:$0)}};onPCM?(data)}
    }
    final class Socket:ASRSocket {
        var opened:(()->Void)?,received:((URLSessionWebSocketTask.Message)->Void)?,failed:(()->Void)?,authRejected:(()->Void)?
        var connects=0,messages:[URLSessionWebSocketTask.Message]=[]
        func connect(_ request:URLRequest){connects+=1}
        func send(_ message:URLSessionWebSocketTask.Message,completion:@escaping(Bool)->Void){messages.append(message);completion(true)}
        func close(){}
    }
    final class HTTP:ASRHTTP {
        var requests=0
        func request(_ request:URLRequest,completion:@escaping(Result<Data,Error>)->Void){requests+=1}
        func cancel(){}
    }
    final class Recorder:HoldRecordingSession {
        var onLevel:((Float)->Void)?,onPartial:((String)->Void)?,onFinal:((String?)->Void)?,lastError:String?
        var begins=0,ends=0,aborts=0
        func begin()->Bool{begins+=1;return true};func end(){ends+=1};func abort(){aborts+=1}
    }
    static func drain(){RunLoop.main.run(until:Date().addingTimeInterval(0.04))}
    static func run(_ check:(String,Bool)->Void) {
        func cloudTest(whole:Bool,cancel:Bool,consent:Bool) {
            let cap=Capture(),socket=Socket(),http=HTTP();var allowed=consent,created=0
            var service:CloudASRRecorder?
            let r=TriggeredRecorder(capture:cap,limit:whole ? 1_920_000:256000,uid:"",allowed:{allowed},makeConsumer:{feed in
                created+=1;var options=CloudASROptions();options.consent=true
                let recorder=CloudASRRecorder(provider:whole ? .baidu:.iflytek,options:options,credentials:whole ? ["apikey":"fixture-key","secretkey":"fixture-secret"]:["appid":"fixture-app","apikey":"fixture-key","apisecret":"fixture-secret"],capture:feed,http:http,socketFactory:{socket});service=recorder;return recorder
            })
            let began=r.begin()
            if !consent{check("unconsented no capture/service/socket/http",!began && cap.starts==0 && created==0 && socket.connects==0 && http.requests==0);return}
            cap.emit(0.6);drain()
            check("pre-gate captures once but no connection",cap.starts==1 && socket.connects==0 && http.requests==0 && created==0)
            if cancel{r.abort();drain();check("pre-gate cancellation zero requests/audio",socket.connects==0 && http.requests==0 && r.bufferedBytes==0);return}
            if !whole {
                check("streaming releases at gate",r.releaseSubmission());service?.synchronizeForTests()
                check("one streaming connection at gate",socket.connects==1)
                socket.opened?();service?.synchronizeForTests();service?.pumpForTests();service?.synchronizeForTests()
                check("streaming PCM frame actually sent after gate",!socket.messages.isEmpty)
                allowed=false;r.abort();let sent=socket.messages.count;service?.pumpForTests();service?.synchronizeForTests()
                check("post-gate cancel stops subsequent messages",socket.messages.count==sent && http.requests==0)
            } else {
                r.stopCapture();check("whole engine still no request before end commit",socket.connects==0 && http.requests==0)
                check("whole end creates consumer",r.releaseSubmission());service?.synchronizeForTests();r.end();drain();service?.synchronizeForTests()
                check("whole end starts token request only now",http.requests==1 && socket.connects==0)
                r.abort()
            }
        }
        cloudTest(whole:false,cancel:true,consent:true);cloudTest(whole:true,cancel:true,consent:true)
        cloudTest(whole:false,cancel:false,consent:true);cloudTest(whole:true,cancel:false,consent:true)
        cloudTest(whole:false,cancel:false,consent:false);cloudTest(whole:true,cancel:false,consent:false)
        let deniedCap=Capture();var allowed=true,creations=0
        let denied=TriggeredRecorder(capture:deniedCap,limit:256000,uid:"",allowed:{allowed},makeConsumer:{_ in creations+=1;return Recorder()})
        _=denied.begin();deniedCap.emit(0.6);drain();allowed=false
        check("consent revoked before gate prevents consumer",!denied.releaseSubmission() && creations==0);denied.abort()

        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=ConfigStore(fileURL:root.appendingPathComponent("config.json"));var c=BridgeConfig.default();c.triggerCoordinatorEnabled=true;c.inputMode="hold";c.engine="apple";_=store.mutate{$0=c}
        let pipeline=VoicePipeline(configStore:store,input:InputSourceController());pipeline.selfTestMode=true
        pipeline.snapshotFocus={FocusIdentity(pid:ProcessInfo.processInfo.processIdentifier,appName:"fixture",element:nil,window:nil,role:nil,readable:false,selectedTextWritable:false,value:nil)}
        let cap=Capture(),consumer=Recorder();let coordinator=TriggerCoordinator(store:store,pipeline:pipeline)
        var time=0.0;coordinator.clockNow={time};coordinator.microphoneAccess={true};coordinator.credentialsReady={_ in true};coordinator.captureFactory={cap};coordinator.consumerFactory={_ in consumer};coordinator.automaticTimers=false;coordinator.automaticEscapeMonitoring=false
        let down=AppTriggerMachine.Event.keyDown(binding:.primary,isRepeat:false,standaloneModifier:true)
        coordinator.handle(down)
        check("new hold capture begins on down, not at threshold",cap.starts==1 && consumer.begins==0 && pipeline.hasActiveSession)
        cap.emit(0.7);drain();time=0.3;coordinator.poll()
        check("new hold recognizer starts at T",consumer.begins==1)
        time=1;coordinator.handle(.keyUp(binding:.primary));drain()
        check("new hold release stops capture and ends consumer",cap.stops==1 && consumer.ends==1 && pipeline.session?.state == .awaitingConfirm)
        coordinator.handle(down);check("new recognizing down ignored",cap.starts==1 && pipeline.session?.state == .awaitingConfirm)
        consumer.onFinal?("fixture");drain();check("coordinated final resets session",!pipeline.hasActiveSession)

        let legacy=Recorder();pipeline.recorderFactory={legacy};pipeline.coordinatedSession=false;pipeline.holdStarted(source:.button)
        check("legacy hold begins on down",legacy.begins==1);pipeline.holdEnded()
        check("legacy release ends once",legacy.ends==1);pipeline.forceEnd(reason:"fixture-cleanup")
        let cap2=Capture();coordinator.captureFactory={cap2};time=2;coordinator.handle(down)
        coordinator.handle(.otherKeyDown)
        check("new pre-gate chord stops one capture with no service",cap2.starts==1 && cap2.stops==1 && !pipeline.hasActiveSession && consumer.begins==1)
        let oldCancel=Recorder();pipeline.recorderFactory={oldCancel};pipeline.holdStarted(source:.button);pipeline.holdChord(reason:"fixture chord")
        check("legacy chord aborts without end",oldCancel.aborts>=1 && oldCancel.ends==0 && !pipeline.hasActiveSession)
        // Recognition deadline is owned by the new coordinator and does not retain a stale session.
        let timeoutCap=Capture(),timeoutConsumer=Recorder();coordinator.captureFactory={timeoutCap};coordinator.consumerFactory={_ in timeoutConsumer}
        time=3;coordinator.handle(down);timeoutCap.emit(0.7);drain();time=3.3;coordinator.poll();time=4;coordinator.handle(.keyUp(binding:.primary));drain()
        time=16;coordinator.poll()
        check("recognition timeout releases pipeline and coordinator",!pipeline.hasActiveSession && !coordinator.active && timeoutConsumer.aborts>=1)
        timeoutConsumer.onFinal?("stale")
        check("late final after timeout cannot revive session",!pipeline.hasActiveSession)
        let copyCap=Capture(),copyConsumer=Recorder();coordinator.captureFactory={copyCap};coordinator.consumerFactory={_ in copyConsumer}
        pipeline.snapshotFocus={FocusIdentity(pid:1,appName:"fixture",element:nil,window:nil,role:nil,readable:false,selectedTextWritable:false,value:nil)}
        var copied="";pipeline.copyToClipboard={copied=$0}
        time=17;coordinator.handle(down);copyCap.emit(0.7);drain();time=17.3;coordinator.poll();time=18;coordinator.handle(.keyUp(binding:.primary));drain();copyConsumer.onFinal?("fixture");drain();drain()
        check("non-editable final preserves clipboard",copied.isEmpty && !pipeline.coordinatedCopied && !pipeline.lastInputAccepted && !pipeline.hasActiveSession)
        let element=AXUIElementCreateApplication(12345)
        let editable=FocusIdentity(pid:12345,appName:"fixture",element:element,window:element,role:"AXTextArea",readable:true,selectedTextWritable:true,value:"")
        var inserted=0;pipeline.insertText={_,_ in inserted+=1;return true}
        let lostCap=Capture(),lostConsumer=Recorder();coordinator.captureFactory={lostCap};coordinator.consumerFactory={_ in lostConsumer};pipeline.snapshotFocus={editable};copied=""
        time=19;coordinator.handle(down);lostCap.emit(0.7);drain();time=19.3;coordinator.poll();pipeline.snapshotFocus={nil};pipeline.tick()
        check("new focus loss keeps recording and marks retention",pipeline.session?.state == .voiceStarted && pipeline.session?.retentionReason != nil)
        // Even recovery to the same editor must not paste after the target was lost.
        pipeline.snapshotFocus={editable};time=20;coordinator.handle(.keyUp(binding:.primary));drain();lostConsumer.onFinal?("retained fixture");drain();drain()
        check("focus loss retains text without altering clipboard after recovery",copied.isEmpty && inserted==0 && !pipeline.coordinatedCopied && pipeline.lastTranscript == "retained fixture")
        for final in [nil,"", "   "] as [String?] {
            let emptyCap=Capture(),emptyConsumer=Recorder();coordinator.captureFactory={emptyCap};coordinator.consumerFactory={_ in emptyConsumer};copied=""
            time+=1;coordinator.handle(down);emptyCap.emit(0.7);drain();time+=0.3;coordinator.poll();emptyConsumer.onPartial?("fixture partial must not insert");drain();drain()
            time+=1;coordinator.handle(.keyUp(binding:.primary));drain();emptyConsumer.onFinal?(final);drain();drain()
            check("empty final never inserts or copies partial text",inserted==0 && copied.isEmpty && pipeline.lastTranscript==nil && !pipeline.hasActiveSession)
        }
        var router=CoordinatedShortcutRouter(primary:HotkeySpec(keyCode:58,modifiers:UInt32(optionKey)),secondary:HotkeySpec(keyCode:49,modifiers:UInt32(cmdKey)))
        check("router modifier down normalized",router.event(type:.flagsChanged,code:58,mods:UInt32(optionKey),down:[58],repeatKey:false).count==1)
        check("router repeated modifier ignored",router.event(type:.flagsChanged,code:58,mods:UInt32(optionKey),down:[58],repeatKey:true).isEmpty)
        check("router modifier chord cancels",router.event(type:.keyDown,code:0,mods:UInt32(optionKey),down:[58,0],repeatKey:false)==[.otherKeyDown])
        _=router.event(type:.flagsChanged,code:58,mods:0,down:[],repeatKey:false)
        check("router independent toggle still emits binding",router.event(type:.keyDown,code:49,mods:UInt32(cmdKey),down:[55,49],repeatKey:false)==[.keyDown(binding:.independentToggle,isRepeat:false,standaloneModifier:false)])
        var overflowConsumer=0;let overflowCap=Capture()
        let bounded=TriggeredRecorder(capture:overflowCap,limit:100,uid:"",allowed:{true},makeConsumer:{_ in overflowConsumer+=1;return Recorder()})
        var overflowed=false;bounded.onOverflow={overflowed=true;bounded.abort()};_=bounded.begin();overflowCap.emit(0.1);drain()
        check("buffer overflow discards before consumer exists",overflowed && bounded.bufferedBytes==0 && overflowConsumer==0)
        var energy=SpeechEnergyDetector()
        check("energy short impulse does not become speech",!energy.observe(level:0.1,duration:0.04))
        check("energy continuous onset becomes speech",energy.observe(level:0.1,duration:0.08))
        check("energy release resets speech",!energy.observe(level:0,duration:0.20))
        var noisy=SpeechEnergyDetector(noiseFloor:0.05)
        check("relative detector noise baseline does not trigger",!noisy.observe(level:0.08,duration:1))
        check("relative detector scaled voice triggers",noisy.observe(level:0.2,duration:0.12))
        check("hysteresis retains voice between thresholds",noisy.observe(level:0.12,duration:0.3))
        check("hysteresis releases below lower ratio",!noisy.observe(level:0.06,duration:0.2))
        check("invalid energy cannot change speech state",!noisy.observe(level:.nan,duration:1))
        check("default configuration remains legacy",!BridgeConfig.default().triggerCoordinatorEnabled)
    }
}
