import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox

/// 自检（--selftest）：不要求说话、不依赖真实语音。
/// 仅查询真实 TIS 输入源并检查保持；录音/事件/焦点变化使用构造数据。
enum SelfTest {
    private static var failures = 0
    private static var checks = 0

    private static func check(_ name: String, _ cond: Bool) {
        checks += 1
        print("[selftest] \(cond ? "PASS" : "FAIL"): \(name)")
        if !cond { failures += 1 }
    }

    private static func skip(_ name: String) {
        print("[selftest] SKIP: \(name)")
    }

    static func run() -> Int32 {
        print("[selftest] start")
        ASRFixtures.run(check)
        DeepgramFixtures.run(check)
        ASRSettingsFixtures.run(check)
        ASREntryFixtures.run(check)
        LocalModelFixtures.run(check)
        ScreenshotFixtures.run(check)
        LocalAPIFixtures.run(check)
        LocalAPIAudioFixtures.run(check)
        CharacterFixtures.run(check)
        PrivacyFixtures.run(check)
        LegacyMigrationFixtures.run(check)
        testConfigValidation()
        testCustomShortcuts()
        testOnboardingReadiness()
        testEnhancedTransaction()
        WechatDiagnosticFixtures.run(check)
        testForegroundCandidates()
        testFocusClassify()
        testRecordingAccessibilityLease()
        check("后台关键窗口不把实体快捷键路由到试说", !TrialFocusOwnership.matches(appActive:false,frontPID:2,ownPID:1,windowKey:true,windowVisible:true))
        check("前台PID不同即使active也不路由试说", !TrialFocusOwnership.matches(appActive:true,frontPID:2,ownPID:1,windowKey:true,windowVisible:true))
        check("前台自己的试说窗口仍使用本地试说", TrialFocusOwnership.matches(appActive:true,frontPID:1,ownPID:1,windowKey:true,windowVisible:true))
        check("前台身份未知不路由试说", !TrialFocusOwnership.matches(appActive:true,frontPID:nil,ownPID:1,windowKey:true,windowVisible:true))
        check("写入验证按UTF16选区替换", TextInserter.expectedValue(before:"A😀B",selection:CFRange(location:1,length:2),inserted:"你好") == "A你好B")
        check("接口成功但读回没变不报告已输入", !TextInserter.verify(expected:"abc你好",write:{0},read:{"abc"}))
        check("读回匹配才报告已输入", TextInserter.verify(expected:"abc你好",write:{0},read:{"abc你好"}))
        check("读取失败不报告已输入", !TextInserter.verify(expected:"abc你好",write:{0},read:{nil}))
        check("写入失败即使文字相同也不报告成功", !TextInserter.verify(expected:"abc你好",write:{-25204},read:{"abc你好"}))
        check("无效选区拒绝写入", TextInserter.expectedValue(before:"abc",selection:CFRange(location:4,length:0),inserted:"x") == nil)
        testHotkeyRegister()
        testSessionFlow()
        testRapidSessions()
        testSilenceAndOwnTargets()
        testRemainingLifecycle()
        testIllustrationSignal()
        testAppearanceConfiguration()
        testDualShortcuts()
        print("[selftest] done checks=\(checks) failures=\(failures)")
        return failures == 0 ? 0 : 1
    }

    static func testRecordingAccessibilityLease() {
        final class Adapter:EnhancedAXAdapter {
            var value=false,writable=true,ignoreEnable=false,throwEnable=false
            var sets:[Bool]=[]
            func validate(requireFront:Bool)throws->EnhancedTargetState {.same}
            func read()throws->EnhancedBoolRead {EnhancedBoolRead(rc:0,value:value)}
            func capability()throws->EnhancedCapability {EnhancedCapability(rc:0,writable:writable)}
            func set(_ new:Bool)throws->Int32 {
                sets.append(new);if !ignoreEnable || !new {value=new}
                if new && throwEnable {throw EnhancedProbeFailure.adapterException}
                return 0
            }
            func inspect(deadline:Double)throws{}
        }
        let a=Adapter(),lease=RecordingAccessibilityLease.begin(a)
        check("微信兼容仅临时开启原false",lease != nil && a.value && a.sets == [true])
        check("会话结束恢复辅助功能原值",lease?.restore() == true && !a.value && a.sets == [true,false])
        _=lease?.restore();check("重复清理不重复修改原应用",a.sets == [true,false])
        let original=Adapter();original.value=true
        let existing=RecordingAccessibilityLease.begin(original);_=existing?.restore()
        check("辅助功能原true始终保留",existing != nil && original.value && original.sets.isEmpty)
        let denied=Adapter();denied.writable=false
        check("不可写辅助功能不修改",RecordingAccessibilityLease.begin(denied) == nil && denied.sets.isEmpty)
        let partial=Adapter();partial.throwEnable=true
        check("辅助功能部分失败仍恢复",RecordingAccessibilityLease.begin(partial) == nil && !partial.value && partial.sets == [true,false])
        let ignored=Adapter();ignored.ignoreEnable=true
        check("未能读回开启即恢复并拒绝",RecordingAccessibilityLease.begin(ignored) == nil && !ignored.value && ignored.sets == [true,false])
    }

    static func testEnhancedTransaction() {
        final class Adapter:EnhancedAXAdapter {
            var flag=false,state=EnhancedTargetState.same,typed=true,writable=true,readRC:Int32=0
            var sets:[Bool]=[],inspectCalls=0,failInspect=false,failEnable=false,ignoreEnable=false
            var throwEnable=false,failRestore=false,throwRestore=false,badRestoreRead=false,throwRestoreRead=false,inspectState:EnhancedTargetState?,inspectAdvance:(()->Void)?
            var readCount=0,validateCount=0,changeAtValidate:Int?
            func validate(requireFront:Bool)throws->EnhancedTargetState {
                validateCount+=1
                if requireFront,changeAtValidate==validateCount {state = .changed}
                if !requireFront,state == .changed || state == .secure {return .same}
                return state
            }
            func read()throws->EnhancedBoolRead {
                readCount+=1
                if throwRestoreRead,sets.last == false {throw EnhancedProbeFailure.adapterException}
                if badRestoreRead,sets.last == false {return EnhancedBoolRead(rc:0,value:nil)}
                return EnhancedBoolRead(rc:readRC,value:typed ? flag:nil)
            }
            func capability()throws->EnhancedCapability {EnhancedCapability(rc:0,writable:writable)}
            func set(_ value:Bool)throws->Int32 {
                sets.append(value)
                if !value && failRestore {return -25204}
                if value && ignoreEnable {return 0}
                flag=value
                if !value && throwRestore {throw EnhancedProbeFailure.adapterException}
                if value && throwEnable {throw EnhancedProbeFailure.adapterException}
                return value && failEnable ? -25204:0
            }
            func inspect(deadline:Double)throws {
                inspectCalls+=1;inspectAdvance?();if let state=inspectState {self.state=state}
                if failInspect {throw EnhancedProbeFailure.adapterException}
            }
        }
        func run(_ a:Adapter,_ now:@escaping()->Double={0})->EnhancedProbeReport {EnhancedAXTransaction.run(a,now:now,log:{_ in})}
        let normal=Adapter();let nr=run(normal)
        check("临时开启后恢复原false并复核",nr.reason=="complete" && nr.restorationVerified && !normal.flag && normal.sets==[true,false])
        let originalTrue=Adapter();originalTrue.flag=true;let tr=run(originalTrue)
        check("原true仅检查而不反向关闭",tr.restorationVerified && originalTrue.flag && originalTrue.sets.isEmpty)
        let exception=Adapter();exception.failInspect=true;let er=run(exception)
        check("元数据异常仍恢复原值",er.reason=="adapterException" && er.restorationVerified && exception.sets==[true,false] && !exception.flag)
        let partial=Adapter();partial.throwEnable=true;let pr=run(partial)
        check("setter先改变再抛错仍恢复",pr.restorationVerified && partial.sets==[true,false] && !partial.flag)
        let failure=Adapter();failure.failEnable=true;let fr=run(failure)
        check("开启返回失败仍尝试恢复且不检查控件",fr.reason=="enableRejected" && fr.restorationVerified && failure.inspectCalls==0 && !failure.flag)
        let ignored=Adapter();ignored.ignoreEnable=true;let ir=run(ignored)
        check("开启未读回true不继续检查",ir.reason=="enableUnverified" && ir.restorationVerified && ignored.inspectCalls==0)
        let changed=Adapter();changed.inspectState = .changed;let cr=run(changed)
        check("前台切换停止诊断并恢复原进程",cr.reason=="targetChanged" && cr.restorationVerified && !changed.flag)
        let before=Adapter();before.changeAtValidate=3;let br=run(before)
        check("开启前目标变化不写属性",br.reason=="targetChanged" && before.sets.isEmpty)
        let exited=Adapter();exited.inspectState = .exited;let xr=run(exited)
        check("原进程退出不对新PID恢复且报告未验证",xr.reason=="targetExited" && !xr.restorationVerified && exited.sets==[true])
        let invalid=Adapter();invalid.typed=false;let vr=run(invalid)
        check("非布尔原值拒绝且零写入",vr.reason=="invalidBoolean" && invalid.sets.isEmpty)
        let denied=Adapter();denied.writable=false;let dr=run(denied)
        check("属性不可写不强行设置",dr.reason=="notWritable" && denied.sets.isEmpty)
        let secure=Adapter();secure.state = .secure;let sr=run(secure)
        check("安全输入拒绝且不读写属性",sr.reason=="secureInput" && secure.readCount==0 && secure.sets.isEmpty)
        let restoreFail=Adapter();restoreFail.failRestore=true;let rr=run(restoreFail)
        check("恢复写入失败不宣称完成",!rr.restorationVerified && rr.reason=="restorationUnverified" && rr.restore.hasPrefix("set-rejected"))
        let restoreThrow=Adapter();restoreThrow.throwRestore=true;let restoreThrowResult=run(restoreThrow)
        check("恢复setter异常仍读回并保守停止",!restoreThrowResult.restorationVerified && restoreThrowResult.restore=="set-exception-readbackMatches-true" && !restoreThrow.flag)
        let restoreReadThrow=Adapter();restoreReadThrow.throwRestoreRead=true;let restoreReadThrowResult=run(restoreReadThrow)
        check("恢复读回异常明确停止",!restoreReadThrowResult.restorationVerified && restoreReadThrowResult.restore=="read-exception")
        let restoreRead=Adapter();restoreRead.badRestoreRead=true;let qr=run(restoreRead)
        check("恢复读回类型错停止并报告",!qr.restorationVerified && qr.restore=="readback-unverified")
        let cancel=EnhancedDiagnosticCancellation(),cancelled=Adapter();cancelled.inspectAdvance={cancel.request()}
        let cancelledResult=EnhancedAXTransaction.run(cancelled,now:{0},stopRequested:{cancel.requested},log:{_ in})
        check("可控退出取消检查仍完成原值恢复",cancelledResult.reason=="cancelled" && cancelledResult.restorationVerified && !cancelled.flag)
        let store=ConfigStore(),saved=store.config;defer{store.mutate{$0=saved}}
        store.mutate{$0.enabled=true;$0.mode="hold"}
        let pipeline=VoicePipeline(configStore:store,input:InputSourceController());pipeline.inputSuspendedForDiagnostic=true
        var focusCalls=0,recorderCalls=0
        pipeline.snapshotFocus={focusCalls+=1;return nil}
        pipeline.recorderFactory={recorderCalls+=1;return StubRecorder()}
        pipeline.holdStarted(source:.menu);pipeline.holdStarted(source:.button);pipeline.togglePressed()
        check("诊断暂停期间菜单按钮切换均不采焦点或录音",focusCalls==0 && recorderCalls==0 && pipeline.resourcesIdle)
        var clock=0.0;let timeout=Adapter();timeout.inspectAdvance={clock=3};let mr=run(timeout,{clock})
        check("达到总截止仍执行恢复",mr.reason=="deadline" && mr.restorationVerified && !timeout.flag)
    }

    static func testIllustrationSignal() {
        var meter=IllustrationSignal();meter.push(0.8,reduced:false)
        check("插画接收已有电平",meter.levels.last == CGFloat(Float(0.8)))
        meter.reset();check("停止清空波形历史和衰减",meter.smoothed == 0 && meter.levels.allSatisfy{$0 == 0})
        meter.push(0.6,reduced:true);meter.push(0,reduced:true)
        check("减少动态效果静音立即归零",meter.levels.allSatisfy{$0 == 0})
        meter.push(.nan,reduced:true);check("无效电平不进入矢量波形",meter.levels.allSatisfy{$0 == 0})
    }

    static func testForegroundCandidates() {
        check("AX聚焦应用无值时采用真正聚焦控件owner",ForegroundIdentity.candidate(applicationPID:nil,elementPID:42,workspacePID:-1)?.0 == 42)
        check("两个系统AX属性无值时正前台PID可进入路径复核",ForegroundIdentity.candidate(applicationPID:nil,elementPID:nil,workspacePID:42)?.0 == 42)
        check("所有PID缺失拒绝建立应用AX",ForegroundIdentity.candidate(applicationPID:nil,elementPID:nil,workspacePID:-1) == nil)
        check("聚焦应用与前台PID不一致拒绝",ForegroundIdentity.candidate(applicationPID:42,elementPID:nil,workspacePID:43) == nil)
        check("聚焦控件与前台PID不一致拒绝且不回退",ForegroundIdentity.candidate(applicationPID:nil,elementPID:42,workspacePID:43) == nil)
        check("无效聚焦控件PID不会用于应用AX",ForegroundIdentity.candidate(applicationPID:nil,elementPID:0,workspacePID:-1) == nil)
    }

    // MARK: 配置校验

    static func testConfigValidation() {
        check("默认配置通过校验", BridgeConfig.validate(BridgeConfig.default()).isEmpty)
        check("默认模式为 hold（按住说话）", BridgeConfig.default().mode == SessionMode.hold.rawValue)

        var c = BridgeConfig.default()
        c.trigger = c.iflytekVoiceHotkey
        check("触发键==讯飞热键被拒绝", !BridgeConfig.validate(c).isEmpty)

        c = BridgeConfig.default()
        c.trigger.keyCode = 63
        check("Fn 作触发键被拒绝", !BridgeConfig.validate(c).isEmpty)

        c = BridgeConfig.default()
        c.trigger.modifiers = 0
        c.trigger.keyCode = 18
        check("无修饰键的普通键被拒绝", !BridgeConfig.validate(c).isEmpty)

        c = BridgeConfig.default()
        c.mode = "turbo"
        check("未知 mode 被拒绝", !BridgeConfig.validate(c).isEmpty)

        c = BridgeConfig.default()
        c.iflytekSourceID = ""
        check("空输入源 ID 被拒绝", !BridgeConfig.validate(c).isEmpty)

        c = BridgeConfig.default()
        c.diagnosticTrigger = c.trigger
        check("历史诊断键不占用正式语音绑定", BridgeConfig.validate(c).isEmpty)

        c = BridgeConfig.default()
        c.trigger = HotkeySpec(keyCode: 179, modifiers: 0)
        check("未知扩展键码179拒绝，不能冒充专用键", !BridgeConfig.validate(c).isEmpty)

        check("左 Option 单键归类为修饰键单按", ListenTrigger.classify(HotkeySpec(keyCode: 58, modifiers: UInt32(optionKey))) == .loneModifierTap)
        check("右 Option 单键归类为修饰键单按", ListenTrigger.classify(HotkeySpec(keyCode: 61, modifiers: UInt32(optionKey))) == .loneModifierTap)
        check("⌥Space 归类为组合键", ListenTrigger.classify(HotkeySpec(keyCode: 49, modifiers: UInt32(optionKey))) == .keyDownCombo)
    }

    static func testCustomShortcuts() {
        let ctrl=UInt32(controlKey), shift=UInt32(shiftKey), cmd=UInt32(cmdKey), opt=UInt32(optionKey)
        let combo=HotkeySpec(keyCode:5,modifiers:ctrl|shift,modifierKeyCodes:[56,59])
        let dedicated=HotkeySpec(keyCode:106,modifiers:0)
        check("可用自定义组合通过静态与系统校验", ShortcutPolicy.reason(combo,assignments:[],menuAssignments:[]) == nil)
        check("专用F16通过校验", ShortcutPolicy.reason(dedicated,assignments:[],menuAssignments:[]) == nil)
        for code:UInt32 in [0,18,43,49,36,48,51,123,53,179,63] {
            check("常用输入导航及未知键拒绝 code=\(code)",ShortcutPolicy.reason(HotkeySpec(keyCode:code,modifiers:0),assignments:[],menuAssignments:[]) != nil)
        }
        for key:UInt32 in [0,6,7,8,9,1,13,12] {
            check("编辑与应用操作受保护 code=\(key)", ShortcutPolicy.reason(HotkeySpec(keyCode:key,modifiers:cmd|opt),assignments:[],menuAssignments:[]) != nil)
        }
        for spec in [HotkeySpec(keyCode:49,modifiers:cmd),HotkeySpec(keyCode:49,modifiers:ctrl),HotkeySpec(keyCode:48,modifiers:cmd),HotkeySpec(keyCode:53,modifiers:cmd|opt),HotkeySpec(keyCode:20,modifiers:cmd|shift),HotkeySpec(keyCode:12,modifiers:ctrl|cmd)] {
            check("Spotlight输入源切换应用截图锁屏强退受保护",ShortcutPolicy.reason(spec,assignments:[],menuAssignments:[]) != nil)
        }
        check("当前系统重分配拒绝候选",ShortcutPolicy.reason(combo,assignments:[HotkeySpec(keyCode:5,modifiers:ctrl|shift)]) != nil)
        check("系统分配不可读时拒绝保存自定义",ShortcutPolicy.reason(combo,assignments:nil) != nil)
        check("媒体模式F6拒绝",ShortcutPolicy.reason(HotkeySpec(keyCode:97,modifiers:0),assignments:[],standardFunctionKeys:false,menuAssignments:[]) != nil)
        check("标准模式且无系统分配F6可校验",ShortcutPolicy.reason(HotkeySpec(keyCode:97,modifiers:0),assignments:[],standardFunctionKeys:true,menuAssignments:[]) == nil)
        check("全局菜单快捷键解析", ShortcutPolicy.parseMenuEquivalent("^$g")?.keyCode == 5 && ShortcutPolicy.parseMenuEquivalent("^$g")?.modifiers == ctrl|shift)
        check("全局菜单重分配拒绝", ShortcutPolicy.reason(combo, assignments: [], menuAssignments: [HotkeySpec(keyCode:5,modifiers:ctrl|shift)]) != nil)
        check("无法解析系统菜单分配时保守拒绝", ShortcutPolicy.reason(combo,assignments:[],menuAssignments:nil) != nil)
        check("本机系统分配API可读取",ShortcutPolicy.systemAssignments() != nil)
        check("专用键短暂注册探测后释放", ShortcutPolicy.registrationReason(dedicated) == nil)
        let occupied = HotkeyCenter()
        if occupied.register(combo, slot: .trigger) {
            check("已有全局注册冲突在保存前拒绝", ShortcutPolicy.registrationReason(combo) != nil)
        } else { check("注册冲突测试建立占用", false) }
        occupied.unregister()
        var cycle=ShortcutCycle(spec:BridgeConfig.default().trigger)
        check("默认左Option按下开始",cycle.event(type:.flagsChanged,code:58,modifiers:opt,downKeys:[58]) == .start)
        check("右Option加入取消左Option录音",cycle.event(type:.flagsChanged,code:61,modifiers:opt,downKeys:[58,61]) == .cancel)
        check("取消后抬起不提交",cycle.event(type:.flagsChanged,code:58,modifiers:opt,downKeys:[61]) == .none)
        cycle=ShortcutCycle(spec:BridgeConfig.default().trigger)
        check("右Option不触发默认",cycle.event(type:.flagsChanged,code:61,modifiers:opt,downKeys:[61]) == .none)
        check("默认干净周期开始",cycle.event(type:.flagsChanged,code:58,modifiers:opt,downKeys:[58]) == .start)
        check("默认干净周期抬起结束",cycle.event(type:.flagsChanged,code:58,modifiers:0,downKeys:[]) == .end)
        cycle=ShortcutCycle(spec:combo)
        check("配置内修饰键不提前启动",cycle.event(type:.flagsChanged,code:56,modifiers:ctrl|shift,downKeys:[56,59]) == .none)
        check("组合完整按下开始",cycle.event(type:.keyDown,code:5,modifiers:ctrl|shift,downKeys:[5,56,59]) == .start)
        check("按住重复不重复开始",cycle.event(type:.keyDown,code:5,modifiers:ctrl|shift,downKeys:[5,56,59],repeatKey:true) == .none)
        check("先释放修饰键结束一次",cycle.event(type:.flagsChanged,code:56,modifiers:ctrl,downKeys:[5,59]) == .end)
        check("随后释放主键不重复提交",cycle.event(type:.keyUp,code:5,modifiers:ctrl,downKeys:[59]) == .none)
        check("相同组合右侧修饰键不触发左侧绑定",cycle.event(type:.keyDown,code:5,modifiers:ctrl|shift,downKeys:[5,60,62]) == .none)
        cycle=ShortcutCycle(spec:combo)
        _=cycle.event(type:.keyDown,code:5,modifiers:ctrl|shift,downKeys:[5,56,59])
        check("先释放主键正常结束",cycle.event(type:.keyUp,code:5,modifiers:ctrl|shift,downKeys:[56,59]) == .end)
        _=cycle.event(type:.keyDown,code:5,modifiers:ctrl|shift,downKeys:[5,56,59])
        check("额外普通键取消组合录音",cycle.event(type:.keyDown,code:0,modifiers:ctrl|shift,downKeys:[0,5,56,59]) == .cancel)
        cycle=ShortcutCycle(spec:combo);_=cycle.event(type:.keyDown,code:5,modifiers:ctrl|shift,downKeys:[5,56,59])
        check("额外修饰键取消",cycle.event(type:.flagsChanged,code:55,modifiers:ctrl|shift|cmd,downKeys:[5,56,59,55]) == .cancel)
        cycle=ShortcutCycle(spec:dedicated)
        check("专用键开始",cycle.event(type:.keyDown,code:106,modifiers:0,downKeys:[106]) == .start)
        check("缺失抬起物理核验发现",!cycle.physicallyHeld([]))
        check("缺失抬起只取消不提交",cycle.cancel() == .cancel)
        check("休眠重复取消幂等",cycle.cancel() == .none)
        _=cycle.poll([])
        check("缺失keyUp后轮询恢复下一周期",cycle.event(type:.keyDown,code:106,modifiers:0,downKeys:[106]) == .start)
        check("旧keyUp遇到新周期仍物理按住不会结束",cycle.event(type:.keyUp,code:106,modifiers:0,downKeys:[106]) == .none)
        check("取消后抬起的轮询不提交",cycle.poll([]) == .cancel)
        check("识别期间Esc仍发取消",cycle.event(type:.keyDown,code:53,modifiers:0,downKeys:[53]) == .cancel)
        let old=BridgeConfig.default().trigger
        var listener=old, durable=old
        let failure=ShortcutTransaction.commit(combo,old:old,activate:{ listener=$0;return $0==old },persist:{ durable=$0;return true })
        check("监听安装失败回滚且不写配置",!failure && listener==old && durable==old)
        let diskFailure=ShortcutTransaction.commit(combo,old:old,activate:{ listener=$0;return true },persist:{ _ in false })
        check("配置写入失败回滚监听",!diskFailure && listener==old && durable==old)
        check("保存成功监听配置同步",ShortcutTransaction.commit(combo,old:old,activate:{listener=$0;return true},persist:{durable=$0;return true}) && listener==combo && durable==combo)
        var config=BridgeConfig.default();config.trigger=combo
        let data=try? JSONEncoder().encode(config);let loaded=data.flatMap {try? JSONDecoder().decode(BridgeConfig.self,from:$0)}
        check("重启序列化保留键码及左右修饰键",loaded?.trigger==combo)
    }

    static func testOnboardingReadiness() {
        check("讯飞试说不要求Apple语音识别权限", EngineReadiness.ready(engine:"iflytek",mic:true,speech:false,local:false,cloud:false,credentials:true,consent:true))
        check("讯飞缺云同意不可进入假试说", !EngineReadiness.ready(engine:"iflytek",mic:true,speech:true,local:true,cloud:true,credentials:true,consent:false))
        check("窗口试说仍要求麦克风", !EngineReadiness.ready(engine:"iflytek",mic:false,speech:true,local:true,cloud:true,credentials:true,consent:true))
        check("Apple本机不可用且未同意联网应拒绝", !EngineReadiness.ready(engine:"apple",mic:true,speech:true,local:false,cloud:false,credentials:false,consent:false))
        check("Apple允许联网且必要权限满足可试说", EngineReadiness.ready(engine:"apple",mic:true,speech:true,local:false,cloud:true,credentials:false,consent:false))
        check("本地引擎仅在真实推理库和已安装模型就绪时可用", EngineReadiness.ready(engine:"local",mic:true,speech:true,local:true,cloud:true,credentials:true,consent:true) == (LocalTranscriberLoader.supported && LocalModelCenter.shared.installedEntries.contains{LocalModelCatalog.usable($0)}))
    }

    // MARK: 焦点分类（构造数据）

    static func testFocusClassify() {
        let a = FocusIdentity(pid: 100, appName: "A", element: AXUIElementCreateApplication(100), window: AXUIElementCreateApplication(100),
                              role: "AXTextArea", readable: true, selectedTextWritable: true, value: "hi")
        check("同 pid 同值 → unchanged", FocusProbe.classify(previous: a, current: a) == .unchanged)
        let b = FocusIdentity(pid: 200, appName: "B", element: nil, window: nil,
                              role: "AXTextArea", readable: true, selectedTextWritable: true, value: "hi")
        check("pid 变化 → appChanged", FocusProbe.classify(previous: a, current: b) == .appChanged)
        let c = FocusIdentity(pid: 100, appName: "A", element: a.element, window: a.window,
                              role: "AXTextArea", readable: true, selectedTextWritable: true, value: "hello")
        check("仅文本值变化 → valueChanged（证据之一）", FocusProbe.classify(previous: a, current: c) == .valueChanged)
        let otherEditor=FocusIdentity(pid:a.pid,appName:a.appName,element:AXUIElementCreateApplication(101),window:a.window,role:a.role,readable:false,selectedTextWritable:true,value:nil)
        let otherWindow=FocusIdentity(pid:a.pid,appName:a.appName,element:a.element,window:AXUIElementCreateApplication(102),role:a.role,readable:false,selectedTextWritable:true,value:nil)
        check("SelectedText可写仍识别原编辑器变化",FocusProbe.classify(previous:a,current:otherEditor) == .elementChanged)
        check("SelectedText可写仍识别原窗口变化",FocusProbe.classify(previous:a,current:otherWindow) == .windowChanged)
        check("current 缺失 → unknown", FocusProbe.classify(previous: a, current: nil) == .unknown)
        check("AXTextArea 视为适合输入", a.suitable)
        var selectedOnly=a;selectedOnly.valueWritable=false
        check("SelectedText可写Value只读允许插入",selectedOnly.identityAvailable && selectedOnly.automaticInputAvailable)
        var valueOnly=a;valueOnly.selectedTextWritable=false;valueOnly.valueWritable=true
        check("Value可写SelectedText只读禁止插入但身份保持",valueOnly.identityAvailable && !valueOnly.automaticInputAvailable && FocusProbe.classify(previous:a,current:valueOnly) == .unchanged)
        var neither=valueOnly;neither.valueWritable=false
        check("两种接口均不可写保留身份但不能插入",neither.identityAvailable && !neither.automaticInputAvailable)
        var secured=selectedOnly;secured.protectedInput=true
        check("安全输入即使SelectedText可写仍拒绝",!secured.identityAvailable && !secured.automaticInputAvailable)
        var changed=selectedOnly;changed.identityValid=false
        check("目标身份失效即使SelectedText可写仍拒绝",!changed.automaticInputAvailable && FocusProbe.classify(previous:a,current:changed) == .unknown)
        let d = FocusIdentity(pid: 1, appName: "D", element: nil, window: nil,
                              role: "AXButton", readable: false, selectedTextWritable: false, value: nil)
        check("AXButton 且值不可写 → 不适合输入", !d.suitable)
    }

    // MARK: Carbon 热键注册

    static func testHotkeyRegister() {
        let hk = HotkeyCenter()
        let ok = hk.register(HotkeySpec(keyCode: 49, modifiers: UInt32(optionKey)), slot: .trigger)
        check("Carbon 热键注册成功", ok && hk.status == L10n.tr("ui.eab7185db6aa"))
        hk.unregister()
        check("注销后状态为未注册", hk.status == L10n.tr("ui.7b89c50978de"))
        let diag = hk.register(HotkeySpec(keyCode: 97, modifiers: 0), slot: .diagnostic)
        check("诊断键 F6 注册成功", diag && hk.statusBySlot[.diagnostic] == L10n.tr("ui.eab7185db6aa"))
        hk.unregister()
    }

    // MARK: 会话状态机（hold 模式，无硬件依赖，不做真实录音/切换）

    static func testSessionFlow() {
        let store = ConfigStore()
        let saved = store.config
        defer { store.mutate { $0 = saved } }
        guard store.mutate({ c in
            c.mode = SessionMode.hold.rawValue
            c.engine = "apple"
            c.enabled = false
        }) else {
            check("hold 会话流程切换配置", false)
            return
        }
        let input = InputSourceController()
        let pipeline = VoicePipeline(configStore: store, input: input)
        pipeline.selfTestMode = true
        let before = input.currentID()

        // 场景 1：停用状态下按住 → 不创建会话、不动输入源
        pipeline.holdStarted(source: .button)
        check("停用状态不创建会话", pipeline.session == nil)
        check("停用状态不动输入源", input.currentID() == before)

        // 场景 2：无会话时松开/取消/触发/强制结束 → 全部安全无副作用
        store.mutate { c in c.enabled = true }
        pipeline.holdEnded()
        pipeline.holdChord(reason: "selftest")
        pipeline.triggerFired()
        pipeline.forceEnd(reason: "selftest")
        check("无会话时各回调安全", pipeline.session == nil && input.currentID() == before)

        // 场景 3：无效配置拒绝启动
        store.mutate { c in c.recordingTimeoutSec = 0 }
        pipeline.holdStarted(source: .button)
        check("无效配置拒绝创建会话", pipeline.session == nil)
        store.mutate { c in c.recordingTimeoutSec = 55 }
    }

    private final class StubRecorder: HoldRecordingSession {
        var onLevel: ((Float) -> Void)?
        var onPartial: ((String) -> Void)?
        var onFinal: ((String?) -> Void)?
        var lastError: String?
        var capturedAudioHasSignal:Bool?
        var aborts = 0
        var ends = 0
        var beginSucceeds=true
        func begin() -> Bool { beginSucceeds }
        func end() { ends += 1 }
        func abort() { aborts += 1 }
    }

    private static func pump() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    static func testRapidSessions() {
        let store = ConfigStore()
        let saved = store.config
        defer { store.mutate { $0 = saved } }
        store.mutate { $0.enabled = true; $0.mode = "hold"; $0.engine = "apple" }
        let pipeline = VoicePipeline(configStore: store, input: InputSourceController())
        pipeline.snapshotFocus = { nil }
        var recorders: [StubRecorder] = []
        var inserted: [String] = []
        var copied:[String]=[]
        pipeline.copyToClipboard={copied.append($0)}
        pipeline.recorderFactory = {
            let recorder = StubRecorder()
            recorders.append(recorder)
            return recorder
        }
        pipeline.insertText = { text,_ in inserted.append(text);return true }
        var clock = Date()
        pipeline.now = { clock }

        pipeline.holdStarted(source: .button)
        let oldPartial = recorders[0].onPartial
        let oldFinal = recorders[0].onFinal
        recorders[0].onPartial?("上一轮文字")
        pump()
        pipeline.holdEnded()
        recorders[0].onFinal?("上一轮文字")
        pump()
        check("窗口试说有字只在软件展示并清理引擎", inserted.isEmpty && pipeline.lastTranscript == "上一轮文字" && pipeline.session == nil && recorders[0].aborts > 0)

        pipeline.holdStarted(source: .button)
        oldPartial?("迟到旧文字")
        oldFinal?("迟到旧结果")
        pump()
        pipeline.holdEnded()
        recorders[1].onFinal?(nil)
        pump()
        check("下一轮空结果不复用旧文字且忽略旧回调", inserted.isEmpty && pipeline.lastTranscript == nil && pipeline.session == nil)

        pipeline.holdStarted(source: .button)
        pipeline.holdEnded()
        clock = clock.addingTimeInterval(13)
        pipeline.tick()
        check("握手或结果不返回时识别等待超时并清理", pipeline.session == nil && recorders[2].aborts > 0 && inserted.isEmpty)

        pipeline.holdStarted(source: .button)
        let waitingRecorder = recorders.last!
        let lateFinal = waitingRecorder.onFinal
        let waitingID = pipeline.session?.id
        pipeline.holdEnded()
        pipeline.holdStarted(source: .button)
        check("识别等待中再次按住立即建立新会话", pipeline.session?.id != waitingID && pipeline.session?.state == .voiceStarted && waitingRecorder.aborts > 0)
        lateFinal?("旧识别结果")
        pump()
        check("被替换会话结果不写入也不结束新录音", inserted.isEmpty && pipeline.session?.state == .voiceStarted)
        pipeline.forceEnd(reason: "selftest")

        for _ in 0..<30 {
            pipeline.holdStarted(source: .button)
            pipeline.holdStarted(source: .button)
            let recorder = recorders.last!
            pipeline.holdEnded()
            pipeline.holdEnded()
            pipeline.forceEnd(reason: "selftest rapid cancel")
            check("快按会话只结束一次且取消后回到空闲", recorder.ends == 1 && recorder.aborts > 0 && pipeline.session == nil)
        }
        check("连续空录音未插入任何额外文字", inserted.isEmpty)
        let element = AXUIElementCreateApplication(12345)
        let focus = FocusIdentity(pid: 12345, appName: "Test", element: element, window: element,
                                  role: "AXTextArea", readable: true, selectedTextWritable: true, value: "")
        var emitted=0
        check("直接输入不依赖剪贴板", TextInserter.sendUnicode("测试",target:focus,current:{focus},emit:{_,pid in emitted+=1;return pid == focus.pid}) && emitted == 1 && copied.isEmpty)
        emitted=0
        check("直接输入目标变化停止发送", !TextInserter.sendUnicode("测试",target:focus,current:{nil},emit:{_,_ in emitted+=1;return true}) && emitted == 0)
        emitted=0;var snapshots=0
        check("分块输入中途失焦停止后续块", !TextInserter.sendUnicode(String(repeating:"字",count:41),target:focus,current:{snapshots+=1;return snapshots == 1 ? focus:nil},emit:{_,_ in emitted+=1;return true}) && emitted == 1)
        check("旧授权名称匹配而内部权限串不匹配", KeychainStore.legacyAccessDescription("言随 · 讯飞凭据",current:"随言 · 识别凭据") && !KeychainStore.legacyAccessDescription("cdhash:abc",current:"随言 · 识别凭据"))
        pipeline.snapshotFocus = { focus }
        pipeline.holdStarted(source: .menu, target: focus)
        pipeline.holdEnded()
        recorders.last?.onFinal?("外部结果")
        pump()
        check("菜单原目标身份确认后只插入一次", inserted == ["外部结果"] && pipeline.session == nil)
        pipeline.holdStarted(source: .menu, target: focus)
        pipeline.holdEnded()
        pipeline.snapshotFocus = { nil }
        recorders.last?.onFinal?("不应插入")
        pump()
        check("目标无法验证时保留结果且不插入", inserted.count == 1 && pipeline.lastTranscript == "不应插入")
        pipeline.holdStarted(source: .hotkey)
        check("未知焦点允许开始但禁用自动上屏", pipeline.session != nil && pipeline.session?.retentionReason != nil)
        pipeline.holdEnded();recorders.last?.onFinal?("仅软件保留");pump()
        check("未知目标按住松开后识别结果保留且不插入", pipeline.session == nil && pipeline.lastTranscript == "仅软件保留" && inserted.count == 1 && pipeline.resultAction == .result)
        check("未知目标不盲写也不自动复制",copied.isEmpty && !pipeline.lastInputAccepted)
        var secured=focus;secured.protectedInput=true
        pipeline.snapshotFocus={secured};let beforeSecure=recorders.count
        pipeline.holdStarted(source:.hotkey)
        check("安全输入拒绝且不创建录音器", pipeline.session == nil && recorders.count == beforeSecure && pipeline.resultAction == .targetHelp)
        let unreadable=FocusIdentity(pid:focus.pid,appName:focus.appName,element:focus.element,window:focus.window,role:focus.role,readable:false,selectedTextWritable:true,value:nil)
        check("可信可编辑身份不因 value 不可读分类 unknown", FocusProbe.classify(previous:unreadable,current:unreadable) == .unchanged)
        pipeline.snapshotFocus={unreadable};pipeline.holdStarted(source:.hotkey);pipeline.holdEnded();recorders.last?.onFinal?("可信无需读值");pump()
        check("可信不可读文本目标仍可上屏", inserted.last == "可信无需读值" && inserted.count == 2)
        pipeline.insertText={_,_ in false}
        pipeline.holdStarted(source:.hotkey);pipeline.holdEnded();recorders.last?.onFinal?("写入接口拒绝");pump()
        check("写入未被原控件接受保留结果且不报已输入",pipeline.session == nil && pipeline.resultAction == .result && pipeline.lastIsError && !pipeline.lastInputAccepted)
        pipeline.insertText={text,_ in inserted.append(text);return true}
        var invalid=focus;invalid.identityValid=false
        var securityUnknown=focus;securityUnknown.securityConfirmed=false
        let readOnly=FocusIdentity(pid:focus.pid,appName:focus.appName,element:focus.element,window:focus.window,role:"AXTextArea",readable:false,selectedTextWritable:false,value:nil)
        check("仅文本角色但不可验证写入时不盲写",!readOnly.automaticInputAvailable)
        check("安全属性未知时只保留不盲写",!securityUnknown.automaticInputAvailable)
        check("AX 根节点别名不作为可信目标", !invalid.automaticInputAvailable && FocusProbe.classify(previous:invalid,current:invalid) == .unknown)
        pipeline.snapshotFocus={nil};pipeline.holdStarted(source:.hotkey);pipeline.snapshotFocus={focus};pipeline.holdEnded();recorders.last?.onFinal?("不能后来盲写");pump()
        check("最初未知后续聚焦编辑器仍只保留结果", inserted.count == 2 && pipeline.lastTranscript == "不能后来盲写")
        pipeline.snapshotFocus={focus};pipeline.holdStarted(source:.hotkey);pipeline.snapshotFocus={nil};pipeline.tick()
        check("录音中目标丢失继续录音并锁定仅保留", pipeline.session?.state == .voiceStarted && pipeline.session?.retentionReason != nil)
        pipeline.holdEnded();recorders.last?.onFinal?("焦点丢失保留");pump()
        check("目标丢失识别结束不写入", inserted.count == 2 && pipeline.lastTranscript == "焦点丢失保留")
        check("旧路径焦点丢失不改剪贴板并提示",copied.isEmpty && !pipeline.coordinatedCopied && pipeline.lastResult == L10n.tr("ui.input.retained-no-clipboard"))
        // Window-bound delivery: no editor can be identified (for example a Chromium app), but the original process and window are unchanged.
        let windowOnly=FocusIdentity(pid:focus.pid,appName:focus.appName,element:nil,window:focus.window,role:nil,readable:false,selectedTextWritable:false,value:nil)
        let movedWindow=FocusIdentity(pid:focus.pid,appName:focus.appName,element:nil,window:AXUIElementCreateSystemWide(),role:nil,readable:false,selectedTextWritable:false,value:nil)
        var windowSent:[String]=[];let insertedBeforeWindow=inserted.count
        pipeline.insertIntoWindow={text,_ in windowSent.append(text);return true}
        pipeline.snapshotFocus={windowOnly};pipeline.holdStarted(source:.hotkey)
        check("无法识别输入框但窗口已知时仍可录音且不进入保留",pipeline.session?.windowBound == true && pipeline.session?.retentionReason == nil)
        pipeline.holdEnded();recorders.last?.onFinal?("窗口发送");pump()
        check("窗口未变时发送文字且不写剪贴板",windowSent == ["窗口发送"] && inserted.count == insertedBeforeWindow && copied.isEmpty && pipeline.lastInputAccepted && !pipeline.lastIsError)
        pipeline.snapshotFocus={windowOnly};pipeline.holdStarted(source:.hotkey);pipeline.snapshotFocus={movedWindow};pipeline.tick()
        check("录音中窗口变化改为只保留",pipeline.session?.retentionReason != nil)
        pipeline.holdEnded();recorders.last?.onFinal?("窗口已变");pump()
        check("窗口变化后不发送文字",windowSent == ["窗口发送"] && pipeline.lastTranscript == "窗口已变" && !pipeline.lastInputAccepted)
        pipeline.snapshotFocus={windowOnly};pipeline.holdStarted(source:.hotkey);pipeline.snapshotFocus={movedWindow};pipeline.holdEnded();recorders.last?.onFinal?("结束时窗口变化");pump()
        check("结束时窗口已变不发送文字",windowSent == ["窗口发送"] && !pipeline.lastInputAccepted)
        var windowEmitted=0
        check("按窗口发送逐段核对同一窗口",TextInserter.sendUnicode(String(repeating:"字",count:45),target:windowOnly,current:{windowOnly},windowBound:true,emit:{_,_ in windowEmitted+=1;return true}) && windowEmitted == 3)
        check("未授权按窗口发送时仍拒绝无输入框目标",!TextInserter.sendUnicode("字",target:windowOnly,current:{windowOnly},emit:{_,_ in true}))
        windowEmitted=0;var windowCalls=0
        check("发送中途窗口变化即停止",!TextInserter.sendUnicode(String(repeating:"字",count:45),target:windowOnly,current:{windowCalls+=1;return windowCalls < 2 ? windowOnly:movedWindow},windowBound:true,emit:{_,_ in windowEmitted+=1;return true}) && windowEmitted == 1)
        var secureWindow=windowOnly;secureWindow.protectedInput=true
        check("安全输入时不按窗口发送",!secureWindow.windowBoundAvailable && !TextInserter.sendUnicode("字",target:secureWindow,current:{secureWindow},windowBound:true,emit:{_,_ in true}))
        pipeline.insertIntoWindow={_,_ in false};pipeline.snapshotFocus={windowOnly};pipeline.holdStarted(source:.hotkey);pipeline.holdEnded();recorders.last?.onFinal?("发送失败");pump()
        check("按窗口发送失败时保留文字",pipeline.lastTranscript == "发送失败" && !pipeline.lastInputAccepted && pipeline.lastIsError)
        pipeline.snapshotFocus={nil}
        let countBeforeEmpty=copied.count
        pipeline.snapshotFocus={focus};pipeline.holdStarted(source:.hotkey);pipeline.holdEnded();recorders.last?.onFinal?("");pump()
        check("空结果既不插入也不改剪贴板",inserted.count == 2 && copied.count == countBeforeEmpty && pipeline.lastTranscript == nil)
        pipeline.snapshotFocus={focus};pipeline.holdStarted(source:.hotkey);pipeline.snapshotFocus={secured};pipeline.tick()
        check("录音中进入安全输入取消且不插入", pipeline.session == nil && inserted.count == 2)
        check("安全子角色识别", FocusProbe.protectedTarget(role:"AXTextField",subrole:"AXSecureTextField",secureInput:false))
        check("系统安全输入识别", FocusProbe.protectedTarget(role:nil,subrole:nil,secureInput:true))
        pipeline.snapshotFocus={focus};pipeline.holdStarted(source:.hotkey);recorders.last?.onPartial?("错误部分结果");pump();pipeline.holdEnded();recorders.last?.lastError="测试服务错误";recorders.last?.onFinal?(nil);pump()
        check("服务失败部分结果保留但不盲写",inserted.count==2 && pipeline.lastTranscript=="错误部分结果" && pipeline.resultAction == .result)
        pipeline.snapshotFocus={focus};pipeline.holdStarted(source:.hotkey);recorders.last?.onPartial?("超时部分结果");pump();pipeline.holdEnded();clock=clock.addingTimeInterval(13);pipeline.tick()
        check("识别超时部分结果不自动上屏且恢复空闲",inserted.count==2 && pipeline.session==nil && pipeline.lastTranscript=="超时部分结果")
        var configuration = store.config
        configuration.microphoneUID = "persistent-mic-uid"
        let roundTrip = try? JSONDecoder().decode(BridgeConfig.self, from: JSONEncoder().encode(configuration))
        check("麦克风与输入模式配置可持久化往返", roundTrip?.microphoneUID == "persistent-mic-uid" && roundTrip?.inputMode == "hold")
        configuration.inputMode = "toggle"
        check("切换窗口模式已支持", BridgeConfig.validate(configuration).isEmpty)

    }
    static func testSilenceAndOwnTargets() {
        let meter=AudioSignalEvidence()
        let format=AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:64)!;buffer.frameLength=64
        buffer.floatChannelData![0].initialize(repeating:0,count:64)
        meter.observe(buffer)
        check("真实PCM零样本数字静音无信号",meter.hasSignal == false)
        buffer.floatChannelData![0][63]=0.0000001;meter.observe(buffer)
        check("极低非零信号不被当作数字静音",meter.hasSignal == true)
        meter.reset();check("新采集信号证据归零",meter.hasSignal == false)
        let stereoFormat=AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:16000,channels:2,interleaved:true)!
        let stereo=AVAudioPCMBuffer(pcmFormat:stereoFormat,frameCapacity:64)!;stereo.frameLength=64
        stereo.int16ChannelData![0].initialize(repeating:0,count:128)
        meter.observe(stereo);check("交错双声道整数PCM数字静音",meter.hasSignal == false)
        stereo.int16ChannelData![0][127]=1;meter.observe(stereo)
        check("交错第二声道非零样本保留信号",meter.hasSignal == true)
        meter.reset()

        let store=ConfigStore(),saved=ConfigStore().config
        defer {store.mutate{$0=saved}}
        store.mutate{$0.enabled=true;$0.mode="hold";$0.engine="apple"}
        let pipeline=VoicePipeline(configStore:store,input:InputSourceController())
        var engines:[StubRecorder]=[]
        pipeline.recorderFactory={let r=StubRecorder();engines.append(r);return r}
        var writes=0;var level:Float=1
        pipeline.insertText={_,_ in writes += 1;return true};pipeline.onLevel={level=$0}
        let el=AXUIElementCreateApplication(12345)
        let external=FocusIdentity(pid:12345,appName:"fixture",element:el,window:el,role:"AXTextArea",readable:false,selectedTextWritable:true,value:nil)
        pipeline.snapshotFocus={external}
        pipeline.holdStarted(source:.hotkey);engines.last?.capturedAudioHasSignal=false
        engines.last?.onPartial?("constructed hallucination");pump();pipeline.holdEnded();engines.last?.onFinal?("constructed hallucination");pump()
        check("数字静音拒绝非空服务结果和partial且完整收尾",writes==0 && pipeline.lastTranscript==nil && pipeline.resourcesIdle && level==0)
        pipeline.holdStarted(source:.hotkey);engines.last?.capturedAudioHasSignal=true
        engines.last?.onPartial?("constructed partial");pump();pipeline.holdEnded();engines.last?.onFinal?(nil);pump()
        check("无最终确认的partial仅保留且不自动写入",writes==0 && pipeline.lastTranscript != nil && pipeline.resourcesIdle && pipeline.resultAction == .result)
        let own=FocusIdentity(pid:ProcessInfo.processInfo.processIdentifier,appName:"fixture",element:el,window:el,role:"AXTextArea",readable:false,selectedTextWritable:true,value:nil)
        pipeline.snapshotFocus={own};pipeline.holdStarted(source:.hotkey);pipeline.holdEnded();engines.last?.onFinal?("constructed own result");pump()
        check("自有目标全局来源保留结果不调用写入且归零",writes==0 && pipeline.lastTranscript != nil && pipeline.resourcesIdle && pipeline.resultAction == .result)
        check("写入器自有PID在CF属性调用前拒绝",!TextInserter.insert("fixture",target:own))
        let invalid=FocusIdentity(pid:-1,appName:"fixture",element:el,window:el,role:"AXTextArea",readable:false,selectedTextWritable:true,value:nil)
        check("写入器无效PID在CF属性调用前拒绝",!TextInserter.insert("fixture",target:invalid) && !invalid.identityAvailable)
        for _ in 0..<30 {pipeline.holdStarted(source:.hotkey);pipeline.holdEnded();pipeline.forceEnd(reason:"constructed rapid restart")}
        check("快速重启后会话录音器计时器partial电平均归零",pipeline.resourcesIdle && level==0 && writes==0)
    }

    static func testRemainingLifecycle() {
        let store=ConfigStore(),saved=store.config
        defer {store.mutate{$0=saved}}
        store.mutate{$0.enabled=true;$0.mode="hold";$0.engine="apple";$0.recordingTimeoutSec=1}
        let input=InputSourceController(),originalSource=input.currentID()
        let pipeline=VoicePipeline(configStore:store,input:input)
        var engines:[StubRecorder]=[];var failBegin=false
        pipeline.recorderFactory={let r=StubRecorder();r.beginSucceeds = !failBegin;engines.append(r);return r}
        var writes=0;var level:Float=0
        pipeline.insertText={_,_ in writes += 1;return true};pipeline.onLevel={level=$0}
        let element=AXUIElementCreateApplication(12345),window=AXUIElementCreateApplication(12346)
        let focus=FocusIdentity(pid:12345,appName:"fixture",element:element,window:window,role:"AXTextArea",readable:false,selectedTextWritable:true,value:nil)
        let changedWindow=FocusIdentity(pid:12345,appName:"fixture",element:element,window:AXUIElementCreateApplication(12347),role:"AXTextArea",readable:false,selectedTextWritable:true,value:nil)
        let changedEditor=FocusIdentity(pid:12345,appName:"fixture",element:AXUIElementCreateApplication(12348),window:window,role:"AXTextArea",readable:false,selectedTextWritable:true,value:nil)
        pipeline.snapshotFocus={focus};pipeline.holdStarted(source:.hotkey)
        pipeline.snapshotFocus={changedWindow};pipeline.tick()
        check("录音中同应用换窗口锁定仅保留",pipeline.session?.retentionReason != nil)
        pipeline.snapshotFocus={focus};pipeline.holdEnded();engines.last?.onFinal?("constructed");pump()
        check("返回原窗口不重新启用该轮写入且资源归零",writes==0 && pipeline.resourcesIdle && pipeline.resultAction == .result)
        pipeline.holdStarted(source:.hotkey);pipeline.holdEnded();pipeline.snapshotFocus={changedEditor};engines.last?.onFinal?("constructed");pump()
        check("最终同窗口换编辑器拒绝自动写入且归零",writes==0 && pipeline.resourcesIdle && pipeline.resultAction == .result)
        pipeline.snapshotFocus={focus};pipeline.holdStarted(source:.hotkey)
        let lateLevel=engines.last?.onLevel;pipeline.forceEnd(reason:"constructed cancel")
        pipeline.holdStarted(source:.hotkey);engines.last?.onLevel?(0.25);pump();lateLevel?(1);pump()
        check("取消后迟到电平不污染新会话",level==0.25 && pipeline.hasActiveSession)
        pipeline.forceEnd(reason:"constructed cancel");check("取消新会话电平归零",pipeline.resourcesIdle && level==0)
        failBegin=true;pipeline.holdStarted(source:.hotkey)
        check("录音启动失败立即归零并可重试",pipeline.resourcesIdle && level==0 && writes==0)
        failBegin=false;var clock=Date();pipeline.now={clock};pipeline.holdStarted(source:.hotkey)
        clock=clock.addingTimeInterval(2);pipeline.tick()
        check("录音超时只结束采集一次进入识别",pipeline.session?.state == .awaitingConfirm && engines.last?.ends==1)
        clock=clock.addingTimeInterval(13);pipeline.tick()
        check("录音与识别双超时最终清理且不写入",pipeline.resourcesIdle && level==0 && writes==0)
        check("开始结束取消失败超时全程保持原输入源",input.currentID()==originalSource)
    }

    static func testAppearanceConfiguration(){
        let old=try! JSONDecoder().decode(BridgeConfig.self,from:Data("{}".utf8))
        check("旧配置无外观字段继续跟随系统",old.appearanceMode == "system")
        for name in ["system","light","dark"] {var c=BridgeConfig.default();c.appearanceMode=name;let decoded=try! JSONDecoder().decode(BridgeConfig.self,from:JSONEncoder().encode(c));check("外观选择保存与解码 "+name,decoded.appearanceMode==name && BridgeConfig.validate(decoded).isEmpty)}
        var bad=BridgeConfig.default();bad.appearanceMode="unknown";check("未知外观配置拒绝",!BridgeConfig.validate(bad).isEmpty)
    }

    static func testDualShortcuts() {
        let opt=UInt32(optionKey),ctrl=UInt32(controlKey),shift=UInt32(shiftKey)
        let hold=HotkeySpec(keyCode:58,modifiers:opt)
        let toggle=HotkeySpec(keyCode:106,modifiers:0)
        var r=DualShortcutCycle(hold:hold,toggle:toggle)
        check("按住模式 down 开始",r.event(type:.flagsChanged,code:58,modifiers:opt,down:[58]) == [.holdStart])
        check("按住模式 up 结束",r.event(type:.flagsChanged,code:58,modifiers:0,down:[]) == [.holdEnd])
        check("切换 down 不提前触发",r.event(type:.keyDown,code:106,modifiers:0,down:[106]).isEmpty)
        check("切换过滤自动重复",r.event(type:.keyDown,code:106,modifiers:0,down:[106],repeatKey:true).isEmpty)
        check("切换完整释放只触发一次",r.event(type:.keyUp,code:106,modifiers:0,down:[]) == [.toggle])
        check("切换重复 up 不触发",r.event(type:.keyUp,code:106,modifiers:0,down:[]).isEmpty)
        check("右 Option 不触发默认左键",r.event(type:.flagsChanged,code:61,modifiers:opt,down:[61]).isEmpty)
        _=r.event(type:.flagsChanged,code:58,modifiers:opt,down:[58],toggleRecording:true)
        check("切换录音中 Option+C 不停止录音",r.event(type:.keyDown,code:8,modifiers:opt,down:[58,8],toggleRecording:true).isEmpty)
        _=r.event(type:.flagsChanged,code:58,modifiers:0,down:[],toggleRecording:true)
        _=r.event(type:.flagsChanged,code:58,modifiers:opt,down:[58],toggleRecording:true)
        check("切换录音中干净按住键完整按压只停止",r.event(type:.flagsChanged,code:58,modifiers:0,down:[],toggleRecording:true) == [.crossStop])
        check("切换中日常打字不取消",r.event(type:.keyDown,code:0,modifiers:0,down:[0],toggleRecording:true).isEmpty)
        check("Esc 对两模式都取消",r.event(type:.keyDown,code:53,modifiers:0,down:[53],toggleRecording:true) == [.cancel])
        var lone=ToggleShortcutCycle(spec:hold)
        _=lone.event(type:.flagsChanged,code:58,modifiers:opt,downKeys:[58])
        _=lone.event(type:.keyDown,code:8,modifiers:opt,downKeys:[58,8])
        check("单修饰切换键组合不误触",!lone.event(type:.flagsChanged,code:58,modifiers:0,downKeys:[]))
        _=lone.event(type:.flagsChanged,code:58,modifiers:opt,downKeys:[58]);lone.poll([])
        check("切换漏 up 不伪造完成周期",!lone.event(type:.flagsChanged,code:58,modifiers:0,downKeys:[]))
        _=lone.event(type:.flagsChanged,code:58,modifiers:opt,downKeys:[58])
        check("切换漏 up 后下一干净周期恢复",lone.event(type:.flagsChanged,code:58,modifiers:0,downKeys:[]))
        let combo=HotkeySpec(keyCode:5,modifiers:ctrl|shift,modifierKeyCodes:[59,56])
        var c=ToggleShortcutCycle(spec:combo)
        _=c.event(type:.keyDown,code:5,modifiers:ctrl|shift,downKeys:[5,59,56])
        check("组合切换不在主键 up 时提前触发",!c.event(type:.keyUp,code:5,modifiers:ctrl|shift,downKeys:[59,56]))
        _=c.event(type:.flagsChanged,code:56,modifiers:ctrl,downKeys:[59])
        check("组合全部释放才触发",c.event(type:.flagsChanged,code:59,modifiers:0,downKeys:[]))
        var cross=DualShortcutCycle(hold:hold,toggle:HotkeySpec(keyCode:5,modifiers:ctrl|opt,modifierKeyCodes:[58,59]))
        _=cross.event(type:.flagsChanged,code:58,modifiers:opt,down:[58])
        check("跨模式合法前缀不提前取消",cross.event(type:.flagsChanged,code:59,modifiers:ctrl|opt,down:[58,59],time:1).isEmpty)
        _=cross.event(type:.keyDown,code:5,modifiers:ctrl|opt,down:[58,59,5],time:1.1)
        _=cross.event(type:.keyUp,code:5,modifiers:ctrl|opt,down:[58,59],time:1.2)
        check("跨模式原键松开只结束当前录音",cross.event(type:.flagsChanged,code:58,modifiers:ctrl,down:[59],time:1.3) == [.crossStop])
        check("跨模式迟到释放不启动第二录音器",cross.event(type:.flagsChanged,code:59,modifiers:0,down:[],time:1.4).isEmpty)
        var config=BridgeConfig.default();config.trigger=combo;config.toggleTrigger=toggle;config.toggleShortcutEnabled=true
        let data=try! JSONEncoder().encode(config);let decoded=try! JSONDecoder().decode(BridgeConfig.self,from:data)
        check("两键及启用状态序列化保持",decoded.trigger==combo && decoded.toggleTrigger==toggle && decoded.toggleShortcutEnabled && decoded.holdShortcutEnabled)
        let legacy=try! JSONDecoder().decode(BridgeConfig.self,from:Data("{\"trigger\":{\"keyCode\":5,\"modifiers\":4608}}".utf8))
        check("旧配置保留原按住绑定且不设置切换",legacy.trigger.keyCode==5 && legacy.toggleTrigger==nil && !legacy.toggleShortcutEnabled && legacy.holdShortcutEnabled)
        config.toggleTrigger=config.trigger
        check("两种绑定相同拒绝",!BridgeConfig.validate(config).isEmpty)
        config.toggleTrigger=nil
        check("未设绑定不能启用切换快捷键",!BridgeConfig.validate(config).isEmpty)
        var activated:[BridgeConfig]=[];var restored=false
        let original=BridgeConfig.default();var proposed=original;proposed.toggleTrigger=toggle;proposed.toggleShortcutEnabled=true
        let failed=DualBindingTransaction.commit(proposed,old:original,activate:{activated.append($0);return $0.toggleTrigger==nil},persist:{_ in fatalError("must not persist")},restore:{_ in restored=true})
        check("双绑定监听失败回滚两套原状态",!failed && restored && activated.count==2 && activated.last?.toggleTrigger==nil)
        activated=[];restored=false
        let diskFail=DualBindingTransaction.commit(proposed,old:original,activate:{activated.append($0);return true},persist:{_ in false},restore:{_ in restored=true})
        check("双绑定持久化失败回滚监听和配置",!diskFail && restored && activated.last?.toggleTrigger==nil)
        let store=ConfigStore();let saved=store.config;defer{_=store.mutate{$0=saved}}
        _=store.mutate{$0.enabled=true;$0.mode="hold";$0.engine="apple"}
        let pipeline=VoicePipeline(configStore:store,input:InputSourceController());pipeline.snapshotFocus={nil}
        var engines:[StubRecorder]=[];pipeline.recorderFactory={let e=StubRecorder();engines.append(e);return e}
        var writes=0;pipeline.insertText={_,_ in writes+=1;return true }
        pipeline.togglePressed()
        check("切换首次开始共用录音器",pipeline.session?.source == .toggle && engines.count==1)
        pipeline.togglePressed()
        check("切换第二次结束进入识别",pipeline.session?.state == .awaitingConfirm && engines[0].ends==1)
        engines[0].onFinal?("切换保留结果");pump()
        check("切换未知目标识别仅保留",pipeline.lastTranscript=="切换保留结果" && pipeline.session==nil && writes==0)
        pipeline.togglePressed();pipeline.holdStarted(source:.hotkey)
        check("按住入口停止切换且不启动第二录音器",pipeline.session?.state == .awaitingConfirm && engines.count==2)
        let old=engines[1].onFinal;pipeline.togglePressed();old?("迟到结果");pump()
        check("切换识别中重录隔离旧结果",engines.count==3 && pipeline.session?.state == .voiceStarted && pipeline.lastTranscript==nil)
        pipeline.forceEnd(reason:"test sleep");check("睡眠取消切换恢复空闲",pipeline.session==nil)
        var clock=Date();pipeline.now={clock};pipeline.togglePressed();clock=clock.addingTimeInterval(601);pipeline.tick()
        check("切换有录音上限并进入识别",pipeline.session?.state == .awaitingConfirm && engines.last?.ends==1)
        pipeline.forceEnd(reason:"test cleanup")
    }

}
