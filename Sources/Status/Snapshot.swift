import AppKit
import SwiftUI

/// 调试用：
/// - STATUS_SNAPSHOT=<目录>：把面板渲染成 PNG 后退出（离屏渲染没有真实模糊，用纯色近似）
/// - STATUS_CHECK_PANEL=1：真实打开面板，打印它和菜单栏图标的位置后退出
/// - STATUS_SHOW_PANEL=<秒>：只打开面板（不模拟点击），停留后退出；可配合 STATUS_APPEARANCE=dark/light
@MainActor
enum Snapshot {
    static func scheduleIfRequested(monitor: SystemMonitor, prefs: Preferences, panel: StatusPanel, statusItem: NSStatusItem,
                                    networkDiagnostics: ClaudeNetworkMonitor) {
        let env = ProcessInfo.processInfo.environment
        if env["STATUS_CHECK_STARTUP"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                // Menu-bar icon windows are expected; count actual app content windows.
                let visible = NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)) != "NSStatusBarWindow" }
                print("startupContentWindows=\(visible.count)")
                visible.forEach { print("\(type(of: $0)): \($0.title)") }
                exit(visible.isEmpty ? 0 : 2)
            }
            return
        }
        if env["STATUS_CHECK_PANEL"] != nil {
            checkPanelPlacement(panel: panel, statusItem: statusItem, prefs: prefs)
            return
        }
        if let seconds = env["STATUS_SHOW_PANEL"].flatMap(Double.init) {
            showPanelForCapture(panel: panel, statusItem: statusItem, prefs: prefs, seconds: seconds)
            return
        }
        guard let dir = env["STATUS_SNAPSHOT"] else { return }
        if env["STATUS_NETWORK_LIVE"] != nil { networkDiagnostics.refresh() }
        let delay = Double(env["STATUS_SNAPSHOT_DELAY"] ?? "") ?? 7
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if env["STATUS_SNAPSHOT_NETWORK_ONLY"] != nil {
                prefs.page = .network
                for dark in [false, true] {
                    capture(PanelPreview(), monitor: monitor, prefs: prefs, networkDiagnostics: networkDiagnostics,
                            dark: dark, to: "\(dir)/network-\(dark ? "dark" : "light").png")
                }
                exit(0)
            }
            for dark in [false, true] {
                prefs.page = .overview
                capture(PanelPreview(), monitor: monitor, prefs: prefs, networkDiagnostics: networkDiagnostics, dark: dark, to: "\(dir)/panel-\(dark ? "dark" : "light").png")
            }
            prefs.page = .network
            for dark in [false, true] {
                capture(PanelPreview(), monitor: monitor, prefs: prefs, networkDiagnostics: networkDiagnostics, dark: dark,
                        to: "\(dir)/network-\(dark ? "dark" : "light").png")
            }
            prefs.page = .settings
            capture(PanelPreview(), monitor: monitor, prefs: prefs, networkDiagnostics: networkDiagnostics, dark: false, to: "\(dir)/settings.png")
            capture(PanelPreview(), monitor: monitor, prefs: prefs, networkDiagnostics: networkDiagnostics, dark: true, to: "\(dir)/settings-dark.png")
            if monitor.battery != nil {
                prefs.page = .battery
                for dark in [false, true] {
                    capture(PanelPreview(), monitor: monitor, prefs: prefs, networkDiagnostics: networkDiagnostics, dark: dark, to: "\(dir)/battery-\(dark ? "dark" : "light").png")
                }
            }
            prefs.page = .overview
            for dark in [false, true] {
                capture(MenuBarStrip(values: monitor.menuBar.values, prefs: prefs), monitor: monitor, prefs: prefs, networkDiagnostics: networkDiagnostics, dark: dark,
                        to: "\(dir)/menubar-\(dark ? "dark" : "light").png")
            }
            // 电池图标的几种状态：普通 / 充电 / 低电量 / 低电量模式 / 充满
            for dark in [false, true] {
                let icons = batteryIcons(prefs: prefs, dark: dark)
                capture(IconRow(images: icons), monitor: monitor, prefs: prefs, networkDiagnostics: networkDiagnostics, dark: dark,
                        to: "\(dir)/battery-icons-\(dark ? "dark" : "light").png")
            }
            exit(0)
        }
    }

    /// 只打开面板、不模拟点击，停留若干秒后退出，方便截屏检查真实的玻璃效果。
    /// STATUS_PAGES=battery,overview：打开后每隔 STATUS_PAGE_EVERY 秒（默认 2）依次切到这些页面，用来检查切换动画
    private static func showPanelForCapture(panel: StatusPanel, statusItem: NSStatusItem, prefs: Preferences, seconds: Double) {
        let env = ProcessInfo.processInfo.environment
        // STATUS_APPEARANCE=dark/light：不改系统设置也能检查两种外观
        switch env["STATUS_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let button = statusItem.button else { return }
            print("opening")
            fflush(stdout)
            panel.show(below: button)
            let pages: [String: Preferences.Page] = ["overview": .overview, "battery": .battery,
                                                     "settings": .settings, "network": .network]
            let every = Double(env["STATUS_PAGE_EVERY"] ?? "") ?? 2
            let sequence = (env["STATUS_PAGES"] ?? "").split(separator: ",").compactMap { pages[String($0)] }
            for (index, page) in sequence.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + every * Double(index + 1)) {
                    print("page=\(page)")
                    fflush(stdout)
                    prefs.page = page
                }
            }
            // 等打开动画和内容高度调整结束后再报告位置
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                print("panel=\(panel.panelFrame) window=\(panel.windowNumber)")
                fflush(stdout)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
        }
    }

    private static func checkPanelPlacement(panel: StatusPanel, statusItem: NSStatusItem, prefs: Preferences) {
        func anchor() -> NSRect {
            guard let button = statusItem.button, let window = button.window else { return .zero }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        func describe(_ label: String) {
            print("\(label): icon=\(anchor()) panel=\(panel.panelFrame) gapToIcon=\(anchor().minY - panel.panelFrame.maxY) shown=\(panel.isShown)")
        }
        /// 模拟一次真实的鼠标点击（需要辅助功能权限，没有权限时事件会被系统丢弃）
        func click(at point: NSPoint) {
            let flipped = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: flipped, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
        }
        func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(work) }
        }

        after(3) {
            guard let button = statusItem.button else { return }
            panel.show(below: button)
            var heights: [CGFloat] = []
            for i in 1...6 {
                after(Double(i) * 1.1) { heights.append(panel.panelFrame.height) }
            }
            after(7.5) {
                describe("overview")
                print("heights over 6 ticks: \(heights)")
                prefs.page = .battery
            }
            var batteryHeights: [CGFloat] = []
            for i in 1...5 {
                after(7.5 + Double(i) * 1.1) { batteryHeights.append(panel.panelFrame.height) }
            }
            after(14) {
                print("battery page heights: \(batteryHeights)")
                prefs.page = .settings
                after(1) {
                    describe("settings")
                    print("trusted for synthetic clicks: \(AXIsProcessTrusted())")
                    click(at: NSPoint(x: anchor().midX, y: anchor().midY))
                    after(1) {
                        describe("after clicking icon while open")
                        click(at: NSPoint(x: anchor().midX, y: anchor().midY))
                        for t in [0.1, 0.3, 0.6, 1.2, 2.0] {
                            after(t) { print("  reopen +\(t)s: y=\(panel.panelFrame.minY) h=\(panel.panelFrame.height) gap=\(anchor().minY - panel.panelFrame.maxY)") }
                        }
                        after(2.2) {
                            describe("after clicking icon again")
                            click(at: NSPoint(x: 300, y: 450))
                            after(1) {
                                describe("after clicking elsewhere")
                                exit(0)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func capture<V: View>(_ view: V, monitor: SystemMonitor, prefs: Preferences, networkDiagnostics: ClaudeNetworkMonitor, dark: Bool, to path: String) {
        let root = view
            .environmentObject(monitor)
            .environmentObject(monitor.menuBar)
            .environmentObject(networkDiagnostics)
            .environmentObject(prefs)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * scale),
                                         pixelsHigh: Int(host.bounds.height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// 模拟桌面 + 面板外观（圆角、高光边、近似毛玻璃的底色）
private struct PanelPreview: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        PanelView()
            .background(dark ? Color(red: 0.16, green: 0.16, blue: 0.19) : Color(red: 0.93, green: 0.93, blue: 0.95))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
            .overlay { PanelEdge() }
            .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            .padding(28)
            .background(LinearGradient(colors: dark ? [Color(red: 0.1, green: 0.12, blue: 0.25), Color(red: 0.25, green: 0.1, blue: 0.2)]
                                                    : [Color(red: 0.62, green: 0.75, blue: 0.95), Color(red: 0.95, green: 0.75, blue: 0.8)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

/// 模拟菜单栏背景下的标签效果
private struct MenuBarStrip: View {
    let values: MenuBarModel.Values
    let prefs: Preferences
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(nsImage: MenuBarIcon.render(values: values, prefs: prefs, darkMenuBar: scheme == .dark))
            .foregroundStyle(scheme == .dark ? .white : .black)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.95))
    }
}

/// 只打开"电池"一项，渲染几种典型状态
@MainActor
private func batteryIcons(prefs: Preferences, dark: Bool) -> [NSImage] {
    let saved = (prefs.showCPU, prefs.showMemory, prefs.showNetwork, prefs.showTemperature, prefs.showGPU, prefs.showBattery)
    (prefs.showCPU, prefs.showMemory, prefs.showNetwork, prefs.showTemperature, prefs.showGPU, prefs.showBattery) = (false, false, false, false, false, true)
    defer { (prefs.showCPU, prefs.showMemory, prefs.showNetwork, prefs.showTemperature, prefs.showGPU, prefs.showBattery) = saved }
    let states: [(Int, Bool, Bool)] = [(78, false, false), (78, true, false), (12, false, false), (45, false, true), (100, false, false)]
    return states.map { percent, charging, lowPower in
        var values = MenuBarModel.Values()
        values.battery = percent
        values.charging = charging
        values.lowPower = lowPower
        return MenuBarIcon.render(values: values, prefs: prefs, darkMenuBar: dark)
    }
}

private struct IconRow: View {
    let images: [NSImage]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 18) {
            ForEach(images.indices, id: \.self) { i in
                Image(nsImage: images[i]).foregroundStyle(scheme == .dark ? .white : .black)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.95))
    }
}

/// Reserved documentation IPs, clearly marked as demo in the UI. No network requests in this mode.
@MainActor
enum NetworkSnapshotFixture {
    static func dns(_ mode: String) -> DNSLeakResult {
        var addresses = [
            DNSObservedAddress(ip: "203.0.113.1", countryCode: "US", country: "United States", isp: "Example Resolver"),
            DNSObservedAddress(ip: "203.0.113.2", countryCode: "SG", country: "Singapore", isp: "Example Resolver")
        ]
        if mode == "cn-dns" { addresses.append(DNSObservedAddress(ip: "198.51.100.3", countryCode: "CN", country: "China", isp: "演示解析器")) }
        if mode == "dns-unknown" { addresses.append(DNSObservedAddress(ip: "198.51.100.4")) }
        return DNSLeakResult(checkedAt: Date(), addresses: addresses)
    }

    static func make(_ mode: String) -> ClaudeNetworkResult? {
        guard ["residential", "ipv6", "blocked", "partial", "unknown", "zero", "cn-dns", "dns-unknown"].contains(mode) else { return nil }
        let ip = mode == "ipv6" ? "2001:db8:1234:5678:abcd:ef01:2345:6789" : "203.0.113.42"
        let trace = mode == "blocked" ? nil : ClaudeExit(ip: ip, countryCode: "US")
        let probes = [
            ClaudeProbe(host: "claude.ai", status: mode == "blocked" ? .restricted : .reachable,
                        httpStatus: mode == "blocked" ? 403 : 200, milliseconds: 182, exit: trace),
            ClaudeProbe(host: "api.anthropic.com", status: .reachable, httpStatus: 200, milliseconds: 156,
                        exit: mode == "ipv6" ? ClaudeExit(ip: "203.0.113.24", countryCode: "US") : trace),
            ClaudeProbe(host: "www.anthropic.com", status: .timedOut),
        ]
        let data = Data("""
        {"ip":"\(ip)", "trust_score":\(mode == "unknown" ? "null" : mode == "zero" ? "0" : "96"),
         "isResidential":\(mode == "unknown" ? "null" : "true"), "is_datacenter":false,
         "is_vpn":false,"is_proxy":false,"is_tor":false,"is_abuser":false,
         "asn":7922,"asOrganization":"Example Residential Internet Communications Company",
         "country":"United States","countryCode":"US","city":"Los Angeles"}
        """.utf8)
        let risk = ["blocked", "partial"].contains(mode) ? nil : try? JSONDecoder().decode(ClaudeIPRisk.self, from: data)
        return ClaudeNetworkResult(checkedAt: Date(), probes: probes, risk: risk,
                                   riskError: mode == "partial" ? "数据源请求受限，稍后重试" : nil,
                                   riskFetchedAt: risk == nil ? nil : Date())
    }
}
