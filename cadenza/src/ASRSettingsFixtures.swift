import AppKit

// Runs the production AppKit target/actions against isolated files and a write-only fake.
// Never constructs the application delegate, pipeline, capture, HTTP or Keychain adapters.
enum ASRSettingsFixtures {
    final class Credentials:ASRCredentialWriting {
        var values:[String:String]=[:],attempts:[String]=[],fail:Set<String>=[]
        func set(_ value:String,for key:String)->Bool {attempts.append(key);if fail.contains(key){return false};values[key]=value;return true}
    }
    static func run(_ check:(String,Bool)->Void) {
        let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("cadenza-settings-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            func canonical(_ config:BridgeConfig)->Data {let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys;return (try? encoder.encode(config)) ?? Data()}
            let url=root.appendingPathComponent("config.json")
            // Write an actual older-format file, with cloudASR/local mappings keys removed.
            var legacy=BridgeConfig.default();legacy.engine="iflytek";legacy.iflytekConsent=true;legacy.appearanceMode="dark"
            var json=try JSONSerialization.jsonObject(with:canonical(legacy)) as! [String:Any]
            json.removeValue(forKey:"cloudASR");json.removeValue(forKey:"localASRMappings")
            try JSONSerialization.data(withJSONObject:json,options:.sortedKeys).write(to:url)
            let store=ConfigStore(fileURL:url),credentials=Credentials()
            check("ASR settings legacy real file loads consent and new defaults",store.validationErrors.isEmpty && store.config.options(.iflytek).consent && store.config.options(.tencent)==CloudASROptions.defaults(.tencent) && store.config.localASRMappings.isEmpty)
            func find(_ controller:ASRSettingsController,_ id:String)->NSView? {
                func walk(_ view:NSView)->NSView? {if view.identifier?.rawValue==id{return view};for child in view.subviews{if let result=walk(child){return result}};return nil}
                return controller.window?.contentView.flatMap{walk($0)}
            }
            func field(_ c:ASRSettingsController,_ id:String)->NSTextField {find(c,id) as! NSTextField}
            func button(_ c:ASRSettingsController,_ id:String)->NSButton {find(c,"asr."+id) as! NSButton}
            func action(_ control:NSControl)->Bool {guard let selector=control.action else{return false};return app.sendAction(selector,to:control.target,from:control)}
            func save(_ c:ASRSettingsController)->Bool {action(button(c,"save"))}
            func populate(_ c:ASRSettingsController,_ engine:ASREngine) {
                button(c,"consent").state = .on
                field(c,"asr.mappings").stringValue="柚子 => 随言"
                if engine != .baidu{button(c,"punctuation").state = .on;button(c,"itn").state = .on}
                if [.volcengine,.tencent,.aliyun].contains(engine){button(c,"smoothing").state = .on}
                if engine == .volcengine {
                    (find(c,"asr.model") as! NSPopUpButton).selectItem(withTitle:"volc.seedasr.sauc.concurrent")
                    field(c,"asr.hotwords").stringValue="随言\n柚子";field(c,"asr.vocabulary").stringValue="fixture-vocabulary"
                    field(c,"asr.correction").stringValue="fixture-correction";button(c,"secondPass").state = .on
                }
                if engine == .tencent{field(c,"asr.hotwords").stringValue="随言|10"}
                if engine == .aliyun{(find(c,"asr.region") as! NSPopUpButton).selectItem(withTitle:"cn-beijing");field(c,"nls-custom-model").stringValue="fixture-model";field(c,"asr.vocabulary").stringValue="fixture-vocabulary"}
                if engine == .baidu{(find(c,"asr.model") as! NSPopUpButton).selectItem(withTitle:"1737")}
                for (key,_) in engine.credentialFields{field(c,"asr.credential."+key).stringValue="fixture-only-"+key}
            }
            var changed=0,expected:[ASREngine:CloudASROptions]=[:]
            let selector=SettingsWindowController();selector.configStore=store;selector.onConfigurationChanged={changed += 1}
            let popup=selector.enginePopup()
            for engine in ASREngine.legacyListed where engine != .apple {
                popup.selectItem(at:ASREngine.legacyListed.firstIndex(of:engine)!)
                check("ASR settings \(engine.rawValue) production selector action persists",action(popup) && ConfigStore(fileURL:url).config.engine==engine.rawValue)
                let controller=ASRSettingsController(store:store,engine:engine,busy:{false},changed:{changed += 1},credentialWriter:credentials)
                populate(controller,engine)
                check("ASR settings \(engine.rawValue) native save succeeds",save(controller) && field(controller,"asr.feedback").stringValue.hasPrefix(L10n.tr("ui.508a0cf51d33")) && engine.credentialFields.allSatisfy{field(controller,"asr.credential."+$0.0).stringValue.isEmpty})
                expected[engine]=store.config.options(engine)
                controller.close()
                let loaded=ConfigStore(fileURL:url)
                let reopened=ASRSettingsController(store:loaded,engine:engine,busy:{false},changed:{},credentialWriter:credentials)
                check("ASR settings \(engine.rawValue) close reopen reload retains all providers",loaded.reload() && expected.allSatisfy{loaded.config.options($0.key)==$0.value} && loaded.config.localASRMappings==[LocalASRMapping(source:"柚子",replacement:"随言")] && loaded.config.appearanceMode=="dark" && button(reopened,"consent").state == .on && engine.credentialFields.allSatisfy{field(reopened,"asr.credential."+$0.0).stringValue.isEmpty})
                let options=loaded.config.options(engine)
                let nativeValuesMatch=[("punctuation",options.punctuation),("itn",options.itn),("smoothing",options.smoothing),("secondPass",options.secondPass)].allSatisfy{button(reopened,$0.0).state == ($0.1 ? .on:.off)}
                    && field(reopened,"asr.mappings").stringValue=="柚子 => 随言"
                    && ((find(reopened,"asr.model") as? NSPopUpButton).map{$0.titleOfSelectedItem==options.model} ?? true)
                    && ((find(reopened,"asr.region") as? NSPopUpButton).map{$0.titleOfSelectedItem==options.region} ?? true)
                    && ((find(reopened,"asr.hotwords") as? NSTextField).map{$0.stringValue==options.hotwords} ?? true)
                    && ((find(reopened,"asr.vocabulary") as? NSTextField).map{$0.stringValue==options.vocabularyID} ?? true)
                    && ((find(reopened,"asr.correction") as? NSTextField).map{$0.stringValue==options.correctionTableID} ?? true)
                    && ((find(reopened,"nls-custom-model") as? NSTextField).map{$0.stringValue==options.model} ?? true)
                check("ASR settings \(engine.rawValue) reopened native controls match disk",nativeValuesMatch)
                check("ASR settings \(engine.rawValue) credentials use independent fake namespace",engine.credentialFields.allSatisfy{credentials.values[engine.rawValue+"."+$0.0]=="fixture-only-"+$0.0})
                let writes=credentials.attempts.count,values=credentials.values
                check("ASR settings \(engine.rawValue) blank credentials preserve existing fake values",save(reopened) && credentials.attempts.count==writes && credentials.values==values)
                if let path=CommandLine.arguments.first(where:{$0.hasPrefix("--asr-settings-evidence=")})?.dropFirst("--asr-settings-evidence=".count) {
                    let output=URL(fileURLWithPath:String(path)).appendingPathComponent(engine.rawValue)
                    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
                    try Data(contentsOf:url).write(to:output.appendingPathComponent("isolated-config-reloaded.json"),options:.atomic)
                    reopened.renderEvidence(theme:"light",outputDirectory:output)
                }
                reopened.close()
            }
            // Switching back through the actual production selector must retain each provider.
            for engine in ASREngine.legacyListed.reversed() where engine != .apple {
                popup.selectItem(at:ASREngine.legacyListed.firstIndex(of:engine)!)
                check("ASR settings \(engine.rawValue) switch back retains all options",action(popup) && store.reload() && expected.allSatisfy{store.config.options($0.key)==$0.value})
            }
            let before=try Data(contentsOf:url),memory=canonical(store.config),writes=credentials.attempts.count
            let cancelled=ASRSettingsController(store:store,engine:.tencent,busy:{false},changed:{changed += 1},credentialWriter:credentials)
            populate(cancelled,.tencent);field(cancelled,"asr.hotwords").stringValue="取消|10"
            let beforeChanges=changed
            check("ASR settings cancel action clears fields without persistence",action(button(cancelled,"cancel")) && (try? Data(contentsOf:url))==before && canonical(store.config)==memory && credentials.attempts.count==writes && changed==beforeChanges && ASREngine.tencent.credentialFields.allSatisfy{field(cancelled,"asr.credential."+$0.0).stringValue.isEmpty})
            let busy=ASRSettingsController(store:store,engine:.tencent,busy:{true},changed:{changed += 1},credentialWriter:credentials)
            populate(busy,.tencent)
            check("ASR settings busy rejects before disk credentials and notification",save(busy) && field(busy,"asr.feedback").stringValue==L10n.tr("ui.6405a2f5fe81") && (try? Data(contentsOf:url))==before && canonical(store.config)==memory && credentials.attempts.count==writes && changed==beforeChanges)
            busy.close()
            let failing=ConfigStore(fileURL:url,writeFile:{_,_ in throw CocoaError(.fileWriteNoPermission)})
            let diskFailure=ASRSettingsController(store:failing,engine:.volcengine,busy:{false},changed:{changed += 1},credentialWriter:credentials)
            populate(diskFailure,.volcengine);field(diskFailure,"asr.hotwords").stringValue="写盘失败"
            check("ASR settings disk failure rolls memory disk back before credentials",save(diskFailure) && field(diskFailure,"asr.feedback").stringValue==L10n.tr("ui.bcd8e5694934") && canonical(failing.config)==memory && (try? Data(contentsOf:url))==before && credentials.attempts.count==writes && changed==beforeChanges && failing.reload() && canonical(failing.config)==memory)
            diskFailure.close()
            let partial=ASRSettingsController(store:store,engine:.tencent,busy:{false},changed:{changed += 1},credentialWriter:credentials)
            populate(partial,.tencent)
            for (key,_) in ASREngine.tencent.credentialFields{field(partial,"asr.credential."+key).stringValue="retry-only-"+key}
            let priorFailedValue=credentials.values["tencent.secretkey"]
            credentials.fail=["tencent.secretkey"]
            check("ASR settings partial credential failure accurately reports and retains failed input",save(partial) && field(partial,"asr.feedback").stringValue.contains(L10n.tr("ui.ef1402ee6cd4")) && credentials.attempts.count==writes+3 && field(partial,"asr.credential.appid").stringValue.isEmpty && field(partial,"asr.credential.secretid").stringValue.isEmpty && field(partial,"asr.credential.secretkey").stringValue=="retry-only-secretkey" && credentials.values["tencent.secretkey"]==priorFailedValue && ConfigStore(fileURL:url).config.options(.tencent)==store.config.options(.tencent))
            credentials.fail=[]
            let successfulValues=credentials.values
            check("ASR settings retry writes only failed credential",save(partial) && credentials.attempts.count==writes+4 && credentials.attempts.last=="tencent.secretkey" && field(partial,"asr.feedback").stringValue.hasPrefix(L10n.tr("ui.508a0cf51d33")) && field(partial,"asr.credential.secretkey").stringValue.isEmpty && successfulValues.filter{$0.key != "tencent.secretkey"}.allSatisfy{credentials.values[$0.key]==$0.value} && credentials.values["tencent.secretkey"]=="retry-only-secretkey")
            let model=find(partial,"asr.model") as! NSPopUpButton
            model.selectItem(withTitle:"16k_en")
            check("ASR settings Tencent model action disables and clears unsupported options",action(model) && ["punctuation","itn","smoothing"].allSatisfy{!button(partial,$0).isEnabled && button(partial,$0).state == .off} && !button(partial,"secondPass").isEnabled)
            check("ASR settings Tencent incompatible options remain off after save reload",save(partial) && store.reload() && store.config.options(.tencent).model=="16k_en" && !store.config.options(.tencent).punctuation && !store.config.options(.tencent).itn && !store.config.options(.tencent).smoothing)
            model.selectItem(withTitle:"16k_zh")
            check("ASR settings Tencent back to Chinese enables without silently opting in",action(model) && ["punctuation","itn","smoothing"].allSatisfy{button(partial,$0).isEnabled && button(partial,$0).state == .off})
            partial.close()
            let invalid=ASRSettingsController(store:store,engine:.tencent,busy:{false},changed:{},credentialWriter:credentials)
            let invalidBefore=try Data(contentsOf:url),invalidWrites=credentials.attempts.count
            field(invalid,"asr.hotwords").stringValue="invalid"
            check("ASR settings invalid native input rejected before writes",save(invalid) && field(invalid,"asr.feedback").stringValue.contains(L10n.tr("ui.97dd62ced699")) && (try? Data(contentsOf:url))==invalidBefore && credentials.attempts.count==invalidWrites)
            invalid.close()
            check("ASR settings isolation uses temporary file only",url.path.hasPrefix(FileManager.default.temporaryDirectory.path) && url != AppPaths.configFile)
        } catch {check("ASR settings isolated fixture completed without file errors",false)}
    }
}
