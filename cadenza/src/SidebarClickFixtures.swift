import AppKit

/// Sends real mouse events through the settings window and checks that the sidebar rows change the page.
enum SidebarClickFixtures {
    static func find<T:NSView>(_ root:NSView?,_ type:T.Type)->T? {
        guard let root=root else{return nil};if let hit=root as? T{return hit}
        for child in root.subviews{if let hit=find(child,type){return hit}};return nil
    }
    static func pump(_ seconds:TimeInterval){let end=Date(timeIntervalSinceNow:seconds);repeat{RunLoop.main.run(until:Date(timeIntervalSinceNow:0.02))}while Date()<end}
    /// Delivers a click straight to the list's own mouse handling, so the result does not depend on whether macOS lets this
    /// test process become the active app. The mouse-up is queued first because the list tracks the click until it arrives.
    static func click(_ window:NSWindow,at point:NSPoint,on table:NSView){
        func event(_ type:NSEvent.EventType)->NSEvent?{NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)}
        guard let down=event(.leftMouseDown),let up=event(.leftMouseUp) else{return}
        NSApp.postEvent(up,atStart:false)
        table.mouseDown(with:down)
        pump(0.15)
    }
    static func run(_ check:(String,Bool)->Void){
        let app=NSApplication.shared;app.setActivationPolicy(.regular);app.finishLaunching()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("cadenza-sidebar-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        // Optional: run against a copy of a real configuration (never the live file) with --sidebar-config=PATH.
        if let arg=CommandLine.arguments.first(where:{$0.hasPrefix("--sidebar-config=")}) { try? FileManager.default.copyItem(at:URL(fileURLWithPath:String(arg.dropFirst("--sidebar-config=".count))),to:root.appendingPathComponent("config.json")) }
        let store=ConfigStore(fileURL:root.appendingPathComponent("config.json"))
        let pipeline=VoicePipeline(configStore:store,input:InputSourceController());pipeline.selfTestMode=true
        let main=SettingsWindowController();main.configStore=store;main.pipeline=pipeline
        main.showSwift()
        defer{main.window?.close()}
        pump(0.8)
        guard let window=main.window,let model=main.settingsModel else{check("sidebar: window and model exist",false);return}
        guard let table=find(window.contentView,NSTableView.self) ?? find(window.contentView,NSOutlineView.self) else{check("sidebar: native list found",false);return}
        for _ in 0..<40 where !(window.isKeyWindow && NSApp.isActive) {NSApp.activate(ignoringOtherApps:true);window.makeKeyAndOrderFront(nil);pump(0.25)}
        print("[sidebar-debug] key=\(window.isKeyWindow) active=\(NSApp.isActive)")
        print("[sidebar-debug] key=\(window.isKeyWindow) active=\(NSApp.isActive) table=\(type(of:table)) selected=\(table.selectedRow) frame=\(table.frame) hit=\(String(describing:window.contentView?.hitTest(NSPoint(x:90,y:window.frame.height-120)).map{String(describing:type(of:$0))}))")
        table.selectRowIndexes(IndexSet(integer:3),byExtendingSelection:false);pump(0.3)
        print("[sidebar-debug] programmatic select row3 -> tab=\(model.tab.rawValue)")
        model.tab = .input;pump(0.3)
        let tabs=MainTab.visible(showDeveloper:model.showDeveloper)
        check("sidebar: one row per visible tab (\(table.numberOfRows) rows, \(tabs.count) tabs)",table.numberOfRows==tabs.count)
        for (index,tab) in tabs.enumerated().reversed() {
            let rowRect=table.convert(table.rect(ofRow:index),to:nil)
            click(window,at:NSPoint(x:rowRect.midX,y:rowRect.midY),on:table)
            let afterFirst=model.tab
            if model.tab != tab {click(window,at:NSPoint(x:rowRect.midX,y:rowRect.midY),on:table)}
            print("[sidebar-debug] row \(index): after 1st click tab=\(afterFirst.rawValue), after 2nd=\(model.tab.rawValue) key=\(window.isKeyWindow)")
            check("sidebar: clicking row \(index) opens \(tab.rawValue) (now \(model.tab.rawValue))",model.tab==tab)
        }
    }
}
