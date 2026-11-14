import XCTest

@testable import Overterm

/// Apps grouped from Argo CD's marks (docs/design/kubernetes/gitops.md,
/// 14.1, decision D-5): by installation and instance name; an `ns_name`
/// app apart from a plain one of the same name; copies left out; instance
/// labels tagged; Helm's `app.kubernetes.io/instance` never an app;
/// several namespaces; a cluster-scoped mark's destination; a merge that
/// makes only the changed apps again; and no quadratic work. The data is
/// the spoke's shape — `<env>-<ns>-<name>-service` apps whose objects
/// carry their own marks, a few copies on HPAs — with fictional names.
final class KubeMarkedAppsTests: XCTestCase {
    typealias Key = KubeTrackingID.AppKey

    /// A member as the reader makes it: the marks read against the kind
    /// listed, as a real row's would be.
    static func member(
        _ kind: KubeMarkedKind, _ name: String, namespace: String? = "acme-pay", mark: String? = nil, installation: String? = nil,
        labels: [String: String] = [:], annotations: [String: String] = [:], health: KubeMarkedHealth.Verdict? = nil
    ) -> KubeMarkedMember {
        var all = annotations
        all[KubeGitOpsOwner.trackingAnnotation] = mark
        all[KubeTrackingID.installationAnnotation] = installation
        let identity = KubeTrackingID.Identity(group: kind.group, kind: kind.kind, namespace: namespace, name: name)
        let marks = KubeMarkWire.read(metadata: ["labels": labels, "annotations": all], self: identity)!
        return KubeMarkedMember(
            id: .init(kind: kind, namespace: namespace, name: name), marks: marks, health: health ?? .init(status: .healthy, sentence: "ready"))
    }

    /// The survey's shape: the app named for its env, namespace and name,
    /// the object for its name alone.
    static func tracked(_ kind: KubeMarkedKind, app: String, _ name: String, namespace: String = "acme-pay", installation: String? = nil) -> KubeMarkedMember {
        member(kind, name, namespace: namespace, mark: "\(app):\(kind.group)/\(kind.kind):\(namespace)/\(name)", installation: installation)
    }

    func testGroupedByInstallationAndInstance() {
        let apps = KubeMarkedApps.group([
            Self.tracked(.deployment, app: "prod-acme-pay-checkout-service", "acme-checkout"),
            Self.tracked(.service, app: "prod-acme-pay-checkout-service", "acme-checkout"),
            Self.tracked(.horizontalPodAutoscaler, app: "prod-acme-pay-checkout-service", "acme-checkout"),
            Self.tracked(.deployment, app: "prod-acme-pay-ledger-service", "acme-ledger"),
            Self.tracked(.deployment, app: "prod-acme-pay-checkout-service", "acme-checkout-b", installation: "globex-hub-b"),
        ])
        XCTAssertEqual(
            apps.apps.map(\.key),
            [
                Key(installation: "", instance: "prod-acme-pay-checkout-service"), Key(installation: "", instance: "prod-acme-pay-ledger-service"),
                Key(installation: "globex-hub-b", instance: "prod-acme-pay-checkout-service"),
            ], "two installations are never merged")
        let checkout = apps[Key(installation: "", instance: "prod-acme-pay-checkout-service")]
        XCTAssertEqual(checkout?.countsSaid, "1 Deploy · 1 Svc · 1 HPA")
        XCTAssertEqual(checkout?.said, "prod-acme-pay-checkout-service", "a plain name, in Argo CD's own namespace")
        XCTAssertEqual(checkout?.into, "acme-pay")
        XCTAssertEqual(checkout?.mark, .trackingID)
        XCTAssertEqual(apps[Key(installation: "globex-hub-b", instance: "prod-acme-pay-checkout-service")]?.installation, "globex-hub-b")
    }

    func testAnAppInAnyNamespaceIsApartFromAPlainOneOfTheSameName() {
        let apps = KubeMarkedApps.group([
            Self.tracked(.deployment, app: "acme-team_acme-web", "acme-web"), Self.tracked(.deployment, app: "acme-web", "acme-web-2"),
        ])
        XCTAssertEqual(apps.count, 2)
        let scoped = apps[Key(installation: "", instance: "acme-team_acme-web")]
        XCTAssertEqual(scoped?.appNamespace, "acme-team")
        XCTAssertEqual(scoped?.appName, "acme-web")
        XCTAssertEqual(scoped?.said, "acme-team/acme-web")
        XCTAssertNil(apps[Key(installation: "", instance: "acme-web")]?.appNamespace)
    }

    /// The survey's 99.9%: every member names itself; the few copies are
    /// on HPAs and PDBs naming another object, and are nobody's.
    func testCopiedMarksAreLeftOutAndCounted() {
        let apps = KubeMarkedApps.group([
            Self.tracked(.deployment, app: "prod-acme-pay-checkout-service", "acme-checkout"),
            Self.member(.horizontalPodAutoscaler, "acme-checkout-hpa", mark: "prod-acme-pay-checkout-service:apps/Deployment:acme-pay/acme-checkout"),
            Self.member(
                .other(group: "policy", kind: "PodDisruptionBudget"), "acme-checkout-pdb",
                mark: "prod-acme-pay-checkout-service:apps/Deployment:acme-pay/acme-checkout"),
        ])
        XCTAssertEqual(apps.apps.first?.members.map(\.id.name), ["acme-checkout"])
        XCTAssertEqual(apps.tally.copied, 2)
    }

    func testInstanceLabelMembersAreTaggedAndMalformedMarksCounted() {
        let apps = KubeMarkedApps.group([
            Self.tracked(.deployment, app: "prod-acme-pay-checkout-service", "acme-checkout"),
            Self.member(.service, "acme-checkout", labels: [KubeGitOpsOwner.argoInstanceLabel: "prod-acme-pay-checkout-service"]),
            Self.member(.deployment, "acme-broken", mark: "prod-acme-pay-x:apps/Deployment"),
            Self.member(
                .deployment, "acme-broken-labelled", mark: "garbled\nmark", labels: [KubeGitOpsOwner.argoInstanceLabel: "prod-acme-pay-checkout-service"]),
            Self.member(.deployment, "acme-bad-install", mark: "prod-acme-pay-y:apps/Deployment:acme-pay/acme-bad-install", installation: "Not Valid"),
        ])
        let app = apps.apps.first
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(app?.members.count, 3)
        XCTAssertEqual(app?.labelOnly, 2, "instance-label members tagged")
        XCTAssertEqual(apps.tally.unparsed, 3, "a garbled id, one beside a label, a bad installation id")
    }

    /// Decision D-5: `app.kubernetes.io/instance` alone forms apps only
    /// when no object carries Argo CD's own marks, never with Helm's
    /// release annotation beside it, never mixed into a tracked app.
    func testHelmsInstanceLabelIsNeverAnAppBesideArgoCDsMarks() {
        let helm = Self.member(
            .deployment, "acme-redis", labels: [KubeGitOpsOwner.appInstanceLabel: "acme-redis"],
            annotations: [KubeGitOpsOwner.helmReleaseAnnotation: "acme-redis"])
        let probable = Self.member(.deployment, "acme-web", labels: [KubeGitOpsOwner.appInstanceLabel: "prod-acme-pay-checkout-service"])
        let tracked = Self.tracked(.deployment, app: "prod-acme-pay-checkout-service", "acme-checkout")
        var apps = KubeMarkedApps.group([helm, probable, tracked])
        XCTAssertEqual(apps.apps.map(\.key.instance), ["prod-acme-pay-checkout-service"])
        XCTAssertEqual(apps.apps.first?.members.map(\.id.name), ["acme-checkout"], "never mixed into the tracked app of the same name")
        XCTAssertEqual(apps.tally.helm, 1)
        XCTAssertFalse(apps.isProbable)
        apps.merge(changed: [], removed: [tracked.id])
        XCTAssertTrue(apps.isProbable, "the only marks left are app.kubernetes.io/instance")
        XCTAssertEqual(apps.apps.map(\.members.first?.id.name), ["acme-web"])
        XCTAssertEqual(apps.apps.first?.mark, .appInstance)
    }

    func testAnAppAcrossNamespacesAndAClusterScopedMarksDestination() {
        let apps = KubeMarkedApps.group([
            Self.tracked(.statefulSet, app: "prod-acme-search-indexer-service", "acme-indexer", namespace: "acme-search"),
            Self.tracked(.cronJob, app: "prod-acme-search-indexer-service", "acme-reindex", namespace: "acme-search-jobs"),
            Self.member(
                .other(group: "rbac.authorization.k8s.io", kind: "ClusterRole"), "acme-indexer-reader", namespace: nil,
                mark: "prod-acme-search-indexer-service:rbac.authorization.k8s.io/ClusterRole:acme-search-dest/acme-indexer-reader"),
        ])
        let app = apps.apps.first
        XCTAssertEqual(app?.members.count, 3, "a cluster-scoped object's mark names itself whatever its namespace part")
        XCTAssertEqual(app?.destination, "acme-search-dest")
        XCTAssertEqual(app?.namespaces, ["acme-search", "acme-search-dest", "acme-search-jobs"])
        XCTAssertEqual(app?.into, "acme-search +2")
    }

    func testTheMergeMakesOnlyTheChangedAppsAgain() {
        let members = (0..<50).map { Self.tracked(.deployment, app: "prod-acme-team-svc\($0)-service", "acme-svc\($0)") }
        var apps = KubeMarkedApps.group(members)
        XCTAssertEqual(apps.count, 50)
        var moved = members[3]
        moved.health = .init(status: .progressing, sentence: "1/2 updated", fromRow: true)
        let relabelled = Self.tracked(.deployment, app: "prod-acme-team-svc9-service", "acme-svc7")
        let dirty = apps.merge(changed: [moved, relabelled], removed: [members[11].id])
        XCTAssertEqual(
            dirty,
            [
                Key(installation: "", instance: "prod-acme-team-svc3-service"), Key(installation: "", instance: "prod-acme-team-svc7-service"),
                Key(installation: "", instance: "prod-acme-team-svc9-service"), Key(installation: "", instance: "prod-acme-team-svc11-service"),
            ])
        XCTAssertEqual(apps.count, 48, "svc7 moved into svc9's app, svc11 gone")
        XCTAssertEqual(apps[Key(installation: "", instance: "prod-acme-team-svc9-service")]?.members.count, 2)
        XCTAssertEqual(apps[Key(installation: "", instance: "prod-acme-team-svc3-service")]?.health.state, .progressing)
        XCTAssertEqual(apps, KubeMarkedApps.group(Array(members.filter { ![3, 7, 11].contains(Int($0.id.name.dropFirst(8))!) }) + [moved, relabelled]))
    }

    /// No accidental quadratic work, counted rather than timed: grouping
    /// 10,000 rows makes each app once, from its own members only, and a
    /// merge of a few changed rows makes only their apps again — the
    /// members it reads are those apps', never the whole scope's.
    func testGroupingScales() {
        func members(_ count: Int) -> [KubeMarkedMember] {
            (0..<count).map { index in
                let app = "prod-acme-team\(index % 70)-svc\(index / 2)-service"
                return Self.tracked(index % 5 == 0 ? .service : .deployment, app: app, "acme-svc\(index)", namespace: "acme-team\(index % 70)")
            }
        }
        for count in [5_000, 10_000] {
            let all = members(count)
            var apps = KubeMarkedApps.group(all)
            XCTAssertEqual(apps.membersMade, count, "\(count) rows: every member read once")
            XCTAssertEqual(apps.apps.reduce(0) { $0 + $1.members.count }, count)
            let before = apps.membersMade
            var changed = all[10]
            changed.health = .init(status: .progressing, sentence: "1/2 updated", fromRow: true)
            let dirty = apps.merge(changed: [changed, all[count - 1]], removed: [all[20].id])
            let touched = dirty.compactMap { apps[$0]?.members.count }.reduce(0, +)
            XCTAssertEqual(apps.membersMade - before, touched, "a merge reads only its apps' members")
            XCTAssertLessThanOrEqual(touched, 6, "three apps of two members each, at most")
        }
    }
}

/// When marks mode is on, and which apps it derives (gitops.md, 14.3 and
/// 14.12's first consequence): not served, served with none listed, or
/// marked apps absent from a whole list; unknown never said absent.
final class KubeMarkedAppsModeTests: XCTestCase {
    typealias Key = KubeTrackingID.AppKey

    static let applications = KubeResourceKind(
        group: "argoproj.io", version: "v1alpha1", resource: "applications", kind: "Application", singular: "application", namespaced: true,
        verbs: ["get", "list", "watch"])

    func discovery(served: Bool, failed: [String] = []) -> KubeDiscovery {
        KubeDiscovery(
            kinds: [.deployments] + (served ? [Self.applications] : []), failedGroups: Dictionary(uniqueKeysWithValues: failed.map { ($0, "503") }))
    }

    func key(_ instance: String, _ installation: String = "") -> Key { Key(installation: installation, instance: instance) }

    func testNotServedIsAnotherClusterUnlessArgoprojFailedDiscovery() {
        let marked: Set<Key> = [key("prod-acme-pay-checkout-service")]
        XCTAssertEqual(KubeMarkedAppsMode.of(discovery: discovery(served: false), applications: .notYetListed, marked: marked), .only(.notServed))
        XCTAssertEqual(
            KubeMarkedAppsMode.of(discovery: discovery(served: false, failed: ["metrics.k8s.io/v1beta1"]), applications: .notYetListed, marked: marked),
            .only(.notServed), "a down metrics.k8s.io says nothing about Argo CD")
        let undiscovered = KubeMarkedAppsMode.of(
            discovery: discovery(served: false, failed: ["argoproj.io/v1alpha1"]), applications: .notYetListed, marked: marked)
        XCTAssertEqual(undiscovered, .only(.undiscovered))
        XCTAssertFalse(KubeMarkedAppsMode.Reason.undiscovered.line(context: "fake-spoke").contains("another cluster"))
        XCTAssertTrue(KubeMarkedAppsMode.Reason.notServed.line(context: "fake-spoke").contains("another cluster"))
        for reason in [KubeMarkedAppsMode.Reason.noApplications, .forbidden, .undiscovered] {
            XCTAssertFalse(reason.line(context: "fake-spoke").contains("another cluster"), "only notServed says another cluster")
            XCTAssertFalse(reason.line(context: "fake-spoke").contains("isn't installed"))
        }
    }

    func testNoDiscoveryIsOffAndTheFirstListNotYetComeIsOff() {
        XCTAssertEqual(KubeMarkedAppsMode.of(discovery: nil, applications: .notYetListed, marked: [key("a")]), .off, "a sign-in still waiting: nothing said")
        XCTAssertEqual(KubeMarkedAppsMode.of(discovery: discovery(served: true), applications: .notYetListed, marked: [key("a")]), .off)
    }

    /// The development cluster's shape: the kind served, no Application in it.
    func testServedWithNoApplicationListedDerivesThemAll() {
        let mode = KubeMarkedAppsMode.of(discovery: discovery(served: true), applications: .acrossCluster([]), marked: [key("dev-acme-pay-checkout-service")])
        XCTAssertEqual(mode, .only(.noApplications))
        XCTAssertEqual(KubeMarkedAppsMode.Reason.noApplications.line(context: "fake-dev"), "Argo CD's Applications for these aren't in this cluster.")
        XCTAssertEqual(KubeMarkedAppsMode.of(discovery: discovery(served: true), applications: .refused, marked: []), .only(.forbidden))
    }

    /// A hub with Argo CD installed and no Application yet, and no marks
    /// anywhere: today's section, never a derived header naming nothing.
    func testServedWithNoApplicationAndNoMarksIsOff() {
        XCTAssertEqual(KubeMarkedAppsMode.of(discovery: discovery(served: true), applications: .acrossCluster([]), marked: []), .off)
    }

    /// R1's row follow lists every Application, uncut; R2's 500 summaries
    /// are no input, so a 1,000-Application hub still finds its missing ones.
    func testBesideApplicationsListedWholeOnlyTheMissingAreSaidMissing() {
        let rows = (0..<1_000).map { KubeRowID(namespace: "argocd", name: "acme-app\($0)") } + [KubeRowID(namespace: "acme-team", name: "acme-web")]
        let marked: Set<Key> = [
            key("acme-app7"), key("acme-team_acme-web"), key("acme-app2000"), key("acme-other_acme-app3"), key("acme-app4", "globex-hub-b"),
            key("acme-app5000", "globex-hub-b"), key("acme-web"),
        ]
        guard case .beside(let coexistence) = KubeMarkedAppsMode.of(discovery: discovery(served: true), applications: .acrossCluster(rows), marked: marked)
        else { return XCTFail("coexistence") }
        XCTAssertEqual(coexistence.missing, [key("acme-app2000")])
        XCTAssertEqual(
            coexistence.maybe, [key("acme-other_acme-app3"): KubeRowID(namespace: "argocd", name: "acme-app3"), key("acme-web"): KubeRowID(namespace: "acme-team", name: "acme-web")],
            "a name an Application has elsewhere: listed, never said missing")
        XCTAssertEqual(coexistence.otherInstallation, [key("acme-app5000", "globex-hub-b")], "an installation id can't be matched to a local Application")
        XCTAssertTrue(coexistence.unknown.isEmpty)
        XCTAssertEqual(
            KubeMarkedAppsMode.of(discovery: discovery(served: true), applications: .acrossCluster(rows), marked: [key("acme-app7")]), .off,
            "every marked app has its Application")
    }

    func testApplicationsReadOnlyInFallbackNamespacesSayMissingOnlyThere() {
        let rows = [KubeRowID(namespace: "argocd", name: "acme-shop")]
        let marked: Set<Key> = [key("acme-team_acme-web"), key("acme-elsewhere_acme-api"), key("acme-plain"), key("acme-team_acme-shop")]
        guard
            case .beside(let coexistence) = KubeMarkedAppsMode.of(
                discovery: discovery(served: true), applications: .namespaces(["argocd", "acme-team"], rows), marked: marked)
        else { return XCTFail("coexistence") }
        XCTAssertEqual(coexistence.missing, [key("acme-team_acme-web")], "an ns_name mark whose namespace was read")
        XCTAssertEqual(coexistence.unknown, [key("acme-elsewhere_acme-api"), key("acme-plain")], "a plain name's namespace is unknown")
        XCTAssertEqual(coexistence.maybe.keys.sorted(), [key("acme-team_acme-shop")])
        XCTAssertEqual(coexistence.listed, [key("acme-team_acme-web"), key("acme-team_acme-shop")])
    }
}
