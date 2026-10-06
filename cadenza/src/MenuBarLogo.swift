import AppKit

/// Each bitmap shares an 18-point logical size; AppKit selects pixels for the display scale.
enum MenuBarLogo {
    static let image:NSImage = load(resources:Bundle.main.resourceURL)
    static func load(resources:URL?)->NSImage {
        let size=NSSize(width:18,height:18)
        let image=NSImage(size:size)
        for (suffix,scale) in [("",1),("@2x",2),("@3x",3)] {
            guard let url=resources?.appendingPathComponent("cadenza-menubar"+suffix+".png"),
                  let data=try? Data(contentsOf:url),let rep=NSBitmapImageRep(data:data),
                  rep.pixelsWide==18*scale,rep.pixelsHigh==18*scale else{continue}
            rep.size=size;image.addRepresentation(rep)
        }
        if image.representations.isEmpty {
            let fallback=NSImage(systemSymbolName:"mic",accessibilityDescription:Brand.name) ?? image
            fallback.size=size;fallback.isTemplate=true;return fallback
        }
        image.isTemplate=true
        image.accessibilityDescription=Brand.name
        return image
    }
}
