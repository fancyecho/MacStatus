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
        // 换语言时整块重建，所有文字立即更新
        .id(prefs.language.rawValue)
        .environment(\.hintCenter, hints)
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
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SystemInfo.computerName)
                    .font(Typeface.ui(14, .semibold))
                    .tracking(-0.1)
                    .lineLimit(1)
                Text("\(SystemInfo.chip) · \(SystemInfo.osVersion) · " + L("已运行 ", "up ") + Fmt.uptime(monitor.uptime))
                    .font(Typeface.ui(10.5, .medium))
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { prefs.page = prefs.page == .overview ? .settings : .overview } label: {
                Image(systemName: prefs.page == .overview ? "gearshape" : "chevron.left")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(IconButtonStyle())
            .keyboardShortcut(",")
            .accessibilityLabel(prefs.page == .overview ? L("设置", "Settings") : L("返回", "Back"))
        }
        .padding(.leading, 4)
        .padding(.trailing, 1)
        .padding(.top, 1)
        .padding(.bottom, 1)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            } label: {
                Label(L("活动监视器", "Activity Monitor"), systemImage: "arrow.up.right")
                    .labelStyle(TrailingIconLabelStyle())
            }
            .buttonStyle(SubtleButtonStyle())
            .foregroundStyle(Ink.secondary)
            Spacer()
            if let release = updater.availableRelease {
                Button { updater.downloadUpdate() } label: {
                    Label(updater.state == .downloading(release) ? L("正在下载…", "Downloading…") : L("新版本 ", "New version ") + release.version,
                          systemImage: "arrow.down")
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .disabled(updater.state == .downloading(release))
                .hint(L("下载新版本到“下载”文件夹并打开，把 Status 拖进“应用程序”替换即可", "Downloads the new version to your Downloads folder and opens it. Drag Status into Applications to replace the old one."))
            }
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .buttonStyle(IconButtonStyle(diameter: 24))
            .keyboardShortcut("q")
            .accessibilityLabel(L("退出", "Quit"))
        }
        .font(Typeface.ui(11, .medium))
        .padding(.leading, -4)
        .padding(.trailing, 1)
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
        Tile(title: "CPU", symbol: "cpu") {
            if let temp = monitor.temperature?.cpu {
                TemperatureBadge(celsius: temp)
            } else if let load = monitor.loadAverage.first {
                Text(String(format: "%.2f", load)).monospacedDigit()
            }
        } content: {
            BigNumber(value: Fmt.percent(monitor.cpu.usage), unit: "%")
            Sparkline(values: monitor.cpuHistory, maxValue: 100, tint: Palette.cpu, guides: [0.5],
                      readout: ChartReadout(interval: prefs.interval) { [history = monitor.cpuHistory] in
                          "\(Fmt.percent(history[$0]))%"
                      })
                .frame(minHeight: 28, maxHeight: .infinity)
            CoreBars(cores: monitor.cpu.cores, tint: Palette.cpu)
                .frame(height: 14)
            HStack(spacing: 12) {
                InlineStat(label: L("用户", "User"), value: "\(Fmt.percent(monitor.cpu.user))%")
                InlineStat(label: L("系统", "System"), value: "\(Fmt.percent(monitor.cpu.system))%")
            }
        }
    }

    private var memoryTile: some View {
        let m = monitor.memory
        let (used, unit) = Fmt.bytesParts(Double(m.used), base: 1024)
        return Tile(title: L("内存", "Memory"), symbol: "memorychip") {
            if m.pressureLevel > 1 {
                PressureBadge(level: m.pressureLevel)
            } else {
                Text("\(Fmt.percent(m.usedPercent))%").monospacedDigit()
            }
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                BigNumber(value: used, unit: unit)
                Text("/ \(Fmt.memory(m.total))")
                    .font(Typeface.ui(10.5, .medium))
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
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
        Tile(title: "GPU", symbol: "square.stack.3d.up") {
            if let temp = monitor.temperature?.gpu {
                TemperatureBadge(celsius: temp)
            }
        } content: {
            BigNumber(value: Fmt.percent(monitor.gpu ?? 0), unit: "%")
            Sparkline(values: monitor.gpuHistory, maxValue: 100, tint: Palette.gpu, guides: [0.5],
                      readout: ChartReadout(interval: prefs.interval) { [history = monitor.gpuHistory] in
                          "\(Fmt.percent(history[$0]))%"
                      })
                .frame(minHeight: 28, maxHeight: .infinity)
        }
    }

    private var diskTile: some View {
        let d = monitor.disk
        let (free, unit) = Fmt.bytesParts(Double(d.free))
        // 卷名放在悬停提示里：标题统一成"磁盘"，长卷名不会把标题挤断
        return Tile(title: L("磁盘", "Disk"), symbol: "internaldrive") {
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
                    .accessibilityLabel(L("网络，查看 Claude 网络诊断", "Network, open Claude network diagnostics"))
            } else {
                networkTile(n)
            }
        }
    }

    private func networkTile(_ n: NetworkSnapshot) -> some View {
        Tile(title: L("网络", "Network"), symbol: "network") {
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
                .frame(height: 46)
            Rectangle().fill(Ink.hairline).frame(height: 0.5).padding(.top, 1)
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
                    Text(verbatim: Self.rate(wifi.rate))
                }
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
        }
        .lineLimit(1)
        .font(Typeface.ui(10.5, .medium))
        .foregroundStyle(Ink.secondary)
        .monospacedDigit()
        .frame(height: 14)
        // 整行都能触发，比只挂在小小的延迟数字上容易得多
        .padding(.vertical, 4)
        .hint(details)
        .padding(.vertical, -4)
    }

    private static func rate(_ mbps: Double) -> String {
        mbps >= 1000 ? String(format: "%.1f Gbps", mbps / 1000) : String(format: "%.0f Mbps", mbps)
    }

    private static func ms(_ value: Double?) -> String {
        value.map { String(format: "%.0f ms", $0) } ?? L("无响应", "No reply")
    }

    private static func latencyTint(_ value: Double?) -> Color {
        switch value {
        case nil: Ink.tertiary
        case let v? where v < 60: Palette.battery
        case let v? where v < 150: Color.orange
        default: Color.red
        }
    }

    /// Wi-Fi 信号和各个目标的往返延迟
    private var details: HintContent {
        var rows: [HintContent.Row] = []
        if let wifi {
            rows.append(.init(label: L("信号", "Signal"), value: "\(wifi.rssi) dBm"))
            rows.append(.init(label: L("信噪比", "SNR"), value: "\(wifi.rssi - wifi.noise) dB"))
            rows.append(.init(label: L("信道", "Channel"), value: wifi.band.isEmpty ? "\(wifi.channel)" : "\(wifi.channel) · \(wifi.band)"))
            rows.append(.init(label: L("速率", "Link rate"), value: Self.rate(wifi.rate)))
        }
        if let gateway = latency?.gateway {
            rows.append(.init(label: L("网关", "Router"), value: Self.ms(gateway), tint: Self.latencyTint(gateway)))
        }
        for target in latency?.targets ?? [] {
            rows.append(.init(label: "\(target.name)  \(target.host)", value: Self.ms(target.milliseconds),
                              tint: Self.latencyTint(target.milliseconds)))
        }
        return HintContent(title: wifi == nil ? L("网络质量", "Network Quality") : L("Wi-Fi 与延迟", "Wi-Fi & Latency"), rows: rows,
                           note: L("“互联网”取以上任播 DNS 中最快的一个，只在面板打开时测量。", "Internet is the fastest of these anycast DNS servers, measured only while the panel is open."))
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

private struct RateView: View {
    let symbol: String
    let tint: Color
    let value: Double

    var body: some View {
        let (number, unit) = Fmt.bytesParts(value)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(Typeface.ui(8.5, .heavy))
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)
                .background { Circle().fill(tint.opacity(0.16)) }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            BigNumber(value: number, unit: "\(unit)/s", size: 21)
        }
    }
}

/// 小号的"标签 数值"：标签淡、数值实，用在大数字下面的补充信息
private struct InlineStat: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(Ink.tertiary)
            Text(value).foregroundStyle(Ink.secondary).monospacedDigit()
        }
        .font(Typeface.ui(10.5, .medium))
        .lineLimit(1)
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
        let byCPU = prefs.processSort == .cpu
        let rows = byCPU ? monitor.topByCPU : monitor.topByMemory
        // 热度条：CPU 按"占满一个核心"计满，内存按榜首计满，只用来比较各行
        let scale = byCPU ? max(100, rows.map(\.cpu).max() ?? 0) : Double(max(rows.map(\.memory).max() ?? 1, 1))
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "list.bullet")
                    .font(Typeface.ui(9.5, .semibold))
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: 12)
                SectionLabel(L("进程", "Processes"))
                Spacer()
                GlassSegmentedControl(L("进程排序", "Sort processes"), selection: $prefs.processSort,
                                      options: [(.cpu, "CPU"), (.memory, L("内存", "Memory"))], height: 18)
            }
            .frame(height: 18)
            VStack(spacing: 2) {
                ForEach(rows) { row in
                    ProcessRow(row: row,
                               value: byCPU ? String(format: "%.1f%%", row.cpu) : Fmt.memory(row.memory),
                               fraction: byCPU ? row.cpu / scale : Double(row.memory) / scale,
                               tint: byCPU ? Palette.cpu : Palette.memory)
                }
            }
            // 排名变化时各行滑到新位置，而不是原地跳字
            .animation(.snappy(duration: 0.35), value: rows.map(\.id))
            // 固定 5 行的高度：刚打开、进程还没采到时卡片也不会变矮
            .frame(height: 5 * 22 + 4 * 2, alignment: .top)
        }
        .padding(12)
        .card()
    }
}

/// 一行进程：底下一条很淡的热度条表示占用，悬停高亮，右键可以在访达中显示或退出应用
private struct ProcessRow: View {
    let row: ProcessEntry
    let value: String
    let fraction: Double
    let tint: Color
    @StateObject private var hover = HoverState()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
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
                .font(Typeface.ui(11.5, .medium))
                .monospacedDigit()
                .foregroundStyle(Ink.secondary)
        }
        .font(Typeface.ui(12))
        .frame(height: 22)
        .padding(.horizontal, 6)
        .background {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    shape.fill(Color.primary.opacity(hover.hovering ? 0.06 : 0))
                    shape.fill(LinearGradient(colors: [tint.opacity(0.05), tint.opacity(0.17)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * min(max(fraction, 0), 1))
                        .opacity(fraction > 0.004 ? 1 : 0)
                }
            }
        }
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onHover { hover.hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.hovering)
        .animation(.easeOut(duration: 0.4), value: fraction)
        .contextMenu { ProcessMenu(row: row) }
    }
}

/// 右键菜单单独成一个视图：查询 NSRunningApplication 要走 LaunchServices，
/// 放在这里只在打开菜单时才做，而不是每次刷新进程列表都查一遍
private struct ProcessMenu: View {
    let row: ProcessEntry

    var body: some View {
        let app = NSRunningApplication(processIdentifier: row.id)
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

// MARK: - Settings

private struct SettingsView: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var monitor: SystemMonitor
    @ObservedObject private var updater = UpdateChecker.shared

    var body: some View {
        // 设置项比屏幕高，和网络诊断页一样放进固定高度的滚动区
        PanelScrollView { sections }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 8) {
            section(L("菜单栏显示", "Menu Bar")) {
                toggle("CPU", "cpu", Palette.cpu, $prefs.showCPU)
                toggle(L("CPU 温度", "CPU temperature"), "thermometer.medium", Color(red: 1, green: 0.42, blue: 0.36), $prefs.showTemperature)
                toggle(L("内存", "Memory"), "memorychip", Palette.memory, $prefs.showMemory)
                toggle("GPU", "square.stack.3d.up", Palette.gpu, $prefs.showGPU)
                toggle(L("网速", "Network speed"), "network", Palette.down, $prefs.showNetwork)
                toggle(L("电池", "Battery"), "battery.75percent", Palette.battery, $prefs.showBattery)
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
                        .toggleStyle(PanelSwitchStyle())
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
            section(L("语言", "Language")) {
                HStack {
                    Text(L("界面语言", "Interface language"))
                    Spacer()
                    GlassSegmentedControl(L("语言", "Language"), selection: $prefs.language,
                                          options: AppLanguage.allCases.map { ($0, $0.title) })
                }
                .frame(height: 24)
            }
            section(L("提醒", "Alerts")) {
                toggle(L("电量低于 20%", "Battery below 20%"), "battery.25percent", Palette.battery, $prefs.alertLowBattery)
                toggle(L("CPU 持续过热", "CPU running hot"), "thermometer.high", Color(red: 1, green: 0.42, blue: 0.36), $prefs.alertHot)
                toggle(L("内存压力过高", "Memory pressure critical"), "memorychip", Palette.memory, $prefs.alertMemory)
                toggle(L("磁盘空间不足 10 GB", "Less than 10 GB disk space"), "internaldrive", Palette.disk, $prefs.alertDisk)
                toggle(L("进程持续占满 CPU 5 分钟", "Process maxing CPU for 5 min"), "flame.fill", Color(red: 1, green: 0.55, blue: 0.25), $prefs.alertRunaway)
            }
            .onChange(of: prefs.anyAlertEnabled) { _, enabled in
                if enabled { monitor.alerts.requestAuthorizationIfNeeded() }
            }
            section(L("网络诊断", "Network Diagnostics")) {
                toggle(L("Claude IP 出口检测", "Claude exit IP check"), "globe", Color(red: 0.85, green: 0.52, blue: 0.38), $prefs.enableClaudeDiagnostics)
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
                    .toggleStyle(PanelSwitchStyle())
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
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title)
                .padding(.leading, 4)
            VStack(spacing: 2, content: content)
                .font(Typeface.ui(12))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .card()
        }
        .padding(.top, 2)
    }

    private func toggle(_ title: String, _ symbol: String, _ tint: Color, _ binding: Binding<Bool>) -> some View {
        HStack(spacing: 9) {
            SettingsIcon(symbol: symbol, tint: tint)
            Text(title)
            Spacer()
            Toggle("", isOn: binding)
                .toggleStyle(PanelSwitchStyle())
                .labelsHidden()
        }
        .frame(height: 24)
    }
}

/// 设置项前的小图标：彩色圆角方块 + 白色符号，和系统设置一致
private struct SettingsIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Image(systemName: symbol)
            .font(Typeface.ui(9.5, .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background {
                shape.fill(LinearGradient(colors: [tint.opacity(0.92), tint], startPoint: .top, endPoint: .bottom))
                    .overlay { shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5) }
            }
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
