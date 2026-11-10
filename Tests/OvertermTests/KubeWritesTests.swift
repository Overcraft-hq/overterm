import Foundation
import NIOHTTP1
import XCTest

@testable import Overterm

/// The writes of stage 2a's first part, pure: which verb a kind has, the
/// class check (read-only, production's switch, the typed name), each
/// request exactly, the access review, the confirmation's words and the
/// outcome said plainly. Every context here is fictional.
final class KubeWritesTests: XCTestCase {
    static func context(_ name: String, settings: KubeContextSettings = KubeContextSettings(), session: Bool = false) -> KubeContext {
        var context = KubeContext(
            name: name, cluster: name, server: "http://127.0.0.1:1", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: KubeClassifier.classify(context: name, cluster: name, set: settings.contextClass), settings: settings)
        context.sessionWrites = session
        return context
    }

    static let deployments = KubeResourceKind(
        group: "apps", version: "v1", resource: "deployments", kind: "Deployment", singular: "deployment", namespaced: true,
        verbs: ["create", "delete", "deletecollection", "get", "list", "patch", "update", "watch"], shortNames: ["deploy"], subresources: ["scale", "status"])
    static let configmaps = KubeResourceKind(
        group: "", version: "v1", resource: "configmaps", kind: "ConfigMap", singular: "configmap", namespaced: true,
        verbs: ["create", "delete", "get", "list", "patch", "update", "watch"], shortNames: ["cm"])

    static let statefulsets = KubeResourceKind(
        group: "apps", version: "v1", resource: "statefulsets", kind: "StatefulSet", singular: "statefulset", namespaced: true,
        verbs: ["create", "delete", "get", "list", "patch", "update", "watch"], shortNames: ["sts"], subresources: ["scale", "status"])
    static let cronjobs = KubeResourceKind(
        group: "batch", version: "v1", resource: "cronjobs", kind: "CronJob", singular: "cronjob", namespaced: true,
        verbs: ["create", "delete", "get", "list", "patch", "update", "watch"], shortNames: ["cj"], subresources: ["status"])
    static let nodes = KubeResourceKind(
        group: "", version: "v1", resource: "nodes", kind: "Node", singular: "node", namespaced: false,
        verbs: ["create", "delete", "get", "list", "patch", "update", "watch"], shortNames: ["no"], subresources: ["proxy", "status"])

    static func pod(_ name: String = "web-1", in context: String = "kind-fake") -> KubeObjectRef {
        KubeObjectRef(context: context, kind: .pods, namespace: "shop", name: name)
    }

    static func deployment(_ name: String = "web", in context: String = "kind-fake") -> KubeObjectRef {
        KubeObjectRef(context: context, kind: deployments, namespace: "shop", name: name)
    }

    // MARK: The class check

    func testWhichKindHasWhichVerb() {
        XCTAssertEqual(KubeWriteVerb.allCases.filter { KubeWriteCheck.offered($0, on: .pods) }, [.delete, .recreate, .forceDelete, .removeFinalizers, .evict, .resize])
        XCTAssertEqual(
            KubeWriteVerb.allCases.filter { KubeWriteCheck.offered($0, on: Self.deployments) }, [.delete, .removeFinalizers, .restart, .scale, .pause, .resume])
        XCTAssertEqual(
            KubeWriteVerb.allCases.filter { KubeWriteCheck.offered($0, on: Self.cronjobs) }, [.delete, .removeFinalizers, .trigger, .suspend, .unsuspend])
        XCTAssertEqual(KubeWriteVerb.allCases.filter { KubeWriteCheck.offered($0, on: Self.nodes) }, [.delete, .removeFinalizers, .cordon, .uncordon])
        XCTAssertEqual(KubeWriteVerb.allCases.filter { KubeWriteCheck.offered($0, on: .namespaces) }, [.delete, .removeFinalizers, .createNamespace])
        XCTAssertFalse(KubeWriteCheck.offered(.pause, on: Self.statefulsets), "kubectl rollout pause takes Deployments only")
        XCTAssertEqual(KubeWriteVerb.allCases.filter { KubeWriteCheck.offered($0, on: Self.configmaps) }, [.delete, .removeFinalizers])
        var readOnly = Self.configmaps
        readOnly.verbs = ["get", "list", "watch"]
        XCTAssertTrue(KubeWriteVerb.allCases.allSatisfy { !KubeWriteCheck.offered($0, on: readOnly) }, "only what discovery says it takes")
        XCTAssertEqual(KubeWriteCheck.access(.delete, on: .pods), KubeAccess(verb: "delete", resource: "pods"))
        XCTAssertEqual(KubeWriteCheck.access(.scale, on: Self.deployments), KubeAccess(verb: "patch", resource: "deployments.apps/scale"))
        XCTAssertEqual(KubeWriteCheck.access(.evict, on: .pods), KubeAccess(verb: "create", resource: "pods/eviction"))
        XCTAssertEqual(KubeWriteCheck.access(.restart, on: Self.deployments), KubeAccess(verb: "patch", resource: "deployments.apps"))
    }

    /// Rule 2: only a writable context — remote by its flag, local unless
    /// it says no, production only with its switch on — and nothing else.
    func testEveryVerbAgainstEveryClass() {
        let dev = Self.context("fake-dev")
        let kind = Self.context("kind-fake")
        let prod = Self.context("fake-prod")
        let devWritable = Self.context("fake-dev", settings: KubeContextSettings(writable: true))
        let kindReadOnly = Self.context("kind-fake", settings: KubeContextSettings(writable: false))
        let prodFlag = Self.context("fake-prod", settings: KubeContextSettings(writable: true))
        let prodOn = Self.context("fake-prod", session: true)
        for verb in KubeWriteVerb.allCases {
            let kindOfObject = [.pods, Self.deployments, Self.cronjobs, Self.nodes, .namespaces, KubeGitOpsTests.kustomizations, KubeGitOpsTests.applications].first {
                KubeWriteCheck.offered(verb, on: $0)
            }!
            XCTAssertEqual(
                KubeWriteCheck.rule(verb, for: dev, kind: kindOfObject).refused, "This context is read-only: Overterm changes nothing here (its writable setting).",
                "\(verb)")
            XCTAssertNotNil(KubeWriteCheck.rule(verb, for: kindReadOnly, kind: kindOfObject).refused, "\(verb): writable: false")
            XCTAssertEqual(
                KubeWriteCheck.rule(verb, for: prod, kind: kindOfObject).refused, "Production is read-only: turn on writes for this session on its card first.",
                "\(verb)")
            XCTAssertNotNil(KubeWriteCheck.rule(verb, for: prodFlag, kind: kindOfObject).refused, "\(verb): a setting never opens production")
            XCTAssertNil(KubeWriteCheck.rule(verb, for: kind, kind: kindOfObject).refused, "\(verb)")
            XCTAssertNil(KubeWriteCheck.rule(verb, for: devWritable, kind: kindOfObject).refused, "\(verb)")
            XCTAssertNil(KubeWriteCheck.rule(verb, for: prodOn, kind: kindOfObject).refused, "\(verb)")
            XCTAssertNotNil(KubeWriteCheck.rule(verb, for: kind, kind: kindOfObject).access, "\(verb): each write ships with its review")
        }
        XCTAssertNotNil(KubeWriteCheck.rule(.restart, for: kind, kind: .pods).refused, "a pod has no rollout")
        // A context never written to stays so: the session switch means nothing off production.
        XCTAssertFalse(Self.context("fake-dev", session: true).isWritable)
    }

    /// Rule 4: the typed name — on production a delete, a recreate, scaling
    /// to 0; force delete and finalizers on every class (Section 2.4), and
    /// a namespace's delete everywhere.
    func testTheTypedNameWhereRuleFourSays() {
        let kind = Self.context("kind-fake")
        let prod = Self.context("fake-prod", session: true)
        func typed(_ verb: KubeWriteVerb, _ context: KubeContext, _ of: KubeResourceKind, replicas: Int? = nil) -> Bool {
            KubeWriteCheck.rule(verb, for: context, kind: of, replicas: replicas).typedName
        }
        XCTAssertFalse(typed(.delete, kind, .pods))
        XCTAssertTrue(typed(.delete, prod, .pods))
        XCTAssertTrue(typed(.delete, kind, .namespaces), "a namespace on every class")
        XCTAssertFalse(typed(.recreate, kind, .pods))
        XCTAssertTrue(typed(.recreate, prod, .pods))
        XCTAssertTrue(typed(.forceDelete, kind, .pods))
        XCTAssertTrue(typed(.removeFinalizers, kind, Self.configmaps))
        XCTAssertFalse(typed(.evict, prod, .pods))
        XCTAssertFalse(typed(.restart, prod, Self.deployments))
        XCTAssertFalse(typed(.scale, prod, Self.deployments, replicas: 2))
        XCTAssertTrue(typed(.scale, prod, Self.deployments, replicas: 0))
        XCTAssertFalse(typed(.scale, kind, Self.deployments, replicas: 0))
        XCTAssertNotNil(KubeWriteCheck.rule(.forceDelete, for: kind, kind: .pods).warning)
        XCTAssertNotNil(KubeWriteCheck.rule(.removeFinalizers, for: kind, kind: .pods).warning)
    }

    // MARK: The requests

    func testEachRequestExactly() throws {
        let pod = Self.pod()
        let delete = KubeWrites.delete(pod)
        XCTAssertEqual(delete.method, .DELETE)
        XCTAssertEqual(delete.path, "/api/v1/namespaces/shop/pods/web-1")
        XCTAssertEqual(delete.contentType, "application/json")
        XCTAssertEqual(String(decoding: delete.body, as: UTF8.self), #"{"apiVersion":"v1","kind":"DeleteOptions","propagationPolicy":"Background"}"#)
        XCTAssertEqual(
            String(decoding: KubeWrites.delete(pod, gracePeriod: 0).body, as: UTF8.self),
            #"{"apiVersion":"v1","gracePeriodSeconds":0,"kind":"DeleteOptions","propagationPolicy":"Background"}"#)

        let finalizers = KubeWrites.removeFinalizers(pod, finalizers: ["example.com/guard"])
        XCTAssertEqual(finalizers.method, .PATCH)
        XCTAssertEqual(finalizers.path, "/api/v1/namespaces/shop/pods/web-1?fieldManager=overterm")
        XCTAssertEqual(finalizers.contentType, "application/json-patch+json")
        XCTAssertEqual(
            String(decoding: finalizers.body, as: UTF8.self),
            #"[{"op":"test","path":"\/metadata\/finalizers","value":["example.com\/guard"]},{"op":"remove","path":"\/metadata\/finalizers"}]"#)

        let evict = KubeWrites.evict(pod)
        XCTAssertEqual(evict.method, .POST)
        XCTAssertEqual(evict.path, "/api/v1/namespaces/shop/pods/web-1/eviction")
        XCTAssertEqual(
            String(decoding: evict.body, as: UTF8.self), #"{"apiVersion":"policy\/v1","kind":"Eviction","metadata":{"name":"web-1","namespace":"shop"}}"#)

        let at = Date(timeIntervalSince1970: 1_793_000_000)
        let restart = KubeWrites.restart(Self.deployment(), at: at)
        XCTAssertEqual(restart.method, .PATCH)
        XCTAssertEqual(restart.path, "/apis/apps/v1/namespaces/shop/deployments/web?fieldManager=overterm")
        XCTAssertEqual(restart.contentType, "application/strategic-merge-patch+json")
        XCTAssertEqual(
            String(decoding: restart.body, as: UTF8.self),
            #"{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io\/restartedAt":"2026-10-26T07:33:20Z"}}}}}"#)

        let scale = KubeWrites.scale(Self.deployment(), replicas: 3)
        XCTAssertEqual(scale.method, .PATCH)
        XCTAssertEqual(scale.path, "/apis/apps/v1/namespaces/shop/deployments/web/scale?fieldManager=overterm")
        XCTAssertEqual(scale.contentType, "application/merge-patch+json")
        XCTAssertEqual(String(decoding: scale.body, as: UTF8.self), #"{"spec":{"replicas":3}}"#)

        let review = KubeWrites.review(KubeAccess(verb: "patch", resource: "deployments.apps/scale"), namespace: "shop")
        XCTAssertEqual(review.method, .POST)
        XCTAssertEqual(review.path, "/apis/authorization.k8s.io/v1/selfsubjectaccessreviews")
        XCTAssertEqual(
            String(decoding: review.body, as: UTF8.self),
            #"{"apiVersion":"authorization.k8s.io\/v1","kind":"SelfSubjectAccessReview","spec":{"resourceAttributes":{"group":"apps","namespace":"shop","resource":"deployments","subresource":"scale","verb":"patch"}}}"#
        )
        // A name in a path can't make it another path.
        XCTAssertEqual(KubeWrites.delete(Self.pod("a/b")).path, "/api/v1/namespaces/shop/pods/a%2Fb")
    }

    func testTheAccessReviewsAnswer() {
        XCTAssertEqual(
            KubeAccessReview.attributes(KubeAccess(verb: "delete", resource: "pods"), namespace: nil), ["verb": "delete", "resource": "pods", "group": ""])
        XCTAssertEqual(
            KubeAccessReview.attributes(KubeAccess(verb: "create", resource: "pods/eviction"), namespace: "shop", name: "web-1"),
            ["verb": "create", "resource": "pods", "group": "", "subresource": "eviction", "namespace": "shop", "name": "web-1"])
        XCTAssertEqual(KubeAccessReview.parse(Data(#"{"status":{"allowed":true}}"#.utf8)), .yes)
        XCTAssertEqual(KubeAccessReview.parse(Data(#"{"status":{"allowed":false,"reason":"RBAC: no"}}"#.utf8)), .no("RBAC: no"))
        XCTAssertEqual(KubeAccessReview.parse(Data(#"{"status":{"allowed":false,"denied":true}}"#.utf8)), .no(nil))
        XCTAssertEqual(
            KubeAccessReview.parse(Data(#"{"status":{"allowed":false,"evaluationError":"webhook down"}}"#.utf8)), .no("evaluation error: webhook down"))
        XCTAssertEqual(KubeAccessReview.parse(Data("nope".utf8)), .failed("The access review's answer couldn't be read."))
        XCTAssertEqual(
            KubeAccessState.answered(.no("RBAC: no")).unavailable(KubeAccess(verb: "delete", resource: "pods"), namespace: "shop", review: true),
            "The cluster's access review says you may not delete pods in shop: RBAC: no")
        XCTAssertEqual(
            KubeAccessState.checking.unavailable(KubeAccess(verb: "delete", resource: "nodes"), namespace: "", review: true),
            "Checking whether you may delete nodes cluster-wide…")
    }

    // MARK: What is said

    func testTheKubectlEachWriteEquals() {
        XCTAssertEqual(KubeWrites.kubectl(.delete, Self.pod()), "kubectl delete po web-1 --context kind-fake -n shop")
        XCTAssertEqual(KubeWrites.kubectl(.forceDelete, Self.pod()), "kubectl delete po web-1 --grace-period=0 --force --context kind-fake -n shop")
        XCTAssertEqual(
            KubeWrites.kubectl(.removeFinalizers, Self.pod()),
            #"kubectl patch po web-1 --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]' --context kind-fake -n shop"#)
        XCTAssertNil(KubeWrites.kubectl(.evict, Self.pod()))
        XCTAssertEqual(KubeWrites.kubectl(.restart, Self.deployment()), "kubectl rollout restart deploy/web --context kind-fake -n shop")
        XCTAssertEqual(KubeWrites.kubectl(.scale, Self.deployment(), replicas: 3), "kubectl scale deploy/web --replicas=3 --context kind-fake -n shop")
        XCTAssertEqual(
            KubeWrites.kubectl(.delete, KubeObjectRef(context: "kind-fake", kind: .namespaces, namespace: nil, name: "shop")),
            "kubectl delete ns shop --context kind-fake", "a cluster-wide object has no -n")
    }

    func testTheConfirmationNamesTheContextAndNamespace() {
        let prod = Self.context("fake-prod", session: true)
        let ref = Self.pod("web-1", in: "fake-prod")
        let rule = KubeWriteCheck.rule(.delete, for: prod, kind: .pods)
        let confirmation = KubeWriteConfirmation.make(.delete, ref, context: prod, rule: rule)
        XCTAssertEqual(confirmation.title, "Delete pod shop/web-1?")
        XCTAssertEqual(confirmation.scope, "PRODUCTION · fake-prod · namespace shop")
        XCTAssertTrue(confirmation.detail.contains("Equals: kubectl delete po web-1 --context fake-prod -n shop"), confirmation.detail)
        XCTAssertTrue(confirmation.detail.hasSuffix("Type web-1 to confirm."))
        XCTAssertEqual(confirmation.typedName, "web-1")
        XCTAssertTrue(confirmation.production)
        XCTAssertFalse(confirmation.accepts(""))
        XCTAssertFalse(confirmation.accepts("web-2"))
        XCTAssertFalse(confirmation.accepts("WEB-1"), "names are case-sensitive")
        XCTAssertTrue(confirmation.accepts(" web-1\n"))

        let kind = Self.context("kind-fake")
        let scale = KubeWriteConfirmation.make(
            .scale, Self.deployment(), context: kind, rule: KubeWriteCheck.rule(.scale, for: kind, kind: Self.deployments, replicas: 0), from: 2, to: 0)
        XCTAssertEqual(scale.title, "Scale deployment shop/web from 2 to 0 replicas?")
        XCTAssertEqual(scale.scope, "kind-fake · namespace shop")
        XCTAssertTrue(scale.detail.hasPrefix("Every one of its pods stops."), scale.detail)
        XCTAssertNil(scale.typedName)
        XCTAssertTrue(scale.accepts(""))

        let recreate = KubeWriteConfirmation.make(
            .recreate, Self.pod(), context: kind, rule: KubeWriteCheck.rule(.recreate, for: kind, kind: .pods),
            meta: KubeObjectMeta(controller: "ReplicaSet web-7d9f"))
        XCTAssertTrue(recreate.detail.contains("Its ReplicaSet web-7d9f makes a new pod"), recreate.detail)
        let lone = KubeWriteConfirmation.make(.recreate, Self.pod(), context: kind, rule: KubeWriteCheck.rule(.recreate, for: kind, kind: .pods), meta: KubeObjectMeta())
        XCTAssertTrue(lone.detail.contains("nothing makes it again"), lone.detail)
        let evict = KubeWriteConfirmation.make(.evict, Self.pod(), context: kind, rule: KubeWriteCheck.rule(.evict, for: kind, kind: .pods))
        XCTAssertTrue(evict.detail.contains("no kubectl command evicts one pod"))
        let force = KubeWriteConfirmation.make(.forceDelete, Self.pod(), context: kind, rule: KubeWriteCheck.rule(.forceDelete, for: kind, kind: .pods))
        XCTAssertTrue(force.detail.contains("⚠︎ Force deleting doesn't wait"), force.detail)
        XCTAssertEqual(force.typedName, "web-1")
    }

    func testTheOutcomeIsSaidPlainly() {
        let pod = Self.pod()
        XCTAssertEqual(KubeWriteOutcome.done(.delete, pod), "Deleted pod shop/web-1 in kind-fake.")
        XCTAssertEqual(KubeWriteOutcome.done(.scale, Self.deployment(), from: 1, replicas: 3), "Scaled deployment shop/web from 1 to 3 in kind-fake.")
        func said(_ status: Int, _ message: String, _ verb: KubeWriteVerb = .delete) -> String {
            KubeWriteOutcome.failed(verb, pod, KubeAPIError(status: status, reason: nil, message: message))
        }
        XCTAssertEqual(said(403, "pods \"web-1\" is forbidden"), "kind-fake refused it — you may not delete pod shop/web-1: pods \"web-1\" is forbidden")
        XCTAssertEqual(said(404, "not found"), "pod shop/web-1 isn't there any more: nothing to delete.")
        XCTAssertEqual(said(409, "the object has been modified"), "pod shop/web-1 changed meanwhile: the object has been modified — look again and retry.")
        XCTAssertEqual(said(422, "spec.replicas: Invalid value", .scale), "The cluster wouldn't take it: spec.replicas: Invalid value")
        XCTAssertEqual(
            said(429, "Cannot evict pod as it would violate the pod's disruption budget.", .evict),
            "A PodDisruptionBudget doesn't allow evicting pod shop/web-1 now: Cannot evict pod as it would violate the pod's disruption budget. — try later, or delete it."
        )
        XCTAssertEqual(KubeWriteOutcome.failed(.delete, pod, KubeWriteRefused(reason: "read-only")), "read-only")
        // A Status's causes say what its message leaves out.
        let status = KubeAPIError.status([
            "code": 429, "message": "Cannot evict pod.", "details": ["causes": [["reason": "DisruptionBudget", "message": "web-pdb needs 1 healthy pods"]]],
        ])
        XCTAssertEqual(status.message, "Cannot evict pod. web-pdb needs 1 healthy pods")
    }

    // MARK: Production's switch

    func testProductionsSwitchHoldsOnlyForTheSameCluster() {
        var writes = KubeProductionWrites()
        let prod = Self.context("fake-prod")
        writes.turnOn(prod)
        writes.turnOn(Self.context("kind-fake"))
        XCTAssertTrue(writes.isOn("fake-prod"))
        XCTAssertFalse(writes.isOn("kind-fake"), "only production has a switch")
        var list = KubeContextList(contexts: [prod, Self.context("fake-dev")])
        XCTAssertEqual(writes.apply(to: &list), [])
        XCTAssertTrue(list.context(named: "fake-prod")!.isWritable)
        XCTAssertFalse(list.context(named: "fake-dev")!.isWritable)
        // The kubeconfig read again points the name at another cluster: off.
        let elsewhere = KubeContext(
            name: "fake-prod", cluster: "fake-prod", server: "http://127.0.0.1:2", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: .production, settings: KubeContextSettings())
        var moved = KubeContextList(contexts: [elsewhere])
        XCTAssertEqual(writes.apply(to: &moved), ["fake-prod"])
        XCTAssertFalse(moved.context(named: "fake-prod")!.isWritable)
        XCTAssertFalse(writes.isOn("fake-prod"))
    }
}

/// The client's writes against the fake API server: each lands on its
/// objects (and its watches), recorded with its method, path, body and
/// content type; a read-only connection sends nothing.
final class KubeWriteClientTests: XCTestCase {
    private var api: FakeKubeAPI!
    private var socket: String!

    override func setUpWithError() throws {
        socket = "/tmp/otkw-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        api.addPod("web-1", namespace: "shop")
        api.addPod("web-2", namespace: "shop")
        api.add(
            "deployments.apps", "web", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1],
            fields: ["spec": ["replicas": 1, "template": ["metadata": ["labels": ["app": "web"]]]], "status": ["replicas": 1]])
    }

    override func tearDown() {
        api?.stop()
    }

    private func client(writable: Bool) -> KubeClient {
        KubeClient(KubeSocketConnection(socket: socket, context: "kind-fake", writable: writable))
    }

    private func written() -> [FakeKubeAPI.Request] { api.writes.filter { !$0.isAccessReview } }

    func testAReadOnlyConnectionSendsNothing() async throws {
        let client = client(writable: false)
        do {
            try await client.write(KubeWrites.delete(KubeWritesTests.pod()))
            XCTFail("refused")
        } catch {
            XCTAssertTrue(error is KubeWriteRefused)
        }
        let review = await client.review(KubeAccess(verb: "delete", resource: "pods"), namespace: "shop")
        XCTAssertEqual(review, .failed("The context is read-only: its socket takes no access review."))
        XCTAssertEqual(api.writes, [], "nothing but GETs reached the server")
        XCTAssertNotNil(api.pod("web-1", namespace: "shop"))
    }

    func testTheAccessReviewIsAskedOfTheServer() async throws {
        let client = client(writable: true)
        api.deniedAccess = ["patch deployments.apps/scale"]
        let allowed = await client.review(KubeAccess(verb: "delete", resource: "pods"), namespace: "shop")
        XCTAssertEqual(allowed, .yes)
        let denied = await client.review(KubeAccess(verb: "patch", resource: "deployments.apps/scale"), namespace: "shop")
        XCTAssertEqual(denied, .no("RBAC: patch deployments.apps/scale is not allowed"))
        XCTAssertEqual(api.writes.map(\.description), Array(repeating: "POST /apis/authorization.k8s.io/v1/selfsubjectaccessreviews", count: 2))
        XCTAssertEqual(written(), [], "a review changes nothing")
    }

    func testEachWriteLandsOnTheServer() async throws {
        let client = client(writable: true)
        // Delete.
        try await client.write(KubeWrites.delete(KubeWritesTests.pod("web-1")))
        XCTAssertNil(api.pod("web-1", namespace: "shop"))
        let delete = try XCTUnwrap(written().last)
        XCTAssertEqual(delete.method, "DELETE")
        XCTAssertEqual(delete.path, "/api/v1/namespaces/shop/pods/web-1")
        XCTAssertEqual(delete.contentType, "application/json")
        XCTAssertEqual((delete.json as? [String: Any])?["propagationPolicy"] as? String, "Background")

        // Scale: the subresource read, then patched.
        let deployment = KubeWritesTests.deployment()
        let before = try await client.replicas(deployment)
        XCTAssertEqual(before, 1)
        try await client.write(KubeWrites.scale(deployment, replicas: 3))
        let after = try await client.replicas(deployment)
        XCTAssertEqual(after, 3)
        let scale = try XCTUnwrap(written().last)
        XCTAssertEqual(scale.method, "PATCH")
        XCTAssertEqual(scale.path, "/apis/apps/v1/namespaces/shop/deployments/web/scale")
        XCTAssertEqual(scale.query["fieldManager"], "overterm")
        XCTAssertEqual(scale.contentType, "application/merge-patch+json")
        let rows = try await client.list(KubeWritesTests.deployments, in: .namespace("shop"))
        XCTAssertEqual(rows.rows.first?.cells.first { $0.text.contains("/") }?.text, "3/3", "its row says so")

        // Restart: the template's annotation.
        let at = Date(timeIntervalSince1970: 1_793_000_000)
        try await client.write(KubeWrites.restart(deployment, at: at))
        let object = try await client.object(KubeWritesTests.deployments, namespace: "shop", name: "web").json
        let template = (object["spec"] as? [String: Any])?["template"] as? [String: Any]
        XCTAssertEqual(((template?["metadata"] as? [String: Any])?["annotations"] as? [String: String])?[KubeWrites.restartedAt], KubeWrites.stamp(at))
        XCTAssertEqual(((template?["metadata"] as? [String: Any])?["labels"] as? [String: String])?["app"], "web", "a merge keeps the rest")
        XCTAssertEqual(written().last?.contentType, "application/strategic-merge-patch+json")

        // Evict: refused while a PDB allows none, the reason said; then done.
        api.evictionBlock = "The disruption budget web-pdb needs 1 healthy pods and has 1 currently"
        do {
            try await client.write(KubeWrites.evict(KubeWritesTests.pod("web-2")))
            XCTFail("the PDB says no")
        } catch let error as KubeAPIError {
            XCTAssertEqual(error.status, 429)
            XCTAssertTrue(error.message.contains("web-pdb needs 1 healthy pods"), error.message)
        }
        XCTAssertNotNil(api.pod("web-2", namespace: "shop"), "not retried: a PDB's 429 isn't the server being busy")
        api.evictionBlock = nil
        try await client.write(KubeWrites.evict(KubeWritesTests.pod("web-2")))
        XCTAssertNil(api.pod("web-2", namespace: "shop"))
        XCTAssertEqual(written().last?.path, "/api/v1/namespaces/shop/pods/web-2/eviction")
        XCTAssertEqual(written().filter { $0.path.hasSuffix("/eviction") }.count, 2)
    }

    /// An object with finalizers is only marked deleting; removing them —
    /// a JSON patch testing them first — lets it go.
    func testFinalizersHoldADeleteUntilRemoved() async throws {
        let client = client(writable: true)
        api.add("configmaps", "guarded", namespace: "shop", fields: ["metadata": ["finalizers": ["example.com/guard"]]])
        let ref = KubeObjectRef(context: "kind-fake", kind: KubeWritesTests.configmaps, namespace: "shop", name: "guarded")
        try await client.write(KubeWrites.delete(ref))
        var meta = try await client.metadata(ref)
        XCTAssertEqual(meta, KubeObjectMeta(finalizers: ["example.com/guard"], deleting: true))
        XCTAssertTrue(api.requests.last?.accept.contains("as=PartialObjectMetadata") == true, "metadata only")
        // One added meanwhile: the test fails, nothing removed.
        do {
            try await client.write(KubeWrites.removeFinalizers(ref, finalizers: ["example.com/other"]))
            XCTFail("the test op fails")
        } catch let error as KubeAPIError {
            XCTAssertEqual(error.status, 422)
        }
        meta = try await client.metadata(ref)
        XCTAssertEqual(meta.finalizers, ["example.com/guard"])
        try await client.write(KubeWrites.removeFinalizers(ref, finalizers: ["example.com/guard"]))
        XCTAssertEqual(api.names("configmaps"), [], "gone once its finalizers are")
        XCTAssertEqual(written().last?.contentType, "application/json-patch+json")
    }

    func testTheAPIsErrorsComeBackAsThemselves() async throws {
        let client = client(writable: true)
        api.failNextWrite(403, reason: "Forbidden", message: "pods \"web-1\" is forbidden: User \"fake\" cannot delete resource \"pods\"")
        do {
            try await client.write(KubeWrites.delete(KubeWritesTests.pod("web-1")))
            XCTFail("forbidden")
        } catch let error as KubeAPIError {
            XCTAssertEqual(error.status, 403)
            XCTAssertEqual(
                KubeWriteOutcome.failed(.delete, KubeWritesTests.pod("web-1"), error),
                "kind-fake refused it — you may not delete pod shop/web-1: pods \"web-1\" is forbidden: User \"fake\" cannot delete resource \"pods\"")
        }
        do {
            try await client.write(KubeWrites.delete(KubeWritesTests.pod("nope")))
            XCTFail("not there")
        } catch let error as KubeAPIError {
            XCTAssertEqual(error.status, 404)
        }
        XCTAssertNotNil(api.pod("web-1", namespace: "shop"))
    }
}

/// G0b (docs/design/kubernetes/gitops.md, 1.1 rows 6–7): deleting a GitOps
/// object says what goes with it, and its name is typed on every class.
extension KubeWritesTests {
    static let applicationSets = KubeGitOpsTests.crd("argoproj.io", "applicationsets", "ApplicationSet", version: "v1alpha1")

    static func data(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    static func gitOps(_ kind: KubeResourceKind, _ object: [String: Any], name: String = "acme-shop", namespace: String = "argocd") throws -> KubeGitOpsDelete {
        let tool = try XCTUnwrap(KubeGitOpsDelete.tool(kind))
        return try KubeGitOpsDelete.read(data(object), tool: tool, ref: KubeObjectRef(context: "fake-dev", kind: kind, namespace: namespace, name: name))
    }

    static func resources(_ count: Int, namespaces: [String]) -> [[String: Any]] {
        (0..<count).map { ["kind": "ConfigMap", "version": "v1", "name": "c\($0)", "namespace": namespaces[$0 % namespaces.count], "status": "Synced"] }
    }

    func testTheNameIsTypedOnEveryClassForTheThreeKinds() {
        let dev = Self.context("fake-dev", settings: KubeContextSettings(writable: true))
        let kind = Self.context("kind-fake")
        for cascading in [KubeGitOpsTests.applications, KubeGitOpsTests.kustomizations, KubeGitOpsTests.helmReleases] {
            XCTAssertTrue(KubeWriteCheck.rule(.delete, for: dev, kind: cascading).typedName, cascading.fullName)
            XCTAssertTrue(KubeWriteCheck.rule(.delete, for: kind, kind: cascading).typedName, cascading.fullName)
            XCTAssertNotNil(KubeWriteCheck.rule(.delete, for: kind, kind: cascading).warning, "never no sentence: \(cascading.fullName)")
        }
        XCTAssertFalse(KubeWriteCheck.rule(.delete, for: dev, kind: Self.applicationSets).typedName, "an ApplicationSet as any custom resource")
        XCTAssertTrue(KubeWriteCheck.rule(.delete, for: dev, kind: Self.applicationSets).warning?.contains("generated Applications") == true)
        XCTAssertFalse(KubeWriteCheck.rule(.delete, for: dev, kind: KubeGitOpsTests.gitRepositories).typedName, "a source deletes nothing it feeds")
        XCTAssertNil(KubeWriteCheck.rule(.delete, for: dev, kind: KubeGitOpsTests.gitRepositories).warning)
        XCTAssertFalse(KubeWriteCheck.rule(.delete, for: dev, kind: Self.configmaps).typedName)
        // The GitOps verbs that only ask their controller are never typed.
        for verb in [KubeWriteVerb.refresh] { XCTAssertFalse(KubeWriteCheck.rule(verb, for: dev, kind: KubeGitOpsTests.applications).typedName) }
        for verb in [KubeWriteVerb.reconcile, .fluxSuspend, .fluxResume] {
            XCTAssertFalse(KubeWriteCheck.rule(verb, for: dev, kind: KubeGitOpsTests.kustomizations).typedName, "\(verb)")
        }
    }

    func testAnApplicationsFinalizerByPrefixAndItsCount() throws {
        let background = try Self.gitOps(
            KubeGitOpsTests.applications,
            [
                "metadata": ["finalizers": ["resources-finalizer.argocd.argoproj.io/background"]],
                "spec": ["destination": ["server": "https://kubernetes.default.svc", "namespace": "shop"]],
                "status": ["resources": Self.resources(42, namespaces: ["shop", "payments", "web"])],
            ])
        XCTAssertEqual(background.finalizer, "resources-finalizer.argocd.argoproj.io/background")
        XCTAssertEqual(
            background.said,
            "Argo CD deletes the 42 resources it manages with it, across 3 namespaces (its resources-finalizer.argocd.argoproj.io/background finalizer).")
        let plain = try Self.gitOps(
            KubeGitOpsTests.applications,
            ["metadata": ["finalizers": ["resources-finalizer.argocd.argoproj.io"]], "status": ["resources": Self.resources(1, namespaces: ["shop"])]])
        XCTAssertEqual(plain.said, "Argo CD deletes the 1 resource it manages with it, in namespace shop (its resources-finalizer.argocd.argoproj.io finalizer).")
        let foreground = try Self.gitOps(KubeGitOpsTests.applications, ["metadata": ["finalizers": ["x", "resources-finalizer.argocd.argoproj.io/foreground"]]])
        XCTAssertEqual(foreground.finalizer, "resources-finalizer.argocd.argoproj.io/foreground")
        XCTAssertTrue(foreground.said.contains("it lists none now"), foreground.said)
        let lookalike = try Self.gitOps(
            KubeGitOpsTests.applications,
            ["metadata": ["finalizers": ["resources-finalizer.argocd.argoproj.io-x"]], "status": ["resources": Self.resources(3, namespaces: ["shop"])]])
        XCTAssertNil(lookalike.finalizer)
        XCTAssertEqual(
            lookalike.said,
            "It has no resources-finalizer.argocd.argoproj.io finalizer: the 3 resources it manages stay, no longer managed by Argo CD.")
        let remote = try Self.gitOps(
            KubeGitOpsTests.applications,
            [
                "metadata": ["finalizers": ["resources-finalizer.argocd.argoproj.io"]],
                "spec": ["destination": ["name": "acme-edge"]], "status": ["resources": Self.resources(2, namespaces: ["shop"])],
            ])
        XCTAssertTrue(remote.said.contains("— in the other cluster it deploys to"), remote.said)
    }

    func testAKustomizationsPruneAndDeletionPolicyAndAHelmRelease() throws {
        let entries: [[String: Any]] = [["id": "shop_web_apps_Deployment", "v": "v1"], ["id": "shop_web__Service", "v": "v1"], ["id": "_shop__Namespace", "v": "v1"]]
        let pruning = try Self.gitOps(KubeGitOpsTests.kustomizations, ["spec": ["prune": true], "status": ["inventory": ["entries": entries]]])
        XCTAssertEqual(pruning.said, "Flux deletes the 3 objects in its inventory with it, in namespace shop (spec.prune).")
        let off = try Self.gitOps(KubeGitOpsTests.kustomizations, ["spec": ["prune": false], "status": ["inventory": ["entries": entries]]])
        XCTAssertEqual(off.said, "spec.prune is off: the 3 objects it applied stay.")
        XCTAssertFalse(off.deletesManaged)
        let orphan = try Self.gitOps(KubeGitOpsTests.kustomizations, ["spec": ["prune": true, "deletionPolicy": "Orphan"]])
        XCTAssertEqual(orphan.said, "spec.deletionPolicy Orphan: what it applied stays.")
        let delete = try Self.gitOps(KubeGitOpsTests.kustomizations, ["spec": ["prune": false, "deletionPolicy": "Delete"]])
        XCTAssertEqual(delete.said, "Flux deletes whatever it applied with it (spec.deletionPolicy Delete); its inventory lists none now.")
        // WaitForTermination deletes the whole inventory whatever prune says, and waits for it.
        let waits = try Self.gitOps(KubeGitOpsTests.kustomizations, ["spec": ["prune": false, "deletionPolicy": "WaitForTermination"], "status": ["inventory": ["entries": entries]]])
        XCTAssertEqual(waits.said, "Flux deletes the 3 objects in its inventory with it, in namespace shop (spec.deletionPolicy WaitForTermination).")
        XCTAssertTrue(waits.deletesManaged)
        // Suspended, its controller skips the cascade.
        let suspended = try Self.gitOps(KubeGitOpsTests.kustomizations, ["spec": ["prune": true, "suspend": true], "status": ["inventory": ["entries": entries]]])
        XCTAssertEqual(suspended.said, "It is suspended (spec.suspend): Flux removes it without deleting what it applied — the 3 objects in its inventory stay, unless it is resumed first.")
        XCTAssertFalse(suspended.deletesManaged)
        let held = try Self.gitOps(KubeGitOpsTests.helmReleases, ["spec": ["suspend": true]])
        XCTAssertEqual(held.said, "It is suspended (spec.suspend): Flux removes it without uninstalling its Helm release, unless it is resumed first.")
        XCTAssertFalse(held.deletesManaged)
        XCTAssertFalse(try Self.gitOps(KubeGitOpsTests.applications, ["spec": ["suspend": true]]).suspended, "Argo CD has no suspend")
        let release = try Self.gitOps(KubeGitOpsTests.helmReleases, ["spec": ["values": ["replicas": 3]]])
        XCTAssertEqual(release.said, "Flux uninstalls its Helm release with it: everything the chart made goes.")
        let set = try Self.gitOps(Self.applicationSets, ["spec": ["syncPolicy": ["preserveResourcesOnDeletion": true]]])
        XCTAssertTrue(set.said.contains("preserveResourcesOnDeletion keeps what they deployed"), set.said)
    }

    func testAFailedReadGivesTheWorstCase() {
        let app = KubeGitOpsDelete.unread(.application, "applications.argoproj.io \"acme-shop\" is forbidden")
        XCTAssertEqual(app.said, "Couldn't read it (applications.argoproj.io \"acme-shop\" is forbidden): Argo CD may delete everything it manages with it.")
        XCTAssertTrue(app.deletesManaged)
        XCTAssertTrue(KubeGitOpsDelete.unread(.kustomization, "timeout").said.contains("Flux may delete everything it applied with it"))
        // A rule made without the read (the menu's) still warns.
        let kind = Self.context("kind-fake")
        XCTAssertEqual(
            KubeWriteCheck.rule(.delete, for: kind, kind: KubeGitOpsTests.applications).warning,
            "It wasn't read: Argo CD may delete everything it manages with it.")
    }

    func testAChildObjectsDeleteSaysItWillBeRecreated() throws {
        let child = try Self.gitOps(
            KubeGitOpsTests.kustomizations,
            [
                "metadata": ["labels": [KubeGitOpsOwner.kustomizeName: "flux-system", KubeGitOpsOwner.kustomizeNamespace: "flux-system"]],
                "spec": ["prune": true],
            ], name: "acme-apps", namespace: "flux-system")
        XCTAssertTrue(child.said.hasSuffix(" Managed by Kustomization flux-system/flux-system: it will be recreated."), child.said)
        // The bootstrap Kustomization applies itself: nothing makes it again.
        let root = try Self.gitOps(
            KubeGitOpsTests.kustomizations,
            [
                "metadata": ["labels": [KubeGitOpsOwner.kustomizeName: "flux-system", KubeGitOpsOwner.kustomizeNamespace: "flux-system"]],
                "spec": ["prune": true],
            ], name: "flux-system", namespace: "flux-system")
        XCTAssertFalse(root.said.contains("recreated"), root.said)
        let generated = try Self.gitOps(
            KubeGitOpsTests.applications, ["metadata": ["ownerReferences": [["apiVersion": "argoproj.io/v1alpha1", "kind": "ApplicationSet", "name": "acme-set"]]]])
        XCTAssertTrue(generated.said.hasSuffix(" Managed by ApplicationSet argocd/acme-set: it will be recreated."), generated.said)
        let appOfApps = try Self.gitOps(
            KubeGitOpsTests.applications, ["metadata": ["annotations": [KubeGitOpsOwner.trackingAnnotation: "acme-root:argoproj.io/Application:argocd/acme-shop"]]])
        XCTAssertTrue(appOfApps.said.hasSuffix(" Managed by Application acme-root: it will be recreated."), appOfApps.said)
        let probably = try Self.gitOps(KubeGitOpsTests.applications, ["metadata": ["labels": [KubeGitOpsOwner.appInstanceLabel: "acme-root"]]])
        XCTAssertTrue(probably.said.hasSuffix(" Probably Argo CD Application acme-root manages it: it may be recreated."), probably.said)
    }

    func testTheConfirmationOfAGitOpsDeleteNamesWhatGoesAndAsksTheName() throws {
        let dev = Self.context("fake-dev", settings: KubeContextSettings(writable: true))
        let facts = try Self.gitOps(
            KubeGitOpsTests.applications,
            ["metadata": ["finalizers": ["resources-finalizer.argocd.argoproj.io"]], "status": ["resources": Self.resources(42, namespaces: ["shop"])]])
        let ref = KubeObjectRef(context: "fake-dev", kind: KubeGitOpsTests.applications, namespace: "argocd", name: "acme-shop")
        let rule = KubeWriteCheck.rule(.delete, for: dev, kind: ref.kind, gitOps: facts)
        let confirmation = KubeWriteConfirmation.make(.delete, ref, context: dev, rule: rule)
        XCTAssertEqual(confirmation.typedName, "acme-shop")
        XCTAssertEqual(confirmation.scope, "fake-dev · namespace argocd")
        XCTAssertTrue(confirmation.detail.contains("⚠︎ Argo CD deletes the 42 resources it manages with it"), confirmation.detail)
        XCTAssertTrue(confirmation.detail.hasSuffix("Type acme-shop to confirm."), confirmation.detail)
    }

    /// Values, parameters, manifests and annotations are never decoded:
    /// nothing of them reaches the facts or their sentence.
    func testNoValueReachesTheFacts() throws {
        let sentinel = "s3cr3t-sentinel"
        let facts = try Self.gitOps(
            KubeGitOpsTests.applications,
            [
                "metadata": [
                    "finalizers": ["resources-finalizer.argocd.argoproj.io"],
                    "annotations": ["kubectl.kubernetes.io/last-applied-configuration": sentinel],
                    "labels": ["acme/token": sentinel],
                ],
                "spec": [
                    "source": [
                        "repoURL": "https://user:\(sentinel)@git.acme.example/shop.git",
                        "helm": ["values": sentinel, "valuesObject": ["k": sentinel], "parameters": [["name": "p", "value": sentinel]]],
                    ]
                ],
                "status": [
                    "resources": Self.resources(2, namespaces: ["shop"]), "sync": ["comparedTo": ["source": ["helm": ["values": sentinel]]]],
                    "operationState": ["operation": ["sync": ["manifests": [sentinel]]], "message": "kind: Secret\ndata:\n  k: \(sentinel)"],
                ],
            ])
        var dumped = ""
        dump(facts, to: &dumped)
        XCTAssertFalse(dumped.contains(sentinel), dumped)
        XCTAssertFalse(facts.said.contains(sentinel))
    }

    /// Discovery not known yet: the worst case, never no sentence.
    func testDeletingANamespaceWithoutDiscoverySaysTheWorst() async {
        let client = KubeClient(KubeSocketConnection(socket: "/tmp/otk-none-\(UInt32.random(in: 0...UInt32.max)).sock", context: "fake-dev"))
        let held = await client.gitOpsHeld(in: "argocd", discovery: nil)
        XCTAssertEqual(held?.uncounted, true)
        let warning = KubeWriteCheck.rule(.delete, for: Self.context("kind-fake"), kind: .namespaces, held: held).warning ?? ""
        XCTAssertEqual(
            warning,
            "Everything in the namespace is deleted with it. Its GitOps objects weren't counted: any Applications, Kustomizations or HelmReleases in it may delete what they manage.")
    }

    /// A kind whose read failed part way is unread, said once: no partial count beside it.
    func testAKindReadPartWayIsUnreadNotCounted() {
        var held = KubeNamespaceGitOps()
        var kustomizations = KubeNamespaceGitOps()
        kustomizations.add([KubeGitOpsDelete(tool: .kustomization, prune: true, managed: 4, namespaces: ["shop"])], tool: .kustomization)
        held.merge(kustomizations)
        // Applications: a page read, the next too large — never merged.
        held.unread.append(.application)
        XCTAssertEqual(
            held.said,
            "And the pruning Kustomization in it deletes what it manages: 4 objects in namespace shop. Its Applications couldn't be read: they may delete everything they manage.")
        XCTAssertLessThanOrEqual(KubeNamespaceGitOps.applicationPageLimit, 20)
    }

    func testDeletingANamespaceCountsWhatItsGitOpsObjectsTake() {
        var held = KubeNamespaceGitOps()
        var apps: [KubeGitOpsDelete] = []
        for index in 0..<31 {
            var app = KubeGitOpsDelete(tool: .application)
            app.finalizer = KubeGitOpsDelete.argoFinalizer
            app.managed = index == 0 ? 64 : 38
            app.namespaces = ["ns\(index % 9)"]
            apps.append(app)
        }
        // Without the finalizer: counted, not cascading.
        apps.append(KubeGitOpsDelete(tool: .application, managed: 500, namespaces: ["elsewhere"]))
        held.add(apps, tool: .application)
        XCTAssertEqual(held.parts.first?.count, 32)
        XCTAssertEqual(
            held.said, "And the 31 Applications in it with Argo CD's resources finalizer delete what they manage: 1,204 objects across 9 namespaces.")
        held.add([KubeGitOpsDelete(tool: .helmRelease), KubeGitOpsDelete(tool: .helmRelease)], tool: .helmRelease)
        held.unread.append(.kustomization)
        XCTAssertTrue(held.said?.contains("Its 2 HelmReleases uninstall their releases.") == true, held.said ?? "")
        XCTAssertTrue(held.said?.contains("Its Kustomizations couldn't be read: they may delete everything they applied.") == true, held.said ?? "")
        held.more(.application, count: 700)
        XCTAssertTrue(held.said?.hasPrefix("And at least 31 Applications") == true, held.said ?? "")

        let kind = Self.context("kind-fake")
        let warning = KubeWriteCheck.rule(.delete, for: kind, kind: .namespaces, held: held).warning ?? ""
        XCTAssertTrue(warning.hasPrefix("Everything in the namespace is deleted with it. And at least 31 Applications"), warning)
        XCTAssertEqual(KubeWriteCheck.rule(.delete, for: kind, kind: .namespaces).warning, "Everything in the namespace is deleted with it.")
        XCTAssertNil(KubeNamespaceGitOps().said, "none held, nothing added")
        // A suspended HelmRelease and a suspended pruning Kustomization take nothing.
        var quiet = KubeNamespaceGitOps()
        quiet.add([KubeGitOpsDelete(tool: .helmRelease, suspended: true)], tool: .helmRelease)
        quiet.add([KubeGitOpsDelete(tool: .kustomization, prune: true, suspended: true, managed: 9)], tool: .kustomization)
        XCTAssertNil(quiet.said, quiet.said ?? "")
        XCTAssertEqual(KubeGitOpsDelete.grouped(1_000_000), "1,000,000")
        XCTAssertEqual(KubeGitOpsDelete.grouped(999), "999")
    }
}
