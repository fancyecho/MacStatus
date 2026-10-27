import AppKit
import SwiftUI

enum Metrics {
    static let panelRadius: CGFloat = 24
    static let panelPadding: CGFloat = 10
    /// 卡片圆角 = 面板圆角 − 内边距，和面板保持同心
    static let cardRadius: CGFloat = panelRadius - panelPadding
    /// 面板与菜单栏之间的距离
    static let menuBarGap: CGFloat = 4
}

/// 面板里用到的动画，集中在一处调节
enum Motion {
    /// STATUS_SLOW_MOTION=<倍数>：把面板动画放慢若干倍，便于截图逐帧检查
    private static let slowdown = max(Double(ProcessInfo.processInfo.environment["STATUS_SLOW_MOTION"] ?? "") ?? 1, 1)

    /// 打开：从菜单栏向下"展开"，快速起步、轻微回弹
    static let open = Animation.spring(response: 0.3, dampingFraction: 0.82).speed(1 / slowdown)
    /// 打开时的淡入要比形变快，第一帧就能看清内容
    static let openFade = Animation.easeOut(duration: 0.1).speed(1 / slowdown)
    static let close = Animation.easeIn(duration: 0.16).speed(1 / slowdown)
    /// 切换页面、面板高度变化
    static let page = Animation.spring(response: 0.4, dampingFraction: 0.86).speed(1 / slowdown)
    static let pageExit = Animation.easeOut(duration: 0.14).speed(1 / slowdown)
    /// 打开时卡片依次落位，每张卡片比上一张晚一点
    static func entrance(order: Int) -> Animation {
        // speed 会连 delay 一起放慢，这里不用再乘 slowdown
        .spring(response: 0.34, dampingFraction: 0.8).delay(0.018 * Double(order)).speed(1 / slowdown)
    }
    /// 关闭动画结束后才把窗口收起
    static var closeDuration: Double { 0.16 * slowdown }
}

/// 面板是否处于打开状态。由窗口切换，SwiftUI 负责所有动画
@MainActor
final class PanelPresentation: ObservableObject {
    @Published var isPresented = false
}

/// 贴在菜单栏图标下方的玻璃面板，取代 MenuBarExtra 以便控制位置、材质和圆角。
/// 窗口本身固定为一块透明的大区域，面板的玻璃、阴影、展开和高度变化都由 SwiftUI 在窗口里绘制，
/// 这样内容和玻璃背景始终在同一个动画里同步变化，不会出现窗口尺寸动画和内容动画对不上的卡顿
@MainActor
final class StatusPanel: NSPanel {
    static let panelWidth: CGFloat = 340
    /// 面板四周留给阴影的透明边距
    static let shadowMargin: CGFloat = 30

    var onVisibilityChange: ((Bool) -> Void)?
    /// 窗口显示前调用，用来让内容用最新数据重绘一次
    var onWillShow: (() -> Void)?
    /// 按 Esc 时先交给内容处理（例如从设置页返回），返回 false 才收起面板
    var onEscape: (() -> Bool)?

    private let presentation = PanelPresentation()
    private var panelSize: CGSize = .zero
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var localClickMonitor: Any?
    private(set) var isShown = false
    /// 菜单栏图标在屏幕上的位置，用来区分"点图标"和"点其他地方"
    private var anchorRect: NSRect = .zero
    private var lastClosed: TimeInterval = 0
    /// 每次打开加一，用来忽略过期的"关闭完成"回调
    private var generation = 0

    /// 面板（玻璃部分）在屏幕上的位置
    var panelFrame: NSRect {
        NSRect(x: frame.minX + Self.shadowMargin, y: frame.maxY - panelSize.height,
               width: Self.panelWidth, height: panelSize.height)
    }

    init<Content: View>(rootView: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth + Self.shadowMargin * 2, height: 600),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        // 阴影由 SwiftUI 跟着面板形状绘制；窗口阴影只会按整个透明窗口算
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none

        let hosting = NSHostingView(rootView: PanelChrome(presentation: presentation,
                                                          onSize: { [weak self] in self?.panelSize = $0 }) { rootView })
        // 窗口大小由我们决定，不让 SwiftUI 内容去撑窗口
        hosting.sizingOptions = []
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }

    /// macOS 26 起面板用系统的 Liquid Glass，边缘高光由系统绘制，不再叠加 PanelEdge
    static var usesSystemGlass: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }

    func toggle(below button: NSStatusBarButton) {
        if isShown {
            close()
        } else if ProcessInfo.processInfo.systemUptime - lastClosed > 0.3 {
            // 刚被同一次点击收起时不要立刻又打开
            show(below: button)
        }
    }

    func show(below button: NSStatusBarButton) {
        guard !isShown, let buttonWindow = button.window, let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        let panelX = min(max(anchor.midX - Self.panelWidth / 2, visible.minX + 6), visible.maxX - Self.panelWidth - 6)
        let top = anchor.minY - Metrics.menuBarGap
        // 窗口从面板顶边一直延伸到屏幕底部：页面变高时不用改窗口，透明部分不接收点击
        setFrame(NSRect(x: panelX - Self.shadowMargin, y: visible.minY,
                        width: Self.panelWidth + Self.shadowMargin * 2, height: top - visible.minY),
                 display: false)
        anchorRect = anchor

        isShown = true
        generation += 1
        onWillShow?()
        makeKeyAndOrderFront(nil)
        // 和窗口显示在同一轮开始展开，不再等下一轮
        withAnimation(Motion.open) { presentation.isPresented = true }
        installMonitors()
        onVisibilityChange?(true)
    }

    override func close() {
        guard isShown else { return }
        isShown = false
        lastClosed = ProcessInfo.processInfo.systemUptime
        removeMonitors()
        onVisibilityChange?(false)
        withAnimation(Motion.close) { presentation.isPresented = false }
        let closing = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.closeDuration) { [weak self] in
            MainActor.assumeIsolated {
                // 关闭动画期间又被打开了就不要收起
                guard let self, !self.isShown, self.generation == closing else { return }
                self.orderOut(nil)
            }
        }
    }

    private func installMonitors() {
        // 点击其他地方或按 Esc 时收起，和系统菜单一致
        // 点在菜单栏图标上的交给图标自己处理（切换开关），否则会先收起再被重新打开
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                guard let self, !self.anchorRect.insetBy(dx: -2, dy: -2).contains(location) else { return }
                self.close()
            }
        }
        // 点在窗口里但在面板外面（阴影边距等透明区域）也收起
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self else { return event }
            let location = NSEvent.mouseLocation
            if self.panelFrame.contains(location) { return event }
            self.close()
            return nil
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self else { return event }
            if self.onEscape?() != true { self.close() }
            return nil
        }
    }

    private func removeMonitors() {
        for monitor in [clickMonitor, localClickMonitor, keyMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        clickMonitor = nil
        localClickMonitor = nil
        keyMonitor = nil
    }

    /// 连续曲率圆角（和系统窗口一样的"超椭圆"），用九宫格拉伸
    static func roundedMask(radius: CGFloat) -> NSImage {
        let inset = ceil(radius * 1.6)
        let edge = inset * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - SwiftUI chrome

/// 面板外壳：展开 / 收起动画，内容贴着窗口顶部。玻璃和阴影由内容自己通过 PanelSurface 画，
/// 这样它们和页面高度处在同一个动画作用域里
private struct PanelChrome<Content: View>: View {
    @ObservedObject var presentation: PanelPresentation
    let onSize: (CGSize) -> Void
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = presentation.isPresented
        // 收起时略微压扁并贴向菜单栏，展开时像从菜单栏里垂下来；减弱动态效果时只淡入淡出
        let folded = !shown && !reduceMotion
        content
            .environment(\.panelPresented, shown)
            .environment(\.panelSurfaceEnabled, true)
            .background { SizeReader(onChange: onSize) }
            .scaleEffect(x: folded ? 0.97 : 1, y: folded ? 0.92 : 1, anchor: .top)
            .offset(y: folded ? -6 : 0)
            // 形变用弹簧，淡入单独用更快的曲线：外层的 animation 只管 opacity
            .animation(shown ? Motion.open : Motion.close, value: shown)
            .opacity(shown ? 1 : 0)
            .animation(shown ? Motion.openFade : Motion.close, value: shown)
            .padding([.horizontal, .bottom], StatusPanel.shadowMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// 面板的玻璃、边缘高光和阴影。放在面板内容的 background 里（静态截图时不画）
struct PanelSurface: View {
    @Environment(\.panelSurfaceEnabled) private var enabled
    @Environment(\.panelPresented) private var presented

    var body: some View {
        if enabled {
            ZStack {
                PanelShadow()
                // 玻璃跟着展开状态插入 / 移除，系统会用"凝结"的方式让它出现和消失，而不是简单淡入淡出
                if presented { PanelBackdrop() }
                if !StatusPanel.usesSystemGlass { PanelEdge() }
            }
        }
    }
}

/// 面板背景。macOS 26 起用 SwiftUI 的 Liquid Glass：它是 SwiftUI 自己绘制的，
/// 高度变化时和内容在同一个动画里伸缩（AppKit 视图的尺寸 SwiftUI 不会逐帧插值）。
/// 浅色模式下常规玻璃在浅色背景上偏白，往深色轻轻着色，更接近背景、卡片边界也更清楚
private struct PanelBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular.tint(scheme == .dark ? nil : .black.opacity(0.06)),
                             in: RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
        } else {
            LegacyBackdrop()
        }
    }
}

/// macOS 14–25：毛玻璃 + 连续曲率圆角遮罩
private struct LegacyBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let effectView = NSVisualEffectView()
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.maskImage = StatusPanel.roundedMask(radius: Metrics.panelRadius)
        return effectView
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 只画在面板外面的阴影：面板里面挖空，不会让半透明的玻璃变暗
private struct PanelShadow: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
        let dark = scheme == .dark
        shape.fill(.black)
            .shadow(color: .black.opacity(dark ? 0.42 : 0.16), radius: 18, y: 10)
            .shadow(color: .black.opacity(dark ? 0.3 : 0.08), radius: 1.5, y: 0.5)
            .mask {
                Rectangle()
                    .padding(-StatusPanel.shadowMargin)
                    .overlay { shape.blendMode(.destinationOut) }
                    .compositingGroup()
            }
            .allowsHitTesting(false)
    }
}

private struct PanelPresentedKey: EnvironmentKey {
    static let defaultValue = true
}

private struct PanelSurfaceEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 面板当前是否展开（静态截图等不在面板里的场合视为展开）
    var panelPresented: Bool {
        get { self[PanelPresentedKey.self] }
        set { self[PanelPresentedKey.self] = newValue }
    }

    /// 是否在真正的面板窗口里（需要自己画玻璃和阴影）
    var panelSurfaceEnabled: Bool {
        get { self[PanelSurfaceEnabledKey.self] }
        set { self[PanelSurfaceEnabledKey.self] = newValue }
    }
}

/// 打开面板时按顺序从上往下落位，收起时一起回去
private struct PanelEntrance: ViewModifier {
    let order: Int
    @Environment(\.panelPresented) private var presented
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(y: presented || reduceMotion ? 0 : -8)
            .opacity(presented ? 1 : 0)
            .animation(presented ? Motion.entrance(order: order) : Motion.close, value: presented)
    }
}

extension View {
    func panelEntrance(_ order: Int) -> some View { modifier(PanelEntrance(order: order)) }
}

/// 面板边缘一圈很淡的高光，模拟玻璃的边
struct PanelEdge: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.22 : 0.65),
                                        .white.opacity(scheme == .dark ? 0.06 : 0.2)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.8)
            .allowsHitTesting(false)
    }
}

private struct SizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct SizeReader: View {
    let onChange: (CGSize) -> Void

    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: SizeKey.self, value: geo.size)
        }
        .onPreferenceChange(SizeKey.self) { size in
            MainActor.assumeIsolated { onChange(size) }
        }
    }
}
