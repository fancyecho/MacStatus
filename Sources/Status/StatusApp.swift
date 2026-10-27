import Combine
import SwiftUI

@main
@MainActor
enum StatusApp {
    static func main() {
        if CommandLine.arguments.contains("--battery-info") {
            BatterySampler.printDiagnostics()
            return
        }
        // The app already owns a status item and NSPanel; a SwiftUI Settings scene
        // would create a second, empty window when launched/reopened by Finder.
        Typeface.registerBundledFonts()
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences()
    private let networkDiagnostics = ClaudeNetworkMonitor()
    private lazy var monitor = SystemMonitor(prefs: prefs)
    private var statusItem: NSStatusItem!
    private var panel: StatusPanel!
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let fixture = ProcessInfo.processInfo.environment["STATUS_NETWORK_FIXTURE"],
           let sample = NetworkSnapshotFixture.make(fixture) {
            networkDiagnostics.useDemo(sample, dns: NetworkSnapshotFixture.dns(fixture))
        }
        networkDiagnostics.setEnabled(prefs.enableClaudeDiagnostics)
        prefs.$enableClaudeDiagnostics.dropFirst().sink { [weak self] enabled in
            self?.networkDiagnostics.setEnabled(enabled)
        }.store(in: &subscriptions)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                  owner: self, userInfo: nil))
        }

        panel = StatusPanel(rootView: PanelView()
            .environmentObject(monitor)
            .environmentObject(prefs)
            .environmentObject(networkDiagnostics))
        // 打开时用已有的数据立刻重绘一次，和展开动画在同一帧开始
        panel.onWillShow = { [weak self] in self?.monitor.objectWillChange.send() }
        panel.onVisibilityChange = { [weak self] visible in
            guard let self else { return }
            self.statusItem.button?.highlight(visible)
            if visible {
                // 等展开动画基本结束再开始高频采样和刷新，避免重绘抢在动画前面造成卡顿
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self, self.panel.isShown else { return }
                    self.monitor.panelVisible = true
                }
            } else {
                self.monitor.panelVisible = false
            }
            // 打开面板时顺便看看是否该检查更新（每天最多一次），不需要额外的定时器
            if visible { UpdateChecker.shared.checkIfDue() }
            // 收起后回到概览页，下次打开总是先看到数据
            if !visible {
                self.networkDiagnostics.setVisible(false)
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

        if ProcessInfo.processInfo.environment["STATUS_PAGE"] == "network" { prefs.page = .network }
        Snapshot.scheduleIfRequested(monitor: monitor, prefs: prefs, panel: panel, statusItem: statusItem,
                                     networkDiagnostics: networkDiagnostics)

        // Read-only diagnostics without opening the panel, for target-machine verification.
        if CommandLine.arguments.contains("--check-network") {
            networkDiagnostics.refresh()
            networkDiagnostics.$isRefreshing.filter { !$0 }.first().sink { [weak self] _ in
                guard let result = self?.networkDiagnostics.result else { exit(2) }
                print("Status 请求路径 · \(result.checkedAt.ISO8601Format())")
                print("Claude 出口：\(result.exit?.ip ?? "未知")")
                print("API 出口：\(result.apiExit?.ip ?? "未知")")
                print("地区：\(result.place)")
                print("IP 属性：\(result.risk?.kind.rawValue ?? "未知")")
                print("Net.Coffee 第三方评分：\(result.risk?.trustScore.map { String($0) } ?? "未知")")
                if let dns = self?.networkDiagnostics.dns {
                    print("DNS：\(dns.assessment(comparedTo: result.exit).title) · \(dns.addresses.map(\.ip).joined(separator: ", "))")
                }
                if let udp = self?.networkDiagnostics.webRTC {
                    print("WebRTC UDP：\(udp.assessment(comparedTo: result.exit).title) · \(udp.publicIPs.joined(separator: ", "))")
                    if let reason = udp.error { print(reason) }
                }
                if let error = result.riskError { print(error) }
                for probe in result.probes {
                    print("\(probe.host)：\(probe.status.title) · HTTP \(probe.httpStatus.map(String.init) ?? "—") · \(probe.milliseconds.map { String(format: "%.0f ms", $0) } ?? "—")")
                }
                exit(result.exit == nil ? 2 : 0)
            }.store(in: &subscriptions)
        }

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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !panel.isShown, let button = statusItem.button { panel.show(below: button) }
        return false
    }

    /// 鼠标移到菜单栏图标上：预先采样，点击后面板可以立刻显示最新数据
    @objc func mouseEntered(with event: NSEvent) {
        monitor.prewarm()
    }

    @objc func mouseExited(with event: NSEvent) {}

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
