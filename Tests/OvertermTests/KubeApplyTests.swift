import Foundation
import NIOHTTP1
import XCTest

@testable import Overterm

/// Stage 2b, pure (docs/design/kubernetes/analysis.md, 2.8 and 3.3): a
/// manifest read, the server-side apply's requests (dry run, apply, force),
/// what each side of the diff leaves out and masks, who else owns a field,
/// a 409 read, the client-side label and production's rules. Every
/// context and value here is fictional.
final class KubeApplyTests: XCTestCase {
    static let secrets = KubeResourceKind(
        group: "", version: "v1", resource: "secrets", kind: "Secret", singular: "secret", namespaced: true,
        verbs: ["create", "delete", "get", "list", "patch", "update", "watch"])
    static let discovery = KubeDiscovery(kinds: [.pods, .namespaces, KubeWritesTests.deployments, KubeWritesTests.configmaps, secrets, KubeWritesTests.nodes])

    static let deployment = """
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: web
          labels:
            app: web
        spec:
          replicas: 3
        """

    // MARK: Reading a manifest

    func testAManifestsDocumentsListsAndJSON() throws {
        let text = Self.deployment + "\n---\n# a comment\n---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: web-config\n  namespace: payments\ndata:\n  a: \"1\"\n"
        let objects = try KubeManifest.parse(text)
        XCTAssertEqual(objects.map(\.spoken), ["deployment web", "configmap payments/web-config"], "an empty document is passed over")
        XCTAssertEqual(objects[0].group, "apps")
        XCTAssertEqual(objects[0].version, "v1")
        XCTAssertEqual(objects[1].group, "", "the core group")
        XCTAssertEqual((objects[0].object["spec"] as? [String: Any])?["replicas"] as? Int, 3)
        let list = try KubeManifest.parse(
            "apiVersion: v1\nkind: List\nitems:\n- apiVersion: v1\n  kind: ConfigMap\n  metadata: {name: a}\n- apiVersion: v1\n  kind: ConfigMap\n  metadata: {name: b}\n")
        XCTAssertEqual(list.map(\.name), ["a", "b"], "a List's items, each an object")
        let json = try KubeManifest.parse(#"{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"j"}}"#)
        XCTAssertEqual(json.map(\.name), ["j"])
        XCTAssertThrowsError(try KubeManifest.parse("  \n")) { XCTAssertEqual(($0 as? KubeManifestProblem)?.message, "The manifest is empty: there is nothing to compare.") }
        XCTAssertThrowsError(try KubeManifest.parse("apiVersion: v1\nkind: Pod\nmetadata:\n  generateName: web-\n")) {
            XCTAssertTrue(($0 as? KubeManifestProblem)?.message.contains("generateName") == true)
        }
        XCTAssertThrowsError(try KubeManifest.parse("kind: Pod\nmetadata: {name: a}\n")) {
            XCTAssertEqual(($0 as? KubeManifestProblem)?.message, "Document 1 has no apiVersion.")
        }
        XCTAssertThrowsError(try KubeManifest.parse("- a\n- b\n")) { XCTAssertEqual(($0 as? KubeManifestProblem)?.message, "Document 1 isn't an object.") }
    }

    func testWhichFilesAreManifests() {
        XCTAssertTrue(KubeManifest.looksLikeManifest(Self.deployment))
        XCTAssertFalse(KubeManifest.looksLikeManifest("name: CI\non: push\njobs: {}\n"), "a workflow file isn't one")
        XCTAssertFalse(KubeManifest.looksLikeManifest("  apiVersion: v1\n  kind: Pod\n"), "only at the top level")
        XCTAssertTrue(KubeManifest.isKustomization(URL(fileURLWithPath: "/src/shop/deploy/kustomization.yaml")))
        XCTAssertTrue(KubeManifest.isYAML(URL(fileURLWithPath: "/src/shop/web.yml")))
        XCTAssertFalse(KubeManifest.isYAML(URL(fileURLWithPath: "/src/shop/web.swift")))
        XCTAssertEqual(KubeApply.kustomizeArguments("/src/shop/deploy"), ["kustomize", "/src/shop/deploy"], "rendered from files: no --context, no cluster")
    }

    // MARK: The requests

    func testWhereAnObjectGoes() throws {
        let objects = try KubeManifest.parse(Self.deployment + "\n---\napiVersion: v1\nkind: Node\nmetadata:\n  name: fake-node-1\n  namespace: shop\n")
        let web = try KubeApply.ref(objects[0], context: "kind-fake", discovery: Self.discovery, namespace: "shop")
        XCTAssertEqual(web.kind.fullName, "deployments.apps")
        XCTAssertEqual(web.namespace, "shop", "no namespace in the file: the one picked")
        let node = try KubeApply.ref(objects[1], context: "kind-fake", discovery: Self.discovery, namespace: "shop")
        XCTAssertNil(node.namespace, "a cluster-wide kind has none, whatever the file says")
        XCTAssertThrowsError(try KubeApply.ref(objects[0], context: "kind-fake", discovery: Self.discovery, namespace: nil)) {
            XCTAssertEqual(($0 as? KubeManifestProblem)?.message, "deployment web names no namespace, and none is picked for it.")
        }
        let old = try KubeManifest.parse("apiVersion: apps/v1beta1\nkind: Deployment\nmetadata: {name: web}\n")[0]
        XCTAssertThrowsError(try KubeApply.ref(old, context: "kind-fake", discovery: Self.discovery, namespace: "shop")) {
            XCTAssertEqual(($0 as? KubeManifestProblem)?.message, "kind-fake serves no Deployment at apps/v1beta1 — it has apps/v1.")
        }
    }

    func testTheDryRunTheApplyAndTheForce() throws {
        let object = try KubeManifest.parse(Self.deployment + "\nstatus:\n  replicas: 9\n")[0]
        let ref = try KubeApply.ref(object, context: "kind-fake", discovery: Self.discovery, namespace: "shop")
        var withFields = object.object
        var metadata = withFields["metadata"] as? [String: Any] ?? [:]
        metadata["managedFields"] = [["manager": "helm"]]
        withFields["metadata"] = metadata
        let body = KubeApply.body(withFields, ref: ref, resourceVersion: "41")
        let dry = KubeApply.request(body, ref: ref, dryRun: true)
        XCTAssertEqual(dry.method, .PATCH)
        XCTAssertEqual(dry.path, "/apis/apps/v1/namespaces/shop/deployments/web?fieldManager=overterm&dryRun=All")
        XCTAssertEqual(dry.contentType, "application/apply-patch+yaml")
        let sent = try XCTUnwrap(dry.json as? [String: Any])
        let sentMetadata = try XCTUnwrap(sent["metadata"] as? [String: Any])
        XCTAssertEqual(sentMetadata["namespace"] as? String, "shop", "the namespace it goes to")
        XCTAssertEqual(sentMetadata["resourceVersion"] as? String, "41", "the version it was opened at")
        XCTAssertNil(sentMetadata["managedFields"], "the server's own")
        XCTAssertNil(sent["status"], "the controllers'")
        XCTAssertEqual(
            KubeApply.request(body, ref: ref, dryRun: false).path, "/apis/apps/v1/namespaces/shop/deployments/web?fieldManager=overterm", "no dry run, no force")
        XCTAssertEqual(
            KubeApply.request(body, ref: ref, dryRun: false, force: true).path, "/apis/apps/v1/namespaces/shop/deployments/web?fieldManager=overterm&force=true")
        XCTAssertEqual(
            KubeApply.kubectl(file: "deployment-web.yaml", context: "kind-fake", namespace: "shop"),
            "kubectl apply --server-side --field-manager=overterm -f deployment-web.yaml --context kind-fake -n shop")
        XCTAssertEqual(
            KubeApply.kubectl(file: "/src/my shop/web.yaml", context: "kind-fake", namespace: nil, force: true),
            "kubectl apply --server-side --field-manager=overterm --force-conflicts -f '/src/my shop/web.yaml' --context kind-fake")
    }

    // MARK: What the diff shows

    func testAnEditorCopyIsStrippedAndMasked() {
        let object: [String: Any] = [
            "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
            "metadata": [
                "name": "web-db", "namespace": "shop", "resourceVersion": "12", "uid": "u-1", "creationTimestamp": "2026-11-01T00:00:00Z",
                "managedFields": [["manager": "kubectl"]], "annotations": [KubeObjectStrip.lastApplied: #"{"data":{"password":"cGxhaW4tcHctUTE="}}"#],
            ],
            "data": ["password": "cGxhaW4tcHctUTE="], "status": ["x": 1],
        ]
        let copy = KubeManifestDiff.forEditing(object)
        let text = KubeYAML.text(copy)
        XCTAssertFalse(text.contains("cGxhaW4tcHctUTE="), "no value in the file, the annotation's neither")
        XCTAssertTrue(text.contains("password: '***'") || text.contains("password: \"***\"") || text.contains("password: ***"), text)
        let metadata = copy["metadata"] as? [String: Any] ?? [:]
        for gone in ["resourceVersion", "uid", "creationTimestamp", "managedFields", "annotations"] { XCTAssertNil(metadata[gone], gone) }
        XCTAssertNil(copy["status"])
        let pod: [String: Any] = [
            "apiVersion": "v1", "kind": "Pod", "metadata": ["name": "web-1"],
            "spec": ["containers": [["name": "web", "env": [["name": "DB_PASSWORD", "value": "plain-pw-Q1"], ["name": "MODE", "value": "fast"]]]]],
        ]
        let podText = KubeYAML.text(KubeManifestDiff.forEditing(pod))
        XCTAssertFalse(podText.contains("plain-pw-Q1"))
        XCTAssertTrue(podText.contains("fast"))
    }

    func testASecretsDiffIsMaskedBeforeAndAfter() {
        let live: [String: Any] = [
            "apiVersion": "v1", "kind": "Secret", "metadata": ["name": "web-db", "namespace": "shop", "managedFields": [["manager": "x"]]],
            "data": ["password": "b2xkLXB3LVEx", "username": "d2Vi", "gone": "eA=="],
        ]
        let after: [String: Any] = [
            "apiVersion": "v1", "kind": "Secret", "metadata": ["name": "web-db", "namespace": "shop"],
            "data": ["password": "bmV3LXB3LVo5", "username": "d2Vi", "added": "eQ=="],
        ]
        let sides = KubeManifestDiff.sides(live: live, after: after)
        for value in ["b2xkLXB3LVEx", "bmV3LXB3LVo5", "d2Vi", "eA==", "eQ=="] {
            XCTAssertFalse(sides.before.contains(value) || sides.after.contains(value), value)
        }
        XCTAssertTrue(sides.before.contains("password: '*** (before)'") || sides.before.contains("password: \"*** (before)\""), sides.before)
        XCTAssertTrue(sides.after.contains("*** (after)"), sides.after)
        XCTAssertFalse(sides.before.contains("username: \"*** (before)\""), "the same value: *** on both sides")
        XCTAssertFalse(sides.before.contains("managedFields"))
        let diff = KubeManifestDiff.unified(before: sides.before, after: sides.after, from: "secret shop/web-db in kind-fake", to: "after apply")
        XCTAssertTrue(diff.text.hasPrefix("--- secret shop/web-db in kind-fake\n+++ after apply\n@@ "), diff.text)
        XCTAssertTrue(diff.text.contains("-  password: \"*** (before)\"") || diff.text.contains("-  password: '*** (before)'"), diff.text)
        XCTAssertTrue(diff.text.contains("+  added: \"***\"") || diff.text.contains("+  added: '***'"), diff.text)
        XCTAssertTrue(diff.text.contains("-  gone:"), diff.text)
        XCTAssertGreaterThan(diff.added, 0)
    }

    func testEnvValuesAreMaskedInPairs() {
        func pod(_ password: String, _ mode: String) -> [String: Any] {
            ["kind": "Pod", "spec": ["containers": [["name": "web", "env": [["name": "DB_PASSWORD", "value": password], ["name": "MODE", "value": mode]]]]]]
        }
        let changed = KubeManifestDiff.sides(live: pod("pw-one-A", "fast"), after: pod("pw-two-B", "slow"))
        XCTAssertFalse(changed.before.contains("pw-one-A") || changed.after.contains("pw-two-B"))
        XCTAssertTrue(changed.before.contains("•••••• (before)") && changed.after.contains("•••••• (after)"), "a changed secret says so")
        XCTAssertTrue(changed.after.contains("slow"), "the rest as it is")
        let same = KubeManifestDiff.sides(live: pod("pw-one-A", "fast"), after: pod("pw-one-A", "slow"))
        XCTAssertEqual(KubeManifestDiff.unified(before: same.before, after: same.after, from: "a", to: "b").removed, 1, "only MODE changes")
    }

    func testTheClientSideGuess() {
        let live: [String: Any] = [
            "apiVersion": "v1", "kind": "Secret", "metadata": ["name": "web-db", "labels": ["a": "1"]], "data": ["password": "b2xk"], "type": "Opaque",
        ]
        let manifest: [String: Any] = ["apiVersion": "v1", "kind": "Secret", "metadata": ["name": "web-db", "labels": ["b": "2"]], "stringData": ["password": "new"]]
        let merged = KubeManifestDiff.clientSide(live: live, manifest: manifest)
        XCTAssertEqual((merged["metadata"] as? [String: Any])?["labels"] as? [String: String], ["a": "1", "b": "2"], "maps merged")
        XCTAssertEqual((merged["data"] as? [String: String])?["password"], Data("new".utf8).base64EncodedString(), "stringData folded into data")
        XCTAssertNil(merged["stringData"])
        XCTAssertEqual(merged["type"] as? String, "Opaque", "what the file leaves out stays")
        let result = KubeManifestDiffResult(context: "fake-dev", production: false, method: .clientSide("fake-dev is read-only."), items: [], text: "")
        XCTAssertEqual(result.label, "client-side: defaults and admission not applied — fake-dev is read-only.")
        XCTAssertFalse(result.isServerSide)
    }

    func testUnchangedIsNoDiff() {
        let text = "a: 1\nb: 2\n"
        XCTAssertEqual(KubeManifestDiff.unified(before: text, after: text, from: "x", to: "y").text, "")
        let long = (1...20).map { "line\($0): x" }.joined(separator: "\n") + "\n"
        let changed = long.replacingOccurrences(of: "line10: x", with: "line10: y")
        let diff = KubeManifestDiff.unified(before: long, after: changed, from: "x", to: "y")
        XCTAssertTrue(diff.text.contains("@@ -7,7 +7,7 @@"), diff.text)
        XCTAssertEqual(diff.added, 1)
        XCTAssertEqual(diff.removed, 1)
    }

    // MARK: Who else owns it

    func testOtherOwnersOfWhatChanges() {
        let live: [String: Any] = [
            "metadata": [
                "name": "web",
                "managedFields": [
                    [
                        "manager": "helm", "operation": "Apply",
                        "fieldsV1": ["f:spec": ["f:replicas": [String: Any](), "f:template": ["f:spec": ["f:containers": ["k:{\"name\":\"web\"}": [".": [String: Any]()]]]]]],
                    ],
                    ["manager": KubeWrites.fieldManager, "operation": "Apply", "fieldsV1": ["f:metadata": ["f:labels": ["f:app": [String: Any]()]]]],
                    ["manager": "kube-controller-manager", "operation": "Update", "fieldsV1": ["f:status": ["f:replicas": [String: Any]()]]],
                ],
                "labels": ["app": "web"],
            ],
            "spec": ["replicas": 1, "template": ["spec": ["containers": [["name": "web", "image": "nginx:1.27"]]]]],
        ]
        let manifest: [String: Any] = ["metadata": ["name": "web", "labels": ["app": "web"]], "spec": ["replicas": 3]]
        let owners = KubeFieldOwners.others(after: manifest, live: live)
        XCTAssertEqual(owners, [KubeFieldOwners.Owner(manager: "helm", operation: "Apply", fields: [".spec.replicas"])], "only what changes; ours and status aren't others'")
        XCTAssertEqual(
            KubeFieldOwners.warnings(owners, managedBy: []), ["Helm manages this: its next upgrade sets these fields back.", "Also owned: helm owns .spec.replicas (Apply)."])
        XCTAssertTrue(KubeFieldOwners.others(after: ["spec": ["replicas": 1]], live: live).isEmpty, "the same value: nobody's change is undone")
        let containers = KubeFieldOwners.others(after: ["spec": ["template": ["spec": ["containers": [["name": "web", "image": "nginx:1.28"]]]]]], live: live)
        XCTAssertEqual(containers.first?.fields, [".spec.template.spec.containers"], "a list's items owned as the list")
        let argo: [String: Any] = [
            "metadata": [
                "name": "web", "labels": ["argocd.argoproj.io/instance": "shop"],
                "managedFields": [["manager": "argocd-controller", "operation": "Apply", "fieldsV1": ["f:spec": ["f:replicas": [String: Any]()]]]],
            ],
            "spec": ["replicas": 1],
        ]
        let argoOwners = KubeFieldOwners.others(after: manifest, live: argo)
        XCTAssertEqual(argoOwners.first?.tool, .argoCD)
        XCTAssertEqual(KubeFieldOwners.warnings(argoOwners, managedBy: KubeFieldOwners.managedBy(argo)).first, "Argo CD manages this; your change will be reverted.")
        XCTAssertEqual(KubeFieldOwners.Tool.of(manager: "kustomize-controller"), .fluxKustomize)
        XCTAssertEqual(KubeFieldOwners.Tool.of(manager: "helm-controller"), .fluxHelm)
        XCTAssertEqual(KubeFieldOwners.managedBy(["metadata": ["labels": ["kustomize.toolkit.fluxcd.io/name": "apps"]]]), [.fluxKustomize])
        XCTAssertEqual(KubeFieldOwners.managedBy(["metadata": ["labels": ["app.kubernetes.io/managed-by": "Helm"]]]), [.helm])
    }

    // MARK: A 409

    func testAConflictRead() {
        var conflict = KubeAPIError(status: 409, reason: "Conflict", message: #"Apply failed with 1 conflict: conflict with "helm" using apps/v1: .spec.replicas"#)
        conflict.causes = [KubeStatusCause(reason: "FieldManagerConflict", message: #"conflict with "helm" using apps/v1"#, field: ".spec.replicas")]
        XCTAssertEqual(KubeApplyConflict.read(conflict), .fields([.init(manager: "helm", field: ".spec.replicas")]))
        XCTAssertEqual(KubeApplyConflict.read(conflict)?.said, "helm owns .spec.replicas")
        conflict.causes = []
        XCTAssertEqual(KubeApplyConflict.read(conflict), .fields([.init(manager: "helm", field: ".spec.replicas")]), "from the message alone too")
        let changed = KubeAPIError(
            status: 409, reason: "Conflict", message: "Operation cannot be fulfilled on deployments.apps \"web\": the object has been modified")
        XCTAssertEqual(KubeApplyConflict.read(changed), .changed(changed.message), "the version sent is old")
        XCTAssertNil(KubeApplyConflict.read(KubeAPIError(status: 422, reason: nil, message: "x")))
        let body = Data(
            #"{"kind":"Status","code":409,"reason":"Conflict","message":"Apply failed with 2 conflicts","details":{"causes":[{"reason":"FieldManagerConflict","message":"conflict with \"helm\" using apps/v1","field":".spec.replicas"},{"reason":"FieldManagerConflict","message":"conflict with \"argocd-controller\" using apps/v1","field":".spec.template"}]}}"#
                .utf8)
        let read = KubeAPIError.from(HTTPResponse(status: 409, headers: [], body: body))
        XCTAssertEqual(KubeApplyConflict.read(read)?.managers, ["helm", "argocd-controller"])
    }

    // MARK: Production and the masks

    func testWhereApplyIsOffered() {
        let local = KubeWritesTests.context("kind-fake")
        XCTAssertNil(KubeApplyCheck.refused(local))
        XCTAssertNil(KubeApplyCheck.refused(local, force: true), "forced on a local context, asked again")
        XCTAssertFalse(KubeApplyCheck.rule(local).typedName)
        XCTAssertEqual(
            KubeApplyCheck.refused(KubeWritesTests.context("fake-dev")),
            "This context is read-only: Overterm changes nothing here (its writable setting). Diff with Cluster still shows what would change.")
        XCTAssertEqual(
            KubeApplyCheck.refused(KubeWritesTests.context("fake-prod")),
            "Production is read-only: turn on writes for this session on its card first. Diff with Cluster still shows what would change.")
        let on = KubeWritesTests.context("fake-prod", session: true)
        XCTAssertEqual(
            KubeApplyCheck.refused(on),
            "Apply is off on production, even with its writes on: the context's applyOnProduction setting turns it on. Diff with Cluster still works.",
            "writes on is not enough (decision 30)")
        let opted = KubeWritesTests.context("fake-prod", settings: KubeContextSettings(applyOnProduction: true), session: true)
        XCTAssertNil(KubeApplyCheck.refused(opted))
        XCTAssertTrue(KubeApplyCheck.rule(opted).typedName, "the name typed (rule 4)")
        XCTAssertEqual(KubeApplyCheck.refused(opted, force: true), "An apply is never forced on production: change the field's owner, or the manifest.")
        XCTAssertNotNil(
            KubeApplyCheck.refused(KubeWritesTests.context("fake-prod", settings: KubeContextSettings(applyOnProduction: true))),
            "applyOnProduction without the session switch: read-only still")
        XCTAssertNotNil(
            KubeApplyCheck.refused(KubeWritesTests.context("kind-fake", settings: KubeContextSettings(writable: false, applyOnProduction: true))),
            "applyOnProduction opens nothing but production")
        XCTAssertEqual(KubeContextSettings(fields: ["applyOnProduction": .bool(true)]).applyOnProduction, true, "a kubernetes.contexts field")
        XCTAssertTrue(KubeContextSettings.fields.contains { $0.name == "applyOnProduction" })
    }

    func testAMaskedValueIsNeverAppliedBack() throws {
        let secret = try KubeManifest.parse("apiVersion: v1\nkind: Secret\nmetadata: {name: web-db}\ndata:\n  password: \"***\"\n  username: d2Vi\n")[0]
        XCTAssertEqual(KubeApplyCheck.masked(secret), [".data.password"])
        XCTAssertEqual(KubeApplyCheck.maskedBeforeReading(secret), [".data.password"], "a Secret's: refused before anything is read")
        let unknown = KubeApplyCheck.maskedSaid([".data.password"], of: secret.spoken, owned: nil)
        XCTAssertTrue(unknown.contains("Retype each value"), unknown)
        XCTAssertTrue(unknown.contains("one it applied before is removed"), "never says a key left out stays, not knowing: \(unknown)")
        XCTAssertFalse(unknown.contains("stays as it is in the cluster"), unknown)
        let pod = try KubeManifest.parse(
            "apiVersion: v1\nkind: Pod\nmetadata: {name: web-1}\nspec:\n  containers:\n  - name: web\n    env:\n    - name: DB_PASSWORD\n      value: \"••••••\"\n")[0]
        XCTAssertEqual(KubeApplyCheck.masked(pod), [".spec.containers[0].env[DB_PASSWORD]"])
        XCTAssertTrue(KubeApplyCheck.maskedBeforeReading(pod).isEmpty, "an env mask waits for the live object")
        let retyped = try KubeManifest.parse("apiVersion: v1\nkind: Secret\nmetadata: {name: web-db}\nstringData:\n  password: typed-again\n")[0]
        XCTAssertTrue(KubeApplyCheck.masked(retyped).isEmpty)
        // For the diff only: what is still masked shows as unchanged.
        let live: [String: Any] = ["apiVersion": "v1", "kind": "Secret", "metadata": ["name": "web-db"], "data": ["password": "b2xk", "username": "d2Vi"]]
        let unmasked = KubeApplyCheck.unmasked(secret.object, live: live)
        XCTAssertEqual((unmasked["data"] as? [String: Any])?["password"] as? String, "b2xk")
        let livePod: [String: Any] = ["spec": ["containers": [["name": "web", "env": [["name": "DB_PASSWORD", "value": "real"]]]]]]
        let podUnmasked = KubeApplyCheck.unmasked(pod.object, live: livePod)
        XCTAssertEqual(
            (((podUnmasked["spec"] as? [String: Any])?["containers"] as? [[String: Any]])?.first?["env"] as? [[String: Any]])?.first?["value"] as? String, "real")
    }

    /// A key Overterm's own apply owns is removed when left out of the
    /// next one: the refusal never offers taking it out.
    func testAMaskedKeyOvertermAppliedIsNeverOfferedForRemoval() throws {
        let secret = try KubeManifest.parse("apiVersion: v1\nkind: Secret\nmetadata: {name: web-db, namespace: shop}\ndata:\n  password: \"***\"\n  username: \"***\"\n")[0]
        let live: [String: Any] = [
            "metadata": [
                "name": "web-db",
                "managedFields": [
                    ["manager": KubeWrites.fieldManager, "operation": "Apply", "fieldsV1": ["f:data": ["f:password": [String: Any]()]]],
                    ["manager": "kubectl-create", "operation": "Update", "fieldsV1": ["f:data": ["f:username": [String: Any]()]]],
                ],
            ]
        ]
        let owned = KubeFieldOwners.overterms(live)
        XCTAssertEqual(owned, [".data.password"])
        let said = KubeApplyCheck.maskedSaid(KubeApplyCheck.masked(secret), of: secret.spoken, owned: owned)
        XCTAssertTrue(said.contains("Don't take .data.password out: Overterm applied it before, so leaving it out removes it from the cluster."), said)
        XCTAssertTrue(said.contains(".data.username may be taken out instead: Overterm never applied it, so it stays as it is in the cluster."), said)
        let stringData = KubeApplyCheck.maskedSaid([".stringData.password"], of: secret.spoken, owned: owned)
        XCTAssertTrue(stringData.contains("Don't take .stringData.password out"), "stringData is data's: \(stringData)")
    }

    /// `y` masks an env value whose name looks secret: the apply gives an
    /// untouched mask its live value back, in memory, by the container's
    /// name — a retyped or new one is the copy's own; a Secret's never.
    func testAnUntouchedEnvMaskIsGivenItsLiveValueBack() throws {
        let live: [String: Any] = [
            "apiVersion": "apps/v1", "kind": "Deployment", "metadata": ["name": "web"],
            "spec": [
                "template": [
                    "spec": [
                        "containers": [
                            ["name": "side", "env": [["name": "API_KEY", "value": "side-key-Q9"]]],
                            [
                                "name": "web",
                                "env": [
                                    ["name": "API_KEY", "value": "web-key-Z7"], ["name": "DB_URL", "value": "postgres://u:pw-Hx@db/shop"],
                                    ["name": "OTHER_TOKEN", "value": "o-1"],
                                ],
                            ],
                        ]
                    ]
                ]
            ],
        ]
        let copy = KubeManifestDiff.forEditing(live)
        let text = KubeYAML.text(copy)
        for value in ["side-key-Q9", "web-key-Z7", "pw-Hx", "o-1"] { XCTAssertFalse(text.contains(value), "never in the copy: \(value)") }
        // The copy's containers in another order, one value retyped, one new.
        var spec = ((copy["spec"] as? [String: Any])?["template"] as? [String: Any])?["spec"] as? [String: Any] ?? [:]
        var containers = (spec["containers"] as? [[String: Any]] ?? []).reversed().map { $0 }
        var env = containers[0]["env"] as? [[String: Any]] ?? []
        env[2]["value"] = "typed-again"
        env.append(["name": "NEW_SECRET", "value": KubeManifestDiff.envMask])
        containers[0]["env"] = env
        spec["containers"] = containers
        var object = copy
        object["spec"] = ["template": ["spec": spec]]
        let sent = KubeApplyCheck.restoringEnv(object, live: live)
        let sentContainers = (((sent["spec"] as? [String: Any])?["template"] as? [String: Any])?["spec"] as? [String: Any])?["containers"] as? [[String: Any]] ?? []
        func value(_ container: Int, _ name: String) -> String? {
            (sentContainers[container]["env"] as? [[String: Any]])?.first { $0["name"] as? String == name }?["value"] as? String
        }
        XCTAssertEqual(value(0, "API_KEY"), "web-key-Z7", "by the container's name, not its place")
        XCTAssertEqual(value(1, "API_KEY"), "side-key-Q9")
        XCTAssertEqual(value(0, "DB_URL"), "postgres://u:pw-Hx@db/shop", "a URL's masked password too")
        XCTAssertEqual(value(0, "OTHER_TOKEN"), "typed-again", "retyped: the copy's own")
        let manifest = try KubeManifest.object(sent, document: 1)
        XCTAssertEqual(KubeApplyCheck.masked(manifest), [".spec.template.spec.containers[0].env[NEW_SECRET]"], "no live twin: still refused")
        // A Secret's values are never given back.
        let secret: [String: Any] = ["apiVersion": "v1", "kind": "Secret", "metadata": ["name": "s"], "data": ["k": "***"]]
        XCTAssertEqual((KubeApplyCheck.restoringEnv(secret, live: ["data": ["k": "dg=="]])["data"] as? [String: Any])?["k"] as? String, "***")
    }

    /// Who else owns what changes is read from the dry run's result: a
    /// checkout's container list without the server's defaults changes
    /// nothing, so nobody is warned of.
    func testOtherOwnersAreReadFromTheResultNotTheFile() {
        let containers: [[String: Any]] = [["name": "web", "image": "nginx:1.27", "imagePullPolicy": "IfNotPresent", "terminationMessagePath": "/dev/termination-log"]]
        let live: [String: Any] = [
            "metadata": [
                "name": "web", "labels": ["argocd.argoproj.io/instance": "shop"],
                "managedFields": [["manager": "argocd-controller", "operation": "Apply", "fieldsV1": ["f:spec": ["f:template": ["f:spec": ["f:containers": [String: Any]()]]]]]],
            ],
            "spec": ["replicas": 1, "template": ["spec": ["containers": containers]]],
        ]
        let file: [String: Any] = ["metadata": ["name": "web"], "spec": ["template": ["spec": ["containers": [["name": "web", "image": "nginx:1.27"]]]]]]
        XCTAssertFalse(KubeFieldOwners.others(after: file, live: live).isEmpty, "the file against the live object: the defaults look changed")
        XCTAssertTrue(KubeFieldOwners.others(after: live, live: live).isEmpty, "the dry run's result: nothing changes")
        let ref = KubeWritesTests.deployment(in: "kind-fake")
        let unchanged = KubeManifestItem(
            ref: ref, before: "a", after: "a", diff: "", added: 0, removed: 0, isNew: false, owners: [], managedBy: KubeFieldOwners.managedBy(live), masked: [])
        let result = KubeManifestDiffResult(context: "kind-fake", production: false, method: .serverSide, items: [unchanged], text: "")
        XCTAssertTrue(result.warnings.isEmpty, "an object that doesn't change warns of nothing: \(result.warnings)")
    }

    func testTheConfirmationSaysItAll() throws {
        let ref = KubeWritesTests.deployment(in: "fake-prod")
        let item = KubeManifestItem(
            ref: ref, before: "", after: "", diff: "--- a\n+++ b\n@@ -1,1 +1,1 @@\n-  replicas: 1\n+  replicas: 3\n", added: 1, removed: 1, isNew: false,
            owners: [KubeFieldOwners.Owner(manager: "argocd-controller", operation: "Apply", fields: [".spec.replicas"])], managedBy: [], masked: [])
        let result = KubeManifestDiffResult(context: "fake-prod", production: true, method: .serverSide, items: [item], text: "")
        let context = KubeWritesTests.context("fake-prod", settings: KubeContextSettings(applyOnProduction: true), session: true)
        let confirmation = KubeApplyConfirmation.make(result, context: context, kubectl: "kubectl apply --server-side -f x.yaml --context fake-prod -n shop")
        XCTAssertEqual(confirmation.title, "Apply deployment shop/web to fake-prod?")
        XCTAssertEqual(confirmation.scope, "PRODUCTION · fake-prod · namespace shop")
        XCTAssertTrue(confirmation.production)
        XCTAssertEqual(confirmation.typedName, "web")
        for said in [
            "Server-side dry run (dryRun=All)", "deployment shop/web: +1 −1", "-  replicas: 1", "+  replicas: 3", "⚠︎ Argo CD manages this; your change will be reverted.",
            "Equals: kubectl apply --server-side", "Type web to confirm.",
        ] {
            XCTAssertTrue(confirmation.detail.contains(said), said)
        }
        XCTAssertFalse(confirmation.accepts("wbe"))
        XCTAssertTrue(confirmation.accepts("web"))
        let forced = KubeApplyConfirmation.make(
            result, context: KubeWritesTests.context("kind-fake"), kubectl: "k", force: .fields([.init(manager: "helm", field: ".spec.replicas")]))
        XCTAssertEqual(forced.title, "Force the apply of deployment shop/web?")
        XCTAssertEqual(forced.button, "Force Apply")
        XCTAssertTrue(forced.detail.contains("Forcing takes these fields from their managers: helm owns .spec.replicas."))
        XCTAssertNil(forced.typedName)
    }
}
