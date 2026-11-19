import Foundation
import SQLite3

/// 读取 macOS 自己的电量记录（系统设置 › 电池 里那张图的数据来源）。
/// powerd 把电量写进 /var/db/powerlog 下的 SQLite 数据库，睡眠时也会在每次短暂唤醒时记一笔，
/// 所以比 Status 自己采样完整得多。这不是公开接口：读不到（权限、表名变化、Intel 机型没有）时返回 nil，
/// 由调用方退回到 Status 自己的记录
enum SystemBatteryLog {
    static let path = "/var/db/powerlog/Library/BatteryLife/CurrentPowerlog.PLSQL"

    static func points(since start: Date, now: Date = Date()) -> [BatteryHistory.Point]? {
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        let uri = "file:\(path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(db, 200)

        let sql = """
            SELECT timestamp, Level, IsCharging FROM PLBatteryAgent_EventBackward_BatteryUI
            WHERE timestamp >= ? ORDER BY timestamp
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)

        var result: [BatteryHistory.Point] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let time = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            let level = sqlite3_column_double(statement, 1)
            // 时间校正前可能出现未来的时间戳，或者异常的电量，都丢掉
            guard time <= now.addingTimeInterval(60), (0...100).contains(level) else { continue }
            result.append(BatteryHistory.Point(time: time, percent: Int(level.rounded()),
                                               charging: sqlite3_column_int(statement, 2) != 0))
        }
        return result
    }
}
