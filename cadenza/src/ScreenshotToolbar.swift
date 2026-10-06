import SwiftUI
import Observation

// MARK: - 截图工具栏
// 三个部件，各自贴在选区旁边：
//   · 标注工具条（两列，贴选区左/右侧）：十种标注工具、撤销/重做/删除，选中工具后在同一张卡片里展开颜色、粗细和该工具特有的选项
//   · 操作胶囊条（横向，贴选区下方）：带文字的“识别文字 / 贴图 / 保存”，以及主操作“复制”和关闭
//   · 识别胶囊条：识别完成后替换操作条，选择文字、复制、在窗口中查看、二维码结果
// 图标均为本项目原创（resources/shot-*.svg）。

/// 原创图标加载：SVG 以模板图方式着色，跟随选中/悬停/深浅色；加载失败时退回系统符号，保证按钮不会空白
enum ScreenshotIcon {
    static let names = ["frame", "ring", "swoosh", "marker", "highlight", "blocks", "blur", "type", "badge", "eraser",
                        "scan", "rewind", "forward", "tray", "float", "clip", "close", "trash",
                        "qr", "selecttext", "copytext", "openwindow", "back", "link",
                        "rotate", "opacity", "ghost", "hide", "show", "zoomin", "zoomout",
                        "solid", "outline", "arrow1", "arrow2", "arrow0", "textplain", "textfilled", "textoutline"]
    private static let fallbacks = ["frame": "square", "ring": "circle", "swoosh": "arrow.up.right", "marker": "pencil", "highlight": "highlighter", "blocks": "squareshape.split.3x3",
                                    "blur": "aqi.medium", "type": "textformat", "badge": "1.circle", "eraser": "eraser", "scan": "text.viewfinder", "rewind": "arrow.uturn.backward",
                                    "forward": "arrow.uturn.forward", "tray": "square.and.arrow.down", "float": "rectangle.on.rectangle", "clip": "doc.on.clipboard", "close": "xmark", "trash": "trash",
                                    "qr": "qrcode", "selecttext": "text.cursor", "copytext": "doc.on.doc", "openwindow": "macwindow", "back": "chevron.left", "link": "arrow.up.right.square",
                                    "rotate": "rotate.right", "opacity": "circle.lefthalf.filled", "ghost": "cursorarrow.click", "hide": "eye.slash", "show": "eye", "zoomin": "plus.magnifyingglass", "zoomout": "minus.magnifyingglass",
                                    "solid": "square.fill", "outline": "square", "arrow1": "arrow.right", "arrow2": "arrow.left.and.right", "arrow0": "minus", "textplain": "textformat", "textfilled": "character.textbox", "textoutline": "textformat.alt"]
    static func image(_ name: String, bundle: Bundle = .main) -> NSImage {
        if let url = bundle.url(forResource: "shot-" + name, withExtension: "svg"), let image = NSImage(contentsOf: url), image.size.width > 0 {
            image.isTemplate = true; return image
        }
        let fallback = NSImage(systemSymbolName: fallbacks[name] ?? "square", accessibilityDescription: nil) ?? NSImage()
        fallback.isTemplate = true; return fallback
    }
    static func isOriginal(_ name: String, bundle: Bundle = .main) -> Bool { bundle.url(forResource: "shot-" + name, withExtension: "svg") != nil }
    static func toolIcon(_ tool: ScreenshotTool) -> String {
        switch tool {
        case .rectangle: return "frame"; case .ellipse: return "ring"; case .arrow: return "swoosh"; case .pen: return "marker"; case .highlighter: return "highlight"
        case .mosaic: return "blocks"; case .blur: return "blur"; case .text: return "type"; case .marker: return "badge"; case .eraser: return "eraser"
        }
    }
    static func toolLabelKey(_ tool: ScreenshotTool) -> String { "screenshot.tool." + tool.rawValue }
    static let toolShortcuts: [ScreenshotTool: String] = [.rectangle: "R", .ellipse: "O", .arrow: "A", .pen: "P", .highlighter: "H", .mosaic: "M", .blur: "B", .text: "T", .marker: "N", .eraser: "E"]
    /// palette 里的显示顺序（两列）
    static let toolOrder: [ScreenshotTool] = [.rectangle, .ellipse, .arrow, .pen, .highlighter, .marker, .text, .mosaic, .blur, .eraser]
    /// 选中某个标注时，对应的“工具”（决定显示哪些样式选项）
    static func tool(for shape: AnnotationObject.Shape) -> ScreenshotTool {
        switch shape {
        case .rectangle: return .rectangle; case .ellipse: return .ellipse; case .line: return .arrow; case .pen: return .pen; case .highlighter: return .highlighter
        case .mosaic: return .mosaic; case .blur: return .blur; case .text: return .text; case .marker: return .marker
        }
    }
}

/// 识别完成后工具栏要显示的信息
struct RecognitionSummary: Equatable {
    var lineCount = 0
    var selectedCount = 0
    var engineNote = ""
    var codes: [ScannedCode] = []
    var hasOverlay = true
}

@Observable
final class ScreenshotToolbarModel {
    var tool: ScreenshotTool?
    var style = ScreenshotStyle()
    /// 选中了已有标注时，样式选项按它的类型显示
    var selectedTool: ScreenshotTool?
    var canUndo = false
    var canRedo = false
    var recognizing = false
    var message = ""
    var recognition: RecognitionSummary?
    /// 当前应当显示哪个工具的样式选项
    var optionsTool: ScreenshotTool? { tool ?? selectedTool }
    var hasSelectedObject: Bool { selectedTool != nil }

    @ObservationIgnored var onSelectTool: (ScreenshotTool?) -> Void = { _ in }
    @ObservationIgnored var onStyleChanged: () -> Void = {}
    @ObservationIgnored var onUndo: () -> Void = {}
    @ObservationIgnored var onRedo: () -> Void = {}
    @ObservationIgnored var onDelete: () -> Void = {}
    @ObservationIgnored var onSave: () -> Void = {}
    @ObservationIgnored var onPin: () -> Void = {}
    @ObservationIgnored var onOCR: () -> Void = {}
    @ObservationIgnored var onCancel: () -> Void = {}
    @ObservationIgnored var onConfirm: () -> Void = {}
    // 识别条
    @ObservationIgnored var onBackToAnnotate: () -> Void = {}
    @ObservationIgnored var onSelectAllText: () -> Void = {}
    @ObservationIgnored var onCopyText: () -> Void = {}
    @ObservationIgnored var onOpenResultWindow: () -> Void = {}
    @ObservationIgnored var onCopyCode: (ScannedCode) -> Void = { _ in }
    @ObservationIgnored var onOpenCode: (ScannedCode) -> Void = { _ in }

    /// 选一个颜色
    func chooseColor(_ color: ScreenshotColor) { style.color = color; onStyleChanged() }
}

private struct IconView: View {
    let name: String
    var size: CGFloat = 19
    var body: some View { Image(nsImage: ScreenshotIcon.image(name)).renderingMode(.template).resizable().scaledToFit().frame(width: size, height: size) }
}

/// 通透的卡片：材质 + 顶部高光 + 渐变描边 + 双层柔和阴影
private struct GlassCard: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(.regularMaterial, in: shape)
            .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(0.20), Color.white.opacity(0)], startPoint: .top, endPoint: .center)).allowsHitTesting(false))
            .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.55), Color.primary.opacity(0.10)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
            .shadow(color: .black.opacity(0.10), radius: 1.5, y: 0.5)
    }
}
private extension View { func glass(_ radius: CGFloat) -> some View { modifier(GlassCard(radius: radius)) } }

/// 选中态：强调色渐变 + 柔和光晕
private struct SelectedGlow: View {
    var radius: CGFloat = 10
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.78)], startPoint: .top, endPoint: .bottom))
            .shadow(color: Color.accentColor.opacity(0.45), radius: 6, y: 2)
    }
}

// MARK: 标注工具条（两列，只放工具）

struct ScreenshotPaletteView: View {
    @Bindable var model: ScreenshotToolbarModel
    private let columns = [GridItem(.fixed(36), spacing: 2), GridItem(.fixed(36), spacing: 2)]

    var body: some View {
        VStack(spacing: 4) {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(ScreenshotIcon.toolOrder) { tool in
                    let shortcut = ScreenshotIcon.toolShortcuts[tool].map { " (\($0))" } ?? ""
                    PaletteButton(icon: ScreenshotIcon.toolIcon(tool), label: L10n.tr(ScreenshotIcon.toolLabelKey(tool)) + shortcut, selected: model.tool == tool) {
                        model.tool = model.tool == tool ? nil : tool
                        model.onSelectTool(model.tool)
                    }
                }
            }
            Divider().frame(width: 58).padding(.vertical, 2)
            HStack(spacing: 2) {
                PaletteButton(icon: "rewind", label: L10n.tr("screenshot.undo") + " (⌘Z)", disabled: !model.canUndo) { model.onUndo() }
                PaletteButton(icon: "forward", label: L10n.tr("screenshot.redo") + " (⇧⌘Z)", disabled: !model.canRedo) { model.onRedo() }
            }
            if model.hasSelectedObject {
                PaletteButton(icon: "trash", label: L10n.tr("screenshot.delete") + " (⌫)", tint: .red) { model.onDelete() }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: model.hasSelectedObject)
        .padding(5).frame(width: 84)
        .glass(16)
        .padding(10).fixedSize()          // 留出阴影空间，避免被裁切
    }
}

// MARK: 选项条（横向）：只显示当前工具用得到的选项；最后是粗细和颜色

struct ScreenshotOptionsBar: View {
    @Bindable var model: ScreenshotToolbarModel
    let tool: ScreenshotTool

    var body: some View {
        HStack(spacing: 10) {
            if tool.usesFill {
                group {
                    PaletteButton(icon: "outline", label: L10n.tr("screenshot.fill.off"), selected: !model.style.filled, compact: true) { model.style.filled = false; model.onStyleChanged() }
                    PaletteButton(icon: "solid", label: L10n.tr("screenshot.fill.on"), selected: model.style.filled, compact: true) { model.style.filled = true; model.onStyleChanged() }
                }
            }
            if tool.usesArrowStyle {
                group {
                    ForEach([(ArrowStyle.single, "arrow1"), (.double, "arrow2"), (.line, "arrow0")], id: \.0) { style, icon in
                        PaletteButton(icon: icon, label: L10n.tr("screenshot.arrow." + style.rawValue), selected: model.style.arrowStyle == style, compact: true, iconSize: 16) { model.style.arrowStyle = style; model.onStyleChanged() }
                    }
                }
            }
            if tool.usesTextStyle {
                group {
                    ForEach([(TextStyle.plain, "textplain"), (.filled, "textfilled"), (.outlined, "textoutline")], id: \.0) { style, icon in
                        PaletteButton(icon: icon, label: L10n.tr("screenshot.text." + style.rawValue), selected: model.style.textStyle == style, compact: true, iconSize: 16) { model.style.textStyle = style; model.onStyleChanged() }
                    }
                }
            }
            if tool.usesLevel { group { LevelPicker(model: model, tool: tool) } }
            if tool.usesColor {
                HStack(spacing: 7) {
                    ForEach(Array(ScreenshotColor.palette.enumerated()), id: \.offset) { _, color in
                        Swatch(color: color, selected: model.style.color == color) { model.chooseColor(color) }
                    }
                }
            }
        }
        .padding(.horizontal, 12).frame(height: 40)
        .glass(20)
    }

    /// 分组之间用细竖线隔开
    @ViewBuilder private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 2) { content() }
        Capsule().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 18)
    }
}

/// 粗细 / 字号 / 强度：直接画出每一档的样子
private struct LevelPicker: View {
    @Bindable var model: ScreenshotToolbarModel
    let tool: ScreenshotTool
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { level in
                Button { model.style.level = level; model.onStyleChanged() } label: {
                    glyph(level).frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(model.style.level == level ? Color.accentColor.opacity(0.18) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(L10n.tr(["screenshot.size.small", "screenshot.size.medium", "screenshot.size.large"][level]))
            }
        }
    }
    @ViewBuilder private func glyph(_ level: Int) -> some View {
        let on = model.style.level == level, ink = Color.primary.opacity(on ? 0.9 : 0.45)
        switch tool {
        case .text: Text("A").font(.system(size: [11, 14, 18][level], weight: .semibold, design: .rounded)).foregroundStyle(ink)
        case .marker: Circle().fill(ink).frame(width: [9, 12, 15][level], height: [9, 12, 15][level])
        case .mosaic: RoundedRectangle(cornerRadius: 1.5).fill(ink).frame(width: [7, 10, 14][level], height: [7, 10, 14][level])
        case .blur: Circle().fill(ink).frame(width: 13, height: 13).blur(radius: [0.4, 1.6, 3.2][level])
        case .highlighter: Capsule().fill(Color.yellow.opacity(on ? 0.9 : 0.5)).frame(width: 18, height: [5, 8, 11][level])
        default: Capsule().fill(ink).frame(width: 18, height: [2, 4, 7][level])
        }
    }
}

/// 一个圆形色块：顶部带一点高光，选中时外面套一圈环并轻轻放大
private struct Swatch: View {
    let color: ScreenshotColor, selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        let base = Color(.sRGB, red: color.r, green: color.g, blue: color.b)
        let top = color.lighter(0.22)
        Button(action: action) {
            Circle()
                .fill(LinearGradient(colors: [Color(.sRGB, red: top.r, green: top.g, blue: top.b), base], startPoint: .top, endPoint: .bottom))
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(color.luminance < 0.2 ? Color.white.opacity(0.4) : Color.black.opacity(color.luminance > 0.85 ? 0.22 : 0.08), lineWidth: 0.8))
                .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.85 : 0), lineWidth: 1.8).padding(-4))
                .shadow(color: base.opacity(selected ? 0.55 : 0.25), radius: selected ? 5 : 2, y: 1)
                .scaleEffect(selected ? 1.1 : (hovering ? 1.12 : 1))
                .animation(.spring(response: 0.25, dampingFraction: 0.62), value: selected)
                .animation(.spring(response: 0.25, dampingFraction: 0.62), value: hovering)
                .frame(width: 26, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .accessibilityLabel(L10n.tr("screenshot.color")).accessibilityValue(color.hex)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PaletteButton: View {
    let icon: String, label: String
    var selected = false, disabled = false, compact = false
    var tint: Color?
    var iconSize: CGFloat = 19
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            IconView(name: icon, size: iconSize)
                .frame(width: compact ? 26 : 36, height: compact ? 28 : 34)
                .foregroundStyle(selected ? Color.white : (tint ?? Color.primary))
                .background {
                    if selected { SelectedGlow() } else { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering && !disabled ? Color.primary.opacity(0.09) : .clear) }
                }
                .scaleEffect(hovering && !disabled && !selected ? 1.07 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.65), value: hovering)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.3 : 1)
        .onHover { hovering = $0 }
        .help(label).accessibilityLabel(label).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: 操作胶囊条（横向，带文字）+ 选项条

struct ScreenshotActionBarView: View {
    @Bindable var model: ScreenshotToolbarModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let summary = model.recognition { recognitionBar(summary) } else { actionBar }
            if model.recognition == nil, let tool = model.optionsTool, tool.usesColor || tool.usesLevel || tool.usesFill || tool.usesArrowStyle || tool.usesTextStyle {
                ScreenshotOptionsBar(model: model, tool: tool).transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
            if model.recognizing {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L10n.tr("screenshot.ocr.running")).font(.callout) }
                    .padding(.horizontal, 12).frame(height: 28).glass(14)
            } else if !model.message.isEmpty {
                Text(model.message).font(.callout).foregroundStyle(.orange).padding(.horizontal, 12).frame(height: 28).glass(14)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: model.optionsTool)
        .padding(10).fixedSize()
    }

    private var actionBar: some View {
        HStack(spacing: 2) {
            ActionButton(icon: "scan", title: L10n.tr("screenshot.ocr.short"), disabled: model.recognizing) { model.onOCR() }
            ActionButton(icon: "float", title: L10n.tr("screenshot.pin.short")) { model.onPin() }
            ActionButton(icon: "tray", title: L10n.tr("screenshot.save.short")) { model.onSave() }
            PrimaryButton(icon: "clip", title: L10n.tr("screenshot.copy.short"), help: L10n.tr("screenshot.confirm"), action: model.onConfirm)
            closeButton
        }
        .padding(.horizontal, 6).frame(height: 42)
        .glass(21)
    }

    private func recognitionBar(_ s: RecognitionSummary) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 2) {
                ActionButton(icon: "back", title: L10n.tr("screenshot.recog.back")) { model.onBackToAnnotate() }
                if s.hasOverlay { ActionButton(icon: "selecttext", title: L10n.tr("screenshot.recog.selectAll")) { model.onSelectAllText() } }
                ActionButton(icon: "openwindow", title: L10n.tr("screenshot.recog.window")) { model.onOpenResultWindow() }
                PrimaryButton(icon: "copytext", title: s.selectedCount > 0 ? L10n.format("screenshot.recog.copySelected", s.selectedCount) : L10n.tr("screenshot.recog.copyAll"), help: L10n.tr("screenshot.ocr.copy"), action: model.onCopyText)
                closeButton
            }
            .padding(.horizontal, 6).frame(height: 42).glass(21)
            Text(s.lineCount == 0 ? L10n.tr("screenshot.ocr.empty") : L10n.format("screenshot.ocr.lines", s.lineCount) + (s.engineNote.isEmpty ? "" : " · " + s.engineNote))
                .font(.caption).padding(.horizontal, 10).frame(height: 24).glass(12)
            ForEach(Array(s.codes.prefix(3).enumerated()), id: \.offset) { _, code in
                HStack(spacing: 6) {
                    IconView(name: "qr", size: 16)
                    Text(code.payload).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .leading)
                    Button(L10n.tr("screenshot.code.copy")) { model.onCopyCode(code) }.buttonStyle(.borderless)
                    if code.isURL { Button(L10n.tr("screenshot.code.open")) { model.onOpenCode(code) }.buttonStyle(.borderless) }
                }
                .padding(.horizontal, 10).frame(height: 28).glass(14)
            }
        }
    }

    private var closeButton: some View {
        Button(action: model.onCancel) {
            IconView(name: "close", size: 15).frame(width: 28, height: 30).foregroundStyle(Color.secondary).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(L10n.tr("screenshot.cancel")).accessibilityLabel(L10n.tr("screenshot.cancel"))
    }
}

private struct PrimaryButton: View {
    let icon: String, title: String, help: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) { IconView(name: icon, size: 17); Text(title).font(.system(size: 13, weight: .semibold)) }
                .padding(.horizontal, 13).frame(height: 30)
                .foregroundStyle(Color.white)
                .background(Capsule().fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.8)], startPoint: .top, endPoint: .bottom)).shadow(color: Color.accentColor.opacity(hovering ? 0.55 : 0.4), radius: hovering ? 7 : 5, y: 2))
                .scaleEffect(hovering ? 1.04 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.65), value: hovering)
        }
        .buttonStyle(.plain).padding(.leading, 4).onHover { hovering = $0 }.help(help).accessibilityLabel(help)
    }
}

private struct ActionButton: View {
    let icon: String, title: String
    var disabled = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) { IconView(name: icon, size: 17); Text(title).font(.system(size: 13)) }
                .padding(.horizontal, 9).frame(height: 30)
                .foregroundStyle(Color.primary)
                .background(Capsule().fill(hovering && !disabled ? Color.primary.opacity(0.09) : .clear))
                .scaleEffect(hovering && !disabled ? 1.04 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.65), value: hovering)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.35 : 1)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }
}
