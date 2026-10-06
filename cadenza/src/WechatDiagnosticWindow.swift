import AppKit

final class WechatDiagnosticWindow:NSWindowController,NSWindowDelegate {
    let flow:WechatDiagnosticFlow
    private let busy:()->Bool,register:(@escaping()->Void)->Bool,unregister:()->Void
    private let field=NSPopUpButton(),agreement=NSButton(checkboxWithTitle:"我同意一次有限诊断，并将在原微信输入位置确认光标后按组合键继续",target:nil,action:nil)
    private let feedback=NSTextField(wrappingLabelWithString:""),prepare=NSButton(),cancelButton=NSButton()
    var onState:(()->Void)?
    init(flow:WechatDiagnosticFlow,busy:@escaping()->Bool,register:@escaping(@escaping()->Void)->Bool,unregister:@escaping()->Void){
        self.flow=flow;self.busy=busy;self.register=register;self.unregister=unregister
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:580),styleMask:[.titled,.closable],backing:.buffered,defer:false);w.title="微信输入诊断";w.isReleasedWhenClosed=false
        super.init(window:w);w.delegate=self
        field.addItems(withTitles:["请选择失败时的实际字段","聊天消息输入框","搜索输入框","其他输入框"])
        prepare.title="准备返回微信";prepare.target=self;prepare.action=#selector(arm);prepare.bezelStyle = .rounded
        cancelButton.title="取消诊断 / 关闭";cancelButton.target=self;cancelButton.action=#selector(cancel);cancelButton.bezelStyle = .rounded
        let explanation=NSTextField(wrappingLabelWithString:"诊断只针对录音前已记录的微信原窗口。会读取辅助功能兼容属性的原值，必要时短暂开启并恢复复核；原本开启则不关闭，不打开VoiceOver。先选择字段并同意，再返回那个窗口，点选输入框看到光标；按 Control + Option + Command + D 代表你现场确认条件并开始。诊断不写任何文字，结束复核属性恢复。结束后切回随言查看诊断和恢复结果，再返回原输入框主动重新录音；旧结果不会补写。诊断完成不代表语音已经上屏。")
        let stack=NSStackView(views:[explanation,field,agreement,feedback,NSStackView(views:[prepare,cancelButton])]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=18;stack.translatesAutoresizingMaskIntoConstraints=false;w.contentView?.addSubview(stack)
        if let content=w.contentView {NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:24),stack.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-24),stack.topAnchor.constraint(equalTo:content.topAnchor,constant:24)])}
        for v in [explanation,agreement,feedback]{v.widthAnchor.constraint(equalToConstant:592).isActive=true}
        for (id,v) in [("field",field),("agreement",agreement),("prepare",prepare),("cancel",cancelButton),("feedback",feedback)] as [(String,NSView)] {v.identifier=NSUserInterfaceItemIdentifier("wechat.diagnostic."+id)}
        flow.changed={[weak self] in self?.refresh();self?.onState?()};refresh()
    }
    required init?(coder:NSCoder){fatalError("unsupported")}
    func present(){window?.center();showWindow(nil);window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    @objc private func arm(){guard flow.prepare(field:field.indexOfSelectedItem,agreed:agreement.state == .on,busy:busy()) else{refresh();return};if !register({[weak self] in self?.continueByUser()}){flow.cancel();feedback.stringValue="专用继续组合键注册失败，未开始诊断；请检查组合键冲突。"}}
    func continueByUser(){flow.continueByUser()}
    @objc private func cancel(){flow.cancel();if flow.state != .running{close()}}
    func refresh(){feedback.stringValue=flow.message;let editable=flow.state == .idle || flow.state == .finished;field.isEnabled=editable;agreement.isEnabled=editable;prepare.isEnabled=editable && flow.available;if flow.state != .waiting{unregister()}}
    func windowShouldClose(_ sender:NSWindow)->Bool {flow.cancel();return flow.state != .running}
    func windowWillClose(_ notification:Notification){unregister();flow.cancel()}
    deinit{unregister()}
}
