import Foundation
import NIOHTTP1
import XCTest

@testable import Overterm

/// Stage 2a's other verbs, pure: rollout pause and resume, a CronJob
/// triggered, suspended and resumed, a node cordoned and uncordoned, a
/// namespace made — each request exactly, the kubectl it equals, the
/// states read from an object or a row, a namespace's name and what a
/// namespace's delete warns of. Every context here is fictional.
final class KubeWriteVerbsTests: XCTestCase {
    private static func cronJob(_ name: String = "nightly") -> KubeObjectRef {
        KubeObjectRef(context: "kind-fake", kind: KubeWritesTests.cronjobs, namespace: "shop", name: name)
    }

    private static func node(_ name: String = "fake-node-1") -> KubeObjectRef {
        KubeObjectRef(context: "kind-fake", kind: KubeWritesTests.nodes, namespace: "shop", name: name)
    }

    private static func body(_ request: KubeWriteRequest) -> String { String(decoding: request.body, as: UTF8.self) }

    func testEachRequestExactly() throws {
        let deployment = KubeWritesTests.deployment()
        let pause = KubeWrites.toggle(deployment, .paused, on: true)
        XCTAssertEqual(pause.method, .PATCH)
        XCTAssertEqual(pause.path, "/apis/apps/v1/namespaces/shop/deployments/web?fieldManager=overterm")
        XCTAssertEqual(pause.contentType, "application/strategic-merge-patch+json")
        XCTAssertEqual(Self.body(pause), #"{"spec":{"paused":true}}"#)
        XCTAssertEqual(Self.body(KubeWrites.toggle(deployment, .paused, on: false)), #"{"spec":{"paused":null}}"#, "kubectl's patch: the field taken away")

        let suspend = KubeWrites.toggle(Self.cronJob(), .suspended, on: true)
        XCTAssertEqual(suspend.path, "/apis/batch/v1/namespaces/shop/cronjobs/nightly?fieldManager=overterm")
        XCTAssertEqual(suspend.contentType, "application/merge-patch+json")
        XCTAssertEqual(Self.body(suspend), #"{"spec":{"suspend":true}}"#)
        XCTAssertEqual(Self.body(KubeWrites.toggle(Self.cronJob(), .suspended, on: false)), #"{"spec":{"suspend":false}}"#)

        let node = Self.node()
        XCTAssertNil(node.namespace, "a node is cluster-wide, whatever namespace was shown")
        let cordon = KubeWrites.toggle(node, .unschedulable, on: true)
        XCTAssertEqual(cordon.path, "/api/v1/nodes/fake-node-1?fieldManager=overterm")
        XCTAssertEqual(Self.body(cordon), #"{"spec":{"unschedulable":true}}"#)
        XCTAssertEqual(Self.body(KubeWrites.toggle(node, .unschedulable, on: false)), #"{"spec":{"unschedulable":null}}"#)

        let namespace = KubeWrites.createNamespace(KubeObjectRef(context: "kind-fake", kind: .namespaces, namespace: nil, name: "scratch"))
        XCTAssertEqual(namespace.method, .POST)
        XCTAssertEqual(namespace.path, "/api/v1/namespaces?fieldManager=overterm")
        XCTAssertEqual(Self.body(namespace), #"{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"scratch"}}"#)
    }

    /// kubectl create job --from=cronjob/…'s Job: the template's spec and
    /// labels, its annotations over instantiate=manual, the CronJob its
    /// controller.
    func testATriggerIsTheJobKubectlMakes() throws {
        let cronJob: [String: Any] = [
            "kind": "CronJob", "metadata": ["name": "nightly", "namespace": "shop", "uid": "cj-uid-1"],
            "spec": [
                "schedule": "0 3 * * *",
                "jobTemplate": [
                    "metadata": ["labels": ["app": "nightly"], "annotations": ["team": "data"]],
                    "spec": ["backoffLimit": 2, "template": ["spec": ["restartPolicy": "OnFailure", "containers": [["name": "job", "image": "busybox:1.36"]]]]],
                ],
            ],
        ]
        let request = try XCTUnwrap(KubeWrites.trigger(Self.cronJob(), cronJob: cronJob, job: "nightly-manual-x2b4k"))
        XCTAssertEqual(request.method, .POST)
        XCTAssertEqual(request.path, "/apis/batch/v1/namespaces/shop/jobs?fieldManager=overterm")
        XCTAssertEqual(request.contentType, "application/json")
        let job = try XCTUnwrap(request.json as? [String: Any])
        XCTAssertEqual(job["kind"] as? String, "Job")
        XCTAssertEqual(job["apiVersion"] as? String, "batch/v1")
        let metadata = try XCTUnwrap(job["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["name"] as? String, "nightly-manual-x2b4k")
        XCTAssertEqual(metadata["namespace"] as? String, "shop")
        XCTAssertEqual(metadata["annotations"] as? [String: String], ["cronjob.kubernetes.io/instantiate": "manual", "team": "data"])
        XCTAssertEqual(metadata["labels"] as? [String: String], ["app": "nightly"])
        let owners = try XCTUnwrap(metadata["ownerReferences"] as? [[String: Any]])
        XCTAssertEqual(owners.count, 1)
        XCTAssertEqual(owners[0]["kind"] as? String, "CronJob")
        XCTAssertEqual(owners[0]["name"] as? String, "nightly")
        XCTAssertEqual(owners[0]["uid"] as? String, "cj-uid-1")
        XCTAssertEqual(owners[0]["apiVersion"] as? String, "batch/v1")
        XCTAssertEqual(owners[0]["controller"] as? Bool, true)
        XCTAssertEqual(owners[0]["blockOwnerDeletion"] as? Bool, true, "as metav1.NewControllerRef makes it")
        XCTAssertEqual((job["spec"] as? [String: Any])?["backoffLimit"] as? Int, 2, "the template's spec, whole")
        XCTAssertNil(KubeWrites.trigger(Self.cronJob(), cronJob: ["metadata": ["uid": "u"], "spec": [:]], job: "x"), "no jobTemplate, no Job")
        XCTAssertNil(KubeWrites.trigger(Self.cronJob(), cronJob: ["spec": cronJob["spec"]!], job: "x"), "no uid, no owner")

        XCTAssertEqual(KubeWrites.manualJobName("nightly", suffix: "x2b4k"), "nightly-manual-x2b4k")
        let long = String(repeating: "a", count: 49) + "-bc"
        let name = KubeWrites.manualJobName(long, suffix: "x2b4k")
        XCTAssertLessThanOrEqual(name.count, 63)
        XCTAssertEqual(name, String(repeating: "a", count: 49) + "-manual-x2b4k", "cut where it ends with a letter")
        XCTAssertNil(KubeNamespaceName.problem(KubeWrites.randomSuffix()), "a suffix a name may hold")
    }

    func testTheKubectlEachEquals() {
        let deployment = KubeWritesTests.deployment()
        XCTAssertEqual(KubeWrites.kubectl(.pause, deployment), "kubectl rollout pause deploy/web --context kind-fake -n shop")
        XCTAssertEqual(KubeWrites.kubectl(.resume, deployment), "kubectl rollout resume deploy/web --context kind-fake -n shop")
        XCTAssertEqual(
            KubeWrites.kubectl(.trigger, Self.cronJob(), job: "nightly-manual-x2b4k"),
            "kubectl create job nightly-manual-x2b4k --from=cronjob/nightly --context kind-fake -n shop")
        XCTAssertEqual(KubeWrites.kubectl(.suspend, Self.cronJob()), #"kubectl patch cj nightly --type=merge -p '{"spec":{"suspend":true}}' --context kind-fake -n shop"#)
        XCTAssertEqual(KubeWrites.kubectl(.unsuspend, Self.cronJob()), #"kubectl patch cj nightly --type=merge -p '{"spec":{"suspend":false}}' --context kind-fake -n shop"#)
        XCTAssertEqual(KubeWrites.kubectl(.cordon, Self.node()), "kubectl cordon fake-node-1 --context kind-fake", "no -n: a node has none")
        XCTAssertEqual(KubeWrites.kubectl(.uncordon, Self.node()), "kubectl uncordon fake-node-1 --context kind-fake")
        XCTAssertEqual(
            KubeWrites.kubectl(.createNamespace, KubeObjectRef(context: "fake-prod", kind: .namespaces, namespace: nil, name: "scratch")),
            "kubectl create namespace scratch --context fake-prod")
    }

    /// Each one's review, and no typed name: none is in rule 4's list.
    func testTheAccessReviewsAndNoTypedName() {
        XCTAssertEqual(KubeWriteCheck.access(.pause, on: KubeWritesTests.deployments), KubeAccess(verb: "patch", resource: "deployments.apps"))
        XCTAssertEqual(KubeWriteCheck.access(.trigger, on: KubeWritesTests.cronjobs), KubeAccess(verb: "create", resource: "jobs.batch"))
        XCTAssertEqual(KubeWriteCheck.access(.unsuspend, on: KubeWritesTests.cronjobs), KubeAccess(verb: "patch", resource: "cronjobs.batch"))
        XCTAssertEqual(KubeWriteCheck.access(.cordon, on: KubeWritesTests.nodes), KubeAccess(verb: "patch", resource: "nodes"))
        XCTAssertEqual(KubeWriteCheck.access(.createNamespace, on: .namespaces), KubeAccess(verb: "create", resource: "namespaces"))
        for verb in KubeWriteVerb.allCases where verb.toggle != nil {
            XCTAssertEqual(verb.opposite?.opposite, verb)
            XCTAssertEqual(verb.opposite?.toggle?.0, verb.toggle?.0)
            XCTAssertEqual(verb.opposite?.toggle?.1, verb.toggle.map { !$0.1 })
            XCTAssertEqual(
                KubeWriteCheck.access(
                    verb, on: [KubeWritesTests.deployments, KubeWritesTests.cronjobs, KubeWritesTests.nodes, KubeGitOpsTests.kustomizations].first { KubeWriteCheck.offered(verb, on: $0) }!),
                KubeWriteCheck.access(
                    verb.opposite!, on: [KubeWritesTests.deployments, KubeWritesTests.cronjobs, KubeWritesTests.nodes, KubeGitOpsTests.kustomizations].first { KubeWriteCheck.offered(verb, on: $0) }!),
                "a toggle turned round keeps its review")
        }
        let prod = KubeWritesTests.context("fake-prod")
        for (verb, kind) in [
            (KubeWriteVerb.pause, KubeWritesTests.deployments), (.resume, KubeWritesTests.deployments), (.trigger, KubeWritesTests.cronjobs),
            (.suspend, KubeWritesTests.cronjobs), (.unsuspend, KubeWritesTests.cronjobs), (.cordon, KubeWritesTests.nodes), (.uncordon, KubeWritesTests.nodes),
            (.createNamespace, .namespaces),
        ] {
            XCTAssertFalse(KubeWriteCheck.rule(verb, for: prod, kind: kind).typedName, "\(verb)")
        }
        XCTAssertTrue(KubeWriteCheck.rule(.delete, for: KubeWritesTests.context("kind-fake"), kind: .namespaces).typedName, "a namespace's delete, everywhere")
        var readOnly = KubeWritesTests.cronjobs
        readOnly.verbs = ["get", "list", "watch"]
        XCTAssertFalse(KubeWriteCheck.offered(.suspend, on: readOnly))
        XCTAssertTrue(KubeWriteCheck.offered(.trigger, on: readOnly), "a trigger patches nothing of the CronJob: it reads it")
        XCTAssertEqual(KubeWriteCheck.rule(.suspend, for: KubeWritesTests.context("kind-fake"), kind: readOnly).refused, "A CronJob has no suspend.")
    }

    func testStatesFromAnObjectOrARow() {
        XCTAssertTrue(KubeWriteToggle.paused.state(of: ["spec": ["paused": true]]))
        XCTAssertFalse(KubeWriteToggle.paused.state(of: ["spec": ["replicas": 1]]))
        XCTAssertNil(KubeWriteToggle.paused.state(cells: ["Ready": "1/1"]), "a Deployment's row doesn't say")
        XCTAssertEqual(KubeWriteToggle.suspended.state(cells: ["Suspend": "True"]), true)
        XCTAssertEqual(KubeWriteToggle.suspended.state(cells: ["Suspend": "False"]), false)
        XCTAssertNil(KubeWriteToggle.suspended.state(cells: [:]))
        XCTAssertEqual(KubeWriteToggle.unschedulable.state(cells: ["Status": "Ready,SchedulingDisabled"]), true)
        XCTAssertEqual(KubeWriteToggle.unschedulable.state(cells: ["Status": "Ready"]), false)
        XCTAssertEqual(KubeWriteToggle.unschedulable.already(true, "node fake-node-1"), "node fake-node-1 is cordoned already.")
        XCTAssertEqual(KubeWriteToggle.paused.already(false, "deployment shop/web"), "deployment shop/web's rollout isn't paused.")
    }

    func testANamespacesNameIsADNSLabel() {
        XCTAssertNil(KubeNamespaceName.problem("scratch"))
        XCTAssertNil(KubeNamespaceName.problem("team-a-2"))
        XCTAssertNil(KubeNamespaceName.problem("7"))
        XCTAssertNil(KubeNamespaceName.problem(String(repeating: "a", count: 63)))
        XCTAssertEqual(KubeNamespaceName.problem(""), "A name, please.")
        XCTAssertEqual(KubeNamespaceName.problem(String(repeating: "a", count: 64)), "At most 63 characters (this is 64).")
        XCTAssertEqual(KubeNamespaceName.problem("Scratch"), "Lowercase only: scratch?")
        XCTAssertEqual(KubeNamespaceName.problem("my_ns"), "Only lowercase letters, digits and - (not “_”).")
        XCTAssertEqual(KubeNamespaceName.problem("a.b"), "Only lowercase letters, digits and - (not “.”).", "a label, not a subdomain")
        XCTAssertEqual(KubeNamespaceName.problem("a b"), "Only lowercase letters, digits and - (not a space).")
        XCTAssertEqual(KubeNamespaceName.problem("-a"), "It must start and end with a letter or a digit.")
        XCTAssertEqual(KubeNamespaceName.problem("a-"), "It must start and end with a letter or a digit.")
    }

    private static let besides = " Whatever else it holds — custom resources, roles, policies… — goes with it too."

    func testWhatANamespacesDeleteWarnsOf() {
        let deployments = KubeWritesTests.deployments
        var contents = KubeNamespaceContents(
            counts: [
                .init(kind: .pods, count: 3), .init(kind: deployments, count: 1), .init(kind: KubeWritesTests.configmaps, count: 500, atLeast: true),
            ])
        XCTAssertEqual(contents.said, "Among the kinds Overterm counts, it holds 3 pods, 1 deployment and 500+ configmaps." + Self.besides, "a lower bound")
        contents.forbidden = ["secrets"]
        XCTAssertEqual(
            contents.said, "Among the kinds Overterm counts, it holds 3 pods, 1 deployment and 500+ configmaps. Not counted (not allowed to list): secrets." + Self.besides)
        XCTAssertEqual(KubeNamespaceContents().said, "It holds none of the kinds Overterm counts." + Self.besides)
        XCTAssertEqual(KubeNamespaceContents(forbidden: ["pods"]).said, "Overterm counted none of what it holds. Not counted (not allowed to list): pods." + Self.besides)
        XCTAssertEqual(KubeNamespaceContents(uncounted: ["pods"]).said, "Overterm counted none of what it holds. Couldn't be counted: pods." + Self.besides)
        let discovery = KubeDiscovery(kinds: [KubeWritesTests.nodes, KubeWritesTests.configmaps, .pods, deployments])
        XCTAssertEqual(KubeNamespaceContents.kinds(in: discovery)?.map(\.fullName), ["pods", "deployments.apps", "configmaps"], "namespaced, in order")
        XCTAssertNil(KubeNamespaceContents.kinds(in: nil), "discovery unknown: nothing to count, not none")

        let confirmation = KubeWriteConfirmation.make(
            .delete, KubeObjectRef(context: "kind-fake", kind: .namespaces, namespace: nil, name: "scratch"), context: KubeWritesTests.context("kind-fake"),
            rule: KubeWriteCheck.rule(.delete, for: KubeWritesTests.context("kind-fake"), kind: .namespaces),
            contents: KubeNamespaceContents(counts: [.init(kind: .pods, count: 2)]))
        XCTAssertEqual(confirmation.title, "Delete namespace scratch and everything in it?")
        XCTAssertEqual(confirmation.scope, "kind-fake · cluster-wide")
        XCTAssertEqual(confirmation.typedName, "scratch")
        XCTAssertEqual(confirmation.button, "Delete Namespace")
        XCTAssertTrue(confirmation.detail.hasPrefix("Among the kinds Overterm counts, it holds 2 pods."), confirmation.detail)
        XCTAssertTrue(confirmation.detail.contains("⚠︎ Everything in the namespace is deleted with it."), confirmation.detail)
        XCTAssertTrue(confirmation.detail.contains("Equals: kubectl delete ns scratch --context kind-fake"), confirmation.detail)
        let uncounted = KubeWriteConfirmation.make(
            .delete, KubeObjectRef(context: "kind-fake", kind: .namespaces, namespace: nil, name: "scratch"), context: KubeWritesTests.context("kind-fake"),
            rule: KubeWriteCheck.rule(.delete, for: KubeWritesTests.context("kind-fake"), kind: .namespaces), contents: nil)
        XCTAssertTrue(uncounted.detail.hasPrefix("What it holds wasn't counted."), "never said as none: \(uncounted.detail)")
    }

    /// A kind's list refused (403) is said as not allowed; any other
    /// failure — a timeout, a 5xx, the proxy gone — as not counted.
    func testWhyAKindWasntCounted() {
        var contents = KubeNamespaceContents()
        contents.failed(KubeWritesTests.configmaps, KubeAPIError(status: 403, reason: "Forbidden", message: "configmaps is forbidden"))
        contents.failed(.pods, KubeAPIError(status: 503, reason: "ServiceUnavailable", message: "unavailable"))
        contents.failed(KubeWritesTests.deployments, URLError(.timedOut))
        XCTAssertEqual(contents.forbidden, ["configmaps"])
        XCTAssertEqual(contents.uncounted, ["pods", "deployments"])
        XCTAssertEqual(
            contents.said,
            "Overterm counted none of what it holds. Not counted (not allowed to list): configmaps. Couldn't be counted: pods, deployments." + Self.besides)
    }

    func testTheConfirmationsAndOutcomes() {
        let kind = KubeWritesTests.context("kind-fake")
        let trigger = KubeWriteConfirmation.make(
            .trigger, Self.cronJob(), context: kind, rule: KubeWriteCheck.rule(.trigger, for: kind, kind: KubeWritesTests.cronjobs), job: "nightly-manual-x2b4k")
        XCTAssertEqual(trigger.title, "Trigger cronjob shop/nightly now?")
        XCTAssertEqual(trigger.scope, "kind-fake · namespace shop")
        XCTAssertNil(trigger.typedName)
        XCTAssertTrue(trigger.detail.contains("Job nightly-manual-x2b4k is made from its jobTemplate"), trigger.detail)
        XCTAssertTrue(trigger.detail.contains("Equals: kubectl create job nightly-manual-x2b4k --from=cronjob/nightly --context kind-fake -n shop"), trigger.detail)
        let prod = KubeWritesTests.context("fake-prod")
        let cordon = KubeWriteConfirmation.make(
            .cordon, KubeObjectRef(context: "fake-prod", kind: KubeWritesTests.nodes, namespace: nil, name: "fake-node-1"), context: prod,
            rule: KubeWriteCheck.rule(.cordon, for: prod, kind: KubeWritesTests.nodes))
        XCTAssertEqual(cordon.title, "Cordon node fake-node-1?")
        XCTAssertEqual(cordon.scope, "PRODUCTION · fake-prod · cluster-wide")
        XCTAssertTrue(cordon.production)
        XCTAssertNil(cordon.typedName)

        XCTAssertEqual(
            KubeWriteOutcome.done(.trigger, Self.cronJob(), job: "nightly-manual-x2b4k"),
            "Triggered cronjob shop/nightly in kind-fake: job shop/nightly-manual-x2b4k made.")
        XCTAssertEqual(KubeWriteOutcome.done(.cordon, Self.node()), "Cordoned node fake-node-1 in kind-fake: no new pod is scheduled on it.")
        let ns = KubeObjectRef(context: "kind-fake", kind: .namespaces, namespace: nil, name: "shop")
        XCTAssertEqual(KubeWriteOutcome.done(.createNamespace, ns), "Made namespace shop in kind-fake.")
        XCTAssertEqual(
            KubeWriteOutcome.failed(.createNamespace, ns, KubeAPIError(status: 409, reason: "AlreadyExists", message: #"namespaces "shop" already exists"#)),
            #"namespace shop is there already: namespaces "shop" already exists"#)
    }
}
