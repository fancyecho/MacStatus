import SwiftUI

// MARK: - Shared

private enum PowerPalette {
    static let system = Palette.cpu
    static let battery = Palette.battery
    static let adapter = Color(red: 1.0, green: 0.74, blue: 0.25)
}

/// 状态（不含时间），例如"充电中 · 低电量模式"
private func batteryState(_ b: BatterySnapshot, _ e: BatteryEstimate?) -> String {
    let state: String = switch e?.kind {
    case .toFull, .toLimit: "充电中"
    case .atLimit(let limit): "已达充电上限 \(limit)%"
    case .full: "已充满"
    case .paused: "已接通电源 · 暂停充电"
    case .remaining, nil: b.onAC ? "已接通电源" : "使用电池"
    }
    return b.lowPowerMode ? state + " · 低电量模式" : state
}

/// 概览卡片用的一行摘要，例如"充电中 · 1:12 后到 90%"
private func batterySummary(_ b: BatterySnapshot, _ e: BatteryEstimate?) -> String {
    guard let e else { return batteryState(b, nil) }
    // "1:12 后充满" / "38 分钟后充满"：汉字结尾时不再加空格
    let time = e.minutes.map { $0 >= 60 ? Fmt.minutes($0) + " " : Fmt.minutes($0) }
    switch e.kind {
    case .toFull: return "充电中 · " + (time.map { "\($0)后充满" } ?? "估算中")
    case .toLimit(let limit): return "充电中 · " + (time.map { "\($0)后到 \(limit)%" } ?? "估算中")
    case .remaining: return "使用电池 · " + (time.map { "剩余 \($0)" } ?? "估算中")
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
                            RoundedRectangle(cornerRadius: height * 0.17, style: .continuous)
                                .fill(tint)
                                .frame(width: max(3, (geo.size.width - 5) * CGFloat(percent) / 100))
                                .padding(2.5)
                        }
                    }
                    .frame(width: width, height: height)
                Capsule().fill(Color.primary.opacity(0.35)).frame(width: 2, height: height * 0.33)
            }
            if charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: height * 0.55, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1)
                    .offset(x: -2)
            }
        }
    }
}

// MARK: - Overview card

/// 概览里的电池摘要，点击进入电池详情
struct BatterySummaryCard: View {
    let battery: BatterySnapshot
    let estimate: BatteryEstimate?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                BatteryGlyph(percent: battery.percent, charging: battery.isCharging, lowPower: battery.lowPowerMode)
                VStack(alignment: .leading, spacing: 1) {
                    BigNumber(value: "\(battery.percent)", unit: "%", size: 20)
                    Text(batterySummary(battery, estimate))
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .frame(height: 14)
                }
                Spacer(minLength: 4)
                VStack(spacing: 2) {
                    Legend(color: PowerPalette.system, label: "系统", value: wattText(battery.systemPower))
                    Legend(color: PowerPalette.battery, label: "电池", value: wattText(battery.batteryPower, signed: true))
                }
                .frame(width: 96)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
            }
            .padding(11)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardButtonStyle())
        .card()
        .help("查看电池详情")
    }
}

// MARK: - Detail page

struct BatteryDetailView: View {
    @EnvironmentObject private var monitor: SystemMonitor

    var body: some View {
        if let battery = monitor.battery {
            VStack(spacing: 8) {
                hero(battery, monitor.batteryEstimate)
                PowerFlowCard(battery: battery, estimate: monitor.batteryEstimate,
                              systemHistory: monitor.systemPowerHistory,
                              batteryHistory: monitor.batteryPowerHistory)
                HealthCard(battery: battery)
            }
        } else {
            Text("没有检测到内置电池")
                .font(.system(size: 12))
                .foregroundStyle(Ink.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
                .card()
        }
    }

    private func hero(_ b: BatterySnapshot, _ e: BatteryEstimate?) -> some View {
        HStack(spacing: 14) {
            BatteryGlyph(percent: b.percent, charging: b.isCharging, lowPower: b.lowPowerMode, width: 46)
            VStack(alignment: .leading, spacing: 2) {
                BigNumber(value: "\(b.percent)", unit: "%", size: 28)
                Text(batteryState(b, e))
                    .font(.system(size: 11.5))
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

/// 右侧的时间：大号数字 + 说明，例如"1 小时 12 分 / 充到 90% 还需"
private struct TimeEstimateView: View {
    let estimate: BatteryEstimate?

    var body: some View {
        if let e = estimate, let caption = caption(e.kind) {
            VStack(alignment: .trailing, spacing: 2) {
                if let minutes = e.minutes {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        ForEach(Array(Fmt.durationParts(minutes).enumerated()), id: \.offset) { _, part in
                            Text(part.0)
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            Text(part.1)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Ink.secondary)
                                .padding(.trailing, 2)
                        }
                    }
                } else {
                    Text("估算中…")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                }
                Text(caption)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Ink.tertiary)
            }
            .help(e.fromSystem ? "系统给出的估计" : "按最近约一分钟的平均功率估算，充电接近上限时会变慢，实际可能稍长")
        }
    }

    private func caption(_ kind: BatteryEstimate.Kind) -> String? {
        switch kind {
        case .toFull: "充满还需"
        case .toLimit(let limit): "充到 \(limit)% 还需"
        case .remaining: "预计还能使用"
        default: nil
        }
    }
}

/// 输入 = 系统 + 电池：用三栏数字 + 一根分段条说明电从哪来、到哪去
private struct PowerFlowCard: View {
    let battery: BatterySnapshot
    let estimate: BatteryEstimate?
    let systemHistory: [Double]
    let batteryHistory: [Double]

    var body: some View {
        let b = battery
        Tile(title: "电源流向", symbol: "bolt.fill", tint: PowerPalette.adapter) {
            if b.onAC {
                Text(verbatim: [b.adapterWatts.map { "\($0) W" }, b.adapterName].compactMap { $0 }.joined(separator: " "))
                    .lineLimit(1)
                    .help("电源适配器额定功率")
            }
        } content: {
            HStack(alignment: .top, spacing: 0) {
                column("电源输入", "powerplug.fill", PowerPalette.adapter, b.onAC ? wattText(b.adapterPower) : "未接电源")
                operatorSign(b.onAC ? "=" : "")
                column("电脑消耗", "laptopcomputer", PowerPalette.system, wattText(b.systemPower))
                operatorSign(b.onAC ? "+" : "←")
                column(batteryColumnTitle, "battery.75percent", PowerPalette.battery, wattText(b.batteryPower.map(abs)))
            }
            flowBar
                .frame(height: 8)
                .padding(.vertical, 2)
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(Ink.secondary)
                .lineLimit(2)
                // 固定两行高度：说明文字一行或两行时卡片都不跳
                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 3) {
                Legend(color: PowerPalette.system, label: "电脑消耗 · 最近 \(historyMinutes) 分钟",
                       value: systemHistory.max().map { String(format: "峰值 %.1f W", $0) } ?? "")
                Sparkline(values: systemHistory, tint: PowerPalette.system)
                    .frame(height: 40)
            }
            .padding(.top, 2)
        }
    }

    private var batteryColumnTitle: String {
        guard let power = battery.batteryPower, abs(power) >= 0.05 else { return "电池" }
        return power > 0 ? "充入电池" : "电池放电"
    }

    private var historyMinutes: Int { max(1, systemHistory.count * 2 / 60) }

    private var caption: String {
        let b = battery
        let system = wattText(b.systemPower)
        let charge = max(b.batteryPower ?? 0, 0)
        if b.onAC {
            if case .atLimit(let limit) = estimate?.kind {
                return "已达到充电上限 \(limit)%，电源只为电脑供电（\(system)）。"
            }
            if charge >= 0.05 {
                return "电源输入 \(wattText(b.adapterPower))，其中 \(system) 供电脑运行，\(wattText(charge)) 充入电池。"
            }
            return "电池暂未充电，电源输入全部用于电脑运行（\(system)）。"
        }
        return "未接电源，电池正以 \(wattText(b.batteryPower.map(abs))) 为电脑供电。"
    }

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

    private func column(_ title: String, _ symbol: String, _ tint: Color, _ value: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(height: 16)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: 18)
                .contentTransition(.numericText())
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.3), value: value)
    }

    private func operatorSign(_ sign: String) -> some View {
        Text(sign)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Ink.tertiary)
            .frame(width: 14)
            .padding(.top, 20)
    }
}

private struct HealthCard: View {
    let battery: BatterySnapshot

    var body: some View {
        let b = battery
        Tile(title: "电池健康", symbol: "heart.fill", tint: Color(red: 1.0, green: 0.42, blue: 0.5)) {
            if let full = b.fullCapacity, let design = b.designCapacity {
                Text(verbatim: "\(full) / \(design) mAh").monospacedDigit()
            }
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                BigNumber(value: b.health.map(String.init) ?? "—", unit: b.health == nil ? "" : "%")
                Text("最大容量")
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.secondary)
                Spacer()
                Text(healthComment)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(healthColor)
            }
            .help("满充容量与设计容量之比，对应 系统设置 › 电池 › 电池健康 里的\"最大容量\"")
            MeterBar(fraction: Double(b.health ?? 0) / 100, tint: healthColor)
                .padding(.bottom, 4)
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    chip("循环次数", b.cycles.map { cycles in b.designCycles.map { "\(cycles) / \($0)" } ?? "\(cycles)" })
                    chip("温度", b.temperature.map { String(format: "%.1f°C", $0) })
                    chip("当前电量", b.currentCapacity.map { "\($0) mAh" })
                }
                GridRow {
                    chip("电压", b.voltage.map { String(format: "%.2f V", $0) })
                    chip("电流", b.amperage.map { String(format: "%@%.2f A", $0 > 0.005 ? "+" : $0 < -0.005 ? "−" : "", abs($0)) })
                    chip("设计容量", b.designCapacity.map { "\($0) mAh" })
                }
            }
        }
    }

    private var healthComment: String {
        guard let health = battery.health else { return "" }
        return health >= 80 ? "状态良好" : "建议检查"
    }

    private var healthColor: Color {
        guard let health = battery.health else { return Palette.battery }
        return health >= 80 ? Palette.battery : .orange
    }

    private func chip(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Ink.secondary)
            Text(value ?? "—")
                .font(.system(size: 12.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(value == nil ? Ink.tertiary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(height: 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
