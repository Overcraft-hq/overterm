import Foundation

/// How bad Docker Scout says a vulnerability is, the worst first. Pure.
enum DockerScoutSeverity: Int, CaseIterable, Comparable, Identifiable, Sendable {
    case critical, high, medium, low, unspecified

    var id: Int { rawValue }

    /// Scout's word (`CRITICAL`, `cvssV3_severity`, a tag), as any case.
    /// GitHub says moderate, Debian negligible; anything else says nothing.
    init(word: String?) {
        switch (word ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "critical": self = .critical
        case "high": self = .high
        case "medium", "moderate": self = .medium
        case "low", "negligible": self = .low
        default: self = .unspecified
        }
    }

    /// SARIF's level, which Scout sets from the severity: error for
    /// critical and high alike, so it is the last thing asked.
    init?(level: String?) {
        switch (level ?? "").lowercased() {
        case "error": self = .high
        case "warning": self = .medium
        case "note": self = .low
        case "none": self = .unspecified
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .critical: "Critical"
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        case .unspecified: "Unspecified"
        }
    }

    /// What a short summary says it with: `1C 2H`.
    var letter: String {
        switch self {
        case .critical: "C"
        case .high: "H"
        case .medium: "M"
        case .low: "L"
        case .unspecified: "?"
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// The package a vulnerability is in, as a package URL says it
/// (`pkg:deb/debian/curl@7.74.0-1.3%2Bdeb11u1?os_distro=bullseye`) — or,
/// from an older Scout, `name version`. Pure.
struct DockerScoutPackage: Hashable, Sendable {
    var purl: String?
    /// deb, apk, rpm, npm, golang, maven, pypi…
    var type: String?
    /// The path before the name: `debian`, `@babel`, `golang.org/x`.
    var namespace: String?
    var name: String
    var version: String?

    /// `pkg:` then the type, the path and `@version`; the qualifiers (`?`)
    /// and the subpath (`#`) are dropped. Every part percent-decoded:
    /// `1%3A4.8.1-1` is the epoch's `1:4.8.1-1`. Nil for anything else.
    init?(purl: String) {
        let text = purl.trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("pkg:") else { return nil }
        var rest = Substring(text.dropFirst(4))
        if let hash = rest.firstIndex(of: "#") { rest = rest[..<hash] }
        if let question = rest.firstIndex(of: "?") { rest = rest[..<question] }
        rest = rest.drop { $0 == "/" }
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let type = rest[..<slash].lowercased()
        var path = rest[rest.index(after: slash)...]
        var version: String?
        // The version follows the last `@` — past the last `/`: an npm
        // scope left unencoded (`@babel/traverse`) isn't one.
        if let at = path.lastIndex(of: "@"), path[at...].firstIndex(of: "/") == nil {
            version = Self.decode(path[path.index(after: at)...])
            path = path[..<at]
        }
        let parts = path.split(separator: "/").map(Self.decode)
        guard !type.isEmpty, let name = parts.last, !name.isEmpty else { return nil }
        self.purl = text
        self.type = type
        self.namespace = parts.count > 1 ? parts.dropLast().joined(separator: "/") : nil
        self.name = name
        self.version = version.flatMap { $0.isEmpty ? nil : $0 }
    }

    init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }

    /// A result's `Package` line: a package URL, else Scout 0.6's
    /// `net 0.3.1-0.2022…`, split at the last space.
    static func from(message value: String?) -> DockerScoutPackage? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if value.lowercased().hasPrefix("pkg:") { return DockerScoutPackage(purl: value) }
        guard let space = value.lastIndex(of: " ") else { return DockerScoutPackage(name: value) }
        let name = value[..<space].trimmingCharacters(in: .whitespaces)
        let version = value[value.index(after: space)...].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? DockerScoutPackage(name: version) : DockerScoutPackage(name: name, version: version.isEmpty ? nil : version)
    }

    /// As its ecosystem names it: a distribution's package by its name
    /// (`curl`), Maven's `group:artifact`, the rest by their path
    /// (`@babel/traverse`, `golang.org/x/net`).
    var displayName: String {
        guard let namespace, !namespace.isEmpty else { return name }
        switch type {
        case "deb", "apk", "rpm", "alpm": return name
        case "maven": return namespace + ":" + name
        default: return namespace + "/" + name
        }
    }

    /// What Copy Package copies: its URL, else `name@version`.
    var reference: String { purl ?? (version.map { name + "@" + $0 } ?? name) }

    private static func decode(_ part: Substring) -> String { String(part).removingPercentEncoding ?? String(part) }
}

/// One vulnerability in one package. A CVE in two packages is two.
struct DockerScoutFinding: Identifiable, Hashable, Sendable {
    /// CVE-…, GHSA-…, GMS-…
    var vulnerability: String
    var severity: DockerScoutSeverity
    /// Scout's `security-severity`: the advisory's CVSS where it has one,
    /// else a 3.1 of its own — Scout's score, never said to be CVSS.
    var score: Double?
    var package: DockerScoutPackage
    /// The versions it is in: `<7.74.0-1.3+deb11u2`, `>=1.18.0-6.1`.
    var affected: String?
    /// Nil: no fix yet.
    var fixedIn: String?
    /// http or https only.
    var advisory: URL?
    var summary: String?
    /// The chance it is exploited in the next 30 days (FIRST's EPSS).
    var epss: Double?

    var id: String { vulnerability + " " + package.reference }
    var fixable: Bool { fixedIn != nil }
}

/// What a scan found: Scout's SARIF, read. Pure.
struct DockerScoutReport: Equatable, Sendable {
    /// In Scout's order, one per vulnerability and package.
    var findings: [DockerScoutFinding]
    /// Past `limit`, left out.
    var dropped = 0
    var scoutVersion: String?
    /// What Scout said it indexed, from its progress.
    var packagesIndexed: Int?

    static let limit = 5000

    func count(_ severity: DockerScoutSeverity) -> Int { findings.filter { $0.severity == severity }.count }
    var fixable: Int { findings.filter(\.fixable).count }
    /// The vulnerable packages, each once.
    var packages: Int { Set(findings.map(\.package.reference)).count }

    /// `1C 2H 5M`, the severities with none left out: an image's row.
    var shortSummary: String {
        let parts = DockerScoutSeverity.allCases.compactMap { severity -> String? in
            let count = count(severity)
            return count == 0 ? nil : "\(count)\(severity.letter)"
        }
        return parts.isEmpty ? "no CVEs" : parts.joined(separator: " ")
    }

    /// `1 critical, 2 high, 5 medium (3 fixable)`.
    var sentence: String {
        let parts = DockerScoutSeverity.allCases.compactMap { severity -> String? in
            let count = count(severity)
            return count == 0 ? nil : "\(count) \(severity.title.lowercased())"
        }
        return parts.isEmpty ? "No known vulnerabilities" : parts.joined(separator: ", ") + " (\(fixable) fixable)"
    }

    /// One line each — what Copy the List copies and an agent reads:
    /// `- CVE-2021-22945 critical 9.1: curl 7.74.0-1.3+deb11u1 (deb) — fixed in … — https://…`.
    /// `limit` lines at most, `characters` at most with the `… and N more`
    /// that ends them: the first are the worst, so it is the end that goes.
    func lines(_ findings: [DockerScoutFinding], limit: Int = 300, characters: Int = .max) -> String {
        // Room kept for the line that says how many more.
        let budget = characters == .max ? .max : characters - 24
        var lines: [String] = []
        var used = 0
        for finding in findings.prefix(limit) {
            var line = "- \(finding.vulnerability) \(finding.severity.title.lowercased())"
            if let score = finding.score, finding.severity != .unspecified { line += " " + Self.score(score) }
            line += ": " + finding.package.displayName
            if let version = finding.package.version { line += " " + version }
            if let type = finding.package.type { line += " (\(type))" }
            line += finding.fixedIn.map { " — fixed in \($0)" } ?? " — no fix yet"
            if let advisory = finding.advisory { line += " — " + advisory.absoluteString }
            used += line.count + 1
            guard used <= budget else { break }
            lines.append(line)
        }
        if findings.count > lines.count { lines.append("… and \(findings.count - lines.count) more") }
        return lines.joined(separator: "\n")
    }

    /// `9.1`, `10.0`.
    static func score(_ value: Double) -> String { String(format: "%.1f", value) }

    // MARK: Reading

    /// Scout's `cves --format sarif`, as defensively as it can be read:
    /// each field on its own, a wrong type ignored. Nil when it isn't a
    /// SARIF report at all.
    static func parse(_ output: String) -> DockerScoutReport? {
        guard let root = json(output) as? [String: Any], let runs = root["runs"] as? [Any] else { return nil }
        var report = DockerScoutReport(findings: [])
        var seen = Set<String>()
        for case let run as [String: Any] in runs {
            let driver = (run["tool"] as? [String: Any])?["driver"] as? [String: Any]
            if report.scoutVersion == nil, let version = string(driver?["version"]) { report.scoutVersion = version }
            // By position — a result's ruleIndex — and by id, the first of each.
            let rules: [[String: Any]?] = (driver?["rules"] as? [Any])?.map { $0 as? [String: Any] } ?? []
            var byID: [String: [String: Any]] = [:]
            for case let rule? in rules {
                if let id = string(rule["id"]), byID[id] == nil { byID[id] = rule }
            }
            for case let result as [String: Any] in run["results"] as? [Any] ?? [] {
                guard let finding = finding(result, rules: rules, byID: byID) else { continue }
                guard seen.insert(finding.id).inserted else { continue }
                if report.findings.count < limit { report.findings.append(finding) } else { report.dropped += 1 }
            }
        }
        return report
    }

    /// A result, with its rule: the message says what holds for this
    /// package — a rule covers every package a CVE is in, but its
    /// properties say only the first one's. They are the fallback.
    private static func finding(_ result: [String: Any], rules: [[String: Any]?], byID: [String: [String: Any]]) -> DockerScoutFinding? {
        let ruleID = string(result["ruleId"])
        var rule: [String: Any]?
        if let index = result["ruleIndex"] as? Int, rules.indices.contains(index), let candidate = rules[index],
            ruleID == nil || string(candidate["id"]) == ruleID
        {
            rule = candidate
        } else if let ruleID {
            rule = byID[ruleID]
        }
        guard let id = ruleID ?? string(rule?["id"]) else { return nil }
        let message = fields(string((result["message"] as? [String: Any])?["text"]) ?? "")
        let properties = rule?["properties"] as? [String: Any] ?? [:]
        let purls = (properties["purls"] as? [Any])?.compactMap(string) ?? []
        let tags = (properties["tags"] as? [Any])?.compactMap(string) ?? []

        // The first word that says a severity; one saying none passes on.
        var severity = DockerScoutSeverity.unspecified
        let words = [message["severity"], string(properties["cvssV3_severity"]), tags.first].compactMap { $0 }
        if let said = words.map(DockerScoutSeverity.init(word:)).first(where: { $0 != .unspecified }) {
            severity = said
        } else if let level = DockerScoutSeverity(level: string(result["level"])) {
            severity = level
        }
        let package =
            DockerScoutPackage.from(message: message["package"]) ?? purls.compactMap(DockerScoutPackage.init(purl:)).first
            ?? DockerScoutPackage(name: "unknown")
        let fixed = (message["fixed version"] ?? string(properties["fixed_version"])).flatMap { value -> String? in
            ["", "-", "not fixed", "none"].contains(value.lowercased()) ? nil : value
        }
        return DockerScoutFinding(
            vulnerability: id, severity: severity, score: score(properties["security-severity"]), package: package,
            affected: message["affected range"] ?? string(properties["affected_version"]), fixedIn: fixed,
            advisory: advisory(string(rule?["helpUri"]), id: id), summary: summary(of: rule, id: id),
            epss: message["epss score"].flatMap(Double.init))
    }

    /// `security-severity`: a string in SARIF, a number from some tools;
    /// 0–10 or nothing.
    private static func score(_ value: Any?) -> Double? {
        let number: Double? =
            switch value {
            case let text as String: Double(text.trimmingCharacters(in: .whitespaces))
            case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): number.doubleValue
            default: nil
            }
        guard let number, number.isFinite, (0...10).contains(number) else { return nil }
        return number
    }

    /// The rule's link, if it is a web page; else Scout's page for a CVE
    /// or a GitHub advisory.
    private static func advisory(_ value: String?, id: String) -> URL? {
        if let value, let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil {
            return url
        }
        guard id.hasPrefix("CVE-") || id.hasPrefix("GHSA-"),
            let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "https://scout.docker.com/v/" + encoded)
    }

    /// The advisory's words: the help text up to Scout's own trailer (a
    /// `---`, a table, 0.6's `Package :` lines), on one line, 400
    /// characters at most.
    private static func summary(of rule: [String: Any]?, id: String) -> String? {
        func text(_ key: String) -> String? { string((rule?[key] as? [String: Any])?["text"]) }
        var kept: [String] = []
        for line in (text("help") ?? "").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("---") || trimmed.hasPrefix("|") || trimmed.range(of: #"^Package\s*:"#, options: .regularExpression) != nil { break }
            kept.append(trimmed)
        }
        var summary = collapse(kept.joined(separator: " "))
        if summary.isEmpty, let short = text("shortDescription").map(collapse), short != id { summary = short }
        if summary.isEmpty, let full = text("fullDescription").map(collapse), full != id { summary = full }
        guard !summary.isEmpty else { return nil }
        return summary.count > 400 ? String(summary.prefix(399)) + "…" : summary
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A message's `  Key        : value` lines, by the key in lower case.
    private static func fields(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !value.isEmpty, fields[key] == nil { fields[key] = value }
        }
        return fields
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// The whole output as JSON; else from the first line that opens an
    /// object to a closing brace — text Scout printed after the report
    /// (scout-cli#78, "What's next") left out.
    private static func json(_ output: String) -> Any? {
        if let value = try? JSONSerialization.jsonObject(with: Data(output.utf8)) { return value }
        let start: String.Index
        if output.hasPrefix("{") {
            start = output.startIndex
        } else if let line = output.range(of: "\n{") {
            start = output.index(after: line.lowerBound)
        } else {
            return nil
        }
        let text = output[start...]
        // The last brace first; a few before it, for a brace in the trailer.
        var end = text.endIndex
        for _ in 0..<8 {
            guard let brace = text[..<end].lastIndex(of: "}") else { return nil }
            if let value = try? JSONSerialization.jsonObject(with: Data(text[...brace].utf8)) { return value }
            end = brace
        }
        return nil
    }
}

/// What the list shows of a report: the severities ticked, what can be
/// fixed, words in a finding's id or package. Kept per window, from one
/// image to the next. Pure.
struct DockerScoutFilter: Equatable, Sendable {
    var severities = Set(DockerScoutSeverity.allCases)
    var fixableOnly = false
    var text = ""

    var isEmpty: Bool { severities.count == DockerScoutSeverity.allCases.count && !fixableOnly && text.trimmingCharacters(in: .whitespaces).isEmpty }

    func matches(_ finding: DockerScoutFinding) -> Bool {
        guard severities.contains(finding.severity), !fixableOnly || finding.fixable else { return false }
        let words = text.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = [finding.vulnerability, finding.package.displayName, finding.package.purl ?? ""].joined(separator: " ").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    /// The findings it leaves, by severity — the worst first, none left
    /// empty; within one, the highest score first (none last), then by id
    /// and package.
    func groups(_ findings: [DockerScoutFinding]) -> [DockerScoutGroup] {
        let shown = findings.filter(matches)
        return DockerScoutSeverity.allCases.compactMap { severity in
            let these = shown.filter { $0.severity == severity }.sorted { a, b in
                switch (a.score, b.score) {
                case (let x?, let y?) where x != y: return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return (a.vulnerability, a.package.displayName) < (b.vulnerability, b.package.displayName)
                }
            }
            return these.isEmpty ? nil : DockerScoutGroup(severity: severity, findings: these)
        }
    }
}

struct DockerScoutGroup: Identifiable, Equatable, Sendable {
    var severity: DockerScoutSeverity
    var findings: [DockerScoutFinding]
    var id: Int { severity.rawValue }
}

/// Why a scan has no report, said as a person would want it. Pure.
enum DockerScoutFailure: Error, Equatable, Sendable {
    /// An isolated run, or a test: the real Scout is never run there.
    case isolated
    case noDocker
    case notInstalled
    case signedOut
    case notFound(String)
    case timedOut(minutes: Int)
    /// It answered, but not with a report.
    case unreadable
    /// Its own last words.
    case failed(String)

    var message: String {
        switch self {
        case .isolated: "This run doesn't run Docker Scout (an isolated run, or a test)."
        case .noDocker: "docker isn't on this Mac: Scout is its plugin."
        case .notInstalled: "Docker Scout isn't installed: it comes with Docker Desktop, or as a CLI plugin (github.com/docker/scout-cli)."
        case .signedOut: "Docker Scout needs you signed in to Docker: sign in once with docker login, or in Docker Desktop, then scan again."
        case .notFound(let image): "Scout couldn't find \(image) on the engine."
        case .timedOut(let minutes):
            "Scout didn't finish in \(minutes) minute\(minutes == 1 ? "" : "s"). A big image's first scan can take that long — run it in a tab to watch it."
        case .unreadable: "Scout answered with something other than a report — run it in a tab to see what it says."
        case .failed(let words): "Docker Scout: " + words
        }
    }

    /// What its exit and its words mean, in that order: a timeout, no
    /// plugin, signed out, no such image — else its last lines.
    static func classify(status: Int32, stderr: String, stdout: String, image: String, timeoutMinutes: Int) -> DockerScoutFailure {
        let text = DockerScout.clean(stderr + "\n" + stdout)
        let lower = text.lowercased()
        if status == -1, lower.contains("timed out") { return .timedOut(minutes: timeoutMinutes) }
        if lower.contains("is not a docker command") { return .notInstalled }
        if ["log in with your docker id", "docker login", "not logged in", "unauthorized"].contains(where: lower.contains) { return .signedOut }
        if ["image not found", "no such image", "not found in containerd store"].contains(where: lower.contains) { return .notFound(image) }
        let lines = DockerScout.lines(of: text).suffix(6)
        let words = lines.joined(separator: "\n")
        guard !words.isEmpty else { return .failed("docker scout exited with \(status)") }
        return .failed(words.count > 600 ? "…" + String(words.suffix(599)) : words)
    }
}

/// Docker Scout's `cves`, as the Vulnerabilities tab runs it. Pure.
enum DockerScout {
    /// Ten minutes: a big image's first scan indexes every package.
    static let timeout: TimeInterval = 600

    /// `docker scout cves --format sarif local://<name>`: the engine's
    /// own copy (`local://`, never a registry), as SARIF on stdout —
    /// nothing written to disk — for its own platform when known.
    static func arguments(for image: String, platform: String?) -> [String] {
        ["scout", "cves", "--format", "sarif"] + (platform.map { ["--platform", $0] } ?? []) + ["local://" + image]
    }

    /// Whether the real Scout may run: never in an isolated run (but for
    /// a scenario's stub) nor inside a test process — a scan sends the
    /// image's packages to Docker's service.
    nonisolated static var mayRunReal: Bool {
        DockerCLI.override != nil || (!AppEnvironment.isIsolated && NSClassFromString("XCTestCase") == nil)
    }

    /// Without ANSI's colours and cursor moves (CSI) and titles (OSC).
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"\u001B\][^\u0007\u001B]*(?:\u0007|\u001B\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\u001B\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\u001B[@-_]"#, with: "", options: .regularExpression)
    }

    /// The text's lines, as a terminal would leave them: split at each
    /// carriage return too (a spinner's frames), the glyphs Scout leads
    /// them with taken off, the empty ones and half a character left out.
    static func lines(of text: String) -> [String] {
        text.split(omittingEmptySubsequences: true) { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }.compactMap { line in
            let kept = line.drop { isGlyph($0) || $0.isWhitespace }
            var trimmed = kept.trimmingCharacters(in: .whitespaces)
            while trimmed.hasSuffix("\u{FFFD}") { trimmed.removeLast() }
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.allSatisfy({ isGlyph($0) || $0.isWhitespace }) ? nil : trimmed
        }
    }

    /// Scout's latest line — `SBOM of image already cached, 245 packages
    /// indexed` — 160 characters at most; nil while it said nothing.
    static func progress(in stderr: String) -> String? {
        guard let last = lines(of: clean(stderr)).last else { return nil }
        return last.count > 160 ? String(last.prefix(159)) + "…" : last
    }

    /// How many packages Scout says it indexed.
    static func indexedPackages(in text: String) -> Int? {
        let pattern = #"(\d+) packages indexed|Indexed (\d+) packages"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: range).last else { return nil }
        for group in 1..<match.numberOfRanges {
            if let found = Range(match.range(at: group), in: text), let count = Int(text[found]) { return count }
        }
        return nil
    }

    /// A spinner's frame (braille), a tick, a cross, a bullet.
    private static func isGlyph(_ character: Character) -> Bool {
        if "✓✔✗✘•·⨯".contains(character) { return true }
        return character.unicodeScalars.allSatisfy { (0x2800...0x28FF).contains($0.value) }
    }
}
