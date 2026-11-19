import Foundation
import XCTest
@testable import Status

/// 不依赖硬件的纯逻辑：格式化、版本比较、电量记录
final class CoreLogicTests: XCTestCase {
    func testCompactRateCarriesToNextUnit() {
        XCTAssertEqual(Fmt.compactRate(0), "0B")
        XCTAssertEqual(Fmt.compactRate(999), "999B")
        XCTAssertEqual(Fmt.compactRate(999.6), "1.0K")
        XCTAssertEqual(Fmt.compactRate(1_500), "1.5K")
        XCTAssertEqual(Fmt.compactRate(999_700), "1.0M")
        XCTAssertEqual(Fmt.compactRate(-5), "0B")
    }

    func testBytesCarriesToNextUnit() {
        XCTAssertEqual(Fmt.bytes(999.7 * 1000), "1.00 MB")
        XCTAssertEqual(Fmt.bytes(12_300_000), "12.3 MB")
        XCTAssertEqual(Fmt.memory(8 * 1024 * 1024 * 1024 as UInt64), "8.00 GB")
    }

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("1.10.0", than: "1.9.2"))
        XCTAssertTrue(UpdateChecker.isNewer("1.6.1", than: "1.6"))
        XCTAssertFalse(UpdateChecker.isNewer("1.6.0", than: "1.6"))
        XCTAssertFalse(UpdateChecker.isNewer("1.5.9", than: "1.6.0"))
    }

    @MainActor
    func testBatteryHistoryThinsSteadyReadings() {
        let history = BatteryHistory(url: nil, usesSystemLog: false)
        let start = Date()
        history.record(percent: 80, charging: false, at: start)
        // 5 分钟内、电量变化不到 3% 且状态不变：不新增点
        history.record(percent: 79, charging: false, at: start.addingTimeInterval(60))
        XCTAssertEqual(history.points.count, 1)
        // 开始充电：立即记一个点
        history.record(percent: 79, charging: true, at: start.addingTimeInterval(120))
        XCTAssertEqual(history.points.count, 2)
        // 超过 24 小时的点会被清掉
        history.record(percent: 90, charging: true, at: start.addingTimeInterval(25 * 3600))
        XCTAssertEqual(history.points.map(\.percent), [90])
    }

    @MainActor
    func testBatteryHistoryPrefersSystemLogAndFillsGaps() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func point(_ minutes: Double, _ percent: Int) -> BatteryHistory.Point {
            .init(time: t0.addingTimeInterval(minutes * 60), percent: percent, charging: false)
        }
        let system = [point(0, 80), point(15, 79), point(30, 78)]
        // 3 分钟处的自己的点和系统记录重复，丢掉；60 分钟处系统没有记录，补上
        let own = [point(3, 80), point(60, 75)]
        XCTAssertEqual(BatteryHistory.merge(system: system, own: own).map(\.percent), [80, 79, 78, 75])
        // 读不到系统记录时只用自己的
        XCTAssertEqual(BatteryHistory.merge(system: nil, own: own).map(\.percent), [80, 75])
    }

    func testLanguageSettingIsApplied() {
        let saved = Lang.setting
        defer { Lang.setting = saved }
        Lang.setting = .english
        XCTAssertEqual(L("中", "en"), "en")
        Lang.setting = .chinese
        XCTAssertEqual(L("中", "en"), "中")
    }
}
