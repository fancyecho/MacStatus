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
            ScrollView {
                VStack(spacing: 8) {
                    exitCard
                    trustCard
                    propertiesCard
                    availabilityCard
                    dnsCard
                    webRTCCard
                }
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(key: NetworkScrollMetricsKey.self,
                                               value: NetworkScrollMetrics(top: geo.frame(in: .named("network-detail-scroll")).minY,
                                                                           height: geo.size.height))
                    }
                }
                .padding(.horizontal, 1)
                .padding(.bottom, 3)
            }
            .coordinateSpace(name: "network-detail-scroll")
            .scrollIndicators(.hidden)
            .frame(height: viewportHeight)
            .mask {
                LinearGradient(stops: [
                    .init(color: detail.scrollTop < -1 ? .clear : .black, location: 0),
                    .init(color: .black, location: 12 / viewportHeight),
                    .init(color: .black, location: 1 - 12 / viewportHeight),
                    .init(color: detail.scrollTop + detail.contentHeight > viewportHeight + 1 ? .clear : .black, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
            .onPreferenceChange(NetworkScrollMetricsKey.self) { detail.update($0) }
        }
        .onAppear { diagnostics.setVisible(true) }
        .onDisappear { diagnostics.setVisible(false) }
    }

    private var toolbar: some View {
        HStack(spacing: 5) {
            Image(systemName: "network").foregroundStyle(Palette.down)
            Text(diagnostics.isDemo ? "Claude 网络诊断 · 演示" : "Claude 网络诊断").fontWeight(.semibold)
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
            .help("重新检测出口与连通性；同一 IP 的情报缓存 10 分钟")
            .accessibilityLabel("刷新网络诊断")
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 3)
        .frame(height: 24)
    }

    private var exitCard: some View {
        Tile(title: "Claude AI 出口", symbol: "globe", tint: Palette.down) {
            Text(diagnostics.result?.exit?.family ?? "HTTPS")
        } content: {
            HStack(alignment: .center, spacing: 4) {
                Text(displayIP(diagnostics.result?.exit?.ip))
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { diagnostics.hideIP.toggle() } label: {
                    Image(systemName: diagnostics.hideIP ? "eye.slash" : "eye")
                        .font(.system(size: 10))
                        .foregroundStyle(Ink.tertiary)
                }
                .buttonStyle(SubtleButtonStyle())
                .help(diagnostics.hideIP ? "显示 IP" : "隐藏 IP")
                .accessibilityLabel(diagnostics.hideIP ? "显示 IP 地址" : "隐藏 IP 地址")
                if let ip = diagnostics.result?.exit?.ip, !diagnostics.hideIP {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ip, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundStyle(Ink.tertiary)
                    }
                    .buttonStyle(SubtleButtonStyle())
                    .help("复制 Claude 出口 IP")
                    .accessibilityLabel("复制 Claude 出口 IP")
                }
            }
            .frame(minHeight: 25)
            Text(exitSubtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(Ink.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let result = diagnostics.result, let apiExit = result.differingAPIExit {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(Palette.disk)
                    Text("API 出口不同  \(displayIP(apiExit.ip))")
                        .monospacedDigit().textSelection(.enabled)
                }
                .font(.system(size: 10))
                .foregroundStyle(Ink.secondary)
                .help("api.anthropic.com 与 claude.ai 的 trace 返回了不同出口；属性和评分对应上方 claude.ai 出口。")
            }
            HStack(spacing: 4) {
                Circle().fill(diagnostics.isRefreshing ? Palette.down : Ink.tertiary).frame(width: 4, height: 4)
                Text(diagnostics.isRefreshing ? "正在检测…" : "claude.ai 实测")
                Spacer()
                if let date = diagnostics.result?.checkedAt {
                    Text(date, style: .time).monospacedDigit()
                }
            }
            .font(.system(size: 10))
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
        return Tile(title: "信任评分", symbol: "checkmark.shield", tint: NetworkStyle.trust) {
            Link("Net.Coffee", destination: URL(string: "https://ip.net.coffee/claude/")!)
                .foregroundStyle(Ink.tertiary)
                .help("查看第三方数据来源")
        } content: {
            HStack(alignment: .firstTextBaseline) {
                BigNumber(value: score.map { String(format: "%.0f", $0) } ?? "—", unit: "/ 100", size: 28)
                Spacer()
                Text(risk?.scoreLabel ?? "暂无评分")
                    .font(.system(size: 11, weight: .medium))
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
                        .help("本应用获取该 IP 情报的时间；数据源自身也可能使用缓存。")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(Ink.tertiary)
        }
        .help("Net.Coffee 第三方 IP 参考评分，沿用其 95 / 80 / 50 / 25 分档。不是 Anthropic 官方评级，也不保证账户安全或服务可用。")
    }

    private var propertiesCard: some View {
        let result = diagnostics.result
        let risk = result?.risk
        return Tile(title: "出口属性", symbol: "point.3.connected.trianglepath.dotted", tint: Palette.cpu) {
            Text(risk?.kind.rawValue ?? "未知")
                .foregroundStyle(risk?.kind == .residential ? Palette.gpu : Ink.secondary)
        } content: {
            NetworkInfoRow(label: "地区", value: result?.country ?? "未知")
            NetworkInfoRow(label: "城市", value: result?.geo?.city ?? risk?.city ?? "未知")
            NetworkInfoRow(label: "ASN", value: risk?.asn.map { $0.uppercased().hasPrefix("AS") ? $0 : "AS\($0)" } ?? "未知")
            NetworkInfoRow(label: "运营商", value: risk?.organization ?? result?.geo?.isp ?? "未知")
            Divider().opacity(0.25).padding(.vertical, 2)
            riskFlags
        }
        .help("属性来自 Net.Coffee 的 IP 情报。没有明确的住宅或机房标记时显示未知，不根据运营商名称猜测。")
    }

    private var availabilityCard: some View {
        Tile(title: "可用性检测", symbol: "waveform.path.ecg", tint: Palette.down) {
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
                        Text(probe?.status.title ?? (diagnostics.isRefreshing ? "检测中" : "未检测"))
                            .foregroundStyle(probe.map { NetworkStyle.statusColor($0.status) } ?? Ink.tertiary)
                        Text(probe?.milliseconds.map { String(format: "%.0f ms", $0) } ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(Ink.tertiary)
                            .frame(width: 49, alignment: .trailing)
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .help(probe?.explanation ?? "等待检测")
                }
            }
            Text("可达表示收到响应，登录与 API 调用仍需认证。")
                .font(.system(size: 9.5))
                .foregroundStyle(Ink.tertiary)
                .padding(.top, 2)
        }
    }

    private var riskFlags: some View {
        let risk = diagnostics.result?.risk
        return HStack(spacing: 6) {
            flag("VPN", risk?.vpn)
            flag("代理", risk?.proxy)
            flag("Tor", risk?.tor)
            flag("滥用", risk?.abuser)
        }
        .help("这些标记是情报源的检测结果；未检测到不表示绝对不存在，也不代表当前代理软件是否启用。")
    }

    private func flag(_ label: String, _ value: Bool?) -> some View {
        HStack(spacing: 3) {
            Circle().fill(value == nil ? Ink.tertiary : value == true ? Palette.disk : Palette.gpu)
                .frame(width: 4, height: 4)
            Text(label).foregroundStyle(Ink.secondary)
            Text(value.map { $0 ? "有" : "无" } ?? "—").foregroundStyle(value == true ? Palette.disk : Ink.tertiary)
        }
        .font(.system(size: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)：\(value.map { $0 ? "检测到" : "未检测到" } ?? "未知")")
    }

    private var viewportHeight: CGFloat {
        min(540, max(260, (NSScreen.main?.visibleFrame.height ?? 800) - 160))
    }

    private var intervalTitle: String {
        switch diagnostics.refreshInterval {
        case 0: "手动"
        case 60: "1 分钟"
        case 900: "15 分钟"
        default: "5 分钟"
        }
    }

    private var intervalMenu: some View {
        Menu {
            ForEach([0.0, 60, 300, 900], id: \.self) { interval in
                Button {
                    diagnostics.refreshInterval = interval
                } label: {
                    HStack {
                        Text(interval == 0 ? "关闭自动检测" : "每 \(Int(interval / 60)) 分钟")
                        if diagnostics.refreshInterval == interval { Image(systemName: "checkmark") }
                    }
                }
            }
            Divider()
            Link("数据来源：Net.Coffee", destination: URL(string: "https://ip.net.coffee/claude/")!)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock").font(.system(size: 9))
                Text(intervalTitle).font(.system(size: 10, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
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
        .accessibilityLabel("自动检测间隔")
        .accessibilityValue(intervalTitle)
        .help("自动检测：\(intervalTitle)。仅在此页打开时运行。结果对应 Status 的请求路径；按应用分流时可能不同于 Claude 客户端。")
    }

    private var dnsCard: some View {
        let sample = diagnostics.dns
        let assessment = sample?.assessment(comparedTo: diagnostics.result?.exit)
        return Tile(title: "DNS 泄露检测", symbol: "server.rack", tint: Palette.down) {
            Text("解析出口")
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
                        .font(.system(size: 10))
                    }
                    .padding(.vertical, 2)
                }
                if sample.addresses.count > 3 {
                    Button(detail.showAllDNS ? "收起解析出口" : "查看全部 \(sample.addresses.count) 个出口") {
                        detail.showAllDNS.toggle()
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Palette.down)
                    .buttonStyle(SubtleButtonStyle())
                }
            }
            Text("重点检查中国大陆 DNS 解析器。")
                .font(.system(size: 9.5)).foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(assessment?.detail ?? "通过随机域名查询及权威 DNS 回读，观察实际解析出口。")
    }

    private var webRTCCard: some View {
        let sample = diagnostics.webRTC
        let assessment = sample?.assessment(comparedTo: diagnostics.result?.exit)
        return Tile(title: "WebRTC UDP 检测", symbol: "point.3.filled.connected.trianglepath.dotted", tint: Palette.gpu) {
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
                    Text(sample.error ?? "未观测到公网 UDP 候选，无法确认是否存在泄露。")
                        .font(.system(size: 10.5)).foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("本次临时 WebKit 环境的检测结果。")
                .font(.system(size: 9.5)).foregroundStyle(Ink.tertiary)
        }
        .help(assessment?.detail ?? "建立无媒体的 WebRTC 数据通道，向 Google / Cloudflare STUN 收集 UDP ICE 候选。不请求摄像头或麦克风权限。")
    }

    private func leakSummary(_ name: String, assessment: LeakAssessment?) -> some View {
        HStack(spacing: 3) {
            Circle().fill(leakColor(assessment)).frame(width: 4, height: 4)
            Text(name)
            Text(assessment?.title ?? (diagnostics.isRefreshing ? "检测中" : "未检测"))
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .font(.system(size: 9.5, weight: .medium))
        .foregroundStyle(Ink.secondary)
        .help(assessment?.detail ?? "检测结果详情在下方，可向下滚动查看。")
    }

    private func leakStatus(_ assessment: LeakAssessment?) -> some View {
        HStack(spacing: 5) {
            Circle().fill(leakColor(assessment)).frame(width: 5, height: 5)
            Text(assessment?.title ?? (diagnostics.isRefreshing ? "正在检测…" : "未检测"))
                .foregroundStyle(leakColor(assessment))
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .medium))
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
        guard let value else { return diagnostics.isRefreshing ? "正在获取…" : "未获取到出口" }
        return diagnostics.hideIP ? "••••••••" : value
    }

    private var exitSubtitle: String {
        guard let result = diagnostics.result else { return "通过 claude.ai 获取本次请求的实际出口" }
        if result.exit != nil { return result.place }
        let probe = result.probes.first { $0.host == "claude.ai" }
        if probe?.status == .reachable { return "服务已响应，但未返回可验证的出口 IP" }
        return "\(probe?.status.title ?? "检测失败")，可点击刷新重试"
    }

    private var scoreCaption: String {
        guard let result = diagnostics.result else { return "第三方 IP 参考评分" }
        if result.exit == nil { return "未获取 Claude 出口，无法评分" }
        if let error = result.riskError { return error }
        if result.risk?.trustScore == nil { return "该出口暂无评分数据" }
        return result.riskCached ? "第三方参考 · 使用缓存" : "第三方参考 · 非官方评级"
    }
}

private struct NetworkInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(Ink.secondary).frame(width: 38, alignment: .leading)
            Spacer(minLength: 0)
            Text(value.isEmpty ? "未知" : value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .textSelection(.enabled)
                .help(value)
        }
        .font(.system(size: 11))
        .fixedSize(horizontal: false, vertical: true)
    }
}

private final class NetworkDetailState: ObservableObject {
    @Published var showAllDNS = false
    @Published private(set) var scrollTop: CGFloat = 0
    @Published private(set) var contentHeight: CGFloat = 0

    func update(_ metrics: NetworkScrollMetrics) {
        if abs(metrics.top - scrollTop) > 0.5 { scrollTop = metrics.top }
        if abs(metrics.height - contentHeight) > 0.5 { contentHeight = metrics.height }
    }
}

private struct NetworkScrollMetrics: Equatable {
    var top: CGFloat = 0
    var height: CGFloat = 0
}

private struct NetworkScrollMetricsKey: PreferenceKey {
    static let defaultValue = NetworkScrollMetrics()
    static func reduce(value: inout NetworkScrollMetrics, nextValue: () -> NetworkScrollMetrics) { value = nextValue() }
}
