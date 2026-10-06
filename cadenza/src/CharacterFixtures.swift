import Foundation

/// Optional character indicator: preference default, fallback, frame decoding and timing. No windows are shown.
enum CharacterFixtures {
    static func run(_ check: (String, Bool) -> Void) {
        func c(_ name: String, _ ok: Bool) { check("Character " + name, ok) }
        errorRowGeometry(c)
        let screen=NSRect(x:0,y:0,width:1440,height:900),visible=NSRect(x:0,y:80,width:1440,height:792)
        let origin=RecordingHUDPlacement.origin(size:NSSize(width:128,height:140),frame:screen,visible:visible)
        c("角色浮层在屏幕底部居中并避开Dock",origin.x+64 == screen.midX && origin.y == visible.minY+24)
        let external=NSRect(x:-1920,y:0,width:1920,height:1080)
        let externalOrigin=RecordingHUDPlacement.origin(size:NSSize(width:128,height:140),frame:external,visible:external)
        c("副屏坐标居中并保持底部间距",externalOrigin.x+64 == external.midX && externalOrigin.y == 80)
        let previousWidth:CGFloat=96
        c("角色缩小四分之一且Retina无需放大位图",CharacterAssets.displaySize == previousWidth*0.75 && CGFloat(CharacterAssets.pixelSize)*392/512 >= CharacterAssets.displaySize*3)
        let defaults = UserDefaults.standard, key = "recordingIndicatorStyle"
        let saved = defaults.object(forKey: key)
        defer { if let saved = saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) } }

        defaults.removeObject(forKey: key)
        c("默认样式是声波", IndicatorStyle.current == .waveform && !CharacterAssets.active)
        defaults.set("nonsense", forKey: key)
        c("无效偏好回退声波", IndicatorStyle.current == .waveform)
        defaults.set("waveform", forKey: key)
        c("选择声波时不启用角色", !CharacterAssets.active)

        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-" + UUID().uuidString + ".gif")
        c("缺少素材返回空", CharacterAssets.load(missing) == nil)
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-" + UUID().uuidString + ".gif")
        try? Data("not a gif".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        c("损坏素材返回空", CharacterAssets.load(junk) == nil)

        guard CharacterAssets.present, let dir = CharacterAssets.directory else {
            c("素材未打包时保持声波", IndicatorStyle.current == .waveform && !CharacterAssets.present)
            return
        }
        guard let listen = CharacterAssets.load(dir.appendingPathComponent("write.gif")) else { c("解码录音素材", false); return }
        c("解码录音素材帧数与时长", listen.frames.count == 75 && abs(listen.total - 3.75) < 0.05)
        c("帧缩小到限定像素", listen.frames.allSatisfy { max($0.width, $0.height) <= CharacterAssets.pixelSize })
        for state in CharacterState.allCases {
            c("素材可解码 \(state.rawValue)", CharacterAssets.load(dir.appendingPathComponent(state.rawValue + ".gif"))?.frames.isEmpty == false)
        }

        for state in CharacterState.allCases {
            guard let clip = CharacterAssets.load(dir.appendingPathComponent(state.rawValue + ".gif")) else { continue }
            let b = clip.bounds, shift = clip.centering(side: 40)
            c("可见区域在画布内且有内容 \(state.rawValue)", b.width > 0.1 && b.height > 0.1 && b.minX >= 0 && b.minY >= 0 && b.maxX <= 1.001 && b.maxY <= 1.001)
            c("平移后可见区域居中 \(state.rawValue)", abs((b.midX - 0.5) * 40 + shift.dx) < 0.01 && abs((0.5 - b.midY) * 40 + shift.dy) < 0.01)
        }
        c("出错素材不在画布正中，需要平移", { guard let e = CharacterAssets.load(dir.appendingPathComponent("error.gif")) else { return false }; let t = e.centering(side: 40); return abs(t.dx) > 0.2 || abs(t.dy) > 0.2 }())
        defaults.set("character", forKey: key)
        c("素材尚未解码时仍用声波", !CharacterAssets.active || CharacterAssets.ready)
        CharacterAssets.prewarm()
        LocalAPIFixtures.spin(10) { CharacterAssets.ready }
        c("后台解码完成后启用角色", CharacterAssets.ready && CharacterAssets.active)
        defaults.set("waveform", forKey: key)
        c("切回声波立即停用角色", !CharacterAssets.active)

        let view = CharacterView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        view.play(.write, now: 100)
        c("播放从第一帧开始", view.state == .write && view.frameIndex == 0)
        view.tick(now: 100.06)
        c("按时间前进到下一帧", view.frameIndex == 1)
        view.tick(now: 100 + listen.total + 0.01)
        c("播放结束后循环回第一帧", view.frameIndex == 0)
        view.play(.think, now: 200)
        c("切换状态重新开始", view.state == .think && view.frameIndex == 0)
        view.stop()
        c("停止后清除状态", view.state == nil)
    }

    /// The error bar's icon, message and button must share one vertical centre and never overlap.
    static func errorRowGeometry(_ c: (String, Bool) -> Void) {
        for reason in ["短提示。", L10n.tr("ui.79250fdff1f6"), L10n.tr("ui.a193c59bb0c6"), String(repeating: "很长的提示", count: 12)] {
            let capsule = CapsuleWindowController(); capsule.suppressPresentation = true
            capsule.showError(reason, action: .retry)
            guard let row = capsule.inspectErrorRow() else { c("出错条可检查", false); continue }
            c("出错条图标、文字、按钮垂直居中一致（\(reason.count) 字）", abs(row.icon - row.panel) < 0.6 && abs(row.label - row.panel) < 0.6 && abs(row.button - row.panel) < 0.6)
            c("出错条文字框高度等于文字实际高度，文字不会在框里偏上（\(reason.count) 字）", abs(row.labelHeight - row.textHeight) < 1)
            c("出错条文字不与按钮重叠（\(reason.count) 字）", row.labelMaxX <= row.buttonMinX)
            capsule.hide()
        }
    }
}
