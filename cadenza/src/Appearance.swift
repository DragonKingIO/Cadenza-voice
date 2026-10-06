import AppKit

enum AppearanceController {
    static var reduceMotion:Bool {NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || CommandLine.arguments.contains("--inspect-reduced-motion")}
    static var highContrast:Bool {NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast || CommandLine.arguments.contains("--inspect-high-contrast")}
    static func apply(_ mode:String) {
        let selection=CommandLine.arguments.contains("--inspect-dark") ? "dark":CommandLine.arguments.contains("--inspect-light") ? "light":mode
        NSApp.appearance=selection == "dark" ? NSAppearance(named:.darkAqua):selection == "light" ? NSAppearance(named:.aqua):nil
    }
}

/// Existing normalized capture levels; no recorder or independent session state.
struct IllustrationSignal {
    private(set) var levels=[CGFloat](repeating:0,count:11)
    private(set) var smoothed:CGFloat=0
    mutating func push(_ value:Float,reduced:Bool) {
        let v=value.isFinite ? CGFloat(max(0,min(1,value))):0
        if reduced {smoothed=v;levels=Array(repeating:v,count:11)}
        else {smoothed=max(v,smoothed*0.75);levels.removeFirst();levels.append(smoothed)}
    }
    mutating func reset(){smoothed=0;levels=Array(repeating:0,count:11)}
}

final class TechnicalEmptyStateView:NSView {
    private var loadedResource="",image:NSImage?
    private var signal=IllustrationSignal()
    private var recording=false,lastLevelAt:Double=0
    private var expiryTimer:Timer?
    override init(frame:NSRect){super.init(frame:frame);setAccessibilityElement(false);updateImage()}
    required init?(coder:NSCoder){fatalError("init(coder:)")}
    deinit {expiryTimer?.invalidate()}
    override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();updateImage()}
    func updateImage(){let base=effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua ? "try-illustration-v2-dark":"try-illustration-v2-light";let name=base+(AppearanceController.highContrast ? "-contrast":"");guard name != loadedResource else{needsDisplay=true;return};loadedResource=name;image=Bundle.main.url(forResource:name,withExtension:"svg").flatMap(NSImage.init(contentsOf:));needsDisplay=true}
    func setRecording(_ value:Bool) {
        guard recording != value else{return};recording=value
        expiryTimer?.invalidate();expiryTimer=nil;signal.reset();lastLevelAt=0;needsDisplay=true
        if value {
            let timer=Timer(timeInterval:0.25,repeats:true){[weak self] _ in
                guard let self=self else{return}
                if ProcessInfo.processInfo.systemUptime-self.lastLevelAt>0.45 {self.signal.reset();self.needsDisplay=true}
            }
            RunLoop.main.add(timer,forMode:.common);expiryTimer=timer
        }
    }
    func pushLevel(_ value:Float) {
        guard recording else{return};lastLevelAt=ProcessInfo.processInfo.systemUptime
        signal.push(value,reduced:AppearanceController.reduceMotion);needsDisplay=true
    }
    private var fittedRect:NSRect {
        let scale=min(bounds.width/640,bounds.height/230)
        return NSRect(x:bounds.midX-320*scale,y:bounds.midY-115*scale,width:640*scale,height:230*scale)
    }
    var evidence:String {"recording=\(recording) levelZero=\(signal.levels.allSatisfy{$0 == 0}) timer=\(expiryTimer != nil) reduced=\(AppearanceController.reduceMotion) resource=\(loadedResource) svgLoaded=\(image != nil) fitted=\(fittedRect) view=\(bounds.size)"}
    override func draw(_ dirtyRect:NSRect) {
        let rect=fittedRect;guard rect.width>0,rect.height>0 else{return}
        image?.draw(in:rect)
        let scale=rect.width/640
        DesignTokens.accent.setFill()
        // SVG coordinates have a top origin. Use the very same fitted rectangle
        // for the image and bars so resizing/letterboxing cannot shift the waveform.
        for (i,v) in signal.levels.enumerated() {
            let h=(6+56*(recording ? v:0))*scale,w=4*scale
            let cx=rect.minX+(250+14*CGFloat(i))*scale,cy=rect.maxY-108*scale
            NSBezierPath(roundedRect:NSRect(x:cx-w/2,y:cy-h/2,width:w,height:h),xRadius:w/2,yRadius:w/2).fill()
        }
    }
}
