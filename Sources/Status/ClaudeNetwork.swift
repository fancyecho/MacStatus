import Combine
import Darwin
import Foundation

/// A trace describes this app's request to a particular host, not another process's proxy route.
struct ClaudeExit: Equatable, Codable {
    let ip: String
    let countryCode: String?

    var family: String { ip.contains(":") ? "IPv6" : "IPv4" }

    static func parse(_ text: String, host: String) -> ClaudeExit? {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { fields[pair[0]] = pair[1].trimmingCharacters(in: .whitespaces) }
        }
        guard fields["h"]?.lowercased() == host.lowercased(),
              let ip = fields["ip"], isIPAddress(ip) else { return nil }
        return ClaudeExit(ip: ip, countryCode: fields["loc"]?.uppercased())
    }

    static func isIPAddress(_ value: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }

    static func sameIP(_ lhs: String, _ rhs: String) -> Bool {
        var a = in6_addr(), b = in6_addr()
        if lhs.withCString({ inet_pton(AF_INET6, $0, &a) }) == 1,
           rhs.withCString({ inet_pton(AF_INET6, $0, &b) }) == 1 {
            return withUnsafeBytes(of: a) { x in withUnsafeBytes(of: b) { y in x.elementsEqual(y) } }
        }
        return lhs == rhs && isIPAddress(lhs)
    }
}

struct ClaudeProbe: Equatable, Identifiable {
    enum Status: String, Codable {
        case reachable, authentication, restricted, limited, serverError, httpError, redirected, timedOut, offline, failed

        var title: String {
            switch self {
            case .reachable: "可达"
            case .authentication: "需要认证"
            case .restricted: "访问受限"
            case .limited: "请求受限"
            case .serverError: "服务异常"
            case .httpError: "HTTP 异常"
            case .redirected: "已重定向"
            case .timedOut: "超时"
            case .offline: "未连接"
            case .failed: "检测失败"
            }
        }

        static func http(_ code: Int) -> Status {
            switch code {
            case 200..<400: .reachable
            case 401: .authentication
            case 403, 451: .restricted
            case 429: .limited
            case 500..<600: .serverError
            default: .httpError
            }
        }
    }

    let host: String
    let status: Status
    var httpStatus: Int?
    var milliseconds: Double?
    var exit: ClaudeExit?
    var detail: String?
    var id: String { host }

    var explanation: String {
        var parts = [status.title]
        if let httpStatus { parts.append("HTTP \(httpStatus)") }
        if let detail { parts.append(detail) }
        parts.append("耗时是本次 HTTPS 请求的总耗时，包含连接和响应，不是 ICMP Ping。可达不代表已登录或账户可用。")
        return parts.joined(separator: "\n")
    }
}

/// Net.Coffee's own rating. It is never presented as an Anthropic account/risk verdict.
struct ClaudeIPRisk: Decodable, Equatable {
    enum Kind: String {
        case residential = "家庭住宅"
        case datacenter = "机房"
        case mobile = "移动网络"
        case unknown = "未知"
        case conflicting = "信息不一致"
    }

    var ip: String?
    var trustScore: Double?
    var residential: Bool?
    var datacenter: Bool?
    var mobile: Bool?
    var vpn: Bool?
    var proxy: Bool?
    var tor: Bool?
    var crawler: Bool?
    var abuser: Bool?
    var asn: String?
    var organization: String?
    var country: String?
    var countryCode: String?
    var region: String?
    var city: String?

    var kind: Kind {
        if residential == true && datacenter == true { return .conflicting }
        if datacenter == true { return .datacenter }
        if mobile == true { return .mobile }
        if residential == true { return .residential }
        // A negative datacenter flag is not evidence of a household connection.
        return .unknown
    }

    var scoreLabel: String {
        guard let trustScore else { return "暂无评分" }
        switch trustScore {
        case 95...: return "极度纯净"
        case 80..<95: return "纯净"
        case 50..<80: return "良好"
        case 25..<50: return "中性"
        default: return "可疑"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case ip, trustScore = "trust_score", residential = "isResidential", datacenter = "is_datacenter"
        case mobile = "is_mobile", vpn = "is_vpn", proxy = "is_proxy", tor = "is_tor"
        case crawler = "is_crawler", abuser = "is_abuser", asn, organization = "asOrganization"
        case country, countryCode, region, city
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? {
            if let value = try? c.decode(String.self, forKey: key), !value.isEmpty { return value }
            if let value = try? c.decode(Int.self, forKey: key) { return String(value) }
            return nil
        }
        func flag(_ key: CodingKeys) -> Bool? { try? c.decode(Bool.self, forKey: key) }
        ip = text(.ip)
        let score = (try? c.decode(Double.self, forKey: .trustScore)) ?? text(.trustScore).flatMap(Double.init)
        trustScore = score.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
        residential = flag(.residential); datacenter = flag(.datacenter); mobile = flag(.mobile)
        vpn = flag(.vpn); proxy = flag(.proxy); tor = flag(.tor)
        crawler = flag(.crawler); abuser = flag(.abuser)
        asn = text(.asn); organization = text(.organization)
        country = text(.country); countryCode = text(.countryCode)
        region = text(.region); city = text(.city)
    }
}

struct ClaudeIPGeo: Decodable, Equatable {
    var country: String?
    var region: String?
    var city: String?
    var isp: String?
    var country_code: String?
}

struct ClaudeNetworkResult: Equatable {
    let checkedAt: Date
    let probes: [ClaudeProbe]
    var risk: ClaudeIPRisk?
    var geo: ClaudeIPGeo?
    var riskError: String?
    var riskFetchedAt: Date?
    var riskCached = false

    var exit: ClaudeExit? { probes.first { $0.host == "claude.ai" }?.exit }
    var apiExit: ClaudeExit? { probes.first { $0.host == "api.anthropic.com" }?.exit }
    var differingAPIExit: ClaudeExit? {
        guard let exit, let apiExit, !ClaudeExit.sameIP(exit.ip, apiExit.ip) else { return nil }
        return apiExit
    }

    var countryCode: String? { geo?.country_code ?? risk?.countryCode ?? exit?.countryCode }

    var country: String {
        if let value = geo?.country ?? risk?.country, !value.isEmpty { return value }
        guard let code = countryCode else { return "未知" }
        return Locale(identifier: "zh_CN").localizedString(forRegionCode: code.uppercased()) ?? code.uppercased()
    }

    var place: String {
        let parts = [geo?.region ?? risk?.region, geo?.city ?? risk?.city].compactMap { $0 }.filter { !$0.isEmpty }
        return ([country] + parts).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: " · ")
    }
}

/// Uses an ephemeral URLSession: no browser cookies, login tokens, analytics, or background WebView.
/// The endpoints are the same GET requests used by https://ip.net.coffee/claude/ (verified 2026-10-24).
actor ClaudeNetworkClient {
    static let targets = ["claude.ai", "api.anthropic.com", "www.anthropic.com"]
    private let session: URLSession
    private var cachedRisk: (ip: String, risk: ClaudeIPRisk, geo: ClaudeIPGeo?, date: Date)?
    private var riskRetryAfter: Date?
    private let dnsPollDelay: Duration
    private var dnsGeoCache: [String: (geo: ClaudeIPGeo, date: Date)] = [:]

    init(session: URLSession? = nil, dnsPollDelay: Duration = .milliseconds(1500)) {
        self.dnsPollDelay = dnsPollDelay
        if let session { self.session = session; return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: config)
    }

    func check() async -> ClaudeNetworkResult {
        async let web = Self.probe("claude.ai", session: session)
        async let api = Self.probe("api.anthropic.com", session: session)
        async let site = Self.probe("www.anthropic.com", session: session)
        let primary = await web
        let checkedAt = Date()
        var risk: ClaudeIPRisk?, geo: ClaudeIPGeo?, riskError: String?, fetchedAt: Date?
        var usedCache = false
        if let exit = primary.exit, !Task.isCancelled {
            if let cachedRisk, ClaudeExit.sameIP(cachedRisk.ip, exit.ip), Date().timeIntervalSince(cachedRisk.date) < 600 {
                risk = cachedRisk.risk; geo = cachedRisk.geo; fetchedAt = cachedRisk.date; usedCache = true
            } else if let riskRetryAfter, riskRetryAfter > Date() {
                riskError = "数据源请求受限，稍后自动重试"
            } else {
                async let riskReply: Result<ClaudeIPRisk, Error> = fetchRisk(exit.ip)
                async let geoReply: ClaudeIPGeo? = fetchGeo(exit.ip)
                let reply = await riskReply
                geo = await geoReply
                switch reply {
                case .success(let value):
                    // Never attach another exit's risk to the freshly detected IP.
                    if let returnedIP = value.ip, !ClaudeExit.sameIP(returnedIP, exit.ip) {
                        riskError = "数据源返回的 IP 与本次出口不一致"
                    } else {
                        risk = value; fetchedAt = Date()
                        cachedRisk = (exit.ip, value, geo, fetchedAt!)
                    }
                case .failure(let error):
                    if case DataError.http(429) = error {
                        riskRetryAfter = Date().addingTimeInterval(600)
                    }
                    riskError = Self.dataErrorText(error)
                }
            }
        }
        return await ClaudeNetworkResult(checkedAt: checkedAt, probes: [primary, api, site], risk: risk, geo: geo,
                                         riskError: riskError, riskFetchedAt: fetchedAt, riskCached: usedCache)
    }

    func checkDNS() async -> DNSLeakResult {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        async let first: Void = triggerDNS(token: token, index: 1)
        async let second: Void = triggerDNS(token: token, index: 2)
        _ = await (first, second)
        struct Payload: Decodable { let dns_servers: [String] }
        var lastError: String?
        var ips: [String] = []
        for attempt in 0..<2 {
            guard !Task.isCancelled else { return DNSLeakResult(checkedAt: Date(), error: "已取消") }
            do {
                try await Task.sleep(for: dnsPollDelay)
                let url = URL(string: "https://ip.net.coffee/api/dns/result/\(token)")!
                let (data, response) = try await session.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3))
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      response.url?.host == "ip.net.coffee", data.count < 256_000 else { throw DataError.invalid }
                let payload = try JSONDecoder().decode(Payload.self, from: data)
                ips = payload.dns_servers.filter(ClaudeExit.isIPAddress).reduce(into: []) { list, ip in
                    if !list.contains(where: { ClaudeExit.sameIP($0, ip) }) { list.append(ip) }
                }
                lastError = nil
                if !ips.isEmpty { break }
            } catch {
                if Task.isCancelled { return DNSLeakResult(checkedAt: Date(), error: "已取消") }
                lastError = "DNS 检测服务暂不可用，请稍后重试"
            }
            if attempt == 1 { break }
        }
        let geoByIP = await fetchDNSGeos(ips)
        let addresses = ips.map { ip in
            DNSObservedAddress(ip: ip, countryCode: geoByIP[ip]?.country_code,
                               country: geoByIP[ip]?.country, isp: geoByIP[ip]?.isp)
        }
        return DNSLeakResult(checkedAt: Date(), addresses: addresses, error: lastError)
    }

    /// The site's public batch endpoint covers every observed resolver, not just
    /// the first few. A mainland resolver at the end of the list must not be missed.
    private func fetchDNSGeos(_ ips: [String]) async -> [String: ClaudeIPGeo] {
        let now = Date()
        dnsGeoCache = dnsGeoCache.filter { now.timeIntervalSince($0.value.date) < 3600 }
        var result: [String: ClaudeIPGeo] = [:]
        for ip in ips { if let cached = dnsGeoCache[ip] { result[ip] = cached.geo } }
        let pending = ips.filter { result[$0] == nil }
        for offset in stride(from: 0, to: pending.count, by: 16) {
            guard !Task.isCancelled else { break }
            let chunk = Array(pending[offset..<min(offset + 16, pending.count)])
            do {
                var components = URLComponents(string: "https://ip.net.coffee/api/geoip-batch")!
                components.queryItems = [URLQueryItem(name: "ips", value: chunk.joined(separator: ","))]
                let request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      response.url?.host == "ip.net.coffee", data.count < 256_000 else { throw DataError.invalid }
                let payload = try JSONDecoder().decode([String: ClaudeIPGeo].self, from: data)
                for ip in chunk { if let geo = payload[ip] { result[ip] = geo } }
            } catch { /* Same individual-lookup fallback as the reference page. */ }
            let missing = chunk.filter { result[$0] == nil }
            await withTaskGroup(of: (String, ClaudeIPGeo?).self) { group in
                for ip in missing { group.addTask { (ip, await self.fetchGeo(ip)) } }
                for await (ip, geo) in group { if let geo { result[ip] = geo } }
            }
        }
        for (ip, geo) in result {
            if DNSObservedAddress(ip: ip, countryCode: geo.country_code).normalizedCountryCode != nil {
                dnsGeoCache[ip] = (geo, now)
            }
        }
        return result
    }

    private func triggerDNS(token: String, index: Int) async {
        guard !Task.isCancelled else { return }
        let url = URL(string: "https://\(token)-\(index).d.ip.net.coffee/pixel.gif")!
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        _ = try? await session.data(for: request)
    }

    private func fetchRisk(_ ip: String) async -> Result<ClaudeIPRisk, Error> {
        do { return .success(try await fetch(ClaudeIPRisk.self, path: "iprisk", ip: ip)) }
        catch { return .failure(error) }
    }

    private func fetchGeo(_ ip: String) async -> ClaudeIPGeo? {
        try? await fetch(ClaudeIPGeo.self, path: "geoip", ip: ip)
    }

    private enum DataError: Error { case http(Int), invalid }

    private func fetch<T: Decodable>(_ type: T.Type, path: String, ip: String) async throws -> T {
        let url = URL(string: "https://ip.net.coffee/api/\(path)/")!.appendingPathComponent(ip)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Status/1.4 NetworkDiagnostics", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DataError.invalid }
        guard http.statusCode == 200 else { throw DataError.http(http.statusCode) }
        guard response.url?.host == "ip.net.coffee", data.count < 256_000 else { throw DataError.invalid }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func dataErrorText(_ error: Error) -> String {
        switch error {
        case DataError.http(429): "数据源请求受限，稍后重试"
        case DataError.http(let code): "数据源暂不可用（HTTP \(code)）"
        case is DecodingError, DataError.invalid: "数据源格式变化，暂无法读取"
        case let error as URLError where error.code == .timedOut: "IP 情报查询超时"
        default: "IP 情报查询失败，请稍后重试"
        }
    }

    private static func probe(_ host: String, session: URLSession) async -> ClaudeProbe {
        var components = URLComponents(string: "https://\(host)/cdn-cgi/trace")!
        components.queryItems = [URLQueryItem(name: "status_probe", value: UUID().uuidString)]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let start = ContinuousClock.now
        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = start.duration(to: .now)
            let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            guard let http = response as? HTTPURLResponse else { return ClaudeProbe(host: host, status: .failed) }
            let sameHost = response.url?.host?.lowercased() == host.lowercased()
            let status: ClaudeProbe.Status = sameHost ? .http(http.statusCode) : .redirected
            let trace = sameHost && http.statusCode == 200
                ? ClaudeExit.parse(String(decoding: data, as: UTF8.self), host: host) : nil
            return ClaudeProbe(host: host, status: status, httpStatus: http.statusCode,
                               milliseconds: milliseconds, exit: trace,
                               detail: status == .reachable && trace == nil ? "已收到响应，但没有可验证的出口 IP。" : nil)
        } catch {
            let urlError = error as? URLError
            let status: ClaudeProbe.Status
            switch urlError?.code {
            case .timedOut: status = .timedOut
            case .notConnectedToInternet, .networkConnectionLost: status = .offline
            default: status = .failed
            }
            return ClaudeProbe(host: host, status: status, detail: urlError?.localizedDescription)
        }
    }
}

@MainActor
final class ClaudeNetworkMonitor: ObservableObject {
    @Published private(set) var result: ClaudeNetworkResult?
    @Published private(set) var isRefreshing = false
    @Published private(set) var dns: DNSLeakResult?
    @Published private(set) var webRTC: WebRTCLeakResult?
    private(set) var isEnabled = true
    private(set) var isDemo = false
    @Published var hideIP: Bool {
        didSet { defaults.set(hideIP, forKey: "claudeNetwork.hideIP") }
    }
    @Published var refreshInterval: Double {
        didSet {
            defaults.set(refreshInterval, forKey: "claudeNetwork.interval")
            restartAutoRefresh()
        }
    }

    private let defaults: UserDefaults
    private let client: ClaudeNetworkClient
    private let webRTCProbe = WebRTCLeakProbe()
    private let includeLeakChecks: Bool
    private var refreshTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var runID = UUID()
    private var visible = false

    init(defaults: UserDefaults = .standard, client: ClaudeNetworkClient = ClaudeNetworkClient(), includeLeakChecks: Bool = true) {
        self.includeLeakChecks = includeLeakChecks
        self.defaults = defaults
        self.client = client
        hideIP = defaults.bool(forKey: "claudeNetwork.hideIP")
        let saved = defaults.object(forKey: "claudeNetwork.interval") as? Double ?? 300
        refreshInterval = [0, 60, 300, 900].contains(saved) ? saved : 300
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            setVisible(false)
            cancelRefresh()
        }
    }

    func setVisible(_ value: Bool) {
        guard !isDemo, !value || isEnabled else { return }
        guard visible != value else { return }
        visible = value
        if value {
            if result == nil || Date().timeIntervalSince(result!.checkedAt) >= max(60, refreshInterval) { refresh() }
            restartAutoRefresh()
        } else {
            cancelRefresh()
        }
    }

    func refresh() {
        guard !isRefreshing, !isDemo, isEnabled else { return }
        isRefreshing = true
        dns = nil; webRTC = nil
        let id = UUID()
        runID = id
        let checks = includeLeakChecks
        let rtcProbe = webRTCProbe
        refreshTask = Task { [weak self, client] in
            guard !Task.isCancelled else { return }
            async let dnsReply: DNSLeakResult? = checks ? client.checkDNS() : nil
            async let udpReply: WebRTCLeakResult? = checks ? rtcProbe.collect() : nil
            let next = await client.check()
            guard !Task.isCancelled, let self, self.runID == id else { return }
            self.result = next
            let (dns, udp) = await (dnsReply, udpReply)
            guard !Task.isCancelled, self.runID == id else { return }
            self.dns = dns; self.webRTC = udp
            self.isRefreshing = false
            self.refreshTask = nil
        }
    }

    /// Only used by the explicit screenshot fixture mode; never fetched or persisted.
    func useDemo(_ value: ClaudeNetworkResult, dns sampleDNS: DNSLeakResult? = nil) {
        setVisible(false)
        isDemo = true
        result = value
        dns = sampleDNS ?? DNSLeakResult(checkedAt: Date(), addresses: [DNSObservedAddress(ip: "8.8.8.8", countryCode: "US", country: "United States", isp: "Google")])
        webRTC = WebRTCLeakResult(checkedAt: Date(), candidates: [WebRTCCandidate(address: "9.9.9.9", kind: "srflx", transport: "udp")], completed: true)
    }

    private func cancelRefresh() {
        autoRefreshTask?.cancel(); autoRefreshTask = nil
        refreshTask?.cancel(); refreshTask = nil
        runID = UUID()
        webRTCProbe.cancel()
        isRefreshing = false
    }

    private func restartAutoRefresh() {
        autoRefreshTask?.cancel()
        guard visible, refreshInterval > 0 else { autoRefreshTask = nil; return }
        let interval = refreshInterval
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval * 0.1)) }
                catch { return }
                guard !Task.isCancelled, let self, self.visible else { return }
                self.refresh()
            }
        }
    }
}
