import AppKit

/// Is there a newer Overterm? The latest GitHub release of `repository`
/// (private: asked through the user's gh), compared with this build's
/// version; its DMG downloaded into ~/Downloads and opened on request.
@MainActor
package final class UpdateChecker: ObservableObject {
    package static let shared = UpdateChecker()

    /// Where releases are published (the Release workflow).
    package static let repository = "Overcraft-hq/overterm"

    package struct Release: Equatable {
        package let version: String
        package let url: URL?
        package let dmgName: String?
    }

    package enum State: Equatable {
        case idle, checking
        case upToDate
        case available(Release)
        case downloading(Release)
        case downloaded(URL)
        case failed(String)
    }

    @Published package private(set) var state: State = .idle

    /// This build's version (CFBundleShortVersionString, i.e. VERSION).
    package var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }

    /// The newer release, if the last check found one.
    package var available: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    package func check() async {
        state = .checking
        do {
            let data = try await GitHub.run(["api", "repos/\(Self.repository)/releases/latest"], in: FileManager.default.homeDirectoryForCurrentUser)
            let release = try Self.parse(latest: data)
            state = Self.isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate
        } catch GitHub.Failure.failed(let message) where message.contains("404") || message.contains("Not Found") {
            state = .upToDate  // no release published yet
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Once a day at launch, when Settings allows it; quiet unless newer.
    package func checkIfDue(defaults: UserDefaults = AppEnvironment.defaults, now: Date = Date()) {
        guard Settings.shared.checkForUpdates, !AppEnvironment.isIsolated else { return }
        let key = FirstRun.lastUpdateCheckKey
        if let last = defaults.object(forKey: key) as? Date, now.timeIntervalSince(last) < 24 * 3600 { return }
        defaults.set(now, forKey: key)
        Task { await check() }
    }

    // MARK: What's new (SET-G2)

    /// The version last run, in the app's own defaults (an isolated run's
    /// are its own).
    package static let lastRunKey = "app.lastVersionRun"

    /// This version, on its first launch after an older one: the strip's
    /// "What's new in …" chip, until it is opened or put away.
    @Published package private(set) var whatsNew: String?

    /// At launch: the first run ever remembers this version and says
    /// nothing; a newer one than the last run offers its entry. The version
    /// is remembered when the chip is opened or dismissed, so a chip not
    /// yet seen is there at the next launch too.
    package func noteLaunch(defaults: UserDefaults = AppEnvironment.defaults) {
        let current = currentVersion
        let last = defaults.string(forKey: Self.lastRunKey)
        whatsNew = Self.whatsNew(lastRun: last, current: current)
        if whatsNew == nil, last != current { defaults.set(current, forKey: Self.lastRunKey) }
    }

    /// The chip opened or put away: not offered again for this version.
    package func dismissWhatsNew(defaults: UserDefaults = AppEnvironment.defaults) {
        guard let version = whatsNew else { return }
        defaults.set(version, forKey: Self.lastRunKey)
        whatsNew = nil
    }

    /// `current` when it is newer than `lastRun`; nil on a first run ever
    /// (no `lastRun`), the same version, or an older one run after a newer.
    package nonisolated static func whatsNew(lastRun: String?, current: String) -> String? {
        guard let lastRun, isNewer(current, than: lastRun) else { return nil }
        return current
    }

    /// The release's DMG into ~/Downloads (through gh: the repository is
    /// private), then opened — Finder mounts it; the app goes to Applications.
    package func download(_ release: Release, into folder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]) async {
        state = .downloading(release)
        do {
            _ = try await GitHub.run(
                ["release", "download", "v\(release.version)", "-R", Self.repository, "-p", "*.dmg", "-D", folder.path, "--clobber"],
                in: FileManager.default.homeDirectoryForCurrentUser, timeout: nil)
            let dmg = folder.appendingPathComponent(release.dmgName ?? "Overterm-\(release.version).dmg")
            state = .downloaded(dmg)
            if !AppEnvironment.isIsolated { NSWorkspace.shared.open(dmg) }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: Pure

    /// `gh api …/releases/latest`: tag_name "v1.2.3", html_url, assets[].name.
    package nonisolated static func parse(latest data: Data) throws -> Release {
        struct Asset: Decodable { let name: String }
        struct Latest: Decodable {
            let tag_name: String
            let html_url: String?
            let assets: [Asset]?
        }
        let latest = try JSONDecoder().decode(Latest.self, from: data)
        let version = latest.tag_name.hasPrefix("v") ? String(latest.tag_name.dropFirst()) : latest.tag_name
        return Release(
            version: version, url: latest.html_url.flatMap(URL.init), dmgName: latest.assets?.first { $0.name.hasSuffix(".dmg") }?.name)
    }

    /// SemVer's MAJOR.MINOR.PATCH, compared as numbers (1.10.0 > 1.9.0).
    package nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: ".").prefix(3).map { Int($0.prefix { $0.isNumber }) ?? 0 } + [0, 0, 0]
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<3 where a[i] != b[i] { return a[i] > b[i] }
        return false
    }
}

/// CHANGELOG.md, bundled in the app (make-app.sh copies it).
package enum Changelog {
    package static var bundled: String? {
        Bundle.main.url(forResource: "CHANGELOG", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// A version's lines: "## 1.14.0 — 2026-09-26" up to the next heading.
    package static func entry(for version: String, in text: String) -> [String] {
        var lines: [String] = []
        var inside = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                if inside { break }
                inside = line.dropFirst(3).split(separator: " ").first.map(String.init) == version
                continue
            }
            if inside, line.hasPrefix("- ") { lines.append(String(line.dropFirst(2))) }
        }
        return lines
    }
}
