import Foundation

enum SettingsUIFixtures {
    final class Writer:ASRCredentialWriting {
        var attempts:[String]=[],values:[String:String]=[:],fail:Set<String>=[]
        func set(_ value:String,for key:String)->Bool{attempts.append(key);guard !fail.contains(key) else{return false};values[key]=value;return true}
    }
    final class Socket:ASRSocket {
        var opened:(()->Void)?,received:((URLSessionWebSocketTask.Message)->Void)?,failed:(()->Void)?,authRejected:(()->Void)?
        var connections=0,sends=0,closed=0
        var autoOpen=true
        func connect(_ request:URLRequest){connections+=1;if autoOpen{opened?()}}
        func send(_ message:URLSessionWebSocketTask.Message,completion:@escaping(Bool)->Void){sends+=1;completion(true)}
        func close(){closed+=1}
    }
    final class HTTP:ASRHTTP {
        var calls=0,cancelled=0,data=Data()
        func request(_ request:URLRequest,completion:@escaping(Result<Data,Error>)->Void){calls+=1;completion(.success(data))}
        func cancel(){cancelled+=1}
    }
    static func run(_ check:(String,Bool)->Void){
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("settings-fixture-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("config.json")
        let store=ConfigStore(fileURL:url),writer=Writer()
        let pipeline = VoicePipeline(configStore: store, input: InputSourceController())
        pipeline.selfTestMode = true
        let settings = SettingsModel(store: store, pipeline: pipeline)
        let entries = LocalModelCatalog.builtin.filter { LocalModelCatalog.usable($0) }
        if LocalTranscriberLoader.supported, entries.count >= 2 {
            _ = store.mutate { $0.engine = ASREngine.iflytek.rawValue; $0.localModel.modelID = entries[1].id }
            _ = store.save(); settings.sync()
            settings.selectLocalModel(entries[0].id, ready: entries)
            check("local primary selection persists without changing cloud backup", store.config.engine == ASREngine.local.rawValue && store.config.localModel.primaryModelID == entries[0].id && store.config.localModel.modelID == entries[1].id)
            settings.persist { $0.localModel.modelID = entries[0].id }
            check("backup selection retains primary engine and model", store.config.engine == ASREngine.local.rawValue && store.config.localModel.primaryModelID == entries[0].id)
            settings.listening = true
            settings.selectLocalModel(entries[1].id, ready: entries)
            check("recording blocks primary model changes", store.config.localModel.primaryModelID == entries[0].id)
            settings.listening = false
            settings.selectLocalModel("not-installed", ready: entries)
            check("unavailable local primary cannot be selected", store.config.localModel.primaryModelID == entries[0].id)
            let reloaded = ConfigStore(fileURL: url)
            check("primary and backup survive configuration reload independently", reloaded.config.engine == ASREngine.local.rawValue && reloaded.config.localModel.primaryModelID == entries[0].id && reloaded.config.localModel.modelID == entries[0].id)
        }
        // Recognition method picker: choosing a method switches the real engine when it can.
        _ = store.mutate { $0.engine = ASREngine.iflytek.rawValue }; _ = store.save(); settings.sync()
        settings.chooseScope(.system)
        check("method picker: system switches to Apple and clears pending", store.config.engine == ASREngine.apple.rawValue && !settings.pendingLocalActivation && settings.scope == .system)
        let installedNow = LocalModelCenter.shared.installedEntries.contains { LocalModelCatalog.usable($0) }
        if LocalTranscriberLoader.supported, !installedNow, let first = entries.first {
            settings.chooseScope(.local)
            check("method picker: local without a model waits instead of switching", store.config.engine == ASREngine.apple.rawValue && settings.pendingLocalActivation && settings.scope == .local)
            settings.activatePendingLocal(ready: [])
            check("method picker: nothing installed keeps waiting", settings.pendingLocalActivation && store.config.engine == ASREngine.apple.rawValue)
            settings.activatePendingLocal(ready: [first])
            check("method picker: installing the model turns local on by itself", store.config.engine == ASREngine.local.rawValue && store.config.localModel.primaryModelID == first.id && !settings.pendingLocalActivation)
            settings.chooseScope(.system)
            check("method picker: leaving local returns to system recognition", store.config.engine == ASREngine.apple.rawValue)
            settings.chooseScope(.local); settings.chooseScope(.system)
            settings.activatePendingLocal(ready: [first])
            check("method picker: choosing another method cancels the pending switch", store.config.engine == ASREngine.apple.rawValue && !settings.pendingLocalActivation)
        }
        if LocalTranscriberLoader.supported, installedNow {
            settings.chooseScope(.local)
            check("method picker: local with an installed model switches immediately", store.config.engine == ASREngine.local.rawValue && !store.config.localModel.primaryModelID.isEmpty && !settings.pendingLocalActivation)
            settings.chooseScope(.system)
            check("method picker: leaving local returns to system recognition (installed)", store.config.engine == ASREngine.apple.rawValue)
        }
        settings.listening = true
        settings.chooseScope(.local)
        check("method picker: recording blocks switching engines", store.config.engine == ASREngine.apple.rawValue && !settings.pendingLocalActivation)
        settings.listening = false
        settings.scope = .system
        // "Only recognize on this Mac" lock
        let lockDefaults = UserDefaults.standard, savedLock = lockDefaults.object(forKey: "localOnlyMode")
        defer { if let savedLock = savedLock { lockDefaults.set(savedLock, forKey: "localOnlyMode") } else { lockDefaults.removeObject(forKey: "localOnlyMode") } }
        lockDefaults.removeObject(forKey: "localOnlyMode")
        check("lock: off by default", !LocalOnlyMode.enabled && !settings.localOnlyOn)
        _ = store.mutate { $0.engine = ASREngine.iflytek.rawValue; $0.allowCloudRecognition = true }; _ = store.save(); settings.sync()
        let hasModel = LocalModelCenter.shared.installedEntries.contains { LocalModelCatalog.usable($0) }
        if LocalTranscriberLoader.supported && !hasModel {
            settings.setLocalOnly(true)
            check("lock: refused without a local model, with a reason", !LocalOnlyMode.enabled && !settings.localOnlyOn && !settings.localOnlyMessage.isEmpty && store.config.engine == ASREngine.iflytek.rawValue)
        }
        LocalOnlyMode.enabled = true; settings.sync()
        settings.chooseScope(.cloud)
        check("lock: cloud and system cannot be chosen while locked", store.config.engine == ASREngine.iflytek.rawValue && settings.scope != .cloud)
        settings.selectEngine(.baidu)
        check("lock: provider rows cannot switch the engine while locked", store.config.engine == ASREngine.iflytek.rawValue)
        pipeline.holdStarted(source: .menu, localOnly: true)
        check("lock: the pipeline refuses a cloud engine and starts no recorder", pipeline.session == nil && pipeline.lastIsError && pipeline.lastResult == L10n.tr("localonly.blocked"))
        let updatesOff = UpdateChecker(); updatesOff.repository = "owner/repo"; var lockedRequests = 0
        updatesOff.fetch = { (_: URL, done: @escaping (Result<Data, Error>) -> Void) in lockedRequests += 1; done(.failure(URLError(.cancelled))) }
        let savedAutoUpdates = lockDefaults.object(forKey: "autoCheckAppUpdates"); lockDefaults.set(true, forKey: "autoCheckAppUpdates"); lockDefaults.removeObject(forKey: "lastAppUpdateCheck")
        updatesOff.checkOnLaunchIfDue()
        if let savedAutoUpdates = savedAutoUpdates { lockDefaults.set(savedAutoUpdates, forKey: "autoCheckAppUpdates") } else { lockDefaults.removeObject(forKey: "autoCheckAppUpdates") }
        check("lock: no automatic update check while locked", lockedRequests == 0)
        settings.setLocalOnly(false)
        check("lock: can be turned off", !LocalOnlyMode.enabled && !settings.localOnlyOn)
        if LocalTranscriberLoader.supported, hasModel {
            settings.setLocalOnly(true)
            check("lock: turning on switches to local and stops Apple cloud use", LocalOnlyMode.enabled && store.config.engine == ASREngine.local.rawValue && !store.config.allowCloudRecognition && settings.scope == .local)
            settings.setLocalOnly(false)
        }
        _ = store.mutate { $0.engine = ASREngine.apple.rawValue }; _ = store.save(); settings.sync(); settings.scope = .system

        // First-run wizard model
        let wizardDefaults = UserDefaults.standard
        let savedTerms = wizardDefaults.object(forKey: "acceptedLegalVersion"), savedLanguage = wizardDefaults.object(forKey: "appLanguage")
        defer {
            if let savedTerms = savedTerms { wizardDefaults.set(savedTerms, forKey: "acceptedLegalVersion") } else { wizardDefaults.removeObject(forKey: "acceptedLegalVersion") }
            if let savedLanguage = savedLanguage { wizardDefaults.set(savedLanguage, forKey: "appLanguage") } else { wizardDefaults.removeObject(forKey: "appLanguage") }
        }
        TermsAcceptance.revoke()
        let wizard = OnboardingModel(store: store, pipeline: pipeline, termsOnly: false)
        check("wizard: five steps starting at the welcome page", wizard.steps == [.welcome, .privacy, .permissions, .method, .ready] && wizard.step == .welcome && wizard.canContinue)
        wizard.next()
        check("wizard: welcome moves to privacy", wizard.step == .privacy)
        check("wizard: privacy cannot continue without agreeing", !wizard.canContinue && !TermsAcceptance.accepted)
        wizard.next()
        check("wizard: continuing without agreeing neither advances nor records acceptance", wizard.step == .privacy && !TermsAcceptance.accepted)
        wizard.termsChecked = true
        check("wizard: ticking the box enables continue", wizard.canContinue)
        wizard.next()
        check("wizard: agreeing records the accepted version and advances", TermsAcceptance.accepted && wizard.step == .permissions)
        wizard.back()
        check("wizard: back returns to the previous step", wizard.step == .privacy)
        TermsAcceptance.revoke()
        let termsOnly = OnboardingModel(store: store, pipeline: pipeline, termsOnly: true)
        var finished = 0
        termsOnly.onDone = { finished += 1 }
        check("wizard: terms-only has the privacy step alone, unchecked", termsOnly.steps == [.privacy] && termsOnly.isLast && !termsOnly.termsChecked && !termsOnly.canContinue)
        termsOnly.next()
        check("wizard: terms-only cannot finish without agreeing", finished == 0 && !TermsAcceptance.accepted)
        termsOnly.termsChecked = true; termsOnly.next()
        check("wizard: terms-only agreeing finishes and records acceptance", finished == 1 && TermsAcceptance.accepted)
        let revision = wizard.languageRevision
        AppLanguage.current = .en
        AppLanguage.current = .zhHans
        check("wizard: changing the language refreshes the wizard", wizard.languageRevision >= revision + 2)
        wizard.step = .ready
        check("wizard: the last step finishes instead of advancing", wizard.isLast)
        AppLanguage.current = .system

        var changed=0,reads=0
        let draft=ProviderSettingsDraft(store:store,engine:.iflytek,busy:{false},changed:{changed+=1},writer:writer,read:{_ in reads+=1;return "fixture-existing"},has:{_ in true})
        check("saved credentials are metadata-only and masked",reads==0 && draft.credentials.isEmpty && draft.saved.count==3)
        draft.options.punctuation=true;draft.options.consent=true;draft.mappings=[MappingDraft(source:"柚子",replacement:"随言")]
        check("save keeps existing credentials and mappings",draft.save() && reads==0 && writer.attempts.isEmpty && store.config.options(.iflytek).punctuation && store.config.localASRMappings.count==1 && changed==1)
        draft.options.consent=false
        check("withdraw upload consent can be saved",draft.save() && !store.config.options(.iflytek).consent)
        draft.recognitionLanguage="en_us"
        check("IAT language saves without exposing credentials",draft.save() && store.config.iflytekLanguage=="en_us" && store.config.recognitionLocale=="en-US" && !draft.supportsOptions && reads==0)
        let noConsentSocket=Socket(),noConsentHTTP=HTTP();draft.test(socketFactory:{noConsentSocket},http:noConsentHTTP)
        check("no consent blocks secret reads and network",reads==0 && noConsentSocket.connections==0 && noConsentHTTP.calls==0 && !draft.testing)
        var busy=true
        let blocked=ProviderSettingsDraft(store:store,engine:.iflytek,busy:{busy},changed:{changed+=1},writer:writer,has:{_ in true})
        let before=try? Data(contentsOf:url);blocked.options.punctuation=false
        check("recording blocks save before writes",!blocked.save() && (try? Data(contentsOf:url))==before && writer.attempts.isEmpty)
        busy=false
        let failing=ConfigStore(fileURL:url,writeFile:{_,_ in throw CocoaError(.fileWriteNoPermission)})
        let rollback=ProviderSettingsDraft(store:failing,engine:.iflytek,busy:{false},changed:{changed+=1},writer:writer,has:{_ in true});rollback.options.punctuation=false;let original=failing.config.options(.iflytek)
        check("disk failure restores memory and retains disk",!rollback.save() && failing.config.options(.iflytek)==original && (try? Data(contentsOf:url))==before && writer.attempts.isEmpty)
        let partial=ProviderSettingsDraft(store:store,engine:.tencent,busy:{false},changed:{},writer:writer,has:{_ in false})
        partial.credentials=["appid":"fixture-app","secretid":"fixture-id","secretkey":"fixture-secret"];writer.fail=["tencent.secretkey"]
        check("partial credential failure retains only failed input",!partial.save() && partial.credentials["secretkey"]=="fixture-secret" && partial.credentials["appid"]=="" && partial.saved==Set(["appid","secretid"]))
        writer.fail=[];let attempts=writer.attempts.count
        check("retry writes only the failed credential",partial.save() && writer.attempts.count==attempts+1 && partial.credentials["secretkey"]=="")
        partial.credentials["secretkey"]="draft-only";partial.cancel()
        check("cancel clears unsaved credential inputs",partial.credentials.isEmpty)
        let incomplete=ProviderSettingsDraft(store:store,engine:.baidu,busy:{false},changed:{},writer:writer,has:{_ in false})
        let savedBefore=try? Data(contentsOf:url)
        check("missing credentials block saving",!incomplete.save() && (try? Data(contentsOf:url))==savedBefore)
        var allowed=CloudASROptions.defaults(.baidu);allowed.consent=true;_=store.mutate{$0.setOptions(.baidu,allowed)};_=store.save()
        let revoke=ProviderSettingsDraft(store:store,engine:.baidu,busy:{false},changed:{},writer:writer,has:{_ in false});revoke.options.consent=false
        check("consent can be withdrawn after credentials are missing",revoke.canSave && revoke.save() && !store.config.options(.baidu).consent)
        for engine in ASREngine.legacyListed where engine != .apple {
            var options=CloudASROptions.defaults(engine);options.consent=true
            let credentials=Dictionary(uniqueKeysWithValues:engine.credentialFields.map{($0.0,"fixture-"+$0.0)})
            let socket=Socket(),http=HTTP();http.data=Data((engine == .aliyun ? "{\"Token\":{\"Id\":\"fixture-token\",\"ExpireTime\":4102444800}}":"{\"access_token\":\"fixture-token\",\"expires_in\":3600}").utf8)
            let probe=ProviderConnectionProbe(engine:engine,options:options,credentials:credentials,socketFactory:{socket},http:http);var outcomes:[Bool]=[];probe.start{outcomes.append($0)}
            for _ in 0..<6{probe.synchronizeForTests()}
            check("\(engine.rawValue) explicit check completes using fake transports",outcomes==[true] && socket.connections==(engine == .baidu ? 0:1) && http.calls==([.aliyun,.baidu].contains(engine) ? 1:0))
            check("\(engine.rawValue) test sends no audio or protocol frame",socket.sends==0)
            socket.failed?();probe.synchronizeForTests();probe.expireForTests()
            check("\(engine.rawValue) late failure cannot change completed result",outcomes==[true])
            options.consent=false;let blockedSocket=Socket(),blockedHTTP=HTTP();let blockedProbe=ProviderConnectionProbe(engine:engine,options:options,credentials:credentials,socketFactory:{blockedSocket},http:blockedHTTP)
            var rejected=false;blockedProbe.start{rejected = !$0};blockedProbe.synchronizeForTests()
            check("\(engine.rawValue) denied consent has zero connections",rejected && blockedSocket.connections==0 && blockedHTTP.calls==0 && blockedSocket.sends==0)
        }
        var probeOptions=CloudASROptions.defaults(.iflytek);probeOptions.consent=true
        let delayed=Socket();delayed.autoOpen=false
        let cancellable=ProviderConnectionProbe(engine:.iflytek,options:probeOptions,credentials:["appid":"fixture","apikey":"fixture","apisecret":"fixture"],socketFactory:{delayed},http:HTTP());var cancelledOutcomes:[Bool]=[]
        cancellable.start{cancelledOutcomes.append($0)};cancellable.synchronizeForTests();cancellable.cancel();cancellable.synchronizeForTests();delayed.opened?();cancellable.synchronizeForTests()
        check("dismiss cancels test and ignores late socket opening",cancelledOutcomes.isEmpty && delayed.closed==1 && delayed.sends==0)
        let timeoutSocket=Socket();timeoutSocket.autoOpen=false
        let expiring=ProviderConnectionProbe(engine:.iflytek,options:probeOptions,credentials:["appid":"fixture","apikey":"fixture","apisecret":"fixture"],socketFactory:{timeoutSocket},http:HTTP());var timeoutOutcomes:[Bool]=[]
        expiring.start{timeoutOutcomes.append($0)};expiring.synchronizeForTests();expiring.expireForTests();timeoutSocket.opened?();expiring.synchronizeForTests()
        check("connection timeout ends once without audio",timeoutOutcomes==[false] && timeoutSocket.sends==0 && timeoutSocket.closed==1)
        let responsiveSocket=Socket(),responsiveHTTP=HTTP()
        let responsive=ProviderSettingsDraft(store:store,engine:.iflytek,busy:{false},changed:{},writer:writer,read:{_ in "fixture"},has:{_ in true})
        responsive.options.consent=true
        responsive.test(socketFactory:{responsiveSocket},http:responsiveHTTP)
        check("test immediately renders pending feedback before credentials resolve",responsive.testing && !responsive.feedback.isEmpty)
        LocalAPIFixtures.spin(2){!responsive.testing}
        check("draft publishes successful connection feedback",!responsive.testing && !responsive.isError && responsive.feedback==L10n.tr("provider.testPassed") && responsiveSocket.connections==1 && responsiveSocket.sends==0)
        let unreadable=ProviderSettingsDraft(store:store,engine:.iflytek,busy:{false},changed:{},writer:writer,read:{_ in nil},has:{_ in true});unreadable.options.consent=true
        let unreadableSocket=Socket();unreadable.test(socketFactory:{unreadableSocket},http:HTTP());LocalAPIFixtures.spin(2){!unreadable.testing}
        check("unreadable saved credentials report an actionable error without connection",unreadable.isError && unreadable.feedback==L10n.tr("provider.keychain") && unreadableSocket.connections==0)
        let gate=DispatchSemaphore(value:0),waitingSocket=Socket()
        let waiting=ProviderSettingsDraft(store:store,engine:.iflytek,busy:{false},changed:{},writer:writer,read:{_ in _=gate.wait(timeout:.now()+2);return "fixture"},has:{_ in true});waiting.options.consent=true
        waiting.test(socketFactory:{waitingSocket},http:HTTP(),credentialTimeout:0.02)
        LocalAPIFixtures.spin(1){!waiting.testing}
        check("credential read timeout releases UI and reports error",!waiting.testing && waiting.isError && waiting.feedback==L10n.tr("provider.testCredentialTimeout"))
        for _ in 0..<3 {gate.signal()};LocalAPIFixtures.spin(0.15)
        check("late credentials after timeout never open a connection",waitingSocket.connections==0)
        let cancelGate=DispatchSemaphore(value:0),pendingSocket=Socket()
        let pending=ProviderSettingsDraft(store:store,engine:.iflytek,busy:{false},changed:{},writer:writer,read:{_ in _=cancelGate.wait(timeout:.now()+2);return "fixture"},has:{_ in true});pending.options.consent=true
        pending.test(socketFactory:{pendingSocket},http:HTTP());pending.cancel();for _ in 0..<3{cancelGate.signal()};LocalAPIFixtures.spin(0.15)
        check("dismiss during credential read ignores late completion",!pending.testing && pendingSocket.connections==0)
        let missingTest=ProviderSettingsDraft(store:store,engine:.iflytek,busy:{false},changed:{},writer:writer,has:{_ in false});missingTest.options.consent=true;missingTest.test(socketFactory:{Socket()},http:HTTP())
        check("click with missing credentials explains the prerequisite",missingTest.isError && missingTest.feedback==L10n.tr("provider.missing"))
        busy=true;blocked.test(socketFactory:{Socket()},http:HTTP())
        check("busy test click explains recording prerequisite",blocked.isError && blocked.feedback==L10n.tr("ui.6405a2f5fe81"));busy=false
        func readiness(_ flag:SettingsReadiness?=nil,system:Bool=true)->SettingsReadiness{SettingsReadiness.evaluate(microphone:flag != .microphone,speech:flag != .speech,accessibility:flag != .accessibility,monitoring:flag != .monitoring,configured:flag != .credentials,consent:flag != .consent,engineAvailable:flag != .unavailable,shortcutEnabled:flag != .shortcut,systemEngine:system)}
        check("ready means all prerequisites pass",readiness() == .ready)
        for flag:SettingsReadiness in [.microphone,.speech,.accessibility,.monitoring,.credentials,.consent,.unavailable,.shortcut]{check("readiness explains \(flag.rawValue)",readiness(flag) == flag)}
        check("cloud engines do not require Apple speech permission",readiness(.speech,system:false) == .ready)
        let invalidHTTP=HTTP(),invalidSocket=Socket();invalidHTTP.data=Data("{}".utf8);var options=CloudASROptions.defaults(.aliyun);options.consent=true
        let invalid=ProviderConnectionProbe(engine:.aliyun,options:options,credentials:["appkey":"fixture","accesskeyid":"fixture","accesskeysecret":"fixture"],socketFactory:{invalidSocket},http:invalidHTTP);var rejected=false;invalid.start{rejected = !$0};for _ in 0..<4{invalid.synchronizeForTests()}
        check("invalid token response stops before websocket",rejected && invalidSocket.connections==0)
    }
}
