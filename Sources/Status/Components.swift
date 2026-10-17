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
            .background(shape.fill(Color.white.opacity(dark ? 0.065 : 0.5)))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(dark ? 0.16 : 0.9), .white.opacity(dark ? 0.03 : 0.35)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.7)
            )
            .shadow(color: .black.opacity(dark ? 0.16 : 0.05), radius: 3, y: 1)
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
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Ink.secondary)
                Spacer(minLength: 0)
                accessory
                    .font(.system(size: 10.5, weight: .medium))
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

struct BigNumber: View {
    let value: String
    let unit: String
    var size: CGFloat = 24

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(unit)
                .font(.system(size: size * 0.5, weight: .medium, design: .rounded))
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
                    .font(.system(size: 8.5, weight: .heavy))
                    .foregroundStyle(color)
                    .frame(width: 8)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(label).foregroundStyle(Ink.secondary)
            Spacer(minLength: 4)
            Text(value).monospacedDigit()
        }
        .font(.system(size: 11))
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
    }
}

/// 下载在中线以上，上传在中线以下
struct MirrorChart: View {
    let top: [Double]
    let bottom: [Double]
    let topTint: Color
    let bottomTint: Color

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
            .overlay(Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5))
        }
    }
}

// MARK: - Buttons

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
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(pressed ? 0.14 : state.hovering ? 0.08 : 0))
            )
            .contentShape(Rectangle())
            .onHover { state.hovering = $0 }
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
            .overlay(shape.fill(Color.primary.opacity(pressed ? 0.07 : state.hovering ? 0.035 : 0)).allowsHitTesting(false))
            .contentShape(shape)
            .scaleEffect(pressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: state.hovering)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .onHover { state.hovering = $0 }
    }
}
