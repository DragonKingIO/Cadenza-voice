import Foundation
import SwiftUI

// Update check for the app itself. It never installs anything: it only tells the user a newer release exists and
// opens that release page in the browser. Off by default for automatic checks; a manual check is always available.

/// Dotted numeric version with an optional pre-release suffix ("1.2.0", "v1.10", "2.0.0-beta.1").
struct AppVersion: Comparable, Equatable {
    let parts: [Int]
    let isPrerelease: Bool

    init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let main = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let core = main.first, !core.isEmpty else { return nil }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.count <= 4, numbers.allSatisfy({ $0 != nil && $0! >= 0 && $0! < 1_000_000 }) else { return nil }
        parts = numbers.map { $0! }
        isPrerelease = main.count > 1
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return a.isPrerelease && !b.isPrerelease // 1.0.0-beta < 1.0.0
    }
}

struct UpdateInfo: Equatable {
    var version: String
    var pageURL: URL
}

enum UpdateStatus: Equatable {
    case idle, checking, upToDate(String), available(UpdateInfo), notConfigured, failed
}

enum AppUpdate {
    /// "owner/repository" of the public release page. Empty until the project publishes releases.
    static let repository = ""
    static let interval: TimeInterval = 7 * 24 * 3600
    static let maxResponseBytes = 256 * 1024
    private static let releaseHost = "github.com"

    /// A test feed may only live on this Mac (loopback), so trying the update flow can never contact anyone.
    /// It is read from a launch argument (`--update-feed-override=http://127.0.0.1:8765/latest.json`) and never saved.
    static func loopbackOverride(_ text: String?) -> URL? {
        guard let text = text, let url = URL(string: text), url.scheme == "http", let host = url.host, ["127.0.0.1", "localhost"].contains(host), url.port != nil else { return nil }
        return url
    }
    static var launchOverride: URL? {
        loopbackOverride(ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--update-feed-override=") }.map { String($0.dropFirst("--update-feed-override=".count)) })
    }
    /// The address a check would request: the loopback test feed if one was given, otherwise the project's release page.
    static func feedURL(repository: String = AppUpdate.repository, override: URL? = AppUpdate.launchOverride) -> URL? {
        override ?? releasesURL(repository: repository)
    }

    static func releasesURL(repository: String = AppUpdate.repository) -> URL? {
        let parts = repository.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } }) else { return nil }
        return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
    }

    /// Reads GitHub's "latest release" JSON. Drafts and pre-releases are ignored, and the page link must stay on github.com.
    static func evaluate(_ data: Data, current: AppVersion) -> UpdateStatus {
        guard data.count <= maxResponseBytes, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = object["tag_name"] as? String, let latest = AppVersion(tag) else { return .failed }
        if object["draft"] as? Bool == true || object["prerelease"] as? Bool == true || latest.isPrerelease { return .upToDate(display(current)) }
        guard latest > current else { return .upToDate(display(current)) }
        guard let page = (object["html_url"] as? String).flatMap(URL.init(string:)), page.scheme == "https", page.host == releaseHost else { return .failed }
        return .available(UpdateInfo(version: tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag, pageURL: page))
    }

    static func display(_ v: AppVersion) -> String { v.parts.map(String.init).joined(separator: ".") }

    static func due(last: Date?, now: Date = Date(), interval: TimeInterval = AppUpdate.interval) -> Bool {
        guard let last = last else { return true }
        return now.timeIntervalSince(last) >= interval || last > now
    }
}

@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()
    private static let autoKey = "autoCheckAppUpdates", lastKey = "lastAppUpdateCheck"

    var status = UpdateStatus.idle
    var lastChecked: Date? { UserDefaults.standard.object(forKey: Self.lastKey) as? Date }
    /// Test hook; the default performs one anonymous GET.
    @ObservationIgnored var fetch: (URL, @escaping (Result<Data, Error>) -> Void) -> Void = UpdateChecker.network
    @ObservationIgnored var repository = AppUpdate.repository
    @ObservationIgnored var override: URL? = AppUpdate.launchOverride
    @ObservationIgnored var currentVersion: AppVersion? = AppVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")

    /// Automatic checks are opt-in.
    static var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    func check() {
        guard status != .checking else { return }
        guard let url = AppUpdate.feedURL(repository: repository, override: override) else { status = .notConfigured; return }
        guard let current = currentVersion else { status = .failed; return }
        status = .checking
        fetch(url) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let data): self.status = AppUpdate.evaluate(data, current: current)
                case .failure: self.status = .failed
                }
                if self.status != .failed { UserDefaults.standard.set(Date(), forKey: Self.lastKey) }
                Log.write("app-update-check result=\(self.status == .failed ? "failed" : "ok")")
            }
        }
    }

    /// Called once at launch. Does nothing unless the user turned automatic checks on and a week has passed.
    func checkOnLaunchIfDue() {
        guard !LocalOnlyMode.enabled, Self.autoCheck, AppUpdate.feedURL(repository: repository, override: override) != nil, AppUpdate.due(last: lastChecked) else { return }
        check()
    }

    private static func network(_ url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Cadenza-update-check", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        URLSession(configuration: configuration).dataTask(with: request) { data, response, error in
            if let data = data, (response as? HTTPURLResponse)?.statusCode == 200 { completion(.success(data)) }
            else { completion(.failure(error ?? URLError(.badServerResponse))) }
        }.resume()
    }
}

// MARK: - About page

struct UpdateSection: View {
    let checker = UpdateChecker.shared
    @State private var auto = UpdateChecker.autoCheck

    private var line: String? {
        switch checker.status {
        case .idle: return checker.lastChecked.map { L10n.format("update.last", $0.formatted(date: .abbreviated, time: .shortened)) }
        case .checking: return L10n.tr("update.checking")
        case .upToDate(let v): return L10n.format("update.upToDate", v)
        case .available(let info): return L10n.format("update.available", info.version)
        case .notConfigured: return L10n.tr("update.notConfigured")
        case .failed: return L10n.tr("update.failed")
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button(L10n.tr("update.check")) { checker.check() }.buttonStyle(.bordered).disabled(checker.status == .checking)
                if case .available(let info) = checker.status { Button(L10n.tr("update.open")) { NSWorkspace.shared.open(info.pageURL) }.buttonStyle(.borderedProminent) }
            }
            if let line = line { Text(line).font(.callout).foregroundStyle(checker.status == .failed ? Color.orange : Color.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true) }
            Toggle(L10n.tr("update.auto"), isOn: Binding(get: { auto }, set: { auto = $0; UpdateChecker.autoCheck = $0 })).toggleStyle(.checkbox)
            Text(L10n.tr("update.privacy")).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }
}
