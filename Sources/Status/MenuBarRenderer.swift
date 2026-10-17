import AppKit

/// 直接用 Core Graphics 画菜单栏图标。
/// 以前用 SwiftUI 的 ImageRenderer，每次网速变化都要跑一遍完整的 SwiftUI 渲染流程（还会唤醒后台渲染线程），
/// 是本应用耗电的主要来源；改成直接绘制后开销降到很低，外观保持一致。
@MainActor
enum MenuBarRenderer {
    static let height: CGFloat = 22
    private static let spacing: CGFloat = 9

    /// - Parameters:
    ///   - ink: 文字和图形颜色（模板图片时用黑色，由系统着色）
    ///   - batteryFill: 电池填充色（低电量模式下为黄色）
    static func render(values: MenuBarModel.Values, prefs: Preferences, ink: NSColor, batteryFill: NSColor) -> NSImage {
        var items: [Item] = []
        if prefs.showCPU { items.append(stacked("CPU", values.cpu, suffix: "%", ink: ink)) }
        if prefs.showTemperature, let temperature = values.temperature {
            items.append(stacked("TEMP", temperature, suffix: "°", ink: ink))
        }
        if prefs.showMemory { items.append(stacked("MEM", values.memory, suffix: "%", ink: ink)) }
        if prefs.showGPU, let gpu = values.gpu { items.append(stacked("GPU", gpu, suffix: "%", ink: ink)) }
        if prefs.showNetwork { items.append(network(up: values.up, down: values.down, ink: ink)) }
        if prefs.showBattery, let battery = values.battery {
            items.append(self.battery(battery, charging: values.charging, ink: ink, fill: batteryFill))
        }
        if items.isEmpty { items.append(symbolItem("gauge.with.dots.needle.33percent", size: 14, weight: .medium, ink: ink)) }

        let width = ceil(items.map(\.width).reduce(0, +) + spacing * CGFloat(items.count - 1))
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return NSImage() }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        var x: CGFloat = 0
        for item in items {
            item.draw(x)
            x += item.width + spacing
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Items

    private struct Item {
        let width: CGFloat
        let draw: (_ x: CGFloat) -> Void
    }

    /// 两行：小标签 + 数值，左边一根竖向占用条（坐标原点在左下角）
    private static func stacked(_ title: String, _ value: Int, suffix: String, ink: NSColor) -> Item {
        let meterWidth: CGFloat = 3.5, meterHeight: CGFloat = 16, gap: CGFloat = 3, textWidth: CGFloat = 26
        let titleText = text(title, size: 7, weight: .bold, color: ink.withAlphaComponent(0.6))
        let valueText = text("\(value)\(suffix)", size: 10.5, weight: .semibold, color: ink, monospaced: true)
        return Item(width: meterWidth + gap + textWidth) { x in
            let meterY = (height - meterHeight) / 2
            let track = NSBezierPath(roundedRect: NSRect(x: x, y: meterY, width: meterWidth, height: meterHeight),
                                     xRadius: meterWidth / 2, yRadius: meterWidth / 2)
            ink.withAlphaComponent(0.22).setFill()
            track.fill()
            let level = max(2, meterHeight * CGFloat(min(max(value, 0), 100)) / 100)
            let fill = NSBezierPath(roundedRect: NSRect(x: x, y: meterY, width: meterWidth, height: level),
                                    xRadius: meterWidth / 2, yRadius: meterWidth / 2)
            ink.setFill()
            fill.fill()

            let textX = x + meterWidth + gap
            valueText.draw(at: NSPoint(x: textX, y: 1))
            titleText.draw(at: NSPoint(x: textX, y: 12.5))
        }
    }

    /// 两行网速，右对齐：上行是上传，下行是下载
    private static func network(up: String, down: String, ink: NSColor) -> Item {
        let width: CGFloat = 44
        let upText = text(up, size: 9.5, weight: .semibold, color: ink, monospaced: true)
        let downText = text(down, size: 9.5, weight: .semibold, color: ink, monospaced: true)
        let upArrow = symbol("arrow.up", size: 6.5, weight: .black, color: ink.withAlphaComponent(0.6))
        let downArrow = symbol("arrow.down", size: 6.5, weight: .black, color: ink.withAlphaComponent(0.6))
        return Item(width: width) { x in
            func line(_ label: NSAttributedString, _ arrow: NSImage?, y: CGFloat) {
                let arrowWidth = arrow?.size.width ?? 0
                let right = x + width
                arrow?.draw(in: NSRect(x: right - arrowWidth, y: y + 2.5, width: arrowWidth, height: arrow?.size.height ?? 0))
                label.draw(at: NSPoint(x: right - arrowWidth - 2 - label.size().width, y: y))
            }
            line(upText, upArrow, y: 10.5)
            line(downText, downArrow, y: 0.5)
        }
    }

    /// 电池：数字在电池里面。填充部分上的数字镂空，空白部分上的数字实心；充电时右侧带闪电
    private static func battery(_ percent: Int, charging: Bool, ink: NSColor, fill: NSColor) -> Item {
        let bodyWidth: CGFloat = 25, bodyHeight: CGFloat = 12, radius: CGFloat = 3.8
        let capWidth: CGFloat = 1.6, capHeight: CGFloat = 4.5, capGap: CGFloat = 1.5
        let bolt = charging ? symbol("bolt.fill", size: 9, weight: .bold, color: ink) : nil
        let boltWidth = bolt.map { $0.size.width + 1 + capGap } ?? 0
        let number = text("\(percent)", size: percent >= 100 ? 8 : 9, weight: .bold, color: ink, monospaced: true, rounded: true)

        return Item(width: bodyWidth + capGap + capWidth + boltWidth) { x in
            guard let cg = NSGraphicsContext.current?.cgContext else { return }
            let body = NSRect(x: x, y: (height - bodyHeight) / 2, width: bodyWidth, height: bodyHeight)
            let filled = max(2.5, bodyWidth * CGFloat(min(max(percent, 0), 100)) / 100)
            let fillRect = NSRect(x: body.minX, y: body.minY, width: filled, height: bodyHeight)
            let emptyRect = NSRect(x: body.minX + filled, y: body.minY, width: bodyWidth - filled, height: bodyHeight)
            let numberSize = number.size()
            let numberOrigin = NSPoint(x: body.midX - numberSize.width / 2, y: body.midY - numberSize.height / 2)

            // 在透明图层里画，镂空只影响电池本身
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius).addClip()
            ink.withAlphaComponent(0.32).setFill()
            body.fill()
            fill.setFill()
            fillRect.fill()
            // 空白部分：实心数字
            NSGraphicsContext.saveGraphicsState()
            emptyRect.clip()
            number.draw(at: numberOrigin)
            NSGraphicsContext.restoreGraphicsState()
            // 填充部分：镂空数字
            NSGraphicsContext.saveGraphicsState()
            fillRect.clip()
            cg.setBlendMode(.destinationOut)
            number.draw(at: numberOrigin)
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.restoreGraphicsState()
            cg.endTransparencyLayer()

            let cap = NSRect(x: body.maxX + capGap, y: body.midY - capHeight / 2, width: capWidth, height: capHeight)
            ink.withAlphaComponent(0.4).setFill()
            NSBezierPath(roundedRect: cap, xRadius: 0.8, yRadius: 0.8).fill()

            if let bolt {
                let boltX = cap.maxX + capGap + 1
                bolt.draw(in: NSRect(x: boltX, y: body.midY - bolt.size.height / 2, width: bolt.size.width, height: bolt.size.height))
            }
        }
    }

    private static func symbolItem(_ name: String, size: CGFloat, weight: NSFont.Weight, ink: NSColor) -> Item {
        let image = symbol(name, size: size, weight: weight, color: ink)
        let imageSize = image?.size ?? NSSize(width: size, height: size)
        return Item(width: imageSize.width) { x in
            image?.draw(in: NSRect(x: x, y: (height - imageSize.height) / 2, width: imageSize.width, height: imageSize.height))
        }
    }

    // MARK: - Helpers

    private static func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor,
                             monospaced: Bool = false, rounded: Bool = false) -> NSAttributedString {
        var font = monospaced ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                              : NSFont.systemFont(ofSize: size, weight: weight)
        if rounded, let descriptor = font.fontDescriptor.withDesign(.rounded) {
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    }

    private static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }
}
