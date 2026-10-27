import CoreText
import SwiftUI

enum Palette {
    static let cpu = Color(red: 0.38, green: 0.56, blue: 1.00)
    static let memory = Color(red: 0.66, green: 0.48, blue: 1.00)
    static let gpu = Color(red: 0.20, green: 0.78, blue: 0.72)
    static let disk = Color(red: 1.00, green: 0.62, blue: 0.28)
    static let down = Color(red: 0.25, green: 0.70, blue: 1.00)
    static let up = Color(red: 1.00, green: 0.42, blue: 0.58)
    static let battery = Color(red: 0.30, green: 0.82, blue: 0.45)

    static func level(_ percent: Double) -> Color {
        percent >= 90 ? Color(red: 1, green: 0.36, blue: 0.36) : percent >= 70 ? Color(red: 1, green: 0.72, blue: 0.2) : .clear
    }
}

// MARK: - Text

/// 次要文字颜色。SwiftUI 的 .secondary/.tertiary 在毛玻璃窗口里会走 vibrancy 混合，
/// 和背景糊在一起；这里用固定的不透明度，深浅色各自调到足够的对比度。
enum Ink {
    static let secondary = dynamic(dark: 0.76, light: 0.68)
    static let tertiary = dynamic(dark: 0.58, light: 0.52)

    private static func dynamic(dark: CGFloat, light: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: dark)
                : NSColor(white: 0, alpha: light)
        })
    }
}

// MARK: - Card

/// 磨砂玻璃卡片：半透明的亮色层 + 顶部更亮的细边，叠在面板的毛玻璃上
struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        let dark = scheme == .dark
        content
            .background { shape.fill(Color.white.opacity(dark ? 0.065 : 0.5)) }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(dark ? 0.16 : 0.9), .white.opacity(dark ? 0.03 : 0.35)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.7)
            }
            // 浅色模式下白色高光边在浅背景上看不出来，再加一圈很淡的深色细线勾出卡片边界
            .overlay {
                if !dark { shape.strokeBorder(Color.black.opacity(0.07), lineWidth: 0.5) }
            }
            .shadow(color: .black.opacity(dark ? 0.16 : 0.07), radius: dark ? 3 : 4, y: 1)
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

struct Tile<Accessory: View, Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(Typeface.ui(10, .bold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(Typeface.ui(11, .medium))
                    .foregroundStyle(Ink.secondary)
                Spacer(minLength: 0)
                accessory
                    .font(Typeface.ui(10.5, .medium))
                    .foregroundStyle(Ink.tertiary)
            }
            .frame(height: 15)   // 右上角有没有内容都保持同样高度
            content
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

extension Tile where Accessory == EmptyView {
    init(title: String, symbol: String, tint: Color, @ViewBuilder content: () -> Content) {
        self.init(title: title, symbol: symbol, tint: tint, accessory: { EmptyView() }, content: content)
    }
}

// MARK: - Numbers

/// 可选的字体。Geist 和圆体同时用于界面文字和数字；其他几种只换数字，标签保持系统字体
enum AppFont: String, CaseIterable {
    case geist, system, rounded, mono, din, serif

    var title: String {
        switch self {
        case .geist: "Geist"
        case .system: "SF Pro"
        case .rounded: L("圆体", "Rounded")
        case .mono: L("等宽", "Mono")
        case .din: "DIN"
        case .serif: L("衬线", "Serif")
        }
    }
}

/// 界面和数字字体，全部经过这里，换字体时只改一处
enum Typeface {
    nonisolated(unsafe) static var current: AppFont = .geist

    /// 注册随应用附带的 Geist（在 .app 的 Resources/Fonts 里；开发时直接从源码目录读取）
    static func registerBundledFonts() {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Fonts")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/Fonts").standardized
        guard let folder = [bundled, source].compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }

    /// 界面文字
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        switch current {
        case .geist: geist(size, weight)
        case .rounded: .system(size: size, weight: weight, design: .rounded)
        default: .system(size: size, weight: weight)
        }
    }

    /// 数字。font 默认是当前选择，设置里预览其他字体时传入
    static func number(_ size: CGFloat, weight: Font.Weight = .semibold, font: AppFont = Typeface.current) -> Font {
        switch font {
        // Geist 的半粗体偏厚，大号数字降一档更精致
        case .geist: geist(size, size >= 16 && weight == .semibold ? .medium : weight)
        case .system: .system(size: size, weight: weight)
        case .rounded: .system(size: size, weight: weight, design: .rounded)
        case .mono: .system(size: size * 0.92, weight: weight == .semibold ? .medium : weight, design: .monospaced)
        case .din: .custom("DINAlternate-Bold", size: size * 1.04)
        case .serif: .system(size: size, weight: weight, design: .serif)
        }
    }

    static func tracking(_ size: CGFloat) -> CGFloat {
        guard size >= 18 else { return 0 }
        return current == .mono || current == .din ? -size * 0.01 : -size * 0.02
    }

    private static func geist(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        let name = switch weight {
        case .bold, .heavy, .black: "Geist-Bold"
        case .semibold: "Geist-SemiBold"
        case .medium: "Geist-Medium"
        default: "Geist-Regular"
        }
        return .custom(name, size: size)
    }
}

struct BigNumber: View {
    let value: String
    let unit: String
    var size: CGFloat = 24

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(Typeface.number(size))
                .tracking(Typeface.tracking(size))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(unit)
                .font(Typeface.ui(size * 0.5, .medium))
                .foregroundStyle(Ink.secondary)
        }
        .animation(.snappy(duration: 0.35), value: value)
    }
}

/// 一行"标签 …… 数值"，左边是色点或小图标。单行、等宽数字，数值变化不会改变高度
struct Legend: View {
    let color: Color
    let label: String
    let value: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(Typeface.ui(8.5, .heavy))
                    .foregroundStyle(color)
                    .frame(width: 8)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(label).foregroundStyle(Ink.secondary)
            Spacer(minLength: 4)
            Text(value).monospacedDigit()
        }
        .font(Typeface.ui(11))
        .lineLimit(1)
    }
}

// MARK: - Bars

struct MeterBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

struct SegmentBar: View {
    let segments: [(value: Double, color: Color)]
    let total: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(segments.indices, id: \.self) { i in
                    Rectangle()
                        .fill(segments[i].color)
                        .frame(width: max(0, geo.size.width * segments[i].value / max(total, 1) - 1.5))
                }
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.08))
            .clipShape(Capsule())
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: segments.map(\.value))
    }
}

struct CoreBars: View {
    let cores: [Double]
    let tint: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(cores.indices, id: \.self) { i in
                GeometryReader { geo in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.08))
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(tint.opacity(0.4 + 0.6 * cores[i] / 100))
                            .frame(height: max(1.5, geo.size.height * min(cores[i], 100) / 100))
                    }
                }
                .hint(L("核心 \(i + 1)：", "Core \(i + 1): ") + "\(Int(cores[i].rounded()))%")
            }
        }
        .animation(.easeOut(duration: 0.4), value: cores)
    }
}

// MARK: - Charts

private func chartPoints(_ values: [Double], capacity: Int, maxValue: Double, in size: CGSize, inset: CGFloat) -> [CGPoint] {
    guard values.count > 1 else { return [] }
    let step = size.width / CGFloat(max(capacity - 1, 1))
    let startX = size.width - CGFloat(values.count - 1) * step
    let usable = size.height - inset
    return values.enumerated().map { i, v in
        CGPoint(x: startX + CGFloat(i) * step,
                y: size.height - usable * CGFloat(min(max(v / maxValue, 0), 1)))
    }
}

private func smoothLine(_ points: [CGPoint]) -> Path {
    var path = Path()
    guard let first = points.first else { return path }
    path.move(to: first)
    for i in 1..<points.count {
        let prev = points[i - 1], cur = points[i]
        let mid = CGPoint(x: (prev.x + cur.x) / 2, y: (prev.y + cur.y) / 2)
        path.addQuadCurve(to: mid, control: prev)
    }
    path.addLine(to: points[points.count - 1])
    return path
}

private func closedArea(_ line: Path, points: [CGPoint], bottom: CGFloat) -> Path {
    var area = line
    area.addLine(to: CGPoint(x: points[points.count - 1].x, y: bottom))
    area.addLine(to: CGPoint(x: points[0].x, y: bottom))
    area.closeSubpath()
    return area
}

struct Sparkline: View {
    let values: [Double]
    var maxValue: Double? = nil
    let tint: Color
    var capacity = SystemMonitor.historyLength
    /// 鼠标悬停时显示的读数；为 nil 时不响应悬停
    var readout: ChartReadout? = nil

    var body: some View {
        GeometryReader { geo in
            let top = max(maxValue ?? (values.max() ?? 1), 0.0001)
            let points = chartPoints(values, capacity: capacity, maxValue: top, in: geo.size, inset: 1.5)
            if points.count > 1 {
                let line = smoothLine(points)
                let area = closedArea(line, points: points, bottom: geo.size.height)
                ZStack {
                    area.fill(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                    line.stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            } else {
                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1).frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .overlay {
            if let readout {
                ChartScrubber(count: values.count, capacity: capacity, readout: readout) { index, size in
                    let top = max(maxValue ?? (values.max() ?? 1), 0.0001)
                    let points = chartPoints(values, capacity: capacity, maxValue: top, in: size, inset: 1.5)
                    return points.indices.contains(index) ? [(points[index], tint)] : []
                }
            }
        }
    }
}

/// 下载在中线以上，上传在中线以下
struct MirrorChart: View {
    let top: [Double]
    let bottom: [Double]
    let topTint: Color
    let bottomTint: Color
    var readout: ChartReadout? = nil

    var body: some View {
        GeometryReader { geo in
            let half = CGSize(width: geo.size.width, height: geo.size.height / 2)
            let peak = max(top.max() ?? 0, bottom.max() ?? 0, 10_000)
            VStack(spacing: 0) {
                Sparkline(values: top, maxValue: peak, tint: topTint)
                    .frame(height: half.height)
                Sparkline(values: bottom, maxValue: peak, tint: bottomTint)
                    .frame(height: half.height)
                    .scaleEffect(x: 1, y: -1)
            }
            .overlay { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5) }
        }
        .overlay {
            if let readout {
                ChartScrubber(count: top.count, capacity: SystemMonitor.historyLength, readout: readout) { index, size in
                    let half = CGSize(width: size.width, height: size.height / 2)
                    let peak = max(top.max() ?? 0, bottom.max() ?? 0, 10_000)
                    let up = chartPoints(top, capacity: SystemMonitor.historyLength, maxValue: peak, in: half, inset: 1.5)
                    let down = chartPoints(bottom, capacity: SystemMonitor.historyLength, maxValue: peak, in: half, inset: 1.5)
                    var markers: [(CGPoint, Color)] = []
                    if up.indices.contains(index) { markers.append((up[index], topTint)) }
                    // 下半部分是翻转画的，换算回整个图表的坐标
                    if down.indices.contains(index) {
                        markers.append((CGPoint(x: down[index].x, y: size.height - down[index].y), bottomTint))
                    }
                    return markers
                }
            }
        }
    }
}

// MARK: - Chart hover

/// 图表悬停读数：每个点之间隔多少秒、某个点显示什么文字
struct ChartReadout {
    let interval: Double
    let text: (Int) -> String
}

final class HoverLocation: ObservableObject {
    @Published var x: CGFloat?
}

/// 悬停读数的小卡片：数值 + 时间，浅色卡片风格，和面板里的卡片一致
struct ReadoutBubble: View {
    let value: String
    let detail: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        HStack(spacing: 5) {
            Text(value)
                .font(Typeface.ui(10.5, .semibold))
                .foregroundStyle(.primary)
            Text(detail)
                .font(Typeface.ui(10, .medium))
                .foregroundStyle(Ink.secondary)
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            shape.fill(scheme == .dark ? Color(white: 0.2).opacity(0.94) : Color.white.opacity(0.96))
                .overlay { shape.strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5) }
                .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.12), radius: 5, y: 2)
        }
    }
}

/// 悬停标出的数据点：带一圈柔光的小圆点
struct ReadoutDot: View {
    let tint: Color

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.22)).frame(width: 13, height: 13)
            Circle().fill(tint).frame(width: 6.5, height: 6.5)
                .overlay { Circle().strokeBorder(.white, lineWidth: 1.3) }
        }
    }
}

/// 竖直参考线，上下两端渐隐
struct ReadoutGuide: View {
    var body: some View {
        LinearGradient(colors: [.primary.opacity(0), .primary.opacity(0.3), .primary.opacity(0.05)],
                       startPoint: .top, endPoint: .bottom)
            .frame(width: 1)
    }
}

/// "8 秒前"、"现在"、"2 分 10 秒前"
func agoText(seconds: Int) -> String {
    seconds <= 0 ? L("现在", "now") : seconds < 60 ? L("\(seconds) 秒前", "\(seconds)s ago")
        : L("\(seconds / 60) 分 \(seconds % 60) 秒前", "\(seconds / 60)m \(seconds % 60)s ago")
}

/// 鼠标在图表上移动时，参考线 + 圆点标出最近的数据点，顶部显示读数和"几秒前"。
/// 标记本身不接收鼠标事件，否则指针一碰到它们就会被当成离开图表，读数会来回闪
private struct ChartScrubber: View {
    let count: Int
    let capacity: Int
    let readout: ChartReadout
    let markers: (Int, CGSize) -> [(CGPoint, Color)]
    @StateObject private var hover = HoverLocation()

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let index = hover.x.flatMap { index(at: $0, width: size.width) }
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hover.x = point.x
                        case .ended: hover.x = nil
                        }
                    }
                if let index {
                    let markerX = position(of: index, width: size.width)
                    Group {
                        ReadoutGuide()
                            .frame(height: size.height)
                            .offset(x: markerX - 0.5)
                        ForEach(Array(markers(index, size).enumerated()), id: \.offset) { _, marker in
                            ReadoutDot(tint: marker.1)
                                .offset(x: marker.0.x - 6.5, y: marker.0.y - 6.5)
                        }
                        ReadoutBubble(value: readout.text(index),
                                      detail: agoText(seconds: Int((Double(count - 1 - index) * readout.interval).rounded())))
                            // 以参考线为中心，但不超出图表左右边界
                            .alignmentGuide(.leading) { d in -min(max(markerX - d.width / 2, 0), size.width - d.width) }
                            .offset(y: -4)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            // 在数据点之间平滑滑动，而不是一格一格跳
            .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.9), value: index)
            .animation(.easeOut(duration: 0.12), value: index == nil)
        }
    }

    /// 数据靠右对齐（最新的点在最右边），和 chartPoints 的排布一致
    private func position(of index: Int, width: CGFloat) -> CGFloat {
        let step = width / CGFloat(max(capacity - 1, 1))
        return width - CGFloat(count - 1 - index) * step
    }

    private func index(at x: CGFloat, width: CGFloat) -> Int? {
        guard count > 1 else { return nil }
        let step = width / CGFloat(max(capacity - 1, 1))
        let fromRight = Int(((width - x) / step).rounded())
        let index = count - 1 - fromRight
        return index >= 0 ? min(index, count - 1) : nil
    }
}

// MARK: - Hover hints

/// 自定义悬停提示。面板属于后台应用、窗口不激活，系统的 .help 提示气泡不会出现，所以自己画。
/// 各视图用 .hint() 报告自己的位置和文字，面板根部的 HintOverlay 统一显示
@MainActor
final class HintCenter: ObservableObject {
    struct Hint: Equatable {
        let id: UUID
        let text: String
        let anchor: CGRect
    }

    static let space = "panel"
    @Published private(set) var hint: Hint?
    private var pending: DispatchWorkItem?

    func hover(id: UUID, text: String, anchor: CGRect, active: Bool) {
        pending?.cancel()
        guard active else {
            if hint?.id == id { hint = nil }
            return
        }
        let next = Hint(id: id, text: text, anchor: anchor)
        // 已经有提示在显示时（从一个元素移到另一个）立刻切换，否则稍等一下再出现
        if hint != nil {
            hint = next
            return
        }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hint = next } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    func dismiss() {
        pending?.cancel()
        hint = nil
    }
}

private struct HintCenterKey: EnvironmentKey {
    static let defaultValue: HintCenter? = nil
}

extension EnvironmentValues {
    var hintCenter: HintCenter? {
        get { self[HintCenterKey.self] }
        set { self[HintCenterKey.self] = newValue }
    }
}

final class HintAnchor: ObservableObject {
    let id = UUID()
    var frame: CGRect = .zero
}

private struct HintModifier: ViewModifier {
    let text: String
    @Environment(\.hintCenter) private var center
    @StateObject private var anchor = HintAnchor()

    func body(content: Content) -> some View {
        if let center, !text.isEmpty {
            content
                .background {
                    GeometryReader { geo in
                        let frame = geo.frame(in: .named(HintCenter.space))
                        Color.clear
                            .onAppear { anchor.frame = frame }
                            .onChange(of: frame) { _, new in anchor.frame = new }
                    }
                }
                .onHover { center.hover(id: anchor.id, text: text, anchor: anchor.frame, active: $0) }
        } else {
            content
        }
    }
}

extension View {
    /// 悬停一会儿后显示的说明文字（替代 .help）
    func hint(_ text: String) -> some View { modifier(HintModifier(text: text)) }
}

/// 在面板根部绘制当前的悬停提示：默认放在元素下方，放不下就放上方，左右不超出面板
struct HintOverlay: View {
    @ObservedObject var center: HintCenter

    var body: some View {
        GeometryReader { geo in
            // 放在 topLeading 的 ZStack 里，alignmentGuide 才能决定位置
            ZStack(alignment: .topLeading) {
                Color.clear
                if let hint = center.hint {
                HintBubble(text: hint.text)
                    .frame(maxWidth: 260, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .alignmentGuide(.leading) { d in
                        -min(max(hint.anchor.midX - d.width / 2, 8), geo.size.width - d.width - 8)
                    }
                    .alignmentGuide(.top) { d in
                        let below = hint.anchor.maxY + 6
                        return -(below + d.height <= geo.size.height - 4 ? below : hint.anchor.minY - d.height - 6)
                    }
                    .id(hint.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: center.hint)
    }
}

struct HintBubble: View {
    let text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Text(text)
            .font(Typeface.ui(11))
            .lineSpacing(2)
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background {
                shape.fill(scheme == .dark ? Color(white: 0.2).opacity(0.96) : Color.white.opacity(0.97))
                    .overlay { shape.strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5) }
                    .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.14), radius: 8, y: 3)
            }
    }
}

// MARK: - Buttons

/// 分段选择：一条浅色轨道，选中块在选项之间滑动；未选中的选项悬停时文字变亮
struct GlassSegmentedControl<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    var height: CGFloat = 20
    /// 每个选项用自己的字体显示（例如字体选择器），为 nil 时用界面字体
    var labelFont: ((Value) -> Font)?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var thumb

    init(_ title: String, selection: Binding<Value>, options: [(Value, String)], height: CGFloat = 20,
         labelFont: ((Value) -> Font)? = nil) {
        self.title = title
        self._selection = selection
        self.options = options
        self.height = height
        self.labelFont = labelFont
    }

    var body: some View {
        let track = RoundedRectangle(cornerRadius: height / 2 - 1, style: .continuous)
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                SegmentButton(title: option.1, selected: selection == option.0, height: height,
                              font: labelFont?(option.0), thumb: thumb, reduceMotion: reduceMotion) {
                    selection = option.0
                }
            }
        }
        .padding(1.5)
        .background {
            track.fill(Color.primary.opacity(scheme == .dark ? 0.08 : 0.055))
                .overlay { track.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
        }
        .fixedSize()
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.8), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

private struct SegmentButton: View {
    let title: String
    let selected: Bool
    let height: CGFloat
    let font: Font?
    let thumb: Namespace.ID
    let reduceMotion: Bool
    let action: () -> Void
    @StateObject private var hover = HoverState()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: height / 2 - 2.5, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(font ?? Typeface.ui(height <= 18 ? 10.5 : 11, selected ? .semibold : .medium))
                .foregroundStyle(selected || hover.hovering ? Color.primary : Ink.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .padding(.horizontal, height <= 18 ? 8 : 9)
                .frame(height: height - 3)
                .fixedSize()
                .background {
                    if selected {
                        shape.fill(scheme == .dark ? Color.white.opacity(0.17) : Color.white)
                            .overlay { shape.strokeBorder(Color.primary.opacity(scheme == .dark ? 0.06 : 0.04), lineWidth: 0.5) }
                            .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.1), radius: 1.5, y: 0.5)
                            .matchedGeometryEffect(id: "thumb", in: thumb)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hover.hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.hovering)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 胶囊按钮：浅色底 + 细边，悬停变亮、按下缩小；prominent 用强调色，给"下载新版本"这类主要操作
struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        PillFace(pressed: configuration.isPressed, prominent: prominent) { configuration.label }
    }
}

private struct PillFace<Label: View>: View {
    let pressed: Bool
    let prominent: Bool
    @ViewBuilder var label: Label
    @StateObject private var hover = HoverState()
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = Capsule(style: .continuous)
        let lift = pressed ? 0.14 : hover.hovering ? 0.1 : 0.06
        label
            .font(Typeface.ui(11, .medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 21)
            .background {
                if prominent {
                    shape.fill(Color.accentColor.opacity(pressed ? 0.8 : hover.hovering ? 0.92 : 1))
                        .shadow(color: Color.accentColor.opacity(0.3), radius: 3, y: 1)
                } else {
                    shape.fill(Color.primary.opacity(scheme == .dark ? lift + 0.02 : lift))
                        .overlay { shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5) }
                }
            }
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.55)
            .scaleEffect(pressed ? 0.95 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: pressed)
            .animation(.easeOut(duration: 0.12), value: hover.hovering)
            .onHover { hover.hovering = $0 }
    }
}

/// 一直转的图标，用于"正在检查"
struct SpinningSymbol: View {
    let name: String
    @StateObject private var state = HoverState()

    var body: some View {
        Image(systemName: name)
            .rotationEffect(.degrees(state.hovering ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: state.hovering)
            .onAppear { state.hovering = true }
    }
}

/// 按下时轻微缩小，松开弹回
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct SubtleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverHighlight(pressed: configuration.isPressed) { configuration.label }
    }
}

/// CLT 自带的 SDK 里 @State 是宏且缺少插件，所以用 StateObject 保存悬停状态
final class HoverState: ObservableObject {
    @Published var hovering = false
}

private struct HoverHighlight<Label: View>: View {
    let pressed: Bool
    @ViewBuilder var label: Label
    @StateObject private var state = HoverState()

    var body: some View {
        label
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(pressed ? 0.14 : state.hovering ? 0.08 : 0))
            }
            .contentShape(Rectangle())
            .onHover { state.hovering = $0 }
    }
}

private struct CardHoveredKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 所在的可点击卡片正被鼠标悬停
    var cardHovered: Bool {
        get { self[CardHoveredKey.self] }
        set { self[CardHoveredKey.self] = newValue }
    }
}

/// 可点击卡片右侧的小箭头：卡片被悬停时往右轻推一下，提示可以点进去
struct DisclosureChevron: View {
    var size: CGFloat = 10
    @Environment(\.cardHovered) private var hovered
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "chevron.right")
            .font(Typeface.ui(size, .semibold))
            .foregroundStyle(hovered ? Ink.secondary : Ink.tertiary)
            .offset(x: hovered && !reduceMotion ? 2.5 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hovered)
    }
}

/// 可点击的卡片：悬停时轻微提亮，按下时略微缩小
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardHover(pressed: configuration.isPressed) { configuration.label }
    }
}

private struct CardHover<Label: View>: View {
    let pressed: Bool
    @ViewBuilder var label: Label
    @StateObject private var state = HoverState()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        label
            .environment(\.cardHovered, state.hovering)
            .overlay { shape.fill(Color.primary.opacity(pressed ? 0.07 : state.hovering ? 0.035 : 0)).allowsHitTesting(false) }
            .contentShape(shape)
            .scaleEffect(pressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: state.hovering)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .onHover { state.hovering = $0 }
    }
}
