import Foundation

/// 最近 24 小时的电量记录。优先用系统自己的记录（SystemBatteryLog，睡眠和应用没运行时也有数据），
/// 再合并 Status 自己每 5 分钟（或充电状态变化时）记的点：系统缺数据的地方由它补上，读不到系统记录时就只用它。
/// 自己的记录存在 Application Support 里，重启应用后还在
@MainActor
final class BatteryHistory {
    struct Point: Codable, Equatable {
        var time: Date
        var percent: Int
        var charging: Bool
    }

    static let window: TimeInterval = 24 * 3600
    static let spacing: TimeInterval = 5 * 60
    /// 相邻两点间隔超过这个时长就当作"没有数据"（例如长时间深度睡眠），画成虚线连过去。
    /// 系统在睡眠中每 15–20 分钟会短暂唤醒记一次，所以这个值要比它大
    static let gap: TimeInterval = 45 * 60
    /// 系统记录多久重新读一次
    static let systemRefresh: TimeInterval = 5 * 60

    /// 曲线用的点：系统记录 + 自己的记录，按时间排序
    private(set) var points: [Point] = []
    /// Status 自己采的点（会存盘）
    private var ownPoints: [Point] = []
    private var systemPoints: [Point]?
    private var systemLoadedAt: Date?
    private let url: URL?
    private let usesSystemLog: Bool

    init(url: URL? = BatteryHistory.defaultURL, usesSystemLog: Bool = true) {
        self.url = url
        self.usesSystemLog = usesSystemLog
        if let url, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([Point].self, from: data) {
            ownPoints = saved.filter { Date().timeIntervalSince($0.time) <= Self.window }
        }
        refreshSystemLog(force: true)
    }

    /// 系统记录为主；自己的点只在系统附近 8 分钟内没有记录时才补进去（例如最新的几分钟，或系统漏记的时段）
    static func merge(system: [Point]?, own: [Point]) -> [Point] {
        guard let system, !system.isEmpty else { return own }
        let times = system.map(\.time)
        let fill = own.filter { point in
            !times.contains { abs($0.timeIntervalSince(point.time)) < 8 * 60 }
        }
        return (system + fill).sorted { $0.time < $1.time }
    }

    private func refreshSystemLog(force: Bool = false, now: Date = Date()) {
        if usesSystemLog, force || systemLoadedAt.map({ now.timeIntervalSince($0) >= Self.systemRefresh }) ?? true {
            systemLoadedAt = now
            systemPoints = SystemBatteryLog.points(since: now.addingTimeInterval(-Self.window), now: now)
        }
        systemPoints?.removeAll { now.timeIntervalSince($0.time) > Self.window }
        points = Self.merge(system: systemPoints, own: ownPoints)
    }

    /// STATUS_DEMO 用的模拟记录：白天放电、中午充一次电、夜里睡眠断开一段；不读写文件
    static func demo(now: Date = Date()) -> BatteryHistory {
        let history = BatteryHistory(url: nil, usesSystemLog: false)
        var percent = 92.0
        for step in stride(from: 288, through: 0, by: -1) {
            let time = now.addingTimeInterval(-Double(step) * spacing)
            let hour = Double(288 - step) / 12
            if (6.5...9).contains(hour) { continue }   // 睡眠
            let charging = (13.0...14.5).contains(hour)
            percent = charging ? min(percent + 3.2, 100) : max(percent - 0.55, 8)
            history.ownPoints.append(Point(time: time, percent: Int(percent), charging: charging))
        }
        history.points = history.ownPoints
        return history
    }

    nonisolated private static var defaultURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("Status", isDirectory: true).appendingPathComponent("battery-history.json")
    }

    func record(percent: Int, charging: Bool, at now: Date = Date()) {
        if let last = ownPoints.last, now.timeIntervalSince(last.time) < Self.spacing,
           last.charging == charging, abs(last.percent - percent) < 3 {
            refreshSystemLog(now: now)
            return
        }
        ownPoints.append(Point(time: now, percent: percent, charging: charging))
        ownPoints.removeAll { now.timeIntervalSince($0.time) > Self.window }
        save()
        refreshSystemLog(now: now)
    }

    private func save() {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(ownPoints) { try? data.write(to: url, options: .atomic) }
    }
}
