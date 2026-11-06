import XCTest

@testable import Overterm

/// A checkout tied to what it deploys (docs/design/kubernetes/analysis.md,
/// 3.1): the guess read from fixture checkouts' files — a chart's name as
/// the release, a kustomization's namespace, manifests' namespaces,
/// workloads and part-of labels, a chart's templates left out —, the walk
/// up to a chart bounded, and the store: kept in a folder of the test's
/// own, keyed by the checkout's real path, nothing written into the
/// checkout.
final class KubeBindingTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("kube-binding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ path: String, _ text: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func checkout(_ name: String) throws -> URL {
        let root = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: Guessing

    func testAChartsNameIsTheRelease() throws {
        let root = try checkout("chart")
        try write("deploy/shop/Chart.yaml", "apiVersion: v2\nname: shop\nversion: 0.1.0\nappVersion: \"1a2b3c4\"\n", in: root)
        try write(
            "deploy/shop/templates/deployment.yaml",
            "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: {{ .Release.Name }}-web\n  namespace: templated\n", in: root)
        let files = KubeCheckoutScan.files(in: root)
        XCTAssertEqual(files.map(\.path), ["deploy/shop/Chart.yaml"], "a chart's templates are Go templates, not manifests")
        let guess = KubeBindingGuess.from(files)
        XCTAssertEqual(guess.release, "shop")
        XCTAssertEqual(guess.selector, "app.kubernetes.io/instance=shop", "Helm's own label for its release")
        XCTAssertNil(guess.namespace)
        XCTAssertEqual(guess.said, "Chart.yaml")
    }

    func testManifestsSayTheNamespaceTheWorkloadsAndTheLabel() throws {
        let root = try checkout("manifests")
        let deployment = """
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: web
              namespace: shop
              labels:
                app.kubernetes.io/part-of: shop
            ---
            apiVersion: v1
            kind: Service
            metadata:
              name: web
              namespace: shop
            """
        try write("k8s/web.yaml", deployment, in: root)
        try write(
            "k8s/db.yml", "apiVersion: apps/v1\nkind: StatefulSet\nmetadata:\n  name: db\n  namespace: shop\n  labels:\n    app.kubernetes.io/part-of: shop\n",
            in: root)
        try write("k8s/agent.yaml", "apiVersion: apps/v1\nkind: DaemonSet\nmetadata:\n  name: agent\n  namespace: kube-system\n", in: root)
        try write("docs/notes.yaml", "title: not a manifest\n", in: root)
        try write(".github/workflows/ci.yaml", "apiVersion: v1\nkind: Pod\nmetadata:\n  name: hidden\n", in: root)
        try write("node_modules/pkg/deploy.yaml", "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: vendored\n", in: root)
        try write("skaffold.yaml", "apiVersion: skaffold/v4beta6\nkind: Config\n", in: root)
        try write("Tiltfile", "k8s_yaml('k8s/web.yaml')\n", in: root)

        let guess = KubeBindingGuess.from(KubeCheckoutScan.files(in: root))
        XCTAssertEqual(guess.namespace, "shop", "the namespace most manifests name")
        XCTAssertEqual(guess.selector, "app.kubernetes.io/part-of=shop")
        XCTAssertEqual(guess.workloads.sorted(), ["deploy/web", "ds/agent", "sts/db"])
        XCTAssertNil(guess.release)
        XCTAssertFalse(guess.files.contains("docs/notes.yaml"), "a YAML that isn't a manifest says nothing")
        XCTAssertFalse(guess.files.contains { $0.hasPrefix(".github") || $0.hasPrefix("node_modules") }, "\(guess.files)")
        XCTAssertTrue(guess.kinds.isSuperset(of: [.skaffold, .tiltfile, .manifest]), "\(guess.kinds)")
        XCTAssertEqual(guess.said, "3 manifests, skaffold.yaml, Tiltfile")
    }

    func testAKustomizationsNamespaceWins() throws {
        let root = try checkout("kustomize")
        try write("overlays/dev/kustomization.yaml", "namespace: shop-dev\nresources:\n  - ../../base\n", in: root)
        try write("base/web.yaml", "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: web\n  namespace: shop\n", in: root)
        let guess = KubeBindingGuess.from(KubeCheckoutScan.files(in: root))
        XCTAssertEqual(guess.namespace, "shop-dev")
        XCTAssertEqual(guess.workloads, ["deploy/web"])
        XCTAssertNil(guess.selector)
        let binding = guess.binding(checkout: root, context: "fake-dev")
        XCTAssertEqual(binding.context, "fake-dev")
        XCTAssertEqual(binding.namespace, "shop-dev")
        XCTAssertEqual(binding.checkout, KubeBindingStore.key(root))
    }

    func testACheckoutWithoutKubernetesFilesGuessesNothing() throws {
        let root = try checkout("plain")
        try write("README.md", "# hello\n", in: root)
        try write("config.yaml", "port: 8080\n", in: root)
        let guess = KubeBindingGuess.from(KubeCheckoutScan.files(in: root))
        XCTAssertTrue(guess.isEmpty)
        XCTAssertEqual(guess.binding(checkout: root, context: "fake-dev").namespace, "default")
    }

    func testTheScanIsBounded() throws {
        let root = try checkout("deep")
        var path = ""
        for depth in 0..<(KubeCheckoutScan.maxDepth + 3) { path += "d\(depth)/" }
        try write(path + "web.yaml", "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: deep\n  namespace: deep\n", in: root)
        XCTAssertTrue(KubeCheckoutScan.files(in: root).isEmpty, "past maxDepth nothing is read")
        for index in 0..<(KubeCheckoutScan.maxFiles + 10) {
            try write("many/m\(index).yaml", "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: m\(index)\n", in: root)
        }
        XCTAssertEqual(KubeCheckoutScan.files(in: root).count, KubeCheckoutScan.maxFiles)
    }

    /// Only a repository's root is guessed from: a tab sitting in a plain
    /// folder, in the home folder or in `/` reads nothing at all.
    func testOnlyARepositorysRootIsGuessedFrom() async throws {
        let manifest = "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: web\n  namespace: shop\n"
        let plain = try checkout("plain-folder")
        try write("k8s/web.yaml", manifest, in: plain)
        XCTAssertFalse(KubeCheckoutScan.isRepositoryRoot(plain))
        let none = await KubeCheckoutScan.guess(plain)
        XCTAssertTrue(none.isEmpty, "a folder that isn't a repository is not walked: \(none)")

        // A home folder, even one that is a repository (dotfiles), is refused outright.
        let home = try checkout("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try write("Documents/k8s/web.yaml", manifest, in: home)
        XCTAssertFalse(KubeCheckoutScan.isRepositoryRoot(home, home: home))
        let fromHome = await KubeCheckoutScan.guess(home, home: home)
        XCTAssertTrue(fromHome.isEmpty, "\(fromHome)")
        XCTAssertFalse(KubeCheckoutScan.isRepositoryRoot(FileManager.default.homeDirectoryForCurrentUser))
        XCTAssertFalse(KubeCheckoutScan.isRepositoryRoot(URL(fileURLWithPath: "/"), exists: { _ in true }), "/ is never a checkout")
        var asked: [String] = []
        _ = KubeCheckoutScan.isRepositoryRoot(home, home: home) {
            asked.append($0); return true
        }
        XCTAssertTrue(asked.isEmpty, "the home folder isn't even looked into")

        // A repository's root (a worktree's .git is a file) is.
        let repo = try checkout("repo")
        try write(".git", "gitdir: /elsewhere\n", in: repo)
        try write("k8s/web.yaml", manifest, in: repo)
        XCTAssertTrue(KubeCheckoutScan.isRepositoryRoot(repo, home: home))
        let guessed = await KubeCheckoutScan.guess(repo, home: home)
        XCTAssertEqual(guessed.namespace, "shop")
    }

    func testLibraryIsPassedOver() throws {
        let root = try checkout("lib")
        try write("Library/Containers/x/web.yaml", "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: web\n", in: root)
        XCTAssertTrue(KubeCheckoutScan.files(in: root).isEmpty)
    }

    func testTheWalkUpToAChartStopsAtTheCheckout() throws {
        let root = try checkout("walk")
        try write("charts/shop/Chart.yaml", "name: shop\n", in: root)
        try write("charts/shop/templates/nested/web.yaml", "kind: x\n", in: root)
        let template = root.appendingPathComponent("charts/shop/templates/nested/web.yaml")
        XCTAssertEqual(
            KubeCheckoutScan.chartRoot(of: template, within: root)?.standardizedFileURL.path,
            root.appendingPathComponent("charts/shop").standardizedFileURL.path)
        XCTAssertNil(KubeCheckoutScan.chartRoot(of: root.appendingPathComponent("k8s/web.yaml"), within: root))
        // A Chart.yaml above the checkout is never reached.
        try write("Chart.yaml", "name: outside\n", in: folder)
        XCTAssertNil(KubeCheckoutScan.chartRoot(of: root.appendingPathComponent("k8s/web.yaml"), within: root))
        // From "/" the walk ends at once, and it is bounded however deep.
        var asked = 0
        XCTAssertNil(
            KubeCheckoutScan.chartRoot(of: URL(fileURLWithPath: "/x"), within: URL(fileURLWithPath: "/")) { _ in
                asked += 1; return false
            })
        XCTAssertLessThanOrEqual(asked, 1)
        let deep = URL(fileURLWithPath: "/" + (0..<200).map { "p\($0)" }.joined(separator: "/") + "/f.yaml")
        asked = 0
        XCTAssertNil(
            KubeCheckoutScan.chartRoot(of: deep, within: URL(fileURLWithPath: "/")) { _ in
                asked += 1; return false
            })
        XCTAssertLessThanOrEqual(asked, KubeCheckoutScan.maxDepth * 4)
    }

    // MARK: Workloads

    func testWorkloadRefs() {
        XCTAssertEqual(KubeWorkloadRef(parsing: "deploy/web"), KubeWorkloadRef(kind: .deployment, name: "web"))
        XCTAssertEqual(KubeWorkloadRef(parsing: " deployments/web ")?.said, "deploy/web")
        XCTAssertEqual(KubeWorkloadRef(parsing: "statefulset/db")?.said, "sts/db")
        XCTAssertEqual(KubeWorkloadRef(parsing: "ds/agent")?.kind, .daemonSet)
        XCTAssertNil(KubeWorkloadRef(parsing: "pod/web"))
        XCTAssertNil(KubeWorkloadRef(parsing: "deploy/a/b"))
        XCTAssertNil(KubeWorkloadRef(parsing: "web"))
        let binding = KubeBinding(checkout: "/x", context: "fake-dev", namespace: "shop", workloads: ["deploy/web"])
        XCTAssertTrue(binding.includes(.deployment, "web"))
        XCTAssertFalse(binding.includes(.deployment, "worker"))
        XCTAssertTrue(KubeBinding(checkout: "/x", context: "fake-dev", namespace: "shop").includes(.statefulSet, "any"), "none named: every one")
    }

    // MARK: The store

    @MainActor
    func testTheStoreKeepsBindingsInItsOwnFolderByRealPath() throws {
        let root = try checkout("bound")
        let file = folder.appendingPathComponent("support/Kubernetes/bindings.json")
        let store = KubeBindingStore(file: file)
        XCTAssertNil(store.binding(for: root))
        // Through a symlink: the same checkout.
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let saved = store.set(
            KubeBinding(
                checkout: link.path, context: " fake-dev ", namespace: "shop", release: "", selector: "app=web", workloads: ["deployment/web", "deploy/web", "x"]))
        XCTAssertTrue(saved)
        let binding = try XCTUnwrap(store.binding(for: root))
        XCTAssertEqual(binding.checkout, FileTreeModel.realPath(root))
        XCTAssertEqual(binding.context, "fake-dev")
        XCTAssertNil(binding.release, "an emptied field is none")
        XCTAssertEqual(binding.workloads, ["deploy/web"], "named once, as kubectl's short name; what isn't one is dropped")
        XCTAssertEqual(store.bindings(on: "fake-dev", namespace: "shop").map(\.checkout), [binding.checkout])
        XCTAssertTrue(store.bindings(on: "fake-dev", namespace: "payments").isEmpty)
        // Several checkouts on one namespace: the one preferred (the selected tab's), else the first.
        let other = try checkout("aaa-worktree")
        XCTAssertTrue(store.set(KubeBinding(checkout: other.path, context: "fake-dev", namespace: "shop")))
        XCTAssertEqual(store.binding(on: "fake-dev", namespace: "shop", preferring: nil)?.checkout, KubeBindingStore.key(other))
        XCTAssertEqual(store.binding(on: "fake-dev", namespace: "shop", preferring: binding)?.checkout, binding.checkout)
        let elsewhere = KubeBinding(checkout: "/x", context: "fake-dev", namespace: "payments")
        XCTAssertEqual(store.binding(on: "fake-dev", namespace: "shop", preferring: elsewhere)?.checkout, KubeBindingStore.key(other), "one bound elsewhere isn't")
        store.remove(other)

        // Read back by another store from the same file.
        let again = KubeBindingStore(file: file)
        XCTAssertEqual(again.binding(for: link), binding)
        XCTAssertFalse(store.set(KubeBinding(checkout: root.path, context: "fake-dev", namespace: " ")), "no namespace, no binding")
        XCTAssertNotNil(store.problem)

        // Nothing of it is in the checkout.
        let inCheckout = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(inCheckout, [])
        store.remove(link)
        XCTAssertNil(KubeBindingStore(file: file).binding(for: root))
    }

    @MainActor
    func testUnitTestsNeverUseTheUsersBindings() {
        XCTAssertFalse(KubeBindingStore.defaultFile.path.hasPrefix(AppEnvironment.supportDirectory.path), KubeBindingStore.defaultFile.path)
        XCTAssertTrue(KubeBindingStore.defaultFile.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }
}
