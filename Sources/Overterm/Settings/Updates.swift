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

    // MARK: What's new (SET-G2, onboarding 7.9)

    /// The version whose chip was opened or put away, in the app's own
    /// defaults (onboarding 7.10): never offered again for it.
    package static let whatsNewSeenKey = "onboarding.whatsNewSeen"

    /// This version, on the first launch after an update: the strip's
    /// "What's new in …" chip, until it is opened or put away.
    @Published package private(set) var whatsNew: String?
    /// The version that ran before this launch, when it was an update with
    /// one remembered: Settings ▸ About lists every version's entry after it.
    /// nil otherwise — About then lists only this version's.
    @Published package private(set) var updatedFrom: String?
    /// The changelog this launch was decided by: the bundled one, or a
    /// scenario's. nil until `noteLaunch` — About then reads the bundled one.
    private var changelog: String?

    /// After the window shows, with what `FirstRun` decided: the chip only
    /// on an update, with `updates.whatsNew` on, for a version not seen yet
    /// whose changelog has lines since the last run. Writes nothing — a chip
    /// not opened is simply not there at the next launch, which is `.same`.
    package func noteLaunch(
        _ launch: FirstRun.Launch, changelog: String? = nil, enabled: Bool? = nil, defaults: UserDefaults = AppEnvironment.defaults
    ) {
        let text = changelog ?? Changelog.bundled
        self.changelog = text
        if case .upgraded(let from) = launch { updatedFrom = from } else { updatedFrom = nil }
        whatsNew = Self.whatsNew(
            launch: launch, seen: defaults.string(forKey: Self.whatsNewSeenKey), changelog: text, current: currentVersion,
            enabled: enabled ?? Settings.shared.whatsNewAfterUpdate)
    }

    /// The chip opened or put away: not offered again for this version.
    package func dismissWhatsNew(defaults: UserDefaults = AppEnvironment.defaults) {
        guard let version = whatsNew else { return }
        defaults.set(version, forKey: Self.whatsNewSeenKey)
        whatsNew = nil
    }

    /// What About lists under "What's new": every version's entry after the
    /// one run before this launch, through this one — the versions skipped
    /// too —; this one's alone when none is remembered.
    package var changes: [Changelog.Entry] {
        guard let text = changelog ?? Changelog.bundled else { return [] }
        return Changelog.entries(after: updatedFrom, through: currentVersion, in: text)
    }

    /// `current` when the chip is due: an update, the setting on, `current`
    /// not seen yet, and the changelog has lines for a version after the
    /// last run (only `current`'s when none is remembered — `from` nil).
    /// nil on a fresh install, the same version again, or an older one run
    /// after a newer. Pure.
    package nonisolated static func whatsNew(launch: FirstRun.Launch, seen: String?, changelog: String?, current: String, enabled: Bool) -> String? {
        guard enabled, case .upgraded(let from) = launch, seen != current, let changelog else { return nil }
        return Changelog.entries(after: from, through: current, in: changelog).isEmpty ? nil : current
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

    /// One version's lines.
    package struct Entry: Equatable, Sendable {
        package let version: String
        package let lines: [String]

        package init(version: String, lines: [String]) {
            self.version = version
            self.lines = lines
        }
    }

    /// Every version's lines after `last` through `current`, newest first,
    /// as the file has them — the versions an update skipped too. Versions
    /// compare as numbers, so a `last` the file doesn't name still counts;
    /// a version with no lines is left out. Only `current`'s when `last` is
    /// nil. Where `current` is the older one, nothing.
    package static func entries(after last: String?, through current: String, in text: String) -> [Entry] {
        guard let last else {
            let lines = entry(for: current, in: text)
            return lines.isEmpty ? [] : [Entry(version: current, lines: lines)]
        }
        var found: [Entry] = []
        var version: String?
        var lines: [String] = []
        func close() {
            guard let version, !lines.isEmpty, UpdateChecker.isNewer(version, than: last), !UpdateChecker.isNewer(version, than: current) else { return }
            found.append(Entry(version: version, lines: lines))
        }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                close()
                version = line.dropFirst(3).split(separator: " ").first.map(String.init)
                lines = []
                continue
            }
            if version != nil, line.hasPrefix("- ") { lines.append(String(line.dropFirst(2))) }
        }
        close()
        return found
    }

    /// Where About's "What's new" begins: Settings opens scrolled to it.
    package static let whatsNewAnchor = "about.whatsNew"
}
