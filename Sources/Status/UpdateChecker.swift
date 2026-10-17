import AppKit
import Foundation

/// 通过 GitHub Releases 检查新版本；有新版本时可以直接下载 DMG 到"下载"文件夹并打开
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    /// STATUS_UPDATE_REPO 仅用于测试（例如指向别的公开仓库验证解析逻辑）
    static let repository = ProcessInfo.processInfo.environment["STATUS_UPDATE_REPO"] ?? "fancyecho/MacStatus"
    static let repositoryURL = URL(string: "https://github.com/\(repository)")!
    static let authorURL = URL(string: "https://github.com/fancyecho")!

    struct Release: Equatable {
        let version: String
        let pageURL: URL
        let dmgURL: URL?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// STATUS_FAKE_VERSION 仅用于测试"发现新版本"的流程
    let currentVersion = ProcessInfo.processInfo.environment["STATUS_FAKE_VERSION"]
        ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    private let defaults = UserDefaults.standard
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    var autoCheck: Bool {
        get { defaults.object(forKey: "autoCheckUpdates") as? Bool ?? true }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: "autoCheckUpdates")
        }
    }

    var availableRelease: Release? {
        switch state {
        case .available(let release), .downloading(let release): release
        default: nil
        }
    }

    /// 打开面板时调用：开启了自动检查且距上次检查超过一天才会联网，不额外占用定时器
    func checkIfDue() {
        guard autoCheck, state != .checking else { return }
        let last = defaults.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > Self.checkInterval else { return }
        check()
    }

    func check() {
        guard state != .checking else { return }
        state = .checking
        Task {
            do {
                let release = try await fetchLatest()
                defaults.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                state = Self.isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate
            } catch {
                state = .failed("检查失败，请稍后再试")
            }
        }
    }

    /// 下载 DMG 到"下载"文件夹并打开，用户把新版拖进"应用程序"即可；没有 DMG 时打开发布页
    func downloadUpdate() {
        guard case .available(let release) = state else { return }
        guard let dmgURL = release.dmgURL else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        state = .downloading(release)
        Task {
            do {
                let (temporary, response) = try await URLSession.shared.download(from: dmgURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let destination = downloads.appendingPathComponent(dmgURL.lastPathComponent)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                NSWorkspace.shared.open(destination)
                state = .available(release)
            } catch {
                state = .available(release)
                NSWorkspace.shared.open(release.pageURL)
            }
        }
    }

    private func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Status/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }

        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let html_url: URL
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        let dmg = payload.assets.first { $0.name.lowercased().hasSuffix(".dmg") }?.browser_download_url
        return Release(version: version, pageURL: payload.html_url, dmgURL: dmg)
    }

    /// 按数字逐段比较版本号，例如 1.10.0 > 1.9.2
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
