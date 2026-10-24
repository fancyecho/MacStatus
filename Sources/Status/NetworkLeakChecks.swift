import Darwin
import Foundation
import WebKit

struct LeakAssessment: Equatable {
    enum Status { case matching, different, observed, unknown, failed }
    let status: Status
    let title: String
    let detail: String
}

struct DNSObservedAddress: Equatable, Identifiable {
    let ip: String
    var countryCode: String?
    var country: String?
    var isp: String?
    var id: String { ip }

    private static let countryCodes = Set(Locale.Region.isoRegions.map(\.identifier))

    var normalizedCountryCode: String? {
        let code = countryCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        return code.count == 2 && Self.countryCodes.contains(code) ? code : nil
    }

    var regionLabel: String {
        guard let code = normalizedCountryCode else { return "地区未知" }
        if code == "CN" { return "中国大陆" }
        if code == "HK" { return "中国香港" }
        if code == "MO" { return "中国澳门" }
        if code == "TW" { return "中国台湾" }
        return Locale(identifier: "zh_CN").localizedString(forRegionCode: code) ?? country ?? code
    }
}

struct DNSLeakResult: Equatable {
    let checkedAt: Date
    var addresses: [DNSObservedAddress] = []
    var error: String?

    func displayAddresses(comparedTo exit: ClaudeExit?) -> [DNSObservedAddress] {
        func rank(_ address: DNSObservedAddress) -> Int {
            guard let code = address.normalizedCountryCode else { return 2 }
            return code == "CN" ? 0 : 1
        }
        return addresses.enumerated().sorted {
            let left = rank($0.element), right = rank($1.element)
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }

    func assessment(comparedTo exit: ClaudeExit?) -> LeakAssessment {
        guard !addresses.isEmpty else {
            return LeakAssessment(status: error == nil ? .unknown : .failed, title: "未获取解析出口",
                                  detail: error ?? "未观测到解析记录，暂时无法判断是否存在中国大陆 DNS 泄露。")
        }
        // This page's criterion is mainland-China resolvers, not a mismatch
        // between two foreign countries (e.g. US HTTPS and Singapore DNS).
        if addresses.contains(where: { $0.normalizedCountryCode == "CN" }) {
            return LeakAssessment(status: .different, title: "检测到泄露",
                                  detail: "本次随机域名查询观测到了中国大陆 DNS 解析器，按本页的大陆 DNS 检测标准标记为泄露。相关解析器已置顶显示。")
        }
        let unknown = addresses.filter { $0.normalizedCountryCode == nil }.count
        if unknown > 0 {
            return LeakAssessment(status: .unknown, title: "地区未完全确认",
                                  detail: "已确认的解析器中未发现中国大陆 DNS；尚有 \(unknown) 个解析器地区未知，暂时无法排除。")
        }
        return LeakAssessment(status: .matching, title: "未检测到泄露",
                              detail: "本次观测的解析器均未被标记为中国大陆。美国、新加坡等境外地区之间的差异不计为大陆 DNS 泄露；结论仅对应此次检测。")
    }

}

struct WebRTCCandidate: Equatable, Decodable {
    let address: String
    let kind: String
    let transport: String
}

struct WebRTCLeakResult: Equatable {
    let checkedAt: Date
    var candidates: [WebRTCCandidate] = []
    var completed = false
    var error: String?

    var publicIPs: [String] {
        candidates.filter { $0.transport.lowercased() == "udp" && PublicNetworkAddress.contains($0.address) }
            .map(\.address).reduce(into: []) { list, ip in
                if !list.contains(where: { ClaudeExit.sameIP($0, ip) }) { list.append(ip) }
            }
    }

    func assessment(comparedTo exit: ClaudeExit?) -> LeakAssessment {
        guard !publicIPs.isEmpty else {
            return LeakAssessment(status: error == nil ? .unknown : .failed,
                                  title: error == nil ? "未获取公网候选" : "检测不可用",
                                  detail: error ?? "WebKit 隐私策略、UDP/STUN 限制或超时都可能导致没有公网候选，不能据此断言没有泄露。")
        }
        guard let exit else {
            return LeakAssessment(status: .observed, title: "已获取 UDP 出口", detail: "缺少 Claude 出口，无法比较 UDP 路径。")
        }
        if publicIPs.contains(where: { !ClaudeExit.sameIP($0, exit.ip) }) {
            return LeakAssessment(status: .different, title: "出口不同 · 可能泄露",
                                  detail: "WebRTC 观测到与本次 Claude HTTPS 出口不同的公网 UDP 地址。请结合分流规则判断；结果只代表 Status 的临时 WebKit 环境。")
        }
        return LeakAssessment(status: .matching, title: "出口一致",
                              detail: "已观测的公网 UDP 候选与本次 Claude 出口一致。只代表此次检测的候选，不代表其他浏览器或客户端。")
    }
}

/// Evaluate address ranges, not string prefixes: 172.253.x.x is public; only
/// 172.16/12 is private. IPv6 and IPv4-mapped IPv6 are handled explicitly.
enum PublicNetworkAddress {
    static func contains(_ value: String) -> Bool {
        var v4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            return withUnsafeBytes(of: v4) { publicV4(Array($0)) }
        }
        var v6 = in6_addr()
        guard value.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
            return publicV4(Array(bytes.suffix(4)))
        }
        guard bytes[0] & 0xe0 == 0x20 else { return false }
        return !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8)
    }

    private static func publicV4(_ b: [UInt8]) -> Bool {
        if b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 { return false }
        if b[0] == 100 && (64...127).contains(b[1]) { return false }
        if b[0] == 169 && b[1] == 254 { return false }
        if b[0] == 172 && (16...31).contains(b[1]) { return false }
        if b[0] == 192 && (b[1] == 168 || b[1] == 0 && (b[2] == 0 || b[2] == 2)) { return false }
        if b[0] == 198 && (b[1] == 18 || b[1] == 19 || b[1] == 51 && b[2] == 100) { return false }
        if b[0] == 203 && b[1] == 0 && b[2] == 113 { return false }
        return true
    }
}

/// A short-lived, nonpersistent WebKit document, created only for the actual
/// RTCPeerConnection ICE gathering. No remote page, trackers or media permission.
@MainActor
final class WebRTCLeakProbe: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<WebRTCLeakResult, Never>?
    private var timeout: Task<Void, Never>?
    private var runID = UUID()

    func collect() async -> WebRTCLeakResult {
        cancel()
        let id = UUID()
        runID = id
        guard !Task.isCancelled else { return WebRTCLeakResult(checkedAt: Date(), error: "已取消") }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                let config = WKWebViewConfiguration()
                config.websiteDataStore = .nonPersistent()
                let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
                view.navigationDelegate = self
                self.webView = view
                view.loadHTMLString("<!doctype html><html><head><meta charset='utf-8'></head><body></body></html>",
                                    baseURL: URL(string: "https://ip.net.coffee/"))
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(9)) } catch { return }
                    guard let self, self.runID == id else { return }
                    self.finish(WebRTCLeakResult(checkedAt: Date(), error: "WebRTC 检测超时，无法确认 UDP 出口"))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.runID == id else { return }
                self.cancel()
            }
        }
    }

    func cancel() {
        finish(WebRTCLeakResult(checkedAt: Date(), error: "已取消"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.callAsyncJavaScript(Self.script, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self, self.webView === webView else { return }
            switch result {
            case .success(let raw):
                guard let dict = raw as? [String: Any] else {
                    self.finish(WebRTCLeakResult(checkedAt: Date(), error: "WebRTC 返回格式不可用"))
                    return
                }
                let candidates = (dict["candidates"] as? [[String: String]] ?? []).compactMap { row -> WebRTCCandidate? in
                    guard let address = row["address"], ClaudeExit.isIPAddress(address) else { return nil }
                    return WebRTCCandidate(address: address, kind: row["kind"] ?? "", transport: row["transport"] ?? "")
                }
                self.finish(WebRTCLeakResult(checkedAt: Date(), candidates: candidates,
                                             completed: dict["completed"] as? Bool ?? false, error: dict["error"] as? String))
            case .failure:
                self.finish(WebRTCLeakResult(checkedAt: Date(), error: "当前 WebKit 环境无法完成 WebRTC 检测"))
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard self.webView === webView else { return }
        finish(WebRTCLeakResult(checkedAt: Date(), error: "WebRTC 检测环境加载失败"))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard self.webView === webView else { return }
        finish(WebRTCLeakResult(checkedAt: Date(), error: "WebRTC 检测环境加载失败"))
    }

    private func finish(_ result: WebRTCLeakResult) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        webView?.evaluateJavaScript("window.statusStop?.()", completionHandler: nil)
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        continuation.resume(returning: result)
    }

    private static let script = #"""
    return await new Promise(async resolve => {
        const candidates = [];
        let pc, timer, finished = false;
        const done = (completed, error) => {
            if (finished) return;
            finished = true;
            clearTimeout(timer);
            if (pc) { pc.onicecandidate = null; pc.close(); }
            delete window.statusStop;
            resolve({ candidates, completed, ...(error ? {error} : {}) });
        };
        window.statusStop = () => done(false, '已取消');
        if (typeof RTCPeerConnection !== 'function') { done(false, '当前 WebKit 不支持 WebRTC'); return; }
        timer = setTimeout(() => done(false), 5000);
        try {
            pc = new RTCPeerConnection({ iceServers: [
                {urls: 'stun:stun.l.google.com:19302'},
                {urls: 'stun:stun.cloudflare.com:3478'}
            ] });
            pc.onicecandidate = event => {
                if (!event.candidate) { done(true); return; }
                const c = event.candidate, fields = c.candidate.trim().split(/\s+/);
                candidates.push({ address: c.address || fields[4] || '',
                    kind: c.type || fields[7] || '', transport: c.protocol || fields[2] || '' });
            };
            pc.createDataChannel('status-network-check');
            await pc.setLocalDescription(await pc.createOffer());
            if (pc.iceGatheringState === 'complete') done(true);
        } catch (e) { done(false, 'WebRTC 无法收集候选：' + (e.name || '未知错误')); }
    });
    """#
}
