import Foundation
import XCTest

@testable import Overterm

/// A bound release upgraded from the checkout's chart (stage 3a): the
/// chart found, `helm template`'s inputs — arguments, no kube setting
/// (`KUBECONFIG=/dev/null`), the release's values on stdin, never a file —,
/// the diff masked on both sides, the upgrade's line and its guard path:
/// refused on read-only contexts, reviewed, confirmed, the name typed on
/// production. helm itself is a stand-in script; the release is the
/// fake's, on a socket of the test's own.
final class KubeHelmUpgradeTests: XCTestCase {
    private let password = "acme-unit-helm-pw-Q4z8"

    private func context(_ name: String, settings: KubeContextSettings = KubeContextSettings(), session: Bool = false) -> KubeContext {
        KubeWritesTests.context(name, settings: settings, session: session)
    }

    // MARK: The chart

    func testTheChartIsTheOneNamedForTheRelease() {
        let root = URL(fileURLWithPath: "/repo")
        let files = [
            KubeCheckoutFile(path: "charts/cache/Chart.yaml", kind: .chart, text: "apiVersion: v2\nname: cache\nversion: 0.1.0\n"),
            KubeCheckoutFile(path: "deploy/web/Chart.yaml", kind: .chart, text: "apiVersion: v2\nname: web\nversion: 1.5.0\n"),
            KubeCheckoutFile(path: "k8s/api.yaml", kind: .manifest, text: "apiVersion: v1\nkind: Service\n"),
        ]
        XCTAssertEqual(KubeHelmUpgrade.chart(in: files, release: "web", root: root)?.path, "/repo/deploy/web")
        XCTAssertNil(KubeHelmUpgrade.chart(in: files, release: "other", root: root), "two charts, neither named so")
        XCTAssertEqual(KubeHelmUpgrade.chart(in: [files[0]], release: "other", root: root)?.path, "/repo/charts/cache", "the only one")
        XCTAssertNil(KubeHelmUpgrade.chart(in: [files[2]], release: "web", root: root))
        XCTAssertEqual(KubeHelmUpgrade.chartInfo(files[1].text).said, "web-1.5.0")
    }

    // MARK: helm template

    func testHelmTemplateIsGivenTheValuesOnStdinAndNoCluster() {
        XCTAssertEqual(
            KubeHelmTemplate.arguments(release: "web", chart: "/repo/chart", namespace: "shop"),
            ["template", "web", "/repo/chart", "--namespace", "shop", "--values", "-", "--is-upgrade"])
        // The cluster's version and what it serves, as helm upgrade will see them.
        let discovery = KubeDiscovery(kinds: [
            KubeResourceKind(group: "", version: "v1", resource: "pods", kind: "Pod", singular: "pod", namespaced: true, verbs: ["list"]),
            KubeWritesTests.deployments,
            KubeResourceKind(
                group: "monitoring.coreos.com", version: "v1", resource: "servicemonitors", kind: "ServiceMonitor", singular: "servicemonitor",
                namespaced: true, verbs: ["list"]),
        ])
        let capabilities = KubeHelmCapabilities(
            version: KubeServerVersion(major: "1", minor: "34", gitVersion: "v1.34.1"), discovery: discovery)
        XCTAssertEqual(
            KubeHelmTemplate.arguments(release: "web", chart: "/c", namespace: "s", capabilities: capabilities).suffix(4),
            [
                "--kube-version", "v1.34.1", "--api-versions",
                "apps/v1,apps/v1/Deployment,monitoring.coreos.com/v1,monitoring.coreos.com/v1/ServiceMonitor,v1,v1/Pod",
            ])
        XCTAssertEqual(KubeHelmCapabilities(version: nil, discovery: nil).arguments, [], "unknown: helm's own")
        let environment = KubeHelmTemplate.environment(
            base: [
                "PATH": "/usr/bin", "KUBECONFIG": "/Users/someone/.kube/config", "HELM_KUBECONTEXT": "acme-prod", "HELM_KUBETOKEN": "t",
                "AWS_PROFILE": "acme", "HELM_DRIVER": "sql",
            ], guarded: true, scratch: "/tmp/ot-helm")
        XCTAssertEqual(environment["KUBECONFIG"], "/dev/null", "not even a lookup reaches a cluster")
        XCTAssertNil(environment["HELM_KUBECONTEXT"])
        XCTAssertNil(environment["HELM_KUBETOKEN"])
        XCTAssertNil(environment["AWS_PROFILE"])
        XCTAssertNil(environment["HELM_DRIVER"])
        XCTAssertEqual(environment["HELM_CONFIG_HOME"], "/tmp/ot-helm/config", "guarded: helm's folders the run's")
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertNil(KubeHelmTemplate.environment(base: [:], guarded: false, scratch: "/x")["HELM_CONFIG_HOME"])
        XCTAssertTrue(KubeProcessCheck.rule(.helmTemplate, for: context("fake-prod")).allowed, "it changes nothing: every class")
    }

    func testTheStandInHelmGetsTheValuesThroughAPipe() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kube-helm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("log")
        let script = folder.appendingPathComponent("helm")
        // It says what it was given — never the values themselves — and renders one object.
        try """
        #!/bin/sh
        input=$(cat)
        case "$input" in *replicaCount*) given=yes ;; *) given=no ;; esac
        printf 'args=%s\\nkubeconfig=%s\\nvalues=%s\\nstdin=%s\\n' "$*" "$KUBECONFIG" "$given" "$(ls -l /dev/fd/0 2>/dev/null | grep -c pipe)" > '\(log.path)'
        printf -- '---\\n# Source: web/templates/deployment.yaml\\napiVersion: apps/v1\\nkind: Deployment\\nmetadata:\\n  name: web\\nspec:\\n  replicas: 3\\n'
        """.write(to: script, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(script.path, 0o755), 0)
        let values = Data(#"{"auth":{"password":"\#(password)"},"replicaCount":3}"#.utf8)
        let rendered = try await KubeHelmTemplate.render(
            chart: folder, release: "web", namespace: "shop", values: values, context: context("kind-fake"), configured: script.path)
        XCTAssertTrue(rendered.contains("replicas: 3"), rendered)
        let said = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(said.contains("args=template web \(folder.path) --namespace shop --values - --is-upgrade"), said)
        XCTAssertTrue(said.contains("kubeconfig=/dev/null"), said)
        XCTAssertTrue(said.contains("values=yes"), "the release's values came on stdin: \(said)")
        XCTAssertFalse(said.contains(password))
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(left, ["helm", "log"], "no values file written anywhere here")
        let scratch = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
        XCTAssertFalse(scratch.contains { $0.hasPrefix("overterm-helm-\(getpid())") }, "the run's helm folders removed after it")
        // helm failing: its last line said, scrubbed.
        try "#!/bin/sh\ncat >/dev/null\necho 'Error: template: web/templates/x.yaml: password \(password) is wrong token=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.abc' >&2\nexit 1\n".write(
            to: script, atomically: true, encoding: .utf8)
        do {
            _ = try await KubeHelmTemplate.render(chart: folder, release: "web", namespace: "shop", values: values, context: context("kind-fake"), configured: script.path)
            XCTFail("it failed")
        } catch let problem as KubeHelmTemplate.Problem {
            XCTAssertTrue(problem.description.hasPrefix("helm template \(folder.lastPathComponent) failed: Error: template"), problem.description)
            XCTAssertFalse(problem.description.contains("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.abc"), "a token scrubbed")
        }
        do {
            _ = try await KubeHelmTemplate.render(chart: folder, release: "web", namespace: "shop", values: values, context: context("kind-fake"), configured: "")
            XCTFail("guarded, with no helm named, nothing runs")
        } catch let problem as KubeHelmTemplate.Problem {
            XCTAssertEqual(problem.description, "No helm: kubernetes.helmPath names none.")
        }
    }

    func testAProcessIsFedItsInputAndSeesEndOfFile() {
        let big = Data(String(repeating: "x", count: 300_000).utf8)
        let result = KubeProcessRun.run(URL(fileURLWithPath: "/usr/bin/wc"), ["-c"], environment: [:], timeout: 10, input: big)
        XCTAssertEqual(result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "300000", "more than a pipe holds, all of it")
        let none = KubeProcessRun.run(URL(fileURLWithPath: "/usr/bin/wc"), ["-c"], environment: [:], timeout: 10)
        XCTAssertEqual(none?.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "0", "else /dev/null")
    }

    // MARK: The diff

    private var current: String {
        """
        ---
        # Source: web/templates/secret.yaml
        apiVersion: v1
        kind: Secret
        metadata:
          name: web-auth
        data:
          password: \(Data(password.utf8).base64EncodedString())
          username: d2Vi
        ---
        # Source: web/templates/deployment.yaml
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: web
        spec:
          replicas: 1
          template:
            spec:
              containers:
              - name: app
                image: nginx:1.27
                env:
                - name: DB_PASSWORD
                  value: \(password)
        ---
        # Source: web/templates/old.yaml
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: web-old
        data:
          url: postgres://web:\(password)@db:5432/shop
        """
    }

    private var rendered: String {
        """
        ---
        # Source: web/templates/secret.yaml
        apiVersion: v1
        kind: Secret
        metadata:
          name: web-auth
        data:
          password: \(Data("acme-unit-new-pw".utf8).base64EncodedString())
          username: d2Vi
        ---
        # Source: web/templates/deployment.yaml
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: web
        spec:
          replicas: 3
          template:
            spec:
              containers:
              - name: app
                image: nginx:1.27
                env:
                - name: DB_PASSWORD
                  value: \(password)
        ---
        # Source: web/templates/service.yaml
        apiVersion: v1
        kind: Service
        metadata:
          name: web
        spec:
          ports:
          - port: 80
        ---
        # Source: web/templates/empty.yaml
        # nothing rendered
        ---
        this: [is not, yaml
        """
    }

    func testTheDiffIsMaskedOnBothSides() {
        let diff = KubeHelmUpgrade.diff(current: current, rendered: rendered, namespace: "shop", revision: 2)
        XCTAssertEqual(diff.items.map(\.id), ["Secret/shop/web-auth", "Deployment/shop/web", "Service/shop/web", "ConfigMap/shop/web-old"])
        XCTAssertEqual(diff.items.map(\.change), [.modified, .modified, .added, .removed])
        XCTAssertEqual(diff.withheld, 1, "the unreadable document left out")
        XCTAssertEqual(diff.secrets, 1)
        let secret = diff.items[0].diff
        XCTAssertTrue(secret.contains("-  password: \"*** (before)\""), secret)
        XCTAssertTrue(secret.contains("+  password: \"*** (after)\""), secret)
        XCTAssertTrue(secret.contains("\n   username: \"***\""), "an unchanged value the same mask on both sides: \(secret)")
        XCTAssertTrue(diff.items[1].diff.contains("+  replicas: 3"), diff.items[1].diff)
        XCTAssertEqual(diff.items[1].file, "deployment-web.yaml")
        XCTAssertTrue(diff.items[1].diff.hasPrefix("--- revision 2/deployment-web.yaml\n+++ checkout/deployment-web.yaml"), diff.items[1].diff)
        let everything = diff.items.map(\.diff).joined()
        XCTAssertFalse(everything.contains(password), "no value of a secret's, an env's or a URL's: \(everything)")
        XCTAssertFalse(everything.contains(Data(password.utf8).base64EncodedString()))
        XCTAssertFalse(everything.contains("acme-unit-new-pw"))
        XCTAssertFalse(everything.contains(Data("acme-unit-new-pw".utf8).base64EncodedString()))
        XCTAssertEqual(diff.said, "4 of 4 objects would change (+\(diff.added) −\(diff.removed)).")
        let same = KubeHelmUpgrade.diff(current: current, rendered: current, namespace: "shop", revision: 2)
        XCTAssertEqual(same.changes, 0)
        XCTAssertEqual(same.said, "Nothing in its objects would change: the chart renders what the release has.")
        XCTAssertTrue(same.items.allSatisfy { $0.diff.isEmpty })
    }

    func testTheReleasesRecordGivesItsValuesAndManifest() throws {
        let release: [String: Any] = [
            "name": "web", "namespace": "shop", "version": 2, "config": ["auth": ["password": password], "replicaCount": 3], "manifest": current,
            "chart": ["metadata": ["name": "web", "version": "1.4.2"]],
        ]
        let body = try JSONSerialization.data(withJSONObject: [
            "kind": "Secret", "apiVersion": "v1", "metadata": ["name": "sh.helm.release.v1.web.v2"],
            "data": ["release": Data(KubeHelm.encode(release).utf8).base64EncodedString()],
        ])
        let inputs = try KubeHelm.upgradeInputs(body, storage: .secret)
        XCTAssertEqual(inputs.revision, 2)
        XCTAssertEqual(inputs.chart.said, "web-1.4.2")
        XCTAssertEqual(inputs.manifest, current)
        let values = try JSONSerialization.jsonObject(with: inputs.values) as? [String: Any]
        XCTAssertEqual(values?["replicaCount"] as? Int, 3)
        XCTAssertFalse("\(inputs)".contains(password), "printed, it says which revision it is: \(inputs)")
    }

    // MARK: The upgrade

    private let upgrade = KubeHelmUpgradeWrite(
        release: "web", namespace: "shop", storage: .secret, chart: "/repo/deploy/web", chartSaid: "web-1.5.0", from: 2,
        summary: "2 of 3 objects would change (+4 −1).")

    func testTheUpgradesLine() throws {
        XCTAssertEqual(
            upgrade.line(context: "kind-fake"), "\(KubeHelmWritesTests.env) HELM_DRIVER=secret helm upgrade web /repo/deploy/web --reset-then-reuse-values --kube-context kind-fake -n shop")
        var spaced = upgrade
        spaced.chart = "/My Repo/chart;id"
        spaced.storage = .configMap
        XCTAssertEqual(
            spaced.line(context: "kind fake"),
            "\(KubeHelmWritesTests.env) HELM_DRIVER=configmap helm upgrade web '/My Repo/chart;id' --reset-then-reuse-values --kube-context 'kind fake' -n shop")
        var flag = upgrade
        flag.release = "--kubeconfig=/x"
        XCTAssertThrowsError(try KubeCommands.command(flag, in: context("kind-fake")))
        var relative = upgrade
        relative.chart = "-x"
        XCTAssertNotNil(relative.refused, "a chart helm could read as a flag")
        var tiller = upgrade
        tiller.storage = .tiller
        XCTAssertEqual(tiller.refused, KubeHelmWrite.refusal(.tiller))
        XCTAssertEqual(try KubeCommands.command(upgrade, in: context("kind-fake")), upgrade.line(context: "kind-fake"))
    }

    func testItIsRefusedOnEveryReadOnlyContext() {
        XCTAssertTrue(KubeProcessVerb.helmUpgrade.writes)
        for name in ["fake-dev", "fake-prod"] {
            XCTAssertThrowsError(try KubeCommands.command(upgrade, in: context(name)), name)
        }
        XCTAssertNoThrow(try KubeCommands.command(upgrade, in: context("fake-prod", session: true)), "production with its writes on")
        XCTAssertNoThrow(try KubeCommands.command(upgrade, in: context("fake-dev", settings: KubeContextSettings(writable: true))))
    }

    func testTheConfirmationNamesTheContextNamespaceAndChart() {
        let local = context("kind-fake")
        let asked = upgrade.confirmation(context: local, rule: KubeProcessCheck.rule(.helmUpgrade, for: local))
        XCTAssertEqual(asked.title, "Upgrade Helm release shop/web from the checkout's chart?")
        XCTAssertEqual(asked.scope, "kind-fake · namespace shop")
        XCTAssertNil(asked.typedName, "off production, no name typed")
        XCTAssertTrue(asked.detail.contains("revision 3 from the checkout's chart (web-1.5.0) with revision 2's values"), asked.detail)
        XCTAssertTrue(asked.detail.contains("2 of 3 objects would change"), asked.detail)
        XCTAssertTrue(asked.detail.contains(upgrade.line(context: "kind-fake")))
        XCTAssertEqual(asked.button, "Upgrade in a Tab")
        let prod = context("fake-prod", session: true)
        let onProd = upgrade.confirmation(context: prod, rule: KubeProcessCheck.rule(.helmUpgrade, for: prod))
        XCTAssertEqual(onProd.scope, "PRODUCTION · fake-prod · namespace shop")
        XCTAssertEqual(onProd.typedName, "web")
        XCTAssertTrue(onProd.production)
        XCTAssertFalse(onProd.accepts("wbe"))
        XCTAssertTrue(onProd.accepts(" web "))
        XCTAssertEqual(upgrade.opened(context: "kind-fake"), "Upgrading Helm release shop/web from the checkout's chart in a new tab, in kind-fake.")
    }

    func testItsAccessReviewIsTheRecordsAndTheRendersKinds() {
        let hpa = KubeResourceKind(
            group: "autoscaling", version: "v2", resource: "horizontalpodautoscalers", kind: "HorizontalPodAutoscaler", singular: "horizontalpodautoscaler",
            namespaced: true, verbs: ["create", "delete", "patch"])
        let binding = KubeResourceKind(
            group: "rbac.authorization.k8s.io", version: "v1", resource: "clusterrolebindings", kind: "ClusterRoleBinding", singular: "clusterrolebinding",
            namespaced: false, verbs: ["create", "delete", "patch"])
        let discovery = KubeDiscovery(kinds: [KubeHelm.secrets, KubeWritesTests.deployments, hpa, binding])
        let current = """
            ---
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: web
            spec:
              replicas: 1
            ---
            apiVersion: rbac.authorization.k8s.io/v1
            kind: ClusterRoleBinding
            metadata:
              name: web-reader
            ---
            apiVersion: v1
            kind: Secret
            metadata:
              name: web-auth
            data:
              password: YQ==
            """
        let next = """
            ---
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: web
            spec:
              replicas: 3
            ---
            apiVersion: autoscaling/v2
            kind: HorizontalPodAutoscaler
            metadata:
              name: web
            ---
            apiVersion: v1
            kind: Secret
            metadata:
              name: web-auth
            data:
              password: YQ==
            """
        let diff = KubeHelmUpgrade.diff(current: current, rendered: next, namespace: "shop", revision: 2)
        let review = KubeHelmUpgrade.accesses(storage: .secret, namespace: "shop", diff: diff, discovery: discovery)
        XCTAssertEqual(
            review.accesses.map { "\($0.access) @\($0.namespace ?? "*")" },
            [
                "create secrets @shop", "update secrets @shop", "patch deployments.apps @shop", "create horizontalpodautoscalers.autoscaling @shop",
                "delete clusterrolebindings.rbac.authorization.k8s.io @*",
            ], "made for an added kind, deleted for a removed one, patched for a changed one; an unchanged Secret not asked")
        XCTAssertNil(review.partial)
        // The page never opened the context and its kinds couldn't be read: the confirmation says only the records were.
        let unknown = KubeHelmUpgrade.accesses(storage: .configMap, namespace: "shop", diff: diff, discovery: nil)
        XCTAssertEqual(unknown.accesses.map { "\($0.access)" }, ["create configmaps", "update configmaps"])
        XCTAssertEqual(unknown.partial?.hasPrefix("Only its records' access was reviewed"), true)
        var write = upgrade
        write.reviewNote = unknown.partial
        let local = context("kind-fake")
        XCTAssertTrue(write.confirmation(context: local, rule: KubeProcessCheck.rule(.helmUpgrade, for: local)).detail.contains(unknown.partial!))
    }
}

/// The upgrade's session against the fake's release (`KubeHelmUpgradeSession`):
/// the diff read, rendered by a stand-in, masked and shown; the upgrade
/// refused on a read-only context with nothing sent, reviewed and
/// confirmed on a writable one, the name typed on production.
@MainActor
final class KubeHelmUpgradeSessionTests: XCTestCase {
    private var api: FakeKubeAPI!
    private var socket: String!
    private let password = "acme-unit-helm-pw-Lp3c"

    override func setUp() async throws {
        socket = "/tmp/otkhu-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        api.addHelmRelease(
            "web", namespace: "shop", revision: 2, config: ["auth": ["password": password], "replicaCount": 1],
            manifest: "---\napiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: web\nspec:\n  replicas: 1\n")
    }

    override func tearDown() async throws {
        if let api {
            XCTAssertTrue(api.writes.allSatisfy(\.isAccessReview), "only reviews: \(api.writes)")
            api.stop()
        }
    }

    private final class Host: KubeHelmUpgradeHost {
        var typed: String? = ""
        var asked: [KubeWriteConfirmation] = []
        var shown = 0
        var ran: [(String, String, String)] = []
        var consent = true
        var consents = 0
        var capabilities: [KubeHelmCapabilities] = []
        func askHelmUpgrade(_ confirmation: KubeWriteConfirmation) async -> String? {
            asked.append(confirmation)
            return typed
        }
        func askHelmUpgrade(_ title: String, _ detail: String, _ button: String) async -> Bool {
            consents += 1
            return consent
        }
        func showHelmDiff(_ session: KubeHelmUpgradeSession) { shown += 1 }
        func runHelmUpgrade(_ command: String, in context: KubeContext, namespace: String) { ran.append((command, context.name, namespace)) }
    }

    private func session(_ context: String, session sessionWrites: Bool = false) -> (KubeHelmUpgradeSession, Host) {
        let model = KubernetesModel(proxies: KubeProxies())
        let kind = KubeWritesTests.context(context, session: sessionWrites)
        let list = KubeContextList(contexts: [kind], current: context)
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        let socket = self.socket!
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name, writable: context.isWritable) }
        let checkout = URL(fileURLWithPath: "/tmp/ot-unit-checkout")
        let host = Host()
        let session = KubeHelmUpgradeSession(
            binding: KubeBinding(checkout: checkout.path, context: context, namespace: "shop", release: "web"), checkout: checkout, model: model)
        session.client = { context in KubeClient(KubeSocketConnection(socket: socket, context: context.name, writable: context.isWritable)) }
        session.findChart = { root, _ in root.appendingPathComponent("chart") }
        session.render = { [weak host] _, _, _, values, _, capabilities in
            host?.capabilities.append(capabilities)
            XCTAssertNotNil((try? JSONSerialization.jsonObject(with: values)) as? [String: Any], "the release's values, as JSON")
            return "---\napiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: web\nspec:\n  replicas: 3\n"
        }
        session.host = host
        return (session, host)
    }

    func testTheDiffReadsTheReleaseAndShowsWhatWouldChange() async throws {
        let (session, host) = session("fake-dev")
        let result = await session.runDiff()
        XCTAssertEqual(result?.revision, 2)
        XCTAssertEqual(result?.diff.items.map(\.change), [.modified])
        XCTAssertTrue(result?.diff.items.first?.diff.contains("+  replicas: 3") == true)
        XCTAssertEqual(host.shown, 1)
        XCTAssertEqual(session.state, .done("1 of 1 object would change (+1 −1)."))
        XCTAssertNotNil(session.fileDiffs["Deployment/shop/web"])
        XCTAssertFalse("\(String(describing: result))".contains(password))
        XCTAssertEqual(host.consents, 0, "off production nothing is asked first")
        // helm template told the cluster's version and what it serves (GETs: /version, discovery).
        XCTAssertEqual(host.capabilities.last?.kubeVersion?.hasPrefix("v1."), true, "\(host.capabilities)")
        XCTAssertEqual(host.capabilities.last?.apiVersions.contains("apps/v1/Deployment"), true, "\(host.capabilities)")
        XCTAssertEqual(result?.discovery == nil, false)
        XCTAssertTrue(api.writes.isEmpty, "a diff writes nothing, a read-only context included")
    }

    func testOnAReadOnlyContextTheUpgradeIsRefusedAndNothingSent() async throws {
        let (session, host) = session("fake-dev")
        await session.runUpgrade()
        XCTAssertEqual(session.state, .failed(KubeProcessCheck.readOnly(.remote)))
        XCTAssertTrue(host.asked.isEmpty && host.ran.isEmpty)
        XCTAssertTrue(api.requests.isEmpty, "not even a review: \(api.requests)")
    }

    func testOnAWritableContextItIsReviewedConfirmedThenTypedIntoATab() async throws {
        let (session, host) = session("kind-fake")
        await session.runUpgrade()
        XCTAssertEqual(host.asked.count, 1)
        XCTAssertEqual(host.asked.first?.scope, "kind-fake · namespace shop")
        XCTAssertEqual(host.ran.first?.0, "\(KubeHelmWritesTests.env) HELM_DRIVER=secret helm upgrade web /tmp/ot-unit-checkout/chart --reset-then-reuse-values --kube-context kind-fake -n shop")
        XCTAssertEqual(host.ran.first?.2, "shop")
        XCTAssertEqual(session.state, .done("Upgrading Helm release shop/web from the checkout's chart in a new tab, in kind-fake."))
        let reviewed = api.requests.filter(\.isAccessReview).compactMap {
            (($0.json as? [String: Any])?["spec"] as? [String: Any])?["resourceAttributes"] as? [String: String]
        }
        XCTAssertTrue(reviewed.contains(["verb": "create", "resource": "secrets", "group": "", "namespace": "shop"]), "\(reviewed)")
        // A refused review stops it.
        api.deniedAccess = ["update secrets"]
        host.ran = []
        await session.runUpgrade()
        XCTAssertTrue(host.ran.isEmpty)
        XCTAssertTrue(session.state.isFailure, "\(session.state)")
        // Cancelled: nothing runs.
        api.deniedAccess = []
        host.typed = nil
        await session.runUpgrade()
        XCTAssertTrue(host.ran.isEmpty)
        XCTAssertEqual(session.state, .done("Cancelled: nothing was run."))
    }

    func testOnProductionTheValuesAreAskedForAndTheNameTyped() async throws {
        let (session, host) = session("fake-prod")
        // Its writes on for the session, as its card turns them on.
        session.model.reloadContexts()
        let end = Date().addingTimeInterval(5)
        while session.model.contexts.context(named: "fake-prod") == nil, Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        await session.model.setProductionWrites(true, for: "fake-prod")
        host.consent = false
        _ = await session.runDiff()
        XCTAssertEqual(host.consents, 1)
        XCTAssertTrue(session.state.isFailure)
        XCTAssertFalse(api.requests.contains { $0.path.contains("/secrets/") }, "no record read without the yes")
        host.consent = true
        host.typed = "wbe"
        await session.runUpgrade()
        XCTAssertEqual(host.consents, 2)
        XCTAssertEqual(host.asked.last?.typedName, "web")
        XCTAssertTrue(host.ran.isEmpty, "a wrong name runs nothing")
        XCTAssertEqual(session.state, .failed("The name typed wasn't web: nothing was run."))
        host.typed = "web"
        await session.runUpgrade()
        XCTAssertEqual(host.consents, 2, "asked once a session")
        XCTAssertEqual(host.ran.first?.0, "\(KubeHelmWritesTests.env) HELM_DRIVER=secret helm upgrade web /tmp/ot-unit-checkout/chart --reset-then-reuse-values --kube-context fake-prod -n shop")
    }
}
