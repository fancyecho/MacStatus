import CoreWLAN
import Foundation
import SystemConfiguration

/// Wi-Fi 信号（没有 Wi-Fi 时为 nil，例如用网线）
struct WiFiSnapshot: Equatable {
    var rssi: Int          // dBm，越接近 0 越强
    var noise: Int         // dBm
    var rate: Double       // 当前协商速率 Mbps
    var channel: Int
    var band: String       // "2.4 GHz" / "5 GHz" / "6 GHz"

    /// 0...1 的信号强度，用来画 Wi-Fi 图标的格数
    var strength: Double { min(max(Double(rssi + 90) / 40, 0), 1) }
}

/// 往返延迟（毫秒），没有回应时为 nil
struct LatencySnapshot: Equatable {
    struct Target: Equatable {
        var name: String
        var host: String
        var milliseconds: Double?
    }

    var gateway: Double?
    var targets: [Target]

    /// 互联网延迟取几个公共 DNS 里最快的一个：它们都是任播地址，在哪个国家都会连到就近的节点，
    /// 其中个别在当地被限制也不影响结果
    var internet: Double? { targets.compactMap(\.milliseconds).min() }
}

enum WiFiSampler {
    static func sample() -> WiFiSnapshot? {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn(), interface.rssiValue() != 0 else { return nil }
        let band: String = switch interface.wlanChannel()?.channelBand {
        case .band2GHz: "2.4 GHz"
        case .band5GHz: "5 GHz"
        case .band6GHz: "6 GHz"
        default: ""
        }
        return WiFiSnapshot(rssi: interface.rssiValue(), noise: interface.noiseMeasurement(),
                            rate: interface.transmitRate(), channel: interface.wlanChannel()?.channelNumber ?? 0, band: band)
    }
}

/// 用 ICMP 测延迟：路由器（很多路由器不回 ping，这时不显示）和几个任播的公共 DNS
enum LatencySampler {
    static let publicTargets = [("Cloudflare", "1.1.1.1"), ("Google", "8.8.8.8"), ("Quad9", "9.9.9.9"), ("AliDNS", "223.5.5.5")]

    /// 阻塞调用，所有目标并行，最多约 1 秒
    static func sample() -> LatencySnapshot {
        let hosts = [gatewayAddress()] + publicTargets.map { Optional($0.1) }
        var results = [Double?](repeating: nil, count: hosts.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: hosts.count) { index in
            guard let host = hosts[index] else { return }
            let value = Pinger.ping(host)
            lock.lock()
            results[index] = value
            lock.unlock()
        }
        let targets = publicTargets.enumerated().map { index, target in
            LatencySnapshot.Target(name: target.0, host: target.1, milliseconds: results[index + 1])
        }
        return LatencySnapshot(gateway: results[0], targets: targets)
    }

    private static func gatewayAddress() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Status" as CFString, nil, nil),
              let info = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { return nil }
        return info["Router"] as? String
    }
}

/// 不需要管理员权限的 ICMP echo（macOS 允许普通进程用 SOCK_DGRAM 发 ICMP）
enum Pinger {
    static func ping(_ address: String, timeout: TimeInterval = 1) -> Double? {
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, address, &target.sin_addr) == 1 else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let identifier = UInt16.random(in: 1...UInt16.max)
        let sequence = UInt16.random(in: 1...UInt16.max)
        var packet = [UInt8](repeating: 0, count: 16)
        packet[0] = 8   // echo request
        packet[4] = UInt8(identifier >> 8); packet[5] = UInt8(identifier & 0xff)
        packet[6] = UInt8(sequence >> 8); packet[7] = UInt8(sequence & 0xff)
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8); packet[3] = UInt8(sum & 0xff)

        let start = DispatchTime.now().uptimeNanoseconds
        let sent = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent == packet.count else { return nil }

        let deadline = start + UInt64(timeout * 1e9)
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return nil }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Int32((deadline - now) / 1_000_000) + 1) > 0 else { return nil }
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            // 收到的数据可能带 IPv4 头，先跳过
            let offset = buffer[0] >> 4 == 4 ? Int(buffer[0] & 0x0f) * 4 : 0
            guard count >= offset + 8 else { continue }
            let replySequence = UInt16(buffer[offset + 6]) << 8 | UInt16(buffer[offset + 7])
            if buffer[offset] == 0, replySequence == sequence {
                return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            }
        }
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        for index in stride(from: 0, to: bytes.count, by: 2) {
            sum += UInt32(bytes[index]) << 8 | UInt32(index + 1 < bytes.count ? bytes[index + 1] : 0)
        }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }
}
