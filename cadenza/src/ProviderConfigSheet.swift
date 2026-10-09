import SwiftUI
import AppKit

struct MappingDraft:Identifiable {
    let id=UUID()
    var source:String=""
    var replacement:String=""
}

@Observable
final class ProviderSettingsDraft {
    let store:ConfigStore,engine:ASREngine
    let previewReadOnly=CommandLine.arguments.contains(where:{$0.hasPrefix("--preview-brand-page=")})
    var recognitionLanguage:String
    var options:CloudASROptions
    var credentials:[String:String]=[:]
    var saved:Set<String>=[]
    /// Fields served by the secret saved for text recognition (see `SharedCredentials`), not by one of their own.
    var shared:Set<String>=[]
    var editing:Set<String>=[]
    var mappings:[MappingDraft]
    var feedback=""
    var isError=false
    var testing=false
    private let writer:ASRCredentialWriting
    private let read:(String)->String?
    private let has:(String)->Bool
    private let busy:()->Bool
    private let changed:()->Void
    private var probe:ProviderConnectionProbe?
    private var testID:UUID?
    private var credentialDeadline:DispatchWorkItem?
    init(store:ConfigStore,engine:ASREngine,busy:@escaping()->Bool,changed:@escaping()->Void,writer:ASRCredentialWriting=KeychainASRCredentialWriter(),read:@escaping(String)->String?={SharedCredentials.get($0)},has:@escaping(String)->Bool={SharedCredentials.has($0)},own:@escaping(String)->String?={KeychainStore.get($0)}){
        self.store=store;self.engine=engine;recognitionLanguage=store.config.iflytekLanguage;options=store.config.options(engine);mappings=store.config.localASRMappings.map{MappingDraft(source:$0.source,replacement:$0.replacement)};self.busy=busy;self.changed=changed;self.writer=writer;self.read=read;self.has=has
        saved=Set(engine.credentialFields.compactMap{has(engine.rawValue+"."+$0.0) ? $0.0:nil})
        shared=Set(saved.filter{(own(engine.rawValue+"."+$0) ?? "").isEmpty})
    }
    var complete:Bool{engine.credentialFields.allSatisfy{saved.contains($0.0) || !(credentials[$0.0] ?? "").isEmpty}}
    var canSave:Bool{complete || (store.config.options(engine).consent && !options.consent)}
    var supportsOptions:Bool{engine.hasTextSwitches && (engine != .tencent || CloudASROptions.tencentTextModels.contains(options.model)) && (engine != .iflytek || recognitionLanguage != "en_us")}
    func fail(_ key:String){feedback=L10n.tr(key);isError=true}
    @discardableResult func save()->Bool {
        guard !previewReadOnly else{return false}
        guard !busy(),!testing else{fail("ui.6405a2f5fe81");return false}
        guard canSave else{fail("provider.missing");return false}
        if engine == .tencent && !supportsOptions {options.punctuation=false;options.itn=false;options.smoothing=false}
        if let reason=ASROptionPolicy.validate(engine,options){feedback=reason;isError=true;return false}
        let maps=mappings.filter{!$0.source.isEmpty || !$0.replacement.isEmpty}.map{LocalASRMapping(source:$0.source,replacement:$0.replacement)}
        guard LocalASRCorrection.valid(maps) else{fail("ui.da8307fb02c3");return false}
        let original=store.config
        guard store.mutate({$0.setOptions(engine,options);$0.localASRMappings=maps;if engine == .iflytek{$0.iflytekLanguage=recognitionLanguage;if recognitionLanguage != "auto"{$0.recognitionLocale=recognitionLanguage == "en_us" ? "en-US":"zh-CN"}}}),store.save() else{_=store.mutate{$0=original};fail("ui.bcd8e5694934");return false}
        var failures=false
        for (key,_) in engine.credentialFields {
            guard let value=credentials[key],!value.isEmpty else{continue}
            if writer.set(value,for:engine.rawValue+"."+key){credentials[key]="";saved.insert(key);shared.remove(key);editing.remove(key)}else{failures=true}
        }
        changed()
        if failures{fail("provider.partial");return false}
        feedback=L10n.tr("provider.saved");isError=false;return true
    }
    func cancel(){testID=nil;credentialDeadline?.cancel();credentialDeadline=nil;probe?.cancel();probe=nil;testing=false;credentials.removeAll();editing.removeAll()}
    /// Explicit click only; no recorder or audio source is created.
    func test(socketFactory:@escaping()->ASRSocket={NativeASRSocket()},http:ASRHTTP=NativeASRHTTP(),credentialTimeout:TimeInterval=15) {
        guard !previewReadOnly else{fail("provider.testPreview");return}
        guard !testing else{return}
        guard !busy() else{fail("ui.6405a2f5fe81");return}
        guard options.consent else{fail("provider.testConsent");return}
        guard complete else{fail("provider.missing");return}
        if let reason=ASROptionPolicy.validate(engine,options){feedback=reason;isError=true;return}
        let id=UUID(),engine=engine,options=options,input=credentials,read=read
        testID=id;testing=true;feedback=L10n.tr("provider.testPreparing");isError=false
        let deadline=DispatchWorkItem{[weak self] in
            guard let self,self.testID==id else{return}
            self.testID=nil;self.credentialDeadline=nil;self.testing=false;self.fail("provider.testCredentialTimeout")
        }
        credentialDeadline=deadline
        DispatchQueue.main.asyncAfter(deadline:.now()+credentialTimeout,execute:deadline)
        // Keychain reads must not block rendering, cancellation or the timeout feedback.
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            var values:[String:String]=[:]
            for (key,_) in engine.credentialFields {
                guard let value=input[key].flatMap({$0.isEmpty ? nil:$0}) ?? read(engine.rawValue+"."+key),!value.isEmpty else{break}
                values[key]=value
            }
            let resolved=values
            DispatchQueue.main.async { [weak self] in
                guard let self,self.testID==id else{return}
                self.credentialDeadline?.cancel();self.credentialDeadline=nil
                guard resolved.count==engine.credentialFields.count else{self.testID=nil;self.testing=false;self.fail("provider.keychain");return}
                self.feedback=L10n.tr("provider.testing")
                let current=ProviderConnectionProbe(engine:engine,options:options,credentials:resolved,socketFactory:socketFactory,http:http)
                self.probe=current
                current.start{[weak self,weak current] ok in DispatchQueue.main.async{
                    guard let self,let current,self.testID==id,self.probe === current else{return}
                    self.testID=nil;self.testing=false;self.probe=nil;self.isError = !ok
                    self.feedback=L10n.tr(ok ? "provider.testPassed":"provider.testFailed")
                }}
            }
        }
    }

}

enum ProviderSheetLayout {
    static func height(parentHeight:CGFloat,screenHeight:CGFloat)->CGFloat {
        let parent=parentHeight.isFinite && parentHeight>0 ? parentHeight:560
        let screen=screenHeight.isFinite && screenHeight>0 ? screenHeight:900
        return max(240,min(700,parent-24,screen-120))
    }
}

struct ProviderConfigSheet:View {
    @State private var draft:ProviderSettingsDraft
    @Environment(\.dismiss) private var dismiss
    var availableHeight:CGFloat=536
    init(store:ConfigStore,engine:ASREngine,busy:@escaping()->Bool,changed:@escaping()->Void){_draft=State(initialValue:ProviderSettingsDraft(store:store,engine:engine,busy:busy,changed:changed))}
    init(draft:ProviderSettingsDraft,availableHeight:CGFloat=536){_draft=State(initialValue:draft);self.availableHeight=availableHeight}
    var engine:ASREngine{draft.engine}
    var body:some View {
        VStack(spacing:0){
            HStack{Text(L10n.format("provider.title",engine.title)).font(.title3.weight(.semibold));Spacer()}.padding(20)
            Divider()
            Form {
                Section {
                    VStack(alignment:.leading,spacing:10){
                        ForEach(0..<3,id:\.self){index in HStack(alignment:.top){Text("\(index+1).").monospacedDigit().foregroundStyle(.secondary);Text(L10n.tr((engine == .deepgram ? "deepgram.step.":BatchTranscription.service(engine) != nil ? "batch.step.":"provider.step.")+String(index+1)))}}
                        if let url=ProviderConnectionProbe.consoleURL(engine){Link(destination:url){Label(L10n.tr("provider.console."+engine.rawValue),systemImage:"arrow.up.right.square")}.buttonStyle(.borderedProminent)}
                        if let url=ProviderHelp.credentialGuideURL(engine:engine,language:L10n.language){
                            Link(destination:url){Label(L10n.tr("provider.credentialGuide"),systemImage:"book")}.buttonStyle(.bordered)
                        }
                    }.padding(.vertical,4)
                } header:{Text(L10n.tr("provider.getCredentials"))}
                Section {
                    ForEach(engine.credentialFields,id:\.0){key,name in
                        LabeledContent(name){
                            if draft.saved.contains(key) && !draft.editing.contains(key){
                                HStack{Text(L10n.tr(draft.shared.contains(key) ? "provider.sharedSecret":"provider.savedSecret")).foregroundStyle(.secondary);Button(L10n.tr("provider.replace")){draft.editing.insert(key)}.buttonStyle(.bordered)}
                            } else {
                                SecureField(L10n.tr(draft.saved.contains(key) ? "provider.replaceHint":"provider.required"),text:Binding(get:{draft.credentials[key] ?? ""},set:{draft.credentials[key]=$0})).textFieldStyle(.roundedBorder).frame(width:270).accessibilityLabel(name)
                            }
                        }
                    }
                    HStack {
                        Button(L10n.tr("provider.test")){draft.test()}.buttonStyle(.bordered).disabled(draft.testing)
                        if draft.testing{ProgressView().controlSize(.small)}
                    }
                    if !draft.feedback.isEmpty {
                        Text(draft.feedback).font(.callout).foregroundStyle(draft.isError ? Color.orange:.primary)
                            .frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)
                    }
                } header:{Text(L10n.tr("provider.credentials"))} footer:{VStack(alignment:.leading,spacing:6){Label(L10n.tr("provider.localKeychain"),systemImage:"lock");Text(L10n.tr("provider.testExplanation"));if !draft.options.consent {Text(L10n.tr("provider.testConsent"))}}.font(.callout).foregroundStyle(.primary)}
                Section {
                    Toggle(L10n.format("provider.consent",engine == .compat ? BatchTranscription.destination(engine,draft.options):engine.title),isOn:$draft.options.consent)
                    VStack(alignment:.leading,spacing:8){
                        Text(L10n.tr("provider.privacy.streaming"))
                        Text(L10n.tr("provider.privacy.irrevocable")).fontWeight(.semibold)
                        Text(L10n.tr("provider.privacy.whole"))
                    }.font(.callout).foregroundStyle(.primary)
                } header:{Text(L10n.tr("provider.uploadAuthorization"))}
                Section {
                    optionsView
                } header:{Text(L10n.tr("provider.options"))}
            }.formStyle(.grouped).frame(minHeight:0,maxHeight:.infinity).disabled(draft.testing)
            Divider()
            HStack {
                if !draft.feedback.isEmpty{Text(draft.feedback).font(.callout).foregroundStyle(draft.isError ? Color.orange:.primary).lineLimit(3).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)}
                Spacer()
                Button(L10n.tr("action.cancel")){draft.cancel();dismiss()}.keyboardShortcut(.cancelAction).fixedSize()
                Button(L10n.tr("action.save")){if draft.save(){dismiss()}}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).fixedSize().disabled(!draft.canSave || draft.testing)
            }.padding(16)
        }.frame(width:640,height:availableHeight).tint(Color(nsColor:.controlAccentColor)).onDisappear{draft.cancel()}
        .onChange(of:draft.options.consent){_,_ in draft.feedback=""}
        .onChange(of:draft.credentials){_,_ in draft.feedback=""}
    }
    @ViewBuilder private var optionsView:some View {
        if engine == .deepgram {
            LabeledContent(L10n.tr("provider.model"),value:"Nova-3")
            Picker(L10n.tr("provider.language"),selection:$draft.options.language) {
                ForEach(DeepgramAPI.languages,id:\.self) {code in
                    Text(code == "multi" ? L10n.tr("deepgram.multilingual"):Locale(identifier:L10n.language).localizedString(forIdentifier:code) ?? code).tag(code)
                }
            }
            Text(L10n.tr("deepgram.languageHint")).font(.callout)
        }
        if engine == .compat {
            Picker(L10n.tr("compat.preset"),selection:Binding(get:{BatchTranscription.preset(forBaseURL:draft.options.baseURL)?.id ?? ""},set:{id in if let p=BatchTranscription.compatPresets.first(where:{$0.id==id}){draft.options.baseURL=p.baseURL;draft.options.model=p.model}})){
                Text(L10n.tr("compat.preset.other")).tag("")
                ForEach(BatchTranscription.compatPresets){Text($0.title).tag($0.id)}
            }
            TextField(L10n.tr("compat.baseURL"),text:$draft.options.baseURL,prompt:Text("https://api.example.com/v1"))
            TextField(L10n.tr("provider.model"),text:$draft.options.model)
            Text(L10n.tr("compat.hint")).font(.callout)
        }
        if let service=BatchTranscription.service(engine) {
            if engine != .compat {Picker(L10n.tr("provider.model"),selection:$draft.options.model){ForEach(service.models,id:\.self){Text($0).tag($0)}}}
            Picker(L10n.tr("provider.language"),selection:$draft.options.language){
                ForEach(BatchTranscription.languages,id:\.self){code in Text(code == "multi" ? L10n.tr("batch.language.auto"):Locale(identifier:L10n.language).localizedString(forIdentifier:code) ?? code).tag(code)}
            }
            Text(L10n.tr("batch.languageHint")).font(.callout)
            TextField(L10n.tr("provider.hotwords"),text:$draft.options.hotwords).help(L10n.tr("batch.hotwords.placeholder"))
        }
        if engine == .iflytek {
            Picker(L10n.tr("provider.language"),selection:$draft.recognitionLanguage){Text(L10n.tr("language.chinese")).tag("zh_cn");Text(L10n.tr("language.english")).tag("en_us");Text(L10n.tr("language.auto")).tag("auto")}
        }
        if engine == .volcengine {
            Picker(L10n.tr("provider.model"),selection:$draft.options.model){ForEach(["volc.seedasr.sauc.duration","volc.seedasr.sauc.concurrent","volc.bigasr.sauc.duration","volc.bigasr.sauc.concurrent"],id:\.self){Text($0).tag($0)}}
        }
        if engine == .tencent {
            Picker(L10n.tr("provider.language"),selection:$draft.options.model){Text(L10n.tr("language.chinese")).tag("16k_zh");Text(L10n.tr("language.english")).tag("16k_en");Text(L10n.tr("language.bilingual")).tag("16k_zh_en")}
        }
        if engine == .aliyun {
            Picker(L10n.tr("provider.region"),selection:$draft.options.region){ForEach(["cn-shanghai","cn-beijing","cn-shenzhen"],id:\.self){Text($0).tag($0)}}
            TextField(L10n.tr("provider.customModel"),text:$draft.options.model)
        }
        if engine == .baidu {
            Picker(L10n.tr("provider.language"),selection:$draft.options.model){Text(L10n.tr("language.chinese")).tag("1537");Text(L10n.tr("language.english")).tag("1737");Text(L10n.tr("language.cantonese")).tag("1637");Text(L10n.tr("language.sichuan")).tag("1837")}
        }
        if draft.supportsOptions {
            Toggle(L10n.tr("provider.punctuation"),isOn:$draft.options.punctuation)
            Toggle(L10n.tr("provider.numbers"),isOn:$draft.options.itn)
            if [.volcengine,.tencent,.aliyun].contains(engine){Toggle(L10n.tr("provider.smoothing"),isOn:$draft.options.smoothing)}
        }
        if engine == .volcengine {Toggle(L10n.tr("provider.secondPass"),isOn:$draft.options.secondPass)}
        if [.volcengine,.tencent].contains(engine){TextField(L10n.tr("provider.hotwords"),text:$draft.options.hotwords).help(L10n.tr(engine == .tencent ? "ui.97dd62ced699":"ui.569e55f7a013"))}
        if [.volcengine,.aliyun,.baidu].contains(engine){TextField(L10n.tr("provider.vocabulary"),text:$draft.options.vocabularyID)}
        if engine == .volcengine {TextField(L10n.tr("provider.correction"),text:$draft.options.correctionTableID)}
    }
}
