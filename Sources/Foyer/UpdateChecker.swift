import SwiftUI
import AppKit

/// Checks GitHub Releases for a newer version. Sends nothing about the user: one anonymous request
/// for the repository's latest release. Automatic checks run at launch, at most once a day, and can
/// be turned off in Settings ▸ About.
@MainActor @Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    struct Release: Equatable {
        let version: String
        let page: URL
        let download: URL?
        let notes: String
    }

    enum Status: Equatable {
        case idle, checking, upToDate, noReleases
        case available(Release)
        case failed(String)
    }

    static let automaticKey = "updates.automatic"
    private static let lastCheckKey = "updates.lastCheck"
    private static let skippedKey = "updates.skippedVersion"

    private(set) var status: Status = .idle
    var lastChecked: Date? { UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date }

    /// At launch: only if enabled (default on) and the last check was over a day ago.
    func checkAutomaticallyIfDue() {
        let enabled = UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true
        guard enabled else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < 24 * 3600 { return }
        Task { await check(userInitiated: false) }
    }

    /// From the menu or Settings: always reports the result. Automatic checks speak up only when
    /// there's a newer version the user hasn't skipped.
    func check(userInitiated: Bool) async {
        guard status != .checking else { return }
        status = .checking
        let result = await Self.fetchLatest()
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        switch result {
        case .success(nil):
            status = .noReleases
            if userInitiated { inform("You're up to date", "\(AppInfo.name) \(AppInfo.version) is the latest version.") }
        case .success(let release?):
            if Self.isNewer(release.version, than: AppInfo.version) {
                status = .available(release)
                let skipped = UserDefaults.standard.string(forKey: Self.skippedKey)
                if userInitiated || skipped != release.version { offer(release) }
            } else {
                status = .upToDate
                if userInitiated { inform("You're up to date", "\(AppInfo.name) \(AppInfo.version) is the latest version.") }
            }
        case .failure(let error):
            status = .failed(error.localizedDescription)
            if userInitiated { inform("Couldn't check for updates", error.localizedDescription) }
        }
    }

    // MARK: Network

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let html_url: URL
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    /// nil when the repository has no published release yet.
    private static func fetchLatest() async -> Result<Release?, Error> {
        guard let url = URL(string: "https://api.github.com/repos/\(AppInfo.repository)/releases/latest") else {
            return .success(nil)
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("\(AppInfo.name)/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession(configuration: .ephemeral).data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { return .success(nil) }
            guard code == 200 else { throw URLError(.badServerResponse) }
            let r = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard !r.draft, !r.prerelease else { return .success(nil) }
            let zip = r.assets.first { $0.name.hasSuffix("-macOS-arm64.zip") }?.browser_download_url
            return .success(Release(version: normalized(r.tag_name), page: r.html_url, download: zip,
                                    notes: (r.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
        } catch {
            return .failure(error)
        }
    }

    // MARK: Versions

    static func normalized(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// Numeric, component-wise: 0.10.0 > 0.9.2; missing components count as 0.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            normalized(v).split(separator: "-")[0].split(separator: ".").map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: Alerts

    private func inform(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "\(AppInfo.name) \(release.version) is available"
        var info = "You have \(AppInfo.version)."
        if !release.notes.isEmpty {
            let notes = release.notes.count > 700 ? String(release.notes.prefix(700)) + "…" : release.notes
            info += "\n\n" + notes
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.download ?? release.page)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.version, forKey: Self.skippedKey)
        default:
            break
        }
    }
}

/// Settings ▸ About: automatic checks toggle, Check Now, and the last result.
struct UpdatesRow: View {
    @AppStorage(UpdateChecker.automaticKey) private var automatic = true
    @State private var checker = UpdateChecker.shared

    var body: some View {
        Toggle("Check for updates automatically", isOn: $automatic)
        LabeledContent {
            HStack(spacing: 10) {
                statusText.foregroundStyle(.secondary)
                if checker.status == .checking {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Check Now") { Task { await checker.check(userInitiated: true) } }
                }
            }
        } label: {
            Text("Updates")
        }
    }

    @ViewBuilder private var statusText: some View {
        switch checker.status {
        case .idle: if let d = checker.lastChecked { Text("Checked \(d.formatted(.relative(presentation: .named)))") }
        case .checking: Text("Checking…")
        case .upToDate, .noReleases: Text("Up to date")
        case .available(let r): Text("Version \(r.version) available")
        case .failed: Text("Couldn't check")
        }
    }
}
