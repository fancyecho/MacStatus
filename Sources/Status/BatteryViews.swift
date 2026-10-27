import SwiftUI

// MARK: - Shared

private enum PowerPalette {
    static let system = Palette.cpu
    static let battery = Palette.battery
    static let adapter = Color(red: 1.0, green: 0.74, blue: 0.25)
}

/// 用于概览卡片的状态（不含时间），例如"已暂停充电"
private func batteryState(_ b: BatterySnapshot, _ e: BatteryEstimate?) -> String {
    let state: String = switch e?.kind {
    case .toFull, .toLimit: L("充电中", "Charging")
    case .atLimit(let limit): L("已达充电上限 \(limit)%", "At charge limit \(limit)%")
    case .full: L("已充满", "Fully charged")
    case .paused: L("已暂停充电", "Charging paused")
    case .remaining, nil: b.onAC ? L("已接通电源", "Plugged in") : L("使用电池", "On battery")
    }
    return b.lowPowerMode ? state + L(" · 低电量模式", " · Low Power") : state
}

/// 详情页左侧：只说电从哪来，例如"已接通电源 · 低电量模式"
private func powerSource(_ b: BatterySnapshot) -> String {
    let source = b.onAC ? (b.isCharging ? L("正在充电", "Charging") : L("已接通电源", "Plugged in")) : L("使用电池", "On battery")
    return b.lowPowerMode ? source + L(" · 低电量模式", " · Low Power") : source
}

/// 概览卡片用的一行摘要，例如"充电中 · 1:12 后到 90%"
private func batterySummary(_ b: BatterySnapshot, _ e: BatteryEstimate?) -> String {
    guard let e else { return batteryState(b, nil) }
    // 中文："1:12 后充满" / "38 分钟后充满"，汉字结尾时不再加空格
    let time = e.minutes.map { $0 >= 60 && Lang.isChinese ? Fmt.minutes($0) + " " : Fmt.minutes($0) }
    let estimating = L("估算中", "estimating")
    switch e.kind {
    case .toFull: return L("充电中 · ", "Charging · ") + (time.map { L("\($0)后充满", "full in \($0)") } ?? estimating)
    case .toLimit(let limit): return L("充电中 · ", "Charging · ") + (time.map { L("\($0)后到 \(limit)%", "\(limit)% in \($0)") } ?? estimating)
    case .remaining: return L("使用电池 · ", "On battery · ") + (time.map { L("剩余 \($0)", "\($0) left") } ?? estimating)
    default: return batteryState(b, e)
    }
}

private func wattText(_ value: Double?, signed: Bool = false) -> String {
    guard let value else { return "—" }
    let text = String(format: "%.1f W", abs(value))
    guard signed, abs(value) >= 0.05 else { return text }
    return (value > 0 ? "+" : "−") + text
}

struct BatteryGlyph: View {
    let percent: Int
    let charging: Bool
    var lowPower = false
    var width: CGFloat = 34

    var body: some View {
        let height = width * 0.53
        // 和系统一致：低电量模式黄色，电量低且没在充电时红色，其余绿色
        let tint = lowPower ? Color(red: 1.0, green: 0.8, blue: 0.0)
            : percent <= 20 && !charging ? Color.red : Palette.battery
        ZStack {
            HStack(spacing: 1.5) {
                RoundedRectangle(cornerRadius: height * 0.28, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.35), lineWidth: 1.2)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            let fill = RoundedRectangle(cornerRadius: height * 0.17, style: .continuous)
                            fill
                                .fill(tint)
                                .overlay { if charging { ChargingSheen().clipShape(fill) } }
                                .frame(width: max(3, (geo.size.width - 5) * CGFloat(percent) / 100))
                                .padding(2.5)
                        }
                    }
                    .frame(width: width, height: height)
                Capsule().fill(Color.primary.opacity(0.35)).frame(width: 2, height: height * 0.33)
            }
            if charging {
                Image(systemName: "bolt.fill")
                    .font(Typeface.ui(height * 0.55, .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1)
                    .offset(x: -2)
            }
        }
    }
}

// MARK: - 24-hour history

/// 最近 24 小时的电量曲线：充电时段用浅绿底纹标出，20% 处一条虚线；悬停看某一刻的电量和时间
private struct BatteryHistoryCard: View {
    let points: [BatteryHistory.Point]
    @StateObject private var hover = HoverLocation()

    var body: some View {
        Tile(title: L("最近 24 小时", "Last 24 Hours"), symbol: "chart.xyaxis.line", tint: Palette.battery) {
            if points.count >= 2, let low = points.map(\.percent).min(), let high = points.map(\.percent).max() {
                Text("\(low)% – \(high)%").monospacedDigit()
            }
        } content: {
            if points.count < 2 {
                Text(L("电量记录从现在开始积累，每 5 分钟记一次，退出应用也不会丢失。", "Battery level is recorded every 5 minutes from now on, and kept when you quit the app."))
                    .font(Typeface.ui(10.5))
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                chart.frame(height: 64)
                HStack {
                    Text(L("24 小时前", "24h ago"))
                    Spacer()
                    Text(L("12 小时前", "12h ago"))
                    Spacer()
                    Text(L("现在", "Now"))
                }
                .font(Typeface.ui(9.5, .medium))
                .foregroundStyle(Ink.tertiary)
            }
        }
    }

    private var chart: some View {
        GeometryReader { geo in
            let size = geo.size
            let now = Date()
            let x = { (time: Date) -> CGFloat in
                size.width * CGFloat(1 - now.timeIntervalSince(time) / BatteryHistory.window)
            }
            let y = { (percent: Int) -> CGFloat in size.height - 1 - (size.height - 2) * CGFloat(percent) / 100 }
            let segments = segments()
            ZStack(alignment: .topLeading) {
                // 充电时段
                ForEach(chargingSpans(), id: \.0) { span in
                    Rectangle()
                        .fill(Palette.battery.opacity(0.13))
                        .frame(width: max(1, x(span.1) - x(span.0)), height: size.height)
                        .offset(x: x(span.0))
                }
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y(20)))
                    path.addLine(to: CGPoint(x: size.width, y: y(20)))
                }
                .stroke(Color.red.opacity(0.35), style: StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
                ForEach(segments.indices, id: \.self) { index in
                    let segment = segments[index]
                    let line = Path { path in
                        for (offset, point) in segment.enumerated() {
                            let p = CGPoint(x: x(point.time), y: y(point.percent))
                            if offset == 0 { path.move(to: p) } else { path.addLine(to: p) }
                        }
                    }
                    closedArea(line, from: x(segment[0].time), to: x(segment[segment.count - 1].time), bottom: size.height)
                        .fill(LinearGradient(colors: [Palette.battery.opacity(0.28), Palette.battery.opacity(0)],
                                             startPoint: .top, endPoint: .bottom))
                    line.stroke(Palette.battery, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hover.x = location.x
                        case .ended: hover.x = nil
                        }
                    }
                if let hoverX = hover.x, let point = nearest(to: hoverX, width: size.width, now: now) {
                    let px = x(point.time)
                    Group {
                        ReadoutGuide().frame(height: size.height).offset(x: px - 0.5)
                        ReadoutDot(tint: Palette.battery).offset(x: px - 6.5, y: y(point.percent) - 6.5)
                        ReadoutBubble(value: "\(point.percent)%",
                                      detail: point.time.formatted(date: .omitted, time: .shortened) + (point.charging ? L(" · 充电中", " · charging") : ""))
                            .alignmentGuide(.leading) { d in -min(max(px - d.width / 2, 0), size.width - d.width) }
                            .offset(y: -6)
                    }
                    .allowsHitTesting(false)
                }
            }
            .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.9), value: hover.x.map { Int($0 / 3) })
        }
    }

    private func closedArea(_ line: Path, from start: CGFloat, to end: CGFloat, bottom: CGFloat) -> Path {
        var area = line
        area.addLine(to: CGPoint(x: end, y: bottom))
        area.addLine(to: CGPoint(x: start, y: bottom))
        area.closeSubpath()
        return area
    }

    /// 按睡眠等长时间空档把记录断开成几段
    private func segments() -> [[BatteryHistory.Point]] {
        var result: [[BatteryHistory.Point]] = []
        for point in points {
            if let last = result.last?.last, point.time.timeIntervalSince(last.time) <= BatteryHistory.gap {
                result[result.count - 1].append(point)
            } else {
                result.append([point])
            }
        }
        return result
    }

    private func chargingSpans() -> [(Date, Date)] {
        var spans: [(Date, Date)] = []
        for (current, next) in zip(points, points.dropFirst())
        where current.charging && next.time.timeIntervalSince(current.time) <= BatteryHistory.gap {
            if let last = spans.last, last.1 == current.time {
                spans[spans.count - 1].1 = next.time
            } else {
                spans.append((current.time, next.time))
            }
        }
        return spans
    }

    private func nearest(to x: CGFloat, width: CGFloat, now: Date) -> BatteryHistory.Point? {
        let time = now.addingTimeInterval(-BatteryHistory.window * Double(1 - x / width))
        return points.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
    }
}

// MARK: - Peripherals

/// 蓝牙外设电量：每个设备一行，每块电池一个小圆环
struct PeripheralsCard: View {
    let devices: [PeripheralBattery]

    var body: some View {
        Tile(title: L("外设电量", "Peripherals"), symbol: "dot.radiowaves.left.and.right", tint: Palette.down) {
            EmptyView()
        } content: {
            VStack(spacing: 7) {
                ForEach(devices) { device in
                    HStack(spacing: 8) {
                        Image(systemName: device.symbol)
                            .font(Typeface.ui(13, .medium))
                            .foregroundStyle(Ink.secondary)
                            .frame(width: 20)
                        Text(device.name)
                            .font(Typeface.ui(12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        HStack(spacing: 10) {
                            ForEach(device.levels.indices, id: \.self) { index in
                                LevelRing(level: device.levels[index])
                            }
                        }
                    }
                    .frame(height: 20)
                }
            }
        }
    }
}

private struct LevelRing: View {
    let level: PeripheralBattery.Level

    var body: some View {
        let tint = level.percent <= 20 ? Color.red : Palette.battery
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 2.2)
                Circle()
                    .trim(from: 0, to: CGFloat(level.percent) / 100)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)
            Text((level.label.map { $0 + " " } ?? "") + "\(level.percent)%")
                .font(Typeface.ui(11, .medium))
                .monospacedDigit()
        }
    }
}

// MARK: - Flow line

/// 两个图标之间的连线：有电流时一串光点沿方向流动，功率越大越快；没有电流时是一条淡淡的虚线
struct FlowLine: View {
    enum Flow: Equatable {
        case idle
        case forward(watts: Double)
        case backward(watts: Double)
    }

    let flow: Flow
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let dotCount = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: flow == .idle || reduceMotion)) { timeline in
            Canvas { context, size in
                let y = size.height / 2
                var track = Path()
                track.move(to: CGPoint(x: 0, y: y))
                track.addLine(to: CGPoint(x: size.width, y: y))
                guard let (direction, watts) = parameters else {
                    context.stroke(track, with: .color(.primary.opacity(0.12)),
                                   style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [2, 3]))
                    return
                }
                context.stroke(track, with: .color(tint.opacity(0.22)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                if reduceMotion {
                    // 不做动画时用一个小箭头表示方向
                    let tip = CGPoint(x: direction > 0 ? size.width : 0, y: y)
                    var arrow = Path()
                    arrow.move(to: CGPoint(x: tip.x - direction * 4, y: y - 3.5))
                    arrow.addLine(to: tip)
                    arrow.addLine(to: CGPoint(x: tip.x - direction * 4, y: y + 3.5))
                    context.stroke(arrow, with: .color(tint), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    return
                }
                // 每秒走过的圈数：0.35（很小的功率）到约 1.25（60 W 以上）
                let speed = 0.35 + min(watts, 60) / 60 * 0.9
                let phase = timeline.date.timeIntervalSinceReferenceDate * speed
                for k in 0..<Self.dotCount {
                    var t = (phase + Double(k) / Double(Self.dotCount)).truncatingRemainder(dividingBy: 1)
                    if direction < 0 { t = 1 - t }
                    // 两端淡入淡出，看起来像从图标里流出来、流进去
                    let fade = sin(t * .pi)
                    let x = size.width * t
                    let dot = CGRect(x: x - 2.25, y: y - 2.25, width: 4.5, height: 4.5)
                    context.fill(Path(ellipseIn: dot.insetBy(dx: -2, dy: -2)), with: .color(tint.opacity(0.18 * fade)))
                    context.fill(Path(ellipseIn: dot), with: .color(tint.opacity(fade)))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// 方向（+1 向右、-1 向左）和功率；没有电流时为 nil
    private var parameters: (Double, Double)? {
        switch flow {
        case .idle: nil
        case .forward(let watts): (1, watts)
        case .backward(let watts): (-1, watts)
        }
    }
}

/// 充电时一道柔光从左到右扫过电量条，约 2.4 秒一次
private struct ChargingSheen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !reduceMotion {
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                GeometryReader { geo in
                    let cycle = 2.4
                    let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
                    // 前 60% 的时间扫过去，剩下的时间停一停
                    let progress = min(t / 0.6, 1)
                    let band = geo.size.width * 0.6
                    LinearGradient(colors: [.white.opacity(0), .white.opacity(0.45), .white.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: band)
                        .offset(x: -band + (geo.size.width + band) * progress)
                        .opacity(t < 0.6 ? 1 : 0)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Overview card

/// 概览卡片和详情页之间共享位置的元素
private enum BatteryMorph: Hashable {
    case glyph, percent
}

private extension View {
    /// 有命名空间时参与 matchedGeometryEffect，没有时（例如静态截图）原样显示
    @ViewBuilder
    func matchedGeometry(_ id: BatteryMorph, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedGeometryEffect(id: id, in: namespace, properties: .position)
        } else {
            self
        }
    }
}

/// 概览里的电池摘要，点击进入电池详情
struct BatterySummaryCard: View {
    let battery: BatterySnapshot
    let estimate: BatteryEstimate?
    var morph: Namespace.ID?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                BatteryGlyph(percent: battery.percent, charging: battery.isCharging, lowPower: battery.lowPowerMode)
                    .matchedGeometry(BatteryMorph.glyph, in: morph)
                VStack(alignment: .leading, spacing: 1) {
                    BigNumber(value: "\(battery.percent)", unit: "%", size: 20)
                        .matchedGeometry(BatteryMorph.percent, in: morph)
                    Text(batterySummary(battery, estimate))
                        .font(Typeface.ui(11))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .frame(height: 14)
                }
                Spacer(minLength: 4)
                VStack(spacing: 2) {
                    Legend(color: PowerPalette.system, label: L("系统", "System"), value: wattText(battery.systemPower))
                    Legend(color: PowerPalette.battery, label: L("电池", "Battery"), value: wattText(battery.batteryPower, signed: true))
                }
                .frame(width: Lang.isChinese ? 96 : 108)
                DisclosureChevron()
            }
            .padding(11)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardButtonStyle())
        .card()
        .hint(L("查看电池详情", "Open battery details"))
    }
}

// MARK: - Detail page

struct BatteryDetailView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    var morph: Namespace.ID?

    var body: some View {
        if let battery = monitor.battery {
            VStack(spacing: 8) {
                hero(battery, monitor.batteryEstimate)
                PowerFlowCard(battery: battery, estimate: monitor.batteryEstimate,
                              systemHistory: monitor.systemPowerHistory,
                              batteryHistory: monitor.batteryPowerHistory)
                BatteryHistoryCard(points: monitor.batteryHistory.points)
                if !monitor.peripherals.isEmpty {
                    PeripheralsCard(devices: monitor.peripherals)
                }
                HealthCard(battery: battery)
            }
        } else {
            Text(L("没有检测到内置电池", "No internal battery found"))
                .font(Typeface.ui(12))
                .foregroundStyle(Ink.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
                .card()
        }
    }

    private func hero(_ b: BatterySnapshot, _ e: BatteryEstimate?) -> some View {
        HStack(spacing: 14) {
            BatteryGlyph(percent: b.percent, charging: b.isCharging, lowPower: b.lowPowerMode, width: 46)
                .matchedGeometry(BatteryMorph.glyph, in: morph)
            VStack(alignment: .leading, spacing: 2) {
                BigNumber(value: "\(b.percent)", unit: "%", size: 28)
                    .matchedGeometry(BatteryMorph.percent, in: morph)
                Text(powerSource(b))
                    .font(Typeface.ui(11.5))
                    .foregroundStyle(b.lowPowerMode ? Color(red: 0.85, green: 0.62, blue: 0.0) : Ink.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(height: 15)
            }
            Spacer(minLength: 0)
            TimeEstimateView(estimate: e)
        }
        .padding(12)
        .card()
    }
}

/// 右侧的充电进度：时间（大号数字 + 说明），或暂停 / 已达上限 / 已充满
private struct TimeEstimateView: View {
    let estimate: BatteryEstimate?

    var body: some View {
        if let e = estimate {
            VStack(alignment: .trailing, spacing: 2) {
                headline(e)
                Text(caption(e.kind))
                    .font(Typeface.ui(10.5, .medium))
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
            }
            .hint(help(e))
        }
    }

    @ViewBuilder
    private func headline(_ e: BatteryEstimate) -> some View {
        switch e.kind {
        case .toFull, .toLimit, .remaining:
            if let minutes = e.minutes {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    ForEach(Array(Fmt.durationParts(minutes).enumerated()), id: \.offset) { _, part in
                        Text(part.0)
                            .font(Typeface.number(20))
                            .tracking(Typeface.tracking(20))
                            .monospacedDigit()
                        Text(part.1)
                            .font(Typeface.ui(11, .medium))
                            .foregroundStyle(Ink.secondary)
                            .padding(.trailing, 2)
                    }
                }
            } else {
                status(L("估算中…", "Estimating…"), symbol: "hourglass")
            }
        case .paused: status(L("已暂停充电", "Paused"), symbol: "pause.circle.fill")
        case .atLimit: status(L("已达上限", "At limit"), symbol: "checkmark.circle.fill")
        case .full: status(L("已充满", "Full"), symbol: "checkmark.circle.fill")
        }
    }

    private func status(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(Typeface.ui(14, .semibold))
            .foregroundStyle(symbol == "hourglass" ? Ink.secondary : .primary)
            .frame(height: 24)
    }

    private func caption(_ kind: BatteryEstimate.Kind) -> String {
        switch kind {
        case .toFull: L("充满还需", "until full")
        case .toLimit(let limit): L("充到 \(limit)% 还需", "until \(limit)%")
        case .remaining: L("预计还能使用", "remaining")
        case .paused: L("可能已达系统充电上限", "system charge limit reached?")
        case .atLimit(let limit): L("充电上限 \(limit)%", "charge limit \(limit)%")
        case .full: L("电源直接为电脑供电", "running on adapter power")
        }
    }

    private func help(_ e: BatteryEstimate) -> String {
        switch e.kind {
        case .paused:
            L("接着电源但没有充电。通常是达到了 系统设置 › 电池 里的充电上限，或者系统的「优化电池充电」暂时停在了 80%。",
              "Plugged in but not charging. Usually the charge limit in System Settings › Battery was reached, or Optimized Battery Charging is holding at 80%.")
        case .toFull, .toLimit, .remaining:
            e.fromSystem ? L("系统给出的估计", "Estimate from macOS")
                : L("按最近约一分钟的平均功率估算，接近充满时充电会变慢，实际可能稍长",
                    "Based on the average power over the last minute. Charging slows near full, so it may take a little longer.")
        default:
            ""
        }
    }
}

/// 输入 = 系统 + 电池：用三栏数字 + 一根分段条说明电从哪来、到哪去
private struct PowerFlowCard: View {
    @EnvironmentObject private var prefs: Preferences
    let battery: BatterySnapshot
    let estimate: BatteryEstimate?
    let systemHistory: [Double]
    let batteryHistory: [Double]

    var body: some View {
        let b = battery
        Tile(title: L("电源流向", "Power Flow"), symbol: "bolt.fill", tint: PowerPalette.adapter) {
            if b.onAC {
                Text(verbatim: [b.adapterWatts.map { "\($0) W" }, b.adapterName].compactMap { $0 }.joined(separator: " "))
                    .lineLimit(1)
                    .hint(L("电源适配器额定功率", "Adapter rated power"))
            }
        } content: {
            VStack(spacing: 5) {
                // 图标之间用流动的光点表示电往哪里走，功率越大流得越快
                ZStack {
                    GeometryReader { geo in
                        let third = geo.size.width / 3
                        let gap: CGFloat = 19
                        FlowLine(flow: inputFlow, tint: PowerPalette.adapter)
                            .frame(width: third - gap * 2, height: 8)
                            .position(x: third, y: geo.size.height / 2)
                        FlowLine(flow: batteryFlow, tint: PowerPalette.battery)
                            .frame(width: third - gap * 2, height: 8)
                            .position(x: third * 2, y: geo.size.height / 2)
                    }
                    HStack(spacing: 0) {
                        badge("powerplug.fill", PowerPalette.adapter, active: b.onAC)
                        badge("laptopcomputer", PowerPalette.system, active: true)
                        badge("battery.75percent", PowerPalette.battery, active: true)
                    }
                }
                .frame(height: 30)
                HStack(alignment: .top, spacing: 0) {
                    column(L("电源输入", "Adapter"), b.onAC ? wattText(b.adapterPower) : L("未接电源", "Unplugged"))
                    column(L("电脑消耗", "System"), wattText(b.systemPower))
                    column(batteryColumnTitle, wattText(b.batteryPower.map(abs)))
                }
            }
            flowBar
                .frame(height: 8)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 3) {
                Legend(color: PowerPalette.system, label: L("电脑消耗 · 最近 \(historyMinutes) 分钟", "System · last \(historyMinutes) min"),
                       value: systemHistory.max().map { String(format: L("峰值 %.1f W", "Peak %.1f W"), $0) } ?? "")
                Sparkline(values: systemHistory, tint: PowerPalette.system,
                          readout: ChartReadout(interval: interval) { [history = systemHistory] in
                              String(format: "%.1f W", history[$0])
                          })
                    .frame(height: 40)
            }
            .padding(.top, 2)
        }
    }

    private var interval: Double { prefs.interval }

    private var batteryColumnTitle: String {
        guard let power = battery.batteryPower, abs(power) >= 0.05 else { return L("电池", "Battery") }
        return power > 0 ? L("充入电池", "Charging") : L("电池放电", "Discharging")
    }

    private var historyMinutes: Int { max(1, Int((Double(systemHistory.count) * interval / 60).rounded())) }

    /// 接电源：整根条 = 输入，分成电脑消耗和充入电池两段；用电池：整根条都是电脑消耗
    private var flowBar: some View {
        let b = battery
        let system = max(b.systemPower ?? 0, 0)
        let charge = max(b.batteryPower ?? 0, 0)
        let total = max(system + charge, 0.001)
        return GeometryReader { geo in
            HStack(spacing: 2) {
                Capsule().fill(PowerPalette.system)
                    .frame(width: max(4, (geo.size.width - 2) * system / total))
                if charge >= 0.05 {
                    Capsule().fill(PowerPalette.battery)
                }
            }
        }
        .animation(.easeOut(duration: 0.4), value: system)
        .animation(.easeOut(duration: 0.4), value: charge)
    }

    /// 电源 → 电脑：接着电源且有输入功率时流动
    private var inputFlow: FlowLine.Flow {
        guard battery.onAC, let input = battery.adapterPower, input >= 0.05 else { return .idle }
        return .forward(watts: input)
    }

    /// 电脑 ↔ 电池：充电时流向电池，放电时从电池流向电脑
    private var batteryFlow: FlowLine.Flow {
        guard let power = battery.batteryPower, abs(power) >= 0.05 else { return .idle }
        return power > 0 ? .forward(watts: power) : .backward(watts: -power)
    }

    private func badge(_ symbol: String, _ tint: Color, active: Bool) -> some View {
        Image(systemName: symbol)
            .font(Typeface.ui(12.5, .semibold))
            .foregroundStyle(active ? tint : Ink.tertiary)
            .frame(width: 30, height: 30)
            .background { Circle().fill((active ? tint : Color.primary).opacity(active ? 0.15 : 0.06)) }
            .frame(maxWidth: .infinity)
    }

    private func column(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(Typeface.number(14))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: 18)
                .contentTransition(.numericText())
            Text(title)
                .font(Typeface.ui(10.5, .medium))
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.3), value: value)
    }
}

private struct HealthCard: View {
    let battery: BatterySnapshot

    var body: some View {
        let b = battery
        Tile(title: L("电池健康", "Battery Health"), symbol: "heart.fill", tint: Color(red: 1.0, green: 0.42, blue: 0.5)) {
            if let full = b.fullCapacity, let design = b.designCapacity {
                Text(verbatim: "\(full) / \(design) mAh").monospacedDigit()
            }
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                BigNumber(value: b.health.map(String.init) ?? "—", unit: b.health == nil ? "" : "%")
                Text(L("最大容量", "max capacity"))
                    .font(Typeface.ui(11))
                    .foregroundStyle(Ink.secondary)
                Spacer()
                Text(healthComment)
                    .font(Typeface.ui(11, .medium))
                    .foregroundStyle(healthColor)
            }
            .hint(L("满充容量与设计容量之比，对应 系统设置 › 电池 › 电池健康 里的\"最大容量\"", "Full-charge capacity compared with design capacity, the same as Maximum Capacity in System Settings › Battery › Battery Health"))
            MeterBar(fraction: Double(b.health ?? 0) / 100, tint: healthColor)
                .padding(.bottom, 4)
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    chip(L("循环次数", "Cycles"), b.cycles.map { cycles in b.designCycles.map { "\(cycles) / \($0)" } ?? "\(cycles)" })
                    chip(L("温度", "Temperature"), b.temperature.map { String(format: "%.1f°C", $0) })
                    chip(L("当前电量", "Charge"), b.currentCapacity.map { "\($0) mAh" })
                }
                GridRow {
                    chip(L("电压", "Voltage"), b.voltage.map { String(format: "%.2f V", $0) })
                    chip(L("电流", "Current"), b.amperage.map { String(format: "%@%.2f A", $0 > 0.005 ? "+" : $0 < -0.005 ? "−" : "", abs($0)) })
                    chip(L("设计容量", "Design capacity"), b.designCapacity.map { "\($0) mAh" })
                }
            }
        }
    }

    private var healthComment: String {
        guard let health = battery.health else { return "" }
        return health >= 80 ? L("状态良好", "Normal") : L("建议检查", "Service recommended")
    }

    private var healthColor: Color {
        guard let health = battery.health else { return Palette.battery }
        return health >= 80 ? Palette.battery : .orange
    }

    private func chip(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Typeface.ui(10.5, .medium))
                .foregroundStyle(Ink.secondary)
            Text(value ?? "—")
                .font(Typeface.ui(12.5, .semibold))
                .monospacedDigit()
                .foregroundStyle(value == nil ? Ink.tertiary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(height: 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
