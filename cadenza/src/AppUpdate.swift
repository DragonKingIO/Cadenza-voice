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

struct UpdateInfo: Equatable, Codable {
    var version: String
    var pageURL: URL
    /// The first lines of the release notes, as plain text.
    var notes: [String] = []
    /// "yyyy-MM-dd", when the release was published.
    var published: String? = nil
}

/// A 404 from GitHub's "latest release" address means the project has not published a release yet.
enum UpdateFetchError: Error, Equatable { case noRelease }

enum UpdateStatus: Equatable {
    case idle, checking, upToDate(String), available(UpdateInfo), notConfigured, noRelease, locked, failed
}

enum AppUpdate {
    /// "owner/repository" whose public releases are checked. Nothing is requested until the user presses Check or turns on weekly checks.
    static let repository = "DragonKingIO/Cadenza-voice"
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
        let published = (object["published_at"] as? String).map { String($0.prefix(10)) }.flatMap { $0.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? $0 : nil }
        return .available(UpdateInfo(version: tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag, pageURL: page, notes: notes(from: object["body"] as? String), published: published))
    }

    /// The first section of the release notes as short plain-text lines: no headings, tables, code or markup, at most
    /// eight lines. Release notes are untrusted text; they are only ever displayed, never interpreted.
    static func notes(from body: String?) -> [String] {
        guard let body = body else { return [] }
        var lines: [String] = []
        var inFence = false
        for raw in body.split(separator: "\n", omittingEmptySubsequences: true).prefix(300) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence || line.isEmpty || line.hasPrefix("|") || line.hasPrefix("<") { continue }
            if line.hasPrefix("#") { if lines.isEmpty { continue } else { break } }   // only the first section
            for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) { line = String(line.dropFirst(marker.count)); break }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
            guard line.count >= 2 else { continue }
            lines.append(line.count > 160 ? String(line.prefix(157)) + "…" : line)
            if lines.count == 8 { break }
        }
        return lines
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
    /// A newer release that has been found and not skipped. It is remembered across launches, so the prompt (menu bar item,
    /// badge on About) stays until the app is updated or the user skips that version.
    private(set) var available: UpdateInfo?
    @ObservationIgnored let defaults: UserDefaults
    private static let availableKey = "availableAppUpdate", skippedKey = "skippedAppUpdateVersion"
    var lastChecked: Date? { defaults.object(forKey: Self.lastKey) as? Date }
    /// Test hook: whether "never go online" forbids a check.
    @ObservationIgnored var isLocked: () -> Bool = { LocalOnlyMode.enabled }
    /// Test hook; the default performs one anonymous GET.
    @ObservationIgnored var fetch: (URL, @escaping (Result<Data, Error>) -> Void) -> Void = UpdateChecker.network
    @ObservationIgnored var repository = AppUpdate.repository
    @ObservationIgnored var override: URL? = AppUpdate.launchOverride
    @ObservationIgnored var currentVersion: AppVersion? = AppVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")

    /// Self-tests and previews must not read or change what the person's installed app has remembered.
    private static let inspectionRun = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--selftest") || $0.hasPrefix("--preview") || $0.hasPrefix("--check-") }
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? (Self.inspectionRun ? UserDefaults(suiteName: "local.cadenza.inspection.\(ProcessInfo.processInfo.processIdentifier)") ?? .standard : .standard)
        restore()
    }

    /// Automatic checks are opt-in. The setup wizard asks once; nothing is requested until the answer is yes.
    static var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    private func isShowable(_ info: UpdateInfo) -> Bool {
        guard let current = currentVersion, let version = AppVersion(info.version), !version.isPrerelease, version > current,
              info.pageURL.scheme == "https", info.pageURL.host == "github.com" else { return false }
        return defaults.string(forKey: Self.skippedKey) != info.version
    }

    /// Reads back what an earlier launch found. A release the app has since caught up with, or one that was skipped, is dropped.
    func restore() {
        guard let data = defaults.data(forKey: Self.availableKey), let info = try? JSONDecoder().decode(UpdateInfo.self, from: data), isShowable(info) else {
            available = nil
            if defaults.data(forKey: Self.availableKey) != nil, defaults.string(forKey: Self.skippedKey) == nil { defaults.removeObject(forKey: Self.availableKey) }
            return
        }
        available = info
        status = .available(info)
    }

    private func remember(_ info: UpdateInfo?) {
        if let info = info, let data = try? JSONEncoder().encode(info) { defaults.set(data, forKey: Self.availableKey) } else { defaults.removeObject(forKey: Self.availableKey) }
        available = info.flatMap { isShowable($0) ? $0 : nil }
    }

    /// Stops prompting for this version. A newer release prompts again.
    func skipAvailable() {
        guard case .available(let info) = status else { return }
        defaults.set(info.version, forKey: Self.skippedKey)
        available = nil
        status = .idle
    }

    func check() {
        guard status != .checking else { return }
        guard !isLocked() else { status = .locked; return }
        guard let url = AppUpdate.feedURL(repository: repository, override: override) else { status = .notConfigured; return }
        guard let current = currentVersion else { status = .failed; return }
        status = .checking
        fetch(url) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let data):
                    self.status = AppUpdate.evaluate(data, current: current)
                    switch self.status {
                    case .available(let info): self.remember(info)
                    case .upToDate: self.remember(nil)
                    default: break
                    }
                case .failure(let error):
                    if (error as? UpdateFetchError) == .noRelease { self.status = .noRelease; self.remember(nil) } else { self.status = .failed }
                }
                if self.status != .failed { self.defaults.set(Date(), forKey: Self.lastKey) }
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
            else if (response as? HTTPURLResponse)?.statusCode == 404 { completion(.failure(UpdateFetchError.noRelease)) }
            else { completion(.failure(error ?? URLError(.badServerResponse))) }
        }.resume()
    }
}

/// Target of the "update available" item in the menu bar menu: opens the release page in the browser.
final class UpdateMenuAction: NSObject {
    static let shared = UpdateMenuAction()
    @objc func open(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL, url.scheme == "https", url.host == "github.com" { NSWorkspace.shared.open(url) }
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
        case .available: return nil
        case .notConfigured: return L10n.tr("update.notConfigured")
        case .noRelease: return L10n.tr("update.noRelease")
        case .locked: return L10n.tr("update.locked")
        case .failed: return L10n.tr("update.failed")
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            if case .available(let info) = checker.status { availableCard(info) }
            HStack(spacing: 10) {
                Button(L10n.tr("update.check")) { checker.check() }.buttonStyle(.bordered).disabled(checker.status == .checking)
            }
            if let line = line {
                Text(line).font(.callout).foregroundStyle(checker.status == .failed || checker.status == .locked ? Color.orange : Color.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            Toggle(L10n.tr("update.auto"), isOn: Binding(get: { auto }, set: { auto = $0; UpdateChecker.autoCheck = $0 })).toggleStyle(.checkbox)
            Text(L10n.tr("update.privacy")).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    private func availableCard(_ info: UpdateInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint).imageScale(.large)
                Text(L10n.format("update.available", info.version)).font(.headline)
                Spacer(minLength: 0)
                if let published = info.published { Text(L10n.format("update.publishedOn", published)).font(.caption).foregroundStyle(.secondary) }
            }
            if !info.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("update.notesTitle")).font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(info.notes.enumerated()), id: \.offset) { _, note in
                        HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•").foregroundStyle(.secondary); Text(note).fixedSize(horizontal: false, vertical: true) }.font(.callout)
                    }
                }
            }
            HStack(spacing: 12) {
                Button(L10n.tr("update.open")) { NSWorkspace.shared.open(info.pageURL) }.buttonStyle(.borderedProminent)
                Button(L10n.tr("update.skip")) { checker.skipAvailable() }.buttonStyle(.borderless)
            }
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.25)))
    }
}
