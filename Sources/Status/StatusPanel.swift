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

    private let effectView = NSVisualEffectView()
    private var contentHeight: CGFloat = 0
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private(set) var isShown = false

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

        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.maskImage = Self.roundedMask(radius: Metrics.panelRadius)

        let hosting = NSHostingView(rootView: rootView
            .background(SizeReader { [weak self] size in self?.contentSizeChanged(size) })
            .overlay(PanelEdge()))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(hosting)
        // 只固定顶部：内容变矮时窗口从下往上收，顶部始终贴着菜单栏
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: effectView.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
        ])
        contentView = effectView
    }

    override var canBecomeKey: Bool { true }

    func toggle(below button: NSStatusBarButton) {
        isShown ? close() : show(below: button)
    }

    func show(below button: NSStatusBarButton) {
        guard let buttonWindow = button.window, let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = NSSize(width: frame.width, height: max(contentHeight, 100))
        let visible = screen.visibleFrame
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 6), visible.maxX - size.width - 6)
        let top = anchor.minY - Metrics.menuBarGap
        setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)

        isShown = true
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        installMonitors()
        onVisibilityChange?(true)
    }

    override func close() {
        guard isShown else { return }
        isShown = false
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

    /// SwiftUI 内容高度变化（例如切换到设置页）时调整窗口，保持顶边不动
    private func contentSizeChanged(_ size: CGSize) {
        guard size.height > 0, abs(size.height - contentHeight) > 0.5 else { return }
        contentHeight = size.height
        var newFrame = frame
        newFrame.origin.y = frame.maxY - size.height
        newFrame.size = NSSize(width: size.width, height: size.height)
        if isShown {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().setFrame(newFrame, display: true)
            }
        } else {
            setFrame(newFrame, display: false)
        }
        invalidateShadow()
    }

    private func installMonitors() {
        // 点击其他地方或按 Esc 时收起，和系统菜单一致
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.close()
                return nil
            }
            return event
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
