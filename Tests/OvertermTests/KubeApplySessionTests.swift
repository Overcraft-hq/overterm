import Foundation
import XCTest

@testable import Overterm

/// A manifest diffed with and applied to `FakeKubeAPI` on a socket of the
/// test's own (stage 2b), over three fictional contexts on it — never
/// ~/.kube: `kind-fake` (local, writable), `fake-dev` (remote, read-only)
/// and `fake-prod` (production: writable, no switch; a person's apply
/// with the name typed, an agent's only with `applyOnProduction`). The dry run is a PATCH with
/// `dryRun=All` and changes nothing; read-only — or refused — the diff is
/// client-side, labelled, and nothing is sent; an apply lands only after
/// its access review and confirmation; a 409 names its managers and Force
/// is asked again; a changed object offers Replace; masks are never sent;
/// agents' `k8s_apply` goes the same way.
@MainActor
final class KubeApplySessionTests: XCTestCase {
    nonisolated(unsafe) private var api: FakeKubeAPI!
    nonisolated(unsafe) private var socket: String!
    private var agentWrites: [String] = []
    /// What fake-prod's kubernetes.contexts entry says, read as the kubeconfig is.
    final class Flags: @unchecked Sendable {
        var applyOnProduction = false
        /// Its `writable: false`: production set read-only by its entry.
        var prodReadOnly = false
        /// Its `writable: true`: agents' own step on production.
        var prodSetWritable = false
    }
    private let flags = Flags()
    private var applyOnProduction: Bool {
        get { flags.applyOnProduction }
        set { flags.applyOnProduction = newValue }
    }

    /// The window, as the session asks it.
    final class Host: KubeManifestHost {
        var typed: String? = ""
        var asked: [KubeWriteConfirmation] = []
        var consents = 0
        var consent = true
        var shown = 0

        func askManifestWrite(_ confirmation: KubeWriteConfirmation) async -> String? {
            asked.append(confirmation)
            return typed
        }

        func askManifest(_ title: String, _ detail: String, _ button: String) async -> Bool {
            consents += 1
            return consent
        }

        func showManifestDiff(_ session: KubeManifestSession) { shown += 1 }
    }

    override func setUpWithError() throws {
        socket = "/tmp/otkap-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        api.add(
            "deployments.apps", "web", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1],
            fields: ["spec": ["replicas": 1, "template": ["metadata": ["labels": ["app": "web"]]]], "status": ["replicas": 1]])
        api.add("secrets", "web-db", namespace: "shop", values: ["Type": "Opaque"], data: ["password": "old-pw-Q1x", "username": "web"])
        MainActor.assumeIsolated { KubeMCP.forgetDiscoveries() }
    }

    override func tearDown() {
        MainActor.assumeIsolated { KubeMCP.askOverride = nil }
        api?.stop()
    }

    private func model() -> KubernetesModel {
        let model = KubernetesModel(proxies: KubeProxies())
        let flags = self.flags
        model.load = { _ in
            var prod = flags.applyOnProduction ? KubeContextSettings(applyOnProduction: true) : KubeContextSettings()
            if flags.prodReadOnly { prod.writable = false } else if flags.prodSetWritable { prod.writable = true }
            return KubeContextList(
                contexts: [KubeWritesTests.context("fake-dev"), KubeWritesTests.context("fake-prod", settings: prod), KubeWritesTests.context("kind-fake")],
                current: "kind-fake")
        }
        model.readConfiguration = { [unowned self] in
            var configuration = KubernetesModel.Configuration()
            configuration.agentWrites = MainActor.assumeIsolated { self.agentWrites }
            return configuration
        }
        model.watchesSettings = false
        model.remembersSelection = false
        let socket = self.socket!
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name, writable: context.isWritable) }
        model.statusOverride = { _ in .open }
        return model
    }

    private func session(_ model: KubernetesModel, _ text: String, context: String, source: KubeManifestSession.Source? = nil) -> (KubeManifestSession, Host) {
        let file = URL(fileURLWithPath: "/tmp/checkout-\(UUID().uuidString)/web.yaml")
        let session = KubeManifestSession(source: source ?? .file(file), file: file, model: model)
        session.contextName = context
        session.text = { text }
        let host = Host()
        session.host = host
        return (session, host)
    }

    private var deployment: String { "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: web\n  namespace: shop\nspec:\n  replicas: 3\n" }

    private func applies(dryRun: Bool) -> [FakeKubeAPI.Request] {
        api.writes.filter { $0.method == "PATCH" && $0.contentType == "application/apply-patch+yaml" && ($0.query["dryRun"] == "All") == dryRun }
    }

    private func replicas() -> Int? {
        ((api.object("deployments.apps", "web", namespace: "shop")?["spec"] as? [String: Any])?["replicas"] as? NSNumber)?.intValue
    }

    /// fake-prod as read: writable, with no switch (the owner's decision).
    private func switchOn(_ model: KubernetesModel) async {
        model.reloadContexts()
        for _ in 0..<250 where model.contexts.context(named: "fake-prod") == nil { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.contexts.context(named: "fake-prod")?.isWritable, true)
    }

    // MARK: Diff with Cluster

    func testTheDiffIsADryRunThatChangesNothing() async throws {
        let model = model()
        let (session, host) = session(model, deployment, context: "kind-fake")
        let resultDiffed = await session.runDiff()
        let result = try XCTUnwrap(resultDiffed)
        XCTAssertTrue(result.isServerSide)
        XCTAssertEqual(result.label, "Server-side dry run (dryRun=All): what kind-fake would make of it — its defaults and admission applied.")
        let dry = applies(dryRun: true)
        XCTAssertEqual(dry.count, 1)
        XCTAssertEqual(dry.first?.path, "/apis/apps/v1/namespaces/shop/deployments/web")
        XCTAssertEqual(dry.first?.query["fieldManager"], "overterm")
        XCTAssertEqual(dry.first?.query["force"], "true", "forced as kubectl diff --force-conflicts: a dry run takes nothing")
        XCTAssertTrue(applies(dryRun: false).isEmpty)
        XCTAssertEqual(replicas(), 1, "nothing changed")
        let item = try XCTUnwrap(result.items.first)
        XCTAssertTrue(item.diff.contains("-  replicas: 1\n+  replicas: 3"), item.diff)
        XCTAssertFalse(item.before.contains("managedFields") || item.after.contains("managedFields"), "stripped")
        XCTAssertFalse(item.before.contains("status:"), "stripped")
        XCTAssertEqual(host.shown, 1, "in the changes pane")
        XCTAssertEqual(session.state, .done("1 of 1 would change: +1 −1"))
        XCTAssertNotNil(session.fileDiffs[item.id])
    }

    func testReadOnlyIsClientSideAndSendsNothing() async throws {
        let model = model()
        let (session, _) = session(model, deployment, context: "fake-dev")
        let resultDiffed = await session.runDiff()
        let result = try XCTUnwrap(resultDiffed)
        XCTAssertEqual(result.method, .clientSide("fake-dev is read-only: its socket takes no dry run, so nothing was sent."))
        XCTAssertTrue(result.label.hasPrefix("client-side: defaults and admission not applied"))
        XCTAssertTrue(result.items.first?.diff.contains("+  replicas: 3") == true)
        XCTAssertTrue(api.writes.isEmpty, "not even a dry run: \(api.writes)")
        XCTAssertTrue(session.state.text?.contains("(client-side: defaults and admission not applied)") == true)
        await session.refreshContexts()
        XCTAssertEqual(
            session.applyRefusal,
            "This context is read-only: Overterm changes nothing here (its writable setting). Diff with Cluster still shows what would change.")
    }

    func testARefusedDryRunFallsBackClientSide() async throws {
        let model = model()
        api.failNextWrite(403, reason: "Forbidden", message: "deployments.apps \"web\" is forbidden: User cannot patch")
        let (session, _) = session(model, deployment, context: "kind-fake")
        let resultDiffed = await session.runDiff()
        let result = try XCTUnwrap(resultDiffed)
        guard case .clientSide(let why) = result.method else { return XCTFail("client-side") }
        XCTAssertTrue(why.hasPrefix("the cluster refused the dry run"), why)
        XCTAssertTrue(result.label.contains(KubeManifestDiffResult.clientSideLabel))
    }

    func testASecretsDiffNeverShowsAValue() async throws {
        let model = model()
        let text = "apiVersion: v1\nkind: Secret\nmetadata:\n  name: web-db\n  namespace: shop\nstringData:\n  password: new-pw-Z9y\n  username: web\n"
        let (session, _) = session(model, text, context: "kind-fake")
        let resultDiffed = await session.runDiff()
        let result = try XCTUnwrap(resultDiffed)
        let item = try XCTUnwrap(result.items.first)
        let shown = [item.before, item.after, item.diff, result.summary(), session.state.text ?? ""].joined(separator: "\n")
        for value in ["old-pw-Q1x", "new-pw-Z9y", Data("old-pw-Q1x".utf8).base64EncodedString(), Data("new-pw-Z9y".utf8).base64EncodedString()] {
            XCTAssertFalse(shown.contains(value), "no value: \(value)")
        }
        XCTAssertTrue(item.diff.contains("*** (before)") && item.diff.contains("*** (after)"), item.diff)
        XCTAssertFalse(item.diff.contains("username: \"*** (before)\""), "unchanged: *** alone")
        XCTAssertEqual(api.object("secrets", "web-db", namespace: "shop").flatMap { ($0["data"] as? [String: String])?["password"] }, Data("old-pw-Q1x".utf8).base64EncodedString())
    }

    func testAProductionSecretIsAskedOnceBeforeItsValuesAreRead() async throws {
        let model = model()
        await switchOn(model)
        let text = "apiVersion: v1\nkind: Secret\nmetadata:\n  name: web-db\n  namespace: shop\nstringData:\n  password: x\n"
        let (session, host) = session(model, text, context: "fake-prod")
        host.consent = false
        api.forgetRequests()
        let declined = await session.runDiff()
        XCTAssertNil(declined)
        XCTAssertEqual(host.consents, 1)
        XCTAssertFalse(api.requests.contains { $0.path.hasSuffix("/secrets/web-db") }, "declined: not read")
        host.consent = true
        let first = await session.runDiff()
        let second = await session.runDiff()
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(host.consents, 2, "once a context and session")
    }

    func testAKustomizationIsRendered() async throws {
        let model = model()
        let folder = URL(fileURLWithPath: "/tmp/checkout/deploy")
        let file = folder.appendingPathComponent("kustomization.yaml")
        let session = KubeManifestSession(source: .kustomization(folder), file: file, model: model)
        session.contextName = "kind-fake"
        var rendered: [URL] = []
        let manifest = deployment
        session.render = { folder, _ in
            rendered.append(folder)
            return manifest
        }
        session.text = { "resources: [web.yaml]\n" }
        session.host = Host()
        let resultDiffed = await session.runDiff()
        let result = try XCTUnwrap(resultDiffed)
        XCTAssertEqual(rendered, [folder])
        XCTAssertEqual(result.items.map(\.spoken), ["deployment shop/web"])
        XCTAssertEqual(session.title, "kustomization deploy")
    }

    // MARK: Apply

    func testApplyIsReviewedConfirmedThenSent() async throws {
        let model = model()
        let (session, host) = session(model, deployment, context: "kind-fake")
        await session.runApply()
        XCTAssertEqual(replicas(), 3, "\(String(describing: session.state))")
        let requests = api.requests.filter { $0.method != "GET" }
        let review = try XCTUnwrap(requests.firstIndex(where: \.isAccessReview))
        let dry = try XCTUnwrap(requests.firstIndex { $0.query["dryRun"] == "All" })
        let real = try XCTUnwrap(requests.firstIndex { $0.contentType == "application/apply-patch+yaml" && $0.query["dryRun"] == nil })
        XCTAssertLessThan(review, dry, "the review before anything else")
        XCTAssertLessThan(dry, real, "the dry run shown before the apply")
        XCTAssertNil(requests[real].query["force"], "never forced unless asked")
        let asked = try XCTUnwrap(host.asked.first)
        XCTAssertEqual(asked.title, "Apply deployment shop/web to kind-fake?")
        XCTAssertEqual(asked.scope, "kind-fake · namespace shop")
        XCTAssertTrue(asked.detail.contains("+  replicas: 3"), asked.detail)
        XCTAssertTrue(asked.detail.contains("Equals: kubectl apply --server-side --field-manager=overterm -f "), asked.detail)
        XCTAssertNil(asked.typedName)
        XCTAssertEqual(session.state, .done("Applied deployment shop/web to kind-fake."))
        XCTAssertTrue(session.result?.items.first?.unchanged == true, "diffed again after: unchanged")
        let reviewed = (requests[review].json as? [String: Any]).flatMap { ($0["spec"] as? [String: Any])?["resourceAttributes"] as? [String: String] }
        XCTAssertEqual(reviewed, ["verb": "patch", "resource": "deployments", "group": "apps", "namespace": "shop"])
    }

    func testDeclinedOrRefusedSendsNothing() async throws {
        let model = model()
        let (session, host) = session(model, deployment, context: "kind-fake")
        host.typed = nil
        await session.runApply()
        XCTAssertEqual(session.state, .done("Cancelled: nothing was applied."))
        XCTAssertTrue(applies(dryRun: false).isEmpty)
        api.deniedAccess = ["patch deployments.apps"]
        host.asked = []
        await session.runApply()
        XCTAssertTrue(session.state.isFailure)
        XCTAssertTrue(host.asked.isEmpty, "a no from the review: not asked")
        XCTAssertTrue(applies(dryRun: false).isEmpty)
        XCTAssertEqual(replicas(), 1)
    }

    func testAConflictNamesItsManagersAndForceIsAskedAgain() async throws {
        api.setManagedFields(
            "deployments.apps", "web", namespace: "shop",
            [["manager": "helm", "operation": "Apply", "apiVersion": "apps/v1", "fieldsType": "FieldsV1", "fieldsV1": ["f:spec": ["f:replicas": [String: Any]()]]]])
        let model = model()
        let (session, host) = session(model, deployment, context: "kind-fake")
        let diffDiffed = await session.runDiff()
        let diff = try XCTUnwrap(diffDiffed)
        XCTAssertEqual(diff.warnings, ["Helm manages this: its next upgrade sets these fields back.", "Also owned: helm owns .spec.replicas (Apply)."], "named before applying")
        await session.runApply()
        XCTAssertEqual(session.conflict, .fields([.init(manager: "helm", field: ".spec.replicas")]))
        XCTAssertEqual(
            session.state, .failed("Conflict: helm owns .spec.replicas. Nothing of it was applied — Force takes these fields from them, asked again."))
        XCTAssertTrue(host.asked.first?.detail.contains("⚠︎ Helm manages this") == true, "the owners in the confirmation")
        XCTAssertEqual(replicas(), 1)
        host.asked = []
        await session.runApply(force: true)
        XCTAssertEqual(host.asked.first?.title, "Force the apply of deployment shop/web?")
        XCTAssertTrue(host.asked.first?.detail.contains("Equals: kubectl apply --server-side --field-manager=overterm --force-conflicts") == true)
        XCTAssertEqual(replicas(), 3)
        XCTAssertEqual(applies(dryRun: false).last?.query["force"], "true")
        XCTAssertNil(session.conflict)
    }

    func testAChangedObjectOffersReplace() async throws {
        let model = model()
        let ref = KubeObjectRef(context: "kind-fake", kind: KubeWritesTests.deployments, namespace: "shop", name: "web")
        let url = KubeManifestEdits.register(ref, resourceVersion: "1")
        addTeardownBlock { await MainActor.run { KubeManifestEdits.remove(url) } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "a name only: nothing is written")
        let session = KubeManifestSession(source: .object(ref), file: url, model: model)
        let host = Host()
        session.host = host
        session.text = { [deployment] in deployment }
        await session.runApply()
        XCTAssertEqual(session.conflict.map { if case .changed = $0 { true } else { false } }, true, "\(String(describing: session.state))")
        XCTAssertEqual(replicas(), 1)
        let sent = applies(dryRun: false).last.flatMap { ($0.json as? [String: Any])?["metadata"] as? [String: Any] }
        XCTAssertEqual(sent?["resourceVersion"] as? String, "1", "the version it was opened at")
        await session.runApply(replacing: true)
        XCTAssertEqual(host.asked.last?.title, "Replace deployment shop/web with your copy?")
        XCTAssertEqual(replicas(), 3)
        XCTAssertNotEqual(KubeManifestEdits.edit(at: url)?.resourceVersion, "1", "what it is at now")
        session.close()
        XCTAssertNil(KubeManifestEdits.edit(at: url), "its buffer gone, so is its name")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "never a file")
    }

    func testAMaskedSecretIsRefused() async throws {
        let model = model()
        let text = "apiVersion: v1\nkind: Secret\nmetadata:\n  name: web-db\n  namespace: shop\ndata:\n  password: \"***\"\n"
        let (session, host) = session(model, text, context: "kind-fake")
        let diffDiffed = await session.runDiff()
        let diff = try XCTUnwrap(diffDiffed)
        XCTAssertEqual(diff.items.first?.masked, [".data.password"])
        XCTAssertTrue(diff.items.first?.unchanged == true, "what is still masked shows as unchanged")
        api.forgetRequests()
        await session.runApply()
        XCTAssertTrue(session.state.text?.contains("still holds masked values (.data.password)") == true, "\(String(describing: session.state))")
        XCTAssertTrue(host.asked.isEmpty)
        XCTAssertTrue(api.writes.isEmpty, "not even a review")
    }

    // MARK: Production

    func testAPersonsApplyOnWritableProductionNeedsNoSetting() async throws {
        let model = model()
        await switchOn(model)
        let (session, host) = session(model, deployment, context: "fake-prod")
        await session.refreshContexts()
        XCTAssertNil(session.applyRefusal, "writable production: Apply offered, nothing turned on first")
        let resultDiffed = await session.runDiff()
        let result = try XCTUnwrap(resultDiffed)
        XCTAssertTrue(result.isServerSide, "the diff is a dry run sent")
        XCTAssertTrue(result.production)
        host.typed = "web"
        await session.runApply()
        XCTAssertEqual(host.asked.first?.typedName, "web", "the name typed on production")
        XCTAssertEqual(replicas(), 3)
    }

    func testApplyOnProductionAsksTheNameAndNeverForces() async throws {
        let model = model()
        await switchOn(model)
        let (session, host) = session(model, deployment, context: "fake-prod")
        await session.refreshContexts()
        XCTAssertNil(session.applyRefusal)
        host.typed = "wbe"
        await session.runApply()
        XCTAssertEqual(host.asked.first?.typedName, "web")
        XCTAssertEqual(host.asked.first?.scope, "PRODUCTION · fake-prod · namespace shop")
        XCTAssertEqual(session.state, .failed("The name typed wasn't web: nothing was applied."))
        XCTAssertTrue(applies(dryRun: false).isEmpty)
        host.typed = "web"
        await session.runApply()
        XCTAssertEqual(replicas(), 3)
        await session.runApply(force: true)
        XCTAssertEqual(session.state, .failed("An apply is never forced on production: change the field's owner, or the manifest."))
        // Its entry set `writable: false`: read-only.
        flags.prodReadOnly = true
        model.reloadContexts()
        for _ in 0..<250 where model.contexts.context(named: "fake-prod")?.isWritable != false { try? await Task.sleep(for: .milliseconds(10)) }
        await session.refreshContexts()
        XCTAssertEqual(
            session.applyRefusal, "This context is read-only: Overterm changes nothing here (its writable setting). Diff with Cluster still shows what would change.",
            "set read-only by its entry")
    }

    // MARK: GitOps objects (gitops.md, G0d)

    private func kustomization(prune: Bool, path: String = "./apps/web", interval: String = "5m") -> String {
        """
        apiVersion: kustomize.toolkit.fluxcd.io/v1
        kind: Kustomization
        metadata:
          name: acme-web
          namespace: shop
        spec:
          interval: \(interval)
          path: \(path)
          prune: \(prune)
          sourceRef:
            kind: GitRepository
            name: fleet

        """
    }

    private func serveFlux() {
        api.addCRD(group: "kustomize.toolkit.fluxcd.io", version: "v1", plural: "kustomizations", kind: "Kustomization", shortNames: ["ks"])
        api.add(
            "kustomizations.kustomize.toolkit.fluxcd.io", "acme-web", namespace: "shop",
            fields: ["spec": ["interval": "5m", "path": "./apps/web", "prune": false, "sourceRef": ["kind": "GitRepository", "name": "fleet"]]])
    }

    private func kustomizationSpec() -> [String: Any] {
        api.object("kustomizations.kustomize.toolkit.fluxcd.io", "acme-web", namespace: "shop")?["spec"] as? [String: Any] ?? [:]
    }

    /// Turning prune on with a new path, on a local context: each change
    /// named, the name typed — a wrong one applies nothing.
    func testChangingAKustomizationsPruneOrPathTypesTheNameOnEveryClass() async throws {
        serveFlux()
        let model = model()
        let (session, host) = session(model, kustomization(prune: true, path: "./apps/other"), context: "kind-fake")
        let diffed = await session.runDiff()
        let item = try XCTUnwrap(diffed?.items.first)
        XCTAssertEqual(item.gitOps.map(\.said), [".spec.prune: false → true", ".spec.path: ./apps/web → ./apps/other"])
        XCTAssertEqual(diffed?.warnings.first, item.gitOpsWarning, "the changes pane says it before Apply")
        host.typed = "acme-wbe"
        await session.runApply()
        let asked = try XCTUnwrap(host.asked.first)
        XCTAssertEqual(asked.scope, "kind-fake · namespace shop")
        XCTAssertEqual(asked.typedName, "acme-web")
        XCTAssertTrue(asked.detail.contains(".spec.prune: false → true; .spec.path: ./apps/web → ./apps/other."), asked.detail)
        XCTAssertTrue(asked.detail.contains("With prune on, Flux deletes whatever it applied that the new spec doesn't make."), asked.detail)
        XCTAssertEqual(session.state, .failed("The name typed wasn't acme-web: nothing was applied."))
        XCTAssertTrue(applies(dryRun: false).isEmpty)
        XCTAssertEqual(kustomizationSpec()["prune"] as? Bool, false)
        host.typed = "acme-web"
        await session.runApply()
        XCTAssertEqual(session.state, .done("Applied kustomization shop/acme-web to kind-fake."))
        XCTAssertEqual(kustomizationSpec()["prune"] as? Bool, true)
        // Its interval alone: an ordinary confirmation.
        let (quiet, quietHost) = self.session(model, kustomization(prune: true, path: "./apps/other", interval: "1m"), context: "kind-fake")
        await quiet.runApply()
        XCTAssertNil(quietHost.asked.first?.typedName, quietHost.asked.first?.detail ?? "not asked")
        XCTAssertEqual(quiet.state, .done("Applied kustomization shop/acme-web to kind-fake."))
    }

    /// `k8s_apply` on a GitOps kind: the person types its name whatever it changes.
    func testAgentsApplyOfAGitOpsObjectHasThePersonTypeItsName() async throws {
        serveFlux()
        agentWrites = ["kind-fake"]
        let model = model()
        var asked: [KubeWriteConfirmation] = []
        var typed = "acme-wbe"
        KubeMCP.askOverride = { confirmation in
            MainActor.assumeIsolated { asked.append(confirmation) }
            return MainActor.assumeIsolated { typed }
        }
        let wrong = await call(model, ["manifest": kustomization(prune: false, interval: "1m"), "context": "kind-fake"])
        XCTAssertTrue(wrong.error && wrong.text.contains("The name typed wasn't acme-web: nothing was changed."), wrong.text)
        XCTAssertEqual(asked.first?.typedName, "acme-web")
        XCTAssertTrue(asked.first?.detail.contains("An agent asks to apply an Argo CD or Flux object: you type its name, whatever it changes.") == true, asked.first?.detail ?? "")
        XCTAssertTrue(applies(dryRun: false).isEmpty)
        XCTAssertEqual(kustomizationSpec()["interval"] as? String, "5m")
        typed = "acme-web"
        let done = await call(model, ["manifest": kustomization(prune: true), "context": "kind-fake"])
        XCTAssertFalse(done.error, done.text)
        XCTAssertTrue(asked.last?.detail.contains(".spec.prune: false → true") == true, asked.last?.detail ?? "")
        XCTAssertEqual(kustomizationSpec()["prune"] as? Bool, true)
    }

    // MARK: Agents

    private func call(_ model: KubernetesModel, _ arguments: [String: Any]) async -> (text: String, error: Bool) {
        do {
            let result = try await KubeMCP.call("k8s_apply", arguments, kubernetes: model)
            return (((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "", result["isError"] as? Bool == true)
        } catch let error as BrowserMCP.ToolError {
            return (error.message, true)
        } catch {
            return ("\(error)", true)
        }
    }

    func testAgentsApplyTheSameWay() async throws {
        let model = model()
        var asked: [KubeWriteConfirmation] = []
        KubeMCP.askOverride = { confirmation in
            MainActor.assumeIsolated { asked.append(confirmation) }
            return ""
        }
        let refused = await call(model, ["manifest": deployment, "context": "kind-fake"])
        XCTAssertTrue(refused.error && refused.text.contains("kubernetes.agentWrites doesn't name kind-fake"), refused.text)
        XCTAssertTrue(api.writes.isEmpty)
        agentWrites = ["kind-fake"]
        let done = await call(model, ["manifest": deployment, "context": "kind-fake"])
        XCTAssertFalse(done.error, done.text)
        XCTAssertTrue(done.text.contains("Applied deployment shop/web to kind-fake."), done.text)
        XCTAssertEqual(replicas(), 3)
        XCTAssertEqual(asked.first.map(KubeAgentWrites.title), "An agent asks, in kind-fake · namespace shop: Apply deployment shop/web to kind-fake?")
        XCTAssertTrue(asked.first?.detail.contains("-  replicas: 1") == true, "the dry-run diff in the confirmation")
        let again = await call(model, ["manifest": deployment, "context": "kind-fake"])
        XCTAssertTrue(again.text.contains("No change"), again.text)
        // A conflict: reported, never forced.
        api.setManagedFields(
            "deployments.apps", "web", namespace: "shop",
            [["manager": "argocd-controller", "operation": "Apply", "apiVersion": "apps/v1", "fieldsType": "FieldsV1", "fieldsV1": ["f:spec": ["f:replicas": [String: Any]()]]]])
        let conflict = await call(model, ["manifest": deployment.replacingOccurrences(of: "replicas: 3", with: "replicas: 5"), "context": "kind-fake"])
        XCTAssertTrue(conflict.error && conflict.text.contains("argocd-controller owns .spec.replicas") && conflict.text.contains("never forces"), conflict.text)
        XCTAssertTrue(asked.last?.detail.contains("Argo CD manages this; your change will be reverted.") == true)
        XCTAssertFalse(applies(dryRun: false).contains { $0.query["force"] == "true" })
        // A masked value: refused before anything.
        let before = api.writes.count
        let masked = await call(model, ["manifest": "apiVersion: v1\nkind: Secret\nmetadata: {name: web-db, namespace: shop}\ndata:\n  password: \"***\"\n", "context": "kind-fake"])
        XCTAssertTrue(masked.error && masked.text.contains("takes no Secret"), masked.text)
        XCTAssertEqual(api.writes.count, before)
    }

    /// An object without a namespace goes to one the agent named, never a
    /// guess: `a,b` named, or several shown and none named, is refused
    /// before anything is read or asked.
    func testAgentsApplyToOneNamespaceTheyName() async throws {
        let model = model()
        agentWrites = ["kind-fake"]
        var asked = 0
        KubeMCP.askOverride = { _ in
            MainActor.assumeIsolated { asked += 1 }
            return ""
        }
        let unnamed = "apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: web}\nspec: {replicas: 2}\n"
        api.forgetRequests()
        let several = await call(model, ["manifest": unnamed, "context": "kind-fake", "namespace": "shop,payments"])
        XCTAssertTrue(several.error && several.text.contains("k8s_apply needs “namespace”"), several.text)

        model.reloadContexts()
        for _ in 0..<250 where model.contexts.context(named: "kind-fake") == nil { try? await Task.sleep(for: .milliseconds(10)) }
        model.select("kind-fake")
        model.setScope(.of(["shop", "payments"]))
        let shown = await call(model, ["manifest": unnamed, "context": "kind-fake"])
        XCTAssertTrue(shown.error && shown.text.contains("k8s_apply needs “namespace”") && shown.text.contains("namespaces payments, shop"), shown.text)
        XCTAssertEqual(asked, 0)
        XCTAssertFalse(api.requests.contains { $0.method != "GET" || $0.path.contains("/deployments") }, "nothing reviewed or read: \(api.requests.map(\.path))")
        XCTAssertTrue(api.writes.isEmpty)

        // Named, one: applied there.
        let named = await call(model, ["manifest": unnamed, "context": "kind-fake", "namespace": "shop"])
        XCTAssertFalse(named.error, named.text)
        XCTAssertEqual(replicas(), 2)
    }

    /// Rule 10: no tool for Secrets. A Secret's diff would read its values
    /// and say whether an agent's guess equals them — refused before
    /// anything is read, asked or sent.
    func testAgentsApplyNoSecret() async throws {
        let model = model()
        agentWrites = ["kind-fake"]
        var asked = 0
        KubeMCP.askOverride = { _ in
            MainActor.assumeIsolated { asked += 1 }
            return ""
        }
        api.forgetRequests()
        for manifest in [
            "apiVersion: v1\nkind: Secret\nmetadata: {name: web-db, namespace: shop}\nstringData:\n  password: old-pw-Q1x\n",
            "apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: web, namespace: shop}\nspec: {replicas: 1}\n---\napiVersion: v1\nkind: Secret\nmetadata: {name: web-db, namespace: shop}\nstringData:\n  password: guess\n",
        ] {
            let refused = await call(model, ["manifest": manifest, "context": "kind-fake"])
            XCTAssertTrue(refused.error && refused.text.contains("takes no Secret"), refused.text)
            XCTAssertFalse(refused.text.contains("No change"), "never says whether a guess is right")
        }
        XCTAssertEqual(asked, 0)
        XCTAssertFalse(api.requests.contains { $0.path.contains("/secrets") }, "nothing of it read: \(api.requests.map(\.path))")
        XCTAssertTrue(api.writes.isEmpty)
    }

    /// A Deployment's secret-looking env value in the clear: refused before
    /// the dry run — its "No change" would confirm a guess of the value
    /// k8s_get and k8s_describe mask. Left masked, it goes on.
    func testAgentsApplyNoSecretLookingEnvValue() async throws {
        let model = model()
        agentWrites = ["kind-fake"]
        var asked = 0
        KubeMCP.askOverride = { _ in
            MainActor.assumeIsolated { asked += 1 }
            return ""
        }
        api.forgetRequests()
        let manifest = { (value: String) in
            "apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: web, namespace: shop}\nspec:\n  template:\n    spec:\n      containers:\n"
                + "      - name: app\n        env:\n        - name: DB_PASSWORD\n          value: \"\(value)\"\n"
        }
        let refused = await call(model, ["manifest": manifest("guess-123"), "context": "kind-fake"])
        XCTAssertTrue(refused.error && refused.text.contains("takes no secret-looking env value (DB_PASSWORD"), refused.text)
        XCTAssertFalse(refused.text.contains("No change"))
        XCTAssertEqual(asked, 0)
        XCTAssertTrue(api.writes.isEmpty, "no dry run either")
        XCTAssertEqual(KubeMCP.secretLookingEnv(["spec": ["env": [["name": "DB_PASSWORD", "value": "••••••"], ["name": "MODE", "value": "x"]]]]), nil)
        XCTAssertEqual(KubeMCP.secretLookingEnv([["env": [["name": "REDIS_PASS", "value": "x"]]]]), "REDIS_PASS")
    }

    // MARK: What is applied is what was diffed

    /// The buffer edited while the review and the dry run are in flight:
    /// the confirmation shows the text read once, and exactly its objects
    /// are sent, each to its own path.
    func testAnEditDuringTheReviewIsNotWhatIsSent() async throws {
        let model = model()
        api.add("deployments.apps", "api", namespace: "shop", values: ["Ready": "1/1"], fields: ["spec": ["replicas": 1]])
        let first = "apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: web, namespace: shop}\nspec: {replicas: 3}\n"
        let later =
            "apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: api, namespace: shop}\nspec: {replicas: 9}\n---\n"
            + "apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: web, namespace: shop}\nspec: {replicas: 7}\n"
        let (session, host) = session(model, first, context: "kind-fake")
        var reads = 0
        session.text = {
            reads += 1
            return reads == 1 ? first : later
        }
        await session.runApply()
        XCTAssertEqual(session.state, .done("Applied deployment shop/web to kind-fake."), "\(String(describing: session.state))")
        let asked = try XCTUnwrap(host.asked.first)
        XCTAssertTrue(asked.detail.contains("+  replicas: 3") && !asked.detail.contains("replicas: 7") && !asked.detail.contains("replicas: 9"), asked.detail)
        let sent = applies(dryRun: false)
        XCTAssertEqual(sent.map(\.path), ["/apis/apps/v1/namespaces/shop/deployments/web"])
        XCTAssertEqual(((sent.first?.json as? [String: Any])?["spec"] as? [String: Any])?["replicas"] as? Int, 3, "the text that was diffed")
        XCTAssertEqual(replicas(), 3)
        let api = ((self.api.object("deployments.apps", "api", namespace: "shop")?["spec"] as? [String: Any])?["replicas"] as? NSNumber)?.intValue
        XCTAssertEqual(api, 1, "an object typed in later isn't sent")
    }

    /// A version the cluster serves but doesn't prefer: the manifest's own
    /// version's path, never refused because discovery holds another.
    func testANonPreferredServedVersionIsApplied() async throws {
        api.addCRD(group: "acme.example", version: "v1", plural: "widgets", kind: "Widget")
        api.serve("widgets.acme.example", alsoAt: "v1beta1")
        api.add("widgets.acme.example", "blue", namespace: "shop", fields: ["spec": ["size": 1]])
        let model = model()
        let text = "apiVersion: acme.example/v1beta1\nkind: Widget\nmetadata: {name: blue, namespace: shop}\nspec: {size: 2}\n"
        let (session, host) = session(model, text, context: "kind-fake")
        defer { withExtendedLifetime(host) {} }
        let diffed = await session.runDiff()
        let result = try XCTUnwrap(diffed, "\(String(describing: session.state))")
        XCTAssertEqual(result.items.first?.ref.kind.version, "v1beta1")
        XCTAssertTrue(result.items.first?.diff.contains("+  size: 2") == true, result.items.first?.diff ?? "")
        await session.runApply()
        XCTAssertEqual(session.state, .done("Applied widget shop/blue to kind-fake."), "\(String(describing: session.state))")
        XCTAssertEqual(applies(dryRun: false).last?.path, "/apis/acme.example/v1beta1/namespaces/shop/widgets/blue", "the URL's version is the body's")
        XCTAssertEqual(applies(dryRun: false).last.flatMap { ($0.json as? [String: Any])?["apiVersion"] as? String }, "acme.example/v1beta1")
        let none = "apiVersion: acme.example/v9\nkind: Widget\nmetadata: {name: blue, namespace: shop}\nspec: {size: 2}\n"
        let (unserved, _) = self.session(model, none, context: "kind-fake")
        await unserved.runDiff()
        XCTAssertEqual(unserved.state, .failed("kind-fake serves no Widget at acme.example/v9 — it has acme.example/v1."))
    }

    /// `y` on a Deployment with a literal API_KEY: the copy holds it
    /// masked, and changing its replicas applies — the value given back
    /// from the live object in memory, never written to the copy.
    func testAnEnvMaskFromYIsAppliedUntouched() async throws {
        api.add(
            "deployments.apps", "api", namespace: "shop", values: ["Ready": "1/1"],
            fields: [
                "spec": [
                    "replicas": 1,
                    "template": ["spec": ["containers": [["name": "api", "image": "acme/api:1", "env": [["name": "API_KEY", "value": "live-key-Wq7"]]]]]],
                ]
            ])
        let model = model()
        let ref = KubeObjectRef(context: "kind-fake", kind: KubeWritesTests.deployments, namespace: "shop", name: "api")
        let live = try XCTUnwrap(api.object("deployments.apps", "api", namespace: "shop"))
        let copy = KubeManifestEdits.header(ref, production: false) + KubeYAML.text(KubeManifestDiff.forEditing(live))
        let url = KubeManifestEdits.register(ref, resourceVersion: nil)
        addTeardownBlock { await MainActor.run { KubeManifestEdits.remove(url) } }
        XCTAssertFalse(copy.contains("live-key-Wq7"))
        let edited = copy.replacingOccurrences(of: "replicas: 1", with: "replicas: 2")
        let session = KubeManifestSession(source: .object(ref), file: url, model: model)
        let host = Host()
        session.host = host
        session.text = { edited }
        await session.runApply()
        XCTAssertEqual(session.state, .done("Applied deployment shop/api to kind-fake."), "\(String(describing: session.state))")
        let now = try XCTUnwrap(api.object("deployments.apps", "api", namespace: "shop"))
        let spec = now["spec"] as? [String: Any]
        XCTAssertEqual((spec?["replicas"] as? NSNumber)?.intValue, 2)
        let env = (((spec?["template"] as? [String: Any])?["spec"] as? [String: Any])?["containers"] as? [[String: Any]])?.first?["env"] as? [[String: Any]]
        XCTAssertEqual(env?.first?["value"] as? String, "live-key-Wq7", "the cluster keeps its value")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "never a file")
        let shown = [host.asked.first?.detail, session.result?.items.first?.after, session.result?.items.first?.diff, session.state.text].compactMap { $0 }
        XCTAssertFalse(shown.joined().contains("live-key-Wq7"), "never shown")
    }

    /// Another context picked while a diff works: its answer is dropped.
    func testAContextPickedMidDiffDropsTheAnswer() async throws {
        let model = model()
        let folder = URL(fileURLWithPath: "/tmp/checkout/deploy")
        let session = KubeManifestSession(source: .kustomization(folder), file: folder.appendingPathComponent("kustomization.yaml"), model: model)
        session.contextName = "kind-fake"
        session.host = Host()
        let manifest = deployment
        session.render = { [weak session] _, _ in
            await MainActor.run { session?.contextName = "fake-dev" }
            return manifest
        }
        let diffed = await session.runDiff()
        XCTAssertNil(diffed)
        XCTAssertNil(session.result, "not shown under fake-dev")
        XCTAssertEqual(session.contextName, "fake-dev")
        XCTAssertEqual(session.state, .idle)
    }

    /// A kustomization renders the saved files: an unsaved one in its
    /// folder is refused, never silently left out; the label says so.
    func testAKustomizationWithUnsavedFilesIsRefused() async throws {
        let model = model()
        let folder = URL(fileURLWithPath: "/tmp/checkout/deploy")
        let session = KubeManifestSession(source: .kustomization(folder), file: folder.appendingPathComponent("kustomization.yaml"), model: model)
        session.contextName = "kind-fake"
        session.host = Host()
        var rendered = 0
        let manifest = deployment
        session.render = { _, _ in
            rendered += 1
            return manifest
        }
        session.unsaved = { [folder.appendingPathComponent("web.yaml"), URL(fileURLWithPath: "/tmp/checkout/other/x.yaml")] }
        let refused = await session.runDiff()
        XCTAssertNil(refused)
        XCTAssertEqual(session.state, .failed("Save first: kubectl kustomize renders the saved files, and web.yaml has unsaved changes."))
        await session.runApply()
        XCTAssertTrue(session.state.text?.hasPrefix("Save first") == true)
        XCTAssertEqual(rendered, 0)
        XCTAssertTrue(applies(dryRun: false).isEmpty)
        session.unsaved = { [URL(fileURLWithPath: "/tmp/checkout/other/x.yaml")] }
        let diffed = await session.runDiff()
        XCTAssertTrue(diffed?.label.hasSuffix("Rendered by kubectl kustomize from the saved files.") == true, diffed?.label ?? "")
    }

    /// A webhook that takes no dry run: the labelled client-side diff. An
    /// admission's denial: shown, never a client-side diff as if it applied.
    func testAWebhookWithoutDryRunFallsBackAndADenialIsShown() async throws {
        let model = model()
        api.failNextWrite(400, reason: "BadRequest", message: "admission webhook \"audit.acme.example\" does not support dry run")
        let (session, _) = session(model, deployment, context: "kind-fake")
        let diffed = await session.runDiff()
        let result = try XCTUnwrap(diffed, "\(String(describing: session.state))")
        guard case .clientSide(let why) = result.method else { return XCTFail("client-side") }
        XCTAssertTrue(why.contains("takes no dry run"), why)
        api.failNextWrite(403, reason: "Forbidden", message: "admission webhook \"policy.acme.example\" denied the request: replicas over 2")
        let denied = await session.runDiff()
        XCTAssertNil(denied)
        XCTAssertEqual(session.state, .failed("kind-fake's admission refuses it: admission webhook \"policy.acme.example\" denied the request: replicas over 2"))
        XCTAssertNil(session.result, "no client-side diff for a denial — not the last one either")
    }

    func testAgentsApplyOnProductionNeedsApplyOnProduction() async throws {
        flags.prodSetWritable = true
        let model = model()
        await switchOn(model)
        agentWrites = ["fake-prod"]
        KubeMCP.askOverride = { _ in "web" }
        let refused = await call(model, ["manifest": deployment, "context": "fake-prod"])
        XCTAssertTrue(refused.error && refused.text.contains("applyOnProduction"), refused.text)
        XCTAssertTrue(applies(dryRun: false).isEmpty && applies(dryRun: true).isEmpty, "refused before a dry run")
        applyOnProduction = true
        let done = await call(model, ["manifest": deployment, "context": "fake-prod"])
        XCTAssertFalse(done.error, done.text)
        XCTAssertEqual(replicas(), 3)
    }
}

/// Overterm's copy of a cluster object is never saved: a value retyped in
/// it stays in memory (rule 9), and its edits ask nothing on close.
@MainActor
final class KubeManifestCopySaveTests: XCTestCase {
    func testAnUnsaveableDocumentIsNeverWritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("deployment-web.yaml")
        try "data:\n  password: \"***\"\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let document = EditorDocument()
        document.load(url)
        document.unsaveable = KubeManifestEdits.unsaved
        document.markEdited()
        XCTAssertThrowsError(try document.save("data:\n  password: retyped-Hq2\n", overwriting: true)) { error in
            XCTAssertEqual(error.localizedDescription, KubeManifestEdits.unsaved)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "data:\n  password: \"***\"\n", "the file as y wrote it")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600, "never replaced at the umask's mode")
    }
}
