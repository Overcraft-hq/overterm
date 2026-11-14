import XCTest

@testable import Overterm

/// Argo CD's tracking id read as Argo CD reads it, and counted only on the
/// object it names (docs/design/kubernetes/gitops.md, 14.1, 14.6): its
/// forms, the core group, a cluster-scoped object's destination namespace,
/// apps in any namespace; every malformed or over-long value refused; the
/// installation id. The names are the spoke's shape — `<env>-<ns>-<name>-service`
/// — and fictional.
final class KubeTrackingIDTests: XCTestCase {
    func testTheFormsArgoCDWrites() throws {
        let deployment = try XCTUnwrap(KubeTrackingID.parse("prod-payments-checkout-service:apps/Deployment:payments/checkout-api"))
        XCTAssertEqual(
            deployment,
            KubeTrackingID(instance: "prod-payments-checkout-service", group: "apps", kind: "Deployment", namespace: "payments", name: "checkout-api"))
        XCTAssertNil(deployment.appNamespace, "a plain name: an Application in Argo CD's own namespace, unknown here")
        XCTAssertEqual(deployment.appName, "prod-payments-checkout-service")
        XCTAssertEqual(deployment.said, "prod-payments-checkout-service")

        let core = try XCTUnwrap(KubeTrackingID.parse("prod-payments-checkout-service:/Service:payments/checkout-api"))
        XCTAssertEqual(core.group, "", "the core group is empty")
        XCTAssertEqual(core.kind, "Service")

        let cluster = try XCTUnwrap(KubeTrackingID.parse("acme-rbac:rbac.authorization.k8s.io/ClusterRole:payments/acme-reader"))
        XCTAssertEqual(cluster.namespace, "payments", "a cluster-scoped object's: the Application's destination namespace")
        XCTAssertEqual(KubeTrackingID.parse("acme-rbac:rbac.authorization.k8s.io/ClusterRole:/acme-reader")?.namespace, "", "none when the destination has none")

        let anyNamespace = try XCTUnwrap(KubeTrackingID.parse("team-a_acme-web:apps/Deployment:shop/web"))
        XCTAssertEqual(anyNamespace.appNamespace, "team-a")
        XCTAssertEqual(anyNamespace.appName, "acme-web")
        XCTAssertEqual(anyNamespace.said, "team-a/acme-web")
        XCTAssertEqual(KubeGitOpsOwner(tracking: anyNamespace), KubeGitOpsOwner(tool: .argoCD, name: "acme-web", namespace: "team-a", mark: .trackingID))

        XCTAssertNotNil(
            KubeTrackingID.parse("fake-app:apps/Deployment:shop/" + String(repeating: "a", count: 120)), "a name's parts aren't capped at 63, only the whole")
        XCTAssertNotNil(KubeTrackingID.parse("fake-app:example.com/Widget:shop/web.v2"), "a custom resource, a dotted name")
    }

    func testEveryMalformedValueIsNoTrackingID() {
        let refused = [
            "", "no-colon", "acme-shop:anything", "acme-shop:apps/Deployment", "acme-shop:apps/Deployment:shop/web:extra",
            "acme-shop:apps/Deployment:shop", ":apps/Deployment:shop/web", "acme-shop:apps:shop/web", "acme-shop:apps/Deployment/x:shop/web",
            "acme-shop:apps/Deployment:shop/web/x", "acme-shop:apps/Deployment:shop/../etc", "acme-shop:apps/Deployment:shop/..",
            "acme-shop:apps/:shop/web", "acme-shop:apps/Deploy-ment:shop/web", "acme-shop:apps/Deployment:shop/",
            "acme-shop:Apps/Deployment:shop/web", "acme-shop:apps/Deployment:Shop/web", "acme-shop:apps/Deployment:shop/Web",
            "Acme-Shop:apps/Deployment:shop/web", "a_b_c:apps/Deployment:shop/web", "_acme:apps/Deployment:shop/web", "acme_:apps/Deployment:shop/web",
            "acme shop:apps/Deployment:shop/web", "acme-shop:apps/Deployment:-shop/web", "acme-shop:apps/Deployment:shop/web-",
            "acme-shop:apps/Deployment:shop/web\n", "acme-shop\u{0}:apps/Deployment:shop/web", "acme-shop:apps/Deployment:shop/w\u{7}eb",
            "acme-shöp:apps/Deployment:shop/web",
        ]
        for value in refused { XCTAssertNil(KubeTrackingID.parse(value), value.debugDescription) }
    }

    func testOverLongPartsAndValuesAreRefused() {
        let long = String(repeating: "a", count: 254)
        XCTAssertNil(KubeTrackingID.parse("\(long):apps/Deployment:shop/web"), "an app part over 253")
        XCTAssertNil(KubeTrackingID.parse("acme:apps/Deployment:shop/\(long)"), "a name over 253")
        XCTAssertNil(KubeTrackingID.parse("acme:apps/\(String(repeating: "K", count: 64)):shop/web"), "a Kind over 63")
        XCTAssertNil(KubeTrackingID.parse("acme:apps/Deployment:\(String(repeating: "n", count: 64))/web"), "a namespace over 63")
        XCTAssertNotNil(KubeTrackingID.parse("acme:apps/Deployment:\(String(repeating: "n", count: 63))/web"))
        // 2 KB: past the 1,024-byte cap whatever its parts say.
        let twoKB = "acme:apps/Deployment:shop/" + Array(repeating: String(repeating: "a", count: 60), count: 34).joined(separator: ".")
        XCTAssertGreaterThan(twoKB.utf8.count, 2000)
        XCTAssertNil(KubeTrackingID.parse(twoKB))
        XCTAssertEqual(KubeGitOpsOwner.tracking(twoKB), nil)
    }

    func testSelfIsTheObjectTheMarkNames() throws {
        let id = try XCTUnwrap(KubeTrackingID.parse("prod-shop-api-service:apps/Deployment:shop/api"))
        XCTAssertTrue(id.isSelf(group: "apps", kind: "Deployment", namespace: "shop", name: "api", clusterScoped: false))
        XCTAssertFalse(id.isSelf(group: "apps", kind: "ReplicaSet", namespace: "shop", name: "api-7d9f8c6b5", clusterScoped: false), "its ReplicaSet's copy")
        XCTAssertFalse(id.isSelf(group: "apps", kind: "Deployment", namespace: "shop-2", name: "api", clusterScoped: false), "copied across namespaces")
        XCTAssertFalse(id.isSelf(group: "extensions", kind: "Deployment", namespace: "shop", name: "api", clusterScoped: false), "another group")
        XCTAssertFalse(id.isSelf(group: "apps", kind: "Deployment", namespace: "shop", name: "web", clusterScoped: false))

        let service = try XCTUnwrap(KubeTrackingID.parse("prod-shop-api-service:/Service:shop/api"))
        XCTAssertTrue(service.isSelf(KubeTrackingID.Identity(group: "", kind: "Service", namespace: "shop", name: "api")), "the core group")
        XCTAssertFalse(service.isSelf(KubeTrackingID.Identity(group: "apps", kind: "Service", namespace: "shop", name: "api")))

        let role = try XCTUnwrap(KubeTrackingID.parse("acme-rbac:rbac.authorization.k8s.io/ClusterRole:payments/acme-reader"))
        XCTAssertTrue(
            role.isSelf(KubeTrackingID.Identity(group: "rbac.authorization.k8s.io", kind: "ClusterRole", namespace: nil, name: "acme-reader")),
            "a cluster-scoped object: its namespace part is the destination's")
        XCTAssertFalse(
            role.isSelf(group: "rbac.authorization.k8s.io", kind: "ClusterRole", namespace: "other", name: "acme-reader", clusterScoped: false))
    }

    func testAnIdentityFromAnObjectsOwnKindAndMetadata() {
        XCTAssertEqual(
            KubeTrackingID.Identity.of(["apiVersion": "apps/v1", "kind": "Deployment", "metadata": ["name": "api", "namespace": "shop"]]),
            KubeTrackingID.Identity(group: "apps", kind: "Deployment", namespace: "shop", name: "api"))
        XCTAssertEqual(
            KubeTrackingID.Identity.of(["apiVersion": "v1", "kind": "Namespace", "metadata": ["name": "shop"]]),
            KubeTrackingID.Identity(group: "", kind: "Namespace", namespace: nil, name: "shop"))
        XCTAssertNil(KubeTrackingID.Identity.of(["metadata": ["name": "api"]]), "no kind said: unknown")
    }

    func testTheInstallationIDKeysTheApp() throws {
        let id = try XCTUnwrap(KubeTrackingID.parse("prod-shop-api-service:apps/Deployment:shop/api"))
        XCTAssertEqual(id.appKey(installation: nil), KubeTrackingID.AppKey(installation: "", instance: "prod-shop-api-service"))
        XCTAssertEqual(id.appKey(installation: ""), KubeTrackingID.AppKey(installation: "", instance: "prod-shop-api-service"))
        XCTAssertEqual(id.appKey(installation: "acme-hub-b"), KubeTrackingID.AppKey(installation: "acme-hub-b", instance: "prod-shop-api-service"))
        XCTAssertNotEqual(id.appKey(installation: "acme-hub-b"), id.appKey(installation: nil), "two installations are never one app")
        XCTAssertNil(id.appKey(installation: String(repeating: "h", count: 64)), "over 63")
        XCTAssertNil(id.appKey(installation: "hub\nb"))
        XCTAssertNil(id.appKey(installation: "Hub B"))
        XCTAssertEqual(KubeTrackingID.installation("acme.hub_b-2"), "acme.hub_b-2")
    }
}
