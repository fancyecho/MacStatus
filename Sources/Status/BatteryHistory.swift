import Foundation

/// 最近 24 小时的电量记录：每 5 分钟（或充电状态变化时）记一个点，存在 Application Support 里，
/// 重启应用后曲线还在
@MainActor
final class BatteryHistory {
    struct Point: Codable, Equatable {
        var time: Date
        var percent: Int
        var charging: Bool
    }

    static let window: TimeInterval = 24 * 3600
    static let spacing: TimeInterval = 5 * 60
    /// 相邻两点间隔超过这个时长（例如睡眠）就断开曲线
    static let gap: TimeInterval = 20 * 60

    private(set) var points: [Point] = []
    private let url: URL?

    init(url: URL? = BatteryHistory.defaultURL) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([Point].self, from: data) {
            points = saved.filter { Date().timeIntervalSince($0.time) <= Self.window }
        }
    }

    /// STATUS_DEMO 用的模拟记录：白天放电、中午充一次电、夜里睡眠断开一段；不读写文件
    static func demo(now: Date = Date()) -> BatteryHistory {
        let history = BatteryHistory(url: nil)
        var percent = 92.0
        for step in stride(from: 288, through: 0, by: -1) {
            let time = now.addingTimeInterval(-Double(step) * spacing)
            let hour = Double(288 - step) / 12
            if (6.5...9).contains(hour) { continue }   // 睡眠
            let charging = (13.0...14.5).contains(hour)
            percent = charging ? min(percent + 3.2, 100) : max(percent - 0.55, 8)
            history.points.append(Point(time: time, percent: Int(percent), charging: charging))
        }
        return history
    }

    nonisolated private static var defaultURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("Status", isDirectory: true).appendingPathComponent("battery-history.json")
    }

    func record(percent: Int, charging: Bool, at now: Date = Date()) {
        if let last = points.last, now.timeIntervalSince(last.time) < Self.spacing,
           last.charging == charging, abs(last.percent - percent) < 3 {
            return
        }
        points.append(Point(time: now, percent: percent, charging: charging))
        points.removeAll { now.timeIntervalSince($0.time) > Self.window }
        save()
    }

    private func save() {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(points) { try? data.write(to: url, options: .atomic) }
    }
}
