import AppKit

/// 翻转坐标：滚动文档视图从顶部排布，避免内容短于视口时顶部出现大块空白
private final class FlippedStackView: NSStackView { override var isFlipped: Bool { true } }

enum ASROptionPolicy {
    static func validate(_ e:ASREngine,_ o:CloudASROptions)->String? {
        guard o.hotwords.utf8.count<=4000,o.vocabularyID.count<=128,o.correctionTableID.count<=128,o.model.count<=128 else{return L10n.tr("ui.b000c25d8071")}
        switch e {
        case .deepgram:
            guard o.model == "nova-3",DeepgramAPI.languages.contains(o.language),!o.smoothing,!o.secondPass,DeepgramAPI.validKeyterms(o.hotwords),o.vocabularyID.isEmpty,o.correctionTableID.isEmpty else{return L10n.tr("deepgram.invalidOptions")}
        case .volcengine:
            guard ["volc.seedasr.sauc.duration","volc.seedasr.sauc.concurrent","volc.bigasr.sauc.duration","volc.bigasr.sauc.concurrent"].contains(o.model) else{return L10n.tr("ui.b2311a36c9a3")}
            guard o.hotwords.split(separator:"\n").count<=50 else{return L10n.tr("ui.569e55f7a013")}
        case .tencent:
            guard ["16k_zh","16k_en","16k_zh_en"].contains(o.model) else{return L10n.tr("ui.2b950601a343")}
            if !CloudASROptions.tencentTextModels.contains(o.model) && (o.smoothing || o.punctuation || o.itn){return L10n.tr("ui.67937abe7fa2")}
            if !o.hotwords.isEmpty {
                let entries=o.hotwords.split(separator:",",omittingEmptySubsequences:false)
                guard entries.count<=128,entries.allSatisfy({let p=$0.split(separator:"|",omittingEmptySubsequences:false);return p.count==2 && !p[0].isEmpty && p[0].count<=30 && p[0].unicodeScalars.filter({(0x4E00...0x9FFF).contains($0.value)}).count<=10 && !p[0].contains(where:{$0.isWhitespace}) && Int(p[1]).map{(1...11).contains($0) || $0==100 && o.model=="16k_zh"}==true}) else{return L10n.tr("ui.97dd62ced699")}
            }
        case .aliyun:
            guard ["cn-shanghai","cn-beijing","cn-shenzhen"].contains(o.region) else{return L10n.tr("ui.7f2f898f4f79")}
        case .baidu:
            guard ["1537","1737","1637","1837"].contains(o.model),o.vocabularyID.isEmpty || o.model=="1537" && Int(o.vocabularyID).map({$0>0})==true else{return L10n.tr("ui.3a69fc7da08b")}
        case .openai,.groq,.compat,.google,.azure:
            if let problem=BatchTranscription.validate(e,o){return problem}
        default:break
        }
        if (e == .iflytek || e == .baidu) && (o.smoothing || o.secondPass){return L10n.tr("ui.25889af6645e")}
        if (e == .tencent || e == .aliyun) && o.secondPass{return L10n.tr("ui.054a6cb3adbe")}
        if e == .iflytek && !o.hotwords.isEmpty{return L10n.tr("ui.78170ece0ed1")}
        return nil
    }
    static func capabilityText(_ e:ASREngine)->String {switch e {
    case .iflytek:return L10n.tr("ui.abedb7d4b47d")
    case .volcengine:return L10n.tr("ui.b5151a619649")
    case .tencent:return L10n.tr("ui.3c7c02a8e59d")
    case .aliyun:return L10n.tr("ui.18445402bdfc")
    case .baidu:return L10n.tr("ui.e0e9b43eb918")
    case .apple:return L10n.tr("ui.a556c4a215de")
    case .local:return L10n.tr("local.capability")
    case .deepgram:return L10n.tr("deepgram.capability")
    case .openai,.groq,.compat,.google,.azure:return L10n.tr("batch.capability")
    }}
}
protocol ASRCredentialWriting:AnyObject {
    @discardableResult func set(_ value:String,for key:String)->Bool
}
final class KeychainASRCredentialWriter:ASRCredentialWriting {
    func set(_ value:String,for key:String)->Bool{KeychainStore.set(value,for:key)}
}
final class ASRSettingsController:NSWindowController,NSWindowDelegate {
    private let store:ConfigStore,engine:ASREngine,changed:()->Void,busy:()->Bool
    private let credentialWriter:ASRCredentialWriting
    private var secure:[String:NSSecureTextField]=[:],model=NSPopUpButton(),region=NSPopUpButton(),hotwords=NSTextField(),vocabulary=NSTextField(),correction=NSTextField(),mappings=NSTextField()
    private var consent=NSButton(),punc=NSButton(),itn=NSButton(),smooth=NSButton(),second=NSButton(),feedback=NSTextField(labelWithString:"")
    init(store:ConfigStore,engine:ASREngine,busy:@escaping()->Bool,changed:@escaping()->Void,credentialWriter:ASRCredentialWriting=KeychainASRCredentialWriter()) {
        self.store=store;self.engine=engine;self.busy=busy;self.changed=changed;self.credentialWriter=credentialWriter
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:740),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);window.title=engine.title+L10n.tr("ui.df3d58c7d84b");window.minSize=NSSize(width:680,height:650);window.isReleasedWhenClosed=false
        super.init(window:window);window.delegate=self;window.appearance=NSApp.appearance
        let stack=FlippedStackView();stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=12;stack.edgeInsets=NSEdgeInsets(top:24,left:24,bottom:24,right:24)
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.drawsBackground=true;scroll.backgroundColor=DesignTokens.settingsBackground;scroll.documentView=stack;window.contentView=scroll
        stack.translatesAutoresizingMaskIntoConstraints=true;stack.autoresizingMask = [.width]
        func label(_ s:String)->NSTextField {let t=NSTextField(wrappingLabelWithString:s);t.font = .systemFont(ofSize:12);t.widthAnchor.constraint(equalToConstant:620).isActive=true;return t}
        func row(_ name:String,_ control:NSView){let t=NSTextField(labelWithString:name);t.widthAnchor.constraint(equalToConstant:168).isActive=true;let r=NSStackView(views:[t,control]);r.orientation = .horizontal;r.spacing=12;control.widthAnchor.constraint(equalToConstant:430).isActive=true;stack.addArrangedSubview(r)}
        func checkbox(_ name:String,_ value:Bool)->NSButton {let b=BrandCheckbox(checkboxWithTitle:name,target:nil,action:nil);b.state=value ? .on:.off;return b}
        let o=store.config.options(engine)
        if engine != .apple {
            let guide=NSTextField(wrappingLabelWithString:L10n.format("ui.cb7ebbb3fc8b", String(describing: engine.title)))
            guide.font = .systemFont(ofSize:12)
            guide.widthAnchor.constraint(equalToConstant:620).isActive=true
            stack.addArrangedSubview(guide)
            let openBtn=NSButton(title:L10n.format("ui.7a79b779f816", String(describing: engine.title)),target:self,action:#selector(openConsole))
            openBtn.bezelStyle = .rounded
            openBtn.identifier=NSUserInterfaceItemIdentifier("asr.console.open")
            stack.addArrangedSubview(openBtn)
        }
        stack.addArrangedSubview(label(engine.title+L10n.tr("ui.b0370fa622d8")))
        stack.addArrangedSubview(label(ASROptionPolicy.capabilityText(engine)))
        if engine == .baidu{stack.addArrangedSubview(label(L10n.tr("ui.d14670c35854")))}
        if engine == .tencent{stack.addArrangedSubview(label(L10n.tr("ui.7008394c2e7f")))}
        if engine == .aliyun{stack.addArrangedSubview(label(L10n.tr("ui.a4666d770479")))}
        if engine == .volcengine{stack.addArrangedSubview(label(L10n.tr("ui.eb45875691d1")))}
        stack.addArrangedSubview(label(L10n.tr("ui.3144e711ad64")))
        for (key,name) in engine.credentialFields {let field=NSSecureTextField();field.identifier=NSUserInterfaceItemIdentifier("asr.credential."+key);field.placeholderString=L10n.tr("ui.5f196397724d");secure[key]=field;row(name,field)}
        let models:[String];switch engine {case .volcengine:models=["volc.seedasr.sauc.duration","volc.seedasr.sauc.concurrent","volc.bigasr.sauc.duration","volc.bigasr.sauc.concurrent"];case .tencent:models=["16k_zh","16k_en","16k_zh_en"];case .baidu:models=["1537","1737","1637","1837"];case .openai,.groq:models=BatchTranscription.service(engine)?.models ?? [];default:models=[]}
        if !models.isEmpty{model.addItems(withTitles:models);model.selectItem(withTitle:o.model);model.target=self;model.action=#selector(modelChanged);row(L10n.tr("ui.d76465693690"),model)}
        if engine == .aliyun{region.addItems(withTitles:["cn-shanghai","cn-beijing","cn-shenzhen"]);region.selectItem(withTitle:o.region);row(L10n.tr("ui.9c26cb4d716d"),region)}
        if engine == .volcengine || engine == .tencent || BatchTranscription.service(engine) != nil {hotwords.stringValue=o.hotwords;hotwords.placeholderString=engine == .tencent ? L10n.tr("ui.b41cffa7de36"):BatchTranscription.service(engine) != nil ? L10n.tr("batch.hotwords.placeholder"):L10n.tr("ui.3feb3b033561");row(L10n.tr("ui.9d39fb2c12be"),hotwords)}
        if engine == .volcengine || engine == .aliyun || engine == .baidu {vocabulary.stringValue=o.vocabularyID;vocabulary.placeholderString=engine == .baidu ? L10n.tr("ui.c2c2358a1fad"):L10n.tr("ui.f402ac0f4c03");row(L10n.tr("ui.7a32a9ca8f38"),vocabulary)}
        if engine == .aliyun {let custom=NSTextField(string:o.model);custom.identifier=NSUserInterfaceItemIdentifier("nls-custom-model");custom.placeholderString=L10n.tr("ui.ca612dbeae8b");row(L10n.tr("ui.39f1a4088dbb"),custom);customModel=custom}
        if engine == .volcengine{correction.stringValue=o.correctionTableID;row(L10n.tr("ui.0c7bfaf16124"),correction)}
        punc=checkbox(L10n.tr("ui.ba8f4e13f8de"),o.punctuation);itn=checkbox(L10n.tr("ui.0f9dc3678abe"),o.itn);smooth=checkbox(L10n.tr("ui.cc8c352f8dbb"),o.smoothing);second=checkbox(L10n.tr("ui.d3cc890d2739"),o.secondPass)
        punc.isEnabled=engine.hasTextSwitches;itn.isEnabled=engine.hasTextSwitches;smooth.isEnabled=[.volcengine,.tencent,.aliyun].contains(engine);second.isEnabled=engine == .volcengine
        modelChanged()
        for b in [punc,itn,smooth,second]{stack.addArrangedSubview(b)}
        mappings.stringValue=store.config.localASRMappings.map{$0.source+" => "+$0.replacement}.joined(separator:"\n");mappings.placeholderString=L10n.tr("ui.54174c25a0b8");row(L10n.tr("ui.d7eb72cda81e"),mappings)
        stack.addArrangedSubview(label(L10n.tr("ui.e2da8cd7a4ea")))
        consent=checkbox(L10n.tr("ui.9d36b92c85c0")+engine.title,o.consent);stack.addArrangedSubview(consent)
        let save=NSButton(title:L10n.tr("ui.acc46dc157bd"),target:self,action:#selector(save));save.bezelStyle = .rounded
        let close=NSButton(title:L10n.tr("ui.2cd0f3be8738"),target:self,action:#selector(dismiss));close.bezelStyle = .rounded;stack.addArrangedSubview(NSStackView(views:[save,close]));stack.addArrangedSubview(feedback)
        for (id,view) in [("model",model),("region",region),("hotwords",hotwords),("vocabulary",vocabulary),("correction",correction),("mappings",mappings),("consent",consent),("punctuation",punc),("itn",itn),("smoothing",smooth),("secondPass",second),("feedback",feedback),("save",save),("cancel",close)] as [(String,NSView)] {view.identifier=NSUserInterfaceItemIdentifier("asr."+id)}
        stack.layoutSubtreeIfNeeded()
        stack.setFrameSize(NSSize(width:max(632,scroll.contentView.bounds.width),height:max(stack.fittingSize.height,scroll.contentView.bounds.height)))
    }
    @objc private func openConsole(){
        let url:String
        switch engine {
        case .deepgram:url="https://console.deepgram.com"
        case .iflytek:url="https://console.xfyun.cn"
        case .volcengine:url="https://console.volcengine.com/speech/app"
        case .tencent:url="https://console.cloud.tencent.com/asr"
        case .aliyun:url="https://nls-portal.console.aliyun.com"
        case .baidu:url="https://console.bce.baidu.com/ai/#/ai/speech/overview/index"
        case .google:url="https://console.cloud.google.com/apis/credentials"
        case .azure:url="https://portal.azure.com/#view/Microsoft_Azure_ProjectOxford/CognitiveServicesHub/~/SpeechServices"
        case .openai:url="https://platform.openai.com/api-keys"
        case .groq:url="https://console.groq.com/keys"
        case .apple,.local,.compat:return
        }
        guard let u=URL(string:url),u.scheme=="https",let host=u.host,!host.isEmpty,host.contains(".") else{return}
        NSWorkspace.shared.open(u)
        Log.write("asr-console-open provider=\(engine.rawValue) host=\(host)")
    }

    func showForEditing(){
        guard let window=window else{return}
        if let scroll=window.contentView as? NSScrollView {scroll.contentView.scroll(to:.zero);scroll.reflectScrolledClipView(scroll.contentView)}
        window.center();showWindow(nil);window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        window.recalculateKeyViewLoop()
        if let key=engine.credentialFields.first?.0,let first=secure[key] {
            window.initialFirstResponder=first
            let focused=window.makeFirstResponder(first)
            Log.write("asr-entry-focus provider=\(engine.rawValue) editable=\(first.isEditable) enabled=\(first.isEnabled) responder-request=\(focused)")
        }
    }
    func renderEvidence(theme:String,outputDirectory:URL=AppPaths.supportDir) {
        guard let window=window,let view=window.contentView else{return}
        window.appearance=NSAppearance(named:theme=="dark" ? .darkAqua:.aqua);view.layoutSubtreeIfNeeded()
        let prefix=outputDirectory.appendingPathComponent("asr-preview-"+engine.rawValue+"-"+theme)
        for (index,fraction) in [CGFloat(0),CGFloat(1)].enumerated() {
            if let scroll=view as? NSScrollView,let document=scroll.documentView {let y=(document.bounds.height-scroll.contentView.bounds.height)*fraction;scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,y)));scroll.reflectScrolledClipView(scroll.contentView)}
            view.layoutSubtreeIfNeeded()
            if let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds){window.effectiveAppearance.performAsCurrentDrawingAppearance{view.cacheDisplay(in:view.bounds,to:bitmap)};if let data=bitmap.representation(using:.png,properties:[:]){try? data.write(to:URL(fileURLWithPath:prefix.path+"-"+String(index)+".png"),options:.atomic)}}
        }
        Log.write("asr-settings-native-render provider=\(engine.rawValue) theme=\(theme) synthetic=true screen-acceptance=false")
    }
    private var customModel:NSTextField?
    required init?(coder:NSCoder){fatalError("unsupported")}
    @objc private func modelChanged(){if engine == .tencent {let supported=CloudASROptions.tencentTextModels.contains(model.titleOfSelectedItem ?? "");for b in [punc,itn,smooth]{b.isEnabled=supported;if !supported{b.state = .off}}}}
    @objc private func dismiss(){secure.values.forEach{$0.stringValue=""};close()}
    @objc private func save(){guard !busy() else{feedback.stringValue=L10n.tr("ui.6405a2f5fe81");return}
        var o=store.config.options(engine);o.consent=consent.state == .on;o.punctuation=punc.state == .on;o.itn=itn.state == .on;o.smoothing=smooth.state == .on;o.secondPass=second.state == .on
        if model.numberOfItems>0{o.model=model.titleOfSelectedItem ?? ""};if region.numberOfItems>0{o.region=region.titleOfSelectedItem ?? ""};if let f=customModel{o.model=f.stringValue}
        o.hotwords=hotwords.stringValue;o.vocabularyID=vocabulary.stringValue;o.correctionTableID=correction.stringValue
        if let reason=ASROptionPolicy.validate(engine,o){feedback.stringValue=reason;return}
        var maps:[LocalASRMapping]=[]
        for line in mappings.stringValue.split(separator:"\n") {let pair=line.components(separatedBy:" => ");guard pair.count==2 else{feedback.stringValue=L10n.tr("ui.bd3cc7a77ef6");return};maps.append(LocalASRMapping(source:pair[0],replacement:pair[1]))}
        guard LocalASRCorrection.valid(maps) else{feedback.stringValue=L10n.tr("ui.da8307fb02c3");return}
        let original=store.config
        guard store.mutate({$0.setOptions(engine,o);$0.localASRMappings=maps}),store.save() else{_=store.mutate{$0=original};feedback.stringValue=L10n.tr("ui.bcd8e5694934");return}
        var success=true
        for (key,field) in secure where !field.stringValue.isEmpty {if credentialWriter.set(field.stringValue,for:engine.rawValue+"."+key){field.stringValue=""}else{success=false}}
        feedback.stringValue=success ? L10n.tr("ui.508a0cf51d33"):L10n.tr("ui.ef1402ee6cd4")
        changed()
    }
    func windowWillClose(_ notification:Notification){secure.values.forEach{$0.stringValue=""}}
}
