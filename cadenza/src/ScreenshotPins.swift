import AppKit
import SwiftUI

// MARK: - 贴图：把截图钉在屏幕最上层。滚轮缩放、⌥+滚轮调透明度、旋转、鼠标穿透、复制/保存/识别文字，统一管理。

enum PinGeometry {
    static let minZoom: CGFloat = 0.1, maxZoom: CGFloat = 8
    static func clampZoom(_ z: CGFloat) -> CGFloat { min(max(z, minZoom), maxZoom) }
    /// 滚轮一格大约缩放 2%；方向向上放大
    static func nextZoom(_ current: CGFloat, scrollDelta: CGFloat) -> CGFloat { clampZoom(current * (1 + scrollDelta * 0.02)) }
    static func clampOpacity(_ a: CGFloat) -> CGFloat { min(max((a * 10).rounded() / 10, 0.2), 1) }
    /// 以窗口中心为锚点缩放
    static func frame(base: CGSize, zoom: CGFloat, center: CGPoint) -> CGRect {
        let w = max(24, base.width * zoom), h = max(24, base.height * zoom)
        return CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    }
    /// 旋转后的点尺寸（奇数个 90° 时宽高互换）
    static func rotatedSize(_ size: CGSize, quarterTurns: Int) -> CGSize { quarterTurns % 2 == 0 ? size : CGSize(width: size.height, height: size.width) }

    /// 顺时针旋转 90° 的整数倍
    static func rotate(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let turns = ((quarterTurns % 4) + 4) % 4
        if turns == 0 { return image }
        let w = image.width, h = image.height
        let (nw, nh) = turns % 2 == 0 ? (w, h) : (h, w)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(nw) / 2, y: CGFloat(nh) / 2)
        ctx.rotate(by: -CGFloat(turns) * .pi / 2)          // CG 的正角度是逆时针，取负得到顺时针
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }
}

final class PinManager {
    static let shared = PinManager()
    private(set) var windows: [PinnedImageWindow] = []
    private(set) var hidden = false
    var count: Int { windows.count }
    var anyClickThrough: Bool { windows.contains { $0.clickThrough } }

    func pin(image: CGImage, scale: CGFloat, at frame: NSRect, router: @escaping () -> OCRRouter) {
        let window = PinnedImageWindow(image: image, scale: scale, frame: frame, router: router)
        window.onClose = { [weak self, weak window] in guard let window else { return }; self?.windows.removeAll { $0 === window } }
        windows.append(window)
        hidden = false
        window.orderFrontRegardless()
    }
    func closeAll() { windows.forEach { $0.dismiss() }; windows.removeAll() }
    func setHidden(_ hide: Bool) { hidden = hide; windows.forEach { hide ? $0.orderOut(nil) : $0.orderFrontRegardless() } }
    func restoreInteraction() { windows.forEach { $0.setClickThrough(false) } }
}

final class PinnedImageWindow: NSPanel {
    private let original: CGImage
    private let scale: CGFloat
    private let router: () -> OCRRouter
    private let baseSize: CGSize                 // 初始点尺寸（未旋转、未缩放）
    private var zoom: CGFloat = 1
    private var quarterTurns = 0
    private(set) var clickThrough = false
    var onClose: (() -> Void)?
    private let content: PinnedImageView

    init(image: CGImage, scale: CGFloat, frame: NSRect, router: @escaping () -> OCRRouter) {
        original = image; self.scale = scale; self.router = router; baseSize = frame.size
        content = PinnedImageView(frame: NSRect(origin: .zero, size: frame.size), image: ScreenshotRenderer.nsImage(image, scale: scale))
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating; isOpaque = false; backgroundColor = .clear; hasShadow = true
        isMovableByWindowBackground = true; hidesOnDeactivate = false; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        content.owner = self
        contentView = content
    }
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { dismiss() }
    func dismiss() { orderOut(nil); onClose?() }

    // MARK: 缩放 / 透明度 / 旋转 / 穿透

    func setZoom(_ z: CGFloat) {
        zoom = PinGeometry.clampZoom(z)
        let size = PinGeometry.rotatedSize(baseSize, quarterTurns: quarterTurns)
        setFrame(PinGeometry.frame(base: size, zoom: zoom, center: CGPoint(x: frame.midX, y: frame.midY)), display: true)
        content.frame = NSRect(origin: .zero, size: frame.size); content.needsLayout = true
    }
    func zoomBy(scroll delta: CGFloat) { setZoom(PinGeometry.nextZoom(zoom, scrollDelta: delta)) }
    func adjustOpacity(by delta: CGFloat) { alphaValue = PinGeometry.clampOpacity(alphaValue + delta) }
    func rotate() {
        quarterTurns = (quarterTurns + 1) % 4
        if let rotated = PinGeometry.rotate(original, quarterTurns: quarterTurns) { content.image = ScreenshotRenderer.nsImage(rotated, scale: scale) }
        setZoom(zoom)
    }
    func setClickThrough(_ on: Bool) {
        clickThrough = on; ignoresMouseEvents = on
        alphaValue = on ? min(alphaValue, 0.85) : alphaValue
    }
    var currentZoom: CGFloat { zoom }
    var currentQuarterTurns: Int { quarterTurns }

    // MARK: 动作

    private var currentImage: CGImage { PinGeometry.rotate(original, quarterTurns: quarterTurns) ?? original }
    func copyImage() { ScreenshotOutputs.copy(currentImage, scale: scale) }
    func saveImage() { do { _ = try ScreenshotOutputs.saveWithPanel(currentImage) } catch { ScreenshotOutputs.alert(title: L10n.tr("screenshot.save.failed"), message: error.localizedDescription) } }
    func recognizeText() {
        let image = original, router = router(), thumb = ScreenshotRenderer.nsImage(original, scale: scale), anchor = frame
        Task { @MainActor in
            do { OCRResultWindow.show(try await router.recognize(image), thumbnail: thumb, near: anchor) }
            catch { ScreenshotOutputs.alert(title: L10n.tr("screenshot.ocr.title"), message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        if event.modifierFlags.contains(.option) { adjustOpacity(by: delta > 0 ? 0.1 : -0.1) } else { zoomBy(scroll: delta) }
    }
    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch (event.charactersIgnoringModifiers ?? "").lowercased() {
        case "=", "+": setZoom(zoom * 1.1)
        case "-": setZoom(zoom / 1.1)
        case "0": setZoom(1)
        case "[": adjustOpacity(by: -0.1)
        case "]": adjustOpacity(by: 0.1)
        case "r": rotate()
        case "c" where cmd: copyImage()
        case "s" where cmd: saveImage()
        default: super.keyDown(with: event)
        }
    }
}

private final class PinnedImageView: NSView {
    var image: NSImage { didSet { needsDisplay = true } }
    weak var owner: PinnedImageWindow?
    private var strip: NSHostingView<PinControlStrip>?
    init(frame: NSRect, image: NSImage) {
        self.image = image; super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var mouseDownCanMoveWindow: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)); border.lineWidth = 1; border.stroke()
    }
    override func mouseDown(with event: NSEvent) { if event.clickCount == 2 { owner?.dismiss() } else { super.mouseDown(with: event) } }
    override func mouseEntered(with event: NSEvent) {
        guard strip == nil, let owner else { return }
        let view = NSHostingView(rootView: PinControlStrip(copy: { owner.copyImage() }, save: { owner.saveImage() }, ocr: { owner.recognizeText() }, rotate: { owner.rotate() },
                                                           fainter: { owner.adjustOpacity(by: -0.1) }, bolder: { owner.adjustOpacity(by: 0.1) },
                                                           through: { owner.setClickThrough(true) }, close: { owner.dismiss() }))
        view.frame.size = view.fittingSize
        view.frame.origin = NSPoint(x: max(0, (bounds.width - view.frame.width) / 2), y: bounds.height - view.frame.height - 6)
        view.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        addSubview(view); strip = view
    }
    override func mouseExited(with event: NSEvent) { strip?.removeFromSuperview(); strip = nil }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner else { return nil }
        let menu = NSMenu()
        for (key, action) in [("screenshot.copy", #selector(copyAction)), ("screenshot.save", #selector(saveAction)), ("screenshot.ocr.short", #selector(ocrAction)), ("screenshot.pin.rotate", #selector(rotateAction)), ("screenshot.pin.through", #selector(throughAction)), ("screenshot.pin.close", #selector(closeAction))] {
            let item = NSMenuItem(title: L10n.tr(key), action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        _ = owner
        return menu
    }
    @objc private func copyAction() { owner?.copyImage() }
    @objc private func saveAction() { owner?.saveImage() }
    @objc private func ocrAction() { owner?.recognizeText() }
    @objc private func rotateAction() { owner?.rotate() }
    @objc private func throughAction() { owner?.setClickThrough(true) }
    @objc private func closeAction() { owner?.dismiss() }
}

private struct PinControlStrip: View {
    let copy: () -> Void, save: () -> Void, ocr: () -> Void, rotate: () -> Void, fainter: () -> Void, bolder: () -> Void, through: () -> Void, close: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            item("clip", "screenshot.copy", copy); item("tray", "screenshot.save", save); item("scan", "screenshot.ocr.short", ocr)
            item("rotate", "screenshot.pin.rotate", rotate); item("opacity", "screenshot.pin.fainter", fainter, tilt: true); item("opacity", "screenshot.pin.bolder", bolder)
            item("ghost", "screenshot.pin.through", through); item("close", "screenshot.pin.close", close)
        }
        .padding(.horizontal, 4).frame(height: 30)
        .background(.regularMaterial, in: Capsule()).overlay(Capsule().strokeBorder(Color.primary.opacity(0.14)))
        .fixedSize()
    }
    private func item(_ icon: String, _ key: String, _ action: @escaping () -> Void, tilt: Bool = false) -> some View {
        Button(action: action) {
            Image(nsImage: ScreenshotIcon.image(icon)).renderingMode(.template).resizable().scaledToFit().frame(width: 15, height: 15)
                .rotationEffect(.degrees(tilt ? 180 : 0)).frame(width: 26, height: 26).contentShape(Rectangle())
        }.buttonStyle(.plain).help(L10n.tr(key)).accessibilityLabel(L10n.tr(key))
    }
}
