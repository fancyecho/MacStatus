import Foundation
import XCTest
@testable import Status

final class ClaudeNetworkTests: XCTestCase {
    private let ip = "203.0.113.42"

    func testTraceRequiresMatchingHostAndValidAddress() {
        XCTAssertNil(ClaudeExit.parse("ip=203.0.113.42\nh=example.com", host: "claude.ai"))
        XCTAssertNil(ClaudeExit.parse("ip=not-an-address\nh=claude.ai", host: "claude.ai"))
        XCTAssertNil(ClaudeExit.parse("<html>ip=203.0.113.42</html>", host: "claude.ai"))
        XCTAssertEqual(ClaudeExit.parse("ip=203.0.113.42\nh=claude.ai\nloc=us\n", host: "claude.ai"),
                       ClaudeExit(ip: ip, countryCode: "US"))
        XCTAssertEqual(ClaudeExit.parse("ip=2001:db8::1\nh=claude.ai", host: "claude.ai")?.family, "IPv6")
        XCTAssertTrue(ClaudeExit.sameIP("2001:db8::1", "2001:0db8:0:0:0:0:0:1"))
        XCTAssertFalse(ClaudeExit.sameIP("203.0.113.42", "203.0.113.43"))
    }

    func testRiskPreservesUnknownsAndDoesNotGuessResidential() throws {
        let unknown = try risk("{}")
        XCTAssertNil(unknown.trustScore)
        XCTAssertNil(unknown.proxy)
        XCTAssertEqual(unknown.kind, .unknown)
        XCTAssertEqual(try risk("{\"is_datacenter\":false}").kind, .unknown)
        XCTAssertEqual(try risk("{\"isResidential\":false}").kind, .unknown)
        XCTAssertEqual(try risk("{\"isResidential\":true}").kind, .residential)
        XCTAssertEqual(try risk("{\"is_datacenter\":true}").kind, .datacenter)
        XCTAssertEqual(try risk("{\"is_mobile\":true}").kind, .mobile)
        XCTAssertEqual(try risk("{\"isResidential\":true,\"is_datacenter\":true}").kind, .conflicting)
    }

    func testRiskToleratesNullsAndNumericStrings() throws {
        let decoded = try risk("{\"trust_score\":\"98\",\"asn\":7922,\"is_vpn\":null,\"is_proxy\":\"false\"}")
        XCTAssertEqual(decoded.trustScore, 98)
        XCTAssertEqual(decoded.asn, "7922")
        XCTAssertNil(decoded.vpn)
        XCTAssertNil(decoded.proxy)
        XCTAssertNil(try risk("{\"trust_score\":101}").trustScore)
        XCTAssertNil(try risk("{\"trust_score\":-1}").trustScore)
        XCTAssertNil(try risk("{\"trust_score\":\"NaN\"}").trustScore)
        XCTAssertEqual(try risk("{\"trust_score\":0}").trustScore, 0)
    }

    func testScoreLabelsMatchSourceThresholds() throws {
        for (score, label) in [(100, "极度纯净"), (95, "极度纯净"), (94, "纯净"), (80, "纯净"),
                               (79, "良好"), (50, "良好"), (49, "中性"), (25, "中性"), (0, "可疑")] {
            XCTAssertEqual(try risk("{\"trust_score\":\(score)}").scoreLabel, label)
        }
    }

    func testAvailabilityDoesNotTreatForbiddenAsAvailable() {
        XCTAssertEqual(ClaudeProbe.Status.http(200), .reachable)
        XCTAssertEqual(ClaudeProbe.Status.http(401), .authentication)
        XCTAssertEqual(ClaudeProbe.Status.http(403), .restricted)
        XCTAssertEqual(ClaudeProbe.Status.http(451), .restricted)
        XCTAssertEqual(ClaudeProbe.Status.http(429), .limited)
        XCTAssertEqual(ClaudeProbe.Status.http(503), .serverError)
        XCTAssertEqual(ClaudeProbe.Status.http(404), .httpError)
    }

    func testLiveFlowUsesClaudeTraceAndNeverSendsCredentials() async {
        let fixture = NetworkHTTPFixture()
        let client = ClaudeNetworkClient(session: fixture.session)
        let result = await client.check()
        XCTAssertEqual(result.exit?.ip, ip)
        XCTAssertEqual(result.risk?.trustScore, 96)
        XCTAssertEqual(result.risk?.kind, .residential)
        XCTAssertEqual(result.geo?.city, "Example City")
        XCTAssertEqual(result.probes.count, 3)
        XCTAssertTrue(fixture.requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertTrue(fixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
        XCTAssertTrue(fixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        XCTAssertFalse(fixture.requests.contains { $0.url?.path == "/api/session" })
    }

    func testRiskIsCachedForSameIPButProbesAreFresh() async {
        let fixture = NetworkHTTPFixture()
        let client = ClaudeNetworkClient(session: fixture.session)
        _ = await client.check()
        let second = await client.check()
        XCTAssertTrue(second.riskCached)
        XCTAssertEqual(fixture.requests.filter { $0.url?.path.hasPrefix("/api/iprisk/") == true }.count, 1)
        let probes = fixture.requests.filter { $0.url?.host == "claude.ai" }
        XCTAssertEqual(probes.count, 2)
        XCTAssertNotEqual(probes[0].url, probes[1].url)
    }

    func testExitChangeCannotReuseOldRisk() async {
        let fixture = NetworkHTTPFixture()
        let client = ClaudeNetworkClient(session: fixture.session)
        let first = await client.check()
        XCTAssertEqual(first.risk?.trustScore, 96)
        fixture.configure(ip: "203.0.113.99", riskStatus: 503)
        let next = await client.check()
        XCTAssertEqual(next.exit?.ip, "203.0.113.99")
        XCTAssertNil(next.risk)
        XCTAssertFalse(next.riskCached)
        XCTAssertNotNil(next.riskError)
    }

    func testRiskFailureKeepsExitAndConnectivity() async {
        let fixture = NetworkHTTPFixture()
        fixture.configure(riskStatus: 429)
        let client = ClaudeNetworkClient(session: fixture.session)
        let first = await client.check()
        XCTAssertEqual(first.exit?.ip, ip)
        XCTAssertEqual(first.probes[0].status, .reachable)
        XCTAssertNil(first.risk)
        XCTAssertTrue(first.riskError?.contains("受限") == true)
        _ = await client.check()
        XCTAssertEqual(fixture.requests.filter { $0.url?.path.hasPrefix("/api/iprisk/") == true }.count, 1)
    }

    func testBlockedTraceNeverQueriesAnUnrelatedDefaultExit() async {
        let fixture = NetworkHTTPFixture()
        fixture.configure(primaryStatus: 403)
        let result = await ClaudeNetworkClient(session: fixture.session).check()
        XCTAssertNil(result.exit)
        XCTAssertNil(result.risk)
        XCTAssertEqual(result.probes[0].status, .restricted)
        XCTAssertFalse(fixture.requests.contains { $0.url?.host == "ip.net.coffee" })
    }

    func testMismatchedIntelligenceIPIsRejected() async {
        let fixture = NetworkHTTPFixture()
        fixture.configure(returnedIP: "203.0.113.99")
        let result = await ClaudeNetworkClient(session: fixture.session).check()
        XCTAssertEqual(result.exit?.ip, ip)
        XCTAssertNil(result.risk)
        XCTAssertTrue(result.riskError?.contains("不一致") == true)
    }

    func testAPIExitMismatchIsExplicit() async {
        let fixture = NetworkHTTPFixture()
        fixture.configure(apiIP: "203.0.113.99")
        let result = await ClaudeNetworkClient(session: fixture.session).check()
        XCTAssertEqual(result.differingAPIExit?.ip, "203.0.113.99")
        XCTAssertEqual(result.risk?.ip, result.exit?.ip)
    }

    @MainActor
    func testOpeningOverviewDoesNotProbeAndClosingCancelsPublication() async throws {
        let fixture = NetworkHTTPFixture()
        let suite = "Status.NetworkTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = ClaudeNetworkMonitor(defaults: defaults, client: ClaudeNetworkClient(session: fixture.session), includeLeakChecks: false)
        XCTAssertEqual(monitor.refreshInterval, 300)
        XCTAssertTrue(fixture.requests.isEmpty)
        monitor.setVisible(true)
        XCTAssertTrue(monitor.isRefreshing)
        monitor.setVisible(false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(monitor.isRefreshing)
        XCTAssertNil(monitor.result)
    }

    @MainActor
    func testDemoIsMarkedAndDoesNotProbe() async {
        let fixture = NetworkHTTPFixture()
        let monitor = ClaudeNetworkMonitor(client: ClaudeNetworkClient(session: fixture.session), includeLeakChecks: false)
        monitor.useDemo(NetworkSnapshotFixture.make("ipv6")!)
        monitor.setVisible(true)
        monitor.refresh()
        XCTAssertTrue(monitor.isDemo)
        XCTAssertNotNil(monitor.result?.differingAPIExit)
        XCTAssertFalse(monitor.isRefreshing)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testPublicAddressesIncludeReal172AndIPv6ButExcludeLocalRanges() {
        for ip in ["8.8.8.8", "172.70.229.186", "172.253.223.208", "172.15.1.1", "172.32.1.1", "100.128.0.1", "2606:4700:4700::1111", "::ffff:8.8.8.8"] {
            XCTAssertTrue(PublicNetworkAddress.contains(ip), ip)
        }
        for ip in ["10.0.0.1", "172.16.1.1", "172.31.255.255", "192.168.1.1", "100.64.0.1", "100.127.255.255", "127.0.0.1", "169.254.1.1", "198.18.0.1", "203.0.113.1", "224.0.0.1", "::1", "fe80::1", "fd00::1", "2001:db8::1", "::ffff:192.168.1.1", "example.local"] {
            XCTAssertFalse(PublicNetworkAddress.contains(ip), ip)
        }
    }

    func testWebRTCNoCandidatesDoesNotClaimNoLeak() {
        let empty = WebRTCLeakResult(checkedAt: Date(), completed: true)
        XCTAssertEqual(empty.assessment(comparedTo: nil).status, .unknown)
        XCTAssertEqual(empty.assessment(comparedTo: nil).title, "未获取公网候选")
        let failed = WebRTCLeakResult(checkedAt: Date(), error: "STUN 不可用")
        XCTAssertEqual(failed.assessment(comparedTo: nil).status, .failed)
    }

    func testWebRTCComparesEveryPublicIPv4AndIPv6Candidate() {
        let sample = WebRTCLeakResult(checkedAt: Date(), candidates: [
            WebRTCCandidate(address: "192.168.1.2", kind: "host", transport: "udp"),
            WebRTCCandidate(address: "8.8.8.8", kind: "srflx", transport: "udp"),
            WebRTCCandidate(address: "2606:4700:4700::1111", kind: "host", transport: "udp"),
            WebRTCCandidate(address: "9.9.9.9", kind: "host", transport: "tcp")
        ], completed: true)
        XCTAssertEqual(sample.publicIPs, ["8.8.8.8", "2606:4700:4700::1111"])
        XCTAssertEqual(sample.assessment(comparedTo: ClaudeExit(ip: "8.8.8.8", countryCode: "US")).status, .different)
        XCTAssertEqual(sample.assessment(comparedTo: nil).status, .observed)
        let matching = WebRTCLeakResult(checkedAt: Date(), candidates: [WebRTCCandidate(address: "2001:4860:4860::8888", kind: "srflx", transport: "udp")])
        XCTAssertEqual(matching.assessment(comparedTo: ClaudeExit(ip: "2001:4860:4860:0:0:0:0:8888", countryCode: "US")).status, .matching)
    }

    func testDNSForeignCountriesDoNotCountAsMainlandLeak() {
        let exit = ClaudeExit(ip: "8.8.8.8", countryCode: "US")
        XCTAssertEqual(DNSLeakResult(checkedAt: Date()).assessment(comparedTo: exit).status, .unknown)
        let overseas = DNSLeakResult(checkedAt: Date(), addresses: [
            DNSObservedAddress(ip: "9.9.9.9", countryCode: "SG"),
            DNSObservedAddress(ip: "8.8.8.8", countryCode: "US"),
            DNSObservedAddress(ip: "1.1.1.1", countryCode: "DE")
        ])
        XCTAssertEqual(overseas.assessment(comparedTo: exit).title, "未检测到泄露")
        XCTAssertEqual(overseas.assessment(comparedTo: exit).status, .matching)
    }

    func testDNSMainlandResolverIsFlaggedEvenAmongForeignResolvers() {
        let sample = DNSLeakResult(checkedAt: Date(), addresses: [
            DNSObservedAddress(ip: "8.8.8.8", countryCode: "US"),
            DNSObservedAddress(ip: "114.114.114.114", countryCode: "cn")
        ])
        XCTAssertEqual(sample.assessment(comparedTo: nil).title, "检测到泄露")
        XCTAssertEqual(sample.displayAddresses(comparedTo: nil).first?.normalizedCountryCode, "CN")
        XCTAssertEqual(sample.addresses.last?.regionLabel, "中国大陆")
    }

    func testDNSUnknownRegionsDoNotBecomeAnAllClear() {
        for code: String? in [nil, "", "ZZ", "001"] {
            let sample = DNSLeakResult(checkedAt: Date(), addresses: [DNSObservedAddress(ip: "9.9.9.9", countryCode: code)])
            XCTAssertEqual(sample.assessment(comparedTo: nil).status, .unknown)
            XCTAssertEqual(sample.assessment(comparedTo: nil).title, "地区未完全确认")
        }
    }

    func testDNSHongKongMacaoAndTaiwanAreNotMainlandResolvers() {
        for code in ["HK", "MO", "TW"] {
            let sample = DNSLeakResult(checkedAt: Date(), addresses: [DNSObservedAddress(ip: "9.9.9.9", countryCode: code)])
            XCTAssertEqual(sample.assessment(comparedTo: nil).status, .matching)
        }
    }

    func testDNSUsesRandomDomainsAndKeepsAllValidatedResolvers() async {
        let fixture = NetworkHTTPFixture()
        fixture.configureDNS(["172.70.229.186", "8.8.8.8", "8.8.8.8", "not-an-ip", "2606:4700:4700::1111"])
        let result = await ClaudeNetworkClient(session: fixture.session, dnsPollDelay: .zero).checkDNS()
        XCTAssertEqual(result.addresses.map(\.ip), ["172.70.229.186", "8.8.8.8", "2606:4700:4700::1111"])
        let triggers = fixture.requests.filter { $0.url?.host?.hasSuffix(".d.ip.net.coffee") == true }
        XCTAssertEqual(triggers.count, 2)
        XCTAssertNotEqual(triggers.first?.url?.host, triggers.last?.url?.host)
        XCTAssertNil(result.error)
    }

    func testDNSPrioritizesMainlandThenKnownForeignThenUnknown() {
        let sample = DNSLeakResult(checkedAt: Date(), addresses: [
            DNSObservedAddress(ip: "8.8.8.8", countryCode: "US"),
            DNSObservedAddress(ip: "9.9.9.9", countryCode: "SG"),
            DNSObservedAddress(ip: "1.1.1.1"),
            DNSObservedAddress(ip: "114.114.114.114", countryCode: "CN")
        ])
        XCTAssertEqual(sample.displayAddresses(comparedTo: nil).map(\.ip),
                       ["114.114.114.114", "8.8.8.8", "9.9.9.9", "1.1.1.1"])
    }

    func testDNSChecksEveryResolverAndCachesOnlyItsRegionMetadata() async {
        let fixture = NetworkHTTPFixture()
        fixture.configureDNS((1...12).map { "8.8.8.\($0)" })
        fixture.configureDNSCountries(["8.8.8.12": "CN"])
        let client = ClaudeNetworkClient(session: fixture.session, dnsPollDelay: .zero)
        let first = await client.checkDNS()
        XCTAssertEqual(first.addresses.count, 12)
        XCTAssertTrue(first.addresses.allSatisfy { $0.normalizedCountryCode != nil })
        XCTAssertEqual(first.assessment(comparedTo: nil).status, .different)
        XCTAssertEqual(first.displayAddresses(comparedTo: nil).first?.ip, "8.8.8.12")
        _ = await client.checkDNS()
        XCTAssertEqual(fixture.requests.filter { $0.url?.path == "/api/geoip-batch" }.count, 1)
        XCTAssertEqual(fixture.requests.filter { $0.url?.host?.hasSuffix(".d.ip.net.coffee") == true }.count, 4)
    }

    func testDNSBatchFailureFallsBackToIndividualRegionLookups() async {
        let fixture = NetworkHTTPFixture()
        fixture.configureDNS(["8.8.8.8", "114.114.114.114"])
        fixture.configureDNSCountries(["114.114.114.114": "CN"], batchStatus: 503)
        let sample = await ClaudeNetworkClient(session: fixture.session, dnsPollDelay: .zero).checkDNS()
        XCTAssertEqual(sample.assessment(comparedTo: nil).title, "检测到泄露")
        XCTAssertEqual(fixture.requests.filter { $0.url?.path.hasPrefix("/api/geoip/") == true }.count, 2)
    }

    func testEmptyDNSResponseIsUnknown() async {
        let fixture = NetworkHTTPFixture()
        fixture.configureDNS([])
        let result = await ClaudeNetworkClient(session: fixture.session, dnsPollDelay: .zero).checkDNS()
        XCTAssertTrue(result.addresses.isEmpty)
        XCTAssertEqual(result.assessment(comparedTo: nil).status, .unknown)
    }

    @MainActor
    func testDiagnosticsSwitchPersistsWithoutChangingNetworkSamplingPreferences() {
        let suite = "Status.PreferenceTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        XCTAssertTrue(prefs.enableClaudeDiagnostics)
        prefs.page = .network
        let showNetwork = prefs.showNetwork
        let interval = prefs.interval
        prefs.enableClaudeDiagnostics = false
        XCTAssertEqual(prefs.page, .overview)
        XCTAssertEqual(prefs.showNetwork, showNetwork)
        XCTAssertEqual(prefs.interval, interval)
        XCTAssertFalse(Preferences(defaults: defaults).enableClaudeDiagnostics)
    }

    @MainActor
    func testDisablingDiagnosticsCancelsManualRefreshEvenWithoutVisiblePage() async throws {
        let fixture = NetworkHTTPFixture()
        let monitor = ClaudeNetworkMonitor(client: ClaudeNetworkClient(session: fixture.session), includeLeakChecks: false)
        monitor.refresh()
        XCTAssertTrue(monitor.isRefreshing)
        monitor.setEnabled(false)
        XCTAssertFalse(monitor.isRefreshing)
        monitor.setVisible(true)
        monitor.refresh()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(monitor.result)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    private func risk(_ json: String) throws -> ClaudeIPRisk {
        try JSONDecoder().decode(ClaudeIPRisk.self, from: Data(json.utf8))
    }
}

/// Isolated per-session fixture routing via a unique header; no real network requests.
private final class NetworkHTTPFixture {
    let id = UUID().uuidString
    let session: URLSession
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    private var ip = "203.0.113.42"
    private var returnedIP: String?
    private var apiIP: String?
    private var primaryStatus = 200
    private var riskStatus = 200
    private var dnsServers: [String] = []
    private var dnsCountries: [String: String] = [:]
    private var batchStatus = 200

    var requests: [URLRequest] { lock.withLock { captured } }

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NetworkStubProtocol.self]
        config.httpAdditionalHeaders = ["X-Status-Fixture": id]
        session = URLSession(configuration: config)
        NetworkStubProtocol.register(self, id: id)
    }

    deinit {
        session.invalidateAndCancel()
        NetworkStubProtocol.unregister(id)
    }

    func configureDNS(_ servers: [String]) { lock.withLock { dnsServers = servers } }
    func configureDNSCountries(_ countries: [String: String], batchStatus: Int = 200) {
        lock.withLock { dnsCountries = countries; self.batchStatus = batchStatus }
    }

    func configure(ip: String? = nil, returnedIP: String? = nil, apiIP: String? = nil,
                   primaryStatus: Int? = nil, riskStatus: Int? = nil) {
        lock.withLock {
            if let ip { self.ip = ip }
            if let returnedIP { self.returnedIP = returnedIP }
            if let apiIP { self.apiIP = apiIP }
            if let primaryStatus { self.primaryStatus = primaryStatus }
            if let riskStatus { self.riskStatus = riskStatus }
        }
    }

    func response(_ request: URLRequest) -> (Int, String) {
        lock.withLock {
            captured.append(request)
            let host = request.url!.host!
            if host == "ip.net.coffee" {
                if request.url!.path == "/api/geoip-batch" {
                    let ips = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ips" }?.value?.split(separator: ",").map(String.init) ?? []
                    let dict = Dictionary(uniqueKeysWithValues: ips.map { ($0, ["country_code": dnsCountries[$0] ?? "US", "country": "Example Country", "isp": "Example Resolver"]) })
                    return (batchStatus, String(data: try! JSONSerialization.data(withJSONObject: dict), encoding: .utf8)!)
                }
                if request.url!.path.hasPrefix("/api/dns/result/") {
                    return (200, String(data: try! JSONSerialization.data(withJSONObject: ["dns_servers": dnsServers]), encoding: .utf8)!)
                }
                if request.url!.path.hasPrefix("/api/iprisk/") {
                    return (riskStatus, "{\"ip\":\"\(returnedIP ?? ip)\",\"trust_score\":96,\"isResidential\":true,\"asn\":7922}")
                }
                let ip = request.url!.lastPathComponent
                return (200, "{\"country\":\"United States\",\"city\":\"Example City\",\"country_code\":\"\(dnsCountries[ip] ?? "US")\"}")
            }
            let code = host == "claude.ai" ? primaryStatus : 200
            return (code, "h=\(host)\nip=\(host == "api.anthropic.com" ? apiIP ?? ip : ip)\nloc=US\n")
        }
    }
}

private final class NetworkStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private final class WeakFixture {
        weak var value: NetworkHTTPFixture?
        init(_ value: NetworkHTTPFixture) { self.value = value }
    }
    private static var fixtures: [String: WeakFixture] = [:]

    static func register(_ value: NetworkHTTPFixture, id: String) { lock.withLock { fixtures[id] = WeakFixture(value) } }
    static func unregister(_ id: String) { _ = lock.withLock { fixtures.removeValue(forKey: id) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let fixture = Self.lock.withLock { Self.fixtures[request.value(forHTTPHeaderField: "X-Status-Fixture") ?? ""]?.value }
        guard let fixture else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let (code, body) = fixture.response(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
