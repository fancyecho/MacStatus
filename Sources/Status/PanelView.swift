import ServiceManagement
import SwiftUI

struct PanelView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var prefs: Preferences
    @ObservedObject private var updater = UpdateChecker.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var pageHeights = PageHeights()
    @StateObject private var hints = HintCenter()
    /// 电池卡片和电池详情之间的"变形"动画：电池图标和电量从卡片里飞到详情页顶部
    @Namespace private var batteryMorph

    var body: some View {
        VStack(spacing: 8) {
            header.panelEntrance(0)
            pages
            footer.panelEntrance(6)
        }
        .padding(Metrics.panelPadding)
        .padding(.top, 2)
        .frame(width: StatusPanel.panelWidth)
        // 换字体或语言时整块重建，所有文字立即更新
        .id("\(prefs.font.rawValue)-\(prefs.language.rawValue)")
        .environment(\.hintCenter, hints)
        .coordinateSpace(name: HintCenter.space)
        .overlay(alignment: .topLeading) { HintOverlay(center: hints) }
        .onChange(of: prefs.page) { _, _ in hints.dismiss() }
        .background { PanelSurface() }
        // 切换页面和随后的高度变化都用同一个弹簧，玻璃背景在这个作用域里一起伸缩
        .animation(Motion.page, value: prefs.page)
        .animation(Motion.page, value: pageHeights.values[prefs.page])
    }

    /// 新旧页面叠在一起交叉过渡；容器高度按量好的新页面高度做弹簧动画，
    /// 玻璃背景跟着同一个动画伸缩
    private var pages: some View {
        let page = prefs.page
        let height = pageHeights.values[page]
        return ZStack(alignment: .top) {
            pageContent(page)
                .fixedSize(horizontal: false, vertical: true)
                .background { PageHeightReader { pageHeights.update(page, $0) } }
                .id(page)
                .transition(pageTransition(page == .overview ? .leading : .trailing))
        }
        .frame(height: height, alignment: .top)
        // 只在竖直方向裁掉过渡中超出的旧页面，左右留出卡片阴影的位置
        .mask { Rectangle().padding(.horizontal, -12).padding(.vertical, -4) }
    }

    @ViewBuilder
    private func pageContent(_ page: Preferences.Page) -> some View {
        switch page {
        case .overview: overview
        case .settings: SettingsView()
        case .network: NetworkDetailView()
        case .battery: BatteryDetailView(morph: batteryMorph)
        }
    }

    /// 概览从左边进出，其他页面从右边进出，像左右翻页；开启"减弱动态效果"时只淡入淡出
    private func pageTransition(_ edge: Edge) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let distance: CGFloat = edge == .leading ? -36 : 36
        // 旧页面很快淡出，新页面带着位移和轻微缩放进来，避免两页长时间叠在一起
        return .asymmetric(
            insertion: .offset(x: distance).combined(with: .opacity).combined(with: .scale(scale: 0.98, anchor: .top)),
            removal: .offset(x: distance / 2).combined(with: .opacity).animation(Motion.pageExit))
    }

    // MARK: Header / Footer

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(SystemInfo.computerName)
                    .font(Typeface.ui(13, .semibold))
                    .lineLimit(1)
                Text("\(SystemInfo.chip) · \(SystemInfo.osVersion) · " + L("已运行 ", "up ") + Fmt.uptime(monitor.uptime))
                    .font(Typeface.ui(11))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button { prefs.page = prefs.page == .overview ? .settings : .overview } label: {
                Image(systemName: prefs.page == .overview ? "slider.horizontal.3" : "xmark")
                    .font(Typeface.ui(12, .medium))
                    .frame(width: 16, height: 16)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(SubtleButtonStyle())
            .keyboardShortcut(",")
            .hint(prefs.page == .overview ? L("设置（⌘,）", "Settings (⌘,)") : L("返回（Esc）", "Back (Esc)"))
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            } label: {
                Label(L("活动监视器", "Activity Monitor"), systemImage: "arrow.up.forward.app")
            }
            Spacer()
            if let release = updater.availableRelease {
                Button { updater.downloadUpdate() } label: {
                    Label(updater.state == .downloading(release) ? L("正在下载…", "Downloading…") : L("新版本 ", "New version ") + release.version,
                          systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
                .disabled(updater.state == .downloading(release))
                .hint(L("下载新版本到“下载”文件夹并打开，把 Status 拖进“应用程序”替换即可", "Downloads the new version to your Downloads folder and opens it. Drag Status into Applications to replace the old one."))
            }
            Button { NSApp.terminate(nil) } label: {
                Text(L("退出", "Quit"))
            }
            .keyboardShortcut("q")
        }
        .font(Typeface.ui(11))
        .foregroundStyle(Ink.secondary)
        .buttonStyle(SubtleButtonStyle())
    }

    // MARK: Overview

    private var overview: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                cpuTile
                memoryTile
            }
            .fixedSize(horizontal: false, vertical: true)
            .panelEntrance(1)

            HStack(spacing: 8) {
                if monitor.gpu != nil { gpuTile }
                diskTile
            }
            .fixedSize(horizontal: false, vertical: true)
            .panelEntrance(2)

            networkCard.panelEntrance(3)
            if let battery = monitor.battery {
                BatterySummaryCard(battery: battery, estimate: monitor.batteryEstimate, morph: batteryMorph) {
                    prefs.page = .battery
                }
                .panelEntrance(4)
            } else if !monitor.peripherals.isEmpty {
                // 台式机没有电池详情页，外设电量直接放在概览里
                PeripheralsCard(devices: monitor.peripherals).panelEntrance(4)
            }
            ProcessCard().panelEntrance(5)
        }
    }

    private var cpuTile: some View {
        Tile(title: "CPU", symbol: "cpu", tint: Palette.cpu) {
            if let t = monitor.temperature, let temp = t.cpu {
                TemperatureBadge(celsius: temp).hint(temperatureHelp(t))
            } else if let load = monitor.loadAverage.first {
                Text(String(format: "%.2f", load)).monospacedDigit().hint(L("1 分钟平均负载", "1-minute load average"))
            }
        } content: {
            BigNumber(value: Fmt.percent(monitor.cpu.usage), unit: "%")
                .hint(monitor.loadAverage.isEmpty ? "" : L("平均负载 ", "Load average ") + monitor.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " / "))
            Sparkline(values: monitor.cpuHistory, maxValue: 100, tint: Palette.cpu,
                      readout: ChartReadout(interval: prefs.interval) { [history = monitor.cpuHistory] in
                          "\(Fmt.percent(history[$0]))%"
                      })
                .frame(minHeight: 24, maxHeight: .infinity)
            CoreBars(cores: monitor.cpu.cores, tint: Palette.cpu)
                .frame(height: 12)
                .hint(L("每个核心的占用", "Usage of each core"))
            HStack(spacing: 10) {
                Text(L("用户 ", "User ") + "\(Fmt.percent(monitor.cpu.user))%")
                Text(L("系统 ", "System ") + "\(Fmt.percent(monitor.cpu.system))%")
            }
            .lineLimit(1)
            .font(Typeface.ui(10.5, .medium))
            .foregroundStyle(Ink.secondary)
            .monospacedDigit()
        }
    }

    private var memoryTile: some View {
        let m = monitor.memory
        let (used, unit) = Fmt.bytesParts(Double(m.used), base: 1024)
        return Tile(title: L("内存", "Memory"), symbol: "memorychip", tint: Palette.memory) {
            if m.pressureLevel > 1 {
                PressureBadge(level: m.pressureLevel)
            } else {
                Text("\(Fmt.percent(m.usedPercent))%").monospacedDigit()
                    .hint(L("内存压力正常。macOS 会主动把空闲内存用作缓存并压缩不常用的数据，所以占用高是正常的，只有内存压力升高时才需要关注。", "Memory pressure is normal. macOS uses free memory as cache and compresses data you are not using, so high usage is expected. It only matters when memory pressure rises."))
            }
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                BigNumber(value: used, unit: unit)
                Text("/ \(Fmt.memory(m.total))")
                    .font(Typeface.ui(11))
                    .foregroundStyle(Ink.tertiary)
            }
            SegmentBar(segments: [
                (Double(m.app), Palette.memory),
                (Double(m.wired), Palette.memory.opacity(0.6)),
                (Double(m.compressed), Palette.memory.opacity(0.35)),
            ], total: Double(m.total))
            .padding(.vertical, 2)
            VStack(spacing: 2) {
                Legend(color: Palette.memory, label: L("应用", "App"), value: Fmt.memory(m.app))
                Legend(color: Palette.memory.opacity(0.6), label: L("联动", "Wired"), value: Fmt.memory(m.wired))
                Legend(color: Palette.memory.opacity(0.35), label: L("压缩", "Compressed"), value: Fmt.memory(m.compressed))
                Legend(color: Ink.tertiary, label: L("交换", "Swap"), value: Fmt.memory(m.swapUsed))
            }
        }
    }

    private var gpuTile: some View {
        Tile(title: "GPU", symbol: "square.stack.3d.up", tint: Palette.gpu) {
            if let temp = monitor.temperature?.gpu {
                TemperatureBadge(celsius: temp).hint(L("GPU 温度", "GPU temperature"))
            }
        } content: {
            BigNumber(value: Fmt.percent(monitor.gpu ?? 0), unit: "%")
            Sparkline(values: monitor.gpuHistory, maxValue: 100, tint: Palette.gpu,
                      readout: ChartReadout(interval: prefs.interval) { [history = monitor.gpuHistory] in
                          "\(Fmt.percent(history[$0]))%"
                      })
                .frame(minHeight: 24, maxHeight: .infinity)
        }
    }

    private var diskTile: some View {
        let d = monitor.disk
        let (free, unit) = Fmt.bytesParts(Double(d.free))
        return Tile(title: d.name, symbol: "internaldrive", tint: Palette.disk) {
            Text("\(Fmt.percent(d.usedPercent))%").monospacedDigit()
        } content: {
            BigNumber(value: free, unit: unit + L(" 可用", " free"))
            MeterBar(fraction: d.usedPercent / 100, tint: Palette.disk)
                .padding(.vertical, 2)
            VStack(spacing: 2) {
                Legend(color: Palette.disk, label: L("读取", "Read"), value: Fmt.rate(d.read), symbol: "arrow.down")
                Legend(color: Palette.disk.opacity(0.7), label: L("写入", "Write"), value: Fmt.rate(d.write), symbol: "arrow.up")
            }
        }
    }

    private var networkCard: some View {
        let n = monitor.network
        return Group {
            if prefs.enableClaudeDiagnostics {
                Button { prefs.page = .network } label: { networkTile(n) }
                    .buttonStyle(CardButtonStyle())
                    .hint(L("查看 Claude 网络诊断", "Open Claude network diagnostics"))
                    .accessibilityLabel(L("网络，查看 Claude 网络诊断", "Network, open Claude network diagnostics"))
            } else {
                networkTile(n)
            }
        }
    }

    private func networkTile(_ n: NetworkSnapshot) -> some View {
        Tile(title: L("网络", "Network"), symbol: "network", tint: Palette.down) {
            HStack(spacing: 5) {
                Text(n.address ?? L("未连接", "Not connected")).monospacedDigit().textSelection(.enabled)
                if prefs.enableClaudeDiagnostics {
                    DisclosureChevron(size: 8)
                }
            }
        } content: {
            HStack(alignment: .firstTextBaseline) {
                RateView(symbol: "arrow.down", tint: Palette.down, value: n.down)
                Spacer()
                RateView(symbol: "arrow.up", tint: Palette.up, value: n.up)
            }
            MirrorChart(top: monitor.downHistory, bottom: monitor.upHistory, topTint: Palette.down, bottomTint: Palette.up,
                        readout: ChartReadout(interval: prefs.interval) { [down = monitor.downHistory, up = monitor.upHistory] in
                            "↓ \(Fmt.rate(down[$0]))  ↑ \(Fmt.rate(up.indices.contains($0) ? up[$0] : 0))"
                        })
                .frame(height: 44)
            NetworkQualityRow(wifi: monitor.wifi, latency: monitor.latency)
            HStack {
                Text(L("开机以来", "Since boot") + "  ↓ \(Fmt.bytes(n.totalDown))  ↑ \(Fmt.bytes(n.totalUp))")
                Spacer(minLength: 8)
                Text(L("峰值 ", "Peak ") + Fmt.rate(max(monitor.downHistory.max() ?? 0, monitor.upHistory.max() ?? 0)))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(height: 14)
            .font(Typeface.ui(10.5, .medium))
            .foregroundStyle(Ink.tertiary)
            .monospacedDigit()
        }
    }
}

// MARK: - Pieces

/// 网络卡片底部：Wi-Fi 信号格数 + 强度 / 速率，右边是到网关、国内、海外的延迟
private struct NetworkQualityRow: View {
    let wifi: WiFiSnapshot?
    let latency: LatencySnapshot?

    var body: some View {
        HStack(spacing: 8) {
            if let wifi {
                HStack(spacing: 4) {
                    Image(systemName: "wifi", variableValue: wifi.strength)
                        .font(Typeface.ui(10, .semibold))
                        .foregroundStyle(Palette.down)
                    Text(verbatim: wifi.rate >= 1000 ? String(format: "%.1f Gbps", wifi.rate / 1000) : String(format: "%.0f Mbps", wifi.rate))
                }
                .hint(help(for: wifi))
            } else {
                Label(L("有线或未连接 Wi-Fi", "Wired or no Wi-Fi"), systemImage: "cable.connector.horizontal")
                    .labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 4)
            HStack(spacing: 10) {
                if let gateway = latency?.gateway { chip(L("网关", "Router"), gateway) }
                chip(L("互联网", "Internet"), latency?.internet)
            }
            .fixedSize()
            .hint(latencyHint)
        }
        .lineLimit(1)
        .font(Typeface.ui(10.5, .medium))
        .foregroundStyle(Ink.secondary)
        .monospacedDigit()
        .frame(height: 14)
    }

    private var latencyHint: String {
        var lines = [L("往返延迟（越低越好）", "Round-trip latency (lower is better)")]
        if let gateway = latency?.gateway { lines.append(L("网关（你的路由器）", "Router") + String(format: "：%.0f ms", gateway)) }
        lines.append(L("互联网取以下任播 DNS 中最快的一个：", "Internet is the fastest of these anycast DNS servers:"))
        for target in latency?.targets ?? [] {
            lines.append("  \(target.name) \(target.host)  " + (target.milliseconds.map { String(format: "%.0f ms", $0) } ?? L("无响应", "no reply")))
        }
        return lines.joined(separator: "\n")
    }

    /// 返回 String（而不是字面量）让 .help 原样显示，不做本地化和数字分组
    private func help(for wifi: WiFiSnapshot) -> String {
        let band = wifi.band.isEmpty ? "" : L("（\(wifi.band)）", " (\(wifi.band))")
        return L("Wi-Fi 信号 \(wifi.rssi) dBm，噪声 \(wifi.noise) dBm，信噪比 \(wifi.rssi - wifi.noise) dB\n信道 \(wifi.channel)\(band)，当前速率 \(Int(wifi.rate)) Mbps",
                 "Wi-Fi signal \(wifi.rssi) dBm, noise \(wifi.noise) dBm, SNR \(wifi.rssi - wifi.noise) dB\nChannel \(wifi.channel)\(band), link rate \(Int(wifi.rate)) Mbps")
    }

    private func chip(_ label: String, _ milliseconds: Double?) -> some View {
        let color: Color = switch milliseconds {
        case nil: Ink.tertiary
        case let value? where value < 60: Palette.battery
        case let value? where value < 150: Color.orange
        default: Color.red
        }
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(verbatim: label)
            HStack(alignment: .firstTextBaseline, spacing: 1.5) {
                Text(verbatim: milliseconds.map { String(format: "%.0f", $0) } ?? "—")
                    .foregroundStyle(.primary)
                Text(verbatim: "ms")
                    .font(Typeface.ui(9.5, .medium))
                    .foregroundStyle(Ink.tertiary)
            }
        }
        .fixedSize()
    }
}

private func temperatureHelp(_ t: TemperatureSnapshot) -> String {
    var lines = [L("CPU 温度：\(t.cpuSensorCount) 个传感器的平均值", "CPU temperature: average of \(t.cpuSensorCount) sensors")]
    if let max = t.cpuMax { lines.append(String(format: L("其中最高 %.0f°C", "Hottest %.0f°C"), max)) }
    lines.append(L("来源：", "Source: ") + t.cpuSource)
    return lines.joined(separator: "\n")
}

private struct RateView: View {
    let symbol: String
    let tint: Color
    let value: Double

    var body: some View {
        let (number, unit) = Fmt.bytesParts(value)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: symbol)
                .font(Typeface.ui(11, .bold))
                .foregroundStyle(tint)
            BigNumber(value: number, unit: "\(unit)/s", size: 20)
        }
    }
}

private struct TemperatureBadge: View {
    let celsius: Double

    var body: some View {
        let color: Color = celsius >= 95 ? .red : celsius >= 80 ? .orange : Ink.secondary
        HStack(spacing: 2) {
            Image(systemName: "thermometer.medium")
            Text(String(format: "%.0f°C", celsius)).monospacedDigit()
        }
        .foregroundStyle(color)
    }
}

private struct PressureBadge: View {
    let level: Int

    var body: some View {
        let (text, color): (String, Color) = level >= 4 ? (L("压力过高", "Critical"), .red) : (L("压力偏高", "High"), .orange)
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text)
        }
        .foregroundStyle(color)
        .hint(L("系统内存压力升高，可能开始频繁压缩或使用交换空间，可以关闭一些占内存的应用。", "Memory pressure is rising and the system may start compressing or swapping heavily. Quitting some memory-hungry apps will help."))
    }
}

private struct ProcessCard: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        let rows = prefs.processSort == .cpu ? monitor.topByCPU : monitor.topByMemory
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "list.bullet")
                    .font(Typeface.ui(10, .bold))
                    .foregroundStyle(Ink.secondary)
                Text(L("进程", "Processes"))
                    .font(Typeface.ui(11, .medium))
                    .foregroundStyle(Ink.secondary)
                Spacer()
                GlassSegmentedControl(L("进程排序", "Sort processes"), selection: $prefs.processSort,
                                      options: [(.cpu, "CPU"), (.memory, L("内存", "Memory"))], height: 18)
            }
            VStack(spacing: 3) {
                ForEach(rows) { row in
                    ProcessRow(row: row, value: prefs.processSort == .cpu
                               ? String(format: "%.1f%%", row.cpu) : Fmt.memory(row.memory))
                }
            }
            // 排名变化时各行滑到新位置，而不是原地跳字
            .animation(.snappy(duration: 0.35), value: rows.map(\.id))
            // 固定 5 行的高度：刚打开、进程还没采到时卡片也不会变矮
            .frame(height: 5 * 20 + 4 * 3, alignment: .top)
        }
        .padding(10)
        .card()
    }
}

/// 一行进程：悬停高亮，右键可以在访达中显示或退出应用
private struct ProcessRow: View {
    let row: ProcessEntry
    let value: String
    @StateObject private var hover = HoverState()

    var body: some View {
        let app = NSRunningApplication(processIdentifier: row.id)
        HStack(spacing: 8) {
            Image(nsImage: row.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
            Text(row.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(Ink.secondary)
                .contentTransition(.numericText())
        }
        .font(Typeface.ui(12))
        .frame(height: 20)
        .padding(.horizontal, 5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hover.hovering ? 0.06 : 0))
        }
        .padding(.horizontal, -5)
        .contentShape(Rectangle())
        .onHover { hover.hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.hovering)
        .hint("\(row.name)\nPID \(row.id) · CPU \(String(format: "%.1f%%", row.cpu)) · " + L("内存 ", "Memory ") + Fmt.memory(row.memory) + "\n" + L("右键查看更多操作", "Right-click for more actions"))
        .contextMenu {
            if let url = app?.bundleURL {
                Button(L("在访达中显示", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier, app.activationPolicy == .regular {
                Button(L("切换到 ", "Switch to ") + row.name) { app.activate() }
                Divider()
                Button(L("退出 ", "Quit ") + row.name) { app.terminate() }
            }
            Button(L("拷贝 PID ", "Copy PID ") + "\(row.id)") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(row.id)", forType: .string)
            }
        }
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var monitor: SystemMonitor
    @ObservedObject private var updater = UpdateChecker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            section(L("菜单栏显示", "Menu Bar")) {
                toggle("CPU", "cpu", $prefs.showCPU)
                toggle(L("CPU 温度", "CPU temperature"), "thermometer.medium", $prefs.showTemperature)
                toggle(L("内存", "Memory"), "memorychip", $prefs.showMemory)
                toggle("GPU", "square.stack.3d.up", $prefs.showGPU)
                toggle(L("网速", "Network speed"), "network", $prefs.showNetwork)
                toggle(L("电池", "Battery"), "battery.75percent", $prefs.showBattery)
            }
            section(L("通用", "General")) {
                HStack {
                    Text(L("刷新间隔", "Refresh every"))
                    Spacer()
                    GlassSegmentedControl(L("刷新间隔", "Refresh every"), selection: $prefs.interval,
                                          options: [1, 2, 3, 5].map { (Double($0), "\($0)" + L(" 秒", " s")) })
                }
                .frame(height: 24)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(L("充电上限", "Charge limit"))
                        Spacer()
                        GlassSegmentedControl(L("充电上限", "Charge limit"), selection: $prefs.chargeLimit,
                                              options: [(0, L("自动", "Auto")), (80, "80"), (85, "85"), (90, "90"), (95, "95"), (100, "100")])
                    }
                    .frame(height: 24)
                    Text(L("只用于估算充电时间，不会改变实际充电。实际上限请在 系统设置 › 电池 中设置；“自动”使用系统自己的估计。", "Only used to estimate charging time; it doesn't change how the Mac charges. Set the real limit in System Settings › Battery. Auto uses the system's own estimate."))
                        .font(Typeface.ui(10.5))
                        .foregroundStyle(Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)
                }
                HStack {
                    Text(L("登录时启动", "Launch at login"))
                    Spacer()
                    Toggle("", isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.launchAtLogin = $0 }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
                .frame(height: 24)
                if prefs.loginItemNeedsApproval || prefs.loginItemError != nil {
                    HStack(spacing: 6) {
                        Text(prefs.loginItemError ?? L("需要在 系统设置 › 通用 › 登录项 中允许 Status", "Allow Status in System Settings › General › Login Items"))
                            .font(Typeface.ui(10.5))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button(L("打开", "Open")) { SMAppService.openSystemSettingsLoginItems() }
                            .buttonStyle(PillButtonStyle())
                    }
                    .padding(.bottom, 4)
                }
            }
            section(L("外观", "Appearance")) {
                // 六个选项放不下标题，选择器单独占一行，每个选项用自己的字体显示
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("字体", "Font"))
                    GlassSegmentedControl(L("字体", "Font"), selection: $prefs.font,
                                          options: AppFont.allCases.map { ($0, $0.title) },
                                          labelFont: { Typeface.number(11, weight: .medium, font: $0) })
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.vertical, 3)
                HStack {
                    Text(L("语言", "Language"))
                    Spacer()
                    GlassSegmentedControl(L("语言", "Language"), selection: $prefs.language,
                                          options: AppLanguage.allCases.map { ($0, $0.title) })
                }
                .frame(height: 24)
            }
            section(L("提醒", "Alerts")) {
                toggle(L("电量低于 20%", "Battery below 20%"), "battery.25percent", $prefs.alertLowBattery)
                toggle(L("CPU 持续过热", "CPU running hot"), "thermometer.high", $prefs.alertHot)
                toggle(L("内存压力过高", "Memory pressure critical"), "memorychip", $prefs.alertMemory)
                toggle(L("磁盘空间不足 10 GB", "Less than 10 GB disk space"), "internaldrive", $prefs.alertDisk)
                toggle(L("进程持续占满 CPU 5 分钟", "Process maxing CPU for 5 min"), "flame", $prefs.alertRunaway)
            }
            .onChange(of: prefs.anyAlertEnabled) { _, enabled in
                if enabled { monitor.alerts.requestAuthorizationIfNeeded() }
            }
            section(L("网络诊断", "Network Diagnostics")) {
                toggle(L("Claude IP 出口检测", "Claude exit IP check"), "globe", $prefs.enableClaudeDiagnostics)
                Text(L("关闭后隐藏诊断入口并停止检测，网速与流量统计照常显示。", "When off, the diagnostics page is hidden and checks stop. Network speed and traffic stay visible."))
                    .font(Typeface.ui(10.5))
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
            }
            about
        }
    }

    private var about: some View {
        section(L("关于", "About")) {
            HStack {
                Text("Status \(updater.currentVersion)")
                Spacer()
                updateStatus
            }
            .frame(height: 24)
            HStack {
                Text(L("自动检查更新", "Check for updates automatically"))
                Spacer()
                Toggle("", isOn: Binding(get: { updater.autoCheck }, set: { updater.autoCheck = $0 }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            .frame(height: 24)
            HStack {
                Link(destination: UpdateChecker.repositoryURL) {
                    Label(L("项目主页", "Project page"), systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Spacer()
                Link(destination: UpdateChecker.authorURL) {
                    Label("@fancyecho", systemImage: "person.crop.circle")
                }
            }
            .font(Typeface.ui(11.5))
            .foregroundStyle(Ink.secondary)
            .frame(height: 24)
            .hint(L("在 GitHub 上查看", "View on GitHub"))
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        // 各个状态都保持胶囊按钮的外形，只换图标和文字，切换时不会跳
        Group {
            switch updater.state {
            case .checking:
                Button {} label: {
                    HStack(spacing: 4) {
                        SpinningSymbol(name: "arrow.triangle.2.circlepath")
                        Text(L("正在检查…", "Checking…"))
                    }
                }
                .buttonStyle(PillButtonStyle())
                .disabled(true)
            case .upToDate:
                Button { updater.check() } label: {
                    Label(L("已是最新", "Up to date"), systemImage: "checkmark")
                        .foregroundStyle(Palette.battery)
                }
                .buttonStyle(PillButtonStyle())
                .hint(L("点击再检查一次", "Click to check again"))
            case .available(let release), .downloading(let release):
                Button { updater.downloadUpdate() } label: {
                    Label(updater.state == .downloading(release) ? L("正在下载…", "Downloading…") : L("下载 ", "Download ") + release.version,
                          systemImage: "arrow.down")
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .disabled(updater.state == .downloading(release))
            case .failed(let message):
                HStack(spacing: 6) {
                    Text(message).foregroundStyle(.orange).lineLimit(1)
                    Button(L("重试", "Retry")) { updater.check() }.buttonStyle(PillButtonStyle())
                }
            case .idle:
                Button { updater.check() } label: {
                    Label(L("检查更新", "Check for Updates"), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(PillButtonStyle())
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .animation(.snappy(duration: 0.25), value: updater.state)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Typeface.ui(11, .medium))
                .foregroundStyle(Ink.secondary)
                .padding(.leading, 2)
            VStack(spacing: 2, content: content)
                .font(Typeface.ui(12))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .card()
        }
    }

    private func toggle(_ title: String, _ symbol: String, _ binding: Binding<Bool>) -> some View {
        HStack {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(Ink.secondary)
            Text(title)
            Spacer()
            Toggle("", isOn: binding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .frame(height: 24)
    }
}

// MARK: - Page height

/// 各页面量出来的高度，切换页面时容器直接用新页面的高度做动画
@MainActor
private final class PageHeights: ObservableObject {
    @Published private(set) var values: [Preferences.Page: CGFloat] = [:]

    func update(_ page: Preferences.Page, _ height: CGFloat) {
        guard height > 0, abs((values[page] ?? 0) - height) > 0.5 else { return }
        values[page] = height
    }
}

private struct PageHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct PageHeightReader: View {
    let onChange: (CGFloat) -> Void

    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: PageHeightKey.self, value: geo.size.height)
        }
        .onPreferenceChange(PageHeightKey.self) { height in
            MainActor.assumeIsolated { onChange(height) }
        }
    }
}
