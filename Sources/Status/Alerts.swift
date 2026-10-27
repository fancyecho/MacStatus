import Foundation
import UserNotifications

/// 达到阈值时发系统通知：电量低、CPU 过热、内存压力严重、磁盘快满、某个进程长时间占满 CPU。
/// 每种提醒有冷却时间，同一件事不会反复打扰
@MainActor
final class AlertMonitor {
    private let prefs: Preferences
    private var lastFired: [String: Date] = [:]
    private var hotSince: Date?
    /// 电量提醒已经发到了哪一档（20%、10%），接上电源或电量回升后重置
    private var batteryNotified: Int?
    private var busySince: [pid_t: Date] = [:]
    private var authorizationRequested = false

    static let lowBatteryLevels = [20, 10]
    static let hotCelsius = 95.0
    static let hotDuration: TimeInterval = 60
    static let lowDiskBytes: Int64 = 10 * 1_000_000_000
    static let busyPercent = 90.0
    static let busyDuration: TimeInterval = 5 * 60

    /// 只有作为 .app 运行时才有通知中心；直接运行 swift build 出来的可执行文件会崩溃
    private static let available = Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")

    init(prefs: Preferences) {
        self.prefs = prefs
    }

    /// 打开任意一项提醒时调用：第一次会弹出系统的通知授权
    func requestAuthorizationIfNeeded() {
        guard Self.available, !authorizationRequested, prefs.anyAlertEnabled else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func evaluate(battery: BatterySnapshot?, temperature: Double?, memoryPressure: Int,
                  disk: DiskSnapshot, processes: [ProcessEntry]?, now: Date = Date()) {
        if let battery { checkBattery(battery) }
        checkTemperature(temperature, now: now)
        if prefs.alertMemory, memoryPressure >= 4 {
            fire("memory", cooldown: 30 * 60, now: now, title: L("内存压力过高", "Memory pressure is critical"),
                 body: L("系统开始频繁压缩内存或使用交换空间，可以关闭一些占内存的应用。",
                         "macOS is compressing and swapping heavily. Quitting some memory-hungry apps will help."))
        }
        if prefs.alertDisk, disk.total > 0, disk.free < Self.lowDiskBytes {
            fire("disk", cooldown: 12 * 3600, now: now, title: L("磁盘空间不足", "Low disk space"),
                 body: L("\(disk.name) 只剩 \(Fmt.bytes(Double(disk.free)))，空间太少会影响系统更新和虚拟内存。",
                         "\(disk.name) has only \(Fmt.bytes(Double(disk.free))) left, which can block system updates and virtual memory."))
        }
        if let processes { checkBusyProcesses(processes, now: now) }
    }

    private func checkBattery(_ battery: BatterySnapshot) {
        if battery.onAC || battery.percent >= 30 {
            batteryNotified = nil
            return
        }
        guard prefs.alertLowBattery,
              let level = Self.lowBatteryLevels.last(where: { battery.percent <= $0 }),
              batteryNotified.map({ level < $0 }) ?? true else { return }
        batteryNotified = level
        post(id: "battery", title: L("电量只剩 \(battery.percent)%", "Battery at \(battery.percent)%"),
             body: level <= 10 ? L("请尽快接上电源。", "Plug in soon.")
                 : L("可以接上电源，或打开低电量模式延长使用时间。", "Plug in, or turn on Low Power Mode to last longer."))
    }

    private func checkTemperature(_ celsius: Double?, now: Date) {
        guard prefs.alertHot, let celsius, celsius >= Self.hotCelsius else {
            hotSince = nil
            return
        }
        let since = hotSince ?? now
        hotSince = since
        guard now.timeIntervalSince(since) >= Self.hotDuration else { return }
        fire("hot", cooldown: 30 * 60, now: now, title: String(format: L("CPU 温度 %.0f°C", "CPU at %.0f°C"), celsius),
             body: L("已经持续一分钟以上处于高温，可以看看是哪个进程在满负荷运行。",
                     "It has been this hot for over a minute. Check which process is running flat out."))
    }

    /// 进程连续 5 分钟占用超过一个核心的 90%
    private func checkBusyProcesses(_ processes: [ProcessEntry], now: Date) {
        guard prefs.alertRunaway else {
            busySince.removeAll()
            return
        }
        let busy = processes.filter { $0.cpu >= Self.busyPercent }
        busySince = busySince.filter { pid, _ in busy.contains { $0.id == pid } }
        for process in busy {
            let since = busySince[process.id] ?? now
            busySince[process.id] = since
            guard now.timeIntervalSince(since) >= Self.busyDuration else { continue }
            fire("busy-\(process.id)", cooldown: 3600, now: now, title: L("\(process.name) 持续占用 CPU", "\(process.name) is maxing out the CPU"),
                 body: String(format: L("已经连续 %d 分钟占用约 %.0f%% CPU。如果它不该这么忙，可以在 Status 的进程列表里右键退出。",
                                        "It has used about %2$.0f%% CPU for %1$d minutes. If it shouldn't be this busy, right-click it in Status's process list to quit it."),
                              Int(now.timeIntervalSince(since) / 60), process.cpu))
        }
    }

    private func fire(_ id: String, cooldown: TimeInterval, now: Date, title: String, body: String) {
        if let last = lastFired[id], now.timeIntervalSince(last) < cooldown { return }
        lastFired[id] = now
        post(id: id, title: title, body: body)
    }

    private func post(id: String, title: String, body: String) {
        guard Self.available else { return }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
