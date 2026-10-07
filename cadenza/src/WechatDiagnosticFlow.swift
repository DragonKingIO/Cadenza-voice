import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin

// Captured at recording start. No text, editor or late insertion target is retained.
final class WechatDiagnosticTarget {
    let pid:pid_t,birth:(UInt64,UInt64),window:AXUIElement
    static func stamp(_ pid:pid_t)->(UInt64,UInt64)? {var info=proc_bsdinfo();guard pid>0,proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,Int32(MemoryLayout<proc_bsdinfo>.size))==Int32(MemoryLayout<proc_bsdinfo>.size) else{return nil};return(info.pbi_start_tvsec,info.pbi_start_tvusec)}
    static func pathMatches(_ pid:pid_t)->Bool {var path=[CChar](repeating:0,count:4096);guard pid>0,proc_pidpath(pid,&path,UInt32(path.count))>0 else{return false};return URL(fileURLWithPath:String(cString:path)).resolvingSymlinksInPath()==URL(fileURLWithPath:"/Applications/微信.app/Contents/MacOS/WeChat").resolvingSymlinksInPath()}
    private init(pid:pid_t,birth:(UInt64,UInt64),window:AXUIElement){self.pid=pid;self.birth=birth;self.window=window}
    static func capture(_ focus:FocusIdentity?)->WechatDiagnosticTarget? {
        guard let f=focus,f.appName=="com.tencent.xinWeChat",f.axTrusted,!f.protectedInput,let w=f.window,pathMatches(f.pid),let birth=stamp(f.pid) else{return nil}
        let target=Self(pid:f.pid,birth:birth,window:w);return target.validate() == .same ? target:nil
    }
    func validate()->EnhancedTargetState {
        guard let current=Self.stamp(pid) else{return .exited}
        guard current.0==birth.0,current.1==birth.1,Self.pathMatches(pid),TCC.axTrusted() else{return .invalid}
        guard !IsSecureEventInputEnabled() else{return .secure}
        guard ForegroundIdentity.capture()?.pid==pid else{return .changed}
        let app=AXUIElementCreateApplication(pid);guard AXUIElementSetMessagingTimeout(app,0.05) == .success else{return .invalid}
        var value:CFTypeRef?;guard AXUIElementCopyAttributeValue(app,kAXFocusedWindowAttribute as CFString,&value) == .success,let value=value,CFGetTypeID(value)==AXUIElementGetTypeID(),CFEqual(value,window) else{return .changed}
        var owner:pid_t=0;guard AXUIElementGetPid(window,&owner) == .success,owner==pid else{return .invalid}
        return ForegroundIdentity.capture()?.pid==pid ? .same:.changed
    }
}

// All UI transitions occur on main; only the existing bounded transaction runs off-main.
final class WechatDiagnosticFlow {
    enum State {case idle,waiting,running,finished,stopped}
    private(set) var fieldCategory=0
    private(set) var state=State.idle,message="请选择原字段类别，阅读说明后准备返回微信。"
    var changed:(()->Void)?
    let available:Bool
    private let validate:()->EnhancedTargetState,make:(EnhancedDiagnosticCancellation)->EnhancedAXAdapter?,pause:(Bool)->Void
    private let runner:(EnhancedAXAdapter,EnhancedDiagnosticCancellation,@escaping(EnhancedProbeReport)->Void)->Void
    private var cancellation=EnhancedDiagnosticCancellation()
    init(available:Bool,validate:@escaping()->EnhancedTargetState,make:@escaping(EnhancedDiagnosticCancellation)->EnhancedAXAdapter?,pause:@escaping(Bool)->Void,runner:@escaping(EnhancedAXAdapter,EnhancedDiagnosticCancellation,@escaping(EnhancedProbeReport)->Void)->Void={adapter,cancel,done in DispatchQueue.global(qos:.userInitiated).async{let report=EnhancedAXTransaction.run(adapter,stopRequested:{cancel.requested});DispatchQueue.main.async{done(report)}}}){self.available=available;self.validate=validate;self.make=make;self.pause=pause;self.runner=runner;if !available{self.message="缺少录音前的微信原窗口身份，不能开启诊断。请回到原输入框后重新主动录音记录原窗口，再查看原因；旧文字不会补写。"}}
    @discardableResult func prepare(field:Int,agreed:Bool,busy:Bool)->Bool {
        guard state == .idle || state == .finished else{return false}
        guard available else{message="缺少录音前的微信原窗口身份，不能开启诊断；现有文字继续保留。";changed?();return false}
        guard !busy else{message="请先结束录音或识别，再准备诊断。";changed?();return false}
        guard (1...3).contains(field),agreed else{message="请选择实际字段类别，并明确同意本次有限诊断。";changed?();return false}
        fieldCategory=field;cancellation=EnhancedDiagnosticCancellation();state = .waiting;pause(true)
        Log.write("wechat-native-flow armed field-category=\(field) requires-user-return-action=true no-automatic-start=true")
        message="请返回失败时的同一微信窗口，点选刚才的字段，确认输入光标已出现。然后按 ⌃⌥⌘D，明确确认现场条件并开始一次诊断。不会倒计时启动。等待期间语音监听已暂停。";changed?();return true
    }
    func continueByUser(){
        guard state == .waiting else{return}
        guard validate() == .same else{finish(EnhancedProbeReport(reason:"originalTargetMismatch"));return}
        guard let adapter=make(cancellation) else{finish(EnhancedProbeReport(reason:"nativePreflightRejected"));return}
        state = .running;message="正在有限诊断；不录音、不读取聊天/转写，不写文字或剪贴板。结束前将恢复并核对原属性。";changed?()
        runner(adapter,cancellation){[weak self] report in self?.finish(report)}
    }
    enum Termination {case allow,wait,refuse}
    func requestTermination()->Termination {if state == .stopped{return .refuse};cancel();return state == .running ? .wait:.allow}
    func cancel(){if state == .waiting {finish(EnhancedProbeReport(reason:"cancelled"))}else if state == .running{cancellation.request();message="已请求取消，正在等待原属性恢复复核。";changed?()}}
    private func finish(_ report:EnhancedProbeReport){
        guard state == .waiting || state == .running else{return}
        if report.restorationVerified {
            state = .finished;pause(false)
            if report.reason=="complete" {message="有限诊断已完成，原属性已恢复并复核。语音监听已恢复；返回原输入框后重新主动录音测试。旧文字继续保留，不会补写，上屏尚未验证。"}
            else if report.reason=="cancelled" {message="诊断已取消；原属性未改动或已恢复复核。监听已恢复，旧文字继续保留。"}
            else {
                let reasons=["originalTargetMismatch":"未回到原微信窗口，或目标/安全状态已变化","nativePreflightRejected":"原进程、窗口或权限条件未通过","targetChanged":"原窗口或前台已变化","targetExited":"原微信进程已退出","invalidTarget":"原进程或窗口身份不可验证","secureInput":"当前处于安全输入","invalidBoolean":"兼容属性原值不可验证","notWritable":"兼容属性不可写","enableRejected":"兼容属性启用被拒绝","enableUnverified":"无法确认兼容属性已启用","deadline":"有限诊断超过时限","adapterException":"系统接口异常"]
                message="诊断未完成："+(reasons[report.reason] ?? "检查条件未通过")+"。原属性未改动或已恢复复核。请返回原窗口检查条件后重新准备，旧文字不会补写。"
            }
        }else{state = .stopped;message="无法确认原属性恢复，录音和监听保持暂停。停止重试，请保留诊断状态交由检查；不能宣称已恢复。"}
        changed?()
    }
}

final class WechatContinueHotkey {
    private var ref:EventHotKeyRef?,handler:EventHandlerRef?
    var callback:(()->Void)?
    func register()->Bool {
        remove();var type=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        let rc=InstallEventHandler(GetApplicationEventTarget(),{next,event,data in
            guard let event=event,let data=data else{return OSStatus(eventNotHandledErr)}
            var id=EventHotKeyID();guard GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&id)==noErr,id.signature==0x59574447,id.id==7 else{return CallNextEventHandler(next,event)}
            let hotkey=Unmanaged<WechatContinueHotkey>.fromOpaque(data).takeUnretainedValue();DispatchQueue.main.async{hotkey.callback?()};return noErr
        },1,&type,Unmanaged.passUnretained(self).toOpaque(),&handler)
        guard rc==noErr else{remove();return false}
        let registered=RegisterEventHotKey(UInt32(kVK_ANSI_D),UInt32(controlKey|optionKey|cmdKey),EventHotKeyID(signature:0x59574447,id:7),GetApplicationEventTarget(),0,&ref)==noErr
        if !registered{remove()};return registered
    }
    func remove(){if let ref=ref{UnregisterEventHotKey(ref)};ref=nil;if let handler=handler{RemoveEventHandler(handler)};handler=nil}
    deinit{remove()}
}
