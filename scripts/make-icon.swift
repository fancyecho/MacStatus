// 生成应用图标：swift scripts/make-icon.swift <输出目录> [variant]
// 输出 <目录>/icon_1024.png，build 时再由 iconutil 转成 AppIcon.icns
import AppKit
import SwiftUI

/// macOS 图标网格：1024 画布，中间 824 的连续圆角方块
private let canvas: CGFloat = 1024
private let tile: CGFloat = 824
private let radius: CGFloat = 185

/// 归一化的折线数据（0 在底部，1 在顶部）
private let samples: [CGFloat] = [0.18, 0.40, 0.30, 0.62, 0.52, 0.86]

private func linePoints(in rect: CGRect) -> [CGPoint] {
    let step = rect.width / CGFloat(samples.count - 1)
    return samples.enumerated().map { i, v in
        CGPoint(x: rect.minX + CGFloat(i) * step, y: rect.maxY - v * rect.height)
    }
}

private func smooth(_ points: [CGPoint]) -> Path {
    var path = Path()
    path.move(to: points[0])
    for i in 1..<points.count {
        let p0 = points[max(i - 2, 0)], p1 = points[i - 1], p2 = points[i], p3 = points[min(i + 1, points.count - 1)]
        // Catmull-Rom 转三次贝塞尔，曲线经过每个点
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        path.addCurve(to: p2, control1: c1, control2: c2)
    }
    return path
}

private func filledArea(_ line: Path, points: [CGPoint], bottom: CGFloat) -> Path {
    var area = line
    area.addLine(to: CGPoint(x: points[points.count - 1].x, y: bottom))
    area.addLine(to: CGPoint(x: points[0].x, y: bottom))
    area.closeSubpath()
    return area
}

struct Icon: View {
    let variant: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let chart = CGRect(x: 150, y: 250, width: tile - 300, height: 330)
        let points = linePoints(in: chart)
        let line = smooth(points)
        let area = filledArea(line, points: points, bottom: chart.maxY + 120)
        let accent = LinearGradient(colors: [Color(red: 0.30, green: 0.85, blue: 1.0),
                                             Color(red: 0.42, green: 0.55, blue: 1.0),
                                             Color(red: 0.72, green: 0.48, blue: 1.0)],
                                    startPoint: .leading, endPoint: .trailing)
        let dark = variant == "dark"

        ZStack {
            // 底板
            shape.fill(dark
                ? LinearGradient(colors: [Color(red: 0.13, green: 0.15, blue: 0.24), Color(red: 0.05, green: 0.06, blue: 0.11)], startPoint: .top, endPoint: .bottom)
                : LinearGradient(colors: [Color(red: 0.40, green: 0.62, blue: 1.0), Color(red: 0.55, green: 0.38, blue: 0.95)], startPoint: .topLeading, endPoint: .bottomTrailing))

            ZStack {
                // 淡淡的网格线
                ForEach(0..<3) { i in
                    Rectangle()
                        .fill(Color.white.opacity(dark ? 0.06 : 0.12))
                        .frame(width: chart.width + 60, height: 4)
                        .position(x: tile / 2, y: chart.minY + CGFloat(i) * chart.height / 2 + 40)
                }
                // 曲线下方的面积
                // 渐变范围对齐到图表区域，确保在底边之前完全淡出
                area.fill(LinearGradient(colors: [(dark ? Color(red: 0.42, green: 0.55, blue: 1.0) : .white).opacity(dark ? 0.32 : 0.3), .clear],
                                         startPoint: UnitPoint(x: 0.5, y: chart.minY / tile),
                                         endPoint: UnitPoint(x: 0.5, y: (chart.maxY + 100) / tile)))
                // 光晕 + 曲线
                if dark {
                    line.stroke(accent, style: StrokeStyle(lineWidth: 34, lineCap: .round, lineJoin: .round)).blur(radius: 26).opacity(0.7)
                    line.stroke(accent, style: StrokeStyle(lineWidth: 30, lineCap: .round, lineJoin: .round))
                } else {
                    line.stroke(Color.black.opacity(0.18), style: StrokeStyle(lineWidth: 30, lineCap: .round, lineJoin: .round)).blur(radius: 14).offset(y: 10)
                    line.stroke(Color.white, style: StrokeStyle(lineWidth: 30, lineCap: .round, lineJoin: .round))
                }
                // 末端圆点
                let end = points[points.count - 1]
                Circle()
                    .fill(dark ? Color(red: 0.72, green: 0.48, blue: 1.0) : .white)
                    .frame(width: 70, height: 70)
                    .overlay(Circle().fill(dark ? Color.white : Color(red: 0.55, green: 0.38, blue: 0.95)).frame(width: 30, height: 30))
                    .shadow(color: dark ? Color(red: 0.72, green: 0.48, blue: 1.0).opacity(0.9) : .black.opacity(0.2), radius: dark ? 30 : 12)
                    .position(end)
            }
            .frame(width: tile, height: tile)

            // 玻璃质感：顶部高光 + 细边
            shape.fill(LinearGradient(colors: [.white.opacity(dark ? 0.10 : 0.22), .clear], startPoint: .top, endPoint: .center))
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.28 : 0.5), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 5)
        }
        .frame(width: tile, height: tile)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.28), radius: 18, y: 12)
        .frame(width: canvas, height: canvas)
    }
}

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "."
let variant = args.count > 2 ? args[2] : "dark"
MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Icon(variant: variant))
    renderer.scale = 1
    guard let cg = renderer.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cg)
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("icon_1024.png")
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path)")
}
