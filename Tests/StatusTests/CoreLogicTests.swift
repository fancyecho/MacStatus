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
        let history = BatteryHistory(url: nil)
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

    func testLanguageSettingIsApplied() {
        let saved = Lang.setting
        defer { Lang.setting = saved }
        Lang.setting = .english
        XCTAssertEqual(L("中", "en"), "en")
        Lang.setting = .chinese
        XCTAssertEqual(L("中", "en"), "中")
    }
}
