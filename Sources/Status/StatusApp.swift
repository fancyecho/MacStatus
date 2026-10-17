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
            // 打开面板时顺便看看是否该检查更新（每天最多一次），不需要额外的定时器
            if visible { UpdateChecker.shared.checkIfDue() }
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
        // 低电量模式下电池图标是彩色的，需要自己跟随菜单栏深浅色。
        // 注意：给按钮设置图片本身也会触发 effectiveAppearance 的 KVO，
        // 必须只在深浅色真正切换时才重绘，否则会形成"设图片 → 通知 → 再设图片"的循环
        statusItem.button?.publisher(for: \.effectiveAppearance)
            .map { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &subscriptions)
        updateIcon()

        Snapshot.scheduleIfRequested(monitor: monitor, prefs: prefs, panel: panel, statusItem: statusItem)

        // Status --check-update：检查一次更新并打印结果后退出
        if CommandLine.arguments.contains("--check-update") {
            let updater = UpdateChecker.shared
            updater.check()
            updater.$state
                .filter { $0 != .checking && $0 != .idle }
                .first()
                .sink { state in
                    print("当前版本 \(updater.currentVersion)：\(state)")
                    exit(0)
                }
                .store(in: &subscriptions)
        }
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        panel.toggle(below: button)
    }

    /// 上一次绘制时用到的全部输入；没变就不重绘，避免无谓的渲染和菜单栏刷新
    private var lastIconKey: IconKey?

    private struct IconKey: Equatable {
        let values: MenuBarModel.Values
        let toggles: [Bool]
        let dark: Bool
    }

    private func updateIcon() {
        let dark = statusItem.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // 只比较菜单栏上实际显示的数值：隐藏的项（比如没显示网速时的网速）变化不需要重绘
        var shown = monitor.menuBar.values
        if !prefs.showCPU { shown.cpu = 0 }
        if !prefs.showMemory { shown.memory = 0 }
        if !prefs.showGPU { shown.gpu = nil }
        if !prefs.showNetwork { shown.up = ""; shown.down = "" }
        if !prefs.showTemperature { shown.temperature = nil }
        if !prefs.showBattery { shown.battery = nil; shown.charging = false; shown.lowPower = false }
        let key = IconKey(values: shown,
                          toggles: [prefs.showCPU, prefs.showMemory, prefs.showGPU, prefs.showNetwork,
                                    prefs.showBattery, prefs.showTemperature],
                          dark: dark)
        guard key != lastIconKey else { return }
        lastIconKey = key
        statusItem.button?.image = MenuBarIcon.render(values: key.values, prefs: prefs, darkMenuBar: dark)
    }
}

/// 菜单栏只接受图片，所以把自定义布局渲染成模板图片，自动适配深浅色菜单栏。
/// 例外：低电量模式下电池要显示成黄色，模板图片做不到，改为按菜单栏深浅色直接上色
@MainActor
enum MenuBarIcon {
    static func render(values: MenuBarModel.Values, prefs: Preferences, darkMenuBar: Bool) -> NSImage {
        let colored = prefs.showBattery && values.battery != nil && values.lowPower
        let ink: NSColor = colored && darkMenuBar ? .white : .black
        let fill: NSColor = colored ? NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1) : ink
        let image = MenuBarRenderer.render(values: values, prefs: prefs, ink: ink, batteryFill: fill)
        image.isTemplate = !colored
        return image
    }
}
