import XCTest

@testable import Terminus

/// The app's version: VERSION and CHANGELOG.md, Scripts/bump-version.sh, and
/// the git hooks that keep them in step with the code (.githooks; CLAUDE.md,
/// Commits). The script and the hooks run for real — on a scratch copy, in a
/// scratch repository — never on this checkout.
final class VersioningTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// SemVer's MAJOR.MINOR.PATCH, no leading zeros. No pre-releases.
    private static func isSemVer(_ version: String) -> Bool {
        version.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil
    }

    private static func numbers(_ version: String) -> [Int] { version.split(separator: ".").compactMap { Int($0) } }

    private static var today: String { isoDay.string(from: Date()) }

    private static var isoDay: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private struct Entry {
        var version: String
        var date: String
        var lines: [String] = []
    }

    /// CHANGELOG.md's entries, top first: `## 1.10.0 — 2026-09-26`, then its `- ` lines.
    private static func entries(_ changelog: String) -> [Entry] {
        var entries: [Entry] = []
        for line in changelog.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                let heading = line.dropFirst(3).components(separatedBy: " — ")
                entries.append(Entry(version: heading[0], date: heading.count == 2 ? heading[1] : ""))
            } else if line.hasPrefix("- "), !entries.isEmpty {
                entries[entries.count - 1].lines.append(String(line.dropFirst(2)))
            }
        }
        return entries
    }

    private func read(_ file: String, in dir: URL = root) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
    }

    private func write(_ text: String, to file: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: VERSION and CHANGELOG.md

    func testVersionIsSemVer() throws {
        let version = try read("VERSION")
        XCTAssertTrue(version.hasSuffix("\n") && !version.hasSuffix("\n\n"), "one line")
        XCTAssertTrue(Self.isSemVer(version.trimmingCharacters(in: .newlines)), "VERSION is \(version)")
    }

    func testTheChangelogsTopEntryIsVersion() throws {
        let top = try XCTUnwrap(Self.entries(try read("CHANGELOG.md")).first, "no entry")
        XCTAssertEqual(top.version, try read("VERSION").trimmingCharacters(in: .newlines))
    }

    /// The shape bump-version.sh reads and writes: `## X.Y.Z — YYYY-MM-DD`
    /// headings, newest first, each with its lines.
    func testTheChangelogIsNewestFirstAndEveryEntryHasLines() throws {
        let entries = Self.entries(try read("CHANGELOG.md"))
        XCTAssertGreaterThan(entries.count, 1)
        for entry in entries {
            XCTAssertTrue(Self.isSemVer(entry.version), "heading \(entry.version)")
            XCTAssertNotNil(Self.isoDay.date(from: entry.date), "\(entry.version): date \(entry.date)")
            XCTAssertFalse(entry.lines.isEmpty, "\(entry.version) has no lines")
        }
        for (newer, older) in zip(entries, entries.dropFirst()) {
            XCTAssertTrue(Self.numbers(older.version).lexicographicallyPrecedes(Self.numbers(newer.version)), "\(newer.version) above \(older.version)")
            XCTAssertGreaterThanOrEqual(newer.date, older.date, "\(newer.version) is dated before \(older.version)")
        }
        XCTAssertEqual(entries.last?.version, "1.0.0", "the original Terminus, as imported")
    }

    // MARK: Running tools

    /// Runs `tool` in `dir` with the environment the test controls: no git
    /// state inherited from a caller (a run from inside a hook has
    /// GIT_DIR & co), no SKIP_VERSION_CHECK, no global or system git config.
    @discardableResult
    private func run(_ tool: String, _ arguments: [String], in dir: URL, env: [String: String] = [:]) async throws -> String {
        let unset = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX", "SKIP_VERSION_CHECK"].flatMap { ["-u", $0] }
        let set = ["GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1"] + env.map { "\($0.key)=\($0.value)" }.sorted()
        return try await Git.run(URL(fileURLWithPath: "/usr/bin/env"), unset + set + [tool] + arguments, in: dir)
    }

    @discardableResult
    private func git(_ arguments: [String], in dir: URL, env: [String: String] = [:]) async throws -> String {
        try await run("/usr/bin/git", arguments, in: dir, env: env)
    }

    /// Runs `body`, which must fail; returns the failure: exit status and stderr.
    private func failure(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async -> GitError? {
        do {
            try await body()
            XCTFail("succeeded", file: file, line: line)
        } catch let error as GitError {
            return error
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
        return nil
    }

    private func scratchDirectory(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-\(name)-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: Scripts/bump-version.sh, on a scratch copy

    private static let olderChangelog = "# Changelog\n\nWhat changed.\n\n## 1.9.3 — 2026-09-01\n\n- older\n"

    /// Scripts/bump-version.sh, VERSION and CHANGELOG.md in a scratch directory (no git).
    private func scratchCopy(version: String, changelog: String = olderChangelog) throws -> URL {
        let dir = try scratchDirectory("bump")
        try write(try read("Scripts/bump-version.sh"), to: "Scripts/bump-version.sh", in: dir)
        try write(version + "\n", to: "VERSION", in: dir)
        try write(changelog, to: "CHANGELOG.md", in: dir)
        return dir
    }

    /// Always the system's bash 3.2, whatever PATH finds first.
    @discardableResult
    private func bump(_ arguments: [String], in dir: URL) async throws -> String {
        try await run("/bin/bash", [dir.appendingPathComponent("Scripts/bump-version.sh").path] + arguments, in: dir)
    }

    func testEachPartBumpsAndResetsTheOnesAfterIt() async throws {
        for (part, expected) in [("patch", "1.9.4"), ("minor", "1.10.0"), ("major", "2.0.0")] {
            let dir = try scratchCopy(version: "1.9.3")
            try await bump([part, "tabs: something"], in: dir)
            XCTAssertEqual(try read("VERSION", in: dir), expected + "\n", part)
            XCTAssertEqual(Self.entries(try read("CHANGELOG.md", in: dir)).first?.version, expected, part)
        }
    }

    func testTheNewEntryGoesOnTopDatedToday() async throws {
        let dir = try scratchCopy(version: "1.9.3")
        try await bump(["minor", "tabs: a new thing"], in: dir)
        XCTAssertEqual(
            try read("CHANGELOG.md", in: dir),
            "# Changelog\n\nWhat changed.\n\n## 1.10.0 — \(Self.today)\n\n- tabs: a new thing\n\n## 1.9.3 — 2026-09-01\n\n- older\n")
    }

    func testAChangelogWithoutEntriesGetsItsFirst() async throws {
        let dir = try scratchCopy(version: "0.9.0", changelog: "# Changelog\n")
        try await bump(["major", "app: first"], in: dir)
        XCTAssertEqual(try read("CHANGELOG.md", in: dir), "# Changelog\n\n## 1.0.0 — \(Self.today)\n\n- app: first\n")
    }

    /// Run again before committing, the script adds to the entry it made —
    /// counted from the committed VERSION, it never bumps twice. After the
    /// commit, the next run is the next version.
    func testASecondRunTheSameDayAddsALineToTheSameVersion() async throws {
        let dir = try scratchCopy(version: "1.9.3")
        try await git(["init", "-q", "-b", "main"], in: dir)
        try await git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"], in: dir)
        try await git(["add", "VERSION", "CHANGELOG.md"], in: dir)
        try await git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "1.9.3"], in: dir)

        try await bump(["patch", "diff: first"], in: dir)
        try await bump(["patch", "diff: second"], in: dir)
        try await bump(["patch", "diff: second"], in: dir)
        XCTAssertEqual(try read("VERSION", in: dir), "1.9.4\n")
        XCTAssertEqual(
            try read("CHANGELOG.md", in: dir),
            "# Changelog\n\nWhat changed.\n\n## 1.9.4 — \(Self.today)\n\n- diff: first\n- diff: second\n\n## 1.9.3 — 2026-09-01\n\n- older\n",
            "one entry, each line once")

        try await git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-am", "1.9.4"], in: dir)
        try await bump(["patch", "diff: third"], in: dir)
        XCTAssertEqual(try read("VERSION", in: dir), "1.9.5\n")
        XCTAssertEqual(Self.entries(try read("CHANGELOG.md", in: dir)).map(\.version), ["1.9.5", "1.9.4", "1.9.3"])
    }

    func testBadInputChangesNothing() async throws {
        let dir = try scratchCopy(version: "1.9.3")
        for arguments in [[], ["patch"], ["mayor", "x"], ["patch", "   "], ["patch", "two\nlines"], ["patch", "a", "b"]] {
            let error = await failure { try await self.bump(arguments, in: dir) }
            XCTAssertEqual(error?.status, 2, "\(arguments)")
            XCTAssertTrue(error?.stderr.contains("usage: Scripts/bump-version.sh major|minor|patch") == true, "\(arguments): \(error?.stderr ?? "")")
        }
        XCTAssertEqual(try read("VERSION", in: dir), "1.9.3\n")
        XCTAssertEqual(try read("CHANGELOG.md", in: dir), Self.olderChangelog)

        for version in ["1.9", "v1.9.3", "1.09.3", ""] {
            let bad = try scratchCopy(version: version)
            let error = await failure { try await self.bump(["patch", "x"], in: bad) }
            XCTAssertEqual(error?.status, 1, version)
            XCTAssertTrue(error?.stderr.contains("MAJOR.MINOR.PATCH") == true, "\(version): \(error?.stderr ?? "")")
            XCTAssertEqual(try read("VERSION", in: bad), version + "\n")
            XCTAssertEqual(try read("CHANGELOG.md", in: bad), Self.olderChangelog)
        }
    }

    // MARK: .githooks, in a scratch repository

    /// A repository on this checkout's hooks, one commit in: VERSION 1.0.0,
    /// a source file, a doc and a test.
    private func scratchRepo() async throws -> URL {
        let repo = try scratchDirectory("hooks")
        try await git(["init", "-q", "-b", "main"], in: repo)
        for (key, value) in [
            ("user.name", "t"), ("user.email", "t@t"), ("commit.gpgsign", "false"), ("tag.gpgsign", "false"),
            ("core.hooksPath", Self.root.appendingPathComponent(".githooks").path),
        ] {
            try await git(["config", key, value], in: repo)
        }
        try write("1.0.0\n", to: "VERSION", in: repo)
        try write("let a = 1\n", to: "Sources/Terminus/App.swift", in: repo)
        try write("# Doc\n", to: "docs/doc.md", in: repo)
        try write("// test\n", to: "Tests/TerminusTests/ATests.swift", in: repo)
        try await git(["add", "-A"], in: repo)
        try await git(["commit", "-q", "-m", "init"], in: repo)
        return repo
    }

    private func commits(in repo: URL) async throws -> Int {
        Int(try await git(["rev-list", "--count", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func tags(in repo: URL) async throws -> [String] {
        try await git(["tag", "--list"], in: repo).split(separator: "\n").map(String.init)
    }

    /// The refusal lists the app paths it found — each kind — and nothing else.
    func testAnAppChangeWithoutVersionIsRefused() async throws {
        let repo = try await scratchRepo()
        let app = ["Sources/Terminus/App.swift", "Resources/Icon.svg", "Scripts/tool.sh", "Package.swift", "Makefile", "mise.toml"]
        for path in app + ["docs/doc.md"] { try write("changed\n", to: path, in: repo) }
        try await git(["add", "-A"], in: repo)
        let error = await failure { try await self.git(["commit", "-q", "-m", "app: no bump"], in: repo) }
        let listed = (error?.stderr ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for path in app { XCTAssertTrue(listed.contains(path), "\(path) named: \(error?.stderr ?? "")") }
        XCTAssertFalse(listed.contains("docs/doc.md"), "not an app change")
        XCTAssertTrue(error?.stderr.contains("Scripts/bump-version.sh patch|minor|major") == true, "says how to bump")
        XCTAssertTrue(error?.stderr.contains("SKIP_VERSION_CHECK=1") == true, "says how to skip")
        let count = try await commits(in: repo)
        XCTAssertEqual(count, 1, "nothing was committed")
    }

    func testAnAppChangeWithVersionIsCommitted() async throws {
        let repo = try await scratchRepo()
        try write("let a = 2\n", to: "Sources/Terminus/App.swift", in: repo)
        try write("1.0.1\n", to: "VERSION", in: repo)
        try await git(["commit", "-q", "-am", "app: fix"], in: repo)
        let count = try await commits(in: repo)
        XCTAssertEqual(count, 2)
    }

    func testDocsAndTestsOnlyNeedNoBump() async throws {
        let repo = try await scratchRepo()
        try write("# Doc, better\n", to: "docs/doc.md", in: repo)
        try write("// more\n", to: "Tests/TerminusTests/ATests.swift", in: repo)
        try write("Read me.\n", to: "README.md", in: repo)
        try await git(["add", "-A"], in: repo)
        try await git(["commit", "-q", "-m", "docs: better"], in: repo)
        let count = try await commits(in: repo)
        XCTAssertEqual(count, 2)
    }

    func testSkipVersionCheckLetsOneThrough() async throws {
        let repo = try await scratchRepo()
        try write("let a = 3\n", to: "Sources/Terminus/App.swift", in: repo)
        try await git(["commit", "-q", "-am", "app: amend-like"], in: repo, env: ["SKIP_VERSION_CHECK": "1"])
        let count = try await commits(in: repo)
        XCTAssertEqual(count, 2)
    }

    /// A commit that changes VERSION gets `v<VERSION>`, annotated; a tag that
    /// exists is never moved or made twice.
    func testACommitThatChangesVersionIsTaggedOnce() async throws {
        let repo = try await scratchRepo()
        let first = try await git(["rev-parse", "HEAD"], in: repo)
        var listed = try await tags(in: repo)
        XCTAssertEqual(listed, ["v1.0.0"], "the first commit brought VERSION")

        try write("let a = 4\n", to: "Sources/Terminus/App.swift", in: repo)
        try write("1.1.0\n", to: "VERSION", in: repo)
        try await git(["commit", "-q", "-am", "app: a feature"], in: repo)
        let bumped = try await git(["rev-parse", "HEAD"], in: repo)
        let kind = try await git(["cat-file", "-t", "v1.1.0"], in: repo)
        XCTAssertEqual(kind, "tag\n", "annotated")
        let message = try await git(["tag", "--list", "--format=%(contents:subject)", "v1.1.0"], in: repo)
        XCTAssertEqual(message, "Terminus 1.1.0\n")
        let tagged = try await git(["rev-parse", "v1.1.0^{commit}"], in: repo)
        XCTAssertEqual(tagged, bumped)

        try write("# Doc, again\n", to: "docs/doc.md", in: repo)
        try await git(["commit", "-q", "-am", "docs: again"], in: repo)
        try write("1.0.0\n", to: "VERSION", in: repo)
        try await git(["commit", "-q", "-am", "back to a version that has its tag"], in: repo)
        listed = try await tags(in: repo)
        XCTAssertEqual(listed, ["v1.0.0", "v1.1.0"])
        let stillFirst = try await git(["rev-parse", "v1.0.0^{commit}"], in: repo)
        XCTAssertEqual(stillFirst, first, "an existing tag stays where it is")
        let stillBumped = try await git(["rev-parse", "v1.1.0^{commit}"], in: repo)
        XCTAssertEqual(stillBumped, bumped)
    }
}
