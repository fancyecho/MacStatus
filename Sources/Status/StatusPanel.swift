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

/// 贴在菜单栏图标下方的毛玻璃面板，取代 MenuBarExtra 以便控制位置、材质和圆角
@MainActor
final class StatusPanel: NSPanel {
    var onVisibilityChange: ((Bool) -> Void)?
    /// 按 Esc 时先交给内容处理（例如从设置页返回），返回 false 才收起面板
    var onEscape: (() -> Bool)?

    private var contentHeight: CGFloat = 0
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private(set) var isShown = false
    /// 菜单栏图标在屏幕上的位置，用来区分"点图标"和"点其他地方"
    private var anchorRect: NSRect = .zero
    /// 面板顶边应在的位置。不能用 frame.maxY 推算：打开动画进行中时 frame 还在起始位置
    private var topEdge: CGFloat?
    private var lastClosed: TimeInterval = 0

    init<Content: View>(rootView: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none

        let hosting = NSHostingView(rootView: rootView
            .background { SizeReader { [weak self] size in self?.contentSizeChanged(size) } }
            .overlay { if !Self.usesSystemGlass { PanelEdge() } })
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(hosting)
        // 只固定顶部：内容变矮时窗口从下往上收，顶部始终贴着菜单栏
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        contentView = Self.makeBackdrop(around: container)
    }

    override var canBecomeKey: Bool { true }

    /// macOS 26 起面板用系统的 Liquid Glass，边缘高光由系统绘制，不再叠加 PanelEdge
    static var usesSystemGlass: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }

    /// macOS 26 起用 NSGlassEffectView；更早的系统用毛玻璃 + 连续曲率圆角遮罩
    private static func makeBackdrop(around content: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = PanelGlassView()
            glass.cornerRadius = Metrics.panelRadius
            glass.contentView = content
            // 玻璃本身不裁剪窗口形状，系统会按整个矩形算窗口阴影，圆角外露出一块深色直角。
            // 套一层圆角裁剪后，阴影也跟着变成圆角
            let clip = NSView()
            clip.wantsLayer = true
            clip.layer?.cornerRadius = Metrics.panelRadius
            clip.layer?.cornerCurve = .continuous
            clip.layer?.masksToBounds = true
            glass.frame = clip.bounds
            glass.autoresizingMask = [.width, .height]
            clip.addSubview(glass)
            return clip
        }
        let effectView = NSVisualEffectView()
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.maskImage = roundedMask(radius: Metrics.panelRadius)
        content.frame = effectView.bounds
        content.autoresizingMask = [.width, .height]
        effectView.addSubview(content)
        return effectView
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
        guard let buttonWindow = button.window, let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = NSSize(width: frame.width, height: max(contentHeight, 100))
        let visible = screen.visibleFrame
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 6), visible.maxX - size.width - 6)
        let top = anchor.minY - Metrics.menuBarGap
        let target = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        anchorRect = anchor
        topEdge = top

        // 从菜单栏方向轻轻落下并淡入
        isShown = true
        alphaValue = 0
        setFrame(target.offsetBy(dx: 0, dy: 6), display: true)
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            animator().alphaValue = 1
            animator().setFrame(target, display: true)
        }
        installMonitors()
        onVisibilityChange?(true)
    }

    override func close() {
        guard isShown else { return }
        isShown = false
        lastClosed = ProcessInfo.processInfo.systemUptime
        removeMonitors()
        onVisibilityChange?(false)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShown else { return }
                self.orderOut(nil)
            }
        })
    }

    /// SwiftUI 内容高度变化（例如切换到设置页）时调整窗口，保持顶边不动。
    /// 这个回调发生在布局过程中，直接改窗口尺寸会触发约束更新死循环，所以：
    /// 隐藏时只记录高度（下次打开时使用），显示时推迟到本轮布局结束后再改。
    private func contentSizeChanged(_ size: CGSize) {
        guard size.height > 0, abs(size.height - contentHeight) > 0.5 else { return }
        contentHeight = size.height
        guard isShown else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.applyContentHeight() }
        }
    }

    private func applyContentHeight() {
        guard isShown, abs(frame.height - contentHeight) > 0.5 else { return }
        let top = topEdge ?? frame.maxY
        let newFrame = NSRect(x: frame.minX, y: top - contentHeight, width: frame.width, height: contentHeight)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(newFrame, display: true)
        }
        invalidateShadow()
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
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self else { return event }
            if self.onEscape?() != true { self.close() }
            return nil
        }
    }

    private func removeMonitors() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
    }

    /// 连续曲率圆角（和系统窗口一样的"超椭圆"），用九宫格拉伸
    private static func roundedMask(radius: CGFloat) -> NSImage {
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

/// 浅色模式下常规玻璃在浅色背景上偏白，往深色轻轻着色，更接近背景、卡片边界也更清楚。
/// （clear 玻璃在浅色模式下反而更亮，不适合这里）
@available(macOS 26.0, *)
private final class PanelGlassView: NSGlassEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        tintColor = dark ? nil : NSColor(white: 0, alpha: 0.06)
    }
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
