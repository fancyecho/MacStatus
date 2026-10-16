import Foundation

enum Fmt {
    /// 返回 (数值, 单位)，十进制换算，和访达 / 活动监视器保持一致
    static func bytesParts(_ value: Double, base: Double = 1000) -> (String, String) {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = max(value, 0)
        var index = 0
        while v >= base && index < units.count - 1 { v /= base; index += 1 }
        let number: String
        if index == 0 { number = String(format: "%.0f", v) }
        else if v >= 100 { number = String(format: "%.0f", v) }
        else if v >= 10 { number = String(format: "%.1f", v) }
        else { number = String(format: "%.2f", v) }
        return (number, units[index])
    }

    static func bytes(_ value: Double) -> String {
        let (n, u) = bytesParts(value)
        return "\(n) \(u)"
    }

    static func bytes<T: BinaryInteger>(_ value: T) -> String { bytes(Double(value)) }

    /// 内存按 1024 换算，8 GB 内存显示为 "8.00 GB"
    static func memory<T: BinaryInteger>(_ value: T) -> String {
        let (n, u) = bytesParts(Double(value), base: 1024)
        return "\(n) \(u)"
    }

    static func rate(_ value: Double) -> String { bytes(value) + "/s" }

    /// 菜单栏用的紧凑写法，例如 "1.2M"
    static func compactRate(_ value: Double) -> String {
        let units = ["B", "K", "M", "G"]
        var v = max(value, 0)
        var index = 0
        while v >= 1000 && index < units.count - 1 { v /= 1000; index += 1 }
        let number = (v >= 10 || index == 0) ? String(format: "%.0f", v) : String(format: "%.1f", v)
        return number + units[index]
    }

    static func percent(_ value: Double) -> String { String(format: "%.0f", min(max(value, 0), 100)) }

    static func uptime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(mins) 分" }
        return "\(mins) 分钟"
    }

    static func minutes(_ total: Int) -> String {
        total >= 60 ? "\(total / 60):\(String(format: "%02d", total % 60))" : "\(total) 分钟"
    }
}
