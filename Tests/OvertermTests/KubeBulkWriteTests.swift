import XCTest

@testable import OvertermCore
@testable import OvertermKubernetes

/// K8S-G1: several rows' writes, narrow — pods and Jobs deleted, workloads
/// restarted — asked once for all of them, the count typed on production.
final class KubeBulkWriteTests: XCTestCase {
    private let pods = KubeResourceKind(
        group: "", version: "v1", resource: "pods", kind: "Pod", singular: "pod", namespaced: true, verbs: ["get", "list", "watch", "delete", "patch"],
        shortNames: ["po"])
    private let jobs = KubeResourceKind(
        group: "batch", version: "v1", resource: "jobs", kind: "Job", singular: "job", namespaced: true, verbs: ["get", "list", "delete", "patch"])
    private let deployments = KubeResourceKind(
        group: "apps", version: "v1", resource: "deployments", kind: "Deployment", singular: "deployment", namespaced: true,
        verbs: ["get", "list", "delete", "patch"], shortNames: ["deploy"])
    private let services = KubeResourceKind(
        group: "", version: "v1", resource: "services", kind: "Service", singular: "service", namespaced: true, verbs: ["get", "list", "delete"])

    private func refs(_ kind: KubeResourceKind, _ names: [String], namespace: String = "shop", context: String = "kind-fake") -> [KubeObjectRef] {
        names.map { KubeObjectRef(context: context, kind: kind, namespace: namespace, name: $0) }
    }

    private func context(_ name: String, production: Bool) -> KubeContext {
        KubeContext(
            name: name, cluster: name, server: nil, namespace: "shop", user: "u", auth: nil, file: nil, contextClass: production ? .production : .local,
            settings: KubeContextSettings())
    }

    func testOnlyTheNarrowVerbsAreOffered() {
        XCTAssertEqual(KubeBulkWrite.verbs(for: pods), [.delete])
        XCTAssertEqual(KubeBulkWrite.verbs(for: jobs), [.delete])
        XCTAssertEqual(KubeBulkWrite.verbs(for: deployments), [.restart], "a Deployment is restarted together, not deleted")
        XCTAssertEqual(KubeBulkWrite.verbs(for: services), [], "nothing else yet")
    }

    func testTheRowsAreOneContextOneKindAndBounded() {
        XCTAssertNil(KubeBulkWrite.refusal(.delete, refs(pods, ["a", "b"])))
        XCTAssertNotNil(KubeBulkWrite.refusal(.delete, refs(pods, ["a"])), "one row is the one-row path's")
        XCTAssertNotNil(KubeBulkWrite.refusal(.delete, refs(pods, ["a"]) + refs(pods, ["b"], context: "other")))
        XCTAssertNotNil(KubeBulkWrite.refusal(.delete, refs(pods, ["a"]) + refs(jobs, ["b"])))
        XCTAssertNotNil(KubeBulkWrite.refusal(.restart, refs(pods, ["a", "b"])))
        let many = refs(pods, (0...KubeBulkWrite.maxObjects).map { "p\($0)" })
        XCTAssertEqual(KubeBulkWrite.refusal(.delete, many), "51 rows: at most 50 at once — filter the list or pick fewer.")
        XCTAssertEqual(KubeBulkWrite.namespaces(refs(pods, ["a"]) + refs(pods, ["b"], namespace: "ops") + refs(pods, ["c"])), ["shop", "ops"])
    }

    func testOneQuestionNamesEveryObjectAndTheKubectl() {
        let three = refs(pods, ["web-0", "web-1", "web-2"])
        let local = context("kind-fake", production: false)
        let asked = KubeBulkWrite.confirmation(.delete, three, context: local, rule: KubeWriteCheck.rule(.delete, for: local, kind: pods))
        XCTAssertEqual(asked.title, "Delete 3 pods?")
        XCTAssertEqual(asked.scope, "kind-fake · namespace shop")
        XCTAssertTrue(["web-0", "web-1", "web-2"].allSatisfy(asked.detail.contains), asked.detail)
        XCTAssertEqual(asked.kubectl, "kubectl delete po web-0 web-1 web-2 --context kind-fake -n shop")
        XCTAssertNil(asked.typedName, "nothing typed off production")
        XCTAssertTrue(asked.destroys, "Return is Cancel's")
        XCTAssertEqual(asked.button, "Delete 3")

        let many = refs(pods, (0..<20).map { "p\($0)" })
        XCTAssertTrue(KubeBulkWrite.confirmation(.delete, many, context: local, rule: KubeWriteRule()).detail.contains("…and 8 more."))
    }

    func testOnProductionTheCountIsTyped() {
        let prod = context("fake-prod", production: true)
        let two = refs(deployments, ["api", "worker"], context: "fake-prod")
        let asked = KubeBulkWrite.confirmation(.restart, two, context: prod, rule: KubeWriteCheck.rule(.restart, for: prod, kind: deployments))
        XCTAssertEqual(asked.title, "Restart 2 deployments?")
        XCTAssertTrue(asked.production && asked.scope.hasPrefix(KubeWriteConfirmation.productionMark))
        XCTAssertEqual(asked.typedName, "2")
        XCTAssertTrue(asked.detail.contains("Type 2 to confirm.") && asked.detail.contains("Equals: kubectl rollout restart"), asked.detail)
        XCTAssertFalse(asked.accepts("1"))
        XCTAssertTrue(asked.accepts(" 2 "))
        XCTAssertEqual(asked.kubectl, "kubectl rollout restart deploy/api deploy/worker --context fake-prod -n shop")
    }

    func testWhatCameOfEachIsSaid() {
        let three = refs(pods, ["a", "b", "c"])
        XCTAssertEqual(KubeBulkWrite.outcome(.delete, three.map { ($0, nil) }).said, "Deleted 3 pods.")
        let mixed = KubeBulkWrite.outcome(.delete, [(three[0], nil), (three[1], "forbidden"), (three[2], nil)])
        XCTAssertFalse(mixed.done)
        XCTAssertEqual(mixed.said, "Deleted 2 of 3 pods. 1 failed — b: forbidden.")
    }
}
