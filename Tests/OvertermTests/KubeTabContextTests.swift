import Combine
import Darwin
import XCTest

@testable import Overterm

/// Stage 3b's tab context and kubectl helpers (docs/design/kubernetes/analysis.md,
/// 3.11, 2.8, 2.11, decision 18): the pane-header warning's context resolution
/// (flags, pinned, files, "probably"), New Task's pin, Kubernetes snippets,
/// templates and saved filters. Fictional clusters only; nothing reads ~/.kube,
/// nothing runs kubectl.
@MainActor
final class KubeTabContextTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ot-kube-tab-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func list(current: String? = "fake-dev", settings: [String: KubeContextSettings] = [:]) -> KubeContextList {
        let text = """
            apiVersion: v1
            kind: Config
            clusters:
            - name: fake-dev
              cluster: {server: "http://127.0.0.1:1"}
            - name: fake-prod
              cluster: {server: "http://127.0.0.1:1"}
            - name: kind-fake
              cluster: {server: "http://127.0.0.1:1"}
            users:
            - name: anonymous
              user: {}
            contexts:
            - name: fake-dev
              context: {cluster: fake-dev, user: anonymous, namespace: shop}
            - name: fake-prod
              context: {cluster: fake-prod, user: anonymous, namespace: payments}
            - name: kind-fake
              context: {cluster: kind-fake, user: anonymous, namespace: shop}
            \(current.map { "current-context: \($0)" } ?? "")

            """
        let config = Kubeconfig.parse(text, file: dir.appendingPathComponent("config"))!
        return KubeContextList.resolve([config], settings: settings)
    }

    // MARK: The command line

    func testOnlyTheKubectlFamilyIsLookedAt() {
        XCTAssertEqual(KubeCommandLine.parse("kubectl get pods")?.tool, "kubectl")
        XCTAssertEqual(KubeCommandLine.parse("/opt/homebrew/bin/helm list")?.tool, "helm")
        XCTAssertEqual(KubeCommandLine.parse("k9s")?.tool, "k9s")
        XCTAssertEqual(KubeCommandLine.parse("stern web")?.tool, "stern")
        for other in ["git status", "echo kubectl", "kubectx fake-prod", "vim kubectl.yaml", "", "ls | wc -l"] {
            XCTAssertNil(KubeCommandLine.parse(other), other)
        }
    }

    func testTheCommandIsFoundBehindWrappersAndInPipelines() {
        XCTAssertEqual(KubeCommandLine.parse("cd x && kubectl get pods | grep web")?.tool, "kubectl")
        XCTAssertEqual(KubeCommandLine.parse("watch -n 2 kubectl get pods")?.tool, "kubectl")
        XCTAssertEqual(KubeCommandLine.parse("sudo -E helm list")?.tool, "helm")
        XCTAssertEqual(KubeCommandLine.parse("time kubectl get ns; echo done")?.tool, "kubectl")
        XCTAssertEqual(KubeCommandLine.parse("(kubectl get pods)")?.tool, "kubectl")
        // A wrapper's option that takes a value: the value isn't the command.
        XCTAssertEqual(KubeCommandLine.parse("sudo -u root kubectl delete pod web")?.tool, "kubectl")
        XCTAssertEqual(KubeCommandLine.parse("sudo -E -u ali kubectl --context fake-prod get pods")?.context, "fake-prod")
        XCTAssertEqual(KubeCommandLine.parse("sudo --user root -g staff helm list")?.tool, "helm")
        XCTAssertEqual(KubeCommandLine.parse("env -u FOO kubectl get pods")?.tool, "kubectl")
        XCTAssertEqual(KubeCommandLine.parse("env -u FOO KUBECONFIG=/tmp/a kubectl get pods")?.kubeconfig, "/tmp/a")
        XCTAssertEqual(KubeCommandLine.parse("watch -n 2 -d kubectl get pods")?.tool, "kubectl")
        XCTAssertNil(KubeCommandLine.parse("sudo -u root vim kubectl.yaml"))
    }

    func testFlagsSayTheContextAndTheKubeconfig() {
        XCTAssertEqual(KubeCommandLine.parse("kubectl --context fake-prod get pods")?.context, "fake-prod")
        XCTAssertEqual(KubeCommandLine.parse("kubectl get pods --context=fake-prod")?.context, "fake-prod")
        XCTAssertEqual(KubeCommandLine.parse("kubectl --context 'acme prod' get pods")?.context, "acme prod")
        // helm's is --kube-context; its --context isn't one.
        XCTAssertEqual(KubeCommandLine.parse("helm --kube-context fake-prod list")?.context, "fake-prod")
        XCTAssertNil(KubeCommandLine.parse("helm --context fake-prod list")?.context)
        XCTAssertEqual(KubeCommandLine.parse("k9s --context fake-prod")?.context, "fake-prod")
        XCTAssertEqual(KubeCommandLine.parse("kubectl --kubeconfig ~/kc get pods")?.kubeconfig, "~/kc")
        XCTAssertEqual(KubeCommandLine.parse("KUBECONFIG=/tmp/a kubectl get pods")?.kubeconfig, "/tmp/a")
        XCTAssertEqual(KubeCommandLine.parse("env KUBECONFIG=/tmp/a kubectl get pods")?.kubeconfig, "/tmp/a")
        // After --, nothing is a flag of kubectl's.
        XCTAssertNil(KubeCommandLine.parse("kubectl exec web -- sh --context fake-prod")?.context)
        // A quoted operator is a word.
        XCTAssertEqual(KubeCommandLine.parse("kubectl get pods -l 'a=b|c' --context fake-prod")?.context, "fake-prod")
    }

    // MARK: The warning: flags, pinned, files, "probably"

    private func warning(
        _ command: String, pin: KubeTerminalPin? = nil, lost: Bool = false, ambient: KubeContextList? = nil,
        named: [String: KubeContextList] = [:], settings: [String: KubeContextSettings] = [:]
    ) -> KubePaneWarning? {
        KubePaneWarning.resolve(command: command, pin: pin, lost: lost, ambient: ambient ?? list(), kubeconfig: { named[$0] }, settings: settings)
    }

    func testTheFilesCurrentContextIsOnlyProbably() {
        let found = warning("kubectl delete pod web", ambient: list(current: "fake-prod"))
        XCTAssertEqual(found?.context, "fake-prod")
        XCTAssertEqual(found?.isProduction, true)
        XCTAssertEqual(found?.source, .files)
        XCTAssertEqual(found?.probably, true)
        XCTAssertEqual(found?.shown, true)
        XCTAssertEqual(found?.label, "⎈ probably fake-prod")
        XCTAssertTrue(found?.help.contains("KUBECONFIG exported in this shell") == true)
        // Not production: nothing shown.
        XCTAssertEqual(warning("kubectl get pods")?.shown, false)
        // No current context: nothing reached, nothing said.
        XCTAssertNil(warning("kubectl get pods", ambient: list(current: nil)))
        XCTAssertNil(warning("git push", ambient: list(current: "fake-prod")))
    }

    func testAFlagWinsAndIsCertain() {
        let found = warning("kubectl --context fake-prod get pods", ambient: list(current: "fake-dev"))
        XCTAssertEqual(found?.context, "fake-prod")
        XCTAssertEqual(found?.source, .flag)
        XCTAssertEqual(found?.probably, false)
        XCTAssertEqual(found?.label, "⎈ fake-prod")
        // And over a pin.
        let pinned = KubeTerminalPin(context: "fake-dev", cluster: "fake-dev", user: "anonymous", namespace: "shop", displayName: "fake-dev", isProduction: false)
        XCTAssertEqual(warning("helm --kube-context fake-prod list", pin: pinned)?.isProduction, true)
        // A name the files don't have is classed by its name.
        XCTAssertEqual(warning("kubectl --context acme-prod get pods")?.isProduction, true)
        XCTAssertEqual(warning("kubectl --context acme-staging get pods")?.isProduction, false)
    }

    func testAKubeconfigFlagIsThatFilesCurrentContext() {
        let found = warning("kubectl --kubeconfig /tmp/prod.yaml get pods", named: ["/tmp/prod.yaml": list(current: "fake-prod")])
        XCTAssertEqual(found?.source, .kubeconfigFlag)
        XCTAssertEqual(found?.isProduction, true)
        // Unread yet: nothing guessed from the pane's own files.
        XCTAssertNil(warning("kubectl --kubeconfig /tmp/other.yaml get pods", ambient: list(current: "fake-prod")))
        // KUBECONFIG= before the command is the same.
        XCTAssertEqual(warning("KUBECONFIG=/tmp/prod.yaml kubectl get pods", named: ["/tmp/prod.yaml": list(current: "fake-prod")])?.source, .kubeconfigFlag)
    }

    func testARelativeKubeconfigIsTheCommandsFolders() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        XCTAssertEqual(KubePaneWarning.kubeconfigKey("./prod.yaml", cwd: "/work/shop", home: home), "/work/shop/prod.yaml")
        XCTAssertEqual(KubePaneWarning.kubeconfigKey("prod.kubeconfig", cwd: "/work/shop", home: home), "/work/shop/prod.kubeconfig")
        XCTAssertEqual(KubePaneWarning.kubeconfigKey("../ops/kc", cwd: "/work/shop", home: home), "/work/ops/kc")
        XCTAssertEqual(KubePaneWarning.kubeconfigKey("$HOME/.kube/prod", cwd: nil, home: home), "/Users/someone/.kube/prod")
        XCTAssertEqual(KubePaneWarning.kubeconfigKey("${HOME}/kc:~/b", cwd: nil, home: home), "/Users/someone/kc:/Users/someone/b")
        // Nowhere to place it: nothing.
        XCTAssertNil(KubePaneWarning.kubeconfigKey("./prod.yaml", cwd: nil, home: home))
        // Resolved as the warning resolves it: that file's current context, production.
        let named = ["/work/shop/prod.yaml": list(current: "fake-prod")]
        let found = KubePaneWarning.resolve(
            command: "kubectl --kubeconfig ./prod.yaml delete pod web", pin: nil, lost: false, ambient: list(),
            kubeconfig: { KubePaneWarning.kubeconfigKey($0, cwd: "/work/shop", home: home).flatMap { named[$0] } }, settings: [:])
        XCTAssertEqual(found?.source, .kubeconfigFlag)
        XCTAssertEqual(found?.isProduction, true)
        XCTAssertEqual(found?.shown, true)
    }

    func testAContextInAPinnedPaneIsLookedUpInThePanesOwnFiles() {
        // `ops` is only in an extra file (kubernetes.kubeconfigs): its cluster's name says production.
        let text = """
            apiVersion: v1
            kind: Config
            clusters:
            - name: acme-prod-eu
              cluster: {server: "http://127.0.0.1:1"}
            users:
            - name: anonymous
              user: {}
            contexts:
            - name: ops
              context: {cluster: acme-prod-eu, user: anonymous}

            """
        let extra = KubeContextList.resolve([Kubeconfig.parse(text, file: dir.appendingPathComponent("extra"))!], settings: [:])
        let pin = KubeTerminalPin(context: "fake-dev", cluster: "fake-dev", user: "anonymous", namespace: "shop", displayName: "fake-dev", isProduction: false)
        let found = KubePaneWarning.resolve(
            command: "kubectl --context ops delete pod web", pin: pin, lost: false, ambient: list(), paneFiles: extra, kubeconfig: { _ in nil },
            settings: [:])
        XCTAssertEqual(found?.isProduction, true)
        XCTAssertEqual(found?.shown, true)
        // Without the pane's files, the ambient ones don't know it: classed by its name only.
        XCTAssertEqual(warning("kubectl --context ops delete pod web", pin: pin)?.isProduction, false)
    }

    func testAGuardedRunReadsNoKubeconfigACommandNamesOutsideItsOwn() {
        let own = dir.appendingPathComponent("fake.yaml")
        let pins = dir.appendingPathComponent("Contexts", isDirectory: true)
        let work = URL(fileURLWithPath: "/Users/someone/work/prod.yaml")
        let pinFile = pins.appendingPathComponent("abc-def-1.yaml")
        XCTAssertEqual(KubeAmbientContexts.admitted([work], guarded: true, permitted: [own], pinFolder: pins), [])
        XCTAssertEqual(KubeAmbientContexts.admitted([own, work, pinFile], guarded: true, permitted: [own], pinFolder: pins), [own, pinFile])
        // Not guarded: the user's own files are the user's to read.
        XCTAssertEqual(KubeAmbientContexts.admitted([work], guarded: false, permitted: [], pinFolder: pins), [work])
    }

    func testTheWatchIsTheFilesAndTheirFoldersAndSaysWhatIsMissing() async throws {
        let file = dir.appendingPathComponent("config")
        try "current-context: fake-dev\n".write(to: file, atomically: false, encoding: .utf8)
        let gone = dir.appendingPathComponent("not-yet/config")
        let changed = expectation(description: "an in-place write is seen")
        changed.assertForOverFulfill = false
        let watcher = KubeconfigFileWatcher(files: [file, gone]) { changed.fulfill() }
        XCTAssertEqual(watcher.missing, [gone.deletingLastPathComponent().path])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("# kubectx\n".utf8))
        try handle.close()
        await fulfillment(of: [changed], timeout: 5)
        watcher.stop()
    }

    /// A FIFO with no writer, or a device, named by `--kubeconfig` in any
    /// pane's title: never opened — opening one blocked the main thread
    /// for good. Each is asked off the main thread here, with a deadline.
    func testAFIFOOrADeviceIsNeverOpenedForTheWatch() throws {
        let fifo = dir.appendingPathComponent("kc.fifo").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        var devices = ["/dev/null"]
        if FileManager.default.fileExists(atPath: "/dev/tty.Bluetooth-Incoming-Port") { devices.append("/dev/tty.Bluetooth-Incoming-Port") }
        let file = dir.appendingPathComponent("config")
        try "current-context: fake-dev\n".write(to: file, atomically: false, encoding: .utf8)
        for (path, watched) in [(fifo, false), (file.path, true), (dir.path, true)] + devices.map({ ($0, false) }) {
            XCTAssertEqual(KubeconfigFileWatcher.isSpecial(path), !watched, path)
            let done = DispatchSemaphore(value: 0)
            let made = Box()
            Thread.detachNewThread {
                let source = KubeconfigFileWatcher.source(path, mask: [.write], {})
                made.value = source != nil
                source?.cancel()
                done.signal()
            }
            XCTAssertEqual(done.wait(timeout: .now() + 2), .success, "\(path) blocked")
            XCTAssertEqual(made.value, watched, path)
        }
        XCTAssertFalse(KubeconfigFileWatcher.isSpecial(dir.appendingPathComponent("not-there").path))
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    func testThePinSettlesItWithoutAFlag() {
        let prod = KubeTerminalPin(
            context: "fake-prod", cluster: "fake-prod", user: "anonymous", namespace: "payments", displayName: "fake-prod", isProduction: true)
        let found = warning("kubectl get pods", pin: prod, ambient: list(current: "fake-dev"))
        XCTAssertEqual(found?.source, .pinned)
        XCTAssertEqual(found?.isProduction, true)
        // The pin's own label says production already: not said twice.
        XCTAssertEqual(found?.shown, false)
        // A dev pin over a production current context: the pin wins, nothing shown.
        let dev = KubeTerminalPin(context: "fake-dev", cluster: "fake-dev", user: "anonymous", namespace: "shop", displayName: "fake-dev", isProduction: false)
        XCTAssertEqual(warning("kubectl delete pod web", pin: dev, ambient: list(current: "fake-prod"))?.context, "fake-dev")
        // A lost pin's KUBECONFIG is /dev/null: nothing reached.
        XCTAssertNil(warning("kubectl get pods", pin: nil, lost: true, ambient: list(current: "fake-prod")))
        // A class set in Settings counts now.
        let classed = warning("kubectl get pods", pin: dev, settings: ["fake-dev": KubeContextSettings(contextClass: .production)])
        XCTAssertEqual(classed?.isProduction, true)
    }

    // MARK: New Task's pin

    func testNewTaskOffersEveryContextButProductionTheBoundFirst() {
        let binding = KubeBinding(checkout: "/work/shop", context: "kind-fake", namespace: "checkout")
        let offer = KubeTaskPin.offer(list(), binding: binding)
        XCTAssertEqual(offer.choices.map(\.context), ["kind-fake", "fake-dev"])
        XCTAssertEqual(offer.suggested, "kind-fake")
        XCTAssertEqual(offer.choices.first?.namespace, "checkout")
        XCTAssertEqual(offer.choices.first?.title, "kind-fake · checkout")
        XCTAssertNil(offer.choices.last?.namespace)
        XCTAssertNil(offer.note)
        // No binding: offered, none suggested.
        XCTAssertNil(KubeTaskPin.offer(list(), binding: nil).suggested)
        // Bound to production: not offered, and said.
        let prod = KubeTaskPin.offer(list(), binding: KubeBinding(checkout: "/work/shop", context: "fake-prod", namespace: "payments"))
        XCTAssertFalse(prod.choices.contains { $0.context == "fake-prod" })
        XCTAssertNil(prod.suggested)
        XCTAssertTrue(prod.note?.contains("production") == true)
        // Read again as it is made.
        XCTAssertNotNil(KubeTaskPin.refused("fake-prod", in: list()))
        XCTAssertNotNil(KubeTaskPin.refused("gone", in: list()))
        XCTAssertNil(KubeTaskPin.refused("fake-dev", in: list()))
    }

    // MARK: Snippets

    private let pod = KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "web-7d9")

    func testASnippetWithKubernetesPlaceholdersIsOneOnTheObjectsItFits() {
        let logs = Snippet(name: "Tail", command: "kubectl --context ${context} -n ${namespace} logs ${pod} -c ${container} --tail=50")
        let describe = Snippet(name: "Describe", command: "kubectl --context ${context} -n ${namespace} describe ${kind} ${name}")
        let plain = Snippet(name: "Status", command: "git status")
        XCTAssertTrue(KubeSnippet.isKubernetes(logs))
        XCTAssertFalse(KubeSnippet.isKubernetes(plain))
        XCTAssertTrue(KubeSnippet.offered(logs, on: pod, shownNamespace: "shop"))
        XCTAssertFalse(KubeSnippet.offered(plain, on: pod, shownNamespace: "shop"))
        let deploy = KubeObjectRef(
            context: "fake-dev",
            kind: KubeResourceKind(
                group: "apps", version: "v1", resource: "deployments", kind: "Deployment", singular: "deployment", namespaced: true, verbs: ["list"],
                shortNames: ["deploy"]), namespace: "shop", name: "web")
        XCTAssertFalse(KubeSnippet.offered(logs, on: deploy, shownNamespace: "shop"), "a pod's placeholders only on a pod")
        XCTAssertTrue(KubeSnippet.offered(describe, on: deploy, shownNamespace: "shop"))
        let node = KubeObjectRef(
            context: "fake-dev",
            kind: KubeResourceKind(group: "", version: "v1", resource: "nodes", kind: "Node", singular: "node", namespaced: false, verbs: ["list"]),
            namespace: nil, name: "fake-node-1")
        XCTAssertFalse(KubeSnippet.offered(describe, on: node, shownNamespace: nil), "no namespace to give it")
        XCTAssertTrue(KubeSnippet.offered(describe, on: node, shownNamespace: "shop"))
    }

    func testValuesAreQuotedForZsh() {
        let values = KubeSnippet.values(for: pod, namespace: "shop", container: "app")
        XCTAssertEqual(
            KubeSnippet.fill("kubectl --context ${context} -n ${namespace} logs ${pod} -c ${container}", values: values),
            "kubectl --context fake-dev -n shop logs web-7d9 -c app")
        let odd = KubeObjectRef(context: "arn:aws:eks:x:1:cluster/acme prod's", kind: .pods, namespace: "shop", name: "web")
        let filled = KubeSnippet.fill("kubectl --context ${context} get pod ${name}; echo $(id)", values: KubeSnippet.values(for: odd, namespace: "shop", container: nil))
        XCTAssertEqual(filled, #"kubectl --context 'arn:aws:eks:x:1:cluster/acme prod'\''s' get pod web; echo $(id)"#)
        XCTAssertEqual(KubeSnippet.missing("x ${container}", values: KubeSnippet.values(for: pod, namespace: "shop", container: nil)), ["container"])
        // A value holding a placeholder stays that text, in its own quotes: one pass.
        let tricky = KubeObjectRef(context: "a${namespace}b", kind: .pods, namespace: "shop", name: "web")
        XCTAssertEqual(
            KubeSnippet.fill("kubectl --context ${context} -n ${namespace} get pod ${pod}", values: KubeSnippet.values(for: tricky, namespace: "sh op", container: nil)),
            "kubectl --context 'a${namespace}b' -n 'sh op' get pod web")
        XCTAssertEqual(KubeSnippet.fill("echo ${other} ${ unclosed", values: ["other": "x"]), "echo ${other} ${ unclosed")
        // A namespace's own row gives its name.
        let namespace = KubeObjectRef(
            context: "fake-dev",
            kind: KubeResourceKind(group: "", version: "v1", resource: "namespaces", kind: "Namespace", singular: "namespace", namespaced: false, verbs: ["list"]),
            namespace: nil, name: "billing")
        XCTAssertEqual(KubeSnippet.namespace(of: namespace, shown: "shop"), "billing")
        XCTAssertEqual(KubeSnippet.values(for: pod, namespace: "shop", container: nil)["kind"], "po")
    }

    // MARK: Templates

    private var repoTemplates: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/kubernetes/templates", isDirectory: true)
    }

    func testEveryBundledTemplateIsAManifestWithANamespacePlaceholder() throws {
        let templates = KubeTemplates.list(bundled: repoTemplates, user: nil)
        XCTAssertGreaterThanOrEqual(templates.count, 10)
        for kind in ["Deployment", "Service", "ConfigMap", "Secret", "Ingress", "Job", "CronJob", "Role", "RoleBinding", "ServiceAccount", "ResourceQuota"] {
            XCTAssertTrue(templates.contains { $0.kind == kind }, kind)
        }
        for template in templates {
            let text = try XCTUnwrap(KubeTemplates.read(template.file))
            XCTAssertTrue(text.contains("namespace: ${namespace}"), template.name)
            let filled = KubeTemplates.text(text, kind: template.kind, context: "fake-dev", production: false, namespace: "shop")
            XCTAssertFalse(filled.contains("${"), template.name)
            let objects = try KubeManifest.parse(filled)
            XCTAssertEqual(objects.count, 1, template.name)
            XCTAssertEqual(objects.first?.namespace, "shop", template.name)
            XCTAssertEqual(objects.first?.kind, template.kind, template.name)
        }
        // A Secret's template holds no value.
        let secret = try XCTUnwrap(templates.first { $0.kind == "Secret" })
        XCTAssertTrue(try XCTUnwrap(KubeTemplates.read(secret.file)).contains("password: \"\""))
    }

    func testTheUsersTemplateReplacesOneOfTheSameName() throws {
        let user = dir.appendingPathComponent("Templates", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: ours\n  namespace: ${namespace}\n".write(
            to: user.appendingPathComponent("deployment.yaml"), atomically: true, encoding: .utf8)
        try "not a manifest\n".write(to: user.appendingPathComponent("notes.yaml"), atomically: true, encoding: .utf8)
        let templates = KubeTemplates.list(bundled: repoTemplates, user: user)
        let deployment = try XCTUnwrap(templates.first { $0.name == "deployment" })
        XCTAssertTrue(deployment.isUsers)
        XCTAssertEqual(templates.filter { $0.name == "deployment" }.count, 1)
        XCTAssertFalse(templates.contains { $0.name == "notes" })
        // Its header says where it goes; a namespace that would read otherwise is quoted.
        let text = KubeTemplates.text("metadata:\n  namespace: ${namespace}\n", kind: "Deployment", context: "fake-prod", production: true, namespace: "yes")
        XCTAssertTrue(text.hasPrefix("# A new Deployment from a template — PRODUCTION · fake-prod · namespace yes\n"), text)
        XCTAssertTrue(text.contains("namespace: \"yes\""), text)
    }

    func testATemplatesCopyIsPrivateAndGoesWithItsTab() throws {
        let url = try KubeManifestEdits.writeTemplate("apiVersion: v1\nkind: ConfigMap\n", name: "configmap")
        defer { KubeManifestEdits.remove(url) }
        XCTAssertTrue(KubeManifestEdits.isTemplate(url))
        XCTAssertNil(KubeManifestEdits.edit(at: url), "not an object's copy")
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(lstat(url.deletingLastPathComponent().path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        KubeManifestEdits.remove(url)
        XCTAssertFalse(KubeManifestEdits.isTemplate(url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Saved filters

    func testSavedFiltersAreKeptPerContextByName() throws {
        let file = dir.appendingPathComponent("Kubernetes/filters.json")
        let store = KubeSavedFilters(file: file)
        let kind = KubeSavedFilter.Kind(.pods)
        XCTAssertTrue(store.save(KubeSavedFilter(name: "failing", context: "fake-dev", kind: kind, namespace: "shop", filter: "status:crashloopbackoff")))
        XCTAssertTrue(store.save(KubeSavedFilter(name: "failing", context: "fake-prod", kind: kind, namespace: nil, filter: "status:error")))
        // The same name on the same context replaces it.
        XCTAssertTrue(store.save(KubeSavedFilter(name: "failing", context: "fake-dev", kind: kind, namespace: "shop", filter: "label:app=web")))
        XCTAssertFalse(store.save(KubeSavedFilter(name: " ", context: "fake-dev", kind: kind, namespace: nil, filter: "x")))
        XCTAssertFalse(store.save(KubeSavedFilter(name: "empty", context: "fake-dev", kind: kind, namespace: nil, filter: "  ")))
        XCTAssertEqual(store.filters(on: "fake-dev").map(\.filter), ["label:app=web"])
        XCTAssertEqual(store.filters(on: "fake-prod").map(\.filter), ["status:error"])
        XCTAssertEqual(store.filters(on: "fake-prod").first?.said, "Pod · all namespaces · fake-prod")
        // Read back from the file.
        let again = KubeSavedFilters(file: file)
        XCTAssertEqual(again.all.count, 2)
        XCTAssertEqual(again.filters(on: "fake-dev").first?.kind.resourceKind.fullName, "pods")
        XCTAssertEqual(again.filters(on: "fake-dev").first?.namespace, "shop")
        again.remove(try XCTUnwrap(again.filters(on: "fake-prod").first).id)
        XCTAssertEqual(KubeSavedFilters(file: file).all.map(\.context), ["fake-dev"])
    }

    func testReadingTheFiltersPublishesNothing() throws {
        let file = dir.appendingPathComponent("Kubernetes/filters.json")
        KubeSavedFilters(file: file).save(KubeSavedFilter(name: "web", context: "fake-dev", kind: .init(.pods), namespace: nil, filter: "web"))
        let store = KubeSavedFilters(file: file)
        var published = 0
        let observer = store.objectWillChange.sink { published += 1 }
        XCTAssertEqual(store.filters(on: "fake-dev").count, 1)
        XCTAssertEqual(store.all.count, 1)
        XCTAssertEqual(published, 0, "a view's body reads it")
        observer.cancel()
    }

    func testAnUnreadableFiltersFileIsSetAsideNotWrittenOver() throws {
        let file = dir.appendingPathComponent("filters.json")
        try "{not json".write(to: file, atomically: true, encoding: .utf8)
        let store = KubeSavedFilters(file: file)
        XCTAssertTrue(store.all.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("filters.unreadable-") }, "\(names)")
    }
}
