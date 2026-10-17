import Foundation
import ServiceManagement

@MainActor
final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var showCPU: Bool { didSet { defaults.set(showCPU, forKey: "showCPU") } }
    @Published var showMemory: Bool { didSet { defaults.set(showMemory, forKey: "showMemory") } }
    @Published var showGPU: Bool { didSet { defaults.set(showGPU, forKey: "showGPU") } }
    @Published var showNetwork: Bool { didSet { defaults.set(showNetwork, forKey: "showNetwork") } }
    @Published var showBattery: Bool { didSet { defaults.set(showBattery, forKey: "showBattery") } }
    @Published var showTemperature: Bool { didSet { defaults.set(showTemperature, forKey: "showTemperature") } }
    @Published var interval: Double { didSet { defaults.set(interval, forKey: "interval") } }
    @Published var processSort: ProcessSort { didSet { defaults.set(processSort.rawValue, forKey: "processSort") } }

    /// 面板当前显示的页面（不持久化）
    @Published var page: Page = .overview

    enum Page { case overview, settings, battery }

    enum ProcessSort: String, CaseIterable { case cpu, memory }

    init() {
        defaults.register(defaults: [
            "showCPU": true, "showMemory": true, "showGPU": false,
            "showNetwork": true, "showBattery": false, "showTemperature": true, "interval": 2.0,
        ])
        showCPU = defaults.bool(forKey: "showCPU")
        showMemory = defaults.bool(forKey: "showMemory")
        showGPU = defaults.bool(forKey: "showGPU")
        showNetwork = defaults.bool(forKey: "showNetwork")
        showBattery = defaults.bool(forKey: "showBattery")
        showTemperature = defaults.bool(forKey: "showTemperature")
        interval = defaults.double(forKey: "interval")
        processSort = ProcessSort(rawValue: defaults.string(forKey: "processSort") ?? "") ?? .cpu
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }
}

/// 菜单栏只用到这几个数值；只有显示内容真正变化时才发布，避免无谓重绘
@MainActor
final class MenuBarModel: ObservableObject {
    struct Values: Equatable {
        var cpu = 0
        var memory = 0
        var gpu: Int?
        var up = "0B"
        var down = "0B"
        var battery: Int?
        var temperature: Int?
        var charging = false
    }

    @Published private(set) var values = Values()

    func update(_ new: Values) {
        if new != values { values = new }
    }
}

/// 面板数据不用 @Published：面板关闭时照常采样，但只在面板可见时通知 SwiftUI 刷新
@MainActor
final class SystemMonitor: ObservableObject {
    static let historyLength = 60

    let menuBar = MenuBarModel()

    private(set) var cpu = CPUSnapshot()
    private(set) var memory = MemorySnapshot()
    private(set) var gpu: Double?
    private(set) var network = NetworkSnapshot()
    private(set) var disk = DiskSnapshot()
    private(set) var battery: BatterySnapshot?
    private(set) var temperature: TemperatureSnapshot?
    private(set) var topByCPU: [ProcessEntry] = []
    private(set) var topByMemory: [ProcessEntry] = []
    private(set) var uptime: TimeInterval = 0
    private(set) var loadAverage: [Double] = []

    private(set) var cpuHistory: [Double] = []
    private(set) var gpuHistory: [Double] = []
    private(set) var downHistory: [Double] = []
    private(set) var upHistory: [Double] = []
    private(set) var systemPowerHistory: [Double] = []
    private(set) var batteryPowerHistory: [Double] = []

    var panelVisible = false {
        didSet {
            guard panelVisible != oldValue else { return }
            if panelVisible {
                // 打开面板时立即刷新进程列表等低频数据
                tick(full: true)
                objectWillChange.send()
            }
        }
    }

    private let prefs: Preferences
    private let cpuSampler = CPUSampler()
    private let networkSampler = NetworkSampler()
    private let diskSampler = DiskSampler()
    private let processSampler = ProcessSampler()
    private let temperatureSampler = TemperatureSampler()
    private var loop: Task<Void, Never>?
    private var tickCount = 0

    init(prefs: Preferences) {
        self.prefs = prefs
        start()
    }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                if self.panelVisible { self.objectWillChange.send() }
                try? await Task.sleep(for: .seconds(self.prefs.interval))
            }
        }
    }

    private func tick(full: Bool = false) {
        let first = tickCount == 0
        cpu = cpuSampler.sample()
        memory = MemorySampler.sample()
        gpu = GPUSampler.sample()
        network = networkSampler.sample()

        // 进程、磁盘、电池只在面板里展示，面板关闭时降低频率
        let detailed = full || panelVisible || tickCount % 5 == 0
        if detailed {
            disk = diskSampler.sample()
            let processes = processSampler.sample()
            topByCPU = processes.byCPU
            topByMemory = processes.byMemory
        }
        // 电池详情要看实时功率，面板打开时每次都采样
        if full || panelVisible || tickCount % 5 == 0 {
            battery = BatterySampler.sample()
            if !full, let battery {
                Self.push(battery.systemPower ?? 0, to: &systemPowerHistory)
                Self.push(battery.batteryPower ?? 0, to: &batteryPowerHistory)
            }
        }
        if full || panelVisible || prefs.showTemperature || tickCount % 5 == 0 {
            temperature = temperatureSampler.sample()
        }
        uptime = SystemInfo.uptime
        loadAverage = SystemInfo.loadAverage
        if Self.demoMode { applyDemoData() }

        // 第一次采样没有差值，不计入历史；额外的刷新也不计入，保持时间轴均匀
        if !first && !full {
            Self.push(cpu.usage, to: &cpuHistory)
            if let gpu { Self.push(gpu, to: &gpuHistory) }
            Self.push(network.down, to: &downHistory)
            Self.push(network.up, to: &upHistory)
        }
        if !full { tickCount += 1 }

        menuBar.update(.init(
            cpu: Int(cpu.usage.rounded()),
            memory: Int(memory.usedPercent.rounded()),
            gpu: gpu.map { Int($0.rounded()) },
            up: Fmt.compactRate(network.up),
            down: Fmt.compactRate(network.down),
            battery: battery?.percent,
            temperature: temperature?.cpu.map { Int($0.rounded()) },
            charging: battery?.isCharging ?? false
        ))
    }

    /// STATUS_DEMO=1：用模拟的 GPU / 温度 / 电池数据填充界面，便于在没有这些传感器的机器上检查布局
    private static let demoMode = ProcessInfo.processInfo.environment["STATUS_DEMO"] != nil

    private func applyDemoData() {
        gpu = Double.random(in: 4...45)
        let cpuTemp = Double.random(in: 52...60)
        temperature = TemperatureSnapshot(cpu: cpuTemp, cpuMax: cpuTemp + 7, cpuSensorCount: 10,
                                          cpuSource: "演示数据", gpu: cpuTemp - 4)
        // 故意让数值的位数来回跳，检查卡片高度是否稳定
        let wide = tickCount % 2 == 0
        disk.read = wide ? 123_400_000 : 820
        disk.write = wide ? 4_560 : 98_700_000
        // 偶数次模拟接电源充电，奇数次模拟使用电池
        let system = Double.random(in: 6...11)
        var b = BatterySnapshot(percent: 78, isCharging: wide, onAC: wide, minutesRemaining: wide ? 72 : 312,
                                health: 92, cycles: 312, designCycles: 1000, temperature: 31.4,
                                currentCapacity: 3420, fullCapacity: 4210, designCapacity: 4563,
                                voltage: 12.61, adapterWatts: wide ? 35 : nil, adapterName: wide ? "USB-C 电源适配器" : nil)
        b.batteryPower = wide ? 18.6 : -system
        b.amperage = (b.batteryPower ?? 0) / 12.61
        b.systemPower = system
        b.adapterPower = wide ? system + 18.6 : nil
        battery = b
        Self.push(system, to: &systemPowerHistory)
        Self.push(b.batteryPower ?? 0, to: &batteryPowerHistory)
    }

    private static func push(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
    }
}
