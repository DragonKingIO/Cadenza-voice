import AppKit

/// Sends real mouse events through the settings window and checks that the sidebar rows change the page.
enum SidebarClickFixtures {
    static func find<T:NSView>(_ root:NSView?,_ type:T.Type)->T? {
        guard let root=root else{return nil};if let hit=root as? T{return hit}
        for child in root.subviews{if let hit=find(child,type){return hit}};return nil
    }
    static func pump(_ seconds:TimeInterval){let end=Date(timeIntervalSinceNow:seconds);repeat{RunLoop.main.run(until:Date(timeIntervalSinceNow:0.02))}while Date()<end}
    /// Sends the click through the window the way the system does, so it goes through hit testing and the list's own tracking.
    static func click(_ window:NSWindow,at point:NSPoint){
        for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
            if let event=NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1){window.sendEvent(event)}
            pump(0.08)
        }
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
        print("[sidebar-debug] key=\(window.isKeyWindow) active=\(NSApp.isActive) selected=\(table.selectedRow) tab=\(model.tab.rawValue)")
        let tabs=MainTab.visible(showDeveloper:model.showDeveloper)
        check("sidebar: one row per visible tab (\(table.numberOfRows) rows, \(tabs.count) tabs)",table.numberOfRows==tabs.count)
        for (index,tab) in tabs.enumerated().reversed() {
            let rowRect=table.convert(table.rect(ofRow:index),to:nil)
            click(window,at:NSPoint(x:rowRect.midX,y:rowRect.midY))
            if model.tab != tab {print("[sidebar-debug] row \(index): selectedRow=\(table.selectedRow) tab=\(model.tab.rawValue) firstResponder=\(String(describing:window.firstResponder.map{type(of:$0)}))")}
            check("sidebar: clicking row \(index) opens \(tab.rawValue) (now \(model.tab.rawValue))",model.tab==tab)
        }
    }
}
