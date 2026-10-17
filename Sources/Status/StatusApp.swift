import Combine
import SwiftUI

@main
struct StatusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Status --battery-info：打印电池原始数据后退出，用于排查字段
        if CommandLine.arguments.contains("--battery-info") {
            BatterySampler.printDiagnostics()
            exit(0)
        }
    }

    var body: some Scene {
        // 界面全部由 AppDelegate 里的状态栏图标和自定义面板负责
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences()
    private lazy var monitor = SystemMonitor(prefs: prefs)
    private var statusItem: NSStatusItem!
    private var panel: StatusPanel!
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        panel = StatusPanel(rootView: PanelView()
            .environmentObject(monitor)
            .environmentObject(prefs))
        panel.onVisibilityChange = { [weak self] visible in
            guard let self else { return }
            self.monitor.panelVisible = visible
            self.statusItem.button?.highlight(visible)
            // 收起后回到概览页，下次打开总是先看到数据
            if !visible {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self, !self.panel.isShown else { return }
                    self.prefs.page = .overview
                }
            }
        }
        panel.onEscape = { [weak self] in
            guard let self, self.prefs.page != .overview else { return false }
            self.prefs.page = .overview
            return true
        }

        // 数值或菜单栏设置变化时重绘图标（receive(on:) 保证读到的是变化后的值）
        Publishers.Merge(monitor.menuBar.objectWillChange, prefs.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &subscriptions)
        // 低电量模式下电池图标是彩色的，需要自己跟随菜单栏深浅色
        statusItem.button?.publisher(for: \.effectiveAppearance)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &subscriptions)
        updateIcon()

        Snapshot.scheduleIfRequested(monitor: monitor, prefs: prefs, panel: panel, statusItem: statusItem)
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        panel.toggle(below: button)
    }

    private func updateIcon() {
        let dark = statusItem.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        statusItem.button?.image = MenuBarIcon.render(values: monitor.menuBar.values, prefs: prefs, darkMenuBar: dark)
    }
}

/// 菜单栏只接受图片，所以把自定义布局渲染成模板图片，自动适配深浅色菜单栏。
/// 例外：低电量模式下电池要显示成黄色，模板图片做不到，改为按菜单栏深浅色直接上色
@MainActor
enum MenuBarIcon {
    static func render(values: MenuBarModel.Values, prefs: Preferences, darkMenuBar: Bool) -> NSImage {
        let colored = prefs.showBattery && values.battery != nil && values.lowPower
        let ink: Color = colored && darkMenuBar ? .white : .black
        let renderer = ImageRenderer(content: MenuBarContent(values: values, prefs: prefs, ink: ink, colored: colored))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = !colored
        return image
    }
}

private struct MenuBarContent: View {
    let values: MenuBarModel.Values
    let prefs: Preferences
    let ink: Color
    let colored: Bool

    var body: some View {
        HStack(spacing: 9) {
            if prefs.showCPU {
                StackedMetric(title: "CPU", value: values.cpu)
            }
            if prefs.showTemperature, let temperature = values.temperature {
                StackedMetric(title: "TEMP", value: temperature, suffix: "°")
            }
            if prefs.showMemory {
                StackedMetric(title: "MEM", value: values.memory)
            }
            if prefs.showGPU, let gpu = values.gpu {
                StackedMetric(title: "GPU", value: gpu)
            }
            if prefs.showNetwork {
                VStack(alignment: .trailing, spacing: -1.5) {
                    rateLine(values.up, arrow: "arrow.up")
                    rateLine(values.down, arrow: "arrow.down")
                }
                .frame(width: 44, alignment: .trailing)
            }
            if prefs.showBattery, let battery = values.battery {
                MenuBarBattery(percent: battery, charging: values.charging, ink: ink,
                               fill: colored ? Color(red: 1.0, green: 0.8, blue: 0.0) : ink)
            }
            if !prefs.showCPU && !prefs.showMemory && !prefs.showNetwork && !(prefs.showGPU && values.gpu != nil) && !(prefs.showBattery && values.battery != nil) && !(prefs.showTemperature && values.temperature != nil) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 14, weight: .medium))
            }
        }
        .foregroundStyle(ink)
        .frame(height: 22)
        .fixedSize()
    }

    private func rateLine(_ value: String, arrow: String) -> some View {
        HStack(spacing: 2) {
            Text(value)
                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
            Image(systemName: arrow)
                .font(.system(size: 6.5, weight: .black))
                .opacity(0.6)
        }
    }
}

/// 两行：小标签 + 数值，左边一根竖向占用条
private struct StackedMetric: View {
    let title: String
    let value: Int
    var suffix = "%"

    var body: some View {
        HStack(spacing: 3) {
            ZStack(alignment: .bottom) {
                Capsule().opacity(0.22)
                Capsule().frame(height: max(2, 16 * CGFloat(min(value, 100)) / 100))
            }
            .frame(width: 3.5, height: 16)
            VStack(alignment: .leading, spacing: -2) {
                Text(title)
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.6)
                Text("\(value)\(suffix)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            }
            .frame(width: 26, alignment: .leading)
        }
    }
}

/// 菜单栏电池：数字在电池里面（类似 iOS）。填充部分上的数字镂空，空白部分上的数字实心；充电时右侧带闪电
private struct MenuBarBattery: View {
    let percent: Int
    let charging: Bool
    let ink: Color
    let fill: Color

    private let size = CGSize(width: 25, height: 12)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3.8, style: .continuous)
        let filled = max(2.5, size.width * CGFloat(min(max(percent, 0), 100)) / 100)
        let number = Text("\(percent)")
            .font(.system(size: percent >= 100 ? 8 : 9, weight: .bold, design: .rounded).monospacedDigit())
            .frame(width: size.width, height: size.height)

        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                shape.fill(ink.opacity(0.32))
                Rectangle().fill(fill).frame(width: filled)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay {
                ZStack {
                    // 空白部分：实心数字
                    number
                        .foregroundStyle(ink)
                        .mask(alignment: .leading) {
                            HStack(spacing: 0) { Color.clear.frame(width: filled); Color.black }
                        }
                    // 填充部分：镂空数字
                    number
                        .mask(alignment: .leading) { Color.black.frame(width: filled) }
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()

            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                   bottomTrailingRadius: 1.2, topTrailingRadius: 1.2)
                .fill(ink.opacity(0.4))
                .frame(width: 1.6, height: 4.5)

            if charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(ink)
                    .padding(.leading, 1)
            }
        }
    }
}
