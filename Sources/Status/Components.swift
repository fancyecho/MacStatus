import CoreText
import SwiftUI

/// 数据配色。颜色只用在数据上（曲线、进度条、数值状态），卡片标题和图标保持单色，界面才不显得花
enum Palette {
    static let cpu = Color(red: 0.36, green: 0.56, blue: 1.00)
    static let memory = Color(red: 0.67, green: 0.50, blue: 1.00)
    static let gpu = Color(red: 0.20, green: 0.78, blue: 0.70)
    static let disk = Color(red: 1.00, green: 0.63, blue: 0.30)
    static let down = Color(red: 0.28, green: 0.70, blue: 1.00)
    static let up = Color(red: 1.00, green: 0.44, blue: 0.58)
    static let battery = Color(red: 0.30, green: 0.82, blue: 0.47)

    static func level(_ percent: Double) -> Color {
        percent >= 90 ? Color(red: 1, green: 0.36, blue: 0.36) : percent >= 70 ? Color(red: 1, green: 0.72, blue: 0.2) : .clear
    }
}

// MARK: - Text

/// 次要文字颜色。SwiftUI 的 .secondary/.tertiary 在毛玻璃窗口里会走 vibrancy 混合，
/// 和背景糊在一起；这里用固定的不透明度，深浅色各自调到足够的对比度。
enum Ink {
    static let secondary = dynamic(dark: 0.74, light: 0.66)
    static let tertiary = dynamic(dark: 0.52, light: 0.48)
    /// 卡片里的分隔线、空轨道
    static let hairline = dynamic(dark: 0.08, light: 0.07)

    private static func dynamic(dark: CGFloat, light: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: dark)
                : NSColor(white: 0, alpha: light)
        })
    }
}

/// 卡片和分组的小标题：英文用小号大写加字距，中文保持原样（大写对汉字没有意义，字距会显得松散）
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        if Lang.isChinese {
            Text(text).font(Typeface.ui(11, .medium)).foregroundStyle(Ink.secondary)
        } else {
            Text(text.uppercased()).font(Typeface.ui(9.5, .semibold)).tracking(0.7).foregroundStyle(Ink.secondary)
        }
    }
}

// MARK: - Card

/// 卡片：只是一层很淡的色调和一圈发丝细边。面板本身已经是玻璃，卡片不再叠高光边和阴影，
/// 层次靠明度区分，整体更干净
struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        let dark = scheme == .dark
        content
            .background { shape.fill(dark ? Color.white.opacity(0.055) : Color.white.opacity(0.66)) }
            .overlay { shape.strokeBorder(dark ? Color.white.opacity(0.075) : Color.black.opacity(0.06), lineWidth: 0.5) }
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

struct Tile<Accessory: View, Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(Typeface.ui(9.5, .semibold))
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: 12)
                SectionLabel(title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                accessory
                    .font(Typeface.ui(10.5, .medium))
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
            }
            .frame(height: 14)   // 右上角有没有内容都保持同样高度
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

extension Tile where Accessory == EmptyView {
    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, symbol: symbol, accessory: { EmptyView() }, content: content)
    }
}

// MARK: - Numbers

/// 界面和数字字体，全部经过这里：统一用 SF Rounded，圆润、清晰，等宽数字也好看
enum Typeface {
    /// 界面文字
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// 数字：大号数字降一档字重，更轻盈
    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: size >= 18 && weight == .semibold ? .medium : weight, design: .rounded)
    }

    static func tracking(_ size: CGFloat) -> CGFloat {
        size >= 18 ? -size * 0.012 : 0
    }
}

struct BigNumber: View {
    let value: String
    let unit: String
    var size: CGFloat = 26

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2.5) {
            Text(value)
                .font(Typeface.number(size))
                .tracking(Typeface.tracking(size))
                .monospacedDigit()
                // 实时数据每一两秒就变，滚动数字会一直晃；只做一次很短的交叉淡化
                .contentTransition(.opacity)
            Text(unit)
                .font(Typeface.ui(max(10, size * 0.44), .medium))
                .foregroundStyle(Ink.tertiary)
        }
        .animation(.easeInOut(duration: 0.25), value: value)
    }
}

/// 一行"标签 …… 数值"，左边是色块或小图标。单行、等宽数字，数值变化不会改变高度
struct Legend: View {
    let color: Color
    let label: String
    let value: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(Typeface.ui(8.5, .heavy))
                    .foregroundStyle(color)
                    .frame(width: 7)
            } else {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 7, height: 7)
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
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.hairline)
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.7), tint], startPoint: .leading, endPoint: .trailing))
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
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(segments.indices, id: \.self) { i in
                    Capsule()
                        .fill(segments[i].color)
                        .frame(width: max(0, geo.size.width * segments[i].value / max(total, 1) - 2))
                }
                Spacer(minLength: 0)
            }
            .background(Capsule().fill(Ink.hairline))
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: segments.map(\.value))
    }
}

/// 每个核心一根细柱，占用越高颜色越实
struct CoreBars: View {
    let cores: [Double]
    let tint: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: cores.count > 12 ? 1.5 : 2.5) {
            ForEach(cores.indices, id: \.self) { i in
                GeometryReader { geo in
                    let radius = min(2, geo.size.width / 2)
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Ink.hairline)
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(tint.opacity(0.35 + 0.65 * min(cores[i], 100) / 100))
                            .frame(height: max(2, geo.size.height * min(cores[i], 100) / 100))
                    }
                }
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

/// 把一条折线向下封闭到底边，用来填充曲线下方的渐变
func closedArea(_ line: Path, from start: CGFloat, to end: CGFloat, bottom: CGFloat) -> Path {
    var area = line
    area.addLine(to: CGPoint(x: end, y: bottom))
    area.addLine(to: CGPoint(x: start, y: bottom))
    area.closeSubpath()
    return area
}

/// 图表里的水平参考线：很淡的点线，给曲线一个刻度感
struct ChartGuides: View {
    /// 0…1，从底部算起
    let levels: [Double]

    var body: some View {
        GeometryReader { geo in
            Path { path in
                for level in levels {
                    let y = (geo.size.height * (1 - level)).rounded() + 0.25
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(Color.primary.opacity(0.09), style: StrokeStyle(lineWidth: 0.5, dash: [1.5, 2.5]))
        }
        .allowsHitTesting(false)
    }
}

/// 曲线最右端的"现在"：实心小点 + 一圈柔光
private struct ChartHead: View {
    let tint: Color

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.2)).frame(width: 10, height: 10)
            Circle().fill(tint).frame(width: 4.5, height: 4.5)
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var maxValue: Double? = nil
    let tint: Color
    var capacity = SystemMonitor.historyLength
    /// 参考线位置（0…1）
    var guides: [Double] = []
    /// 在最新的点上画一个小圆点
    var head = true
    /// 鼠标悬停时显示的读数；为 nil 时不响应悬停
    var readout: ChartReadout? = nil

    var body: some View {
        GeometryReader { geo in
            let top = max(maxValue ?? (values.max() ?? 1), 0.0001)
            let points = chartPoints(values, capacity: capacity, maxValue: top, in: geo.size, inset: 2)
            ZStack(alignment: .topLeading) {
                if !guides.isEmpty { ChartGuides(levels: guides) }
                if points.count > 1, let last = points.last {
                    let line = smoothLine(points)
                    let area = closedArea(line, from: points[0].x, to: last.x, bottom: geo.size.height)
                    area.fill(LinearGradient(colors: [tint.opacity(0.24), tint.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                    line.stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    if head {
                        ChartHead(tint: tint).position(last)
                    }
                } else {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: geo.size.height - 0.5))
                        path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height - 0.5))
                    }
                    .stroke(Color.primary.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [1.5, 2.5]))
                }
            }
        }
        .overlay {
            if let readout {
                ChartScrubber(count: values.count, capacity: capacity, readout: readout) { index, size in
                    let top = max(maxValue ?? (values.max() ?? 1), 0.0001)
                    let points = chartPoints(values, capacity: capacity, maxValue: top, in: size, inset: 2)
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
            .overlay { Rectangle().fill(Ink.hairline).frame(height: 0.5) }
        }
        .overlay {
            if let readout {
                ChartScrubber(count: top.count, capacity: SystemMonitor.historyLength, readout: readout) { index, size in
                    let half = CGSize(width: size.width, height: size.height / 2)
                    let peak = max(top.max() ?? 0, bottom.max() ?? 0, 10_000)
                    let up = chartPoints(top, capacity: SystemMonitor.historyLength, maxValue: peak, in: half, inset: 2)
                    let down = chartPoints(bottom, capacity: SystemMonitor.historyLength, maxValue: peak, in: half, inset: 2)
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

    var body: some View {
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
        .padding(.vertical, 3.5)
        .popoverSurface(radius: 7)
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

/// 浮层卡片的底：不透明的抬起卡片 + 发丝边 + 两层柔和阴影。不用毛玻璃：面板已经是玻璃，再叠一层只会更乱
struct PopoverSurface: ViewModifier {
    var radius: CGFloat = 10
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = scheme == .dark
        content.background {
            shape.fill(dark ? Color(white: 0.2) : Color.white)
                .overlay { shape.strokeBorder(dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08), lineWidth: 0.5) }
                .shadow(color: .black.opacity(dark ? 0.4 : 0.1), radius: 14, y: 6)
                .shadow(color: .black.opacity(dark ? 0.25 : 0.06), radius: 1.5, y: 0.5)
        }
    }
}

extension View {
    func popoverSurface(radius: CGFloat = 10) -> some View { modifier(PopoverSurface(radius: radius)) }
}

/// 悬停提示的内容：标题，可选的"标签 … 数值"几行，和一段补充说明
struct HintContent: Equatable {
    struct Row: Equatable {
        let label: String
        let value: String
        var tint: Color? = nil
    }

    var title: String
    var rows: [Row] = []
    var note: String? = nil

    /// 纯文字：多行时第一行作标题、其余作说明；一句话就只是说明，不加粗
    init(_ text: String) {
        let lines = text.split(separator: "\n", maxSplits: 1).map(String.init)
        title = lines.count > 1 ? lines[0] : ""
        note = lines.last
    }

    init(title: String, rows: [Row] = [], note: String? = nil) {
        self.title = title
        self.rows = rows
        self.note = note
    }

    var isEmpty: Bool { title.isEmpty && rows.isEmpty && (note ?? "").isEmpty }
}

/// 自定义悬停提示。面板属于后台应用、窗口不激活，系统的 .help 提示气泡不会出现，所以自己画。
/// 位置取悬停时鼠标在屏幕上的实际位置（和系统提示一样出现在指针下方），显示时再换算到提示层里。
/// 不用 SwiftUI 的布局坐标：元素常处在展开、翻页、滚动之中，测到的坐标会过期或换算错，提示就会错位
@MainActor
final class HintCenter: ObservableObject {
    struct Hint: Equatable {
        let id: UUID
        let content: HintContent
        /// 屏幕坐标（左下角原点）
        let screenPoint: CGPoint
    }
    @Published private(set) var hint: Hint?
    private var pending: DispatchWorkItem?

    /// 指针在带提示的元素上移动：停稳一会儿后出现；已有提示时直接换成新的
    func track(id: UUID, content: HintContent) {
        if hint?.id == id {
            // 内容随数据刷新时原地更新，位置不动
            if hint?.content != content, let current = hint { hint = Hint(id: id, content: content, screenPoint: current.screenPoint) }
            return
        }
        pending?.cancel()
        if hint != nil {
            hint = Hint(id: id, content: content, screenPoint: NSEvent.mouseLocation)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hint = Hint(id: id, content: content, screenPoint: NSEvent.mouseLocation) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func end(id: UUID) {
        pending?.cancel()
        if hint?.id == id { hint = nil }
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
}

private struct HintModifier: ViewModifier {
    let content: HintContent
    @Environment(\.hintCenter) private var center
    @StateObject private var anchor = HintAnchor()

    func body(content view: Content) -> some View {
        if let center, !content.isEmpty {
            view
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active: center.track(id: anchor.id, content: content)
                    case .ended: center.end(id: anchor.id)
                    }
                }
        } else {
            view
        }
    }
}

extension View {
    /// 悬停一会儿后显示的说明（替代 .help）。只给真正需要补充信息的地方用
    func hint(_ text: String) -> some View { modifier(HintModifier(content: HintContent(text))) }
    func hint(_ content: HintContent) -> some View { modifier(HintModifier(content: content)) }
}

/// 在面板根部绘制当前的悬停提示：放在指针右下方，放不下就放上方，左右不超出面板
struct HintOverlay: View {
    @ObservedObject var center: HintCenter

    var body: some View {
        GeometryReader { geo in
            let hint = center.hint
            let point = hint.flatMap { Self.localPoint($0.screenPoint, overlay: geo.frame(in: .global)) }
            HintPlacement(point: point ?? .zero) {
                if let hint, point != nil {
                    HintBubble(content: hint.content)
                        .id(hint.id)
                        .transition(.opacity.combined(with: .offset(y: -3)))
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.16), value: center.hint?.id)
    }

    /// 屏幕坐标 → 提示层坐标：先换到面板窗口里（SwiftUI 的 global 是窗口内容区、左上角原点），再减去提示层的位置
    private static func localPoint(_ screen: CGPoint, overlay: CGRect) -> CGPoint? {
        guard let window = NSApp.windows.first(where: { $0 is StatusPanel }), let content = window.contentView else { return nil }
        let inWindow = window.convertPoint(fromScreen: screen)
        return CGPoint(x: inWindow.x - overlay.minX, y: content.bounds.height - inWindow.y - overlay.minY)
    }
}

/// 先按最多 250 宽量出气泡的真实尺寸（文字会换行），再据此摆放。
/// 不能用 .frame(maxWidth:)：弹性框会直接撑满 250，按它算右边界会把提示推到左边
private struct HintPlacement: Layout {
    let point: CGPoint

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let bubble = subviews.first else { return }
        let size = bubble.sizeThatFits(ProposedViewSize(width: min(250, bounds.width - 16), height: nil))
        let x = min(max(point.x - 14, 8), bounds.width - size.width - 8)
        let below = point.y + 20
        let y = below + size.height <= bounds.height - 6 ? below : point.y - size.height - 10
        bubble.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
    }
}

/// 提示卡片：标题、两列的数据行（标签淡、数值实且等宽对齐）、底部一段说明，用发丝线隔开
struct HintBubble: View {
    let content: HintContent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !content.title.isEmpty {
                Text(content.title)
                    .font(Typeface.ui(11.5, .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !content.rows.isEmpty {
                VStack(spacing: 4) {
                    ForEach(content.rows.indices, id: \.self) { index in
                        let row = content.rows[index]
                        HStack(spacing: 12) {
                            Text(row.label).foregroundStyle(Ink.secondary)
                            Spacer(minLength: 8)
                            Text(row.value).foregroundStyle(row.tint ?? .primary).monospacedDigit()
                        }
                        .font(Typeface.ui(10.5, .medium))
                        .lineLimit(1)
                    }
                }
                .padding(.top, 8)
            }
            if let note = content.note {
                if content.rows.isEmpty {
                    if !content.title.isEmpty { Color.clear.frame(height: 3) }
                } else {
                    Rectangle().fill(Ink.hairline).frame(height: 0.5).padding(.vertical, 7)
                }
                Text(note)
                    .font(Typeface.ui(content.title.isEmpty && content.rows.isEmpty ? 11 : 10.5))
                    .foregroundStyle(content.title.isEmpty && content.rows.isEmpty ? Color.primary : Ink.secondary)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(minWidth: content.rows.isEmpty ? 0 : 200, alignment: .leading)
        .popoverSurface()
    }
}

// MARK: - Scrolling

/// 面板里的滚动区：固定高度、隐藏滚动条，上下边缘在还能继续滚动时渐隐，四角跟卡片同心
struct PanelScrollView<Content: View>: View {
    @ViewBuilder var content: Content
    @StateObject private var metrics = ScrollMetricsState()
    private let space = "panel-scroll"

    /// 屏幕再矮也至少 260，最高 540
    static var viewportHeight: CGFloat {
        min(540, max(260, (NSScreen.main?.visibleFrame.height ?? 800) - 160))
    }

    var body: some View {
        let height = Self.viewportHeight
        ScrollView {
            content
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(key: ScrollMetricsKey.self,
                                               value: ScrollMetrics(top: geo.frame(in: .named(space)).minY, height: geo.size.height))
                    }
                }
                .padding(.horizontal, 1)
                .padding(.bottom, 3)
        }
        .coordinateSpace(name: space)
        .scrollIndicators(.hidden)
        .frame(height: height)
        .mask {
            LinearGradient(stops: [
                .init(color: metrics.top < -1 ? .clear : .black, location: 0),
                .init(color: .black, location: 12 / height),
                .init(color: .black, location: 1 - 12 / height),
                .init(color: metrics.top + metrics.height > height + 1 ? .clear : .black, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .onPreferenceChange(ScrollMetricsKey.self) { value in
            MainActor.assumeIsolated { metrics.update(value) }
        }
    }
}

@MainActor
private final class ScrollMetricsState: ObservableObject {
    @Published private(set) var top: CGFloat = 0
    @Published private(set) var height: CGFloat = 0

    func update(_ value: ScrollMetrics) {
        if abs(value.top - top) > 0.5 { top = value.top }
        if abs(value.height - height) > 0.5 { height = value.height }
    }
}

private struct ScrollMetrics: Equatable {
    var top: CGFloat = 0
    var height: CGFloat = 0
}

private struct ScrollMetricsKey: PreferenceKey {
    static let defaultValue = ScrollMetrics()
    static func reduce(value: inout ScrollMetrics, nextValue: () -> ScrollMetrics) { value = nextValue() }
}

// MARK: - Buttons

/// 分段选择：一条浅色轨道，选中块在选项之间滑动；未选中的选项悬停时文字变亮
struct GlassSegmentedControl<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    var height: CGFloat = 20
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var thumb

    init(_ title: String, selection: Binding<Value>, options: [(Value, String)], height: CGFloat = 20) {
        self.title = title
        self._selection = selection
        self.options = options
        self.height = height
    }

    var body: some View {
        let track = RoundedRectangle(cornerRadius: height / 2 - 1, style: .continuous)
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                SegmentButton(title: option.1, selected: selection == option.0, height: height,
                              thumb: thumb, reduceMotion: reduceMotion) {
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
    let thumb: Namespace.ID
    let reduceMotion: Bool
    let action: () -> Void
    @StateObject private var hover = HoverState()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: height / 2 - 2.5, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(Typeface.ui(height <= 18 ? 10.5 : 11, selected ? .semibold : .medium))
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

/// 圆形图标按钮：平时只有一圈很淡的底，悬停变亮，按下缩小。用于页眉、页脚这类工具按钮
struct IconButtonStyle: ButtonStyle {
    var diameter: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        IconButtonFace(pressed: configuration.isPressed, diameter: diameter) { configuration.label }
    }
}

private struct IconButtonFace<Label: View>: View {
    let pressed: Bool
    let diameter: CGFloat
    @ViewBuilder var label: Label
    @StateObject private var hover = HoverState()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let fill = pressed ? 0.16 : hover.hovering ? 0.11 : 0.055
        label
            .font(Typeface.ui(11.5, .medium))
            .foregroundStyle(hover.hovering ? Color.primary : Ink.secondary)
            .frame(width: diameter, height: diameter)
            .background {
                Circle().fill(dark ? Color.white.opacity(fill + 0.01) : Color.black.opacity(fill * 0.8))
            }
            .contentShape(Circle())
            .scaleEffect(pressed ? 0.92 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: pressed)
            .animation(.easeOut(duration: 0.12), value: hover.hovering)
            .onHover { hover.hovering = $0 }
    }
}

/// 面板里的开关。面板属于后台应用、从不激活，系统开关在这里打开时也是灰色，看不出开没开；
/// 自己画一个：打开时用强调色，旋钮带弹簧滑动
struct PanelSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        PanelSwitch(isOn: configuration.$isOn) { configuration.label }
    }
}

private struct PanelSwitch<Label: View>: View {
    @Binding var isOn: Bool
    @ViewBuilder var label: Label
    @StateObject private var hover = HoverState()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dark = scheme == .dark
        let width: CGFloat = 30, height: CGFloat = 18, inset: CGFloat = 2
        let off = dark ? Color.white.opacity(hover.hovering ? 0.2 : 0.15) : Color.black.opacity(hover.hovering ? 0.13 : 0.09)
        HStack(spacing: 6) {
            label
            Capsule(style: .continuous)
                .fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(off))
                .overlay { Capsule(style: .continuous).strokeBorder(Color.black.opacity(isOn ? 0.06 : 0.04), lineWidth: 0.5) }
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.22), radius: 1.2, y: 0.6)
                        .padding(inset)
                }
                .frame(width: width, height: height)
                .contentShape(Capsule())
                .onTapGesture { isOn.toggle() }
                .onHover { hover.hovering = $0 }
        }
        .opacity(enabled ? 1 : 0.5)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.72), value: isOn)
        .animation(.easeOut(duration: 0.12), value: hover.hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? L("开", "On") : L("关", "Off"))
        .accessibilityAction { isOn.toggle() }
    }
}

/// 文字在前、小图标在后，例如"活动监视器 ↗"
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.font(Typeface.ui(8.5, .bold)).opacity(0.75)
        }
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
