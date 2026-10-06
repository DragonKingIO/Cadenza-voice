import AppKit

enum WechatDiagnosticFixtures {
    final class Adapter:EnhancedAXAdapter {
        var original=false,current=false,sets:[Bool]=[],inspections=0,unverified=false
        init(original:Bool=false){self.original=original;current=original}
        func validate(requireFront:Bool)throws->EnhancedTargetState{.same}
        func read()throws->EnhancedBoolRead{EnhancedBoolRead(rc:unverified && sets.last == false ? -1:0,value:current)}
        func capability()throws->EnhancedCapability{EnhancedCapability(rc:0,writable:true)}
        func set(_ value:Bool)throws->Int32{sets.append(value);current=value;return 0}
        func inspect(deadline:Double)throws{inspections += 1}
    }
    static func run(_ check:(String,Bool)->Void){
        NSApplication.shared.setActivationPolicy(.prohibited)
        var validation=EnhancedTargetState.same,makeCount=0,pause:[Bool]=[],pending:((EnhancedProbeReport)->Void)?,cancel:EnhancedDiagnosticCancellation?
        let adapter=Adapter()
        let flow=WechatDiagnosticFlow(available:true,validate:{validation},make:{_ in makeCount += 1;return adapter},pause:{pause.append($0)},runner:{_,c,done in cancel=c;pending=done})
        flow.continueByUser()
        check("Wechat native flow no continuation before prepare",makeCount==0 && pause.isEmpty)
        check("Wechat native flow missing field refused",!flow.prepare(field:0,agreed:true,busy:false) && makeCount==0 && pause.isEmpty)
        check("Wechat native flow missing explicit agreement refused",!flow.prepare(field:1,agreed:false,busy:false) && pause.isEmpty)
        check("Wechat native flow busy refuses without suspending",!flow.prepare(field:1,agreed:true,busy:true) && pause.isEmpty)
        let window=WechatDiagnosticWindow(flow:flow,busy:{false},register:{_ in true},unregister:{})
        let root=window.window?.contentView
        let field=ASREntryFixtures.view(root,"wechat.diagnostic.field") as! NSPopUpButton
        let agree=ASREntryFixtures.view(root,"wechat.diagnostic.agreement") as! NSButton
        let prepare=ASREntryFixtures.view(root,"wechat.diagnostic.prepare") as! NSButton
        let close=ASREntryFixtures.view(root,"wechat.diagnostic.cancel") as! NSButton
        _=ASREntryFixtures.action(prepare)
        check("Wechat native production prepare button rejects missing native confirmation",flow.state == .idle && makeCount==0)
        field.selectItem(at:1);agree.state = .on;_=ASREntryFixtures.action(prepare)
        check("Wechat native production button arms only and collects field category",flow.state == .waiting && flow.fieldCategory==1 && pause==[true] && makeCount==0 && adapter.sets.isEmpty)
        check("Wechat native waiting explains return original window and explicit action",flow.message.contains("同一微信窗口") && flow.message.contains("⌃⌥⌘D") && flow.message.contains("不会倒计时"))
        _=ASREntryFixtures.action(close)
        check("Wechat native waiting cancel restores listener with no property write",flow.state == .finished && pause==[true,false] && adapter.sets.isEmpty)
        _=ASREntryFixtures.action(prepare);window.continueByUser()
        check("Wechat native explicit continuation invokes existing transaction runner once",flow.state == .running && makeCount==1 && pending != nil)
        window.continueByUser()
        check("Wechat native duplicate continuation cannot execute twice",makeCount==1)
        check("Wechat native closing running window requests cancel and defers close",window.windowShouldClose(window.window!)==false && cancel?.requested==true && flow.state == .running)
        check("Wechat native quit while running waits for restoration",flow.requestTermination() == .wait && cancel?.requested==true)
        pending?(EnhancedProbeReport(reason:"cancelled"));pending=nil
        check("Wechat native controlled cancellation completion resumes only after verified restoration",flow.state == .finished && pause.last==false && flow.message.contains("旧文字继续保留"))
        check("Wechat native quit after safe completion allowed",flow.requestTermination() == .allow)
        for state in [EnhancedTargetState.changed,.exited,.invalid,.secure] {
            validation=state;_=flow.prepare(field:2,agreed:true,busy:false);let count=makeCount;window.continueByUser()
            check("Wechat native target preflight \(state.rawValue) refuses adapter writes",makeCount==count && adapter.sets.isEmpty && flow.state == .finished && pause.last==false)
        }
        validation = .same;_=flow.prepare(field:3,agreed:true,busy:false);window.continueByUser()
        pending?(EnhancedProbeReport(reason:"restorationUnverified",restorationVerified:false));pending=nil
        check("Wechat native restoration unknown leaves input paused and blocks retry",flow.state == .stopped && pause.last==true && !flow.prepare(field:1,agreed:true,busy:false) && flow.message.contains("停止重试"))
        check("Wechat native restoration unknown rejects application quit",flow.requestTermination() == .refuse)
        window.close()
        var noTargetPause=0
        let noTarget=WechatDiagnosticFlow(available:false,validate:{.same},make:{_ in adapter},pause:{_ in noTargetPause += 1})
        check("Wechat native no original window never arms",!noTarget.prepare(field:1,agreed:true,busy:false) && noTargetPause==0)
        let rejected=WechatDiagnosticFlow(available:true,validate:{.same},make:{_ in nil},pause:{pause.append($0)})
        _=rejected.prepare(field:1,agreed:true,busy:false);rejected.continueByUser()
        check("Wechat native adapter factory rejection resumes without running transaction",rejected.state == .finished && pause.last==false && rejected.message.contains("原进程、窗口或权限"))
        let fakeChatGPT=FocusIdentity(pid:ProcessInfo.processInfo.processIdentifier,appName:"com.openai.chat",element:nil,window:nil,role:nil,readable:false,selectedTextWritable:false,value:nil)
        check("Wechat native ChatGPT never captures WeChat property target",WechatDiagnosticTarget.capture(fakeChatGPT)==nil)
        let registrationFailFlow=WechatDiagnosticFlow(available:true,validate:{.same},make:{_ in adapter},pause:{pause.append($0)})
        let registrationFail=WechatDiagnosticWindow(flow:registrationFailFlow,busy:{false},register:{_ in false},unregister:{})
        (ASREntryFixtures.view(registrationFail.window?.contentView,"wechat.diagnostic.field") as! NSPopUpButton).selectItem(at:1)
        (ASREntryFixtures.view(registrationFail.window?.contentView,"wechat.diagnostic.agreement") as! NSButton).state = .on
        _=ASREntryFixtures.action(ASREntryFixtures.view(registrationFail.window?.contentView,"wechat.diagnostic.prepare") as! NSButton)
        check("Wechat native continuation key registration failure cancels without writing",registrationFailFlow.state == .finished && pause.last==false && adapter.sets.isEmpty)
        registrationFail.close()
        for original in [false,true] {
            let bound=Adapter(original:original)
            let transaction=WechatDiagnosticFlow(available:true,validate:{.same},make:{_ in bound},pause:{pause.append($0)},runner:{a,c,done in done(EnhancedAXTransaction.run(a,stopRequested:{c.requested},log:{_ in}))})
            _=transaction.prepare(field:1,agreed:true,busy:false);transaction.continueByUser()
            check("Wechat native flow existing transaction restores original \(original)",transaction.state == .finished && bound.current==original && bound.inspections==1 && bound.sets==(original ? []:[true,false]) && transaction.message.contains("上屏尚未验证"))
        }
    }
}
