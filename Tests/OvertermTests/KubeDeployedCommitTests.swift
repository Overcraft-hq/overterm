import XCTest

@testable import Overterm

/// What is deployed, compared with the checkout (docs/design/kubernetes/analysis.md,
/// 3.2): the sources in their order of trust — an image's revision label
/// (asked for), a SHA-shaped tag, a release's appVersion — and the answer
/// from a git repository of the test's own (nothing fetched): ahead,
/// behind, deployed from elsewhere, HEAD itself, missing, none — and the
/// words each is said in.
final class KubeDeployedCommitTests: XCTestCase {
    private var repo: URL!

    override func tearDown() {
        if let repo { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
    }

    // MARK: The sources

    func testSHAShapes() {
        XCTAssertTrue(KubeDeployedCommit.isSHAShaped("1a2b3c4"))
        XCTAssertTrue(KubeDeployedCommit.isSHAShaped("deadbeef"))
        XCTAssertTrue(KubeDeployedCommit.isSHAShaped(String(repeating: "ab12", count: 10)))
        XCTAssertFalse(KubeDeployedCommit.isSHAShaped("1a2b3c"), "six is too short")
        XCTAssertFalse(KubeDeployedCommit.isSHAShaped(String(repeating: "a", count: 41)))
        XCTAssertTrue(KubeDeployedCommit.isSHAShaped("6761904"), "a short SHA can be digits alone")
        XCTAssertTrue(KubeDeployedCommit.isDigitsOnly("20241105"))
        XCTAssertFalse(KubeDeployedCommit.isSHAShaped("v1.2.3"))
        XCTAssertFalse(KubeDeployedCommit.isSHAShaped("latest"))
    }

    func testATagShapedLikeACommit() {
        XCTAssertEqual(KubeDeployedCommit.commit(inTag: "1A2B3C4"), "1a2b3c4")
        XCTAssertEqual(KubeDeployedCommit.commit(inTag: "main-1a2b3c4"), "1a2b3c4")
        XCTAssertEqual(KubeDeployedCommit.commit(inTag: "sha-1a2b3c4d"), "1a2b3c4d")
        XCTAssertEqual(KubeDeployedCommit.commit(inTag: "v1.4.0-9f8e7d6"), "9f8e7d6")
        XCTAssertNil(KubeDeployedCommit.commit(inTag: "1.27"))
        XCTAssertNil(KubeDeployedCommit.commit(inTag: "v1.2.3"))
        XCTAssertEqual(KubeDeployedCommit.tag(of: "ghcr.io/acme/web:1a2b3c4"), "1a2b3c4")
        XCTAssertEqual(KubeDeployedCommit.tag(of: "localhost:5000/web:main-1a2b3c4"), "main-1a2b3c4")
        XCTAssertNil(KubeDeployedCommit.tag(of: "nginx"), "no tag written: nothing to read")
        XCTAssertNil(KubeDeployedCommit.tag(of: "nginx@sha256:" + String(repeating: "a", count: 64)))
        XCTAssertEqual(KubeDeployedCommit.images(inCell: "ghcr.io/acme/web:1a2b3c4, busybox:1.36"), ["ghcr.io/acme/web:1a2b3c4", "busybox:1.36"])
        XCTAssertEqual(KubeDeployedCommit.images(inCell: nil), [])
    }

    func testTheSourcesInTheirOrderOfTrust() {
        let images = ["ghcr.io/acme/web:1a2b3c4", "busybox:1.36"]
        XCTAssertEqual(
            KubeDeployedCommit.candidates(images: images, revisions: ["ghcr.io/acme/web:1a2b3c4": "9f8e7d6c5b"], appVersion: "abcdef12"),
            [
                KubeCommitCandidate(sha: "9f8e7d6c5b", source: .revisionLabel, image: "ghcr.io/acme/web:1a2b3c4"),
                KubeCommitCandidate(sha: "1a2b3c4", source: .tag, image: "ghcr.io/acme/web:1a2b3c4"),
                KubeCommitCandidate(sha: "abcdef12", source: .appVersion, image: nil),
            ])
        XCTAssertEqual(KubeDeployedCommit.candidates(images: ["nginx:1.27"], appVersion: "1.27"), [], "nothing SHA-shaped: none")
        XCTAssertEqual(KubeDeployedCommit.candidates(images: ["nginx:1.27"], appVersion: "abcdef12").map(\.source), [.appVersion])
    }

    func testTheRevisionLabelFromImagetools() {
        let inspect = """
            {"name":"ghcr.io/acme/web:1","manifest":{"annotations":{"org.opencontainers.image.created":"2026-11-01"}},
             "image":{"linux/arm64":{"config":{"Labels":{"org.opencontainers.image.revision": "0123456789abcdef0123456789abcdef01234567"}}}}}
            """
        XCTAssertEqual(KubeDeployedCommit.revision(inInspect: inspect), "0123456789abcdef0123456789abcdef01234567")
        XCTAssertNil(KubeDeployedCommit.revision(inInspect: #"{"org.opencontainers.image.revision":"v1.2.3"}"#))
        XCTAssertNil(KubeDeployedCommit.revision(inInspect: "error: not found"))
    }

    // MARK: The words

    func testTheWords() {
        let sha = "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b"
        func found(behind: Int?, ahead: Int, elsewhere: Int = 0, branch: String? = "feat/x", isHead: Bool = false) -> String {
            KubeDeployedAnswer.found(
                .init(sha: sha, source: .tag, base: behind == nil ? nil : "main", behind: behind, branch: branch, ahead: ahead, elsewhere: elsewhere, isHead: isHead)
            ).text
        }
        XCTAssertEqual(found(behind: 4, ahead: 2), "deployed 1a2b3c4, 4 commits behind main; this branch is 2 commits ahead")
        XCTAssertEqual(found(behind: 1, ahead: 1, branch: "main"), "deployed 1a2b3c4, 1 commit behind main")
        XCTAssertEqual(found(behind: 0, ahead: 0, branch: "main", isHead: true), "deployed 1a2b3c4, up to date with main")
        XCTAssertEqual(found(behind: 0, ahead: 0, isHead: true), "deployed 1a2b3c4, up to date with main; this branch is at it")
        XCTAssertEqual(found(behind: 2, ahead: 0), "deployed 1a2b3c4, 2 commits behind main; nothing on this branch is newer")
        XCTAssertEqual(found(behind: nil, ahead: 3, branch: nil), "deployed 1a2b3c4; HEAD is 3 commits ahead")
        XCTAssertEqual(
            found(behind: 1, ahead: 1, elsewhere: 2, branch: "main"), "deployed 1a2b3c4, 1 commit behind main; it has 2 commits this branch doesn't")
        XCTAssertEqual(KubeDeployedAnswer.missing(sha: "abcdef1234", source: .tag).text, "commit abcdef1 is not in this checkout")
        XCTAssertEqual(KubeDeployedAnswer.none.text, "no commit found in the image")
        XCTAssertEqual(KubeDeployedAnswer.missing(sha: "abcdef1234", source: .appVersion).sourceSaid, "from the chart's appVersion")
        XCTAssertNil(KubeDeployedAnswer.none.sourceSaid)
    }

    // MARK: The checkout

    private func git(_ arguments: [String]) async throws -> String {
        try await Git.run(["-c", "user.email=t@overterm", "-c", "user.name=t", "-c", "commit.gpgsign=false"] + arguments, in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// main: c1 — c2 — c3; feat/x from c2: f1 — f2.
    private func makeRepo() async throws -> [String: String] {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("kube-deployed-\(UUID().uuidString)", isDirectory: true)
        repo = parent.appendingPathComponent("shop", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await git(["init", "-q", "-b", "main"])
        var shas: [String: String] = [:]
        func commit(_ name: String) async throws {
            try name.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
            _ = try await git(["add", name])
            _ = try await git(["commit", "-q", "-m", name])
            shas[name] = try await git(["rev-parse", "HEAD"])
        }
        try await commit("c1")
        try await commit("c2")
        _ = try await git(["checkout", "-q", "-b", "feat/x"])
        try await commit("f1")
        try await commit("f2")
        _ = try await git(["checkout", "-q", "main"])
        try await commit("c3")
        return shas
    }

    private func tagged(_ sha: String) -> [KubeCommitCandidate] {
        KubeDeployedCommit.candidates(images: ["ghcr.io/acme/web:\(sha.prefix(7))"])
    }

    func testTheAnswerFromTheCheckout() async throws {
        let shas = try await makeRepo()
        let c1 = try XCTUnwrap(shas["c1"]), c3 = try XCTUnwrap(shas["c3"]), f2 = try XCTUnwrap(shas["f2"])

        // On main, deployed c1: two behind.
        var answer = await KubeDeployedCommit.answer(tagged(c1), in: repo)
        XCTAssertEqual(answer.found?.sha, c1, "the short tag is the whole commit in git")
        XCTAssertEqual(answer.text, "deployed \(c1.prefix(7)), 2 commits behind main")
        XCTAssertEqual(answer.sourceSaid, "from the image's tag")
        answer = await KubeDeployedCommit.answer(tagged(c3), in: repo)
        XCTAssertEqual(answer.text, "deployed \(c3.prefix(7)), up to date with main")
        XCTAssertEqual(answer.found?.isHead, true)
        // Deployed from the branch, read on main: it has two commits main doesn't.
        answer = await KubeDeployedCommit.answer(tagged(f2), in: repo)
        XCTAssertEqual(answer.text, "deployed \(f2.prefix(7)), 1 commit behind main; it has 2 commits this branch doesn't")

        // On the branch, deployed c1: main is two ahead of it, the branch three.
        _ = try await git(["checkout", "-q", "feat/x"])
        answer = await KubeDeployedCommit.answer(tagged(c1), in: repo)
        XCTAssertEqual(answer.text, "deployed \(c1.prefix(7)), 2 commits behind main; this branch is 3 commits ahead")
        XCTAssertEqual(KubeDeployedCommit.review(try XCTUnwrap(answer.found)), .range(base: c1, head: "HEAD"), "Diff deployed…current")

        // Missing, and none.
        answer = await KubeDeployedCommit.answer(KubeDeployedCommit.candidates(images: ["ghcr.io/acme/web:deadbee"]), in: repo)
        XCTAssertEqual(answer, .missing(sha: "deadbee", source: .tag))
        XCTAssertEqual(answer.text, "commit deadbee is not in this checkout")
        answer = await KubeDeployedCommit.answer(KubeDeployedCommit.candidates(images: ["nginx:1.27"]), in: repo)
        XCTAssertEqual(answer, .none)
        answer = await KubeDeployedCommit.answer(KubeDeployedCommit.candidates(images: ["ghcr.io/acme/web:20241105"]), in: repo)
        XCTAssertEqual(answer, .none, "digits the checkout hasn't are a build number, not a missing commit")
        XCTAssertEqual(answer.text, "no commit found in the image")

        // The most trusted source the checkout has wins; one it hasn't is passed over.
        answer = await KubeDeployedCommit.answer(
            KubeDeployedCommit.candidates(images: ["ghcr.io/acme/web:deadbee"], revisions: ["ghcr.io/acme/web:deadbee": c3]), in: repo)
        XCTAssertEqual(answer.found?.sha, c3)
        XCTAssertEqual(answer.found?.source, .revisionLabel)
        answer = await KubeDeployedCommit.answer(
            KubeDeployedCommit.candidates(images: ["ghcr.io/acme/web:\(c1.prefix(8))"], revisions: ["ghcr.io/acme/web:\(c1.prefix(8))": "beefbeef00"]),
            in: repo)
        XCTAssertEqual(answer.found?.source, .tag, "a label the checkout hasn't: the tag next")

        // Nothing was fetched: the repository has no remote at all.
        let remotes = try await git(["remote"])
        XCTAssertEqual(remotes, "")
    }

    func testOutsideARepositoryEveryCommitIsMissing() async throws {
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("kube-plain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        let answer = await KubeDeployedCommit.answer(KubeDeployedCommit.candidates(images: ["web:1a2b3c4"]), in: plain)
        XCTAssertEqual(answer, .missing(sha: "1a2b3c4", source: .tag))
    }
}
