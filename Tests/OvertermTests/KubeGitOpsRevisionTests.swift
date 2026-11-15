import Foundation
import XCTest

@testable import Overterm

/// Revisions as Argo CD and Flux write them (docs/design/kubernetes/
/// gitops.md, 2.6), and what reaches git from the cluster (5.4): paths
/// checked against the checkout by components, literal pathspecs, refs
/// and revisions refused unless safe, a short SHA resolved to one commit
/// or said ambiguous — against a throwaway repository, its git config
/// isolated.
final class KubeGitOpsRevisionTests: XCTestCase {
    private let sha = "a77b0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c"

    /// What `Git.run` would inherit from the developer's shell or config:
    /// set (or unset) for each test, as the fixture's own `git` has them,
    /// and given back after (gitops.md, 8: every fixture repository's git
    /// calls run isolated).
    private static let isolation: [String: String?] = [
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_LITERAL_PATHSPECS": nil, "GIT_GLOB_PATHSPECS": nil,
        "GIT_NOGLOB_PATHSPECS": nil, "GIT_ICASE_PATHSPECS": nil, "GIT_DIR": nil, "GIT_WORK_TREE": nil, "GIT_INDEX_FILE": nil,
        "GIT_OBJECT_DIRECTORY": nil, "GIT_COMMON_DIR": nil, "GIT_CEILING_DIRECTORIES": nil, "GIT_CONFIG": nil, "GIT_CONFIG_COUNT": nil,
    ]
    private var saved: [String: String?] = [:]

    override func setUp() {
        super.setUp()
        for (name, value) in Self.isolation {
            saved[name] = ProcessInfo.processInfo.environment[name]
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
    }

    override func tearDown() {
        for (name, value) in saved {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
        saved = [:]
        super.tearDown()
    }

    func testTheTableOfRevisions() {
        let digest = String(repeating: "1f2e3d4c", count: 8)
        let cases: [(String, String, String?)] = [
            ("main@sha1:\(sha)", "main@a77b0d1", sha),
            ("refs/heads/main@sha1:\(sha)", "main@a77b0d1", sha),
            ("v1.2.3@sha1:\(sha)", "v1.2.3@a77b0d1", sha),
            ("main/\(sha)", "main@a77b0d1", sha),
            ("sha1:\(sha)", "a77b0d1", sha),
            ("latest@sha256:\(digest)", "sha256:1f2e3d4", nil),
            ("sha256:\(digest)", "sha256:1f2e3d4", nil),
            ("1.2.3", "1.2.3", nil),
            (sha, "a77b0d1", sha),
            ("a77b0d1", "a77b0d1", nil),
            ("20241105", "20241105", nil),
        ]
        for (written, shown, commit) in cases {
            XCTAssertEqual(KubeGitOpsRevision.shown(written), shown, written)
            XCTAssertEqual(KubeGitOpsRevision.commit(written), commit, written)
        }
        XCTAssertEqual(KubeGitOpsRevision.parse("refs/heads/main@sha1:\(sha)").ref, "main", "what it tracks")
        XCTAssertEqual(KubeGitOpsRevision.parse("latest@sha256:\(digest)").digest, "sha256:\(digest)")
        // Flux's Revision strategy: a chart version's build is a commit's 12-character prefix, to verify first.
        let built = KubeGitOpsRevision.parse("1.2.3+a77b0d1e2f3a")
        XCTAssertEqual(built.shown, "1.2.3")
        XCTAssertEqual(built.commit, "a77b0d1e2f3a")
        XCTAssertTrue(built.prefix)
        XCTAssertNil(KubeGitOpsRevision.commit("1.2.3+build.7"))
    }

    // MARK: Paths

    private func repository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ot-gitops-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("apps/web"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("deploy/fake-dev"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testAPathIsCheckedAgainstTheCheckoutByComponents() throws {
        let root = try repository()
        XCTAssertEqual(KubeGitOpsPath.resolve("./deploy/fake-dev/", in: root), .inCheckout("deploy/fake-dev"))
        XCTAssertEqual(KubeGitOpsPath.resolve("", in: root), .inCheckout(""), "the root")
        XCTAssertEqual(KubeGitOpsPath.resolve(".", in: root), .inCheckout(""))
        XCTAssertEqual(KubeGitOpsPath.resolve("apps/cron", in: root), .missing("apps/cron"))
        XCTAssertEqual(KubeGitOpsPath.said(.missing("apps/cron")), "path apps/cron is not on this branch")
        guard case .refused = KubeGitOpsPath.resolve("../outside", in: root) else { return XCTFail("..") }
        guard case .refused = KubeGitOpsPath.resolve("apps/../../outside", in: root) else { return XCTFail("a .. further in") }
        guard case .refused = KubeGitOpsPath.resolve("/etc", in: root) else { return XCTFail("absolute") }
        guard case .refused = KubeGitOpsPath.resolve("apps\u{0}/web", in: root) else { return XCTFail("NUL") }
        // A sibling whose name starts like the root's: components, not a string prefix.
        let sibling = URL(fileURLWithPath: root.path + "-evil", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sibling) }
        guard case .refused = KubeGitOpsPath.resolve("../\(root.lastPathComponent)-evil", in: root) else { return XCTFail("a sibling") }
        // A symlink out of the checkout.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: sibling)
        guard case .refused = KubeGitOpsPath.resolve("escape", in: root) else { return XCTFail("a symlink out") }
        // A symlink inside it is fine.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("web"), withDestinationURL: root.appendingPathComponent("apps/web"))
        XCTAssertEqual(KubeGitOpsPath.resolve("web", in: root), .inCheckout("apps/web"))
        // manifest-generate-paths: `/` is the repository's root; else relative to the app's path.
        XCTAssertEqual(KubeGitOpsPath.resolve(generatePath: "/deploy", appPath: "apps/web", in: root), .inCheckout("deploy"))
        XCTAssertEqual(KubeGitOpsPath.resolve(generatePath: ".", appPath: "apps/web", in: root), .inCheckout("apps/web"))
        XCTAssertEqual(KubeGitOpsPath.resolve(generatePath: "../../deploy", appPath: "apps/web", in: root), .inCheckout("deploy"))
        guard case .refused = KubeGitOpsPath.resolve(generatePath: "../../../x", appPath: "apps/web", in: root) else { return XCTFail("out") }
    }

    // MARK: What git is given

    func testRefsAndRevisionsAreRefusedUnlessSafe() {
        XCTAssertEqual(KubeGitOpsGitArgs.ref("main"), "main")
        XCTAssertEqual(KubeGitOpsGitArgs.ref("fix/orders"), "fix/orders")
        for bad in ["-x", "--output=f", "a..b", "main@{1}", "has space", "a\u{0}b", "x~1", "x^", "a:b", "*", "/main", "main/", "main.lock", ".hidden", "a//b", ""] {
            XCTAssertNil(KubeGitOpsGitArgs.ref(bad), bad)
        }
        XCTAssertEqual(KubeGitOpsGitArgs.remoteRef(remote: "origin", "main"), "refs/remotes/origin/main")
        XCTAssertNil(KubeGitOpsGitArgs.remoteRef(remote: "origin", "--output=f"))
        XCTAssertNil(KubeGitOpsGitArgs.remoteRef(remote: "-o", "main"))
        XCTAssertEqual(KubeGitOpsGitArgs.revision("A77B0D1"), "a77b0d1")
        XCTAssertNil(KubeGitOpsGitArgs.revision("main"))
        XCTAssertNil(KubeGitOpsGitArgs.revision("--all"))
        XCTAssertNil(KubeGitOpsGitArgs.verifyArguments("HEAD~1"))
        XCTAssertEqual(
            KubeGitOpsGitArgs.verifyArguments("a77b0d1"), ["--literal-pathspecs", "rev-parse", "--verify", "--end-of-options", "a77b0d1^{commit}"])
        XCTAssertEqual(
            KubeGitOpsGitArgs.countArguments(from: sha, to: "refs/remotes/origin/main", pathspecs: ["apps/web"]),
            ["--literal-pathspecs", "rev-list", "--count", "--end-of-options", "\(sha)..refs/remotes/origin/main", "--", "apps/web"])
        XCTAssertNil(KubeGitOpsGitArgs.countArguments(from: "a..b", to: sha, pathspecs: ["x"]))
        XCTAssertNil(KubeGitOpsGitArgs.countArguments(from: sha, to: "refs/remotes/origin/--x", pathspecs: ["x"]))
        XCTAssertNil(KubeGitOpsGitArgs.changedArguments(base: sha, pathspecs: []), "no path checked: nothing asked")
        XCTAssertEqual(KubeGitOpsGitArgs.pathspecs([.inCheckout(""), .missing("x"), .inCheckout("apps/web"), .inCheckout("apps/web")]), [".", "apps/web"])
    }

    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Acme", "-c", "user.email=dev@acme.example", "-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pathspecs are literal; a revision becomes a commit only once verified.
    func testGitIsGivenOnlyCheckedStrings() async throws {
        let root = try repository()
        _ = try git(["init", "-q", "-b", "main"], in: root)
        try "x".write(to: root.appendingPathComponent("x"), atomically: true, encoding: .utf8)
        try "w".write(to: root.appendingPathComponent("apps/web/a.yaml"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."], in: root)
        _ = try git(["commit", "-qm", "c1"], in: root)
        let head = try git(["rev-parse", "HEAD"], in: root)
        // `:(top)x` and `:!x` are plain names, not magic.
        let literal = try await Git.run([KubeGitOpsGitArgs.literal, "ls-files", "--", ":(top)x", ":!x"], in: root)
        XCTAssertEqual(literal, "", "nothing is named so")
        let magic = try await Git.run(["ls-files", "--", ":(top)x"], in: root)
        XCTAssertEqual(magic.trimmingCharacters(in: .whitespacesAndNewlines), "x", "without it, git reads the magic")
        // A commit, whole or short; a SHA it doesn't have; a word.
        let resolved = await KubeGitOpsGitArgs.resolve(String(head.prefix(7)), in: root)
        XCTAssertEqual(resolved, .commit(head))
        let unknown = await KubeGitOpsGitArgs.resolve("0123456789abcdef0123456789abcdef01234567", in: root)
        XCTAssertEqual(unknown, .missing)
        let tree = try git(["rev-parse", "HEAD^{tree}"], in: root)
        let notACommit = await KubeGitOpsGitArgs.resolve(tree, in: root)
        XCTAssertEqual(notACommit, .missing, "a tree's SHA is no commit")
        let word = await KubeGitOpsGitArgs.resolve("--all", in: root)
        XCTAssertEqual(word, .refused)
        // The count, under a path, through the built arguments.
        let count = try XCTUnwrap(KubeGitOpsGitArgs.countArguments(from: head, to: head, pathspecs: ["apps/web"]))
        let counted = try await Git.run(count, in: root)
        XCTAssertEqual(counted.trimmingCharacters(in: .whitespacesAndNewlines), "0")
    }

    /// Several commits under one prefix: said ambiguous, never a guess.
    func testAnAmbiguousPrefixIsSaidSo() {
        let said = """
            error: short object ID a77b0d1 is ambiguous
            hint: The candidates are:
            hint:   a77b0d1e2 commit 2026-11-01 - one
            hint:   a77b0d1f9 commit 2026-11-02 - two
            fatal: Needed a single revision
            """
        XCTAssertEqual(KubeGitOpsGitArgs.failure(said), .ambiguous)
        XCTAssertEqual(KubeGitOpsGitArgs.failure("fatal: Needed a single revision"), .missing)
    }
}
