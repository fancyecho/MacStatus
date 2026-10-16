import AppKit
import Darwin
import IOKit
import IOKit.ps
import SystemConfiguration
import UniformTypeIdentifiers

// MARK: - Snapshots

struct CPUSnapshot {
    var usage: Double = 0      // 0–100
    var user: Double = 0
    var system: Double = 0
    var cores: [Double] = []   // 每个核心 0–100
}

struct MemorySnapshot {
    var total: UInt64 = ProcessInfo.processInfo.physicalMemory
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressureLevel: Int = 1 // 1 正常 / 2 警告 / 4 严重

    var used: UInt64 { app + wired + compressed }
    var usedPercent: Double { total == 0 ? 0 : Double(used) / Double(total) * 100 }
}

struct NetworkSnapshot {
    var down: Double = 0       // bytes/s
    var up: Double = 0
    var totalDown: UInt64 = 0
    var totalUp: UInt64 = 0
    var address: String?
}

struct DiskSnapshot {
    var name: String = "Macintosh HD"
    var total: Int64 = 0
    var free: Int64 = 0
    var read: Double = 0       // bytes/s
    var write: Double = 0

    var usedPercent: Double { total == 0 ? 0 : Double(total - free) / Double(total) * 100 }
}

struct BatterySnapshot {
    var percent: Int = 0
    var isCharging = false
    var onAC = false
    var minutesRemaining: Int?
    var health: Int?
    var cycles: Int?
    var temperature: Double?
    var watts: Double?
}

struct ProcessEntry: Identifiable {
    let id: pid_t
    let name: String
    let icon: NSImage
    let cpu: Double
    let memory: UInt64
}

// MARK: - CPU

final class CPUSampler {
    private var previous: [[UInt32]] = []

    func sample() -> CPUSnapshot {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return CPUSnapshot() }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var current: [[UInt32]] = []
        for i in 0..<Int(cpuCount) {
            let base = Int(CPU_STATE_MAX) * i
            current.append([
                UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]),
            ])
        }
        defer { previous = current }
        guard previous.count == current.count else { return CPUSnapshot(cores: Array(repeating: 0, count: current.count)) }

        var snapshot = CPUSnapshot()
        var sumUser = 0.0, sumSystem = 0.0, sumTotal = 0.0
        for (cur, prev) in zip(current, previous) {
            let user = Double(cur[0] &- prev[0]) + Double(cur[3] &- prev[3])
            let system = Double(cur[1] &- prev[1])
            let idle = Double(cur[2] &- prev[2])
            let total = user + system + idle
            snapshot.cores.append(total > 0 ? (user + system) / total * 100 : 0)
            sumUser += user; sumSystem += system; sumTotal += total
        }
        if sumTotal > 0 {
            snapshot.user = sumUser / sumTotal * 100
            snapshot.system = sumSystem / sumTotal * 100
            snapshot.usage = snapshot.user + snapshot.system
        }
        return snapshot
    }
}

// MARK: - Memory

enum MemorySampler {
    static func sample() -> MemorySnapshot {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var snapshot = MemorySnapshot()
        guard result == KERN_SUCCESS else { return snapshot }

        let page = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        snapshot.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        snapshot.wired = UInt64(stats.wire_count) * page
        snapshot.compressed = UInt64(stats.compressor_page_count) * page
        snapshot.cached = (purgeable + UInt64(stats.external_page_count)) * page

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            snapshot.swapUsed = swap.xsu_used
        }
        snapshot.pressureLevel = Int(SystemInfo.sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 1)
        return snapshot
    }
}

// MARK: - GPU

enum GPUSampler {
    /// 返回 0–100，读不到（例如虚拟机）时返回 nil
    static func sample() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let value = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            best = max(best ?? 0, value)
        }
        return best
    }
}

// MARK: - Network

final class NetworkSampler {
    private var last: (rx: UInt64, tx: UInt64, time: TimeInterval)?
    private var names: [UInt16: String] = [:]

    func sample() -> NetworkSnapshot {
        let (rx, tx) = counters()
        let now = ProcessInfo.processInfo.systemUptime
        var snapshot = NetworkSnapshot(totalDown: rx, totalUp: tx, address: Self.primaryIPv4())
        if let last, now > last.time {
            let dt = now - last.time
            snapshot.down = rx >= last.rx ? Double(rx - last.rx) / dt : 0
            snapshot.up = tx >= last.tx ? Double(tx - last.tx) / dt : 0
        }
        last = (rx, tx, now)
        return snapshot
    }

    private func interfaceName(_ index: UInt16) -> String {
        if let cached = names[index] { return cached }
        var buffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        let name = if_indextoname(UInt32(index), &buffer) != nil ? String(cString: buffer) : ""
        names[index] = name
        return name
    }

    /// 只统计物理接口（en*），避免 VPN 隧道重复计数
    private func counters() -> (UInt64, UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return (0, 0) }

        var rx: UInt64 = 0, tx: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if interfaceName(message.ifm_index).hasPrefix("en") {
                        rx += message.ifm_data.ifi_ibytes
                        tx += message.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (rx, tx)
    }

    static func primaryIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  String(cString: entry.pointee.ifa_name).hasPrefix("en") else { continue }
            var addr = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                return String(cString: buffer)
            }
        }
        return nil
    }
}

// MARK: - Disk

final class DiskSampler {
    private var last: (read: UInt64, write: UInt64, time: TimeInterval)?

    private var capacity = DiskSnapshot()
    private var capacityTime: TimeInterval = -.infinity

    func sample() -> DiskSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        // 查询可用空间很慢，30 秒刷新一次就够了
        if now - capacityTime > 30 {
            capacityTime = now
            let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey]
            if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) {
                capacity.total = Int64(values.volumeTotalCapacity ?? 0)
                capacity.free = values.volumeAvailableCapacityForImportantUsage ?? 0
                capacity.name = values.volumeLocalizedName ?? capacity.name
            }
        }

        var snapshot = capacity
        let (read, write) = Self.ioCounters()
        if let last, now > last.time {
            let dt = now - last.time
            snapshot.read = read >= last.read ? Double(read - last.read) / dt : 0
            snapshot.write = write >= last.write ? Double(write - last.write) / dt : 0
        }
        last = (read, write, now)
        return snapshot
    }

    private static func ioCounters() -> (UInt64, UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0, write: UInt64 = 0
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, write)
    }
}

// MARK: - Battery

enum BatterySampler {
    static func sample() -> BatterySnapshot? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }

            var snapshot = BatterySnapshot()
            let current = info[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(info[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            snapshot.percent = Int((Double(current) / Double(maximum) * 100).rounded())
            snapshot.isCharging = info[kIOPSIsChargingKey] as? Bool ?? false
            snapshot.onAC = info[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let minutes = snapshot.isCharging ? info[kIOPSTimeToFullChargeKey] as? Int : info[kIOPSTimeToEmptyKey] as? Int
            if let minutes, minutes > 0 { snapshot.minutesRemaining = minutes }
            addSmartBatteryDetails(to: &snapshot)
            return snapshot
        }
        return nil
    }

    private static func addSmartBatteryDetails(to snapshot: inout BatterySnapshot) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any] else { return }

        func number(_ key: String) -> Int64? { (dict[key] as? NSNumber)?.int64Value }

        snapshot.cycles = number("CycleCount").map(Int.init)
        if let temp = number("Temperature") { snapshot.temperature = Double(temp) / 100 }
        if let design = number("DesignCapacity"), design > 0,
           let raw = number("AppleRawMaxCapacity") ?? number("NominalChargeCapacity") {
            snapshot.health = min(100, Int((Double(raw) / Double(design) * 100).rounded()))
        }
        if let voltage = number("Voltage"), let amperage = number("InstantAmperage") ?? number("Amperage") {
            let amps = Double(Int32(truncatingIfNeeded: amperage)) / 1000
            let watts = abs(Double(voltage) / 1000 * amps)
            if watts > 0.05 { snapshot.watts = watts }
        }
    }
}

// MARK: - Processes

final class ProcessSampler {
    private var previous: [pid_t: UInt64] = [:]
    private var lastTime: UInt64 = 0
    private var identities: [pid_t: (name: String, icon: NSImage)] = [:]
    private static let genericIcon = NSWorkspace.shared.icon(for: .unixExecutable)

    func sample(limit: Int = 5) -> (byCPU: [ProcessEntry], byMemory: [ProcessEntry]) {
        let capacity = Int(proc_listallpids(nil, 0)) + 32
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return ([], []) }

        let now = mach_absolute_time()
        let elapsed = lastTime == 0 ? 0 : Double(now - lastTime)
        var current: [pid_t: UInt64] = [:]
        var rows: [(pid: pid_t, cpu: Double, memory: UInt64)] = []

        for pid in pids.prefix(count) where pid > 0 {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard ok == 0 else { continue }
            // 两者都是 mach 时间单位，直接相除即可
            let time = info.ri_user_time + info.ri_system_time
            current[pid] = time
            var cpu = 0.0
            if elapsed > 0, let prev = previous[pid], time >= prev {
                cpu = Double(time - prev) / elapsed * 100
            }
            rows.append((pid, cpu, info.ri_phys_footprint))
        }
        previous = current
        lastTime = now
        identities = identities.filter { current[$0.key] != nil }

        func entries(_ sorted: some Sequence<(pid: pid_t, cpu: Double, memory: UInt64)>) -> [ProcessEntry] {
            sorted.prefix(limit).map { row in
                let identity = identity(for: row.pid)
                return ProcessEntry(id: row.pid, name: identity.name, icon: identity.icon, cpu: row.cpu, memory: row.memory)
            }
        }
        return (entries(rows.sorted { $0.cpu > $1.cpu }), entries(rows.sorted { $0.memory > $1.memory }))
    }

    private func identity(for pid: pid_t) -> (name: String, icon: NSImage) {
        if let cached = identities[pid] { return cached }

        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let path = proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
        let app = NSRunningApplication(processIdentifier: pid)

        var name = app?.localizedName ?? (path as NSString).lastPathComponent
        if name.isEmpty {
            var short = [CChar](repeating: 0, count: 64)
            proc_name(pid, &short, UInt32(short.count))
            name = String(cString: short)
        }

        var icon = app?.icon
        if icon == nil, let range = path.range(of: ".app/") {
            icon = NSWorkspace.shared.icon(forFile: String(path[..<range.lowerBound]) + ".app")
        }
        let identity = (name, icon ?? Self.genericIcon)
        identities[pid] = identity
        return identity
    }
}

// MARK: - System info

enum SystemInfo {
    static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static let chip: String = {
        let brand = sysctlString("machdep.cpu.brand_string") ?? "Mac"
        return brand.replacingOccurrences(of: " (Virtual)", with: "")
    }()

    static let computerName: String = {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }()

    static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "macOS \(v.majorVersion).\(v.minorVersion)"
    }()

    static var uptime: TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return ProcessInfo.processInfo.systemUptime }
        return Date().timeIntervalSince1970 - Double(boot.tv_sec)
    }

    static var loadAverage: [Double] {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads : []
    }
}

// MARK: - Temperature

struct TemperatureSnapshot: Equatable {
    var cpu: Double?
    var gpu: Double?
}

/// Apple 芯片的温度只能通过 IOKit 的 HID 传感器读取，相关函数没有公开头文件，用 dlsym 动态加载。
/// 读不到（Intel、虚拟机、系统更改了接口）时返回 nil，界面会自动隐藏温度。
final class TemperatureSampler {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatFn = @convention(c) (AnyObject, Int32) -> Double

    private static let temperatureEvent: Int64 = 15

    private var copyEvent: CopyEventFn?
    private var getFloat: GetFloatFn?
    private var client: AnyObject?
    private var cpuSensors: [AnyObject] = []
    private var gpuSensors: [AnyObject] = []

    init() {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let create = dlsym(iokit, "IOHIDEventSystemClientCreate"),
              let setMatching = dlsym(iokit, "IOHIDEventSystemClientSetMatching"),
              let copyServices = dlsym(iokit, "IOHIDEventSystemClientCopyServices"),
              let copyProperty = dlsym(iokit, "IOHIDServiceClientCopyProperty"),
              let copyEvent = dlsym(iokit, "IOHIDServiceClientCopyEvent"),
              let getFloat = dlsym(iokit, "IOHIDEventGetFloatValue") else { return }

        self.copyEvent = unsafeBitCast(copyEvent, to: CopyEventFn.self)
        self.getFloat = unsafeBitCast(getFloat, to: GetFloatFn.self)

        guard let client = unsafeBitCast(create, to: CreateFn.self)(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        self.client = client
        // 0xff00 / 5 = Apple 厂商定义的温度传感器
        _ = unsafeBitCast(setMatching, to: SetMatchingFn.self)(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let services = (unsafeBitCast(copyServices, to: CopyServicesFn.self)(client)?.takeRetainedValue() as? [AnyObject]) ?? []

        let property = unsafeBitCast(copyProperty, to: CopyPropertyFn.self)
        var accSensors: [AnyObject] = [], dieSensors: [AnyObject] = []
        for service in services {
            guard let name = property(service, "Product" as CFString)?.takeRetainedValue() as? String else { continue }
            if name.contains("pACC") || name.contains("eACC") { accSensors.append(service) }
            else if name.hasPrefix("PMU") && name.contains("tdie") { dieSensors.append(service) }
            else if name.contains("GPU") { gpuSensors.append(service) }
        }
        // M1/M2 有按核心簇划分的 pACC/eACC 传感器；较新的芯片退回到芯片核心温度 (tdie)
        cpuSensors = accSensors.isEmpty ? dieSensors : accSensors
    }

    var isAvailable: Bool { !cpuSensors.isEmpty }

    func sample() -> TemperatureSnapshot? {
        guard isAvailable else { return nil }
        return TemperatureSnapshot(cpu: average(cpuSensors), gpu: average(gpuSensors))
    }

    private func average(_ sensors: [AnyObject]) -> Double? {
        guard let copyEvent, let getFloat else { return nil }
        let values = sensors.compactMap { sensor -> Double? in
            guard let event = copyEvent(sensor, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
            let value = getFloat(event, Int32(Self.temperatureEvent << 16))
            return value > 0 && value < 150 ? value : nil
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
