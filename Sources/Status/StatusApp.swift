import Combine
import SwiftUI

@main
struct StatusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

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
                    self.prefs.showingSettings = false
                }
            }
        }
        panel.onEscape = { [weak self] in
            guard let self, self.prefs.showingSettings else { return false }
            self.prefs.showingSettings = false
            return true
        }

        // 数值或菜单栏设置变化时重绘图标（receive(on:) 保证读到的是变化后的值）
        Publishers.Merge(monitor.menuBar.objectWillChange, prefs.objectWillChange)
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
        statusItem.button?.image = MenuBarIcon.render(values: monitor.menuBar.values, prefs: prefs)
    }
}

/// 菜单栏只接受图片，所以把自定义布局渲染成模板图片，自动适配深浅色菜单栏
@MainActor
enum MenuBarIcon {
    static func render(values: MenuBarModel.Values, prefs: Preferences) -> NSImage {
        let renderer = ImageRenderer(content: MenuBarContent(values: values, prefs: prefs))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }
}

private struct MenuBarContent: View {
    let values: MenuBarModel.Values
    let prefs: Preferences

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
                HStack(spacing: 2) {
                    if values.charging { Image(systemName: "bolt.fill").font(.system(size: 8)) }
                    Text("\(battery)%").font(.system(size: 11, weight: .medium).monospacedDigit())
                }
            }
            if !prefs.showCPU && !prefs.showMemory && !prefs.showNetwork && !(prefs.showGPU && values.gpu != nil) && !(prefs.showBattery && values.battery != nil) && !(prefs.showTemperature && values.temperature != nil) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 14, weight: .medium))
            }
        }
        .foregroundStyle(.black)
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
