import SwiftUI

private enum NetworkStyle {
    static let trust = Palette.gpu

    static func scoreColor(_ value: Double?) -> Color {
        guard let value else { return Ink.tertiary }
        return value >= 80 ? Palette.gpu : value >= 50 ? Palette.down : value >= 25 ? Palette.disk : Palette.up
    }

    static func statusColor(_ status: ClaudeProbe.Status) -> Color {
        switch status {
        case .reachable: Palette.gpu
        case .authentication, .redirected: Palette.down
        case .restricted, .limited, .serverError, .httpError: Palette.disk
        case .timedOut, .offline, .failed: Palette.up
        }
    }
}

/// Independent of the system sampling loop; network probes run only while this page is visible.
struct NetworkDetailView: View {
    @EnvironmentObject private var diagnostics: ClaudeNetworkMonitor
    @StateObject private var detail = NetworkDetailState()

    var body: some View {
        VStack(spacing: 8) {
            toolbar
            PanelScrollView {
                VStack(spacing: 8) {
                    exitCard
                    trustCard
                    propertiesCard
                    availabilityCard
                    dnsCard
                    webRTCCard
                }
            }
        }
        .onAppear { diagnostics.setVisible(true) }
        .onDisappear { diagnostics.setVisible(false) }
    }

    private var toolbar: some View {
        HStack(spacing: 5) {
            Image(systemName: "network").foregroundStyle(Palette.down)
            Text(diagnostics.isDemo ? L("Claude 网络诊断 · 演示", "Claude Network · Demo") : L("Claude 网络诊断", "Claude Network")).fontWeight(.semibold)
            Spacer(minLength: 4)
            intervalMenu
            if diagnostics.isRefreshing {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 14, height: 14)
            }
            Button { diagnostics.refresh() } label: {
                Image(systemName: "arrow.clockwise").frame(width: 14, height: 14)
            }
            .buttonStyle(SubtleButtonStyle())
            .disabled(diagnostics.isRefreshing)
            .hint(L("重新检测出口与连通性；同一 IP 的情报缓存 10 分钟", "Check the exit and connectivity again. IP details for the same IP are cached for 10 minutes."))
            .accessibilityLabel(L("刷新网络诊断", "Refresh network diagnostics"))
        }
        .font(Typeface.ui(11.5, .medium))
        .padding(.horizontal, 3)
        .frame(height: 24)
    }

    private var exitCard: some View {
        Tile(title: L("Claude AI 出口", "Claude AI Exit"), symbol: "globe", tint: Palette.down) {
            Text(diagnostics.result?.exit?.family ?? "HTTPS")
        } content: {
            HStack(alignment: .center, spacing: 4) {
                Text(displayIP(diagnostics.result?.exit?.ip))
                    .font(Typeface.number(19))
                    .tracking(Typeface.tracking(19))
                    .monospacedDigit()
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { diagnostics.hideIP.toggle() } label: {
                    Image(systemName: diagnostics.hideIP ? "eye.slash" : "eye")
                        .font(Typeface.ui(10))
                        .foregroundStyle(Ink.tertiary)
                }
                .buttonStyle(SubtleButtonStyle())
                .hint(diagnostics.hideIP ? L("显示 IP", "Show IP") : L("隐藏 IP", "Hide IP"))
                .accessibilityLabel(diagnostics.hideIP ? L("显示 IP 地址", "Show IP address") : L("隐藏 IP 地址", "Hide IP address"))
                if let ip = diagnostics.result?.exit?.ip, !diagnostics.hideIP {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ip, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(Typeface.ui(10)).foregroundStyle(Ink.tertiary)
                    }
                    .buttonStyle(SubtleButtonStyle())
                    .hint(L("复制 Claude 出口 IP", "Copy Claude exit IP"))
                    .accessibilityLabel(L("复制 Claude 出口 IP", "Copy Claude exit IP"))
                }
            }
            .frame(minHeight: 25)
            Text(exitSubtitle)
                .font(Typeface.ui(10.5))
                .foregroundStyle(Ink.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let result = diagnostics.result, let apiExit = result.differingAPIExit {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(Palette.disk)
                    Text(L("API 出口不同  ", "API exit differs  ") + displayIP(apiExit.ip))
                        .monospacedDigit().textSelection(.enabled)
                }
                .font(Typeface.ui(10))
                .foregroundStyle(Ink.secondary)
                .hint(L("api.anthropic.com 与 claude.ai 的 trace 返回了不同出口；属性和评分对应上方 claude.ai 出口。", "api.anthropic.com and claude.ai traced different exits. The attributes and score below are for the claude.ai exit above."))
            }
            HStack(spacing: 4) {
                Circle().fill(diagnostics.isRefreshing ? Palette.down : Ink.tertiary).frame(width: 4, height: 4)
                Text(diagnostics.isRefreshing ? L("正在检测…", "Checking…") : L("claude.ai 实测", "measured via claude.ai"))
                Spacer()
                if let date = diagnostics.result?.checkedAt {
                    Text(date, style: .time).monospacedDigit()
                }
            }
            .font(Typeface.ui(10))
            .foregroundStyle(Ink.tertiary)
            HStack(spacing: 12) {
                leakSummary("DNS", assessment: diagnostics.dns?.assessment(comparedTo: diagnostics.result?.exit))
                leakSummary("UDP", assessment: diagnostics.webRTC?.assessment(comparedTo: diagnostics.result?.exit))
            }
        }
    }

    private var trustCard: some View {
        let risk = diagnostics.result?.risk
        let score = risk?.trustScore
        let color = NetworkStyle.scoreColor(score)
        return Tile(title: L("信任评分", "Trust Score"), symbol: "checkmark.shield", tint: NetworkStyle.trust) {
            Link("Net.Coffee", destination: URL(string: "https://ip.net.coffee/claude/")!)
                .foregroundStyle(Ink.tertiary)
                .hint(L("查看第三方数据来源", "View the third-party data source"))
        } content: {
            HStack(alignment: .firstTextBaseline) {
                BigNumber(value: score.map { String(format: "%.0f", $0) } ?? "—", unit: "/ 100", size: 28)
                Spacer()
                Text(risk?.scoreLabel ?? L("暂无评分", "No score"))
                    .font(Typeface.ui(11, .medium))
                    .foregroundStyle(color)
            }
            GeometryReader { geo in
                Capsule().fill(Color.primary.opacity(0.08))
                if let score, score > 0 {
                    Capsule().fill(LinearGradient(colors: [color.opacity(0.65), color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * score / 100)
                }
            }
            .frame(height: 6)
            .padding(.vertical, 2)
            HStack {
                Text(scoreCaption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 2)
                if let date = diagnostics.result?.riskFetchedAt {
                    Text(date, style: .time).monospacedDigit()
                        .hint(L("本应用获取该 IP 情报的时间；数据源自身也可能使用缓存。", "When Status fetched these IP details. The data source may cache too."))
                }
            }
            .font(Typeface.ui(10))
            .foregroundStyle(Ink.tertiary)
        }
        .hint(L("Net.Coffee 第三方 IP 参考评分，沿用其 95 / 80 / 50 / 25 分档。不是 Anthropic 官方评级，也不保证账户安全或服务可用。", "A third-party IP reference score from Net.Coffee, using its 95 / 80 / 50 / 25 bands. It is not an Anthropic rating and says nothing certain about account safety or availability."))
    }

    private var propertiesCard: some View {
        let result = diagnostics.result
        let risk = result?.risk
        return Tile(title: L("出口属性", "Exit Details"), symbol: "point.3.connected.trianglepath.dotted", tint: Palette.cpu) {
            Text(risk?.kind.title ?? L("未知", "Unknown"))
                .foregroundStyle(risk?.kind == .residential ? Palette.gpu : Ink.secondary)
        } content: {
            NetworkInfoRow(label: L("地区", "Region"), value: result?.country ?? L("未知", "Unknown"))
            NetworkInfoRow(label: L("城市", "City"), value: result?.geo?.city ?? risk?.city ?? L("未知", "Unknown"))
            NetworkInfoRow(label: "ASN", value: risk?.asn.map { $0.uppercased().hasPrefix("AS") ? $0 : "AS\($0)" } ?? L("未知", "Unknown"))
            NetworkInfoRow(label: L("运营商", "ISP"), value: risk?.organization ?? result?.geo?.isp ?? L("未知", "Unknown"))
            Divider().opacity(0.25).padding(.vertical, 2)
            riskFlags
        }
        .hint(L("属性来自 Net.Coffee 的 IP 情报。没有明确的住宅或机房标记时显示未知，不根据运营商名称猜测。", "These details come from Net.Coffee. Without a clear residential or data center flag it shows Unknown rather than guessing from the ISP name."))
    }

    private var availabilityCard: some View {
        Tile(title: L("可用性检测", "Reachability"), symbol: "waveform.path.ecg", tint: Palette.down) {
            Text("HTTPS")
        } content: {
            VStack(spacing: 7) {
                ForEach(ClaudeNetworkClient.targets, id: \.self) { host in
                    let probe = diagnostics.result?.probes.first { $0.host == host }
                    HStack(spacing: 4) {
                        Circle().fill(probe.map { NetworkStyle.statusColor($0.status) } ?? Ink.tertiary)
                            .frame(width: 5, height: 5)
                        Text(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text(probe?.status.title ?? (diagnostics.isRefreshing ? L("检测中", "Checking") : L("未检测", "Not checked")))
                            .foregroundStyle(probe.map { NetworkStyle.statusColor($0.status) } ?? Ink.tertiary)
                        Text(probe?.milliseconds.map { String(format: "%.0f ms", $0) } ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(Ink.tertiary)
                            .frame(width: 49, alignment: .trailing)
                    }
                    .font(Typeface.ui(10.5, .medium))
                    .hint(probe?.explanation ?? L("等待检测", "Waiting to check"))
                }
            }
            Text(L("可达表示收到响应，登录与 API 调用仍需认证。", "Reachable means it responded; signing in and API calls still need authentication."))
                .font(Typeface.ui(9.5))
                .foregroundStyle(Ink.tertiary)
                .padding(.top, 2)
        }
    }

    private var riskFlags: some View {
        let risk = diagnostics.result?.risk
        return HStack(spacing: 6) {
            flag("VPN", risk?.vpn)
            flag(L("代理", "Proxy"), risk?.proxy)
            flag("Tor", risk?.tor)
            flag(L("滥用", "Abuse"), risk?.abuser)
        }
        .hint(L("这些标记是情报源的检测结果；未检测到不表示绝对不存在，也不代表当前代理软件是否启用。", "These flags come from the data source. Not detected doesn't mean absent, and says nothing about whether your proxy app is on."))
    }

    private func flag(_ label: String, _ value: Bool?) -> some View {
        HStack(spacing: 3) {
            Circle().fill(value == nil ? Ink.tertiary : value == true ? Palette.disk : Palette.gpu)
                .frame(width: 4, height: 4)
            Text(label).foregroundStyle(Ink.secondary)
            Text(value.map { $0 ? L("有", "Yes") : L("无", "No") } ?? "—").foregroundStyle(value == true ? Palette.disk : Ink.tertiary)
        }
        .font(Typeface.ui(10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label + ": " + (value.map { $0 ? L("检测到", "detected") : L("未检测到", "not detected") } ?? L("未知", "unknown")))
    }

    private var intervalTitle: String {
        switch diagnostics.refreshInterval {
        case 0: L("手动", "Manual")
        case 60: L("1 分钟", "1 min")
        case 900: L("15 分钟", "15 min")
        default: L("5 分钟", "5 min")
        }
    }

    private var intervalMenu: some View {
        Menu {
            ForEach([0.0, 60, 300, 900], id: \.self) { interval in
                Button {
                    diagnostics.refreshInterval = interval
                } label: {
                    HStack {
                        Text(interval == 0 ? L("关闭自动检测", "Don't check automatically") : L("每 \(Int(interval / 60)) 分钟", "Every \(Int(interval / 60)) min"))
                        if diagnostics.refreshInterval == interval { Image(systemName: "checkmark") }
                    }
                }
            }
            Divider()
            Link(L("数据来源：Net.Coffee", "Data source: Net.Coffee"), destination: URL(string: "https://ip.net.coffee/claude/")!)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock").font(Typeface.ui(9))
                Text(intervalTitle).font(Typeface.ui(10, .medium))
                Image(systemName: "chevron.down").font(Typeface.ui(7, .semibold))
            }
            .foregroundStyle(Ink.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.035))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L("自动检测间隔", "Automatic check interval"))
        .accessibilityValue(intervalTitle)
        .hint(L("自动检测：\(intervalTitle)。仅在此页打开时运行。结果对应 Status 的请求路径；按应用分流时可能不同于 Claude 客户端。", "Automatic check: \(intervalTitle). Only runs while this page is open. Results follow Status's own route, which can differ from the Claude app if you route per app."))
    }

    private var dnsCard: some View {
        let sample = diagnostics.dns
        let assessment = sample?.assessment(comparedTo: diagnostics.result?.exit)
        return Tile(title: L("DNS 泄露检测", "DNS Leak Check"), symbol: "server.rack", tint: Palette.down) {
            Text(L("解析出口", "Resolvers"))
        } content: {
            leakStatus(assessment)
            if let sample, !sample.addresses.isEmpty {
                let addresses = sample.displayAddresses(comparedTo: diagnostics.result?.exit)
                let shown = detail.showAllDNS ? addresses : Array(addresses.prefix(3))
                ForEach(shown) { address in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayIP(address.ip))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 4) {
                            Text(address.regionLabel)
                                .foregroundStyle(address.normalizedCountryCode == "CN" ? Palette.up : Ink.secondary)
                            if let isp = address.isp, !isp.isEmpty {
                                Text("· \(isp)").foregroundStyle(Ink.tertiary).lineLimit(1)
                            }
                        }
                        .font(Typeface.ui(10))
                    }
                    .padding(.vertical, 2)
                }
                if sample.addresses.count > 3 {
                    Button(detail.showAllDNS ? L("收起解析出口", "Show fewer") : L("查看全部 \(sample.addresses.count) 个出口", "Show all \(sample.addresses.count) resolvers")) {
                        detail.showAllDNS.toggle()
                    }
                    .font(Typeface.ui(10.5, .medium))
                    .foregroundStyle(Palette.down)
                    .buttonStyle(SubtleButtonStyle())
                }
            }
            Text(L("重点检查中国大陆 DNS 解析器。", "Focuses on resolvers in mainland China."))
                .font(Typeface.ui(9.5)).foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .hint(assessment?.detail ?? L("通过随机域名查询及权威 DNS 回读，观察实际解析出口。", "Queries a random domain and reads it back from the authoritative DNS to see which resolvers are really used."))
    }

    private var webRTCCard: some View {
        let sample = diagnostics.webRTC
        let assessment = sample?.assessment(comparedTo: diagnostics.result?.exit)
        return Tile(title: L("WebRTC UDP 检测", "WebRTC UDP Check"), symbol: "point.3.filled.connected.trianglepath.dotted", tint: Palette.gpu) {
            Text("ICE / STUN")
        } content: {
            leakStatus(assessment)
            if let sample {
                ForEach(sample.publicIPs, id: \.self) { ip in
                    Text(displayIP(ip))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 2)
                }
                if sample.publicIPs.isEmpty {
                    Text(sample.error ?? L("未观测到公网 UDP 候选，无法确认是否存在泄露。", "No public UDP candidates were seen, so a leak can't be confirmed either way."))
                        .font(Typeface.ui(10.5)).foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(L("本次临时 WebKit 环境的检测结果。", "Result from a temporary WebKit environment."))
                .font(Typeface.ui(9.5)).foregroundStyle(Ink.tertiary)
        }
        .hint(assessment?.detail ?? L("建立无媒体的 WebRTC 数据通道，向 Google / Cloudflare STUN 收集 UDP ICE 候选。不请求摄像头或麦克风权限。", "Opens a media-free WebRTC data channel and gathers UDP ICE candidates from Google / Cloudflare STUN. No camera or microphone access is requested."))
    }

    private func leakSummary(_ name: String, assessment: LeakAssessment?) -> some View {
        HStack(spacing: 3) {
            Circle().fill(leakColor(assessment)).frame(width: 4, height: 4)
            Text(name)
            Text(assessment?.title ?? (diagnostics.isRefreshing ? L("检测中", "Checking") : L("未检测", "Not checked")))
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .font(Typeface.ui(9.5, .medium))
        .foregroundStyle(Ink.secondary)
        .hint(assessment?.detail ?? L("检测结果详情在下方，可向下滚动查看。", "Details are below; scroll down to see them."))
    }

    private func leakStatus(_ assessment: LeakAssessment?) -> some View {
        HStack(spacing: 5) {
            Circle().fill(leakColor(assessment)).frame(width: 5, height: 5)
            Text(assessment?.title ?? (diagnostics.isRefreshing ? L("正在检测…", "Checking…") : L("未检测", "Not checked")))
                .foregroundStyle(leakColor(assessment))
            Spacer(minLength: 0)
        }
        .font(Typeface.ui(11, .medium))
        .padding(.bottom, 2)
    }

    private func leakColor(_ assessment: LeakAssessment?) -> Color {
        switch assessment?.status {
        case .matching: Palette.gpu
        case .different: Palette.disk
        case .observed: Palette.down
        case .failed: Palette.up
        case .unknown, nil: Ink.tertiary
        }
    }

    private func displayIP(_ value: String?) -> String {
        guard let value else { return diagnostics.isRefreshing ? L("正在获取…", "Fetching…") : L("未获取到出口", "No exit found") }
        return diagnostics.hideIP ? "••••••••" : value
    }

    private var exitSubtitle: String {
        guard let result = diagnostics.result else { return L("通过 claude.ai 获取本次请求的实际出口", "Finds the real exit of this request via claude.ai") }
        if result.exit != nil { return result.place }
        let probe = result.probes.first { $0.host == "claude.ai" }
        if probe?.status == .reachable { return L("服务已响应，但未返回可验证的出口 IP", "It responded, but returned no exit IP that can be verified") }
        return (probe?.status.title ?? L("检测失败", "Failed")) + L("，可点击刷新重试", ", click refresh to retry")
    }

    private var scoreCaption: String {
        guard let result = diagnostics.result else { return L("第三方 IP 参考评分", "Third-party IP reference score") }
        if result.exit == nil { return L("未获取 Claude 出口，无法评分", "No Claude exit, so no score") }
        if let error = result.riskError { return error }
        if result.risk?.trustScore == nil { return L("该出口暂无评分数据", "No score for this exit yet") }
        return result.riskCached ? L("第三方参考 · 使用缓存", "Third-party · cached") : L("第三方参考 · 非官方评级", "Third-party · not an official rating")
    }
}

private struct NetworkInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(Ink.secondary).frame(width: 38, alignment: .leading)
            Spacer(minLength: 0)
            Text(value.isEmpty ? L("未知", "Unknown") : value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .textSelection(.enabled)
                .hint(value)
        }
        .font(Typeface.ui(11))
        .fixedSize(horizontal: false, vertical: true)
    }
}

private final class NetworkDetailState: ObservableObject {
    @Published var showAllDNS = false
}

