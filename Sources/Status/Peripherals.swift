import CoreAudio
import Foundation
import IOKit

/// 蓝牙外设的电量（AirPods、妙控鼠标 / 键盘 / 触控板等）
struct PeripheralBattery: Identifiable, Equatable {
    struct Level: Equatable {
        var label: String?    // AirPods 的"左""右""盒"；单电池设备为 nil
        var percent: Int
    }

    var id: String { name }
    var name: String
    var symbol: String
    var levels: [Level]
}

/// 两个来源：IORegistry 里苹果 HID 外设的 BatteryPercent（妙控系列），
/// 以及 system_profiler 的蓝牙信息（AirPods 的左右耳和充电盒）。都是阻塞调用，放在后台线程
enum PeripheralSampler {
    static func sample() -> [PeripheralBattery] {
        var result = hidDevices()
        for device in bluetoothDevices() where !result.contains(where: { $0.name == device.name }) {
            result.append(device)
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func hidDevices() -> [PeripheralBattery] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [PeripheralBattery] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let percent = property("BatteryPercent") as? Int, let name = property("Product") as? String else { continue }
            devices.append(PeripheralBattery(name: name, symbol: symbol(name: name, type: nil),
                                             levels: [.init(label: nil, percent: percent)]))
        }
        return devices
    }

    private static func bluetoothDevices() -> [PeripheralBattery] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = json["SPBluetoothDataType"] as? [[String: Any]] else { return [] }

        var devices: [PeripheralBattery] = []
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let parts: [(String, String?)] = [("device_batteryLevelMain", nil), ("device_batteryLevelLeft", L("左", "L")),
                                                      ("device_batteryLevelRight", L("右", "R")), ("device_batteryLevelCase", L("盒", "Case"))]
                    let levels = parts.compactMap { key, label -> PeripheralBattery.Level? in
                        guard let text = info[key] as? String, let percent = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) else { return nil }
                        return .init(label: label, percent: percent)
                    }
                    guard !levels.isEmpty else { continue }
                    devices.append(PeripheralBattery(name: name, symbol: symbol(name: name, type: info["device_minorType"] as? String),
                                                     levels: levels))
                }
            }
        }
        return devices
    }

    private static func symbol(name: String, type: String?) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("mouse") || type == "Mouse" { return "magicmouse" }
        if lower.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if lower.contains("keyboard") || type == "Keyboard" { return "keyboard" }
        if lower.contains("pencil") { return "applepencil" }
        if type == "Headphones" || type == "Headset" { return "headphones" }
        if type == "Gamepad" || type == "Joystick" { return "gamecontroller" }
        return "dot.radiowaves.left.and.right"
    }
}

/// 外设连接 / 断开时回调。蓝牙耳机连上后会出现在音频设备列表里，妙控外设会出现新的 HID 服务；
/// 两种通知都不需要蓝牙权限，比定时轮询快得多
@MainActor
final class PeripheralWatcher {
    private let onChange: () -> Void
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        var devices = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange() }
        }

        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            IOServiceAddMatchingNotification(port, type, IOServiceMatching("AppleDeviceManagementHIDEventService"), { context, iterator in
                PeripheralWatcher.drain(iterator)
                guard let context else { return }
                let watcher = Unmanaged<PeripheralWatcher>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { watcher.onChange() }
            }, context, &iterator)
            // 先把已有的设备取完，通知才会开始工作
            Self.drain(iterator)
            iterators.append(iterator)
        }
    }

    private nonisolated static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
    }
}
