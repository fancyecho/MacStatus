import ServiceManagement
import SwiftUI

struct PanelView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var prefs: Preferences
    @ObservedObject private var updater = UpdateChecker.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            header
            switch prefs.page {
            case .overview:
                overview
                    .transition(pageTransition(from: .leading))
            case .settings:
                SettingsView()
                    .transition(pageTransition(from: .trailing))
            case .battery:
                BatteryDetailView()
                    .transition(pageTransition(from: .trailing))
            }
            footer
        }
        .padding(Metrics.panelPadding)
        .padding(.top, 2)
        .frame(width: 340)
        .animation(.snappy(duration: 0.25), value: prefs.page)
    }

    /// 切换页面时从侧边滑入；开启"减弱动态效果"时只淡入淡出
    private func pageTransition(from edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: edge))
    }

    // MARK: Header / Footer

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(SystemInfo.computerName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("\(SystemInfo.chip) · \(SystemInfo.osVersion) · 已运行 \(Fmt.uptime(monitor.uptime))")
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button { prefs.page = prefs.page == .overview ? .settings : .overview } label: {
                Image(systemName: prefs.page == .overview ? "slider.horizontal.3" : "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16, height: 16)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(SubtleButtonStyle())
            .keyboardShortcut(",")
            .help(prefs.page == .overview ? "设置（⌘,）" : "返回（Esc）")
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            } label: {
                Label("活动监视器", systemImage: "arrow.up.forward.app")
            }
            Spacer()
            if let release = updater.availableRelease {
                Button { updater.downloadUpdate() } label: {
                    Label(updater.state == .downloading(release) ? "正在下载…" : "新版本 \(release.version)",
                          systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
                .disabled(updater.state == .downloading(release))
                .help("下载新版本到“下载”文件夹并打开，把 Status 拖进“应用程序”替换即可")
            }
            Button { NSApp.terminate(nil) } label: {
                Text("退出")
            }
            .keyboardShortcut("q")
        }
        .font(.system(size: 11))
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

            HStack(spacing: 8) {
                if monitor.gpu != nil { gpuTile }
                diskTile
            }
            .fixedSize(horizontal: false, vertical: true)

            networkCard
            if let battery = monitor.battery {
                BatterySummaryCard(battery: battery, estimate: monitor.batteryEstimate) { prefs.page = .battery }
            }
            ProcessCard()
        }
    }

    private var cpuTile: some View {
        Tile(title: "CPU", symbol: "cpu", tint: Palette.cpu) {
            if let t = monitor.temperature, let temp = t.cpu {
                TemperatureBadge(celsius: temp).help(temperatureHelp(t))
            } else if let load = monitor.loadAverage.first {
                Text(String(format: "%.2f", load)).monospacedDigit().help("1 分钟平均负载")
            }
        } content: {
            BigNumber(value: Fmt.percent(monitor.cpu.usage), unit: "%")
                .help(monitor.loadAverage.isEmpty ? "" : "平均负载 " + monitor.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " / "))
            Sparkline(values: monitor.cpuHistory, maxValue: 100, tint: Palette.cpu)
                .frame(minHeight: 24, maxHeight: .infinity)
            CoreBars(cores: monitor.cpu.cores, tint: Palette.cpu)
                .frame(height: 12)
                .help("每个核心的占用")
            HStack(spacing: 10) {
                Text("用户 \(Fmt.percent(monitor.cpu.user))%")
                Text("系统 \(Fmt.percent(monitor.cpu.system))%")
            }
            .lineLimit(1)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Ink.secondary)
            .monospacedDigit()
        }
    }

    private var memoryTile: some View {
        let m = monitor.memory
        let (used, unit) = Fmt.bytesParts(Double(m.used), base: 1024)
        return Tile(title: "内存", symbol: "memorychip", tint: Palette.memory) {
            if m.pressureLevel > 1 {
                PressureBadge(level: m.pressureLevel)
            } else {
                Text("\(Fmt.percent(m.usedPercent))%").monospacedDigit()
                    .help("内存压力正常。macOS 会主动把空闲内存用作缓存并压缩不常用的数据，所以占用高是正常的，只有内存压力升高时才需要关注。")
            }
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                BigNumber(value: used, unit: unit)
                Text("/ \(Fmt.memory(m.total))")
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.tertiary)
            }
            SegmentBar(segments: [
                (Double(m.app), Palette.memory),
                (Double(m.wired), Palette.memory.opacity(0.6)),
                (Double(m.compressed), Palette.memory.opacity(0.35)),
            ], total: Double(m.total))
            .padding(.vertical, 2)
            VStack(spacing: 2) {
                Legend(color: Palette.memory, label: "应用", value: Fmt.memory(m.app))
                Legend(color: Palette.memory.opacity(0.6), label: "联动", value: Fmt.memory(m.wired))
                Legend(color: Palette.memory.opacity(0.35), label: "压缩", value: Fmt.memory(m.compressed))
                Legend(color: Ink.tertiary, label: "交换", value: Fmt.memory(m.swapUsed))
            }
        }
    }

    private var gpuTile: some View {
        Tile(title: "GPU", symbol: "square.stack.3d.up", tint: Palette.gpu) {
            if let temp = monitor.temperature?.gpu {
                TemperatureBadge(celsius: temp).help("GPU 温度")
            }
        } content: {
            BigNumber(value: Fmt.percent(monitor.gpu ?? 0), unit: "%")
            Sparkline(values: monitor.gpuHistory, maxValue: 100, tint: Palette.gpu)
                .frame(minHeight: 24, maxHeight: .infinity)
        }
    }

    private var diskTile: some View {
        let d = monitor.disk
        let (free, unit) = Fmt.bytesParts(Double(d.free))
        return Tile(title: d.name, symbol: "internaldrive", tint: Palette.disk) {
            Text("\(Fmt.percent(d.usedPercent))%").monospacedDigit()
        } content: {
            BigNumber(value: free, unit: "\(unit) 可用")
            MeterBar(fraction: d.usedPercent / 100, tint: Palette.disk)
                .padding(.vertical, 2)
            VStack(spacing: 2) {
                Legend(color: Palette.disk, label: "读取", value: Fmt.rate(d.read), symbol: "arrow.down")
                Legend(color: Palette.disk.opacity(0.7), label: "写入", value: Fmt.rate(d.write), symbol: "arrow.up")
            }
        }
    }

    private var networkCard: some View {
        let n = monitor.network
        return Tile(title: "网络", symbol: "network", tint: Palette.down) {
            Text(n.address ?? "未连接").monospacedDigit().textSelection(.enabled)
        } content: {
            HStack(alignment: .firstTextBaseline) {
                RateView(symbol: "arrow.down", tint: Palette.down, value: n.down)
                Spacer()
                RateView(symbol: "arrow.up", tint: Palette.up, value: n.up)
            }
            MirrorChart(top: monitor.downHistory, bottom: monitor.upHistory, topTint: Palette.down, bottomTint: Palette.up)
                .frame(height: 44)
            HStack {
                Text("开机以来  ↓ \(Fmt.bytes(n.totalDown))  ↑ \(Fmt.bytes(n.totalUp))")
                Spacer(minLength: 8)
                Text("峰值 \(Fmt.rate(max(monitor.downHistory.max() ?? 0, monitor.upHistory.max() ?? 0)))")
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(height: 14)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Ink.tertiary)
            .monospacedDigit()
        }
    }
}

// MARK: - Pieces

private func temperatureHelp(_ t: TemperatureSnapshot) -> String {
    var lines = ["CPU 温度：\(t.cpuSensorCount) 个传感器的平均值"]
    if let max = t.cpuMax { lines.append(String(format: "其中最高 %.0f°C", max)) }
    lines.append("来源：\(t.cpuSource)")
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
                .font(.system(size: 11, weight: .bold))
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
        let (text, color): (String, Color) = level >= 4 ? ("压力过高", .red) : ("压力偏高", .orange)
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text)
        }
        .foregroundStyle(color)
        .help("系统内存压力升高，可能开始频繁压缩或使用交换空间，可以关闭一些占内存的应用。")
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
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                Text("进程")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Ink.secondary)
                Spacer()
                Picker("", selection: $prefs.processSort) {
                    Text("CPU").tag(Preferences.ProcessSort.cpu)
                    Text("内存").tag(Preferences.ProcessSort.memory)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 96)
            }
            VStack(spacing: 3) {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Image(nsImage: row.icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 16, height: 16)
                        Text(row.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(prefs.processSort == .cpu ? String(format: "%.1f%%", row.cpu) : Fmt.memory(row.memory))
                            .monospacedDigit()
                            .foregroundStyle(Ink.secondary)
                    }
                    .font(.system(size: 12))
                    .frame(height: 20)
                    .contentShape(Rectangle())
                    .help("\(row.name)\nPID \(row.id) · CPU \(String(format: "%.1f%%", row.cpu)) · 内存 \(Fmt.memory(row.memory))")
                }
            }
            // 固定 5 行的高度：刚打开、进程还没采到时卡片也不会变矮
            .frame(height: 5 * 20 + 4 * 3, alignment: .top)
        }
        .padding(10)
        .card()
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @EnvironmentObject private var prefs: Preferences
    @ObservedObject private var updater = UpdateChecker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            section("菜单栏显示") {
                toggle("CPU", "cpu", $prefs.showCPU)
                toggle("CPU 温度", "thermometer.medium", $prefs.showTemperature)
                toggle("内存", "memorychip", $prefs.showMemory)
                toggle("GPU", "square.stack.3d.up", $prefs.showGPU)
                toggle("网速", "network", $prefs.showNetwork)
                toggle("电池", "battery.75percent", $prefs.showBattery)
            }
            section("通用") {
                HStack {
                    Text("刷新间隔")
                    Spacer()
                    Picker("", selection: $prefs.interval) {
                        Text("1 秒").tag(1.0)
                        Text("2 秒").tag(2.0)
                        Text("3 秒").tag(3.0)
                        Text("5 秒").tag(5.0)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 180)
                }
                .frame(height: 24)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("充电上限")
                        Spacer()
                        Picker("", selection: $prefs.chargeLimit) {
                            Text("自动").tag(0)
                            ForEach([80, 85, 90, 95, 100], id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 214)
                    }
                    .frame(height: 24)
                    Text("只用于估算充电时间，不会改变实际充电。实际上限请在 系统设置 › 电池 中设置；“自动”使用系统自己的估计。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)
                }
                HStack {
                    Text("登录时启动")
                    Spacer()
                    Toggle("", isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.launchAtLogin = $0 }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
                .frame(height: 24)
                if prefs.loginItemNeedsApproval || prefs.loginItemError != nil {
                    HStack(spacing: 6) {
                        Text(prefs.loginItemError ?? "需要在 系统设置 › 通用 › 登录项 中允许 Status")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button("打开") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                    .padding(.bottom, 4)
                }
            }
            about
        }
    }

    private var about: some View {
        section("关于") {
            HStack {
                Text("Status \(updater.currentVersion)")
                Spacer()
                updateStatus
            }
            .frame(height: 24)
            HStack {
                Text("自动检查更新")
                Spacer()
                Toggle("", isOn: Binding(get: { updater.autoCheck }, set: { updater.autoCheck = $0 }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            .frame(height: 24)
            HStack {
                Link(destination: UpdateChecker.repositoryURL) {
                    Label("项目主页", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Spacer()
                Link(destination: UpdateChecker.authorURL) {
                    Label("@fancyecho", systemImage: "person.crop.circle")
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Ink.secondary)
            .frame(height: 24)
            .help("在 GitHub 上查看")
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updater.state {
        case .checking:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("正在检查…").foregroundStyle(Ink.secondary)
            }
        case .upToDate:
            Label("已是最新版本", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Palette.battery)
        case .available(let release), .downloading(let release):
            Button("下载 \(release.version)") { updater.downloadUpdate() }
                .controlSize(.small)
                .disabled(updater.state == .downloading(release))
        case .failed(let message):
            HStack(spacing: 6) {
                Text(message).foregroundStyle(.orange)
                Button("重试") { updater.check() }.controlSize(.small)
            }
        case .idle:
            Button("检查更新") { updater.check() }.controlSize(.small)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .padding(.leading, 2)
            VStack(spacing: 2, content: content)
                .font(.system(size: 12))
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
