import Foundation
import UserNotifications

/// Polls the GitHub Releases API for a newer version of NetWatch.
/// On discovery, fires a desktop notification via NetWatchNotificationManager (gated by settings).
@MainActor
class UpdateChecker: ObservableObject {
    @Published var latestVersion: String = ""
    @Published var updateAvailable: Bool = false
    @Published var releaseURL: URL?

    /// Injected by NetWatchApp.onAppear — routes update notifications through the gated manager.
    var notificationManager: NetWatchNotificationManager?

    private let repoAPI = URL(string: "https://api.github.com/repos/lswingrover/netwatch/releases/latest")!
    private var timer: Timer?

    // Version bundled into the running binary
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - Public

    func start(checkInterval: TimeInterval = 3600) {
        checkNow()
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkNow() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func checkNow() {
        Task {
            await fetchLatestRelease()
        }
    }

    // MARK: - Private

    private func fetchLatestRelease() async {
        var request = URLRequest(url: repoAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28",                  forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return }

        let htmlURL = (json["html_url"] as? String).flatMap { URL(string: $0) }
        let remoteVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

        guard isNewer(remote: remoteVersion, than: currentVersion) else { return }

        latestVersion = remoteVersion
        releaseURL    = htmlURL
        updateAvailable = true
        // Route through gated notification manager; fall back to direct banner if not injected
        if let nm = notificationManager {
            nm.notifyUpdateAvailable(version: remoteVersion)
        } else {
            await postFallbackNotification(version: remoteVersion, url: htmlURL)
        }
    }

    /// Returns true if `remote` is strictly greater than `local` using semver integer comparison.
    private func isNewer(remote: String, than local: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: ".").compactMap { Int($0) }
        }
        let r = parts(remote), l = parts(local)
        let count = max(r.count, l.count)
        for i in 0..<count {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }

    /// Fallback direct notification (used when notificationManager is not yet injected).
    private func postFallbackNotification(version: String, url: URL?) async {
        let content = UNMutableNotificationContent()
        content.title    = "NetWatch \(version) is available"
        content.body     = "A new version of NetWatch is available on GitHub."
        content.sound    = .default
        if let url = url {
            content.userInfo = ["releaseURL": url.absoluteString]
        }
        let req = UNNotificationRequest(
            identifier: "netwatch-update-\(version)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(req)
    }
}
