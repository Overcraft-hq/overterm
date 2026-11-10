import Foundation

/// The fixture checkout the Kubernetes scenarios bind (gitops.md 8.4): a
/// repository of the run's own in its scratch folder — `k8s/api.yaml`
/// naming namespace shop and `app.kubernetes.io/part-of: ot-shop`,
/// committed on main as `c1` (what is deployed), and a branch
/// `fix/orders` one commit ahead. Its git runs with the developer's
/// config left out (`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM`),
/// so no `insteadOf` or hook of theirs changes what a scenario sees.
struct E2EKubeCheckoutFixture {
    let repo: URL
    /// main's commit: the one the cluster has.
    let c1: String

    /// `c1`'s seven characters.
    var short: String { String(c1.prefix(7)) }

    /// Made afresh at `scratch/<name>`; nil when git couldn't.
    static func make(in scratch: URL, name: String = "ot-kube-shop") async -> E2EKubeCheckoutFixture? {
        let repo = scratch.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.createDirectory(at: repo.appendingPathComponent("k8s"), withIntermediateDirectories: true)
        let manifest =
            "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: shop-api\n  namespace: shop\n  labels:\n    app.kubernetes.io/part-of: ot-shop\n"
        try? manifest.write(to: repo.appendingPathComponent("k8s/api.yaml"), atomically: true, encoding: .utf8)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        try? await git(["add", "k8s/api.yaml"], in: repo)
        try? await git(["commit", "-q", "-m", "shop-api"], in: repo)
        let c1 = ((try? await git(["rev-parse", "HEAD"], in: repo)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        try? await git(["checkout", "-q", "-b", "fix/orders"], in: repo)
        try? "fix\n".write(to: repo.appendingPathComponent("FIX"), atomically: true, encoding: .utf8)
        try? await git(["add", "FIX"], in: repo)
        try? await git(["commit", "-q", "-m", "the fix"], in: repo)
        guard c1.count == 40 else { return nil }
        return E2EKubeCheckoutFixture(repo: repo, c1: c1)
    }

    /// git in the fixture, isolated from the developer's config.
    @discardableResult
    static func git(_ arguments: [String], in repo: URL) async throws -> String {
        let env = ["GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1"]
        let identity = ["-c", "user.email=e2e@overterm", "-c", "user.name=e2e", "-c", "commit.gpgsign=false"]
        return try await Git.run(URL(fileURLWithPath: "/usr/bin/env"), env + ["/usr/bin/git"] + identity + arguments, in: repo)
    }

    @discardableResult
    func git(_ arguments: [String]) async throws -> String { try await Self.git(arguments, in: repo) }
}
