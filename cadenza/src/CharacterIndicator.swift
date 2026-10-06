import AppKit
import ImageIO
import SwiftUI

/// Optional animated character for the recording bar. The waveform stays the default; the character is used only when
/// the user chooses it and its frames are present and decoded, otherwise the waveform is shown.
enum IndicatorStyle: String {
    case waveform, character
    private static let key = "recordingIndicatorStyle"
    static var current: IndicatorStyle {
        get { UserDefaults.standard.string(forKey: key).flatMap(IndicatorStyle.init(rawValue:)) ?? .waveform }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key); if newValue == .character { CharacterAssets.prewarm() } }
    }
}

enum CharacterState: String, CaseIterable { case write, think, alert, error }

struct CharacterClip {
    var frames: [CGImage]
    var delays: [TimeInterval]
    /// Union of the visible (non-transparent) area over all frames, normalized, origin at the top left.
    var bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
    var total: TimeInterval { delays.reduce(0, +) }

    /// The artwork is not centered in its canvas (the error and alert characters sit low, with a badge at the top).
    /// This returns the translation (layer coordinates, y up) that centers the visible area in a square view.
    func centering(side: CGFloat) -> (dx: CGFloat, dy: CGFloat) {
        ((0.5 - bounds.midX) * side, (bounds.midY - 0.5) * side)
    }

    /// Alpha bounding box of one frame, normalized with the origin at the top left; nil when fully transparent.
    static func visibleBounds(of image: CGImage, threshold: UInt8 = 24) -> CGRect? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h { for x in 0..<w where pixels[y * w + x] > threshold {
            if x < minX { minX = x }; if x > maxX { maxX = x }; if y < minY { minY = y }; if y > maxY { maxY = y }
        } }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: CGFloat(minX) / CGFloat(w), y: CGFloat(minY) / CGFloat(h), width: CGFloat(maxX - minX + 1) / CGFloat(w), height: CGFloat(maxY - minY + 1) / CGFloat(h))
    }
}

enum CharacterAssets {
    static let displaySize: CGFloat = 72
    static let pixelSize = 384 // after transparent trim, still covers 72 pt at 3x
    private static let lock = NSLock()
    private static var clips: [CharacterState: CharacterClip] = [:]
    private static var loading = false

    static var directory: URL? { Bundle.main.resourceURL?.appendingPathComponent("character", isDirectory: true) }
    /// Files are bundled at build time; they may be absent (for example a source checkout without the artwork).
    static var present: Bool {
        guard let dir = directory else { return false }
        return CharacterState.allCases.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.rawValue + ".gif").path) }
    }

    static func load(_ url: URL, maxPixel: Int = pixelSize) -> CharacterClip? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0, CGImageSourceGetCount(source) <= 400 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        var frames: [CGImage] = [], delays: [TimeInterval] = []
        for i in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, i, options as CFDictionary) else { return nil }
            let gif = (CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.05
            // All four supplied 512px clips share this safe trim; retain the same
            // canvas throughout playback so gestures do not jump between frames.
            let trim=CGRect(x:CGFloat(image.width)*72/512,y:CGFloat(image.height)*88/512,
                            width:CGFloat(image.width)*392/512,height:CGFloat(image.height)*392/512).integral
            frames.append(image.cropping(to:trim) ?? image); delays.append(max(0.02, delay))
        }
        var clip = CharacterClip(frames: frames, delays: delays)
        var union: CGRect?
        for image in frames { if let box = CharacterClip.visibleBounds(of: image) { union = union.map { $0.union(box) } ?? box } }
        if let union = union { clip.bounds = union }
        return clip
    }

    /// Decodes the frames off the main thread. Until they are ready the waveform is used.
    static func prewarm() {
        lock.lock()
        if loading || clips.count == CharacterState.allCases.count { lock.unlock(); return }
        loading = true; lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            if let dir = directory {
                for state in CharacterState.allCases {
                    if let clip = load(dir.appendingPathComponent(state.rawValue + ".gif")) { lock.lock(); clips[state] = clip; lock.unlock() }
                }
            }
            lock.lock(); loading = false; lock.unlock()
            DispatchQueue.main.async { NotificationCenter.default.post(name: .characterAssetsReady, object: nil) }
        }
    }

    static func cached(_ state: CharacterState) -> CharacterClip? { lock.lock(); defer { lock.unlock() }; return clips[state] }
    static var ready: Bool { CharacterState.allCases.allSatisfy { cached($0) != nil } }
    /// True when the user's choice can be shown right now.
    static var active: Bool { IndicatorStyle.current == .character && ready }
}

extension Notification.Name { static let characterAssetsReady = Notification.Name("CharacterAssetsReady") }

/// Plays a decoded clip on a layer. With Reduce Motion it shows the first frame only.
final class CharacterView: NSView {
    private(set) var state: CharacterState?
    private var clip: CharacterClip?
    private var started = 0.0
    private var timer: Timer?
    private(set) var frameIndex = 0

    /// The artwork lives on a sublayer so the centering offset never fights AppKit's own frame handling.
    private let art = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        art.contentsGravity = .resizeAspect
        art.minificationFilter = .trilinear
        art.magnificationFilter = .linear
        layer?.addSublayer(art)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        art.frame = bounds
        if let clip = clip { let c = clip.centering(side: min(bounds.width, bounds.height)); art.setAffineTransform(CGAffineTransform(translationX: c.dx, y: c.dy)) }
        else { art.setAffineTransform(.identity) }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        art.contentsScale = window?.backingScaleFactor ?? 2
    }

    func play(_ next: CharacterState, now: Double = CACurrentMediaTime()) {
        guard next != state else { return }
        guard let clip = CharacterAssets.cached(next) else { stop(); return }
        state = next; self.clip = clip; started = now; frameIndex = 0
        art.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        needsLayout = true; layoutSubtreeIfNeeded()
        show(0)
        timer?.invalidate(); timer = nil
        guard !AppearanceController.reduceMotion else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        timer = t; RunLoop.main.add(t, forMode: .common)
    }

    func tick(now: Double = CACurrentMediaTime()) {
        guard let clip = clip, clip.total > 0 else { return }
        var t = (now - started).truncatingRemainder(dividingBy: clip.total), index = 0
        for (i, d) in clip.delays.enumerated() { if t < d { index = i; break }; t -= d; index = i }
        if index != frameIndex { show(index) }
    }

    private func show(_ index: Int) {
        guard let clip = clip, index < clip.frames.count else { return }
        frameIndex = index
        CATransaction.begin(); CATransaction.setDisableActions(true)
        art.contents = clip.frames[index]
        CATransaction.commit()
    }

    func stop() {
        timer?.invalidate(); timer = nil; state = nil; clip = nil
        art.contents = nil
    }
}

// MARK: - Settings

private struct CharacterPreview: NSViewRepresentable {
    var revision: Int
    func makeNSView(context: Context) -> CharacterView { CharacterView(frame: NSRect(x: 0, y: 0, width: 44, height: 44)) }
    func updateNSView(_ view: CharacterView, context: Context) { view.play(.write) }
}

/// Uses the recording HUD's renderer with synthetic levels; never opens a microphone.
private struct WaveformPreview: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    final class Coordinator {
        private var timer: Timer?
        private var phase: CGFloat = 0
        private weak var view: WaveformView?
        private var animated = false

        func update(_ view: WaveformView, animated: Bool) {
            self.view = view
            render()
            guard self.animated != animated else { return }
            self.animated = animated
            timer?.invalidate(); timer = nil
            if animated {
                let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.phase += 0.18
                    self.render()
                }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        private func render() {
            view?.levels = (0..<21).map { index in
                let distance = abs(CGFloat(index) - 10) / 10
                return (0.18 + 0.70 * abs(sin(CGFloat(index) * 0.55 + phase))) * (1 - distance * 0.55)
            }
        }
        func stop() { timer?.invalidate(); timer = nil }
        deinit { stop() }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WaveformView {
        let view = WaveformView(frame: NSRect(x: 0, y: 0, width: 96, height: 22))
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel(L10n.tr("indicator.waveform"))
        return view
    }
    func updateNSView(_ view: WaveformView, context: Context) {
        context.coordinator.update(view, animated: !reduceMotion)
    }
    static func dismantleNSView(_ view: WaveformView, coordinator: Coordinator) { coordinator.stop() }
}

/// Shown only when the artwork is bundled. The default stays the waveform.
struct IndicatorStyleSection: View {
    @State private var style = IndicatorStyle.current
    @State private var assetsReady = CharacterAssets.ready
    @State private var assetsFailed = false

    private func loadCharacter() {
        assetsReady = CharacterAssets.ready
        assetsFailed = false
        if !assetsReady { CharacterAssets.prewarm() }
    }

    var body: some View {
        Section {
            Picker(L10n.tr("indicator.title"), selection: $style) {
                Text(L10n.tr("indicator.waveform")).tag(IndicatorStyle.waveform)
                Text(L10n.tr("indicator.character")).tag(IndicatorStyle.character)
            }
            .pickerStyle(.segmented)
            .onChange(of: style) { _, value in
                IndicatorStyle.current = value
                if value == .character { loadCharacter() }
            }
            HStack {
                Spacer()
                if style == .character {
                    if assetsReady { CharacterPreview(revision: 0).frame(width: 44, height: 44) }
                    else if assetsFailed {
                        VStack(spacing: 6) {
                            Label(L10n.tr("indicator.preview.failed"), systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.secondary)
                            Button(L10n.tr("indicator.preview.retry")) { loadCharacter() }.buttonStyle(.bordered)
                        }
                    } else { ProgressView().controlSize(.small).frame(width: 44, height: 44) }
                } else {
                    WaveformPreview().frame(width: 96, height: 22)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Capsule().fill(Color(nsColor: DesignTokens.hudBackground)))
                        .overlay(Capsule().stroke(Color(nsColor: DesignTokens.outline), lineWidth: 1))
                        .frame(height: 44)
                }
                Spacer()
            }
        } header: {
            Text(L10n.tr("indicator.header"))
        } footer: {
            Text(L10n.tr("indicator.hint")).font(.callout).foregroundStyle(.primary)
        }
        .onReceive(NotificationCenter.default.publisher(for: .characterAssetsReady)) { _ in
            assetsReady = CharacterAssets.ready
            assetsFailed = !assetsReady
        }
        .onAppear { if style == .character { loadCharacter() } }
    }
}
