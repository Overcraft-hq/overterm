import XCTest

@testable import Overterm

/// Has this branch reached the cluster (docs/design/kubernetes/gitops.md,
/// 4.3, 8.1): what each tool applied as a commit or not (`.gitopsRevision`,
/// its words by tool), attempted ≠ applied, fetched not applied, the
/// pathspecs (the path, `manifest-generate-paths`, a `kustomization.yaml`'s
/// entries one level deep, a remote one not followed, one out of the
/// checkout refused), and the answers against a repository of the test's
/// own — its git isolated from the developer's config, nothing fetched.
final class KubeGitOpsReachTests: XCTestCase {
    private var root: URL!
    private let isolated = KubeGitOpsCheckouts.isolatedGit

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gitops-reach-\(UUID().uuidString)", isDirectory: true)
        for path in ["apps/web", "base", "components/probe"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try "kind: Deployment\n".write(to: root.appendingPathComponent("base/web.yaml"), atomically: true, encoding: .utf8)
        try "kind: Component\n".write(to: root.appendingPathComponent("components/probe/kustomization.yaml"), atomically: true, encoding: .utf8)
        let kustomization = """
            resources:
              - ../../base/web.yaml
              - https://github.com/acme/remote//base?ref=v1
              - github.com/acme/other/base
              - ../../../outside
            components:
              - ../../components/probe
            """
        try kustomization.write(to: root.appendingPathComponent("apps/web/kustomization.yaml"), atomically: true, encoding: .utf8)
        try await git(["init", "-q", "-b", "main"])
        try await git(["add", "."])
        try await git(["commit", "-q", "-m", "web"])
        try await git(["remote", "add", "origin", "git@git.acme.example:acme/shop.git"])
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    @discardableResult
    private func git(_ arguments: [String]) async throws -> String {
        let identity = ["-c", "user.email=t@overterm", "-c", "user.name=t", "-c", "commit.gpgsign=false"]
        return try await isolated(identity + arguments, root, [0]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit(_ file: String, _ message: String) async throws -> String {
        let url = root.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try UUID().uuidString.write(to: url, atomically: true, encoding: .utf8)
        try await git(["add", file])
        try await git(["commit", "-q", "-m", message])
        return try await git(["rev-parse", "HEAD"])
    }

    private func checkout(head: String?, branch: String = "main") -> KubeGitOpsMatch.Checkout {
        KubeGitOpsMatch.Checkout(
            root: root, remotes: [KubeGitOpsMatch.Remote(name: "origin", repo: GitRemoteURL("git@git.acme.example:acme/shop.git")!)], branch: branch,
            defaults: ["origin": "main"], head: head)
    }

    private func object(_ kind: String, _ name: String, namespace: String, spec: [String: Any], status: [String: Any] = [:], annotations: [String: String] = [:])
        -> KubeGitOpsObject
    {
        let apiVersion: String =
            switch kind {
            case "Application": "argoproj.io/v1alpha1"
            case "Kustomization": "kustomize.toolkit.fluxcd.io/v1"
            case "HelmRelease": "helm.toolkit.fluxcd.io/v2"
            default: "source.toolkit.fluxcd.io/v1"
            }
        let json: [String: Any] = [
            "apiVersion": apiVersion, "kind": kind, "metadata": ["name": name, "namespace": namespace, "annotations": annotations], "spec": spec,
            "status": status,
        ]
        return KubeGitOpsSummary.object(json, readAt: Date())!
    }

    private func ready(_ status: String, _ reason: String, _ message: String = "") -> [String: Any] {
        ["type": "Ready", "status": status, "reason": reason, "message": message, "lastTransitionTime": FakeKubeAPI.time(Date())]
    }

    private func peers(_ list: [KubeGitOpsObject]) -> [KubeGitOpsObject.Key: KubeGitOpsObject] {
        Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private let sha = "a77b0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c"
    private let other = "c03f9aa1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7"

    private func fleet(artifact: String) -> KubeGitOpsObject {
        object(
            "GitRepository", "acme-fleet", namespace: "flux-system", spec: ["url": "https://git.acme.example/acme/shop.git", "ref": ["branch": "main"]],
            status: ["artifact": ["revision": artifact, "lastUpdateTime": FakeKubeAPI.time(Date())]])
    }

    private func kustomization(applied: String?, attempted: String?, ready: [String: Any]) -> KubeGitOpsObject {
        var status: [String: Any] = ["conditions": [ready]]
        if let applied { status["lastAppliedRevision"] = applied }
        if let attempted { status["lastAttemptedRevision"] = attempted }
        return object(
            "Kustomization", "acme-web", namespace: "flux-system", spec: ["path": "./apps/web", "sourceRef": ["kind": "GitRepository", "name": "acme-fleet"]],
            status: status)
    }

    // MARK: Pure

    func testWhatEachToolAppliedAsACommitOrNot() {
        let ks = kustomization(applied: "main@sha1:\(sha)", attempted: "main@sha1:\(sha)", ready: ready("True", "ReconciliationSucceeded"))
        XCTAssertEqual(KubeGitOpsReach.applied(ks, source: 0, peers: [:]), .commit(sha, prefix: false))
        let release = object(
            "HelmRelease", "acme-payments", namespace: "shop", spec: ["chart": ["spec": ["chart": "charts/payments"]]],
            status: ["history": [["chartVersion": "1.4.2+a77b0d1e2f3a", "status": "deployed"]]])
        XCTAssertEqual(KubeGitOpsReach.applied(release, source: 0, peers: [:]), .commit("a77b0d1e2f3a", prefix: true), "Flux's Revision strategy")
        let chart = object(
            "HelmRelease", "acme-redis", namespace: "shop", spec: [:], status: ["history": [["chartVersion": "1.4.2", "status": "deployed"]]])
        XCTAssertEqual(KubeGitOpsReach.applied(chart, source: 0, peers: [:]), .notACommit("chart 1.4.2"))
        // A multi-source Application: the matched source's live revision.
        let app = object(
            "Application", "acme-api", namespace: "argocd",
            spec: [
                "sources": [
                    ["repoURL": "oci://ghcr.io/acme/charts", "chart": "api", "targetRevision": "1.4.2"],
                    ["repoURL": "git@git.acme.example:acme/shop", "path": "apps/web", "targetRevision": "main"],
                ]
            ],
            status: ["history": [["revisions": ["1.4.2", sha]]], "sync": ["status": "Synced", "revisions": ["1.4.2", sha]]])
        XCTAssertEqual(KubeGitOpsReach.applied(app, source: 1, peers: [:]), .commit(sha, prefix: false))
        XCTAssertEqual(KubeGitOpsReach.applied(app, source: 0, peers: [:]), .notACommit("chart 1.4.2"))
        let unsynced = object("Application", "acme-new", namespace: "argocd", spec: ["source": ["repoURL": "x", "path": "apps/web"]])
        XCTAssertEqual(KubeGitOpsReach.applied(unsynced, source: 0, peers: [:]), .none)
    }

    func testTheWordsBySource() {
        XCTAssertEqual(KubeCommitSource.gitopsRevision.said(tool: .argo), "Argo CD's synced revision")
        XCTAssertEqual(KubeCommitSource.gitopsRevision.said(tool: .flux), "Flux's applied revision")
        XCTAssertEqual(KubeCommitSource.tag.said(tool: .argo), "the image's tag", "an image's source is said as before")
        var question = KubeGitOpsReach.Question(
            tool: .argo, said: "Application acme-api, Ready", applied: .notACommit("chart 1.4.2"), countsUnder: false)
        XCTAssertEqual(KubeGitOpsReach.notACommit(question, shown: "chart 1.4.2"), "Argo CD's synced revision isn't a commit (chart 1.4.2)")
        XCTAssertEqual(KubeGitOpsReach.notACommit(question, shown: nil), "Argo CD hasn't synced a revision yet")
        question.tool = .flux
        XCTAssertEqual(KubeGitOpsReach.notACommit(question, shown: nil), "Flux hasn't applied a revision yet")
        XCTAssertEqual(KubeDeployedAnswer.missing(sha: sha, source: .gitopsRevision).text, "manifests at a77b0d1, not in this checkout — fetch to compare")
        XCTAssertEqual(KubeDeployedAnswer.notACommit("Argo CD's synced revision isn't a commit (chart 1.4.2)").text, "Argo CD's synced revision isn't a commit (chart 1.4.2)")
        XCTAssertNil(KubeDeployedAnswer.notACommit("x").sourceSaid)
        let found = KubeDeployedAnswer.found(
            .init(sha: sha, source: .gitopsRevision, base: "main", behind: 0, branch: "fix/orders", ahead: 1, elsewhere: 0, isHead: false))
        XCTAssertEqual(found.text, "manifests at a77b0d1, up to date with main; this branch is 1 commit ahead")
        XCTAssertEqual(KubeGitOpsReach.unchangedText(count: 0, pathspecs: ["apps/web"], since: sha, on: "origin/main"), "no change under apps/web since a77b0d1 on origin/main")
        XCTAssertEqual(
            KubeGitOpsReach.unchangedText(count: 2, pathspecs: ["apps/web", "base", "c", "d"], since: sha, on: "origin/main"),
            "2 commits under apps/web and 3 more paths on origin/main since a77b0d1, not synced")
    }

    func testAttemptedIsNotApplied() {
        let failed = kustomization(
            applied: "main@sha1:\(sha)", attempted: "main@sha1:\(other)",
            ready: ready("False", "BuildFailed", "kustomize build failed:\napiVersion: v1\nkind: Secret\nstringData:\n  pw: s3cr3t-sentinel"))
        let attempt = try! XCTUnwrap(KubeGitOpsReach.attempted(failed))
        let said = KubeGitOpsReach.attemptedText(attempt, head: other)
        // The commit's short SHA, as 4.3 says it — not the ref Flux wrote before it.
        XCTAssertTrue(said.hasPrefix("Flux tried c03f9aa (this branch's HEAD) and failed: BuildFailed: kustomize build failed"), said)
        XCTAssertTrue(said.hasSuffix("; a77b0d1 is still applied"), said)
        XCTAssertFalse(said.contains("s3cr3t-sentinel"))
        XCTAssertFalse(KubeGitOpsReach.attemptedText(attempt, head: sha).contains("HEAD"))
        // Ready: no attempt said.
        XCTAssertNil(KubeGitOpsReach.attempted(kustomization(applied: "main@sha1:\(sha)", attempted: "main@sha1:\(other)", ready: ready("True", "ReconciliationSucceeded"))))
        // A HelmRelease rolled back.
        let release = object(
            "HelmRelease", "acme-payments", namespace: "shop", spec: [:],
            status: [
                "conditions": [ready("False", "RollbackSucceeded", "Helm rollback to previous release shop/acme-payments.v3 with chart payments@1.4.2 succeeded")],
                "lastAttemptedRevision": "1.5.0", "history": [["chartVersion": "1.4.2", "status": "deployed"]],
            ])
        let rolled = try! XCTUnwrap(KubeGitOpsReach.attempted(release))
        XCTAssertTrue(KubeGitOpsReach.attemptedText(rolled, head: nil).hasPrefix("Flux tried 1.5.0 and failed: "))
        XCTAssertTrue(KubeGitOpsReach.attemptedText(rolled, head: nil).contains("Helm rollback"))
        XCTAssertTrue(KubeGitOpsReach.attemptedText(rolled, head: nil).hasSuffix("; rolled back to 1.4.2"))
    }

    func testFetchedNotApplied() {
        let ks = kustomization(applied: "main@sha1:\(sha)", attempted: "main@sha1:\(sha)", ready: ready("True", "ReconciliationSucceeded"))
        let fetched = try! XCTUnwrap(KubeGitOpsReach.fetched(ks, source: 0, peers: peers([ks, fleet(artifact: "main@sha1:\(other)")])))
        XCTAssertEqual(KubeGitOpsReach.fetchedText(fetched, tool: .flux, order: .newer), "Flux fetched main@c03f9aa, not applied yet (newer than main@a77b0d1)")
        XCTAssertNil(KubeGitOpsReach.fetched(ks, source: 0, peers: peers([ks, fleet(artifact: "main@sha1:\(sha)")])), "the source holds what is applied")
        let app = object(
            "Application", "acme-web", namespace: "argocd", spec: ["source": ["repoURL": "x", "path": "apps/web"]],
            status: ["history": [["revision": sha]], "sync": ["status": "Synced", "revision": other]])
        let seen = try! XCTUnwrap(KubeGitOpsReach.fetched(app, source: 0, peers: [:]))
        XCTAssertEqual(KubeGitOpsReach.fetchedText(seen, tool: .argo, order: nil), "git has c03f9aa; Argo CD synced a77b0d1")
    }

    func testThePathspecs() {
        let found = KubeGitOpsReach.pathspecs(path: "./apps/web/", generatePaths: [".", "/base", "../../../etc"], in: root)
        XCTAssertEqual(found.pathspecs, ["apps/web", "base", "components/probe"], "base/web.yaml is under base")
        XCTAssertTrue(found.notes.contains("2 remote entries of its kustomization.yaml not followed"), "\(found.notes)")
        XCTAssertTrue(found.notes.contains("2 paths outside the checkout or not here left out"), "\(found.notes)")
        XCTAssertEqual(KubeGitOpsReach.pathspecs(path: "apps/gone", generatePaths: [], in: root).pathspecs, [], "a path not here checks nothing")
        XCTAssertEqual(KubeGitOpsReach.under(["."]), "the repository's root")
        // Every argument through 5.4: a ref and a revision refused before git sees them.
        XCTAssertNil(KubeGitOpsGitArgs.refArguments("refs/remotes/origin/--output=f"))
        XCTAssertNil(KubeGitOpsGitArgs.mergeBaseArguments("refs/heads/a..b"))
        XCTAssertNil(KubeGitOpsGitArgs.mergeBaseArguments("-x"))
        XCTAssertNil(KubeGitOpsGitArgs.ancestorArguments("HEAD", sha))
        XCTAssertNil(KubeGitOpsGitArgs.logArguments(from: sha, to: "--all", limit: 20))
        XCTAssertEqual(KubeGitOpsGitArgs.logArguments(from: sha, to: other, limit: 20)?.first, KubeGitOpsGitArgs.literal)
        // The tracked branch found locally (a branch, a tag) counts as the remote's does; a short name never.
        XCTAssertNotNil(KubeGitOpsGitArgs.countArguments(from: sha, to: "refs/heads/main", pathspecs: ["apps/web"]))
        XCTAssertNotNil(KubeGitOpsGitArgs.countArguments(from: sha, to: "refs/tags/v1.2.0", pathspecs: ["apps/web"]))
        XCTAssertNil(KubeGitOpsGitArgs.countArguments(from: sha, to: "main", pathspecs: ["apps/web"]), "DWIM would read a tag or a branch first")
        XCTAssertNil(KubeGitOpsGitArgs.countArguments(from: sha, to: "refs/notes/x", pathspecs: ["apps/web"]))
        XCTAssertEqual(KubeGitOpsGitArgs.changedFiles("deploy/caf\u{E9}.yaml\0a b.yaml\0"), ["deploy/caf\u{E9}.yaml", "a b.yaml"])
    }

    /// 4.3's key: what git reads, not the words — a reconcile's Ready →
    /// Progressing, a new message, asks nothing again; HEAD, a revision, the
    /// refs (a fetch) do.
    func testTheKeyIsWhatGitReads() {
        let failed = kustomization(applied: "main@sha1:\(sha)", attempted: "main@sha1:\(other)", ready: ready("False", "BuildFailed", "kustomize build failed"))
        let why = KubeGitOpsMatch.Why.repoAndPath("apps/web", source: nil)
        let source = fleet(artifact: "main@sha1:\(sha)")
        let question = try! XCTUnwrap(KubeGitOpsReach.question(failed, why: why, checkout: checkout(head: other), peers: peers([failed, source])))
        var said = question
        said.said = "Kustomization acme-web, Progressing"
        said.attempted?.reason = "HealthCheckFailed"
        said.attempted?.message = "health check failed after 5m"
        XCTAssertNotEqual(said, question)
        XCTAssertEqual(said.key, question.key, "the words aren't the key")
        let answer = KubeGitOpsReach.labeled(KubeGitOpsReach.Answer(deployed: .none, source: KubeGitOpsReach.sourceText(question)), said)
        XCTAssertEqual(answer.source, "from Flux's applied revision (Kustomization acme-web, Progressing)")
        XCTAssertEqual(answer.attempted, "Flux tried c03f9aa (this branch's HEAD) and failed: HealthCheckFailed — health check failed after 5m; a77b0d1 is still applied")
        var moved = question
        moved.head = sha
        XCTAssertNotEqual(moved.key, question.key, "HEAD")
        var fetched = question
        fetched.refs = (question.refs ?? 0) &+ 1
        XCTAssertNotEqual(fetched.key, question.key, "a fetch moved a ref")
        var refs = checkout(head: other)
        refs.refs = 42
        XCTAssertEqual(KubeGitOpsReach.question(failed, why: why, checkout: refs, peers: peers([failed, source]))?.refs, 42)
    }

    // MARK: Against the checkout

    func testAKustomizationsAnswerAndAskWhysCommits() async throws {
        let c1 = try await git(["rev-parse", "HEAD"])
        try await git(["update-ref", "refs/remotes/origin/main", c1])
        try await git(["checkout", "-q", "-b", "fix/orders"])
        let c2 = try await commit("base/web.yaml", "the fix, from https://bot:ghp_fake0123@git.acme.example/acme/shop")
        let source = fleet(artifact: "main@sha1:\(c1)")
        let ks = kustomization(
            applied: "main@sha1:\(c1)", attempted: "main@sha1:\(c2)", ready: ready("False", "HealthCheckFailed", "health check failed after 5m"))
        let why = KubeGitOpsMatch.Why.repoAndPath("apps/web", source: nil)
        let question = try XCTUnwrap(KubeGitOpsReach.question(ks, why: why, checkout: checkout(head: c2, branch: "fix/orders"), peers: peers([ks, source])))
        XCTAssertEqual(question.remote, "origin")
        XCTAssertEqual(question.tracked, "main")
        XCTAssertNil(
            KubeGitOpsReach.question(ks, why: .owns([]), checkout: checkout(head: c2), peers: peers([ks, source])), "only case (a) is compared")
        let answer = await KubeGitOpsReach.answer(question, in: root, git: isolated)
        XCTAssertEqual(answer.deployed.text, "manifests at \(c1.prefix(7)), up to date with origin/main; this branch is 1 commit ahead")
        XCTAssertEqual(answer.attempted, "Flux tried \(c2.prefix(7)) (this branch's HEAD) and failed: HealthCheckFailed: health check failed after 5m; \(c1.prefix(7)) is still applied")
        XCTAssertEqual(answer.range, KubeGitOpsReach.CommitRange(from: c1, to: c2))
        XCTAssertEqual(answer.changed?.files, ["base/web.yaml"], "under a kustomization.yaml entry")
        XCTAssertEqual(answer.changed?.text, "1 file under apps/web, base/web.yaml, components/probe on this branch")
        XCTAssertNil(answer.unchanged)
        let commits = await KubeGitOpsReach.commits(try XCTUnwrap(answer.range), in: root, git: isolated)
        XCTAssertEqual(commits.count, 1)
        let parts = KubeGitOpsReach.briefParts(answer, commits: commits, checkout: root)
        XCTAssertEqual(parts.map(\.title), ["checkout", "commits", "changed files"])
        XCTAssertFalse(parts.contains { $0.text.contains("ghp_fake0123") }, "scrubbed")
        XCTAssertTrue(parts[1].text.contains("\(c2.prefix(7)) the fix"), parts[1].text)
    }

    func testNoChangeUnderAnApplicationsPathAndAMissingCommit() async throws {
        let c1 = try await git(["rev-parse", "HEAD"])
        let c2 = try await commit("README", "outside the path")
        try await git(["update-ref", "refs/remotes/origin/main", c2])
        func app(live: String) -> KubeGitOpsObject {
            object(
                "Application", "acme-web", namespace: "argocd",
                spec: ["source": ["repoURL": "https://git.acme.example/acme/shop.git", "path": "apps/web", "targetRevision": "HEAD"]],
                status: ["history": [["revision": live]], "sync": ["status": "Synced", "revision": c2]],
                annotations: ["argocd.argoproj.io/manifest-generate-paths": ".;/components"])
        }
        let why = KubeGitOpsMatch.Why.repoAndPath("apps/web", source: nil)
        let question = try XCTUnwrap(KubeGitOpsReach.question(app(live: c1), why: why, checkout: checkout(head: c2), peers: [:]))
        XCTAssertEqual(question.tracked, "main", "HEAD: the remote's default branch")
        XCTAssertTrue(question.countsUnder)
        let answer = await KubeGitOpsReach.answer(question, in: root, git: isolated)
        XCTAssertEqual(answer.pathspecs, ["apps/web", "components", "base/web.yaml"])
        XCTAssertEqual(answer.unchanged, "no change under apps/web, components, base/web.yaml since \(c1.prefix(7)) on origin/main")
        XCTAssertEqual(answer.fetched, "git has \(c2.prefix(7)); Argo CD synced \(c1.prefix(7)) (newer than \(c1.prefix(7)))")
        XCTAssertEqual(answer.changed?.text, "no change under apps/web, components, base/web.yaml on this branch")

        // A change under the path on origin/main since the live one: counted.
        let c3 = try await commit("apps/web/deployment.yaml", "under the path")
        try await git(["update-ref", "refs/remotes/origin/main", c3])
        let again = await KubeGitOpsReach.answer(question, in: root, git: isolated)
        XCTAssertEqual(again.unchanged, "1 commit under apps/web, components, base/web.yaml on origin/main since \(c1.prefix(7)), not synced")

        // Not in the checkout: said, never fetched.
        let missing = try XCTUnwrap(KubeGitOpsReach.question(app(live: sha), why: why, checkout: checkout(head: c3), peers: [:]))
        let none = await KubeGitOpsReach.answer(missing, in: root, git: isolated)
        XCTAssertEqual(none.deployed, .missing(sha: sha, source: .gitopsRevision))
        XCTAssertNil(none.unchanged)
    }

    /// The branch it tracks isn't here: nothing compared with main instead,
    /// and said — a repository-only match too.
    func testATrackedBranchNotHereIsComparedWithNothing() async throws {
        let c1 = try await git(["rev-parse", "HEAD"])
        try await git(["update-ref", "refs/remotes/origin/main", c1])
        let app = object(
            "Application", "acme-web", namespace: "argocd",
            spec: ["source": ["repoURL": "https://git.acme.example/acme/shop.git", "path": "apps/web", "targetRevision": "release"]],
            status: ["history": [["revision": c1]], "sync": ["status": "Synced", "revision": c1]])
        for why in [KubeGitOpsMatch.Why.repoAndPath("apps/web", source: nil), .repoOnly("its repository", source: nil)] {
            let question = try XCTUnwrap(KubeGitOpsReach.question(app, why: why, checkout: checkout(head: c1), peers: [:]))
            XCTAssertEqual(question.tracked, "release")
            let answer = await KubeGitOpsReach.answer(question, in: root, git: isolated)
            XCTAssertEqual(answer.deployed.found?.sha, c1)
            XCTAssertNil(answer.deployed.found?.base, "never \"up to date with main\" for an app that tracks release")
            XCTAssertFalse(answer.deployed.text.contains("main"), answer.deployed.text)
            XCTAssertEqual(answer.checked.first, "origin/release isn't in this checkout — fetch to compare", "\(why)")
            XCTAssertNil(answer.unchanged)
            XCTAssertNil(answer.changed)
        }
    }

    /// The tracked branch only local (no remote-tracking ref): said by its
    /// name, counted under the path, compared by its whole ref.
    func testALocalTrackedBranchIsSaidByItsName() async throws {
        let c1 = try await git(["rev-parse", "HEAD"])
        // A tag named like the remote's branch: DWIM would pick it over the remote's.
        try await git(["checkout", "-q", "-b", "fix/orders"])
        let c2 = try await commit("apps/web/caf\u{E9}.yaml", "a name git quotes")
        try await git(["tag", "origin/main", c2])
        let app = object(
            "Application", "acme-web", namespace: "argocd",
            spec: ["source": ["repoURL": "https://git.acme.example/acme/shop.git", "path": "apps/web", "targetRevision": "main"]],
            status: ["history": [["revision": c1]], "sync": ["status": "Synced", "revision": c1]])
        let why = KubeGitOpsMatch.Why.repoAndPath("apps/web", source: nil)
        let question = try XCTUnwrap(KubeGitOpsReach.question(app, why: why, checkout: checkout(head: c2, branch: "fix/orders"), peers: [:]))
        let answer = await KubeGitOpsReach.answer(question, in: root, git: isolated)
        XCTAssertEqual(answer.deployed.text, "manifests at \(c1.prefix(7)), up to date with main; this branch is 1 commit ahead")
        XCTAssertEqual(answer.unchanged, "no change under apps/web, base/web.yaml, components/probe since \(c1.prefix(7)) on main", "counted against refs/heads/main")
        XCTAssertEqual(answer.changed?.files, ["apps/web/caf\u{E9}.yaml"], "as it is on disk, not C-quoted")
        XCTAssertEqual(answer.changed?.against, "main")

        // The local fallback compared by whole ref: `rev-list` never reads a tag named origin/main.
        try await git(["update-ref", "refs/remotes/origin/main", c1])
        let remote = await KubeGitOpsReach.answer(question, in: root, git: isolated)
        XCTAssertEqual(remote.deployed.found?.base, "origin/main")
        XCTAssertEqual(remote.deployed.found?.behind, 0, "refs/remotes/origin/main, not the tag at \(c2.prefix(7))")
    }
}
