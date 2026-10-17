import AppKit
import SwiftUI

/// 调试用：
/// - STATUS_SNAPSHOT=<目录>：把面板渲染成 PNG 后退出（离屏渲染没有真实模糊，用纯色近似）
/// - STATUS_CHECK_PANEL=1：真实打开面板，打印它和菜单栏图标的位置后退出
@MainActor
enum Snapshot {
    static func scheduleIfRequested(monitor: SystemMonitor, prefs: Preferences, panel: StatusPanel, statusItem: NSStatusItem) {
        let env = ProcessInfo.processInfo.environment
        if env["STATUS_CHECK_PANEL"] != nil {
            checkPanelPlacement(panel: panel, statusItem: statusItem, prefs: prefs)
            return
        }
        guard let dir = env["STATUS_SNAPSHOT"] else { return }
        let delay = Double(env["STATUS_SNAPSHOT_DELAY"] ?? "") ?? 7
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            for dark in [false, true] {
                prefs.page = .overview
                capture(PanelPreview(), monitor: monitor, prefs: prefs, dark: dark, to: "\(dir)/panel-\(dark ? "dark" : "light").png")
            }
            prefs.page = .settings
            capture(PanelPreview(), monitor: monitor, prefs: prefs, dark: false, to: "\(dir)/settings.png")
            if monitor.battery != nil {
                prefs.page = .battery
                for dark in [false, true] {
                    capture(PanelPreview(), monitor: monitor, prefs: prefs, dark: dark, to: "\(dir)/battery-\(dark ? "dark" : "light").png")
                }
            }
            prefs.page = .overview
            for dark in [false, true] {
                capture(MenuBarStrip(values: monitor.menuBar.values, prefs: prefs), monitor: monitor, prefs: prefs, dark: dark,
                        to: "\(dir)/menubar-\(dark ? "dark" : "light").png")
            }
            // 电池图标的几种状态：普通 / 充电 / 低电量 / 低电量模式 / 充满
            for dark in [false, true] {
                let icons = batteryIcons(prefs: prefs, dark: dark)
                capture(IconRow(images: icons), monitor: monitor, prefs: prefs, dark: dark,
                        to: "\(dir)/battery-icons-\(dark ? "dark" : "light").png")
            }
            exit(0)
        }
    }

    private static func checkPanelPlacement(panel: StatusPanel, statusItem: NSStatusItem, prefs: Preferences) {
        func anchor() -> NSRect {
            guard let button = statusItem.button, let window = button.window else { return .zero }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        func describe(_ label: String) {
            print("\(label): icon=\(anchor()) panel=\(panel.frame) gapToIcon=\(anchor().minY - panel.frame.maxY) shown=\(panel.isShown)")
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
                after(Double(i) * 1.1) { heights.append(panel.frame.height) }
            }
            after(7.5) {
                describe("overview")
                print("heights over 6 ticks: \(heights)")
                prefs.page = .battery
            }
            var batteryHeights: [CGFloat] = []
            for i in 1...5 {
                after(7.5 + Double(i) * 1.1) { batteryHeights.append(panel.frame.height) }
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
                        after(1) {
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

    private static func capture<V: View>(_ view: V, monitor: SystemMonitor, prefs: Preferences, dark: Bool, to path: String) {
        let root = view
            .environmentObject(monitor)
            .environmentObject(monitor.menuBar)
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
            .overlay(PanelEdge())
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
